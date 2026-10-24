import UIKit

/// 下载结果
struct DKDownloadResult {
    let entry: RepoEntry
    let error: Error?
    let skipped: Bool
}

/// 只下载、不入队。完全独立于 Sileo 的 DownloadManager。
final class DKDownloader {

    struct Progress {
        let index: Int       // 第几个（从 1 开始）
        let total: Int
        let name: String
        let fraction: Double
    }

    private var currentTask: URLSessionTask?
    private var observation: NSKeyValueObservation?
    private(set) var isCancelled = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = DKDownloader.headers
        return URLSession(configuration: config)
    }()

    /// 与 Sileo 一致的基本请求头（不发送任何设备唯一标识）
    private static var headers: [String: String] {
        let sileoVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.5"
        var machine = [CChar](repeating: 0, count: 64)
        var size = machine.count
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return [
            "User-Agent": "Sileo/\(sileoVersion) CoreFoundation/\(Int(kCFCoreFoundationVersionNumber))",
            "X-Firmware": UIDevice.current.systemVersion,
            "X-Machine": String(cString: machine)
        ]
    }

    func cancel() {
        isCancelled = true
        currentTask?.cancel()
    }

    /// 依次下载，回调都在主线程
    func download(_ entries: [RepoEntry],
                  progress: @escaping (Progress) -> Void,
                  completion: @escaping ([DKDownloadResult]) -> Void) {
        var results = [DKDownloadResult]()
        func next(_ index: Int) {
            if index >= entries.count || isCancelled {
                DispatchQueue.main.async { completion(results) }
                return
            }
            let entry = entries[index]
            if ArchiveStore.contains(package: entry.package, version: entry.version, architecture: entry.architecture) {
                results.append(DKDownloadResult(entry: entry, error: nil, skipped: true))
                next(index + 1)
                return
            }
            downloadOne(entry, onProgress: { fraction in
                DispatchQueue.main.async {
                    progress(Progress(index: index + 1, total: entries.count, name: entry.name, fraction: fraction))
                }
            }, completion: { error in
                results.append(DKDownloadResult(entry: entry, error: error, skipped: false))
                if error == nil { ArchiveStore.applyRetention(package: entry.package) }
                next(index + 1)
            })
        }
        next(0)
    }

    private func downloadOne(_ entry: RepoEntry, onProgress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        DKPayments.shared.resolve(entry, taskStarted: { task in
            self.currentTask = task
            if self.isCancelled { task.cancel() }
        }) { result in
            guard !self.isCancelled else {
                completion(DKError.message(DKL("已取消")))
                return
            }
            switch result {
            case .failure(let error): completion(error)
            case .success(let url): self.downloadFile(entry, url: url, onProgress: onProgress, completion: completion)
            }
        }
    }

    private func downloadFile(_ entry: RepoEntry, url: URL, onProgress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        let task = session.downloadTask(with: url) { tmp, response, error in
            if let error = error {
                completion(error)
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(DKError.message(DKL("服务器返回 HTTP %d", http.statusCode)))
                return
            }
            guard let tmp = tmp else {
                completion(DKError.message(DKL("下载失败")))
                return
            }
            // URLSession 的临时文件在回调结束后会被删除，先移到自己的目录
            let fm = FileManager.default
            try? fm.createDirectory(atPath: DKPaths.tmpDir, withIntermediateDirectories: true)
            let staged = URL(fileURLWithPath: DKPaths.tmpDir + "/" + UUID().uuidString + ".deb")
            do {
                try fm.moveItem(at: tmp, to: staged)
            } catch {
                completion(error)
                return
            }
            // SHA256 校验
            let actual = sha256(ofFile: staged.path) ?? ""
            var verified = false
            if let expected = entry.sha256, !expected.isEmpty {
                guard expected == actual else {
                    try? fm.removeItem(at: staged)
                    completion(DKError.message(DKL("SHA256 校验失败，文件可能已损坏或被篡改")))
                    return
                }
                verified = true
            }
            do {
                try ArchiveStore.save(tempFile: staged, entry: entry, verified: verified, sha256: actual)
                completion(nil)
            } catch {
                try? fm.removeItem(at: staged)
                completion(error)
            }
        }
        observation = task.progress.observe(\.fractionCompleted) { p, _ in
            onProgress(p.fractionCompleted)
        }
        currentTask = task
        task.resume()
    }

    // MARK: - 依赖解析（简化版）

    /// 递归收集依赖。规则：
    /// - "a | b" 取第一个在源里能找到的
    /// - 忽略版本约束，取最新版本
    /// - 找不到的（虚拟包、系统自带如 firmware）记入 unresolved
    static func resolveDependencies(of root: RepoEntry) -> (entries: [RepoEntry], unresolved: [String]) {
        var chosen = [root]
        var visited: Set<String> = [root.package]
        var unresolved = [String]()
        var queue = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for group in current.dependencyGroups {
                if group.contains(where: { visited.contains($0) }) { continue }
                var picked: RepoEntry?
                var needsAuthorization: RepoEntry?
                for name in group {
                    let candidates = RepoIndex.shared.entries(for: name)
                    if let candidate = candidates.first(where: { !$0.isCommercial || DKPayments.shared.isPurchased($0) == true }) {
                        picked = candidate
                        break
                    }
                    if needsAuthorization == nil { needsAuthorization = candidates.first }
                }
                if let picked = picked ?? needsAuthorization {
                    visited.insert(picked.package)
                    chosen.append(picked)
                    queue.append(picked)
                } else {
                    let label = group.joined(separator: " | ")
                    if !unresolved.contains(label) { unresolved.append(label) }
                    group.forEach { visited.insert($0) }
                }
            }
        }
        return (chosen, unresolved)
    }
}

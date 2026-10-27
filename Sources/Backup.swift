import Foundation

/// dpkg 里记录的某个已安装版本
struct InstalledVersion: Codable, Equatable {
    var version: String
    var architecture: String
}

/// 需要补存进仓库的版本
enum BackupAction: Equatable {
    /// 当前装着的版本（新装，或升级之后的新版本）
    case installed(package: String, version: String, architecture: String)
    /// 升级前装着的旧版本——只能从 APT 缓存或软件源找回原始 DEB
    case previous(package: String, version: String, architecture: String)

    var package: String {
        switch self {
        case .installed(let p, _, _), .previous(let p, _, _): return p
        }
    }

    var version: String {
        switch self {
        case .installed(_, let v, _), .previous(_, let v, _): return v
        }
    }

    var architecture: String {
        switch self {
        case .installed(_, _, let a), .previous(_, _, let a): return a
        }
    }

    var isPrevious: Bool {
        if case .previous = self { return true }
        return false
    }
}

/// 纯逻辑：对比前后两次 dpkg 状态，决定要补存哪些版本
enum BackupPlan {
    static func actions(previous: [String: InstalledVersion],
                        current: [String: InstalledVersion],
                        autoBackup: Bool,
                        installBackup: Bool,
                        archived: (String, String) -> Bool) -> [BackupAction] {
        // 第一次运行只建立基线：不把整台设备已有的包装一次性倒进仓库
        guard !previous.isEmpty else { return [] }
        var actions = [BackupAction]()
        for package in current.keys.sorted() {
            guard let now = current[package], previous[package]?.version != now.version else { continue }
            if let before = previous[package], autoBackup, !archived(package, before.version) {
                actions.append(.previous(package: package, version: before.version,
                                         architecture: before.architecture))
            }
            if installBackup, !archived(package, now.version) {
                actions.append(.installed(package: package, version: now.version,
                                          architecture: now.architecture))
            }
        }
        return actions
    }
}

/// APT 缓存里的 DEB 文件名：<包名>_<版本>_<架构>.deb。
/// 三段都按 APT 的规则编码过（_ → %5f，: → %3a，架构里的 . → %2e），所以可以直接按 _ 切分。
struct CachedDebName: Equatable {
    let package: String
    let version: String
    let architecture: String

    init?(fileName: String) {
        guard fileName.hasSuffix(".deb") else { return nil }
        let parts = fileName.dropLast(4).split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        package = CachedDebName.decode(parts[0])
        version = CachedDebName.decode(parts[1])
        architecture = CachedDebName.decode(parts[2])
    }

    static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "%5f", with: "_", options: .caseInsensitive)
            .replacingOccurrences(of: "%3a", with: ":", options: .caseInsensitive)
            .replacingOccurrences(of: "%2e", with: ".", options: .caseInsensitive)
    }
}

/// 留存目录（captured）的清理规则
enum CapturePolicy {
    /// 当前装着的版本一直保留：它就是下次升级时要补存的"旧版本"。
    /// 其他版本（已经补存进仓库的旧版本、下载了但没装上的、已卸载的包）在这个包最近一次留存
    /// 之后放够 maxAge 再删，免得删掉刚下载、Sileo 还没来得及安装的 DEB。
    static func shouldPrune(version: String, installedVersion: String?, age: TimeInterval,
                            maxAge: TimeInterval = 86400) -> Bool {
        if let installedVersion = installedVersion, installedVersion == version { return false }
        return age > maxAge
    }
}

/// 安装/升级完成之后补存 DEB。
///
/// 不在 APT 事务里做任何事：装完之后对比 dpkg 状态，发现版本变了就补存——
/// 先用 DKCapture 在下载时留存的原始 DEB（Sileo 装完会 apt-get clean，缓存里通常已经没有了），
/// 再看 APT 缓存（Zebra、apt 命令行等其他前端），都没有才从软件源按版本号拉一次。
/// 拿到的都是原始字节，不需要 root、不需要 shell，也不会让安装卡住或失败。
enum DKBackup {

    private static let queue = DispatchQueue(label: "im.mjh.doleo.backup", qos: .utility)
    private static let lock = NSLock()
    private static var lastStart = Date.distantPast

    /// 从 Sileo 启动、回到前台、装完一个队列等时机触发；内部节流，可以随便调。
    /// force 用于"刚装完"的通知，不受节流限制
    static func start(force: Bool = false) {
        lock.lock()
        let now = Date()
        let tooSoon = !force && now.timeIntervalSince(lastStart) < 5
        if !tooSoon { lastStart = now }
        lock.unlock()
        guard !tooSoon else { return }
        queue.async { sweep() }
    }

    // MARK: - 主流程

    private static func sweep() {
        guard DKPaths.isDataDirWritable else { return }
        let installed = DpkgStatus.all()
        guard !installed.isEmpty else { return }
        let baseline = installed.mapValues {
            InstalledVersion(version: $0.version, architecture: $0.architecture)
        }

        let settings = DKSettings.current
        guard settings.autoBackup || settings.installBackup else {
            // 两个开关都关着：只更新基线，留存目录也不再保留
            Snapshot.save(baseline)
            DKCapture.prune(installed: baseline, keep: [], removeAll: true)
            return
        }
        // 先把缓存里还没来得及留存的 DEB 收进来
        DKCapture.scanNow()

        let previous = Snapshot.load()
        guard !previous.isEmpty else {
            // 首次运行：只建立基线，不倒灌整台设备
            Snapshot.save(baseline)
            DKCapture.prune(installed: baseline, keep: [])
            return
        }

        let actions = BackupPlan.actions(
            previous: previous,
            current: baseline,
            autoBackup: settings.autoBackup,
            installBackup: settings.installBackup,
            archived: { package, version in
                ArchiveStore.items(for: package).contains { $0.meta.version == version }
            })

        var next = baseline
        var saved = false
        var failed = Set<String>()
        var storedLocally = Set<String>()
        for action in actions {
            if importLocal(action) { saved = true; storedLocally.insert(action.package); continue }
            // 软件源下载走 DKDownloader，它自己会按保留数量清理
            if download(action) { saved = true; continue }
            log("跳过 \(action.package) \(action.version)：没有留存，缓存里没有，软件源也找不到")
            failed.insert(action.package)
        }

        // 失败的包保持旧基线，下次回到 Sileo 时再试一次（留存/缓存/索引都是本地读取，不会再走网络）
        for package in failed {
            if let before = previous[package] { next[package] = before }
            else { next.removeValue(forKey: package) }
        }
        Snapshot.save(next)
        // 和手动下载一样遵守"每个包保留版本数"（已下架的版本不会被清理）
        for package in storedLocally.sorted() {
            ArchiveStore.applyRetention(package: package)
        }
        // 补存完再清理留存目录：已经进仓库的旧版本在仓库里有自己的硬链接，这里删掉不影响
        DKCapture.prune(installed: baseline, keep: failed)
        if saved { try? ArchiveStore.rebuildLocalIndex() }
    }

    // MARK: - 来源

    /// 留存目录或 APT 缓存里有这个版本的原始 DEB 时，直接链接进仓库（不复制数据）
    private static func importLocal(_ action: BackupAction) -> Bool {
        guard let source = DKCapture.localDeb(package: action.package, version: action.version) else {
            return false
        }
        return store(source: source, action: action)
    }

    /// 缓存里没有：按版本号从软件源重新拉一份（付费包沿用 Sileo 的授权流程）
    private static func download(_ action: BackupAction) -> Bool {
        guard let entry = RepoIndex.shared.entry(package: action.package, version: action.version) else {
            return false
        }
        let downloader = DKDownloader(origin: action.isPrevious ? "upgrade" : "install")
        let done = DispatchSemaphore(value: 0)
        var ok = false
        downloader.download([entry], progress: { _ in }, completion: { results in
            ok = results.contains { $0.error == nil }
            done.signal()
        })
        guard done.wait(timeout: .now() + 180) == .success, ok else {
            log("下载失败 \(action.package) \(action.version)")
            return false
        }
        log("已保存 \(action.package) \(action.version)（软件源下载）")
        return true
    }

    /// 把一个现成的 DEB 放进仓库并写元数据
    private static func store(source: String, action: BackupAction) -> Bool {
        let fm = FileManager.default
        let dir = DKPaths.archiveDir + "/" + action.package
        let dest = dir + "/" + dkDebFileName(package: action.package, version: action.version,
                                            arch: action.architecture)
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest) {
                // 硬链接：APT 之后清掉缓存也不影响仓库里的副本
                do { try fm.linkItem(atPath: source, toPath: dest) }
                catch { try fm.copyItem(atPath: source, toPath: dest) }
            }
            let entry = RepoIndex.shared.entry(package: action.package, version: action.version)
            let size = ((try? fm.attributesOfItem(atPath: dest))?[.size] as? NSNumber)?.int64Value ?? 0
            let meta = ArchiveMeta(package: action.package, version: action.version,
                                   architecture: action.architecture, name: entry?.name,
                                   origin: action.isPrevious ? "apt-cache" : "install",
                                   repo: entry?.baseURL, downloadURL: entry?.downloadURL?.absoluteString,
                                   // 缓存文件没有本地测得的哈希，留给 rebuildLocalIndex 按实际文件补
                                   sha256: nil, verified: false,
                                   savedAt: Date().timeIntervalSince1970, note: nil)
            ArchiveItem(debPath: dest, meta: meta, size: size).saveMeta()
            log("已保存 \(action.package) \(action.version)（下载时留存）")
            return true
        } catch {
            log("保存失败 \(action.package) \(action.version)：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 基线

    enum Snapshot {
        static func load() -> [String: InstalledVersion] {
            guard let data = FileManager.default.contents(atPath: DKPaths.installedSnapshot),
                  let decoded = try? JSONDecoder().decode([String: InstalledVersion].self, from: data)
            else { return [:] }
            return decoded
        }

        static func save(_ installed: [String: InstalledVersion]) {
            guard let data = try? JSONEncoder().encode(installed) else { return }
            try? data.write(to: URL(fileURLWithPath: DKPaths.installedSnapshot), options: .atomic)
        }
    }

    // MARK: - 日志

    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let data = (formatter.string(from: Date()) + " " + message + "\n").data(using: .utf8) else { return }
        let path = DKPaths.backupLog
        // 日志只用于用户排查，别在数据目录里无限增长
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue > 65536,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let tail = text.split(separator: "\n").suffix(200).joined(separator: "\n") + "\n"
            try? tail.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

/// 在 Sileo 进程里盯住 APT 缓存目录。
///
/// Sileo 的流程是：自己下载 DEB、校验后挪进 APT 缓存 → 调用 APT 安装 → 装完立刻 apt-get clean。
/// 从 DEB 落进缓存到被清掉之间，把它硬链接（不行就复制）到 Doleo 的留存目录。
/// 不碰 APT、不需要 root、不在安装流程里等待任何东西，失败只影响备份本身。
enum DKCapture {

    // userInitiated：缓存里的 DEB 随时可能被 apt-get clean 清掉，留存要尽快跑
    private static let queue = DispatchQueue(label: "im.mjh.doleo.capture", qos: .userInitiated)
    private static var source: DispatchSourceFileSystemObject?

    static func start() {
        queue.async {
            guard source == nil else { return }
            let fd = open(DKPaths.aptCacheDir, O_EVTONLY)
            guard fd >= 0 else {
                DKBackup.log("无法监听 APT 缓存目录 \(DKPaths.aptCacheDir)")
                return
            }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                    eventMask: [.write, .extend, .rename, .link],
                                                                    queue: queue)
            // 收到目录事件立即扫描，不做合并延迟：扫描只是列目录、跳过已留存的文件，开销很小，
            // 而任何等待都可能错过 Sileo 装完后的 apt-get clean
            watcher.setEventHandler { scan() }
            watcher.setCancelHandler { close(fd) }
            source = watcher
            watcher.resume()
            scan()
        }
    }

    /// 同步扫一遍（补存前调用，确保最新下载的 DEB 已经留存）
    static func scanNow() {
        queue.sync { scan() }
    }

    /// 把缓存里的每个 DEB 链接进 captured/<包名>/，已经有了就跳过
    private static func scan() {
        let settings = DKSettings.current
        guard settings.autoBackup || settings.installBackup, DKPaths.isDataDirWritable else { return }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: DKPaths.aptCacheDir)) ?? []
        for fileName in names {
            guard let deb = CachedDebName(fileName: fileName) else { continue }
            let cachePath = DKPaths.aptCacheDir + "/" + fileName
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: cachePath, isDirectory: &isDir), !isDir.boolValue else { continue }
            let dir = DKPaths.capturedDir + "/" + deb.package
            let dest = dir + "/" + fileName
            guard !fm.fileExists(atPath: dest) else { continue }
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                do { try fm.linkItem(atPath: cachePath, toPath: dest) }
                catch { try fm.copyItem(atPath: cachePath, toPath: dest) }
            } catch {
                // 缓存可能正好被 apt-get clean 清掉，下次装完的比对会改从软件源下载
                DKBackup.log("留存失败 \(deb.package) \(deb.version)：\(error.localizedDescription)")
            }
        }
    }

    /// 在留存目录和 APT 缓存里找指定版本的原始 DEB，留存目录优先
    static func localDeb(package: String, version: String) -> String? {
        let fm = FileManager.default
        for dir in [DKPaths.capturedDir + "/" + package, DKPaths.aptCacheDir] {
            let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            for fileName in names {
                guard let deb = CachedDebName(fileName: fileName),
                      deb.package == package, deb.version == version else { continue }
                return dir + "/" + fileName
            }
        }
        return nil
    }

    /// 按 CapturePolicy 清理留存目录；keep 里的包这次补存失败，先不动。
    /// 和留存在同一个队列上执行，避免一边建目录一边删目录
    static func prune(installed: [String: InstalledVersion], keep: Set<String>, removeAll: Bool = false) {
        queue.sync { pruneLocked(installed: installed, keep: keep, removeAll: removeAll) }
    }

    private static func pruneLocked(installed: [String: InstalledVersion], keep: Set<String>, removeAll: Bool) {
        let fm = FileManager.default
        let root = DKPaths.capturedDir
        let now = Date()
        for package in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !keep.contains(package) {
            let dir = root + "/" + package
            if removeAll {
                try? fm.removeItem(atPath: dir)
                continue
            }
            // 用包目录的修改时间代表"最近一次留存"：硬链接和缓存文件共用 inode，
            // 文件自己的修改时间往往是服务器上的时间，不能说明它是什么时候下载的
            let lastCapture = ((try? fm.attributesOfItem(atPath: dir))?[.modificationDate] as? Date) ?? now
            let age = now.timeIntervalSince(lastCapture)
            for fileName in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + fileName
                guard let deb = CachedDebName(fileName: fileName) else {
                    try? fm.removeItem(atPath: path)
                    continue
                }
                if CapturePolicy.shouldPrune(version: deb.version,
                                             installedVersion: installed[package]?.version,
                                             age: age) {
                    try? fm.removeItem(atPath: path)
                }
            }
            if ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).isEmpty {
                try? fm.removeItem(atPath: dir)
            }
        }
    }
}

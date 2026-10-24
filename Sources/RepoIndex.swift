import Foundation

/// 软件源索引中的一个包版本
struct RepoEntry {
    let stanza: ControlStanza
    /// 源的基础地址（Sileo 用 rawURL + Filename 拼下载地址，这里保持一致）
    let baseURL: String
    let listFile: String

    var package: String { stanza["Package"] ?? "" }
    var version: String { stanza["Version"] ?? "" }
    var architecture: String { stanza["Architecture"] ?? "" }
    var name: String { stanza["Name"] ?? package }
    var sha256: String? { stanza["SHA256"]?.lowercased() }
    var size: Int64? { stanza["Size"].flatMap { Int64($0) } }
    var filename: String? { stanza["Filename"] }

    /// 付费包：下载前向商店验证购买状态并申请授权
    var isCommercial: Bool {
        (stanza["Tag"] ?? "").contains("cydia::commercial")
    }

    var downloadURL: URL? {
        guard var file = filename, !file.isEmpty else { return nil }
        if file.hasPrefix("http://") || file.hasPrefix("https://") { return URL(string: file) }
        while file.hasPrefix("./") { file.removeFirst(2) }
        while file.hasPrefix("/") { file.removeFirst() }
        var base = baseURL
        if !base.hasSuffix("/") { base += "/" }
        // 保留已有的 %xx 转义，只编码空格等非法字符
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert("%")
        let encoded = file.addingPercentEncoding(withAllowedCharacters: allowed) ?? file
        return URL(string: base + encoded)
    }

    var repoHost: String {
        URL(string: baseURL)?.host ?? baseURL
    }

    func isOtherSource(than source: String?) -> Bool {
        guard let source = source, !source.isEmpty else { return false }
        let slash = CharacterSet(charactersIn: "/")
        return baseURL.trimmingCharacters(in: slash) != source.trimmingCharacters(in: slash)
    }

    var dependencyGroups: [[String]] {
        DependsParser.groups(stanza["Pre-Depends"]) + DependsParser.groups(stanza["Depends"])
    }
}

/// 读取 APT 本地索引（Sileo 把各源的 Packages 缓存在 <jbroot>/var/lib/apt/lists）
final class RepoIndex {

    static let shared = RepoIndex()

    private struct ListFile {
        let path: String
        let baseURL: String
        let data: Data
    }

    private var lists: [ListFile]?
    private var listsStamp: Date?
    private var cache = [String: [RepoEntry]]()
    private let lock = NSLock()

    /// 某个包在所有源中的全部版本（只含当前架构和 all），按版本从新到旧排序
    func entries(for package: String) -> [RepoEntry] {
        lock.lock(); defer { lock.unlock() }
        reloadIfNeeded()
        if let hit = cache[package] { return hit }
        var result = [RepoEntry]()
        var seen = Set<String>()
        for list in lists ?? [] {
            for raw in StanzaSearch.stanzas(in: list.data, package: package) {
                let entry = RepoEntry(stanza: ControlStanza(raw: raw), baseURL: list.baseURL, listFile: list.path)
                let arch = entry.architecture
                guard arch == DKPaths.debArch || arch == "all"
                    || (DKPaths.scheme == .roothide && arch == "iphoneos-arm64") else { continue }
                // 同一版本可能出现在多个源，保留第一个
                let key = entry.version + "|" + entry.baseURL + "|" + arch
                if seen.insert(key).inserted { result.append(entry) }
            }
        }
        result.sort { DebVersion.isNewer($0.version, than: $1.version) }
        cache[package] = result
        return result
    }

    func entry(package: String, version: String) -> RepoEntry? {
        entries(for: package).first { $0.version == version }
    }

    func isAvailable(package: String, version: String) -> Bool {
        entry(package: package, version: version) != nil
    }

    func invalidate() {
        lock.lock(); lists = nil; cache.removeAll(); lock.unlock()
    }

    // MARK: - 加载

    private func reloadIfNeeded() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: DKPaths.aptLists))?[.modificationDate] as? Date
        if lists != nil && stamp == listsStamp { return }
        listsStamp = stamp
        cache.removeAll()

        let bases = SourcesParser.repoBaseURLs()
        var loaded = [ListFile]()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: DKPaths.aptLists)) ?? []
        for name in names where name.hasSuffix("_Packages") {
            guard let base = SourcesParser.baseURL(forListFile: name, candidates: bases) else { continue }
            let path = DKPaths.aptLists + "/" + name
            // 内存映射，避免一次性读入几十 MB
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { continue }
            loaded.append(ListFile(path: path, baseURL: base, data: data))
        }
        lists = loaded
    }
}

/// 解析 sources.list.d，得到每个源的 rawURL，并按 APT/Sileo 的缓存文件命名规则反查
enum SourcesParser {

    static func repoBaseURLs() -> [String] {
        var urls = [String]()
        let dir = DKPaths.sourcesDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files where file.hasSuffix(".sources") || file.hasSuffix(".list") {
            guard let text = try? String(contentsOfFile: dir + "/" + file, encoding: .utf8) else { continue }
            urls += self.urls(in: text)
        }
        return urls
    }

    static func urls(in text: String) -> [String] {
        var urls = [String]()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("uris:") {
                urls += trimmed.dropFirst(5).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            } else {
                var parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard parts.first == "deb" else { continue }
                parts.removeFirst()
                if parts.first?.hasPrefix("[") == true {
                    while let p = parts.first, !p.contains("]") { parts.removeFirst() }
                    if !parts.isEmpty { parts.removeFirst() }
                }
                if let uri = parts.first { urls.append(uri) }
            }
        }
        return urls.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    /// 缓存文件名形如 repo.example.com_._Packages 或
    /// apt.procurs.us_dists_1900_main_binary-iphoneos-arm64_Packages。
    /// 取"去掉协议、/ 换成 _"后能作为前缀匹配上的最长 rawURL。
    static func baseURL(forListFile name: String, candidates: [String]) -> String? {
        var best: (String, Int)?
        for url in candidates {
            var key = url
            for scheme in ["https://", "http://"] where key.hasPrefix(scheme) {
                key.removeFirst(scheme.count)
            }
            key = key.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: "_")
            if name.hasPrefix(key), key.count > (best?.1 ?? 0) {
                best = (url, key.count)
            }
        }
        return best?.0
    }
}

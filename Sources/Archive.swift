import Foundation
import CommonCrypto

// MARK: - 设置

struct DKSettings: Codable {
    /// 升级后补存被替换掉的旧版本
    var autoBackup = false
    /// 安装/升级完成后补存本次装上的 DEB
    var installBackup = false
    /// "仅下载"时默认一并下载依赖
    var includeDependencies = false
    /// 每个包最多保留的版本数，0 表示不限。已下架的版本永远不会被自动清理
    var keepVersions = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case autoBackup, installBackup, includeDependencies, keepVersions
    }

    /// 逐个字段解码，缺的字段用默认值。
    /// 自动生成的解码遇到缺失的键会整份失败：1.0.x 的 settings.json 没有 installBackup，
    /// 升级后会把"包含依赖""保留版本数"等用户设置全部重置成默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoBackup = (try? c.decodeIfPresent(Bool.self, forKey: .autoBackup)) ?? false
        installBackup = (try? c.decodeIfPresent(Bool.self, forKey: .installBackup)) ?? false
        includeDependencies = (try? c.decodeIfPresent(Bool.self, forKey: .includeDependencies)) ?? false
        keepVersions = (try? c.decodeIfPresent(Int.self, forKey: .keepVersions)) ?? 0
    }

    static var current: DKSettings {
        get {
            guard let data = FileManager.default.contents(atPath: DKPaths.settingsFile),
                  let s = try? JSONDecoder().decode(DKSettings.self, from: data) else { return DKSettings() }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                FileManager.default.createFile(atPath: DKPaths.settingsFile, contents: data)
            }
        }
    }

    /// 1.0.x 把开关写成标记文件交给 APT 钩子；换成新机制时把用户已保存的选择搬过来。
    /// 只在第一次运行做一次，之后删掉旧标记。
    static func migrateLegacyOnce() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: DKPaths.legacyMigratedFlag) else { return }
        let hasSettings = fm.fileExists(atPath: DKPaths.settingsFile)
        let hasInstallFlag = fm.fileExists(atPath: DKPaths.legacyInstallBackupFlag)
        var settings = current
        if hasSettings || hasInstallFlag {
            if hasInstallFlag { settings.installBackup = true }
            // 1.0.x 默认会建这个"关闭"标记，没有它就说明用户当年打开过开关
            if !fm.fileExists(atPath: DKPaths.legacyAutoBackupOffFlag) { settings.autoBackup = true }
            current = settings
        }
        for path in [DKPaths.legacyInstallBackupFlag, DKPaths.legacyAutoBackupOffFlag] {
            try? fm.removeItem(atPath: path)
        }
        fm.createFile(atPath: DKPaths.legacyMigratedFlag, contents: Data())
    }
}

// MARK: - 仓库条目

/// 与 deb 同名的 .json 元数据（APT 钩子也会写入同样的格式）
struct ArchiveMeta: Codable {
    var package: String
    var version: String
    var architecture: String
    var name: String?
    /// download：手动下载；apt-cache：从 APT 缓存保存；rebuilt：根据已安装文件重新打包；install：待安装的原始 DEB；manual：用户自行放入
    var origin: String
    var repo: String?
    var downloadURL: String?
    var sha256: String?
    var verified: Bool?
    var savedAt: Double
    var note: String?
}

final class ArchiveItem {
    let debPath: String
    var meta: ArchiveMeta
    let size: Int64

    init(debPath: String, meta: ArchiveMeta, size: Int64) {
        self.debPath = debPath
        self.meta = meta
        self.size = size
    }

    var basePath: String { String(debPath.dropLast(4)) }
    var metaPath: String { basePath + ".json" }
    var controlPath: String { basePath + ".control" }
    var fileName: String { (debPath as NSString).lastPathComponent }

    lazy var control: ControlStanza? = {
        guard let text = try? String(contentsOfFile: controlPath, encoding: .utf8) else { return nil }
        return ControlStanza(raw: text)
    }()

    var originText: String {
        switch meta.origin {
        case "download": return DKL("手动下载")
        case "install": return DKL("安装时备份")
        case "apt-cache": return DKL("升级前备份")
        case "upgrade": return DKL("升级前备份（源下载）")
        case "rebuilt": return DKL("升级前备份（重新打包）")
        default: return DKL("外部文件")
        }
    }

    func saveMeta() {
        if let data = try? JSONEncoder.dk.encode(meta) {
            FileManager.default.createFile(atPath: metaPath, contents: data)
        }
    }
}

struct ArchivePackage {
    let package: String
    let items: [ArchiveItem]
    var name: String { items.first?.meta.name ?? package }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var sourceSubtitle: String? {
        let urls = Set(items.compactMap { $0.meta.repo?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }).sorted()
        return urls.isEmpty ? nil : DKL("下载自：") + urls.joined(separator: "、")
    }
}

enum DKError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

// MARK: - 仓库

enum ArchiveStore {

    static func scan() -> [ArchivePackage] {
        let fm = FileManager.default
        let root = DKPaths.archiveDir
        let dirs = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        var result = [ArchivePackage]()
        for dir in dirs where !dir.hasPrefix(".") {
            let items = loadItems(in: root + "/" + dir)
            if !items.isEmpty { result.append(ArchivePackage(package: dir, items: items)) }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func items(for package: String) -> [ArchiveItem] {
        loadItems(in: DKPaths.archiveDir + "/" + package)
    }

    static func contains(package: String, version: String, architecture: String) -> Bool {
        items(for: package).contains { $0.meta.version == version && $0.meta.architecture == architecture }
    }

    private static func loadItems(in dir: String) -> [ArchiveItem] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        var items = [ArchiveItem]()
        for file in files where file.hasSuffix(".deb") {
            let path = dir + "/" + file
            let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            let metaPath = String(path.dropLast(4)) + ".json"
            var meta: ArchiveMeta
            if let data = fm.contents(atPath: metaPath), let m = try? JSONDecoder().decode(ArchiveMeta.self, from: data) {
                meta = m
            } else {
                meta = metaFromFileName(file, package: (dir as NSString).lastPathComponent, path: path)
            }
            items.append(ArchiveItem(debPath: path, meta: meta, size: size))
        }
        return items.sorted { DebVersion.isNewer($0.meta.version, than: $1.meta.version) }
    }

    /// 没有元数据的 deb（用户自己放进来的），按 APT 文件名规则推断
    private static func metaFromFileName(_ file: String, package: String, path: String) -> ArchiveMeta {
        let parts = file.dropLast(4).split(separator: "_").map(String.init)
        let version = parts.count >= 3 ? parts[1].replacingOccurrences(of: "%3a", with: ":") : "?"
        let arch = parts.count >= 3 ? parts[2] : DKPaths.debArch
        let date = ((try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date) ?? Date()
        return ArchiveMeta(package: package, version: version, architecture: arch, name: nil, origin: "manual",
                           repo: nil, downloadURL: nil, sha256: nil, verified: nil,
                           savedAt: date.timeIntervalSince1970, note: nil)
    }

    /// 把下载完成并校验过的临时文件存入仓库
    @discardableResult
    static func save(tempFile: URL, entry: RepoEntry, verified: Bool, sha256: String,
                     origin: String = "download") throws -> ArchiveItem {
        let fm = FileManager.default
        let dir = DKPaths.archiveDir + "/" + entry.package
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let arch = entry.architecture.isEmpty ? DKPaths.debArch : entry.architecture
        let dest = dir + "/" + dkDebFileName(package: entry.package, version: entry.version, arch: arch)
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.moveItem(at: tempFile, to: URL(fileURLWithPath: dest))

        let size = ((try? fm.attributesOfItem(atPath: dest))?[.size] as? NSNumber)?.int64Value ?? 0
        let meta = ArchiveMeta(package: entry.package, version: entry.version, architecture: arch,
                               name: entry.stanza["Name"], origin: origin, repo: entry.baseURL,
                               downloadURL: entry.downloadURL?.absoluteString, sha256: sha256,
                               verified: verified, savedAt: Date().timeIntervalSince1970, note: nil)
        let item = ArchiveItem(debPath: dest, meta: meta, size: size)
        item.saveMeta()
        try? entry.stanza.raw.write(toFile: item.controlPath, atomically: true, encoding: .utf8)
        return item
    }

    static func delete(_ item: ArchiveItem) {
        let fm = FileManager.default
        for path in [item.debPath, item.metaPath, item.controlPath] {
            try? fm.removeItem(atPath: path)
        }
        let dir = (item.debPath as NSString).deletingLastPathComponent
        if ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).isEmpty {
            try? fm.removeItem(atPath: dir)
        }
    }

    /// 按"保留版本数"清理。已下架（源里已经找不到）的版本最珍贵，不自动删除
    static func applyRetention(package: String) {
        let keep = DKSettings.current.keepVersions
        guard keep > 0 else { return }
        let items = items(for: package)
        guard items.count > keep else { return }
        for item in items.dropFirst(keep)
        where RepoIndex.shared.isAvailable(package: item.meta.package, version: item.meta.version) {
            delete(item)
        }
    }

    static var totalSize: Int64 {
        scan().reduce(0) { $0 + $1.totalSize }
    }

    // MARK: - 安装

    /// Sileo 安装本地 deb 时会把文件"移动"到 APT 缓存目录，
    /// 所以先复制一份临时文件交给它，保证仓库本身不被拿走。
    static func prepareForInstall(_ item: ArchiveItem) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(atPath: DKPaths.tmpDir, withIntermediateDirectories: true)
        let dest = DKPaths.tmpDir + "/" + item.fileName
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.copyItem(atPath: item.debPath, toPath: dest)
        return URL(fileURLWithPath: dest)
    }

    static func cleanTmp() {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: DKPaths.tmpDir)) ?? [] {
            try? fm.removeItem(atPath: DKPaths.tmpDir + "/" + file)
        }
    }

    // MARK: - 本地软件源索引

    /// 在仓库目录生成 Packages 和 Release，使整个仓库目录成为一个平铺（flat）软件源，
    /// 可通过 file:// 地址添加给 APT。
    static func rebuildLocalIndex() throws {
        var stanzas = [String]()
        let stripped: Set<String> = ["Filename", "Size", "MD5sum", "SHA1", "SHA256", "SHA512", "Status", "Config-Version", "Conffiles"]
        for pkg in scan() {
            for item in pkg.items {
                if item.meta.sha256 == nil || item.meta.sha256?.isEmpty == true {
                    item.meta.sha256 = sha256(ofFile: item.debPath)
                    item.saveMeta()
                }
                var body: String
                if let control = item.control {
                    body = control.rawRemoving(stripped)
                } else {
                    body = "Package: \(item.meta.package)\nVersion: \(item.meta.version)\nArchitecture: \(item.meta.architecture)"
                }
                body += "\nFilename: ./\(pkg.package)/\(item.fileName)"
                body += "\nSize: \(item.size)"
                if let sum = item.meta.sha256, !sum.isEmpty { body += "\nSHA256: \(sum)" }
                stanzas.append(body)
            }
        }
        let packages = stanzas.joined(separator: "\n\n") + (stanzas.isEmpty ? "" : "\n")
        try packages.write(toFile: DKPaths.archiveDir + "/Packages", atomically: true, encoding: .utf8)

        let release = """
        Origin: Doleo
        Label: Doleo Local Repository
        Suite: ./
        Version: 1.0
        Architectures: \(DKPaths.debArch) all
        Description: Doleo local repository

        """
        try release.write(toFile: DKPaths.archiveDir + "/Release", atomically: true, encoding: .utf8)
    }

    /// 给 APT 用的本地源条目（roothide 下路径会去掉 jbroot 前缀）
    static var localSourceLine: String {
        "deb [trusted=yes] file://\(DKPaths.aptVisible(DKPaths.archiveDir))/ ./"
    }
}

// MARK: - 工具

func sha256(ofFile path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }
    var ctx = CC_SHA256_CTX()
    CC_SHA256_Init(&ctx)
    while true {
        let chunk = handle.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        chunk.withUnsafeBytes { ptr in
            _ = CC_SHA256_Update(&ctx, ptr.baseAddress, CC_LONG(chunk.count))
        }
    }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &ctx)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func dkFormatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

extension JSONEncoder {
    static var dk: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

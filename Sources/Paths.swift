import Foundation
import Darwin

/// 越狱环境类型
enum DKScheme: String {
    case rootful, rootless, roothide
}

/// 统一管理所有路径。
/// 原则：所有文件都放在越狱根目录（jbroot）之内，不污染原生文件系统。
enum DKPaths {

    /// 越狱根目录的真实路径。rootful 为 ""，rootless 通常为 /var/jb，roothide 为随机路径。
    static let jbroot: String = detectJBRoot()

    static let scheme: DKScheme = {
        let root = DKPaths.jbroot
        if root.isEmpty { return .rootful }
        if root == "/var/jb" { return .rootless }
        if FileManager.default.fileExists(atPath: "/var/jb"),
           DKPaths.resolve(root) == DKPaths.resolve("/var/jb") {
            return .rootless
        }
        return .roothide
    }()

    /// 把"rootful 风格"的路径转换成真实路径，例如 /var/lib/xx -> <jbroot>/var/lib/xx
    static func rooted(_ path: String) -> String {
        jbroot + path
    }

    /// apt / dpkg 看到的路径。roothide 下 bootstrap 程序通过 vroot 把 jbroot 映射成 "/"，
    /// 所以给 apt 用的路径要去掉 jbroot 前缀。
    static func aptVisible(_ realPath: String) -> String {
        switch scheme {
        case .roothide:
            if realPath.hasPrefix(jbroot) { return String(realPath.dropFirst(jbroot.count)) }
            return realPath
        case .rootless:
            // Sileo 的 bundle 路径可能是 /private/preboot/.../procursus 这种解析后的真实路径，统一还原成 /var/jb
            if realPath.hasPrefix(jbroot) && jbroot != "/var/jb" {
                return "/var/jb" + String(realPath.dropFirst(jbroot.count))
            }
            return realPath
        case .rootful:
            return realPath
        }
    }

    // MARK: - 本 tweak 的数据目录（由 postinst 创建并 chown 给 mobile）

    static func fileManagerURL(scheme: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "view"
        components.path = path
        return components.url
    }

    static var dataDir: String { rooted("/var/lib/doleo") }
    static var archiveDir: String { dataDir + "/archive" }
    static var tmpDir: String { dataDir + "/tmp" }
    static var settingsFile: String { dataDir + "/settings.json" }
    /// 上一次看到的已安装版本，用于识别"刚装完/刚升级完"
    static var installedSnapshot: String { dataDir + "/installed.json" }
    /// Sileo 下载后、apt-get clean 之前从 APT 缓存链接过来的原始 DEB，按包名分子目录
    static var capturedDir: String { dataDir + "/captured" }
    static var backupLog: String { dataDir + "/backup.log" }
    /// 1.0.x 的 APT 钩子开关文件，只在迁移旧设置时读取
    static var legacyAutoBackupOffFlag: String { dataDir + "/autobackup.off" }
    static var legacyInstallBackupFlag: String { dataDir + "/installbackup.on" }
    static var legacyMigratedFlag: String { dataDir + "/.legacy-imported" }

    // MARK: - 系统 / APT 路径

    static var aptLists: String { rooted("/var/lib/apt/lists") }
    /// APT 下载好的 DEB 落在这里；备份优先从这里链接原始文件
    static var aptCacheDir: String { rooted("/var/cache/apt/archives") }
    static var sourcesDir: String { rooted("/etc/apt/sources.list.d") }
    static var dpkgStatus: String { rooted("/var/lib/dpkg/status") }

    /// 当前环境的 deb 架构
    static let debArch: String = {
        // 优先读取本 tweak 自己在 dpkg 中登记的架构，最准确
        if let arch = DpkgStatus.field("Architecture", of: DKPaths.scheme == .roothide ? "im.mjh.doleo.roothide" : "im.mjh.doleo"), arch != "all" {
            return arch
        }
        switch DKPaths.scheme {
        case .rootful: return "iphoneos-arm"
        case .rootless: return "iphoneos-arm64"
        case .roothide: return "iphoneos-arm64e"
        }
    }()

    static var isDataDirWritable: Bool {
        FileManager.default.isWritableFile(atPath: archiveDir)
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [archiveDir, tmpDir, capturedDir] where !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - 探测

    private static func resolve(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    private static func looksLikeJBRoot(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: root + "/var/lib/dpkg/status")
    }

    private static func detectJBRoot() -> String {
        // 1. 由 Sileo 自身的安装位置推导：<jbroot>/Applications/Sileo.app
        //    同时适用于 rootful / rootless / roothide
        let bundlePath = Bundle.main.bundlePath
        if let range = bundlePath.range(of: "/Applications/", options: .backwards) {
            let root = String(bundlePath[..<range.lowerBound])
            if looksLikeJBRoot(root) { return root }
        }

        // 2. roothide：libroothide 导出的 jbroot()
        typealias JBRootFn = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "jbroot") { // RTLD_DEFAULT
            let fn = unsafeBitCast(sym, to: JBRootFn.self)
            if let c = fn("/") {
                var root = String(cString: c)
                while root.hasSuffix("/") { root.removeLast() }
                if looksLikeJBRoot(root) { return root }
            }
        }

        // 3. rootless 固定路径
        if looksLikeJBRoot("/var/jb") { return "/var/jb" }

        // 4. rootful
        return ""
    }
}

/// 读取 dpkg 状态数据库（只读，mobile 用户可读）
enum DpkgStatus {

    struct Installed {
        let package: String
        let version: String
        let architecture: String
        let isHeld: Bool
    }

    private static func loadStanza(of package: String) -> String? {
        guard let data = FileManager.default.contents(atPath: DKPaths.dpkgStatus) else { return nil }
        return StanzaSearch.firstStanza(in: data, package: package)
    }

    static func field(_ name: String, of package: String) -> String? {
        guard let stanza = loadStanza(of: package) else { return nil }
        return ControlStanza(raw: stanza)[name]
    }

    /// 已安装（或锁定）的版本；未安装返回 nil
    static func installed(_ package: String) -> Installed? {
        guard let raw = loadStanza(of: package) else { return nil }
        let st = ControlStanza(raw: raw)
        guard let status = st["Status"], let version = st["Version"] else { return nil }
        let words = status.split(separator: " ")
        guard words.count == 3, words[2] == "installed" else { return nil }
        return Installed(package: package, version: version,
                         architecture: st["Architecture"] ?? DKPaths.debArch,
                         isHeld: words[0] == "hold")
    }

    /// 状态库里所有已安装的包（备份时用来识别版本变化）
    static func all() -> [String: Installed] {
        guard let data = FileManager.default.contents(atPath: DKPaths.dpkgStatus),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var result = [String: Installed]()
        for raw in text.components(separatedBy: "\n\n") where !raw.isEmpty {
            let st = ControlStanza(raw: raw)
            guard let package = st["Package"], let version = st["Version"],
                  let status = st["Status"] else { continue }
            let words = status.split(separator: " ")
            guard words.count == 3, words[2] == "installed" else { continue }
            result[package] = Installed(package: package, version: version,
                                        architecture: st["Architecture"] ?? DKPaths.debArch,
                                        isHeld: words[0] == "hold")
        }
        return result
    }
}

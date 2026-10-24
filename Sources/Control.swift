import Foundation

/// 一段 deb 控制信息（Packages 索引 / dpkg status / control 文件中的一个段落）
struct ControlStanza {
    let raw: String
    /// 字段名统一转小写
    let fields: [String: String]
    /// 保留原始顺序，用于重新输出
    let orderedKeys: [String]

    init(raw: String) {
        self.raw = raw
        var fields = [String: String]()
        var order = [String]()
        var currentKey: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                // 续行
                if let key = currentKey {
                    fields[key, default: ""] += "\n" + line
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { order.append(key) }
            fields[key] = value
            currentKey = key
        }
        self.fields = fields
        self.orderedKeys = order
    }

    subscript(_ key: String) -> String? {
        fields[key.lowercased()]
    }

    /// 输出时去掉指定字段（连同续行），用于生成本地源索引
    func rawRemoving(_ keys: Set<String>) -> String {
        let lowered = Set(keys.map { $0.lowercased() })
        var out = [Substring]()
        var skipping = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                if !skipping { out.append(line) }
                continue
            }
            let key = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            skipping = lowered.contains(key)
            if !skipping { out.append(line) }
        }
        return out.joined(separator: "\n")
    }
}

/// 在大文件里按字节快速定位某个包的段落，避免把整个 Packages 索引解析成字符串
enum StanzaSearch {

    private static let doubleNewline = Data("\n\n".utf8)

    /// 返回 data 中所有 `Package: <name>` 段落的原文
    static func stanzas(in data: Data, package: String) -> [String] {
        let needle = Data("Package: \(package)\n".utf8)
        var results = [String]()
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let hit = data.range(of: needle, options: [], in: searchStart..<data.endIndex) {
            searchStart = hit.upperBound
            // 必须位于行首
            if hit.lowerBound != data.startIndex && data[hit.lowerBound - 1] != UInt8(ascii: "\n") {
                continue
            }
            let start: Data.Index
            if let prev = data.range(of: doubleNewline, options: .backwards, in: data.startIndex..<hit.lowerBound) {
                start = prev.upperBound
            } else {
                start = data.startIndex
            }
            let end = data.range(of: doubleNewline, options: [], in: hit.lowerBound..<data.endIndex)?.lowerBound ?? data.endIndex
            if let text = String(data: data[start..<end], encoding: .utf8) {
                results.append(text)
            }
            searchStart = end
        }
        return results
    }

    static func firstStanza(in data: Data, package: String) -> String? {
        stanzas(in: data, package: package).first
    }
}

/// Debian 版本号比较（epoch:upstream-revision，支持 ~ 规则）
enum DebVersion {

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (ea, ua, ra) = split(a)
        let (eb, ub, rb) = split(b)
        if ea != eb { return ea < eb ? .orderedAscending : .orderedDescending }
        let u = compareFragment(ua, ub)
        if u != .orderedSame { return u }
        return compareFragment(ra, rb)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        compare(a, b) == .orderedDescending
    }

    private static func split(_ v: String) -> (Int, String, String) {
        var rest = Substring(v)
        var epoch = 0
        if let colon = rest.firstIndex(of: ":") {
            epoch = Int(rest[..<colon]) ?? 0
            rest = rest[rest.index(after: colon)...]
        }
        var revision = Substring("")
        if let dash = rest.lastIndex(of: "-") {
            revision = rest[rest.index(after: dash)...]
            rest = rest[..<dash]
        }
        return (epoch, String(rest), String(revision))
    }

    private static func order(_ c: Character?) -> Int {
        guard let c = c else { return 0 }
        if c == "~" { return -1 }
        if c.isLetter { return Int(c.asciiValue ?? 0) }
        return Int(c.asciiValue ?? 0) + 256
    }

    private static func compareFragment(_ a: String, _ b: String) -> ComparisonResult {
        var ia = Array(a)[...]
        var ib = Array(b)[...]
        while !ia.isEmpty || !ib.isEmpty {
            // 非数字部分
            while (!ia.isEmpty && !ia.first!.isNumber) || (!ib.isEmpty && !ib.first!.isNumber) {
                let ca = ia.first.flatMap { $0.isNumber ? nil : $0 }
                let cb = ib.first.flatMap { $0.isNumber ? nil : $0 }
                let oa = order(ca), ob = order(cb)
                if oa != ob { return oa < ob ? .orderedAscending : .orderedDescending }
                if ca != nil { ia = ia.dropFirst() }
                if cb != nil { ib = ib.dropFirst() }
            }
            // 数字部分
            var na = Substring(""), nb = Substring("")
            let da = ia.prefix { $0.isNumber }
            let db = ib.prefix { $0.isNumber }
            na = Substring(String(da)); nb = Substring(String(db))
            ia = ia.dropFirst(da.count); ib = ib.dropFirst(db.count)
            let ta = na.drop { $0 == "0" }, tb = nb.drop { $0 == "0" }
            if ta.count != tb.count { return ta.count < tb.count ? .orderedAscending : .orderedDescending }
            if ta != tb { return ta < tb ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// 解析 Depends / Pre-Depends 字段，返回每组可选依赖（"a | b" 视为一组）
enum DependsParser {
    static func groups(_ field: String?) -> [[String]] {
        guard let field = field, !field.isEmpty else { return [] }
        return field.split(separator: ",").map { group in
            group.split(separator: "|").compactMap { alt -> String? in
                var name = alt.trimmingCharacters(in: .whitespacesAndNewlines)
                if let cut = name.firstIndex(where: { $0 == " " || $0 == "(" || $0 == "[" }) {
                    name = String(name[..<cut])
                }
                if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
                return name.isEmpty ? nil : name
            }
        }.filter { !$0.isEmpty }
    }
}

/// APT 风格的 deb 文件名：<包名>_<版本(: 编码为 %3a)>_<架构>.deb
func dkDebFileName(package: String, version: String, arch: String) -> String {
    let v = version.replacingOccurrences(of: ":", with: "%3a")
    return "\(package)_\(v)_\(arch).deb"
}

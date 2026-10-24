import Foundation

private enum DKLocalization {
    static let bundle: Bundle = {
        let language = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? "zh-Hans" : "en"
        let path = DKPaths.rooted("/usr/share/doleo/Doleo.bundle") + "/" + language + ".lproj"
        return Bundle(path: path) ?? .main
    }()
}

func DKL(_ key: String, _ arguments: CVarArg...) -> String {
    let format = DKLocalization.bundle.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
}

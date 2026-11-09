import Foundation

/// The version shown in the Ustawienia footer, read from the Info.plist. Pure, so it is tested
/// without a bundle. There is no automatic update check: new versions come by hand from the
/// GitHub releases (docs/release.md).
enum AppVersion {
    /// `CFBundleVersion` as a whole number; nil for anything else.
    static func buildNumber(info: [String: Any]) -> Int? {
        guard let raw = info["CFBundleVersion"] as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(text)
    }

    /// "1.0.0 (142)", or "1.0.0" without a numeric build.
    static func versionString(info: [String: Any]) -> String {
        let version = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        guard let build = buildNumber(info: info) else { return version }
        return "\(version) (\(build))"
    }

    /// "Wersja 1.0.0 (142)": the settings footer.
    static func versionLine(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String {
        let version = versionString(info: info)
        return String(localized: "Wersja \(version)")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

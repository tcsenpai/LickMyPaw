import Foundation

/// UI strings use the English text as the key (gettext style). Translations live in Resources/<lang>.lproj/Localizable.strings.
/// Language follows macOS; override via Settings ("lang") or LICKMYPAW_LANG=it|fr|es|en.
enum L10n {
    /// SwiftPM's generated `Bundle.module` only looks next to the .app root or at the absolute build path, so a packaged app
    /// (resources in Contents/Resources) CRASHES on any machine but the one that built it. Never use `Bundle.module`; use this.
    static let resourceBundle: Bundle = {
        let name = "LickMyPaw_LickMyPaw.bundle"
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(name)) }                       // packaged .app
        if let e = Bundle.main.executableURL?.deletingLastPathComponent() { candidates.append(e.appendingPathComponent(name)) }  // swift build / .build/release
        for u in candidates { if let b = Bundle(url: u) { return b } }
        return Bundle.main   // no translations found: keys (English) are shown
    }()
    /// Pure decision: env LICKMYPAW_LANG, then UserDefaults "lang", else nil (= system). Resolved once, so changes need a restart.
    static func resolveLang(env: [String: String], defaults: UserDefaults) -> String? {
        let ok = ["en", "it", "fr", "es"]
        if let l = env["LICKMYPAW_LANG"], ok.contains(l) { return l }
        if let l = defaults.string(forKey: "lang"), ok.contains(l) { return l }
        return nil
    }
    static let bundle: Bundle = {
        if let l = resolveLang(env: ProcessInfo.processInfo.environment, defaults: .standard),
           let p = resourceBundle.path(forResource: l, ofType: "lproj"), let b = Bundle(path: p) { return b }
        return resourceBundle
    }()
}
func T(_ key: String) -> String { NSLocalizedString(key, bundle: L10n.bundle, comment: "") }
func TF(_ key: String, _ args: CVarArg...) -> String { String(format: T(key), arguments: args) }

/// Per-module string tables (Resources/<lang>.lproj/<Table>.strings) so parallel work never conflicts in Localizable.strings.
func TT(_ key: String, _ table: String) -> String { NSLocalizedString(key, tableName: table, bundle: L10n.bundle, comment: "") }
func TTF(_ key: String, _ table: String, _ args: CVarArg...) -> String { String(format: TT(key, table), arguments: args) }

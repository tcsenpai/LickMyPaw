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

extension L10n {
    /// --i18n-check: every table's key set and format specifiers (%d/%@/%lld...) must match en. Returns (tables, keys, one line per problem).
    static func parityReport() -> (Int, Int, [String]) {
        let fm = FileManager.default, root = resourceBundle.bundleURL.path, tabs = ((try? fm.contentsOfDirectory(atPath: root + "/en.lproj")) ?? []).filter { $0.hasSuffix(".strings") }.sorted()
        let spec = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[-+0# ]*\\d*(?:\\.\\d+)?(?:ll|l|h)?[@dDuUxXfegscCSpi]")
        let fs = { (s: String) -> [String] in let c = s.replacingOccurrences(of: "%%", with: ""); let m = spec.matches(in: c, range: NSRange(c.startIndex..., in: c)).map { String(c[Range($0.range, in: c)!]) }; return c.contains("$") ? m.sorted() : m }  // shortcut: positional args compared as a set
        var bad: [String] = [], n = 0
        for t in tabs {
            guard let en = NSDictionary(contentsOfFile: "\(root)/en.lproj/\(t)") as? [String: String] else { bad.append("en/\(t): unreadable"); continue }
            n += en.count
            for l in ["it", "fr", "es"] {
                guard let d = NSDictionary(contentsOfFile: "\(root)/\(l).lproj/\(t)") as? [String: String] else { bad.append("\(l)/\(t): missing or unreadable table"); continue }
                for k in Set(en.keys).subtracting(d.keys).sorted() { bad.append("\(l)/\(t): missing key \"\(k)\"") }
                for k in Set(d.keys).subtracting(en.keys).sorted() { bad.append("\(l)/\(t): extra key \"\(k)\"") }
                for (k, v) in d.sorted(by: { $0.key < $1.key }) where en[k] != nil && fs(en[k]!) != fs(v) { bad.append("\(l)/\(t): format mismatch \"\(k)\" en=\(fs(en[k]!)) \(l)=\(fs(v))") }
            }
        }
        return (tabs.count, n, bad)
    }
}

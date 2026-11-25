import Foundation

enum Prefs {
    static let languages = ["en", "it", "fr", "es"]
    /// Contract used by Safety/Scanner.
    static var exclusions: [String] { UserDefaults.standard.stringArray(forKey: "exclusions") ?? [] }

    static var languageOverride: String? {
        get { UserDefaults.standard.string(forKey: "lang").flatMap { languages.contains($0) ? $0 : nil } }
        set { if let v = newValue, languages.contains(v) { UserDefaults.standard.set(v, forKey: "lang") } else { UserDefaults.standard.removeObject(forKey: "lang") } }
    }

    /// Returns nil on success, otherwise the refusal reason.
    @discardableResult
    static func addExclusion(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "not an absolute path" }
        let p = Safety.real(path)
        guard FileManager.default.fileExists(atPath: p) else { return "folder does not exist" }
        if p == "/" || p == Safety.real(Env.home) { return "this folder cannot be excluded" }
        var l = exclusions
        if l.contains(where: { Safety.real($0) == p }) { return "already excluded" }
        l.append(p); UserDefaults.standard.set(l, forKey: "exclusions"); return nil
    }

    static func removeExclusion(_ path: String) {
        UserDefaults.standard.set(exclusions.filter { $0 != path }, forKey: "exclusions")
    }
}

enum PrefsSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let ud = UserDefaults.standard
        let savedEx = ud.object(forKey: "exclusions"), savedLang = ud.object(forKey: "lang")
        defer { // restore the real values
            if let v = savedEx { ud.set(v, forKey: "exclusions") } else { ud.removeObject(forKey: "exclusions") }
            if let v = savedLang { ud.set(v, forKey: "lang") } else { ud.removeObject(forKey: "lang") }
            unsetenv("LICKMYPAW_HOME")
        }
        ud.removeObject(forKey: "exclusions"); ud.removeObject(forKey: "lang")
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1)
        let proj = f.dir("home/proj"), file = f.file("home/proj/big.bin", kb: 4)

        t.check(Prefs.addExclusion("/") != nil && Prefs.addExclusion(f.home) != nil && Prefs.exclusions.isEmpty, "refuses / and home root"); t.reachedCode()
        t.check(Prefs.addExclusion(f.root + "/nope") != nil, "refuses nonexistent folder")
        t.check(Safety.check(file).ok, "path allowed before exclusion")
        t.check(Prefs.addExclusion(proj) == nil && Prefs.exclusions == [Safety.real(proj)], "add exclusion (realpath)"); t.reachedCode()
        t.check(Prefs.addExclusion(proj) != nil && Prefs.exclusions.count == 1, "dedupe")
        t.check(!Safety.check(file).ok, "Safety refuses path under exclusion"); t.reachedCode()
        Prefs.removeExclusion(Safety.real(proj))
        t.check(Prefs.exclusions.isEmpty && Safety.check(file).ok, "allowed again after removal")

        Prefs.languageOverride = "it"; t.check(Prefs.languageOverride == "it" && ud.string(forKey: "lang") == "it", "language override round-trip")
        Prefs.languageOverride = "xx"; t.check(Prefs.languageOverride == nil, "invalid language clears override")
        Prefs.languageOverride = "fr"
        t.check(L10n.resolveLang(env: ["LICKMYPAW_LANG": "es"], defaults: ud) == "es", "env beats defaults"); t.reachedCode()
        t.check(L10n.resolveLang(env: [:], defaults: ud) == "fr", "defaults used without env")
        t.check(L10n.resolveLang(env: ["LICKMYPAW_LANG": "zz"], defaults: ud) == "fr", "bad env ignored")
        Prefs.languageOverride = nil
        t.check(L10n.resolveLang(env: [:], defaults: ud) == nil, "system when nothing set")

        let victim = f.file("home/stuff/a.bin", kb: 8)
        let e = try? Engine.trash(victim, size: 8192)
        t.check(ActionLog.all().first?.path == victim, "history shows the entry"); t.reachedCode()
        if let e { try? Engine.undo(e) }
        t.check(FileManager.default.fileExists(atPath: victim) && ActionLog.all().first?.undone == true, "undo from history restores")
    }
}

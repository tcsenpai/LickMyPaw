import Foundation

enum SafetyMode {
    case userSelected   // the user explicitly picked this item (Prowl, Apps): only the deny-list applies
    case automatic      // LickMyPaw proposes it (Cleanup): must also live under an allow-root
}

struct SafetyVerdict { let ok: Bool; let reason: String }

/// THE single gate every delete goes through (GUI, CLI, modules). Never bypass.
enum Safety {
    static let denyExact: Set<String> = ["/", "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/Library", "/Applications",
                                         "/Users", "/Volumes", "/opt", "/cores", "/dev", "/tmp"]
    static let denyPrefix = ["/System", "/usr/bin", "/usr/sbin", "/usr/lib", "/bin", "/sbin", "/dev", "/cores", "/private/etc", "/private/var/db", "/Library/Apple", "/etc", "/var/db"]
    static let protectedHomeDirs = ["", "/Library", "/Documents", "/Desktop", "/Downloads", "/Pictures", "/Music", "/Movies", "/Public", "/Applications"]
    /// Allow-roots for .automatic mode (relative to home). Cleanup may append more (e.g. from its target list).
    nonisolated(unsafe) static var automaticRoots: [String] = [
        "/Library/Caches", "/Library/Logs", "/Library/Saved Application State", "/Library/Developer/Xcode/DerivedData",
        "/Library/Developer/CoreSimulator", "/Library/Application Support/CrashReporter", "/.npm", "/.cache", "/.bun/install/cache",
        "/.cargo/registry", "/.gradle/caches"]

    static func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
    static func under(_ p: String, _ root: String) -> Bool { p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/") }

    static func check(_ path: String, mode: SafetyMode = .userSelected) -> SafetyVerdict {
        guard !path.isEmpty, path.hasPrefix("/") else { return .init(ok: false, reason: "not an absolute path") }
        let p = real(path)
        if denyExact.contains(p) { return .init(ok: false, reason: "protected system location") }
        if let d = denyPrefix.first(where: { under(p, $0) }) { return .init(ok: false, reason: "protected system location (\(d))") }
        let home = real(Env.home)
        if protectedHomeDirs.contains(where: { p == home + $0 }) { return .init(ok: false, reason: "protected folder (remove its contents instead)") }
        if let x = Prefs.exclusions.first(where: { under(p, real($0)) }) { return .init(ok: false, reason: "excluded by you (\(x))") }
        if mode == .automatic && !automaticRoots.contains(where: { under(p, home + $0) }) {
            return .init(ok: false, reason: "outside the automatic cleanup allow-list")
        }
        return .init(ok: true, reason: "ok")
    }
}

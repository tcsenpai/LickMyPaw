import Foundation
import AppKit

enum CleanRisk: Int { case low, medium, high }

struct CleanItem: Identifiable, Hashable {
    let path: String, name: String, size: Int64, targetID: String, risk: CleanRisk
    var id: String { path }
}

/// Declarative cleanup target: every child of each root (relative to Env.home) is one candidate item.
struct CleanupTarget {
    let id: String, name: String, category: String, icon: String
    let roots: [String]
    let risk: CleanRisk
    var skipNames: Set<String> = []   // children handled by another target
    var appCaches = false             // children are named after bundle ids: apply running/fragile exclusions
    var skipWhenRunning: Set<String> = []   // offer nothing while any of these bundle ids is running
    var custom: (@Sendable (String) -> [(path: String, name: String)])? = nil   // own enumeration (home -> candidates), roots ignored
}

enum CleanupTargets {
    static let userCat = "User junk", devCat = "Developer junk"
    static let all: [CleanupTarget] = [
        .init(id: "caches", name: "User caches", category: userCat, icon: "internaldrive", roots: ["/Library/Caches"], risk: .low, skipNames: ["Homebrew", "pip"], appCaches: true),
        .init(id: "logs", name: "User logs", category: userCat, icon: "doc.text", roots: ["/Library/Logs"], risk: .low, skipNames: ["DiagnosticReports"]),
        .init(id: "crash", name: "Crash reports", category: userCat, icon: "exclamationmark.triangle", roots: ["/Library/Logs/DiagnosticReports", "/Library/Application Support/CrashReporter"], risk: .low),
        .init(id: "saved", name: "Saved application state", category: userCat, icon: "macwindow", roots: ["/Library/Saved Application State"], risk: .medium),
        .init(id: "derived", name: "Xcode DerivedData", category: devCat, icon: "hammer", roots: ["/Library/Developer/Xcode/DerivedData"], risk: .low),
        .init(id: "sim", name: "Simulator caches", category: devCat, icon: "iphone", roots: ["/Library/Developer/CoreSimulator/Caches"], risk: .low),
        .init(id: "npm", name: "npm cache", category: devCat, icon: "shippingbox", roots: ["/.npm/_cacache"], risk: .low),
        .init(id: "bun", name: "bun cache", category: devCat, icon: "shippingbox", roots: ["/.bun/install/cache"], risk: .low),
        .init(id: "cargo", name: "Cargo registry cache", category: devCat, icon: "shippingbox", roots: ["/.cargo/registry/cache"], risk: .medium),
        .init(id: "gradle", name: "Gradle caches", category: devCat, icon: "shippingbox", roots: ["/.gradle/caches"], risk: .medium),
        .init(id: "pip", name: "pip / uv cache", category: devCat, icon: "shippingbox", roots: ["/.cache/uv", "/Library/Caches/pip"], risk: .low),
        .init(id: "brew", name: "Homebrew cache", category: devCat, icon: "shippingbox", roots: ["/Library/Caches/Homebrew"], risk: .low),
    ] + CleanupExtra.targets

    /// Tests inject a fake set; production asks NSWorkspace.
    nonisolated(unsafe) static var runningIDs: () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    static let fragileWords = ["keychain", "credential", "cloudkit", "icloud", "cloudd", "safari", "com.apple.bird", "mobilesync", "accounts"]
    static let safeApple: Set<String> = ["com.apple.dt.Xcode", "com.apple.python"]

    static func fragile(_ name: String) -> Bool {
        let l = name.lowercased()
        if l.hasPrefix("com.apple.") && !safeApple.contains(where: { l == $0.lowercased() }) { return true }
        return fragileWords.contains { l.contains($0) }
    }

    static func size(_ path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR { return Int64(st.st_size) }
        return Scanner.scan(path: path, progress: Progress()).size
    }

    static func items(_ t: CleanupTarget, running: Set<String>) -> [CleanItem] {
        let home = Env.home, fm = FileManager.default
        var out: [CleanItem] = []
        if t.skipWhenRunning.contains(where: running.contains) { return [] }
        if let c = t.custom {
            for (p, n) in c(home) where !Prefs.exclusions.contains(where: { Safety.under(p, $0) }) {
                let s = size(p)
                if s > 0 { out.append(CleanItem(path: p, name: n, size: s, targetID: t.id, risk: t.risk)) }
            }
            return out
        }
        for r in t.roots {
            guard let kids = try? fm.contentsOfDirectory(atPath: home + r) else { continue }
            for k in kids.sorted() where !t.skipNames.contains(k) && !k.hasPrefix(".") {
                if t.appCaches && (fragile(k) || running.contains(where: { k == $0 || k.hasPrefix($0 + ".") })) { continue }
                let p = home + r + "/" + k
                if Prefs.exclusions.contains(where: { Safety.under(p, $0) }) { continue }
                let s = size(p)
                if s > 0 { out.append(CleanItem(path: p, name: k, size: s, targetID: t.id, risk: t.risk)) }
            }
        }
        return out
    }
}

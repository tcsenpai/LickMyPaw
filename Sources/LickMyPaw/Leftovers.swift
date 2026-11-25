import Foundation

struct Leftover: Identifiable, Hashable {
    enum Confidence: Int { case low, medium, high }
    var id: String { path }
    let path: String
    let size: Int64
    let confidence: Confidence
    let readOnly: Bool          // system-level (/Library): shown, never selectable
}

enum LeftoverMatcher {
    static let userDirs = ["Application Support", "Caches", "Preferences", "Logs", "Containers", "Group Containers",
                           "Saved Application State", "HTTPStorages", "WebKit", "LaunchAgents", "Application Scripts"]
    static let systemDirs = ["/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
    static let seps: Set<Character> = [".", "-", "_"]

    /// Name variants to compare: strips file extension, "group." and a 10-char Team ID prefix.
    static func stems(_ entry: String) -> [String] {
        var s = [entry]
        let base = (entry as NSString).deletingPathExtension
        if base != entry { s.append(base) }
        for b in s { 
            if b.hasPrefix("group.") { s.append(String(b.dropFirst(6))) }
            if let dot = b.firstIndex(of: "."), b.distance(from: b.startIndex, to: dot) == 10, b[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) {
                s.append(String(b[b.index(after: dot)...]))
            }
        }
        return s
    }

    static func confidence(entry: String, bundleID: String, name: String) -> Leftover.Confidence? {
        let st = stems(entry)
        if !bundleID.isEmpty {
            let b = bundleID.lowercased()
            for x in st.map({ $0.lowercased() }) {
                if x == b { return .high }
                if x.hasPrefix(b), let c = x.dropFirst(b.count).first, seps.contains(c) { return .high }
            }
        }
        let n = name.lowercased()
        guard !n.isEmpty else { return nil }
        if st.contains(where: { $0.lowercased() == n }) { return .medium }
        if n.count >= 4, entry.lowercased().contains(n) { return .low }
        return nil
    }

    /// Synchronous (scans sizes): call off the main thread. `home`/`systemDirs` injectable for tests.
    static func find(for app: AppInfo, home: String = Env.home, systemDirs: [String] = LeftoverMatcher.systemDirs) -> [Leftover] {
        let fm = FileManager.default
        var out: [Leftover] = []
        func scan(_ dir: String, readOnly: Bool) {
            for e in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                guard let c = confidence(entry: e, bundleID: app.bundleID, name: app.name) else { continue }
                let p = dir + "/" + e
                out.append(Leftover(path: p, size: allocSize(p), confidence: c, readOnly: readOnly))
            }
        }
        for d in userDirs { scan(home + "/Library/" + d, readOnly: false) }
        for d in systemDirs { scan(d, readOnly: true) }
        return out.sorted { ($0.confidence.rawValue, $0.size) > ($1.confidence.rawValue, $1.size) }
    }
}

protocol Launchctl {
    func bootout(plist: String) -> Result<Void, EngineError>
    func isLoaded(label: String) -> Bool
}

protocol AppTerminator {
    func isRunning(bundleID: String) -> Bool
    /// true when the app quit within the timeout
    func terminate(bundleID: String) -> Bool
}

/// Only user LaunchAgents (~/Library/LaunchAgents), as the current user, never root.
struct SystemLaunchctl: Launchctl {
    static func label(of plist: String) -> String? {
        (NSDictionary(contentsOfFile: plist)?["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    private func run(_ args: [String]) -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit(); return (p.terminationStatus, out)
    }
    func bootout(plist: String) -> Result<Void, EngineError> {
        guard geteuid() != 0 else { return .failure(EngineError(message: "Refused: running as root")) }
        guard plist.hasPrefix(Env.home + "/Library/LaunchAgents/"), !plist.contains("..") else { return .failure(EngineError(message: "Refused: not a user LaunchAgent")) }
        guard let label = Self.label(of: plist) else { return .success(()) }   // unreadable plist: nothing to unload
        let (code, out) = run(["bootout", "gui/\(getuid())/\(label)"])
        // 3 = no such process, 113 = not found: already unloaded is fine
        return code == 0 || code == 3 || code == 113 || out.contains("No such process") ? .success(()) : .failure(EngineError(message: "launchctl bootout failed (\(code)): \(out)"))
    }
    func isLoaded(label: String) -> Bool { run(["print", "gui/\(getuid())/\(label)"]).0 == 0 }
}

struct SystemAppTerminator: AppTerminator {
    func isRunning(bundleID: String) -> Bool { NSRunningApplicationLookup.running(bundleID) != nil }
    func terminate(bundleID: String) -> Bool {
        guard let r = NSRunningApplicationLookup.running(bundleID) else { return true }
        r.terminate()   // never forceTerminate
        for _ in 0..<50 where !r.isTerminated { Thread.sleep(forTimeInterval: 0.1) }
        return r.isTerminated
    }
}

enum Uninstaller {
    struct ItemResult { let path: String; let ok: Bool; let error: String? }
    nonisolated(unsafe) static var launchctl: Launchctl = SystemLaunchctl()
    nonisolated(unsafe) static var terminator: AppTerminator = SystemAppTerminator()

    struct AppResult { let app: AppInfo; let items: [ItemResult]
        var ok: Bool { !items.isEmpty && items.allSatisfy(\.ok) }
        var error: String? { items.first { !$0.ok }?.error }
    }
    /// Sequential batch; a failure (refused, won't quit, trash error) never aborts the others. `progress(i, total)` fires before app i (1-based).
    static func uninstallMany(apps: [AppInfo], leftoversFor: (AppInfo) -> [Leftover], quit: Bool = true, progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [AppResult] {
        var out: [AppResult] = []
        for (i, a) in apps.enumerated() {
            progress?(i + 1, apps.count)
            out.append(AppResult(app: a, items: await uninstall(a, leftoversFor(a), quit: quit)))
        }
        return out
    }

    /// Quits the app if running (when `quit`), boots out LaunchAgent leftovers, then trashes the bundle and the given leftovers. Never removes files directly.
    static func uninstall(_ app: AppInfo, _ leftovers: [Leftover], quit: Bool = true) async -> [ItemResult] {
        if app.isSystem { return [ItemResult(path: app.path, ok: false, error: "Refused: system app")] }
        if !app.bundleID.isEmpty, terminator.isRunning(bundleID: app.bundleID) {
            guard quit else { return [ItemResult(path: app.path, ok: false, error: "App is running")] }
            if !terminator.terminate(bundleID: app.bundleID) { return [ItemResult(path: app.path, ok: false, error: "Could not quit \(app.name)")] }
        }
        var res: [ItemResult] = []
        func go(_ p: String, _ size: Int64) {
            do { try Engine.trash(p, size: size, mode: .userSelected); res.append(.init(path: p, ok: true, error: nil)) }
            catch { res.append(.init(path: p, ok: false, error: error.localizedDescription)) }
        }
        let agents = Env.home + "/Library/LaunchAgents/"
        var failed = Set<String>()   // still loaded: don't trash their plist
        for l in leftovers where !l.readOnly && l.path.hasPrefix(agents) && l.path.hasSuffix(".plist") {
            if case .failure(let e) = launchctl.bootout(plist: l.path) { failed.insert(l.path); res.append(.init(path: l.path, ok: false, error: e.message)) }
        }
        go(app.path, app.size)
        for l in leftovers where !l.readOnly && !failed.contains(l.path) { go(l.path, l.size) }
        return res
    }
}

import AppKit
enum NSRunningApplicationLookup {
    static func running(_ bid: String) -> NSRunningApplication? {
        bid.isEmpty ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
    }
}

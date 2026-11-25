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

enum Uninstaller {
    struct ItemResult { let path: String; let ok: Bool; let error: String? }

    /// Quits the app if running (when `quit`), then trashes the bundle and the given leftovers. Never removes files directly.
    static func uninstall(_ app: AppInfo, _ leftovers: [Leftover], quit: Bool = true) async -> [ItemResult] {
        if app.isSystem { return [ItemResult(path: app.path, ok: false, error: "Refused: system app")] }
        if let r = NSRunningApplicationLookup.running(app.bundleID) {
            guard quit else { return [ItemResult(path: app.path, ok: false, error: "App is running")] }
            r.terminate()
            for _ in 0..<50 where !r.isTerminated { try? await Task.sleep(nanoseconds: 100_000_000) }
            if !r.isTerminated { return [ItemResult(path: app.path, ok: false, error: "Could not quit \(app.name)")] }
        }
        var res: [ItemResult] = []
        func go(_ p: String, _ size: Int64) {
            do { try Engine.trash(p, size: size, mode: .userSelected); res.append(.init(path: p, ok: true, error: nil)) }
            catch { res.append(.init(path: p, ok: false, error: error.localizedDescription)) }
        }
        go(app.path, app.size)
        for l in leftovers where !l.readOnly { go(l.path, l.size) }
        return res
    }
}

import AppKit
enum NSRunningApplicationLookup {
    static func running(_ bid: String) -> NSRunningApplication? {
        bid.isEmpty ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
    }
}

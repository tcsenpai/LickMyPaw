import Foundation
import AppKit

struct AppInfo: Identifiable, Hashable {
    enum Source { case appStore, other }
    var id: String { path }
    let name: String, bundleID: String, version: String, path: String
    var size: Int64
    let source: Source
    let isSystem: Bool
    var running: Bool
    var lastUsed: Date?
}

func allocSize(_ path: String) -> Int64 {
    var st = stat()
    guard lstat(path, &st) == 0 else { return 0 }
    if (st.st_mode & S_IFMT) == S_IFDIR { return Scanner.scan(path: path, progress: Progress()).size }
    return Int64(st.st_blocks) * 512
}

enum AppInventory {
    static var defaultRoots: [String] { ["/Applications", Env.home + "/Applications"] }

    /// Synchronous (sizes are scanned): call off the main thread.
    static func load(roots: [String] = defaultRoots) -> [AppInfo] {
        let fm = FileManager.default
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        var out: [AppInfo] = []
        for root in roots {
            for e in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where e.hasSuffix(".app") {
                let p = root + "/" + e
                let info = NSDictionary(contentsOfFile: p + "/Contents/Info.plist")
                let bid = info?["CFBundleIdentifier"] as? String ?? ""
                let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? String(e.dropLast(4))
                let ver = (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String) ?? ""
                let mas = fm.fileExists(atPath: p + "/Contents/_MASReceipt")
                // shortcut: com.apple.* without a MAS receipt counts as shipped-with-macOS (Xcode etc. also match), refuse rather than risk it
                let sys = Safety.real(p).hasPrefix("/System") || (bid.hasPrefix("com.apple.") && !mas)
                out.append(AppInfo(name: name, bundleID: bid, version: ver, path: p, size: allocSize(p), source: mas ? .appStore : .other,
                                   isSystem: sys, running: running.contains(bid), lastUsed: nil))
            }
        }
        return out
    }

    /// Best effort via Spotlight; nil when unknown.
    static func lastUsed(_ path: String) -> Date? {
        let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        pr.arguments = ["-raw", "-name", "kMDItemLastUsedDate", path]
        let pipe = Pipe(); pr.standardOutput = pipe; pr.standardError = FileHandle.nullDevice
        guard (try? pr.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); pr.waitUntilExit()
        guard let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), s != "(null)" else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}

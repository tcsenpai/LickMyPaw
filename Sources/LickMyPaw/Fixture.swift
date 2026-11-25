import Foundation

/// Throwaway filesystem trees for tests. Never point tests at real user data.
final class Fixture {
    let root: String
    var home: String { root + "/home" }          // use with LICKMYPAW_HOME-style injection (Env) or pass paths directly
    init() {
        root = NSTemporaryDirectory() + "lmp-fx-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    @discardableResult func dir(_ rel: String) -> String { let p = root + "/" + rel; try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true); return p }
    @discardableResult func file(_ rel: String, kb: Int = 4, daysOld: Int? = nil) -> String {
        let p = root + "/" + rel
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 0x5a, count: kb << 10))
        if let d = daysOld { try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(d) * 86400)], ofItemAtPath: p) }
        return p
    }
    @discardableResult func hardlink(_ rel: String, to target: String) -> String {
        let p = root + "/" + rel; try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        link(target, p); return p
    }
    @discardableResult func symlink(_ rel: String, to target: String) -> String {
        let p = root + "/" + rel; try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target); return p
    }
    func cleanup() { try? FileManager.default.removeItem(atPath: root) }
    deinit { cleanup() }
}

import Foundation

/// Scanner suite: hard links counted once, symlinks ignored, exclusions honored, totals match allocated sizes.
enum ScannerSelfTest {
    private static func allocated(_ p: String) -> Int64 { var st = stat(); return stat(p, &st) == 0 ? Int64(st.st_blocks) * 512 : -1 }
    @MainActor static func run(_ t: TestCtx) async {
        let saved = UserDefaults.standard.object(forKey: "exclusions")
        defer { if let s = saved { UserDefaults.standard.set(s, forKey: "exclusions") } else { UserDefaults.standard.removeObject(forKey: "exclusions") } }
        UserDefaults.standard.removeObject(forKey: "exclusions")

        // plain tree: total == sum of allocated sizes
        let a = Fixture(); defer { a.cleanup() }
        let p1 = a.file("t/a.bin", kb: 8), p2 = a.file("t/sub/b.bin", kb: 600), p3 = a.file("t/sub/c.bin", kb: 4)
        let r = Scanner.scan(path: a.root + "/t", progress: Progress()); t.reachedCode()
        t.check(r.size == allocated(p1) + allocated(p2) + allocated(p3), "plain tree total equals sum of allocated sizes (\(r.size))")

        // hard links + symlink
        let b = Fixture(); defer { b.cleanup() }
        let orig = b.file("t/orig.bin", kb: 64)
        b.hardlink("t/l1.bin", to: orig); b.hardlink("t/d/l2.bin", to: orig)
        b.symlink("t/sym.bin", to: orig)
        let one = allocated(orig)
        let rb = Scanner.scan(path: b.root + "/t", progress: Progress()); t.reachedCode()
        t.check(rb.size == one, "file + 2 hard links + symlink counted once (\(rb.size) vs \(one))")

        // exclusions
        let c = Fixture(); defer { c.cleanup() }
        let keep = c.file("t/keep/k.bin", kb: 8); c.file("t/skip/s.bin", kb: 8); c.file("t/skipper/x.bin", kb: 8)
        UserDefaults.standard.set([c.root + "/t/skip"], forKey: "exclusions")
        let rc = Scanner.scan(path: c.root + "/t", progress: Progress()); t.reachedCode()
        t.check(rc.size == allocated(keep) + allocated(c.root + "/t/skipper/x.bin"), "excluded folder skipped, sibling with same prefix kept")
    }
}

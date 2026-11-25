import SwiftUI
import AppKit

/// `LickMyPaw --demo-shots <outdir>`: renders every page offscreen with 100% FAKE data (README screenshots).
/// `Demo.enabled` is false in normal runs; every hook elsewhere is a one-line `if Demo.enabled` guard.
enum Demo {
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) static var page: Page = .home
    nonisolated(unsafe) static var perfProcesses = false
    static let GB: Int64 = 1_000_000_000
    static let user = "/Users/Alex"
    static let disk: (name: String, total: Int64, free: Int64) = ("Macintosh HD", 1000 * GB, 380 * GB)
    static let trash: Int64 = 2_400_000_000
    static let mem = MemStats(total: 16 << 30, used: 11 << 30, app: 6 << 30, wired: 3 << 30, compressed: 2 << 30, cached: 3 << 30, free: 2 << 30)

    struct Procs: ProcessSnapshotProvider {
        func snapshot() -> [ProcInfo] {
            let u = getuid(); var pid: Int32 = 100
            func p(_ path: String, _ mb: UInt64) -> ProcInfo { pid += 1; return ProcInfo(pid: pid, uid: u, path: path, resident: mb << 20) }
            func app(_ n: String) -> String { "/Applications/\(n).app/Contents/MacOS/\(n)" }
            return [p(app("Sketchbook"), 1450), p(app("Sketchbook") + " Helper", 420), p(app("CodeNest"), 1180), p(app("CodeNest") + " Helper", 640),
                    p(app("Orbit Mail"), 760), p(app("VideoCut"), 940), p(app("NoteDeck"), 380), p(app("Chatterly"), 520), p(app("Chatterly") + " Helper", 210),
                    p(app("TunePilot"), 310), p(app("Cloudbox"), 240), p(app("FocusTimer"), 95), p("/usr/local/bin/devserver", 330), p("/usr/local/bin/syncd", 120)]
        }
    }

    static func tree() -> Node {
        func f(_ n: String, _ gb: Double, _ p: String = "") -> Node { Node(name: n, path: p + "/" + n, isDir: false, size: Int64(gb * Double(GB))) }
        func d(_ n: String, _ p: String, _ kids: [Node]) -> Node {
            let x = Node(name: n, path: p + "/" + n, isDir: true, size: kids.reduce(0) { $0 + $1.size })
            x.children = kids.sorted { $0.size > $1.size }; x.children.forEach { $0.parent = x }; return x
        }
        let h = user
        let root = d("Alex", "/Users", [
            d("Movies", h, [f("holiday-2025.mov", 41), f("family-reunion.mov", 33), f("timelapse.mp4", 24), d("Edits", h + "/Movies", [f("trailer-v3.mov", 19), f("trailer-v2.mov", 17), f("intro.mov", 8)]), f("clips-archive.zip", 26)]),
            d("Projects", h, [d("sketchbook-app", h + "/Projects", [f("build.tar", 38), f("assets.psd", 22), f("node_modules.cache", 18)]), d("game-jam", h + "/Projects", [f("world.pak", 34), f("textures.bin", 20)]), f("dataset.csv", 10)]),
            d("Games", h, [f("open-world-saga.pkg", 62), f("space-racers.pkg", 38), f("pixel-quest.pkg", 18)]),
            d("Photos", h, [f("Library.photoslibrary", 71), f("exports-2024.zip", 25)]),
            d("Downloads", h, [f("installer.dmg", 12), f("backup-old.zip", 14), f("film-clip.mkv", 8)]),
            d("Music", h, [f("Library.musiclibrary", 30), f("samples.wav", 8)]),
            d("Documents", h, [f("scans.pdf", 9), f("taxes-archive.zip", 6), f("notes.db", 7)]),
        ])
        root.children.forEach { $0.parent = root }
        return root
    }

    @MainActor static func seed() {
        enabled = true
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "lmp-demo-\(getpid())"
        let sup = tmp + "/Library/Application Support/LickMyPaw"
        try? fm.createDirectory(atPath: sup, withIntermediateDirectories: true)
        setenv("LICKMYPAW_HOME", tmp, 1)
        // settings: exclusions + history (volatile domain: never persisted, shadows the real prefs)
        UserDefaults.standard.setVolatileDomain(["exclusions": ["\(user)/Projects/archive", "\(user)/Documents/Contracts"], "lang": "en"], forName: UserDefaults.argumentDomain)
        let now = Date().timeIntervalSince1970
        let hist: [ActionEntry] = [
            .init(ts: now - 3_600, op: "trash", path: user + "/Library/Caches/com.example.sketchbook", trashedTo: nil, size: 420_000_000),
            .init(ts: now - 86_400, op: "trash", path: user + "/Downloads/installer-old.dmg", trashedTo: nil, size: 1_800_000_000),
            .init(ts: now - 2 * 86_400, op: "trash", path: user + "/Movies/render-test.mov", trashedTo: nil, size: 3_200_000_000, undone: true),
            .init(ts: now - 5 * 86_400, op: "trash", path: user + "/Library/Logs/notedeck.log", trashedTo: nil, size: 96_000_000)]
        try? hist.compactMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }.joined(separator: "\n").write(toFile: sup + "/actions.jsonl", atomically: true, encoding: .utf8)

        TrashModel.shared.size = trash; TrashModel.shared.loaded = true

        // Cleanup
        func ci(_ t: Int, _ n: String, _ mb: Int64) -> CleanItem {
            let tg = CleanupTargets.all[t]; return CleanItem(path: "\(user)\(tg.roots[0])/\(n)", name: n, size: mb * 1_000_000, targetID: tg.id, risk: tg.risk)
        }
        let cg = [CleanGroup(target: CleanupTargets.all[0], items: [ci(0, "com.example.sketchbook", 1240), ci(0, "com.example.videocut", 860), ci(0, "com.example.chatterly", 410), ci(0, "com.example.notedeck", 160)]),
                  CleanGroup(target: CleanupTargets.all[1], items: [ci(1, "CodeNest", 210), ci(1, "Cloudbox", 64)]),
                  CleanGroup(target: CleanupTargets.all[4], items: [ci(4, "sketchbook-app-abc123", 2100), ci(4, "game-jam-def456", 980)]),
                  CleanGroup(target: CleanupTargets.all[5], items: [ci(5, "com.example.simulator", 540)]),
                  CleanGroup(target: CleanupTargets.all[6], items: [ci(6, "content-v2", 730)])]
        let cm = CleanupModel.shared
        cm.groups = cg; cm.selected = Set(cg.flatMap(\.items).filter { $0.risk == .low }.map(\.id)); cm.expanded = [cg[0].id]; cm.scannedAt = Date(); cm.phase = .ready

        // Applications
        func a(_ n: String, _ v: String, _ mb: Int64, mas: Bool, run: Bool = false, days: Int) -> AppInfo {
            AppInfo(name: n, bundleID: "com.example." + n.lowercased().replacingOccurrences(of: " ", with: ""), version: v, path: "/Applications/\(n).app", size: mb * 1_000_000,
                    source: mas ? .appStore : .other, isSystem: false, running: run, lastUsed: Date().addingTimeInterval(-Double(days) * 86400))
        }
        let apps = [a("VideoCut", "5.2", 4100, mas: false, days: 3), a("Sketchbook", "12.1", 2300, mas: true, run: true, days: 0), a("CodeNest", "3.8.2", 1900, mas: false, run: true, days: 0),
                    a("PixelForge", "2.0", 1500, mas: true, days: 40), a("Cloudbox", "9.4", 820, mas: false, run: true, days: 1), a("Orbit Mail", "4.7", 640, mas: false, run: true, days: 0),
                    a("Chatterly", "8.3", 560, mas: false, days: 2), a("TunePilot", "6.1", 430, mas: true, days: 12), a("NoteDeck", "1.9", 310, mas: true, days: 1),
                    a("MindMapper", "3.3", 280, mas: true, days: 120), a("Paperplane", "2.5", 190, mas: false, days: 75), a("ClipBoard Pro", "7.0", 120, mas: false, days: 9),
                    a("FocusTimer", "1.4", 64, mas: true, days: 2), a("Calcly", "2.2", 38, mas: true, days: 200)]
        let am = AppsModel.shared
        am.loader = { apps }; am.finder = { _ in [] }; am.fillLastUsed = false

        // Clutter
        func cf(_ p: String, _ mb: Int64, _ days: Int) -> CFile { CFile(path: user + "/" + p, size: mb * 1_000_000, mtime: Date().addingTimeInterval(-Double(days) * 86400)) }
        let big = [cf("Movies/holiday-2025.mov", 41000, 200), cf("Games/open-world-saga.pkg", 62000, 400), cf("Movies/family-reunion.mov", 33000, 700), cf("Photos/exports-2024.zip", 25000, 480),
                   cf("Downloads/backup-old.zip", 14000, 520), cf("Projects/game-jam/world.pak", 34000, 300), cf("Downloads/installer.dmg", 12000, 150), cf("Movies/clips-archive.zip", 26000, 800),
                   cf("Documents/taxes-archive.zip", 6000, 900), cf("Music/samples.wav", 8000, 260)]
        let dups = DupGroup(id: "demo-dup-1", size: 1_200_000_000, files: [cf("Downloads/film-clip.mkv", 1200, 90), cf("Movies/film-clip copy.mkv", 1200, 85), cf("Documents/film-clip.mkv", 1200, 60)])
        let km = ClutterModel.shared
        km.root = user; km.files = big; km.groups = [dups]; km.scannedAt = Date(); km.dupAt = Date(); km.tab = .large

        // Purr
        var r = PurrReport(); r.disk = (disk.total, disk.free); r.cleanupBytes = 3_200_000_000; r.startupAgents = 7; r.startupBroken = 2; r.pressure = .normal; r.fda = .granted
        PurrModel.shared.report = r

        // Protection
        let pm = ProtectionModel.shared
        pm.status = .ready(path: "/opt/homebrew/bin/clamscan", version: "ClamAV 1.4.1", dbAgeDays: 1)
        let S = "Protection"
        pm.checks = [SecurityCheck(id: "sip", title: TT("System Integrity Protection", S), posture: .good, detail: TT("Enabled: system files are protected", S)),
                     SecurityCheck(id: "gk", title: TT("Gatekeeper", S), posture: .good, detail: TT("Enabled: only trusted apps open without a warning", S)),
                     SecurityCheck(id: "fv", title: TT("FileVault disk encryption", S), posture: .good, detail: TT("On: your disk is encrypted", S)),
                     SecurityCheck(id: "fw", title: TT("Firewall", S), posture: .attention, detail: TT("Off: incoming connections are not filtered", S)),
                     SecurityCheck(id: "xp", title: TT("XProtect (Apple built-in malware definitions)", S), posture: .good, detail: TTF("Version %@", S, "5300"))]
        let det = Detection(path: user + "/Downloads/eicar-test-file.com", signature: "Win.Test.EICAR_HDB-1", size: 68)
        pm.detections = [det]; pm.found = 1; pm.scannedAt = Date(); pm.lastReport = ScanReport(detections: [det], duration: 41.6); pm.elapsed = 41.6
    }

    /// Called from ContentView.onAppear in demo mode.
    @MainActor static func apply(_ m: Model) {
        m.page = page
        if page == .prowl { let t = tree(); m.root = t; m.current = t }
    }

    @MainActor static func shots(_ out: String) {
        seed()
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let pages: [(String, Page, Bool)] = [("01-home", .home, false), ("02-prowl", .prowl, false), ("03-cleanup", .cleanup, false), ("04-applications", .apps, false), ("05-clutter", .clutter, false),
                                             ("06-performance", .performance, true), ("07-purr", .purr, false), ("08-protection", .protection, false), ("09-settings", .settings, false)]
        let waits = Int(ProcessInfo.processInfo.environment["LMP_RENDER_WAIT"] ?? "") ?? 25
        for (name, pg, perf) in pages {
            page = pg; perfProcesses = perf
            let host = NSHostingView(rootView: ContentView().ignoresSafeArea().frame(width: 1440, height: 900))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSAppearance(named: .darkAqua)
            for _ in 0..<waits { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("render failed \(name)"); exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { print("render failed \(name)"); exit(1) }
            try? png.write(to: URL(fileURLWithPath: out + "/\(name).png")); print("rendered \(name)")
            win.contentView = nil
        }
        exit(0)
    }
}


/// RelativeDateTimeFormatter that stays in English while rendering screenshots (the system locale is not overridable from the command line).
func makeRelativeFormatter() -> RelativeDateTimeFormatter {
    let f = RelativeDateTimeFormatter()
    if Demo.enabled { f.locale = Locale(identifier: "en_US") }
    return f
}

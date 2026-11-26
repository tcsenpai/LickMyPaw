import SwiftUI
import AppKit

private let S = "Privacy"

// MARK: - core

enum PrivRisk { case low, medium, high }
enum PrivCat: String { case cache, history, cookies, downloads, recent, quicklook, quarantine, shell }

struct PrivacyItem: Identifiable, Equatable {
    let browser: String          // display name, or "System"
    let bundleID: String?        // nil for system items; set for browsers (must be quit before cleaning)
    let cat: PrivCat
    let paths: [String]
    var size: Int64
    let risk: PrivRisk
    var id: String { (bundleID ?? "system") + "." + cat.rawValue }
    var title: String {
        switch cat {
        case .cache: return TT("Cache", S)
        case .history: return TT("Browsing history", S)
        case .cookies: return TT("Cookies and site data", S)
        case .downloads: return TT("Download list", S)
        case .recent: return TT("Recent items", S)
        case .quicklook: return TT("Quick Look cache", S)
        case .quarantine: return TT("Download quarantine log", S)
        case .shell: return TT("Shell history", S)
        }
    }
    /// Shown under the row when the item has a side effect worth knowing.
    var warning: String? {
        switch cat {
        case .cookies: return TT("You will be signed out of websites.", S)
        case .history where bundleID == "org.mozilla.firefox": return TT("Firefox keeps bookmarks in the same file: they will go too.", S)
        case .shell: return TT("Removes the command history of your terminals. Off by default.", S)
        case .quarantine: return TT("macOS forgets where your downloads came from.", S)
        default: return nil
        }
    }
    /// Cookies and anything that can cost you data or logins stay unchecked until you choose them.
    var defaultOn: Bool { risk == .low }
}

enum PrivacyScan {
    struct Chromium { let name, bundleID, support, cache: String }
    static let chromium = [Chromium(name: "Chrome", bundleID: "com.google.Chrome", support: "Library/Application Support/Google/Chrome", cache: "Library/Caches/Google/Chrome"),
                           Chromium(name: "Edge", bundleID: "com.microsoft.edgemac", support: "Library/Application Support/Microsoft Edge", cache: "Library/Caches/Microsoft Edge"),
                           Chromium(name: "Brave", bundleID: "com.brave.Browser", support: "Library/Application Support/BraveSoftware/Brave-Browser", cache: "Library/Caches/BraveSoftware/Brave-Browser"),
                           Chromium(name: "Arc", bundleID: "company.thebrowser.Browser", support: "Library/Application Support/Arc/User Data", cache: "Library/Caches/Arc")]
    static let safariID = "com.apple.Safari", firefoxID = "org.mozilla.firefox"
    static let browserIDs = [safariID, firefoxID] + chromium.map(\.bundleID)

    private static func existing(_ home: String, _ rels: [String]) -> [String] { rels.map { home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) } }
    private static func subdirs(_ path: String, _ ok: (String) -> Bool) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter(ok).sorted().map { path + "/" + $0 }
    }
    private static func item(_ name: String, _ bid: String?, _ cat: PrivCat, _ paths: [String], _ risk: PrivRisk) -> PrivacyItem? {
        paths.isEmpty ? nil : PrivacyItem(browser: name, bundleID: bid, cat: cat, paths: paths, size: paths.reduce(0) { $0 + allocSize($1) }, risk: risk)
    }

    /// Read-only listing of what exists under `home`. Shell history only when opted in.
    static func scan(home: String, includeShell: Bool) -> [PrivacyItem] {
        var out: [PrivacyItem?] = []
        // Safari (history, cookies, downloads need Full Disk Access to be visible)
        out += [item("Safari", safariID, .cache, existing(home, ["Library/Caches/com.apple.Safari"]), .low),
                item("Safari", safariID, .history, existing(home, ["Library/Safari/History.db", "Library/Safari/History.db-shm", "Library/Safari/History.db-wal"]), .low),
                item("Safari", safariID, .downloads, existing(home, ["Library/Safari/Downloads.plist"]), .low),
                item("Safari", safariID, .cookies, existing(home, ["Library/Cookies/Cookies.binarycookies", "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"]), .medium)]
        // Chromium family: per profile files, one row per category
        for c in chromium {
            let profiles = subdirs(home + "/" + c.support) { $0 == "Default" || $0.hasPrefix("Profile ") }
            func files(_ names: [String]) -> [String] { profiles.flatMap { p in names.map { p + "/" + $0 } }.filter { FileManager.default.fileExists(atPath: $0) } }
            out += [item(c.name, c.bundleID, .cache, existing(home, [c.cache]), .low),
                    item(c.name, c.bundleID, .history, files(["History", "History-journal", "Visited Links", "Top Sites"]), .low),
                    item(c.name, c.bundleID, .cookies, files(["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]), .medium)]
        }
        // Firefox
        let ff = subdirs(home + "/Library/Application Support/Firefox/Profiles") { _ in true }
        func ffFiles(_ names: [String]) -> [String] { ff.flatMap { p in names.map { p + "/" + $0 } }.filter { FileManager.default.fileExists(atPath: $0) } }
        out += [item("Firefox", firefoxID, .cache, existing(home, ["Library/Caches/Firefox"]), .low),
                item("Firefox", firefoxID, .history, ffFiles(["places.sqlite", "places.sqlite-wal", "places.sqlite-shm"]), .high),
                item("Firefox", firefoxID, .cookies, ffFiles(["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"]), .medium)]
        // System traces
        let sfl = home + "/Library/Application Support/com.apple.sharedfilelist"
        let recent = subdirs(sfl) { $0.contains("Recent") }
        let sys = "System"
        out += [item(sys, nil, .recent, recent, .low),
                item(sys, nil, .quicklook, existing(home, ["Library/Caches/com.apple.QuickLook.thumbnailcache"]), .low),
                item(sys, nil, .quarantine, existing(home, ["Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2", "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2-shm", "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2-wal"]), .low)]
        if includeShell { out.append(item(sys, nil, .shell, existing(home, [".zsh_history", ".bash_history", ".local/share/fish/fish_history"]), .high)) }
        return out.compactMap { $0 }
    }
}

// MARK: - model

@MainActor final class PrivacyModel: ObservableObject {
    static let shared = PrivacyModel()
    @Published var items: [PrivacyItem] = []
    @Published var selected: Set<String> = []
    @Published var includeShell = false { didSet { if includeShell != oldValue && scannedAt != nil { scan() } } }
    @Published var scanning = false
    @Published var scannedAt: Date?
    @Published var message: String?
    @Published var freed: Int64 = 0
    @Published var runningIDs: Set<String> = []
    @Published var fda: Permissions.Status = .unknown
    var terminator: AppTerminator
    var home: () -> String
    var fdaProbe: () -> Permissions.Status
    private var token: NSObjectProtocol?

    init(terminator: AppTerminator = SystemAppTerminator(), home: @escaping () -> String = { Env.home }, fdaProbe: @escaping () -> Permissions.Status = { Permissions.fullDiskAccess() }) {
        self.terminator = terminator; self.home = home; self.fdaProbe = fdaProbe
        token = NotificationCenter.default.addObserver(forName: Engine.didChange, object: nil, queue: nil) { [weak self] n in   // queue: nil, never .main
            let op = n.userInfo?["op"] as? String ?? ""
            Task { @MainActor in if op == "undo" { self?.message = TT("Restored: rescan to see it again", S) } }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    var browsers: [String] { var seen: [String] = []; for i in items where !seen.contains(i.browser) { seen.append(i.browser) }; return seen }
    func items(of browser: String) -> [PrivacyItem] { items.filter { $0.browser == browser } }
    func bundleID(of browser: String) -> String? { items.first { $0.browser == browser }?.bundleID }
    var selectedItems: [PrivacyItem] { items.filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func refreshRunning() { runningIDs = Set(PrivacyScan.browserIDs.filter { terminator.isRunning(bundleID: $0) }) }

    func scan() {
        guard !scanning else { return }
        scanning = true; message = nil
        let h = home(), sh = includeShell
        Task {
            let r = await Task.detached { PrivacyScan.scan(home: h, includeShell: sh) }.value
            withAnimation(spring) { items = r; selected = Set(r.filter(\.defaultOn).map(\.id)); scanning = false; scannedAt = Date() }
            refreshRunning(); fda = fdaProbe()
        }
    }

    func quit(_ browser: String) {
        guard let b = bundleID(of: browser) else { return }
        if !terminator.terminate(bundleID: b) { message = TTF("%@ did not quit. Close it yourself and try again.", S, browser) }
        refreshRunning()
    }

    struct Outcome { var trashed = 0, failed: [String] = [], refusedBrowsers: [String] = [] }

    /// Trash every selected item. Items of a running browser are refused (never touch a live profile) unless `quitFirst` and the polite quit succeeds.
    @discardableResult func clean(quitFirst: Bool = false) -> Outcome {
        var o = Outcome(), gone = Set<String>(), freedNow: Int64 = 0
        var quit: [String: Bool] = [:]   // one polite quit request per browser, not per row
        for it in selectedItems {
            if let b = it.bundleID, terminator.isRunning(bundleID: b) {
                if quit[b] == nil { quit[b] = quitFirst && terminator.terminate(bundleID: b) }
                if quit[b] != true { if !o.refusedBrowsers.contains(it.browser) { o.refusedBrowsers.append(it.browser) }; continue }
            }
            var ok = true
            for p in it.paths where FileManager.default.fileExists(atPath: p) || (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil {
                do { try Engine.trash(p, size: allocSize(p)) } catch { ok = false; o.failed.append("\(p): \(error.localizedDescription)") }
            }
            if ok { gone.insert(it.id); o.trashed += 1; freedNow += it.size }
        }
        withAnimation(spring) { items.removeAll { gone.contains($0.id) }; selected.subtract(gone); freed += freedNow }
        refreshRunning()
        if !o.refusedBrowsers.isEmpty { message = TTF("Quit first: %@", S, o.refusedBrowsers.joined(separator: ", ")) }
        else if !o.failed.isEmpty { message = o.failed[0] }
        else { message = TTF("Moved %d item(s) to the Trash. Restore from History if needed.", S, o.trashed) }
        return o
    }
}

// MARK: - view

struct PrivacyView: View {
    @ObservedObject private var m = PrivacyModel.shared
    @State private var review = false
    @State private var fdaGuide = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(TT("Privacy", S)).font(.system(size: 30, weight: .bold, design: .rounded))
                    Spacer()
                    Button { m.scan() } label: { SpinnerLabel(title: m.scannedAt == nil ? TT("Scan", S) : TT("Rescan", S), busy: m.scanning) }.buttonStyle(SoftButton()).disabled(m.scanning)
                }
                Text(TT("Removes traces of your browsing. Everything goes to the Trash, so it can be restored from History. Quit the browser first.", S)).font(.caption).opacity(0.65)
                if m.fda != .granted && m.scannedAt != nil { fdaBanner }
                Toggle(TT("Include shell history (off by default)", S), isOn: $m.includeShell).toggleStyle(.switch).font(.callout)
                if let msg = m.message { Text(msg).font(.callout).foregroundStyle(.orange) }
                if m.scannedAt != nil && m.items.isEmpty { Text(TT("Nothing to clean", S)).opacity(0.6) }
                ForEach(m.browsers, id: \.self) { group($0) }
                if !m.items.isEmpty { footer }
            }.padding(20)
        }
        .foregroundStyle(.white)
        .onAppear { if m.scannedAt == nil && !Demo.enabled { m.scan() } else { m.refreshRunning() } }
        .sheet(isPresented: $review) { ReviewSheet(m: m, isPresented: $review) }
        .sheet(isPresented: $fdaGuide) { FDAGuideView(onNotNow: { fdaGuide = false }, onClose: { fdaGuide = false }).frame(width: 520, height: 420) }
    }

    private var fdaBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.system(size: 20)).foregroundStyle(Color(hex: 0xFF8AD1))
            Text(TT("Safari history, cookies and download list need Full Disk Access to be seen.", S)).font(.callout)
            Spacer()
            Button(TT("Set up…", S)) { fdaGuide = true }.buttonStyle(PinkButton())
        }.padding(12).glass(14)
    }

    private func group(_ name: String) -> some View {
        let its = m.items(of: name), bid = m.bundleID(of: name), running = bid.map { m.runningIDs.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name == "System" ? TT("macOS traces", S) : name).font(.headline)
                if running {
                    Text(TT("Running", S)).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 2).background(Color.orange.opacity(0.4), in: Capsule())
                    Button(TT("Quit", S)) { m.quit(name) }.buttonStyle(SoftButton())
                }
                Spacer()
            }
            ForEach(its) { row($0, locked: running) }
        }.padding(14).glass(16)
    }

    private func row(_ it: PrivacyItem, locked: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { m.selected.contains(it.id) }, set: { if $0 { m.selected.insert(it.id) } else { m.selected.remove(it.id) } })).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(it.title).font(.body.weight(.medium))
                    if it.risk != .low { Text(it.risk == .high ? TT("High risk", S) : TT("Signs you out", S)).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2).background((it.risk == .high ? Color.red : .orange).opacity(0.4), in: Capsule()) }
                }
                if let w = it.warning { Text(w).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Text(fmt(it.size)).opacity(0.8)
        }.opacity(locked ? 0.55 : 1)
    }

    private var footer: some View {
        HStack {
            Text(TTF("Selected: %@", S, fmt(m.selectedSize))).font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            Button(TT("Review and Clean", S)) { m.refreshRunning(); review = true }.buttonStyle(PinkButton()).disabled(m.selected.isEmpty)
        }
    }
}

private struct ReviewSheet: View {
    @ObservedObject var m: PrivacyModel
    @Binding var isPresented: Bool
    var body: some View {
        let sel = m.selectedItems, running = Set(sel.compactMap { i in i.bundleID.flatMap { m.runningIDs.contains($0) ? i.browser : nil } })
        VStack(alignment: .leading, spacing: 12) {
            Text(TTF("Move %d item(s) to the Trash?", S, sel.count)).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sel) { i in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(i.browser == "System" ? "" : i.browser + ": ")\(i.title)").font(.body.weight(.medium))
                                if let w = i.warning { Text(w).font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer(); Text(fmt(i.size)).opacity(0.8)
                        }
                    }
                }
            }.frame(maxHeight: 260)
            if !running.isEmpty { Text(TTF("Running now: %@. They will be asked to quit first.", S, running.sorted().joined(separator: ", "))).font(.callout).foregroundStyle(.yellow) }
            Text(TT("Files go to the Trash and can be restored from History.", S)).font(.callout).opacity(0.8)
            HStack {
                Text(TTF("Total: %@", S, fmt(m.selectedSize))).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button(TT("Cancel", S)) { isPresented = false }.buttonStyle(SoftButton())
                Button(TT("Move to Trash", S)) { m.clean(quitFirst: true); isPresented = false }.buttonStyle(PinkButton())
            }
        }.padding(24).frame(width: 520).foregroundStyle(.white).background(Background())
    }
}

// MARK: - self test

enum PrivacySelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        let fm = FileManager.default
        // fake home: Safari, Chrome (2 profiles), Firefox, system traces, shell history. Edge/Brave/Arc absent.
        let sCache = f.file("home/Library/Caches/com.apple.Safari/cache.db", kb: 8)
        let sHist = f.file("home/Library/Safari/History.db", kb: 4), sCook = f.file("home/Library/Cookies/Cookies.binarycookies", kb: 2)
        let cCache = f.file("home/Library/Caches/Google/Chrome/Default/Cache/data_0", kb: 16)
        let cHist = f.file("home/Library/Application Support/Google/Chrome/Default/History", kb: 4), cHist2 = f.file("home/Library/Application Support/Google/Chrome/Profile 1/History", kb: 4)
        let cCook = f.file("home/Library/Application Support/Google/Chrome/Default/Network/Cookies", kb: 4)
        f.file("home/Library/Application Support/Google/Chrome/Default/Preferences", kb: 1)   // profile data we must NEVER list
        f.dir("home/Library/Application Support/Google/Chrome/System Profile")               // not a profile
        let ffPlaces = f.file("home/Library/Application Support/Firefox/Profiles/abc.default/places.sqlite", kb: 4)
        let ffCook = f.file("home/Library/Application Support/Firefox/Profiles/abc.default/cookies.sqlite", kb: 4)
        let recent = f.file("home/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3", kb: 2)
        let fav = f.file("home/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl3", kb: 2)   // not "recent": keep
        let ql = f.file("home/Library/Caches/com.apple.QuickLook.thumbnailcache/index.sqlite", kb: 4)
        let qr = f.file("home/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2", kb: 4)
        let zsh = f.file("home/.zsh_history", kb: 2)

        let items = PrivacyScan.scan(home: f.home, includeShell: false); t.reachedCode()
        func it(_ id: String) -> PrivacyItem? { items.first { $0.id == id } }
        t.check(items.contains { $0.browser == "Safari" } && items.contains { $0.browser == "Chrome" } && items.contains { $0.browser == "Firefox" } && items.contains { $0.browser == "System" }, "detects installed browsers and system traces")
        t.check(!items.contains { ["Edge", "Brave", "Arc"].contains($0.browser) }, "absent browsers are not listed")
        t.check(it("com.google.Chrome.history")?.paths.sorted() == [cHist, cHist2].sorted(), "Chrome history covers every profile")
        t.check(it("com.google.Chrome.cookies")?.paths == [cCook] && it("com.apple.Safari.cookies")?.paths == [sCook], "cookie files found per browser")
        t.check(!items.flatMap(\.paths).contains { $0.hasSuffix("Preferences") || $0.contains("System Profile") }, "only history/cookie/cache files are ever listed, no profile settings")
        t.check(it("system.recent")?.paths == [recent] && !items.flatMap(\.paths).contains(fav), "Recent Items only, not Favorites")
        t.check(it("system.shell") == nil, "shell history is not even listed unless opted in")
        t.check(PrivacyScan.scan(home: f.home, includeShell: true).first { $0.cat == .shell }?.paths == [zsh], "shell history appears with the opt-in")
        t.check(it("com.apple.Safari.cache")?.size ?? 0 >= 8 << 10 && it("com.google.Chrome.cache")?.size ?? 0 >= 16 << 10, "sizes reported")
        t.check(items.filter { $0.cat == .cookies }.allSatisfy { !$0.defaultOn && $0.warning != nil } && it("org.mozilla.firefox.history")?.defaultOn == false && it("org.mozilla.firefox.history")?.warning != nil, "cookies and Firefox history default unchecked with a warning")
        t.check(it("com.google.Chrome.cache")?.defaultOn == true && it("system.recent")?.defaultOn == true, "low-risk caches default checked")

        // model: running browser is refused, polite quit through the terminator, trash + log
        let ft = FakeTerminator(); ft.onlyRunning = ["com.google.Chrome"]
        let m = PrivacyModel(terminator: ft, home: { f.home }, fdaProbe: { .denied })
        m.items = items; m.selected = Set(items.filter(\.defaultOn).map(\.id)); m.selected.insert("com.google.Chrome.cookies")
        m.refreshRunning()
        t.check(m.runningIDs == ["com.google.Chrome"], "running browsers detected through the terminator")
        let o1 = m.clean(quitFirst: false)
        t.check(o1.refusedBrowsers == ["Chrome"] && fm.fileExists(atPath: cCache) && fm.fileExists(atPath: cHist) && fm.fileExists(atPath: cCook) && ft.events.isEmpty, "running browser refused: nothing of it touched, no kill")
        t.check(!fm.fileExists(atPath: sCache) && !fm.fileExists(atPath: sHist) && !fm.fileExists(atPath: ql) && !fm.fileExists(atPath: recent) && !fm.fileExists(atPath: qr), "other selected items were removed")
        t.check(fm.fileExists(atPath: sCook) && fm.fileExists(atPath: ffCook) && fm.fileExists(atPath: ffPlaces) && fm.fileExists(atPath: fav), "unselected cookies/Firefox history/Favorites stay")
        let log = ActionLog.all()
        t.check(log.count >= 5 && log.allSatisfy { $0.op == "trash" && ($0.trashedTo ?? "").hasPrefix(f.home + "/.Trash") }, "deletion goes through Engine.trash (fake Trash, logged)"); t.reachedCode()
        ft.refuse = ["com.google.Chrome"]
        let o2 = m.clean(quitFirst: true)
        t.check(o2.refusedBrowsers == ["Chrome"] && ft.events == ["terminate:com.google.Chrome"] && fm.fileExists(atPath: cCook), "quit refused by the app: still nothing touched")
        ft.refuse = []
        let o3 = m.clean(quitFirst: true)
        t.check(o3.failed.isEmpty && o3.trashed == 3 && !fm.fileExists(atPath: cCache) && !fm.fileExists(atPath: cHist2) && !fm.fileExists(atPath: cCook), "after a polite quit Chrome items are trashed (cache, history, selected cookies)")
        t.check(m.freed > 0 && !m.items.contains { $0.browser == "Chrome" }, "freed counter updated, rows dropped")
        if let e = log.first { try? Engine.undo(e) }
        t.check(ActionLog.all().first?.undone == true, "trashed traces are undoable")

        // Safety refusal: a crafted item pointing at a protected place is refused by Engine.trash
        let bad = PrivacyItem(browser: "System", bundleID: nil, cat: .recent, paths: ["/System/Library", f.home], size: 1, risk: .low)
        m.items = [bad]; m.selected = [bad.id]
        let o4 = m.clean()
        t.check(o4.failed.count == 2 && o4.trashed == 0 && fm.fileExists(atPath: "/System/Library") && fm.fileExists(atPath: f.home), "Safety.check refuses protected paths even if an item names them")
        m.fdaProbe = { .granted }
        t.check(m.fdaProbe() == .granted && m.includeShell == false, "shell history opt-in defaults to off")
    }
}

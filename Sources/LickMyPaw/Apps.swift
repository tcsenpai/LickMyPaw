import SwiftUI
import AppKit

/// Process-wide: results survive section switches. Scans on first open and on explicit Rescan only.
@MainActor final class AppsModel: ObservableObject {
    static let shared = AppsModel()
    enum Sort { case size, name }
    enum Phase: Equatable { case idle, confirm, running(Int, Int), done }
    struct Entry: Identifiable { let app: AppInfo; let items: [Leftover]; var id: String { app.id }; var total: Int64 { app.size + items.reduce(0) { $0 + $1.size } } }

    @Published var apps: [AppInfo] = []
    @Published var loading = false
    @Published var query = ""
    @Published var sort = Sort.size
    @Published var selected: AppInfo?
    @Published var leftovers: [Leftover] = []
    @Published var picked: Set<String> = []
    @Published var scanningLeftovers = false
    @Published var confirming = false
    @Published var busy = false
    @Published var results: [Uninstaller.ItemResult]?
    @Published var scannedAt: Date?
    @Published var stale = false
    @Published var selection: Set<String> = []          // app paths
    @Published var leftoversCache: [String: [Leftover]] = [:]
    @Published var phase = Phase.idle
    @Published var entries: [Entry] = []
    @Published var batchResults: [Uninstaller.AppResult] = []
    @Published var quitFirst = true
    @Published var undoNote: String?
    var userPicks: [String: Set<String>] = [:]          // leftover choices the user changed, per app path
    var batchStart = 0.0
    var loader: @Sendable () -> [AppInfo]
    var finder: @Sendable (AppInfo) -> [Leftover]
    var fillLastUsed = true
    private var observer: NSObjectProtocol?

    init(loader: @escaping @Sendable () -> [AppInfo] = { AppInventory.load() }, finder: @escaping @Sendable (AppInfo) -> [Leftover] = { LeftoverMatcher.find(for: $0) }) {
        self.loader = loader; self.finder = finder
        observer = NotificationCenter.default.addObserver(forName: Engine.didChange, object: nil, queue: nil) { [weak self] n in
            let op = n.userInfo?["op"] as? String ?? "", paths = n.userInfo?["paths"] as? [String] ?? []
            if Thread.isMainThread { MainActor.assumeIsolated { self?.handleEngineChange(op: op, paths: paths) } }
            else { Task { @MainActor in self?.handleEngineChange(op: op, paths: paths) } }
        }
    }

    var shown: [AppInfo] {
        let q = query.lowercased()
        let l = apps.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        return sort == .size ? l.sorted { $0.size > $1.size } : l.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    var chosen: [Leftover] { leftovers.filter { picked.contains($0.id) && !$0.readOnly } }
    var total: Int64 { (selected?.size ?? 0) + chosen.reduce(0) { $0 + $1.size } }
    var selectedApps: [AppInfo] { apps.filter { selection.contains($0.id) } }
    var selectionTotal: Int64 { selectedApps.reduce(0) { $0 + $1.size + chosen(for: $1).reduce(0) { $0 + $1.size } } }

    /// Pure: "just now" / "3 min ago" / "2 h ago" / "4 d ago".
    static func relativeTime(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return TT("just now", "Apps") }
        if s < 3600 { return TTF("%d min ago", "Apps", s / 60) }
        if s < 86400 { return TTF("%d h ago", "Apps", s / 3600) }
        return TTF("%d d ago", "Apps", s / 86400)
    }
    static func defaultPicks(_ ls: [Leftover]) -> Set<String> { Set(ls.filter { $0.confidence == .high && !$0.readOnly }.map(\.id)) }

    // MARK: scan / cache
    func open() async { if scannedAt == nil && !loading { await rescan() } }

    func rescan() async {
        guard !loading else { return }
        loading = true
        let l = loader
        let a = await Task.detached { l() }.value
        apps = a; scannedAt = Date(); stale = false; loading = false; leftoversCache = [:]
        let ids = Set(a.map(\.id))
        selection.formIntersection(ids)
        if let s = selected, !ids.contains(s.id) { selected = nil; leftovers = []; picked = [] }
        guard fillLastUsed else { return }
        Task { // last-used is best effort, filled in progressively
            for app in a {
                let d = await Task.detached { AppInventory.lastUsed(app.path) }.value
                if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].lastUsed = d; if selected?.id == app.id { selected?.lastUsed = d } }
            }
        }
    }

    /// Any trash/undo anywhere: drop vanished apps, flag the cache as possibly stale (no auto-rescan).
    func handleEngineChange(op: String, paths: [String]) {
        let fm = FileManager.default
        let gone = Set(apps.filter { a in (op == "trash" && paths.contains { a.path == $0 || a.path.hasPrefix($0 + "/") }) || !fm.fileExists(atPath: a.path) }.map(\.id))
        if !gone.isEmpty {
            apps.removeAll { gone.contains($0.id) }
            selection.subtract(gone)
            for g in gone { userPicks[g] = nil }
            if let s = selected, gone.contains(s.id) { selected = nil; leftovers = []; picked = [] }
        }
        leftoversCache = [:]
        if scannedAt != nil { stale = true }
    }

    // MARK: leftovers
    func leftovers(for a: AppInfo) async -> [Leftover] {
        if let c = leftoversCache[a.id] { return c }
        let f = finder
        let l = await Task.detached { f(a) }.value
        leftoversCache[a.id] = l
        return l
    }
    func picks(for a: AppInfo) -> Set<String> { userPicks[a.id] ?? Self.defaultPicks(leftoversCache[a.id] ?? []) }
    func chosen(for a: AppInfo) -> [Leftover] { let p = picks(for: a); return (leftoversCache[a.id] ?? []).filter { p.contains($0.id) && !$0.readOnly } }

    func select(_ a: AppInfo) {
        selected = a; results = nil
        if let c = leftoversCache[a.id] { leftovers = c; picked = picks(for: a); scanningLeftovers = false; return }
        leftovers = []; picked = []; scanningLeftovers = true
        Task {
            let l = await leftovers(for: a)
            guard selected?.id == a.id else { return }
            leftovers = l; picked = picks(for: a); scanningLeftovers = false
        }
    }
    func togglePick(_ id: String, _ on: Bool) {
        if on { picked.insert(id) } else { picked.remove(id) }
        if let s = selected { userPicks[s.id] = picked }
    }

    // MARK: selection
    func toggle(_ a: AppInfo) {
        guard !a.isSystem else { return }
        if selection.remove(a.id) == nil { selection.insert(a.id); Task { _ = await leftovers(for: a) } }
    }
    func selectAll() {
        let l = shown.filter { !$0.isSystem }
        selection.formUnion(l.map(\.id))
        Task { for a in l { _ = await leftovers(for: a) } }
    }
    func selectNone() { selection = [] }

    // MARK: single app
    func uninstall() {
        guard let a = selected else { return }
        busy = true; let ls = chosen
        Task {
            let r = await Uninstaller.uninstall(a, ls)
            busy = false; results = r; confirming = false
            if r.first?.ok == true { apps.removeAll { $0.id == a.id }; selection.remove(a.id); leftovers = []; picked = [] }
        }
    }

    // MARK: batch
    func prepareBatch() async {
        let sel = selectedApps; guard !sel.isEmpty else { return }
        var es: [Entry] = []
        for a in sel { _ = await leftovers(for: a); es.append(Entry(app: a, items: chosen(for: a))) }
        entries = es; batchResults = []; undoNote = nil; phase = .confirm
    }
    func runBatch() async {
        let es = entries; guard !es.isEmpty else { return }
        batchStart = Date().timeIntervalSince1970; undoNote = nil
        phase = .running(1, es.count)
        let map = Dictionary(uniqueKeysWithValues: es.map { ($0.app.id, $0.items) })
        let r = await Uninstaller.uninstallMany(apps: es.map(\.app), leftoversFor: { map[$0.id] ?? [] }, quit: quitFirst) { i, n in
            Task { @MainActor in if case .running = self.phase { self.phase = .running(i, n) } }
        }
        batchResults = r
        handleEngineChange(op: "trash", paths: r.flatMap { $0.items.filter(\.ok).map(\.path) })
        phase = .done
    }
    func undoBatch() {
        let paths = Set(batchResults.flatMap { $0.items.filter(\.ok).map(\.path) })
        var n = 0
        for e in ActionLog.all().reversed() where e.op == "trash" && !e.undone && e.ts >= batchStart && paths.contains(e.path) { if (try? Engine.undo(e)) != nil { n += 1 } }
        undoNote = TTF("Restored %d items", "Apps", n)
    }
}

struct AppsView: View {
    @ObservedObject private var m = AppsModel.shared
    private let T_ = "Apps"
    var body: some View {
        ZStack {
            Background()
            HStack(alignment: .top, spacing: 16) {
                list.frame(maxWidth: .infinity)
                detail.frame(width: 340)
            }.padding(20)
        }
        .onAppear { Task { await m.open() } }
        .sheet(isPresented: $m.confirming) { confirmSheet }
        .sheet(isPresented: Binding(get: { m.phase != .idle }, set: { if !$0, case .running = m.phase {} else if !$0 { m.phase = .idle } })) { batchSheet }
        .animation(spring, value: m.selected?.id)
    }

    var list: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack { Image(systemName: "magnifyingglass").opacity(0.7)
                    TextField(TT("Search apps", T_), text: $m.query).textFieldStyle(.plain) }
                    .padding(.horizontal, 12).padding(.vertical, 8).glass(16)
                Picker("", selection: $m.sort) { Text(TT("Size", T_)).tag(AppsModel.Sort.size); Text(TT("Name", T_)).tag(AppsModel.Sort.name) }
                    .pickerStyle(.segmented).frame(width: 150).labelsHidden()
                Button(TT("Rescan", T_)) { Task { await m.rescan() } }.buttonStyle(SoftButton()).disabled(m.loading)
            }
            if let at = m.scannedAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TTF("Saved results from %@ (%@) — press Rescan to refresh", T_, at.formatted(date: .omitted, time: .shortened), AppsModel.relativeTime(at)))
                        if m.stale { Text(TT("Updated after recent actions — Rescan to be sure", T_)).foregroundStyle(Color(hex: 0xFF8FC8)) }
                    }.font(.system(size: 11, design: .rounded)).opacity(0.8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if m.loading && m.apps.isEmpty { Spacer(); ProgressView(TT("Scanning applications…", T_)); Spacer() }
            else {
                ScrollView { LazyVStack(spacing: 6) { ForEach(m.shown) { row($0) } } }
                selectionBar
            }
        }.foregroundStyle(.white)
    }

    var selectionBar: some View {
        HStack(spacing: 10) {
            Text(TTF("%d apps selected", T_, m.selection.count) + (m.selection.isEmpty ? "" : " · " + fmt(m.selectionTotal))).font(.system(size: 12, weight: .semibold, design: .rounded))
            Menu(TT("Select all", T_)) {
                Button(TT("Select all", T_)) { m.selectAll() }
                Button(TT("None", T_)) { m.selectNone() }
            }.menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Button(TT("Uninstall", T_)) { Task { await m.prepareBatch() } }.buttonStyle(PinkButton()).disabled(m.selection.isEmpty || m.busy)
        }.padding(10).glass(14)
    }

    func row(_ a: AppInfo) -> some View {
        HStack(spacing: 12) {
            Button { m.toggle(a) } label: {
                Image(systemName: m.selection.contains(a.id) ? "checkmark.square.fill" : "square").font(.system(size: 17)).opacity(a.isSystem ? 0.3 : 1)
            }.buttonStyle(.plain).disabled(a.isSystem).help(a.isSystem ? TT("System apps cannot be selected", T_) : "")
            Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(a.version.isEmpty ? a.bundleID : TTF("Version %@", T_, a.version)).font(.system(size: 11, design: .rounded)).opacity(0.65).lineLimit(1)
            }
            Spacer()
            badge(a.isSystem ? TT("System", T_) : a.source == .appStore ? TT("App Store", T_) : TT("Other", T_))
            Text(fmt(a.size)).font(.system(size: 13, weight: .medium, design: .rounded)).frame(width: 74, alignment: .trailing)
        }
        .padding(10).glass(14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(hex: 0xFF3FA4), lineWidth: m.selected?.id == a.id ? 2 : 0))
        .contentShape(Rectangle()).onTapGesture { withAnimation(spring) { m.select(a) } }
    }

    func badge(_ s: String, _ c: Color = .white) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold, design: .rounded)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(c.opacity(0.18)))
    }

    @ViewBuilder var detail: some View {
        if let a = m.selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading) {
                        Text(a.name).font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
                        Text(a.lastUsed.map { TTF("Last used %@", T_, $0.formatted(date: .abbreviated, time: .omitted)) } ?? "").font(.system(size: 11)).opacity(0.65)
                    }
                }
                if a.isSystem { Text(TT("System app, cannot be uninstalled", T_)).font(.system(size: 12)).opacity(0.8) }
                else if a.running { Text(TT("Running: it will be quit first", T_)).font(.system(size: 12)).opacity(0.8) }
                Text(TT("Leftovers", T_)).font(.system(size: 13, weight: .semibold, design: .rounded)).opacity(0.8)
                if m.scanningLeftovers { ProgressView().controlSize(.small) }
                else if m.leftovers.isEmpty { Text(TT("No leftovers found", T_)).font(.system(size: 12)).opacity(0.65) }
                ScrollView { VStack(spacing: 4) { ForEach(m.leftovers) { l in leftoverRow(l) } } }
                if let r = m.results { resultView(r) }
                Button(TT("Uninstall", T_)) { m.confirming = true }.buttonStyle(PinkButton()).disabled(a.isSystem || m.busy)
            }.padding(16).glass().foregroundStyle(.white).transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            Text(TT("Select an app to see its leftovers", T_)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding().glass()
        }
    }

    func leftoverRow(_ l: Leftover) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { m.picked.contains(l.id) }, set: { m.togglePick(l.id, $0) }))
                .labelsHidden().disabled(l.readOnly)
            VStack(alignment: .leading, spacing: 1) {
                Text((l.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text((l.path as NSString).deletingLastPathComponent.replacingOccurrences(of: Env.home, with: "~")).font(.system(size: 10)).opacity(0.55).lineLimit(1)
            }
            Spacer()
            if l.readOnly { badge(TT("System-wide (read-only)", T_)) }
            else { badge(l.confidence == .high ? TT("Certain", T_) : l.confidence == .medium ? TT("Likely", T_) : TT("Maybe", T_),
                         l.confidence == .high ? .green : l.confidence == .medium ? .yellow : .gray) }
            Text(fmt(l.size)).font(.system(size: 11)).frame(width: 60, alignment: .trailing)
        }.padding(.vertical, 4)
    }

    func resultView(_ r: [Uninstaller.ItemResult]) -> some View {
        let ok = r.filter(\.ok).count, bad = r.count - ok
        return VStack(alignment: .leading, spacing: 2) {
            Text(TTF("Moved %d items to the Trash", T_, ok)).font(.system(size: 12, weight: .semibold))
            if bad > 0 { Text(TTF("%d items failed", T_, bad)).font(.system(size: 12)).foregroundStyle(Color(hex: 0xFF8FC8)) }
            ForEach(r.filter { !$0.ok }, id: \.path) { Text($0.error ?? "").font(.system(size: 10)).opacity(0.7).lineLimit(2) }
        }.transition(.opacity)
    }

    var confirmSheet: some View {
        ZStack {
            Background()
            VStack(alignment: .leading, spacing: 12) {
                Text(TTF("Uninstall %@?", T_, m.selected?.name ?? "")).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(TT("These items will be moved to the Trash. You can undo from the activity log.", T_)).font(.system(size: 12)).opacity(0.75)
                ScrollView { VStack(alignment: .leading, spacing: 4) {
                    if let a = m.selected { Text("\(a.name).app · \(fmt(a.size))").font(.system(size: 12, weight: .semibold)) }
                    ForEach(m.chosen) { Text("\(($0.path as NSString).lastPathComponent) · \(fmt($0.size))").font(.system(size: 12)).opacity(0.85) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.padding(10).glass(12)
                Text(TTF("Total: %@", T_, fmt(m.total))).font(.system(size: 14, weight: .semibold, design: .rounded))
                HStack {
                    Spacer()
                    if m.busy { ProgressView(TT("Moving to Trash…", T_)).controlSize(.small) }
                    Button(TT("Cancel", T_)) { m.confirming = false }.buttonStyle(SoftButton()).disabled(m.busy)
                    Button(TT("Uninstall", T_)) { m.uninstall() }.buttonStyle(PinkButton()).disabled(m.busy)
                }
            }.padding(22).foregroundStyle(.white)
        }.frame(width: 440, height: 380)
    }

    var batchSheet: some View {
        ZStack {
            Background()
            VStack(alignment: .leading, spacing: 12) {
                switch m.phase {
                case .confirm:
                    Text(TTF("Uninstall %d apps?", T_, m.entries.count)).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(TT("These items will be moved to the Trash. You can undo from the activity log.", T_)).font(.system(size: 12)).opacity(0.75)
                    ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(m.entries) { e in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(e.items) { Text("\(($0.path as NSString).lastPathComponent) · \(fmt($0.size))").font(.system(size: 11)).opacity(0.8) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        } label: { Text("\(e.app.name) · \(fmt(e.total))").font(.system(size: 12, weight: .semibold)) }
                    } }.frame(maxWidth: .infinity, alignment: .leading) }.padding(10).glass(12)
                    Toggle(TT("Quit running apps first", T_), isOn: $m.quitFirst).font(.system(size: 12))
                    Text(TTF("Total: %@", T_, fmt(m.entries.reduce(0) { $0 + $1.total }))).font(.system(size: 14, weight: .semibold, design: .rounded))
                    HStack {
                        Spacer()
                        Button(TT("Cancel", T_)) { m.phase = .idle }.buttonStyle(SoftButton())
                        Button(TT("Uninstall", T_)) { Task { await m.runBatch() } }.buttonStyle(PinkButton())
                    }
                case .running(let i, let n):
                    Spacer(); ProgressView(TTF("Removing %d of %d…", T_, i, n)).frame(maxWidth: .infinity); Spacer()
                case .done:
                    Text(TTF("Moved %d items to the Trash", T_, m.batchResults.reduce(0) { $0 + $1.items.filter(\.ok).count })).font(.system(size: 18, weight: .bold, design: .rounded))
                    ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(m.batchResults, id: \.app.id) { r in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(r.app.name).font(.system(size: 12, weight: .semibold)); Spacer()
                                badge(r.ok ? TT("Removed", T_) : r.app.isSystem ? TT("Refused", T_) : TT("Failed", T_), r.ok ? .green : Color(hex: 0xFF8FC8))
                            }
                            if let e = r.error { Text(e).font(.system(size: 10)).opacity(0.7).lineLimit(2) }
                        }
                    } }.frame(maxWidth: .infinity, alignment: .leading) }.padding(10).glass(12)
                    if let u = m.undoNote { Text(u).font(.system(size: 12)).opacity(0.8) }
                    HStack {
                        Spacer()
                        Button(TT("Undo", T_)) { m.undoBatch() }.buttonStyle(SoftButton()).disabled(m.undoNote != nil || !m.batchResults.contains { $0.items.contains(where: \.ok) })
                        Button(TT("Close", T_)) { m.phase = .idle }.buttonStyle(PinkButton())
                    }
                case .idle: EmptyView()
                }
            }.padding(22).foregroundStyle(.white)
        }.frame(width: 480, height: 460)
    }
}

final class FakeLaunchctl: Launchctl {
    var events: [String] = []; var fail = false; var existedAtBootout: [Bool] = []
    func bootout(plist: String) -> Result<Void, EngineError> { events.append("bootout:" + plist); existedAtBootout.append(FileManager.default.fileExists(atPath: plist)); return fail ? .failure(EngineError(message: "boom")) : .success(()) }
    func isLoaded(label: String) -> Bool { false }
}
final class FakeTerminator: AppTerminator {
    var running = true, quits = true; var events: [String] = []
    var onlyRunning: Set<String>?, refuse: Set<String> = []   // per-bundle overrides for batch tests
    func isRunning(bundleID: String) -> Bool { running && (onlyRunning?.contains(bundleID) ?? true) }
    func terminate(bundleID: String) -> Bool { events.append("terminate:" + bundleID); if quits && !refuse.contains(bundleID) { if onlyRunning != nil { onlyRunning!.remove(bundleID) } else { running = false }; return true }; return false }
}

enum AppsSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        func mkApp(_ name: String, _ bid: String, _ extra: [String: Any] = [:]) {
            let c = f.dir("home/Applications/\(name).app/Contents")
            var d: [String: Any] = ["CFBundleIdentifier": bid, "CFBundleName": name, "CFBundleShortVersionString": "1.2"]; d.merge(extra) { $1 }
            try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0).write(to: URL(fileURLWithPath: c + "/Info.plist"))
            f.file("home/Applications/\(name).app/Contents/MacOS/\(name)", kb: 16)
        }
        mkApp("Foo", "com.test.foo"); mkApp("Bar", "com.test.foobar"); mkApp("Sys", "com.apple.systhing")
        f.dir("home/Applications/Bar.app/Contents/_MASReceipt")
        let lib = "home/Library/"
        f.file(lib + "Application Support/com.test.foo/a.bin"); let hi2 = f.file(lib + "Caches/com.test.foo/b.bin")
        f.file(lib + "Preferences/com.test.foo.plist"); let med = f.file(lib + "Application Support/Foo/c.bin")
        let decoy = f.file(lib + "Caches/com.test.foobar/d.bin")
        f.file(lib + "LaunchAgents/com.test.foo.helper.plist")

        let apps = AppInventory.load(roots: [f.home + "/Applications"])
        t.reachedCode()
        t.check(apps.count == 3, "inventory finds 3 apps")
        guard let foo = apps.first(where: { $0.name == "Foo" }), let bar = apps.first(where: { $0.name == "Bar" }), let sys = apps.first(where: { $0.name == "Sys" }) else { t.check(false, "apps present"); return }
        t.check(foo.bundleID == "com.test.foo" && foo.version == "1.2" && foo.path == f.home + "/Applications/Foo.app", "foo fields")
        t.check(foo.size > 0 && foo.source == .other && !foo.isSystem && !foo.running, "foo size/source/system/running")
        t.check(bar.source == .appStore, "MAS receipt -> App Store")
        t.check(sys.isSystem, "com.apple.* flagged system")

        let ls = LeftoverMatcher.find(for: foo, home: f.home, systemDirs: [])
        t.reachedCode()
        func conf(_ p: String) -> Leftover.Confidence? { ls.first { $0.path == p }?.confidence }
        let L = f.home + "/Library/"
        t.check(Set(ls.filter { $0.confidence == .high }.map(\.path)) == [L + "Application Support/com.test.foo", L + "Caches/com.test.foo", L + "Preferences/com.test.foo.plist", L + "LaunchAgents/com.test.foo.helper.plist"], "bundle-id matches are exactly the 4 high")
        t.check(conf(f.home + "/Library/Application Support/Foo") == .medium, "app-name folder is medium")
        t.check(!ls.contains { $0.path.contains("foobar") }, "no loose prefix match (foobar decoy)")
        t.check(ls.first { $0.path.hasSuffix("com.test.foo") && $0.path.contains("Caches") }?.size ?? 0 > 0, "leftover size computed")
        t.check(LeftoverMatcher.confidence(entry: "com.test.foo2", bundleID: "com.test.foo", name: "Zzzzz") == nil, "foo2 not matched")
        t.check(LeftoverMatcher.confidence(entry: "ABCDE12345.com.test.foo", bundleID: "com.test.foo", name: "Zzzzz") == .high, "team-id prefix handled")

        let refused = await Uninstaller.uninstall(sys, [])
        t.check(refused.count == 1 && !refused[0].ok && FileManager.default.fileExists(atPath: sys.path), "system app refused")

        let high = ls.filter { $0.confidence == .high }
        let res = await Uninstaller.uninstall(foo, high)
        let fm = FileManager.default
        t.check(res.allSatisfy(\.ok) && res.count == 1 + high.count, "all items trashed ok")
        t.check(!fm.fileExists(atPath: foo.path) && !fm.fileExists(atPath: f.home + "/Library/Caches/com.test.foo"), "app + high leftovers gone")
        t.check(fm.fileExists(atPath: med) && fm.fileExists(atPath: decoy) && fm.fileExists(atPath: bar.path), "medium leftover, decoy and Bar untouched")
        let log = ActionLog.all()
        t.check(log.count == res.count && log.contains { $0.path == foo.path } && log.allSatisfy { $0.trashedTo.map { fm.fileExists(atPath: $0) } == true }, "actions logged, items in fake Trash")
        for e in log { try? Engine.undo(e) }
        t.check(fm.fileExists(atPath: foo.path) && fm.fileExists(atPath: hi2) && ActionLog.all().allSatisfy(\.undone), "undo restores everything")

        // injected launchctl / terminator: never touches the real system
        let fl = FakeLaunchctl(), ft = FakeTerminator()
        Uninstaller.launchctl = fl; Uninstaller.terminator = ft
        defer { Uninstaller.launchctl = SystemLaunchctl(); Uninstaller.terminator = SystemAppTerminator() }
        let plist = f.home + "/Library/LaunchAgents/com.test.foo.helper.plist"
        let sysPlist = "/Library/LaunchAgents/com.test.foo.helper.plist"
        let agent = Leftover(path: plist, size: 4096, confidence: .high, readOnly: false)
        let sysAgent = Leftover(path: sysPlist, size: 4096, confidence: .high, readOnly: true)

        ft.quits = false
        let r1 = await Uninstaller.uninstall(foo, [agent], quit: true)
        t.reachedCode()
        t.check(r1.count == 1 && !r1[0].ok && ft.events == ["terminate:com.test.foo"] && fl.events.isEmpty && fm.fileExists(atPath: foo.path) && fm.fileExists(atPath: plist), "app refuses to quit -> nothing trashed, error reported")
        ft.events = []; ft.running = true
        let r2 = await Uninstaller.uninstall(foo, [agent], quit: false)
        t.check(r2.count == 1 && !r2[0].ok && ft.events.isEmpty && fl.events.isEmpty && fm.fileExists(atPath: foo.path), "quit:false on running app -> refused, no terminate")
        ft.quits = true
        let r3 = await Uninstaller.uninstall(foo, [agent, sysAgent], quit: true)
        t.check(r3.allSatisfy(\.ok) && r3.count == 2 && ft.events == ["terminate:com.test.foo"], "running + quit:true -> terminated then trashed")
        t.check(fl.events == ["bootout:" + plist], "bootout only for the user LaunchAgent, never /Library")
        t.check(!fm.fileExists(atPath: foo.path) && !fm.fileExists(atPath: plist), "app and agent plist trashed")
        t.check(fl.existedAtBootout == [true], "bootout ran BEFORE the plist was trashed")

        // bootout failure keeps the plist
        let g = f.file("home/Library/LaunchAgents/com.test.foo.other.plist")
        fl.events = []; fl.fail = true; ft.running = false
        let bar2 = bar
        let r4 = await Uninstaller.uninstall(bar2, [Leftover(path: g, size: 4096, confidence: .high, readOnly: false)])
        t.check(fl.events == ["bootout:" + g] && fm.fileExists(atPath: g) && r4.contains { !$0.ok && $0.path == g }, "failed bootout -> plist not trashed, error reported")

        // ---- batch uninstall + cache model ----
        ft.running = true; ft.quits = true; ft.events = []; fl.fail = false; fl.events = []
        ft.onlyRunning = ["com.test.b2", "com.test.b3"]; ft.refuse = ["com.test.b3"]
        mkApp("B1", "com.test.b1"); mkApp("B2", "com.test.b2"); mkApp("B3", "com.test.b3")
        let b1c = f.file(lib + "Caches/com.test.b1/x.bin"), b2c = f.file(lib + "Caches/com.test.b2/x.bin"), b3c = f.file(lib + "Caches/com.test.b3/x.bin")
        let roots = [f.home + "/Applications"]
        let counter = LoadCounter()
        let finder: @Sendable (AppInfo) -> [Leftover] = { LeftoverMatcher.find(for: $0, home: f.home, systemDirs: []) }
        let m = AppsModel(loader: { counter.n += 1; return AppInventory.load(roots: roots) }, finder: finder)
        m.fillLastUsed = false
        await m.open(); await m.open()
        t.reachedCode()
        t.check(counter.n == 1 && m.scannedAt != nil && !m.stale, "opened twice -> ONE inventory load")
        await m.rescan()
        t.check(counter.n == 2, "explicit rescan -> second load")
        t.check(m.apps.contains { $0.name == "Sys" } && m.apps.count >= 4, "model lists fake apps")
        let byName = { (n: String) in m.apps.first { $0.name == n }! }
        m.toggle(byName("Sys"))
        t.check(m.selection.isEmpty, "system app cannot be selected")
        for n in ["B1", "B3", "B2"] { m.toggle(byName(n)) }
        m.selection.insert(byName("Sys").id)   // force a system app into the batch: must be refused, others proceed
        m.query = "b"; t.check(m.shown.allSatisfy { $0.name.lowercased().contains("b") } && m.selection.count == 4, "selection persists while filtering")
        m.query = "zzz"; t.check(m.shown.isEmpty && m.selection.count == 4, "selection persists with empty filter"); m.query = ""; m.sort = .name
        // user changes a leftover choice in the detail panel: B2's cache folder deselected
        m.select(byName("B2")); try? await Task.sleep(nanoseconds: 300_000_000)
        t.check(m.leftovers.contains { $0.path == b2c.replacingOccurrences(of: "/x.bin", with: "") } && !m.picked.isEmpty, "detail panel leftovers loaded with defaults")
        for l in m.leftovers { m.togglePick(l.id, false) }
        await m.prepareBatch()
        t.check(m.phase == .confirm && m.entries.count == 4 && m.entries.first { $0.app.name == "B2" }?.items.isEmpty == true && m.entries.first { $0.app.name == "B1" }?.items.count == 1, "plan lists apps; user's leftover change respected, defaults for the rest")
        await m.runBatch()
        let bres = Dictionary(uniqueKeysWithValues: m.batchResults.map { ($0.app.name, $0) })
        t.check(m.phase == .done && bres.count == 4, "result per app")
        t.check(bres["B1"]?.ok == true && bres["B2"]?.ok == true, "B1/B2 ok")
        t.check(bres["Sys"]?.ok == false && fm.fileExists(atPath: byName0(m, bres, "Sys")), "system app refused, still there")
        t.check(bres["B3"]?.ok == false && bres["B3"]?.error?.contains("quit") == true && fm.fileExists(atPath: f.home + "/Applications/B3.app") && fm.fileExists(atPath: b3c), "app refusing to quit -> failure reported, nothing of it trashed")
        t.check(!fm.fileExists(atPath: f.home + "/Applications/B1.app") && !fm.fileExists(atPath: b1c) && !fm.fileExists(atPath: f.home + "/Applications/B2.app") && fm.fileExists(atPath: b2c), "B1 + leftover trashed; B2 app trashed, deselected leftover kept")
        t.check(ActionLog.all().filter { !$0.undone && ($0.path.contains("B1") || $0.path.contains("B2") || $0.path.contains("b1")) }.allSatisfy { $0.trashedTo.map { fm.fileExists(atPath: $0) } == true }, "trashed items sit in the fake Trash")
        t.check(!m.apps.contains { $0.name == "B1" || $0.name == "B2" } && !m.selection.contains { $0.contains("B1") || $0.contains("B2") } && m.stale, "list + selection updated, stale set")
        t.check(ft.events.contains("terminate:com.test.b2") && ft.events.contains("terminate:com.test.b3"), "quit-first honoured")
        m.undoBatch()
        t.check(fm.fileExists(atPath: f.home + "/Applications/B1.app") && fm.fileExists(atPath: b1c) && fm.fileExists(atPath: f.home + "/Applications/B2.app") && m.undoNote != nil, "batch undo restores")

        // handleEngineChange in isolation
        let m2 = AppsModel(loader: { AppInventory.load(roots: roots) }, finder: finder); m2.fillLastUsed = false
        await m2.open(); t.check(!m2.stale, "fresh model not stale")
        let victim = m2.apps.first { $0.name == "B1" }!
        m2.selection = [victim.id]; m2.selected = victim
        m2.handleEngineChange(op: "trash", paths: [victim.path])
        t.check(!m2.apps.contains { $0.id == victim.id } && m2.selection.isEmpty && m2.selected == nil && m2.stale, "handleEngineChange drops the app, clears selection, sets stale")
        let missing = m2.apps.first { $0.name == "B3" }!
        try? fm.removeItem(atPath: missing.path)
        m2.handleEngineChange(op: "undo", paths: ["/nowhere"])
        t.check(!m2.apps.contains { $0.id == missing.id }, "app whose bundle vanished is dropped")
        let now = Date()
        t.check(AppsModel.relativeTime(now, now: now) == TT("just now", "Apps") && AppsModel.relativeTime(now.addingTimeInterval(-180), now: now) == TTF("%d min ago", "Apps", 3) && AppsModel.relativeTime(now.addingTimeInterval(-7300), now: now) == TTF("%d h ago", "Apps", 2) && AppsModel.relativeTime(now.addingTimeInterval(-200000), now: now) == TTF("%d d ago", "Apps", 2), "relative time helper")
    }
    static func byName0(_ m: AppsModel, _ r: [String: Uninstaller.AppResult], _ n: String) -> String { r[n]?.app.path ?? "" }
}

final class LoadCounter: @unchecked Sendable { var n = 0 }

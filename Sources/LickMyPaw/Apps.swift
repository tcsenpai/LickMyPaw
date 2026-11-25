import SwiftUI
import AppKit

@MainActor final class AppsModel: ObservableObject {
    enum Sort { case size, name }
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

    var shown: [AppInfo] {
        let q = query.lowercased()
        let l = apps.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        return sort == .size ? l.sorted { $0.size > $1.size } : l.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    var chosen: [Leftover] { leftovers.filter { picked.contains($0.id) && !$0.readOnly } }
    var total: Int64 { (selected?.size ?? 0) + chosen.reduce(0) { $0 + $1.size } }

    func reload() {
        loading = true
        Task.detached {
            let a = AppInventory.load()
            await MainActor.run { self.apps = a; self.loading = false }
            for app in a { // last-used is best effort, filled in progressively
                let d = AppInventory.lastUsed(app.path)
                await MainActor.run { if let i = self.apps.firstIndex(where: { $0.id == app.id }) { self.apps[i].lastUsed = d; if self.selected?.id == app.id { self.selected?.lastUsed = d } } }
            }
        }
    }

    func select(_ a: AppInfo) {
        selected = a; leftovers = []; picked = []; results = nil; scanningLeftovers = true
        Task.detached {
            let l = LeftoverMatcher.find(for: a)
            await MainActor.run {
                guard self.selected?.id == a.id else { return }
                self.leftovers = l; self.picked = Set(l.filter { $0.confidence == .high && !$0.readOnly }.map(\.id)); self.scanningLeftovers = false
            }
        }
    }

    func uninstall() {
        guard let a = selected else { return }
        busy = true; let ls = chosen
        Task {
            let r = await Uninstaller.uninstall(a, ls)
            busy = false; results = r; confirming = false
            if r.first?.ok == true { apps.removeAll { $0.id == a.id }; leftovers = []; picked = [] }
        }
    }
}

struct AppsView: View {
    @StateObject private var m = AppsModel()
    private let T_ = "Apps"
    var body: some View {
        ZStack {
            Background()
            HStack(alignment: .top, spacing: 16) {
                list.frame(maxWidth: .infinity)
                detail.frame(width: 340)
            }.padding(20)
        }
        .onAppear { if m.apps.isEmpty { m.reload() } }
        .sheet(isPresented: $m.confirming) { confirmSheet }
        .animation(spring, value: m.selected?.id)
    }

    var list: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack { Image(systemName: "magnifyingglass").opacity(0.7)
                    TextField(TT("Search apps", T_), text: $m.query).textFieldStyle(.plain) }
                    .padding(.horizontal, 12).padding(.vertical, 8).glass(16)
                Picker("", selection: $m.sort) { Text(TT("Size", T_)).tag(AppsModel.Sort.size); Text(TT("Name", T_)).tag(AppsModel.Sort.name) }
                    .pickerStyle(.segmented).frame(width: 150).labelsHidden()
            }
            if m.loading && m.apps.isEmpty { Spacer(); ProgressView(TT("Scanning applications…", T_)); Spacer() }
            else {
                ScrollView { LazyVStack(spacing: 6) { ForEach(m.shown) { row($0) } } }
            }
        }.foregroundStyle(.white)
    }

    func row(_ a: AppInfo) -> some View {
        HStack(spacing: 12) {
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
            Toggle("", isOn: Binding(get: { m.picked.contains(l.id) }, set: { if $0 { m.picked.insert(l.id) } else { m.picked.remove(l.id) } }))
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
}

final class FakeLaunchctl: Launchctl {
    var events: [String] = []; var fail = false; var existedAtBootout: [Bool] = []
    func bootout(plist: String) -> Result<Void, EngineError> { events.append("bootout:" + plist); existedAtBootout.append(FileManager.default.fileExists(atPath: plist)); return fail ? .failure(EngineError(message: "boom")) : .success(()) }
    func isLoaded(label: String) -> Bool { false }
}
final class FakeTerminator: AppTerminator {
    var running = true, quits = true; var events: [String] = []
    func isRunning(bundleID: String) -> Bool { running }
    func terminate(bundleID: String) -> Bool { events.append("terminate:" + bundleID); if quits { running = false }; return quits }
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
    }
}

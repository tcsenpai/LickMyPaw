import SwiftUI

@MainActor final class ProcessesModel: ObservableObject {
    @Published var mem: MemStats?
    @Published var pressure: Pressure = .normal
    @Published var groups: [ProcGroup] = []
    @Published var allUsers = false
    @Published var query = ""
    @Published var confirming: ProcGroup?
    @Published var message: String?
    let provider: ProcessSnapshotProvider, killer: ProcessKiller
    let ownPid = getpid(), myUid = getuid()
    private var all: [ProcInfo] = []
    init(provider: ProcessSnapshotProvider = LibprocProvider(), killer: ProcessKiller = RealKiller()) { self.provider = provider; self.killer = killer }
    var shown: [ProcGroup] { query.isEmpty ? groups : groups.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    func refresh() async {
        let p = provider
        let (snap, m) = await Task.detached { (p.snapshot(), MemoryReader.read()) }.value
        if Task.isCancelled { return }
        all = snap; regroup(); mem = m
        if let m { pressure = MemoryReader.pressure(level: MemoryReader.pressureLevel(), stats: m) }
    }
    func regroup() { withAnimation(spring) { groups = ProcessGrouping.group(all, onlyUid: allUsers ? nil : myUid) } }
    func quit(_ g: ProcGroup) {
        let r = ProcessGuard.quit(g, killer: killer, ownPid: ownPid, myUid: myUid)
        message = TTF("Asked %d process(es) to quit", "Processes", r.quit.count) + (r.refused.isEmpty ? "" : " · " + TTF("%d protected", "Processes", r.refused.count))
        confirming = nil
    }
}

struct ProcessesView: View {
    @StateObject private var m = ProcessesModel()
    var body: some View {
        VStack(spacing: 12) {
            memoryCard
            HStack(spacing: 10) {
                HStack { Image(systemName: "magnifyingglass").opacity(0.7); TextField(TT("Search processes", "Processes"), text: $m.query).textFieldStyle(.plain) }
                    .padding(.horizontal, 12).padding(.vertical, 8).glass(16)
                Picker("", selection: Binding(get: { m.allUsers }, set: { m.allUsers = $0; m.regroup() })) {
                    Text(TT("Mine", "Processes")).tag(false); Text(TT("All", "Processes")).tag(true)
                }.pickerStyle(.segmented).frame(width: 130).labelsHidden()
            }
            if let s = m.message { Text(s).font(.system(size: 12)).opacity(0.8) }
            ScrollView { LazyVStack(spacing: 6) { ForEach(m.shown) { row($0) } } }
        }
        .padding(20).foregroundStyle(.white)
        // Polls only while on screen: SwiftUI cancels this task on disappear.
        .task { while !Task.isCancelled { await m.refresh(); try? await Task.sleep(nanoseconds: 2_000_000_000) } }
        .sheet(item: Binding(get: { m.confirming }, set: { m.confirming = $0 })) { confirmSheet($0) }
    }
    var pColor: Color { m.pressure == .normal ? .green : m.pressure == .warning ? .yellow : .red }
    var pLabel: String { m.pressure == .normal ? TT("Memory pressure: normal", "Processes") : m.pressure == .warning ? TT("Memory pressure: elevated", "Processes") : TT("Memory pressure: critical", "Processes") }

    @ViewBuilder var memoryCard: some View {
        if let s = m.mem {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 10)
                    Circle().trim(from: 0, to: CGFloat(s.used) / CGFloat(s.total)).stroke(pColor, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int(Double(s.used) / Double(s.total) * 100))%").font(.system(size: 16, weight: .bold, design: .rounded))
                }.frame(width: 84, height: 84).animation(spring, value: s.used)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { Circle().fill(pColor).frame(width: 9, height: 9); Text(pLabel).font(.system(size: 13, weight: .semibold, design: .rounded)) }
                    Text(TTF("%@ used of %@", "Processes", fmt(Int64(s.used)), fmt(Int64(s.total)))).font(.system(size: 12)).opacity(0.8)
                    HStack(spacing: 14) {
                        stat(TT("App", "Processes"), s.app); stat(TT("Wired", "Processes"), s.wired); stat(TT("Compressed", "Processes"), s.compressed)
                        stat(TT("Cached", "Processes"), s.cached); stat(TT("Free", "Processes"), s.free)
                    }
                }
                Spacer()
            }.padding(16).glass()
        }
    }
    func stat(_ l: String, _ v: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(l).font(.system(size: 10)).opacity(0.6); Text(fmt(Int64(v))).font(.system(size: 12, weight: .medium, design: .rounded)) }
    }

    func row(_ g: ProcGroup) -> some View {
        let why = ProcessGuard.refusal(g, ownPid: m.ownPid, myUid: m.myUid)
        return HStack(spacing: 12) {
            Group {
                if let p = g.appPath { Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable() } else { Image(systemName: "terminal").resizable().scaledToFit().padding(6).opacity(0.7) }
            }.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.name).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(why ?? TTF("%d process(es)", "Processes", g.procs.count)).font(.system(size: 11)).opacity(0.6).lineLimit(1)
            }
            Spacer()
            Text(fmt(Int64(g.total))).font(.system(size: 13, weight: .medium, design: .rounded)).frame(width: 80, alignment: .trailing)
            Button(TT("Quit", "Processes")) { m.confirming = g }.buttonStyle(SoftButton()).disabled(why != nil).help(why ?? "")
        }.padding(10).glass(14)
    }

    func confirmSheet(_ g: ProcGroup) -> some View {
        VStack(spacing: 14) {
            Text(TTF("Quit %@?", "Processes", g.name)).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(TTF("%d process(es) will be asked to quit politely. Unsaved work in the app may be lost.", "Processes", g.procs.count)).font(.system(size: 12)).multilineTextAlignment(.center).opacity(0.8)
            HStack { Button(TT("Cancel", "Processes")) { m.confirming = nil }.buttonStyle(SoftButton()); Button(TT("Quit", "Processes")) { m.quit(g) }.buttonStyle(PinkButton()) }
        }.padding(24).frame(width: 360).foregroundStyle(.white)
    }
}
extension ProcGroup: Hashable { static func == (a: ProcGroup, b: ProcGroup) -> Bool { a.id == b.id }; func hash(into h: inout Hasher) { h.combine(id) } }

enum ProcessesSelfTest {
    struct Fake: ProcessSnapshotProvider { let p: [ProcInfo]; func snapshot() -> [ProcInfo] { p } }
    final class FakeKiller: ProcessKiller { var gui: [Int32] = [], term: [Int32] = []
        func terminateGUI(_ pid: Int32) -> Bool { gui.append(pid); return true }
        func sigterm(_ pid: Int32) -> Bool { term.append(pid); return true } }
    @MainActor static func run(_ t: TestCtx) async {
        let me: UInt32 = 501, own: Int32 = 4242
        let ps = [
            ProcInfo(pid: 100, uid: me, path: "/Applications/Foo.app/Contents/MacOS/Foo", resident: 300),
            ProcInfo(pid: 101, uid: me, path: "/Applications/Foo.app/Contents/Frameworks/X.app/Contents/Helper", resident: 200),
            ProcInfo(pid: 102, uid: me, path: "/Applications/Foo.app/Contents/Frameworks/Foo Helper", resident: 100),
            ProcInfo(pid: 200, uid: me, path: "/Applications/Bar.app/Contents/MacOS/Bar", resident: 50),
            ProcInfo(pid: 300, uid: me, path: "/opt/homebrew/bin/node", resident: 700),
            ProcInfo(pid: 301, uid: me, path: "/opt/homebrew/bin/node", resident: 100),
            ProcInfo(pid: 1, uid: 0, path: "/sbin/launchd", resident: 10),
            ProcInfo(pid: 400, uid: 0, path: "/Applications/Rooty.app/Contents/MacOS/Rooty", resident: 999),
            ProcInfo(pid: 500, uid: me, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", resident: 20),
            ProcInfo(pid: own, uid: me, path: "/Applications/LickMyPaw.app/Contents/MacOS/LickMyPaw", resident: 5),
        ]
        let g = ProcessGrouping.group(Fake(p: ps).snapshot(), onlyUid: me); t.reachedCode()
        let foo = g.first { $0.name == "Foo" }, node = g.first { $0.name == "node" }
        t.check(foo?.procs.count == 3 && foo?.total == 600, "nested helpers grouped under one .app and summed")
        t.check(node?.procs.count == 2 && node?.appPath == nil && node?.total == 800, "non-app processes grouped by executable")
        t.check(g.map(\.total) == g.map(\.total).sorted(by: >), "sorted by memory descending")
        t.check(!g.contains { $0.name == "Rooty" || $0.name == "launchd" }, "user filter hides root-owned")
        t.check(ProcessGrouping.group(ps, onlyUid: nil).contains { $0.name == "Rooty" }, "All shows root-owned")
        t.check(ProcessGrouping.appBundle("/a/B.app/Contents/X.app/y") == "/a/B.app", "outermost .app")
        let k = FakeKiller()
        for p in [ps[6], ps[7], ps[8], ps[9]] { t.check(ProcessGuard.refusal(p, ownPid: own, myUid: me) != nil, "refused: \(p.path)") }
        let refusedG = ProcGroup(id: "x", name: "x", appPath: nil, procs: [ps[6], ps[7], ps[8], ps[9]])
        let r = ProcessGuard.quit(refusedG, killer: k, ownPid: own, myUid: me)
        t.check(k.gui.isEmpty && k.term.isEmpty && r.quit.isEmpty, "killer NOT called for protected processes")
        if let foo { let r2 = ProcessGuard.quit(foo, killer: k, ownPid: own, myUid: me)
            t.check(Set(k.gui) == [100, 101, 102] && r2.quit.count == 3 && ProcessGuard.refusal(foo, ownPid: own, myUid: me) == nil, "killer called for normal user app") }
        if let s = MemoryReader.read() {
            t.check(s.total > 0 && s.used > 0 && s.used < s.total, "host_statistics64 plausible"); t.reachedCode()
            let sum = Double(s.used + s.cached + s.free) / Double(s.total)
            t.check(abs(sum - 1) < 0.02 && s.used + s.free <= s.total, "used+cached+free ≈ total")
        } else { t.check(false, "memory read failed") }
        let real = LibprocProvider().snapshot(); t.reachedCode()
        t.check(real.first { $0.pid == getpid() }.map { $0.resident > 0 } == true, "libproc returns current process with resident > 0")
        let z = MemStats(total: 100, used: 50, app: 0, wired: 0, compressed: 0, cached: 10, free: 40), lo = MemStats(total: 100, used: 95, app: 0, wired: 0, compressed: 0, cached: 2, free: 3)
        t.check(MemoryReader.pressure(level: 1, stats: lo) == .normal && MemoryReader.pressure(level: 2, stats: z) == .warning && MemoryReader.pressure(level: 4, stats: z) == .critical, "kernel level mapping")
        t.check(MemoryReader.pressure(level: nil, stats: z) == .normal && MemoryReader.pressure(level: nil, stats: lo) == .critical, "ratio fallback")
    }
}

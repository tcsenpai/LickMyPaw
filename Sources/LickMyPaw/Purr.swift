import SwiftUI

/// Purr = Smart Care. Read-only aggregation of the other modules; it NEVER deletes anything.
/// Every data source is a closure so tests inject fakes (no source has any write capability).
struct PurrSources {
    var disk: @Sendable () -> (total: Int64, free: Int64)?
    var cleanup: @MainActor () async -> Int64                       // reclaimable size of the pre-selected items
    var startup: @MainActor () async -> (agents: Int, broken: Int)  // user agents, broken launch items
    var memory: @Sendable () -> Pressure
    var fda: @Sendable () -> Permissions.Status

    @MainActor static func real() -> PurrSources {
        PurrSources(
            disk: {
                guard let v = try? URL(fileURLWithPath: Env.home).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
                      let t = v.volumeTotalCapacity, let f = v.volumeAvailableCapacityForImportantUsage else { return nil }
                return (Int64(t), f)
            },
            cleanup: {
                let m = CleanupModel.shared
                if !m.hasScanned { if m.phase != .scanning { m.scan() }; await m.scanTask?.value }
                return m.selectedSize
            },
            startup: {
                let m = StartupModel.shared
                if m.savedAt == nil { if !m.scanning { m.scan() }; var n = 0; while m.savedAt == nil && n < 150 { try? await Task.sleep(nanoseconds: 100_000_000); n += 1 } }
                return (m.items.filter { $0.kind == .userAgent }.count, m.items.filter(\.broken).count)
            },
            memory: { MemoryReader.read().map { MemoryReader.pressure(level: MemoryReader.pressureLevel(), stats: $0) } ?? .normal },
            fda: { Permissions.fullDiskAccess() })
    }
}

struct PurrReport {
    var disk: (total: Int64, free: Int64)?
    var cleanupBytes: Int64 = 0
    var startupAgents = 0, startupBroken = 0
    var pressure = Pressure.normal
    var fda = Permissions.Status.unknown
    var at = Date()

    static let cleanupLimit: Int64 = 500 * 1_000_000   // 500 MB
    var diskAttention: Bool { disk.map { $0.total > 0 && Double($0.free) / Double($0.total) < 0.15 } ?? false }
    var cleanupAttention: Bool { cleanupBytes > Self.cleanupLimit }
    var startupAttention: Bool { startupBroken > 0 }
    var memoryAttention: Bool { pressure != .normal }
    var fdaAttention: Bool { fda != .granted }
    var attentionCount: Int { [diskAttention, cleanupAttention, startupAttention, memoryAttention, fdaAttention].filter { $0 }.count }
}

@MainActor final class PurrModel: ObservableObject {
    static let shared = PurrModel()
    static let steps = ["Checking disk…", "Looking for junk…", "Checking startup items…", "Checking memory…", "Checking permissions…"]

    @Published var report: PurrReport?
    @Published var running = false
    @Published var stepsDone = 0          // 0...steps.count
    @Published var stale = false
    @Published var now = Date()
    var runs = 0                          // how many times the sources were actually read (tests)
    var sources: PurrSources
    var stepDelay: UInt64
    private var token: NSObjectProtocol?

    init(sources: PurrSources? = nil, stepDelay: UInt64 = 350_000_000) {
        self.sources = sources ?? .real(); self.stepDelay = stepDelay
        // queue: nil + hop to the main actor: `queue: .main` deadlocks when Engine.trash posts from the main thread.
        token = NotificationCenter.default.addObserver(forName: Engine.didChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in if self?.report != nil { self?.stale = true } }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    func run() async {
        guard !running else { return }
        running = true; stepsDone = 0; runs += 1
        var r = PurrReport(); let s = sources
        func tick() async { if stepDelay > 0 { try? await Task.sleep(nanoseconds: stepDelay) }; withAnimation(spring) { stepsDone += 1 } }
        r.disk = s.disk(); await tick()
        r.cleanupBytes = await s.cleanup(); await tick()
        (r.startupAgents, r.startupBroken) = await s.startup(); await tick()
        r.pressure = s.memory(); await tick()
        r.fda = s.fda(); await tick()
        r.at = Date(); now = r.at
        withAnimation(spring) { report = r; stale = false; running = false }
    }
}

struct PurrView: View {
    @ObservedObject private var m = PurrModel.shared

    private func ago(_ d: Date) -> String { CleanupModel.relative(d, now: m.now) }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if m.running { stepList.transition(.opacity.combined(with: .scale(scale: 0.97))) }
                else if let r = m.report { cards(r).transition(.opacity.combined(with: .move(edge: .bottom))) }
            }.padding(30).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .onAppear { m.now = Date() }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 12)
                Circle().trim(from: 0, to: Double(m.stepsDone) / Double(PurrModel.steps.count))
                    .stroke(AngularGradient(colors: [Color(hex: 0xFF3FA4), Color(hex: 0x9b5cff)], center: .center), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(spring, value: m.stepsDone)
                if m.running { PulseOrb() } else { Image(systemName: m.report.map { $0.attentionCount == 0 ? "checkmark" : "exclamationmark" } ?? "pawprint.fill").font(.system(size: 34, weight: .semibold)) }
            }.frame(width: 130, height: 130)
            if let r = m.report, !m.running {
                Text(r.attentionCount == 0 ? TT("Your Mac looks good", "Purr") : TTF("%d things need attention", "Purr", r.attentionCount))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .none; d.timeStyle = .short; return d }()
                Text(TTF("Scanned at %@ (%@): press Run again to refresh", "Purr", df.string(from: r.at), ago(r.at))).font(.system(size: 12, design: .rounded)).opacity(0.7)
                if m.stale { Text(TT("Updated after recent actions: run again", "Purr")).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Color(hex: 0xFFB84D)) }
            } else if !m.running {
                Text(TT("One click to check your whole Mac", "Purr")).font(.system(size: 20, weight: .semibold, design: .rounded))
            }
            Button(m.report == nil ? TT("Run Smart Scan", "Purr") : TT("Run again", "Purr")) { Task { await m.run() } }
                .buttonStyle(PinkButton()).disabled(m.running)
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(PurrModel.steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    Image(systemName: i < m.stepsDone ? "checkmark.circle.fill" : i == m.stepsDone ? "circle.dotted" : "circle")
                        .foregroundStyle(i < m.stepsDone ? Color(hex: 0x6EE7A8) : .white.opacity(0.5))
                    Text(TT(s, "Purr")).opacity(i <= m.stepsDone ? 1 : 0.5)
                }.font(.system(size: 14, design: .rounded)).animation(spring, value: m.stepsDone)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).glass()
    }

    private func cards(_ r: PurrReport) -> some View {
        let disk = r.disk.map { TTF("%@ free of %@", "Purr", fmt($0.free), fmt($0.total)) } ?? TT("Disk size unavailable", "Purr")
        let mem = r.pressure == .normal ? TT("Memory pressure is normal", "Purr") : r.pressure == .warning ? TT("Memory pressure is elevated", "Purr") : TT("Memory pressure is critical", "Purr")
        let fda = r.fda == .granted ? TT("Full Disk Access is granted", "Purr") : r.fda == .denied ? TT("Full Disk Access is not granted", "Purr") : TT("Full Disk Access could not be checked", "Purr")
        return VStack(spacing: 12) {
            card("internaldrive", TT("Disk", "Purr"), disk, r.diskAttention, "home")
            card("sparkles", TT("Cleanup", "Purr"), TTF("%@ can be cleaned safely", "Purr", fmt(r.cleanupBytes)), r.cleanupAttention, "cleanup")
            card("power", TT("Startup", "Purr"), TTF("%d user agents, %d broken", "Purr", r.startupAgents, r.startupBroken), r.startupAttention, "performance")
            card("memorychip", TT("Memory", "Purr"), mem, r.memoryAttention, "performance")
            card("lock.shield", TT("Permissions", "Purr"), fda, r.fdaAttention, "home")
        }
    }

    private func card(_ icon: String, _ title: String, _ text: String, _ attention: Bool, _ page: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 20)).frame(width: 42, height: 42)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(attention ? TT("Attention", "Purr") : TT("Good", "Purr")).font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(attention ? Color(hex: 0xFFB84D).opacity(0.35) : Color(hex: 0x6EE7A8).opacity(0.3)))
                }
                Text(text).font(.system(size: 13, design: .rounded)).opacity(0.75)
            }
            Spacer()
            Button(TT("Review", "Purr")) { Nav.go(page) }.buttonStyle(SoftButton())
        }.padding(16).glass()
    }
}

enum PurrSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        final class Counter: @unchecked Sendable { var n = 0 }
        let c = Counter()
        func src(free: Int64 = 50, cleanup: Int64 = 0, broken: Int = 0, p: Pressure = .normal, fda: Permissions.Status = .granted) -> PurrSources {
            PurrSources(disk: { c.n += 1; return (100, free) }, cleanup: { c.n += 1; return cleanup }, startup: { c.n += 1; return (3, broken) },
                        memory: { c.n += 1; return p }, fda: { c.n += 1; return fda })
        }
        func run(_ s: PurrSources) async -> PurrReport { let m = PurrModel(sources: s, stepDelay: 0); await m.run(); return m.report! }

        let good = await run(src()); t.reachedCode()
        t.check(good.attentionCount == 0, "good case: nothing needs attention")
        // thresholds: below / exact / above
        let d14 = await run(src(free: 14)), d15 = await run(src(free: 15)), d16 = await run(src(free: 16))
        t.check(d14.diskAttention && !d15.diskAttention && !d16.diskAttention, "disk: <15% attention, 15% and 16% fine")
        let lim = PurrReport.cleanupLimit
        let c0 = await run(src(cleanup: lim)), c1 = await run(src(cleanup: lim + 1))
        t.check(!c0.cleanupAttention && c1.cleanupAttention, "cleanup: >500 MB attention, exactly 500 MB fine")
        let b1 = await run(src(broken: 1)), b0 = await run(src(broken: 0))
        t.check(b1.startupAttention && !b0.startupAttention, "startup: any broken -> attention")
        let pw = await run(src(p: .warning)), pc = await run(src(p: .critical)), pn = await run(src(p: .normal))
        t.check(pw.memoryAttention && pc.memoryAttention && !pn.memoryAttention, "memory: yellow/red attention, green fine")
        let fd = await run(src(fda: .denied)), fu = await run(src(fda: .unknown)), fg = await run(src(fda: .granted))
        t.check(fd.fdaAttention && fu.fdaAttention && !fg.fdaAttention, "permissions: not granted -> attention")
        let all = await run(src(free: 5, cleanup: lim + 1, broken: 2, p: .critical, fda: .denied))
        t.check(all.attentionCount == 5 && good.attentionCount == 0, "summary counts: 5 attention vs 0")

        // cached: report kept, sources not re-read until run() again
        c.n = 0
        let m = PurrModel(sources: src(), stepDelay: 0)
        await m.run(); let after = c.n
        _ = m.report; _ = m.report
        t.check(after == 5 && c.n == after && m.runs == 1, "report cached: reading it does not re-run sources")
        // stale flag on Engine.didChange
        t.check(!m.stale, "fresh report not stale")
        Engine.announce("trash", ["/x"]); try? await Task.sleep(nanoseconds: 100_000_000)
        t.check(m.stale, "Engine.didChange marks report stale")
        await m.run(); t.check(!m.stale && m.runs == 2, "run again clears stale")
        let empty = PurrModel(sources: src(), stepDelay: 0)
        Engine.announce("trash", ["/y"]); try? await Task.sleep(nanoseconds: 100_000_000)
        t.check(!empty.stale, "no report yet -> not stale")
        // never destructive: sources are read-only closures; the action log stays empty on the fake home
        t.check(ActionLog.all().isEmpty, "Smart Scan never trashed anything (ActionLog empty)")
    }
}

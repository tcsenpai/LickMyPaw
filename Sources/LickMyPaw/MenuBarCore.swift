import Foundation
import Darwin
import ServiceManagement

// Menu bar, login item, notifications: the testable core (no UI, no UserNotifications, no AppKit).
//
// PERFORMANCE BUDGET (hard requirement, the app must never slow the machine down):
//  - The menu bar icon is a static SF Symbol. There is no live-updating label.
//  - Stats are sampled ONLY while the popover is open: 1 sample on open, then a 2 s timer (tolerance 0.5 s), stopped on close.
//    One sample = a few mach/sysctl calls (about 0.01 ms). The disk free read (URL resourceValues, ~14 ms because it accounts for
//    purgeable space) happens on open and then every 30 s only. No process enumeration, no shelling out. Budget: sample < 5 ms,
//    disk read < 50 ms; the selftest measures both and prints the numbers.
//  - Background: one tick at most every 5 minutes (tolerance 60 s) that reads the disk free value and nothing else. No directory
//    walks, no scans, no process lists. The Trash size is never computed in background: it is only evaluated when the Trash model
//    refreshes for its own reasons (the user opened the UI, or LickMyPaw itself changed the Trash).
//  - The tick timer exists only while a feature needs it (notifications or the daily update check). Idle = no timer, no work.

/// Everything stored in UserDefaults for these features, with the defaults documented in one place.
enum AppPrefs {
    private static var d: UserDefaults { .standard }
    static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    static func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
    static var menuBar: Bool { get { bool("menubar.enabled", true) } set { d.set(newValue, forKey: "menubar.enabled") } }
    static var notify: Bool { get { bool("notify.enabled", false) } set { d.set(newValue, forKey: "notify.enabled") } }
    static var updateAuto: Bool { get { bool("update.auto", true) } set { d.set(newValue, forKey: "update.auto") } }
    static var config: NotifyConfig {
        NotifyConfig(enabled: notify, diskPercent: num("notify.diskPercent", 10), diskGB: num("notify.diskGB", 10), trashGB: num("notify.trashGB", 5))
    }
    static func lastNotified(_ k: NotifyKind) -> Date? { (d.object(forKey: "notify.last." + k.rawValue) as? Double).map { Date(timeIntervalSince1970: $0) } }
    static func setLastNotified(_ k: NotifyKind, _ t: Date) { d.set(t.timeIntervalSince1970, forKey: "notify.last." + k.rawValue) }
    static var updateLastCheck: Date? {
        get { (d.object(forKey: "update.lastCheck") as? Double).map { Date(timeIntervalSince1970: $0) } }
        set { d.set(newValue?.timeIntervalSince1970, forKey: "update.lastCheck") }
    }
}

/// True only in a real, packaged GUI run. UNUserNotificationCenter crashes outside a proper bundle, and the headless/CLI/selftest
/// paths must never touch it (nor the network, nor the login item).
enum Runtime {
    static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && !Env.fake && !CommandLine.arguments.contains("--selftest")
    }
}

// MARK: - System stats (mach / sysctl, no processes spawned)

enum SysStats {
    struct CPUTicks { var busy: UInt64; var total: UInt64 }
    struct Sample {
        var diskFree: Int64, diskTotal: Int64
        var memUsed: Int64, memTotal: Int64
        var memLevel: Int          // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical
        var cpu: Double            // 0...1
    }
    private static let host = mach_host_self()   // one send right for the whole process, not one per sample

    /// Free/total of the startup volume. The only thing the background tick reads.
    static func disk() -> (free: Int64, total: Int64)? {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let t = v.volumeTotalCapacity, let f = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (f, Int64(t))
    }

    static func memory() -> (used: Int64, total: Int64) {
        var vm = vm_statistics64_data_t()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(host, HOST_VM_INFO64, $0, &cnt) } }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard r == KERN_SUCCESS else { return (0, total) }
        // Activity Monitor's "Memory Used": app memory (internal minus purgeable) + wired + compressed.
        let pages = Int64(vm.internal_page_count) - Int64(vm.purgeable_count) + Int64(vm.wire_count) + Int64(vm.compressor_page_count)
        return (min(max(pages, 0) * Int64(sysconf(_SC_PAGESIZE)), total), total)
    }

    static func pressureLevel() -> Int {
        var v: Int32 = 1, n = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &n, nil, 0) == 0 ? Int(v) : 1
    }

    static func ticks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var cnt = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cnt) } }
        guard r == KERN_SUCCESS else { return nil }
        let (u, s, i, n) = (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3))
        return CPUTicks(busy: u + s + n, total: u + s + i + n)
    }

    /// CPU use since the previous call; the first call falls back to the 1 minute load average per core.
    static func cpu(prev: inout CPUTicks?) -> Double {
        let now = ticks()
        defer { prev = now }
        if let p = prev, let n = now, n.total > p.total { return min(1, Double(n.busy &- p.busy) / Double(n.total - p.total)) }
        var l = [Double](repeating: 0, count: 1)
        return getloadavg(&l, 1) == 1 ? min(1, l[0] / Double(ProcessInfo.processInfo.activeProcessorCount)) : 0
    }

    /// `disk` is passed in: the "important usage" free-space read is the one expensive call (~14 ms, it accounts for purgeable
    /// space), so the popover reads it on open and then only every 30 s, while memory/CPU (about 0.01 ms) refresh every tick.
    static func sample(prev: inout CPUTicks?, disk d: (free: Int64, total: Int64)) -> Sample {
        let m = memory()
        return Sample(diskFree: d.free, diskTotal: d.total, memUsed: m.used, memTotal: m.total, memLevel: pressureLevel(), cpu: cpu(prev: &prev))
    }
}

// MARK: - Notification decision (pure)

enum NotifyKind: String, CaseIterable { case disk, trash }

struct NotifyConfig: Equatable {
    var enabled: Bool
    var diskPercent: Double   // notify when free space is below this percent of the volume ...
    var diskGB: Double        // ... or below this many GB (decimal, like Finder)
    var trashGB: Double       // notify when the Trash is larger than this; 0 disables
}

enum NotifyPolicy {
    static let minGap: TimeInterval = 24 * 3600   // at most one notification per kind per 24 h
    static let gb: Double = 1_000_000_000

    /// Which notifications should go out now. Pure: no clock, no defaults, no side effects.
    static func decide(cfg: NotifyConfig, free: Int64?, total: Int64?, trash: Int64?, now: Date, last: (NotifyKind) -> Date?) -> [NotifyKind] {
        guard cfg.enabled else { return [] }
        func due(_ k: NotifyKind) -> Bool { last(k).map { now.timeIntervalSince($0) >= minGap } ?? true }
        var out: [NotifyKind] = []
        if let f = free, let t = total, t > 0, due(.disk),
           Double(f) / Double(t) * 100 < cfg.diskPercent || Double(f) < cfg.diskGB * gb { out.append(.disk) }
        if let s = trash, cfg.trashGB > 0, Double(s) > cfg.trashGB * gb, due(.trash) { out.append(.trash) }
        return out
    }
}

/// Decide, then record and deliver. Delivery is injected: the real one is the UNUserNotificationCenter wrapper.
enum Notifier {
    static func evaluate(cfg: NotifyConfig, disk: (free: Int64, total: Int64)?, trash: Int64?, now: Date,
                         last: (NotifyKind) -> Date?, mark: (NotifyKind, Date) -> Void, send: (NotifyKind, Int64) -> Void) {
        for k in NotifyPolicy.decide(cfg: cfg, free: disk?.free, total: disk?.total, trash: trash, now: now, last: last) {
            mark(k, now); send(k, k == .disk ? (disk?.free ?? 0) : (trash ?? 0))
        }
    }
}

// MARK: - Background tick (disk free only)

enum BackgroundTick {
    static let interval: TimeInterval = 5 * 60
    static let tolerance: TimeInterval = 60
    /// True when anything needs the periodic tick. Otherwise no timer is installed at all.
    static func needed(cfg: NotifyConfig, updateAuto: Bool) -> Bool { cfg.enabled || updateAuto }

    /// One tick: the disk free value (one resourceValues read) and, if notifications are on, the decision. Nothing else.
    static func run(cfg: NotifyConfig, disk: () -> (free: Int64, total: Int64)?, now: Date,
                    last: (NotifyKind) -> Date?, mark: (NotifyKind, Date) -> Void, send: (NotifyKind, Int64) -> Void) {
        guard cfg.enabled else { return }
        Notifier.evaluate(cfg: cfg, disk: disk(), trash: nil, now: now, last: last, mark: mark, send: send)   // trash: never scanned here
    }
}

// MARK: - Dock / activation policy (pure rule)

enum ActivationRule {
    enum Policy { case regular, accessory }
    /// Menu bar on and no window left: live in the menu bar only (no Dock icon). Otherwise a normal app.
    static func policy(menuBarOn: Bool, visibleWindows: Int) -> Policy { menuBarOn && visibleWindows == 0 ? .accessory : .regular }
}

// MARK: - Login item

enum LoginState: Equatable {
    case off, on, needsApproval, notFound
    init(_ s: SMAppService.Status) {
        switch s { case .enabled: self = .on; case .requiresApproval: self = .needsApproval; case .notFound: self = .notFound; default: self = .off }
    }
    /// What the toggle shows: registered (even if the user still has to approve it in System Settings) counts as on.
    var toggleOn: Bool { self == .on || self == .needsApproval }
}

enum LoginItem {
    static var state: LoginState { LoginState(SMAppService.mainApp.status) }
    /// nil on success, otherwise the error text. Only ever called from the Settings toggle in a packaged app.
    static func set(_ on: Bool) -> String? {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; return nil }
        catch { return error.localizedDescription }
    }
}

// MARK: - Selftests

enum MenuBarSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        // 1. cost of one sample (disk read is cached by the popover, measured separately)
        var prev: SysStats.CPUTicks?
        let dk = SysStats.disk() ?? (0, 0)
        _ = SysStats.sample(prev: &prev, disk: dk)   // warm-up
        let n = 200, t0 = DispatchTime.now().uptimeNanoseconds
        var s = SysStats.sample(prev: &prev, disk: dk)
        for _ in 1..<n { s = SysStats.sample(prev: &prev, disk: dk) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(n)
        let d0 = DispatchTime.now().uptimeNanoseconds; _ = SysStats.disk()
        let diskMs = Double(DispatchTime.now().uptimeNanoseconds - d0) / 1e6
        print(String(format: "  info one sample costs %.4f ms (budget 5 ms); the disk free read costs %.2f ms (budget 50 ms, on open and every 30 s only)", ms, diskMs))
        t.check(ms < 5, "one stats sample costs under 5 ms (\(String(format: "%.4f", ms)) ms)"); t.reachedCode()
        t.check(diskMs < 50, "disk free read under 50 ms (\(String(format: "%.2f", diskMs)) ms)")
        t.check(s.diskTotal > 0 && s.diskFree > 0 && s.diskFree <= s.diskTotal, "disk free/total read via resourceValues")
        t.check(s.memTotal > 0 && s.memUsed > 0 && s.memUsed <= s.memTotal, "memory used within total (\(fmt(s.memUsed)) of \(fmt(s.memTotal)))")
        t.check([1, 2, 4].contains(s.memLevel), "pressure level is one of 1/2/4 (\(s.memLevel))")
        t.check(s.cpu >= 0 && s.cpu <= 1, "cpu fraction in 0...1 (\(String(format: "%.2f", s.cpu)))")
        var none: SysStats.CPUTicks?
        let first = SysStats.cpu(prev: &none)
        t.check(none != nil && first >= 0 && first <= 1, "first cpu reading falls back to load average and seeds the baseline")

        // 2. sampling lifecycle: idle until the popover opens, one timer, stops on close
        let m = MenuBarModel()
        t.check(!m.isSampling && m.sample == nil, "creating the model samples nothing and starts no timer"); t.reachedCode()
        m.start(); m.start()
        t.check(m.isSampling && m.sample != nil && m.timerInterval == 2 && m.timerTolerance > 0, "start: sample at once, 2 s timer with tolerance, never duplicated")
        m.stop()
        t.check(!m.isSampling, "stop cancels the timer")

        // 3. background tick: disk free only, no scan, nothing when idle
        let cfgOn = NotifyConfig(enabled: true, diskPercent: 10, diskGB: 10, trashGB: 5), cfgOff = NotifyConfig(enabled: false, diskPercent: 10, diskGB: 10, trashGB: 5)
        var diskReads = 0, sent: [NotifyKind] = [], marks = 0
        let tt0 = DispatchTime.now().uptimeNanoseconds
        BackgroundTick.run(cfg: cfgOff, disk: { diskReads += 1; return nil }, now: Date(), last: { _ in nil }, mark: { _, _ in marks += 1 }, send: { k, _ in sent.append(k) })
        t.check(diskReads == 0 && sent.isEmpty && marks == 0, "tick with notifications off does no work at all"); t.reachedCode()
        BackgroundTick.run(cfg: cfgOn, disk: { diskReads += 1; return (5_000_000_000, 500_000_000_000) }, now: Date(), last: { _ in nil }, mark: { _, _ in marks += 1 }, send: { k, _ in sent.append(k) })
        let tickMs = Double(DispatchTime.now().uptimeNanoseconds - tt0) / 1e6
        print(String(format: "  info background tick costs %.3f ms", tickMs))
        t.check(diskReads == 1 && sent == [.disk] && marks == 1, "tick reads disk free exactly once and notifies")
        t.check(tickMs < 5, "background tick under 5 ms")
        // the tick never walks a directory: a fake Trash full of files is invisible to it
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        for i in 0..<200 { f.file("home/.Trash/f\(i).bin", kb: 1) }
        sent = []
        BackgroundTick.run(cfg: NotifyConfig(enabled: true, diskPercent: 10, diskGB: 10, trashGB: 0.0000001), disk: { (400_000_000_000, 500_000_000_000) }, now: Date(), last: { _ in nil }, mark: { _, _ in }, send: { k, _ in sent.append(k) })
        t.check(sent.isEmpty, "tick never looks at the Trash (no directory walk in background)")
        t.check(!BackgroundTick.needed(cfg: cfgOff, updateAuto: false) && BackgroundTick.needed(cfg: cfgOn, updateAuto: false) && BackgroundTick.needed(cfg: cfgOff, updateAuto: true), "tick timer only needed when a feature uses it")
        t.check(BackgroundTick.interval >= 300 && BackgroundTick.tolerance > 0, "tick interval is at least 5 minutes with tolerance")

        // 4. activation policy and login state mapping
        t.check(ActivationRule.policy(menuBarOn: true, visibleWindows: 0) == .accessory, "menu bar on, last window closed: stay in the menu bar only"); t.reachedCode()
        t.check(ActivationRule.policy(menuBarOn: true, visibleWindows: 1) == .regular && ActivationRule.policy(menuBarOn: false, visibleWindows: 0) == .regular, "otherwise a normal Dock app")
        t.check(LoginState(.enabled) == .on && LoginState(.requiresApproval) == .needsApproval && LoginState(.notFound) == .notFound && LoginState(.notRegistered) == .off, "SMAppService status mapping")
        t.check(LoginState.needsApproval.toggleOn && LoginState.on.toggleOn && !LoginState.off.toggleOn && !LoginState.notFound.toggleOn, "toggle shows registered items as on")
        t.check(!Runtime.isPackagedApp, "headless runs are never treated as a packaged app (no UNUserNotificationCenter, no network)")
    }
}

enum NotifySelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cfg = NotifyConfig(enabled: true, diskPercent: 10, diskGB: 10, trashGB: 5)
        let tb: Int64 = 1_000_000_000_000   // 1 TB volume: 10 percent = 100 GB, so the GB rule is the lower one below 10 GB
        func d(_ free: Int64, total: Int64 = tb, trash: Int64? = nil, c: NotifyConfig = cfg, last: [NotifyKind: Date] = [:]) -> [NotifyKind] {
            NotifyPolicy.decide(cfg: c, free: free, total: total, trash: trash, now: now, last: { last[$0] })
        }
        // percent boundary (10 percent of 1 TB = 100 GB) with the GB rule neutralised
        let pct = NotifyConfig(enabled: true, diskPercent: 10, diskGB: 0, trashGB: 0)
        t.check(d(99_999_999_999, c: pct) == [.disk], "just below 10 percent notifies"); t.reachedCode()
        t.check(d(100_000_000_000, c: pct).isEmpty, "exactly 10 percent does not")
        t.check(d(100_000_000_001, c: pct).isEmpty, "just above 10 percent does not")
        // GB boundary with the percent rule neutralised
        let gbc = NotifyConfig(enabled: true, diskPercent: 0, diskGB: 10, trashGB: 0)
        t.check(d(9_999_999_999, c: gbc) == [.disk] && d(10_000_000_000, c: gbc).isEmpty && d(10_000_000_001, c: gbc).isEmpty, "10 GB boundary: below / exact / above")
        t.check(d(200_000_000_000).isEmpty, "plenty of space (20 percent, 200 GB): nothing")
        t.check(d(5_000_000_000) == [.disk], "either rule is enough (5 GB free)")
        // out-of-range configuration is harmless
        t.check(d(5_000_000_000, total: 0).isEmpty && NotifyPolicy.decide(cfg: cfg, free: nil, total: nil, trash: nil, now: now, last: { _ in nil }).isEmpty, "unknown or zero-sized volume never notifies")
        // 24 h rate limit
        let h = 3600.0
        t.check(d(1, last: [.disk: now.addingTimeInterval(-23.99 * h)]).isEmpty, "inside 24 h: rate limited"); t.reachedCode()
        t.check(d(1, last: [.disk: now.addingTimeInterval(-24 * h)]) == [.disk], "exactly 24 h later: allowed again")
        t.check(d(1, last: [.disk: now.addingTimeInterval(-48 * h)]) == [.disk], "long ago: allowed")
        t.check(d(1, last: [.disk: now.addingTimeInterval(+h)]).isEmpty, "a last-sent time in the future (clock moved back) stays limited")
        // trash rule
        t.check(d(tb / 2, trash: 5_000_000_001) == [.trash] && d(tb / 2, trash: 5_000_000_000).isEmpty && d(tb / 2, trash: 4_999_999_999).isEmpty, "Trash threshold: above / exact / below")
        t.check(d(tb / 2, trash: 50_000_000_000, c: NotifyConfig(enabled: true, diskPercent: 10, diskGB: 10, trashGB: 0)).isEmpty, "trash threshold 0 disables the Trash notification")
        t.check(d(1, trash: 9_000_000_000, last: [.disk: now.addingTimeInterval(-h)]) == [.trash], "kinds are rate limited independently")
        t.check(Set(d(1, trash: 9_000_000_000)) == [.disk, .trash], "both can fire together")
        t.check(d(1, trash: 9_000_000_000, c: NotifyConfig(enabled: false, diskPercent: 10, diskGB: 10, trashGB: 5)).isEmpty, "disabled means silent")
        // evaluate: records and sends once, then holds for 24 h
        var last: [NotifyKind: Date] = [:], sent: [(NotifyKind, Int64)] = []
        func ev(_ at: Date) { Notifier.evaluate(cfg: cfg, disk: (1_000_000_000, tb), trash: nil, now: at, last: { last[$0] }, mark: { last[$0] = $1 }, send: { sent.append(($0, $1)) }) }
        ev(now); ev(now.addingTimeInterval(3 * h)); ev(now.addingTimeInterval(23 * h))
        t.check(sent.count == 1 && sent[0].0 == .disk && sent[0].1 == 1_000_000_000, "evaluate sends once and carries the free bytes"); t.reachedCode()
        ev(now.addingTimeInterval(25 * h))
        t.check(sent.count == 2, "after 24 h it sends again")
        t.check(!NotifyCenter.available, "headless: the notification center is never touched")
        t.check(NotifyCenter.title(.disk) != "" && NotifyCenter.body(.disk, bytes: 1_000_000_000).contains(fmt(1_000_000_000)) && NotifyCenter.body(.trash, bytes: 6_000_000_000).contains(fmt(6_000_000_000)), "notification texts mention the sizes")
        // i18n parity for this feature's table
        for l in Prefs.languages {
            let keys = SystemStrings.keys(lang: l)
            t.check(keys == SystemStrings.keys(lang: "en") && !keys.isEmpty, "System.strings keys match English in \(l) (\(keys.count))")
        }
    }
}

/// Reads a language's System.strings keys straight from the resource bundle, for the parity check.
enum SystemStrings {
    static func keys(lang: String) -> Set<String> {
        guard let p = L10n.resourceBundle.path(forResource: "System", ofType: "strings", inDirectory: nil, forLocalization: lang),
              let d = NSDictionary(contentsOfFile: p) as? [String: String] else { return [] }
        return Set(d.keys)
    }
}

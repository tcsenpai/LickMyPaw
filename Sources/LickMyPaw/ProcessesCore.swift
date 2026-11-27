import Foundation
import Darwin

struct ProcInfo: Equatable { let pid: Int32; let uid: UInt32; let path: String; let resident: UInt64 }

protocol ProcessSnapshotProvider { func snapshot() -> [ProcInfo] }

/// Real provider: libproc, read-only.
struct LibprocProvider: ProcessSnapshotProvider {
    func snapshot() -> [ProcInfo] {
        let n = proc_listallpids(nil, 0); guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var out: [ProcInfo] = []
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            var ti = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
            var bi = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            let path = len > 0 ? String(cString: buf) : withUnsafePointer(to: bi.pbi_comm) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            out.append(ProcInfo(pid: pid, uid: bi.pbi_uid, path: path, resident: ti.pti_resident_size))
        }
        return out
    }
}

struct ProcGroup: Identifiable {
    let id: String          // outermost .app path, or executable path for non-app processes
    let name: String
    let appPath: String?
    let procs: [ProcInfo]
    var total: UInt64 { procs.reduce(0) { $0 + $1.resident } }
}

enum ProcessGrouping {
    /// Path up to and including the outermost `.app`, if any.
    static func appBundle(_ path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let i = comps.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + comps[...i].joined(separator: "/")
    }
    /// Executables named only by their version (…/claude/versions/2.1.331) are shown by the first folder with a real name.
    static func readableName(_ path: String) -> String {
        let parts = (path as NSString).pathComponents.filter { $0 != "/" }
        guard let last = parts.last, !last.contains(where: \.isLetter) else { return parts.last ?? "" }
        let skip: Set<String> = ["versions", "version", "bin", "current", "libexec"]
        return parts.dropLast().reversed().first { $0.contains(where: \.isLetter) && !skip.contains($0.lowercased()) }.map { "\($0) \(last)" } ?? last
    }
    static func group(_ procs: [ProcInfo], onlyUid: UInt32?) -> [ProcGroup] {
        var buckets: [String: [ProcInfo]] = [:]
        for p in procs where onlyUid == nil || p.uid == onlyUid { buckets[appBundle(p.path) ?? p.path, default: []].append(p) }
        return buckets.map { key, ps in
            let app = appBundle(ps[0].path) != nil
            let name = app ? (key as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") : readableName(key)
            return ProcGroup(id: key, name: name.isEmpty ? "?" : name, appPath: app ? key : nil, procs: ps)
        }.sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
    }
}

protocol ProcessKiller {
    /// true if pid is a GUI app that was asked to quit politely
    func terminateGUI(_ pid: Int32) -> Bool
    /// polite SIGTERM, never SIGKILL
    func sigterm(_ pid: Int32) -> Bool
}
import AppKit
struct RealKiller: ProcessKiller {
    func terminateGUI(_ pid: Int32) -> Bool {
        guard let a = NSRunningApplication(processIdentifier: pid), a.activationPolicy != .prohibited else { return false }
        return a.terminate()
    }
    func sigterm(_ pid: Int32) -> Bool { kill(pid, SIGTERM) == 0 }
}

enum ProcessGuard {
    static let protectedPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/", "/Library/Apple/"]
    static let protectedNames: Set<String> = ["launchd", "WindowServer", "loginwindow", "kernel_task", "Finder", "Dock", "SystemUIServer"]
    /// nil = allowed; otherwise a localized reason shown in the UI.
    static func refusal(_ p: ProcInfo, ownPid: Int32, myUid: UInt32) -> String? {
        let name = (p.path as NSString).lastPathComponent
        if p.pid <= 1 || protectedNames.contains(name) { return TT("Essential system process", "Processes") }
        if p.pid == ownPid { return TT("This is LickMyPaw itself", "Processes") }
        if p.uid == 0 || p.uid != myUid { return TT("Owned by root or another user", "Processes") }
        if protectedPrefixes.contains(where: { p.path.hasPrefix($0) }) { return TT("Apple system process", "Processes") }
        return nil
    }
    /// Group-level refusal: nil when at least one process may be quit and none is LickMyPaw itself.
    static func refusal(_ g: ProcGroup, ownPid: Int32, myUid: UInt32) -> String? {
        let rs = g.procs.map { refusal($0, ownPid: ownPid, myUid: myUid) }
        if g.procs.contains(where: { $0.pid == ownPid }) { return TT("This is LickMyPaw itself", "Processes") }
        return rs.contains(where: { $0 == nil }) ? nil : rs.compactMap { $0 }.first
    }
    /// Quits the allowed processes of a group. Refused ones are never handed to the killer.
    static func quit(_ g: ProcGroup, killer: ProcessKiller, ownPid: Int32, myUid: UInt32) -> (quit: [Int32], refused: [Int32]) {
        if g.procs.contains(where: { $0.pid == ownPid }) { return ([], g.procs.map(\.pid)) }
        var q: [Int32] = [], r: [Int32] = []
        for p in g.procs {
            if refusal(p, ownPid: ownPid, myUid: myUid) != nil { r.append(p.pid); continue }
            if killer.terminateGUI(p.pid) || killer.sigterm(p.pid) { q.append(p.pid) }
        }
        return (q, r)
    }
}

struct MemStats { var total: UInt64 = 0, used: UInt64 = 0, app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0, free: UInt64 = 0 }
enum Pressure { case normal, warning, critical }

enum MemoryReader {
    static func read() -> MemStats? {
        if Demo.enabled { return Demo.mem }
        var total: UInt64 = 0; var sz = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &sz, nil, 0) == 0, total > 0 else { return nil }
        var vm = vm_statistics64(); var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt) } }
        guard kr == KERN_SUCCESS else { return nil }
        let ps = UInt64(vm_kernel_page_size)
        let wired = UInt64(vm.wire_count) * ps, comp = UInt64(vm.compressor_page_count) * ps
        let purg = UInt64(vm.purgeable_count) * ps
        let app = UInt64(vm.internal_page_count) * ps - min(purg, UInt64(vm.internal_page_count) * ps)
        let cached = UInt64(vm.external_page_count) * ps + purg
        let used = min(total, app + wired + comp)
        return MemStats(total: total, used: used, app: app, wired: wired, compressed: comp, cached: min(cached, total - used), free: total - used - min(cached, total - used))
    }
    static func pressureLevel() -> Int32? {
        var l: Int32 = 0; var sz = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &l, &sz, nil, 0) == 0 ? l : nil
    }
    /// kernel level 1/2/4 -> state; unknown/absent -> ratio of (free+cached) to total.
    static func pressure(level: Int32?, stats: MemStats) -> Pressure {
        switch level { case 1: return .normal; case 2: return .warning; case 4: return .critical; default: break }
        guard stats.total > 0 else { return .normal }
        let avail = Double(stats.free + stats.cached) / Double(stats.total)
        return avail < 0.08 ? .critical : avail < 0.2 ? .warning : .normal
    }
}

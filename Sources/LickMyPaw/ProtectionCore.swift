import Foundation

// Engine layer: ClamAV (GPLv2) is used ONLY as an external child process. No ClamAV code is linked or bundled (keeps this project MIT).

struct Detection: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let signature: String
    var size: Int64 = 0
}

struct ScanReport {
    var detections: [Detection] = []
    var errors: [String] = []
    var cancelled = false, timedOut = false
    var failure: String?          // engine could not run at all
    var duration: TimeInterval = 0
}

enum EngineStatus: Equatable {
    case missing
    case noDatabase(String)       // engine path
    case ready(path: String, version: String, dbAgeDays: Int?)
    var path: String? { switch self { case .missing: return nil; case .noDatabase(let p): return p; case .ready(let p, _, _): return p } }
}

final class CancelFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    var isSet: Bool { l.lock(); defer { l.unlock() }; return v }
    func set() { l.lock(); v = true; l.unlock() }
}

protocol ScanEngine: Sendable {
    var name: String { get }
    func availability() -> EngineStatus
    func scan(paths: [String], progress: @escaping @Sendable (Detection) -> Void, cancel: CancelFlag) async -> ScanReport
    func updateDatabase(onLine: @escaping @Sendable (String) -> Void, cancel: CancelFlag) async -> (ok: Bool, summary: String)
}

// MARK: process runner (no shell, argv only)

struct ProcResult { var status: Int32 = -1; var output = ""; var timedOut = false; var cancelled = false; var launchError: String? }

enum ProcRunner {
    /// Runs exe with argv (never through a shell), merges stdout+stderr, streams complete lines to onLine. SIGTERM on cancel/timeout.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval, cancel: CancelFlag? = nil, onLine: (@Sendable (String) -> Void)? = nil) -> ProcResult {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        var res = ProcResult()
        do { try p.run() } catch { res.launchError = error.localizedDescription; return res }
        let flags = FlagBox()
        let deadline = Date().addingTimeInterval(timeout)
        let watch = Thread {
            while p.isRunning {
                if cancel?.isSet == true { flags.cancelled = true; p.terminate(); return }
                if Date() > deadline { flags.timedOut = true; p.terminate(); return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        watch.start()
        var buf = Data(), all = Data()
        let h = pipe.fileHandleForReading
        while true {
            let d = h.availableData
            if d.isEmpty { break }
            all.append(d); buf.append(d)
            while let nl = buf.firstIndex(of: 10) {
                let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                buf.removeSubrange(buf.startIndex...nl); onLine?(line)
            }
        }
        if !buf.isEmpty { onLine?(String(decoding: buf, as: UTF8.self)) }
        p.waitUntilExit()
        res.status = p.terminationStatus; res.output = String(decoding: all, as: UTF8.self)
        res.timedOut = flags.timedOut; res.cancelled = flags.cancelled
        return res
    }
    private final class FlagBox: @unchecked Sendable { var timedOut = false, cancelled = false }
}

// MARK: parser (pure)

enum ClamParser {
    struct Parsed: Equatable { var detections: [Detection] = []; var errors: [String] = [] }
    /// 'path: Signature FOUND' (paths may contain spaces and colons: split at the LAST ": ").
    /// Error lines ('ERROR' suffix or prefix, 'WARNING', 'Operation not permitted') go to errors; the rest is ignored.
    static func parse(_ out: String) -> Parsed {
        var r = Parsed()
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(" FOUND") {
                let body = String(line.dropLast(6))
                guard let sep = body.range(of: ": ", options: .backwards) else { continue }
                let path = String(body[..<sep.lowerBound]), sig = String(body[sep.upperBound...])
                if path.hasPrefix("/"), !sig.isEmpty { r.detections.append(Detection(path: path, signature: sig)) }
            } else if line.hasSuffix(" ERROR") || line.hasPrefix("ERROR") || line.hasPrefix("WARNING") || line.contains("Operation not permitted") {
                r.errors.append(line)
            }
        }
        return r
    }
}

// MARK: ClamAV (external process)

struct ClamAVEngine: ScanEngine {
    var name: String { "ClamAV" }
    var searchDirs: [String]
    var dbDirs: [String]
    var exclusions: @Sendable () -> [String] = { Prefs.exclusions }
    var scanTimeout: TimeInterval = 3 * 3600

    static let defaultDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    static let defaultDBDirs = ["/opt/homebrew/var/lib/clamav", "/usr/local/var/lib/clamav", "/opt/local/share/clamav", "/var/lib/clamav"]
    init(searchDirs: [String]? = nil, dbDirs: [String]? = nil) {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        self.searchDirs = searchDirs ?? (Self.defaultDirs + path)
        self.dbDirs = dbDirs ?? Self.defaultDBDirs
    }

    func find(_ tool: String) -> String? {
        searchDirs.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func availability() -> EngineStatus {
        guard let bin = find("clamscan") else { return .missing }
        let fm = FileManager.default
        var newest: Date?
        for d in dbDirs { for n in ["daily.cvd", "daily.cld"] {
            if let m = (try? fm.attributesOfItem(atPath: d + "/" + n))?[.modificationDate] as? Date, newest == nil || m > newest! { newest = m }
        } }
        guard let dbDate = newest else { return .noDatabase(bin) }
        let v = ProcRunner.run(bin, ["--version"], timeout: 10)
        let version = v.output.split(separator: "\n").first.map(String.init) ?? "ClamAV"
        return .ready(path: bin, version: version, dbAgeDays: max(0, Int(Date().timeIntervalSince(dbDate) / 86400)))
    }

    static func args(paths: [String], exclusions: [String]) -> [String] {
        ["-r", "--infected", "--stdout", "--no-summary", "--max-filesize=200M", "--max-scansize=500M"]
            + exclusions.map { "--exclude-dir=^" + NSRegularExpression.escapedPattern(for: $0) } + paths
    }

    func scan(paths: [String], progress: @escaping @Sendable (Detection) -> Void, cancel: CancelFlag) async -> ScanReport {
        guard let bin = find("clamscan") else { var r = ScanReport(); r.failure = "ClamAV not found"; return r }
        let ex = exclusions(), timeout = scanTimeout
        return await Task.detached {
            let t0 = Date()
            var seen: [Detection] = []
            let r = ProcRunner.run(bin, Self.args(paths: paths, exclusions: ex), timeout: timeout, cancel: cancel) { line in
                if let d = ClamParser.parse(line).detections.first { progress(d) }
            }
            let parsed = ClamParser.parse(r.output)
            seen = parsed.detections.map { var d = $0; d.size = ((try? FileManager.default.attributesOfItem(atPath: d.path)[.size]) as? NSNumber)?.int64Value ?? 0; return d }
            var rep = ScanReport(detections: seen, errors: parsed.errors, cancelled: r.cancelled, timedOut: r.timedOut, failure: r.launchError, duration: Date().timeIntervalSince(t0))
            if r.status >= 2 && !r.cancelled && !r.timedOut && rep.failure == nil && seen.isEmpty && parsed.errors.isEmpty { rep.failure = "clamscan exited with status \(r.status)" }
            return rep
        }.value
    }

    func updateDatabase(onLine: @escaping @Sendable (String) -> Void, cancel: CancelFlag) async -> (ok: Bool, summary: String) {
        guard let fc = find("freshclam") else { return (false, "freshclam not found") }
        return await Task.detached {
            let r = ProcRunner.run(fc, [], timeout: 900, cancel: cancel, onLine: onLine)
            if let e = r.launchError { return (false, e) }
            if r.cancelled { return (false, "cancelled") }
            if r.timedOut { return (false, "timeout") }
            return (r.status == 0, r.status == 0 ? "ok" : r.output.split(separator: "\n").suffix(3).joined(separator: " "))
        }.value
    }
}

/// Test double: canned detections, no process.
struct FakeEngine: ScanEngine {
    var name: String { "Fake" }
    var status: EngineStatus = .ready(path: "/fake/clamscan", version: "Fake 1.0", dbAgeDays: 0)
    var canned: [Detection] = []
    var lastPaths: PathsBox = PathsBox()
    final class PathsBox: @unchecked Sendable { var paths: [String] = [] }
    func availability() -> EngineStatus { status }
    func scan(paths: [String], progress: @escaping @Sendable (Detection) -> Void, cancel: CancelFlag) async -> ScanReport {
        lastPaths.paths = paths
        canned.forEach(progress)
        return ScanReport(detections: canned)
    }
    func updateDatabase(onLine: @escaping @Sendable (String) -> Void, cancel: CancelFlag) async -> (ok: Bool, summary: String) { onLine("fake"); return (true, "ok") }
}

enum ScanScope { case quick, home, custom(String) }
enum Scopes {
    static func paths(_ s: ScanScope, home: String = Env.home) -> [String] {
        let l: [String]
        switch s {
        case .quick: l = ["/Downloads", "/Desktop", "/Library/LaunchAgents", "/Applications"].map { home + $0 }
        case .home: l = [home]
        case .custom(let p): l = [p]
        }
        return l.filter { FileManager.default.fileExists(atPath: $0) }
    }
    /// Drops paths the user excluded (or lying under an excluded folder).
    static func allowed(_ paths: [String], exclusions: [String]) -> [String] {
        paths.filter { p in !exclusions.contains { Safety.under(Safety.real(p), Safety.real($0)) } }
    }
}

// MARK: native security checks (read-only, injectable runner)

protocol CommandRunner: Sendable { func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) }
struct SystemCommandRunner: CommandRunner {
    func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let r = ProcRunner.run(exe, args, timeout: timeout); return (r.launchError == nil && !r.timedOut ? r.status : -1, r.output)
    }
}

enum Posture { case good, attention, unknown }
struct SecurityCheck: Identifiable, Equatable {
    let id: String; let title: String; let posture: Posture; let detail: String
}

enum NativeChecks {
    static func parseSIP(_ o: String) -> Posture { o.contains("enabled") ? .good : o.contains("disabled") ? .attention : .unknown }
    static func parseGatekeeper(_ o: String) -> Posture { o.contains("assessments enabled") ? .good : o.contains("assessments disabled") ? .attention : .unknown }
    static func parseFileVault(_ o: String) -> Posture { o.contains("FileVault is On") ? .good : o.contains("FileVault is Off") ? .attention : .unknown }
    static func parseFirewall(_ o: String) -> Posture {
        let l = o.lowercased(); return l.contains("is enabled") || l.contains("state = 1") || l.contains("state = 2") ? .good : l.contains("is disabled") || l.contains("state = 0") ? .attention : .unknown
    }
    static let xprotectPlists = ["/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist",
                                 "/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"]
    static func xprotectVersion(plists: [String] = xprotectPlists) -> String? {
        for p in plists { if let v = (NSDictionary(contentsOfFile: p)?["CFBundleShortVersionString"] as? String) { return v } }
        return nil
    }

    static func run(_ r: CommandRunner, xprotect: [String] = xprotectPlists) -> [SecurityCheck] {
        func go(_ exe: String, _ a: [String]) -> String { r.run(exe, a, timeout: 5).output }
        let S = "Protection"
        func mk(_ id: String, _ title: String, _ p: Posture, good: String, bad: String) -> SecurityCheck {
            SecurityCheck(id: id, title: TT(title, S), posture: p, detail: TT(p == .good ? good : p == .attention ? bad : "Could not be determined", S))
        }
        var out = [
            mk("sip", "System Integrity Protection", parseSIP(go("/usr/bin/csrutil", ["status"])), good: "Enabled: system files are protected", bad: "Disabled: system files are not protected"),
            mk("gk", "Gatekeeper", parseGatekeeper(go("/usr/sbin/spctl", ["--status"])), good: "Enabled: only trusted apps open without a warning", bad: "Disabled: any app can open without a check"),
            mk("fv", "FileVault disk encryption", parseFileVault(go("/usr/bin/fdesetup", ["status"])), good: "On: your disk is encrypted", bad: "Off: your disk is not encrypted"),
            mk("fw", "Firewall", parseFirewall(go("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])), good: "On: incoming connections are filtered", bad: "Off: incoming connections are not filtered"),
        ]
        if let v = xprotectVersion(plists: xprotect) { out.append(SecurityCheck(id: "xp", title: TT("XProtect (Apple built-in malware definitions)", S), posture: .good, detail: TTF("Version %@", S, v))) }
        else { out.append(SecurityCheck(id: "xp", title: TT("XProtect (Apple built-in malware definitions)", S), posture: .unknown, detail: TT("Could not be determined", S))) }
        return out
    }
}

// MARK: persistence audit (reuses StartupModel's inventory)

enum Severity: Int, Comparable { case low = 0, medium, high; static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue } }
enum SignState: Equatable { case signed, adhoc, unsigned, unknown }
struct AuditFinding: Identifiable, Equatable {
    var id: String { path + "|" + reason }
    let path: String, label: String, program: String
    let severity: Severity
    let reason: String      // English key in the Protection table
}

enum PersistenceAudit {
    /// `codesign -dv` writes to stderr: 'Signature=adhoc', 'Authority=...', 'code object is not signed at all'.
    static func parseCodesign(_ o: String) -> SignState {
        if o.contains("not signed at all") { return .unsigned }
        if o.contains("Signature=adhoc") { return .adhoc }
        if o.contains("Authority=") || o.contains("TeamIdentifier=") { return .signed }
        return .unknown
    }
    static func realSigner(_ path: String) -> SignState { parseCodesign(ProcRunner.run("/usr/bin/codesign", ["-dv", "--", path], timeout: 5).output) }

    static let tmpRoots = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders", "/Users/Shared"]
    static func unusual(_ program: String, tmp: [String] = tmpRoots) -> Bool {
        if tmp.contains(where: { Safety.under(program, $0) }) { return true }
        return program.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }   // hidden dirs, e.g. Application Support/.x7f3
    }
    static let trustedPrefixes = ["/System", "/usr/bin", "/usr/sbin", "/usr/libexec", "/bin", "/sbin"]

    static func audit(_ items: [StartupItem], tmp: [String] = tmpRoots, signer: (String) -> SignState) -> [AuditFinding] {
        var out: [AuditFinding] = []
        var cache: [String: SignState] = [:]
        for it in items {
            func add(_ s: Severity, _ r: String) { out.append(AuditFinding(path: it.path, label: it.label, program: it.program, severity: s, reason: r)) }
            if it.program.isEmpty { add(.low, "Launch item has no readable program"); continue }
            guard it.program.hasPrefix("/") else { continue }
            let exists = FileManager.default.fileExists(atPath: it.program)
            if !exists { add(.medium, "Program is missing (leftover or removed malware)"); continue }
            if unusual(it.program, tmp: tmp) { add(.high, "Runs a program from a temporary or hidden location") }
            if trustedPrefixes.contains(where: { Safety.under(it.program, $0) }) { continue }
            let s = cache[it.program] ?? signer(it.program); cache[it.program] = s
            if s == .unsigned { add(.high, "Program is not code-signed") }
            else if s == .adhoc { add(.medium, "Program has only an ad-hoc signature (no developer identity)") }
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

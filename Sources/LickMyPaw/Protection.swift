import SwiftUI
import AppKit

private let S = "Protection"

enum ProtectInstall {
    static var prefix: String { FileManager.default.fileExists(atPath: "/opt/homebrew") ? "/opt/homebrew" : "/usr/local" }
    /// Shown verbatim and copied. Homebrew ships freshclam.conf only as a sample, so it must be enabled once.
    static var commands: String {
        "brew install clamav\ncp \(prefix)/etc/clamav/freshclam.conf.sample \(prefix)/etc/clamav/freshclam.conf\nsed -i '' 's/^Example/#Example/' \(prefix)/etc/clamav/freshclam.conf\nfreshclam"
    }
}

@MainActor final class ProtectionModel: ObservableObject {
    static let shared = ProtectionModel()
    @Published var status: EngineStatus?
    @Published var checks: [SecurityCheck] = []
    @Published var findings: [AuditFinding] = []
    @Published var auditedAt: Date?
    @Published var detections: [Detection] = []
    @Published var selected: Set<String> = []
    @Published var scanning = false
    @Published var found = 0
    @Published var elapsed: TimeInterval = 0
    @Published var scannedAt: Date?
    @Published var stale = false
    @Published var message: String?
    @Published var updating = false
    @Published var updateLog: [String] = []
    @Published var lastReport: ScanReport?
    var engine: ScanEngine
    var runner: CommandRunner
    var roots: StartupRoots?
    var signer: @Sendable (String) -> SignState
    var exclusions: () -> [String]
    var xprotect = NativeChecks.xprotectPlists
    private var cancelFlag = CancelFlag()
    private var token: NSObjectProtocol?

    init(engine: ScanEngine = ClamAVEngine(), runner: CommandRunner = SystemCommandRunner(), roots: StartupRoots? = nil,
         signer: @escaping @Sendable (String) -> SignState = PersistenceAudit.realSigner, exclusions: @escaping () -> [String] = { Prefs.exclusions }) {
        self.engine = engine; self.runner = runner; self.roots = roots; self.signer = signer; self.exclusions = exclusions
        // queue: nil + hop to the main actor: `queue: .main` deadlocks when Engine.trash posts from the main thread.
        token = NotificationCenter.default.addObserver(forName: Engine.didChange, object: nil, queue: nil) { [weak self] n in
            let op = n.userInfo?["op"] as? String ?? "", paths = n.userInfo?["paths"] as? [String] ?? []
            Task { @MainActor in self?.handleEngineChange(op: op, paths: paths) }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    /// First open: only the cheap native checks + engine detection. Never a scan.
    func onFirstOpen() { if checks.isEmpty { refreshChecks() }; if status == nil { refreshStatus() } }

    func refreshStatus() {
        let e = engine
        Task { let s = await Task.detached { e.availability() }.value; status = s }
    }
    func refreshChecks() {
        let r = runner, x = xprotect
        Task { let c = await Task.detached { NativeChecks.run(r, xprotect: x) }.value; withAnimation(spring) { checks = c } }
    }
    func runAudit() {
        let r = roots ?? .real(), sg = signer
        Task {
            let f = await Task.detached { PersistenceAudit.audit(StartupScanner.scan(r, control: NoControl()), signer: sg) }.value
            withAnimation(spring) { findings = f; auditedAt = Date() }
        }
    }

    func scan(_ scope: ScanScope) async {
        guard !scanning else { return }
        let paths = Scopes.allowed(Scopes.paths(scope), exclusions: exclusions())
        guard !paths.isEmpty else { message = TT("Nothing to scan (folders missing or excluded)", S); return }
        scanning = true; found = 0; elapsed = 0; message = nil; selected = []; cancelFlag = CancelFlag()
        let t0 = Date()
        let ticker = Task { while !Task.isCancelled { elapsed = Date().timeIntervalSince(t0); try? await Task.sleep(nanoseconds: 250_000_000) } }
        let ex = exclusions()
        let rep = await engine.scan(paths: paths, progress: { _ in Task { @MainActor in self.found += 1 } }, cancel: cancelFlag)
        ticker.cancel()
        let kept = rep.detections.filter { d in !ex.contains { Safety.under(Safety.real(d.path), Safety.real($0)) } }
        withAnimation(spring) { detections = kept; lastReport = rep; scannedAt = Date(); stale = false; scanning = false; elapsed = rep.duration }
        if let f = rep.failure { message = f } else if rep.timedOut { message = TT("The scan took too long and was stopped", S) }
    }
    func cancel() { cancelFlag.set() }

    func updateSignatures() async {
        guard !updating else { return }
        updating = true; updateLog = []; cancelFlag = CancelFlag()
        let r = await engine.updateDatabase(onLine: { l in Task { @MainActor in self.updateLog.append(l); if self.updateLog.count > 200 { self.updateLog.removeFirst() } } }, cancel: cancelFlag)
        updating = false
        message = r.ok ? nil : TTF("Signature update failed: %@", S, r.summary)
        refreshStatus()
    }

    /// Removal = Trash through Engine only (logged, undoable).
    func removeSelected() {
        var failed: [String] = []
        for d in detections where selected.contains(d.path) {
            do { try Engine.trash(d.path, size: d.size, mode: .userSelected) } catch { failed.append(error.localizedDescription) }
        }
        handleEngineChange(op: "trash", paths: detections.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) })
        message = failed.first
    }

    func handleEngineChange(op: String, paths: [String]) {
        let before = detections.count
        if op == "trash" { withAnimation(spring) { detections.removeAll { d in paths.contains { Safety.under(d.path, $0) } } }; selected = selected.filter { s in detections.contains { $0.path == s } } }
        if before > 0 { stale = true }
    }
}

/// Audit only reads plists; launchctl state is irrelevant here.
struct NoControl: LaunchAgentControl {
    func isLoaded(label: String) -> Bool { false }
    func isDisabled(label: String) -> Bool { false }
    func disable(label: String) -> Result<Void, EngineError> { .failure(EngineError(message: "read-only")) }
    func enable(label: String) -> Result<Void, EngineError> { .failure(EngineError(message: "read-only")) }
}

struct ProtectionView: View {
    @ObservedObject private var m = ProtectionModel.shared
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(TT("Detections come from open-source ClamAV signatures; this is not a full antivirus replacement.", S)).font(.caption).opacity(0.65)
                if let msg = m.message { Text(msg).font(.callout).foregroundStyle(.orange) }
                posture
                engineCard
                if m.scanning { progressCard }
                results
            }.padding(20)
        }
        .foregroundStyle(.white)
        .onAppear { m.onFirstOpen() }
        .sheet(isPresented: $confirm) { ConfirmSheet(m: m, isPresented: $confirm) }
    }

    // MARK: posture
    private var posture: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(TT("Security posture", S)).font(.headline)
                Spacer()
                Button(TT("Recheck", S)) { m.refreshChecks() }.buttonStyle(SoftButton())
            }
            ForEach(m.checks) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.posture == .good ? "checkmark.shield.fill" : c.posture == .attention ? "exclamationmark.triangle.fill" : "questionmark.circle")
                        .foregroundStyle(c.posture == .good ? Color.green : c.posture == .attention ? .orange : .gray)
                    VStack(alignment: .leading, spacing: 1) { Text(c.title).font(.body.weight(.medium)); Text(c.detail).font(.caption).opacity(0.65) }
                    Spacer()
                }
            }
            Divider().opacity(0.3)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TT("Persistence audit", S)).font(.subheadline.weight(.semibold))
                    Text(TT("Checks launch agents and daemons for missing, unsigned or oddly placed programs", S)).font(.caption).opacity(0.65)
                }
                Spacer()
                Button(m.auditedAt == nil ? TT("Run audit", S) : TT("Rescan", S)) { m.runAudit() }.buttonStyle(SoftButton())
            }
            if let t = m.auditedAt {
                if m.findings.isEmpty { Label(TT("No suspicious launch items found", S), systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green) }
                ForEach(m.findings) { f in
                    HStack(alignment: .top, spacing: 8) {
                        Text(f.severity == .high ? TT("High", S) : f.severity == .medium ? TT("Medium", S) : TT("Low", S)).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3).background((f.severity == .high ? Color.red : f.severity == .medium ? .orange : .gray).opacity(0.4), in: Capsule())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.label).font(.callout.weight(.medium)); Text(TT(f.reason, S)).font(.caption).opacity(0.75)
                            Text(f.program).font(.caption2).opacity(0.5).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } label: { Image(systemName: "folder") }.buttonStyle(SoftButton()).help(TT("Show in Finder", S))
                    }
                }
                Text(TTF("Saved results from %@ (%@) — press Rescan to refresh", S, DateFormatter.localizedString(from: t, dateStyle: .none, timeStyle: .short), RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date()))).font(.caption2).opacity(0.5)
            }
        }.padding(14).glass(16)
    }

    // MARK: engine
    @ViewBuilder private var engineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TT("Malware scan (ClamAV)", S)).font(.headline)
            switch m.status {
            case nil: ProgressView()
            case .missing?:
                Text(TT("The ClamAV engine is not installed. It is free, open-source software that runs separately from this app. Nothing is installed automatically: run these commands in Terminal.", S)).font(.callout).opacity(0.85)
                Text(ProtectInstall.commands).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button(TT("Copy commands", S)) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ProtectInstall.commands, forType: .string) }.buttonStyle(SoftButton())
                    Button(TT("Check again", S)) { m.refreshStatus() }.buttonStyle(SoftButton())
                }
            case .noDatabase?:
                Text(TT("ClamAV is installed but has no signature database yet.", S)).font(.callout).opacity(0.85)
                updateUI
            case .ready(_, let v, let age)?:
                Text(v).font(.caption).opacity(0.6)
                if let a = age, a > 7 { Text(TTF("Signatures are %d days old", S, a)).font(.callout).foregroundStyle(.yellow); updateUI }
                scopes
            }
        }.padding(14).glass(16)
    }
    @ViewBuilder private var updateUI: some View {
        HStack {
            Button(TT("Update signatures", S)) { Task { await m.updateSignatures() } }.buttonStyle(PinkButton()).disabled(m.updating)
            if m.updating { Button(TT("Cancel", S)) { m.cancel() }.buttonStyle(SoftButton()) }
        }
        if !m.updateLog.isEmpty {
            Text(m.updateLog.suffix(6).joined(separator: "\n")).font(.system(.caption2, design: .monospaced)).opacity(0.7).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var scopes: some View {
        HStack {
            Button(TT("Quick scan", S)) { Task { await m.scan(.quick) } }.buttonStyle(PinkButton())
            Button(TT("Scan home folder", S)) { Task { await m.scan(.home) } }.buttonStyle(SoftButton())
            Button(TT("Choose folder…", S)) {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                if p.runModal() == .OK, let u = p.url { Task { await m.scan(.custom(u.path)) } }
            }.buttonStyle(SoftButton())
        }.disabled(m.scanning)
    }

    private var progressCard: some View {
        HStack(spacing: 20) {
            PulseOrb().frame(width: 90, height: 90)
            VStack(alignment: .leading, spacing: 4) {
                Text(TT("Scanning…", S)).font(.headline)
                Text(TTF("%d detection(s) so far · %d s", S, m.found, Int(m.elapsed))).font(.callout).opacity(0.75)
            }
            Spacer()
            Button(TT("Cancel", S)) { m.cancel() }.buttonStyle(SoftButton())
        }.padding(14).glass(16)
    }

    @ViewBuilder private var results: some View {
        if let t = m.scannedAt, !m.scanning {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(m.detections.isEmpty ? TT("No threats found", S) : TTF("%d possible threat(s)", S, m.detections.count)).font(.headline)
                    Spacer()
                    if !m.detections.isEmpty { Button(TT("Move selected to Trash", S)) { confirm = true }.buttonStyle(PinkButton()).disabled(m.selected.isEmpty) }
                }
                if !m.detections.isEmpty { Text(TT("Signature matches can be false positives — review before removing", S)).font(.caption).foregroundStyle(.yellow) }
                ForEach(m.detections) { d in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(get: { m.selected.contains(d.path) }, set: { on in if on { m.selected.insert(d.path) } else { m.selected.remove(d.path) } })).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text((d.path as NSString).lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                            Text(d.signature).font(.caption).foregroundStyle(.orange)
                            Text(d.path).font(.caption2).opacity(0.5).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(fmt(d.size)).font(.caption).opacity(0.7)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.path)]) } label: { Image(systemName: "folder") }.buttonStyle(SoftButton()).help(TT("Show in Finder", S))
                    }.padding(8).glass(12)
                }
                if let r = m.lastReport, !r.errors.isEmpty { Text(TTF("%d file(s) could not be read (permissions)", S, r.errors.count)).font(.caption).opacity(0.6) }
                Text(TTF("Saved results from %@ (%@) — press Rescan to refresh", S, DateFormatter.localizedString(from: t, dateStyle: .none, timeStyle: .short), RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date()))).font(.caption2).opacity(0.5)
                if m.stale { Text(TT("Updated after recent actions — Rescan to be sure", S)).font(.caption).foregroundStyle(.yellow) }
            }.padding(14).glass(16)
        }
    }
}

private struct ConfirmSheet: View {
    @ObservedObject var m: ProtectionModel
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TTF("Move %d file(s) to Trash?", S, m.selected.count)).font(.headline)
            Text(TT("Signature matches can be false positives — review before removing", S)).font(.callout).foregroundStyle(.yellow)
            Text(TT("Files go to the Trash and can be restored from History.", S)).font(.callout).opacity(0.8)
            HStack {
                Spacer()
                Button(TT("Cancel", S)) { isPresented = false }.buttonStyle(SoftButton())
                Button(TT("Move to Trash", S)) { m.removeSelected(); isPresented = false }.buttonStyle(PinkButton())
            }
        }.padding(24).frame(width: 440).foregroundStyle(.white).background(Background())
    }
}

// MARK: - self test

enum ProtectionSelfTest {
    final class FakeRunner: CommandRunner, @unchecked Sendable {
        var outputs: [String: String] = [:]
        func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) { (0, outputs[(exe as NSString).lastPathComponent] ?? "") }
    }
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }

        // parser
        let sample = """
        /Users/a/Downloads/evil file.dmg: OSX.Trojan.Gen FOUND
        /Users/a/Downloads/we:ird: name.zip: Win.Test.EICAR_HDB-1 FOUND
        /Users/a/Library/Mail/x.emlx: Operation not permitted. ERROR
        ERROR: Can't open file /x
        WARNING: something
        /Users/a/ok.txt: OK
        """
        let p = ClamParser.parse(sample); t.reachedCode()
        t.check(p.detections.count == 2 && p.detections[0] == Detection(path: "/Users/a/Downloads/evil file.dmg", signature: "OSX.Trojan.Gen"), "parser: FOUND with spaces")
        t.check(p.detections[1].path == "/Users/a/Downloads/we:ird: name.zip" && p.detections[1].signature == "Win.Test.EICAR_HDB-1", "parser: colons in path")
        t.check(p.errors.count == 3, "parser: ERROR/WARNING/not permitted collected (\(p.errors.count))")
        t.check(ClamParser.parse("").detections.isEmpty && ClamParser.parse("garbage FOUND\nrel/path: X FOUND").detections.isEmpty, "parser: empty and malformed ignored")

        // availability with injected dirs and a fake clamscan script
        let bin = f.dir("bin"), db = f.dir("db"), emptyDB = f.dir("emptydb")
        let script = bin + "/clamscan"
        try? "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'ClamAV 9.9.9/1/x'; exit 0; fi\necho '/x y/a: b.txt: Fake.Sig FOUND'\necho '/x y/err: Operation not permitted. ERROR'\nexit 1\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755); f.file("db/daily.cvd", kb: 1, daysOld: 2)
        t.check(ClamAVEngine(searchDirs: [f.root + "/none"], dbDirs: [db]).availability() == .missing, "availability: missing"); t.reachedCode()
        t.check(ClamAVEngine(searchDirs: [bin], dbDirs: [emptyDB]).availability() == .noDatabase(script), "availability: no database")
        var eng = ClamAVEngine(searchDirs: [bin], dbDirs: [db]); eng.exclusions = { [] }
        if case .ready(let path, let v, let age) = eng.availability() { t.check(path == script && v.hasPrefix("ClamAV 9.9.9") && age == 2, "availability: ready, version and db age") } else { t.check(false, "availability: ready") }
        let a = ClamAVEngine.args(paths: ["/a b"], exclusions: ["/x.y"])
        t.check(a.last == "/a b" && a.contains("--exclude-dir=^\\/x\\.y") && a.contains("--infected"), "argv built without shell, exclusions escaped")
        let real = await eng.scan(paths: [f.home], progress: { _ in }, cancel: CancelFlag())
        t.check(real.detections.map(\.signature) == ["Fake.Sig"] && real.detections[0].path == "/x y/a: b.txt" && real.errors.count == 1 && real.failure == nil, "ClamAVEngine parses a (fake) clamscan process"); t.reachedCode()

        // process runner: timeout / cancel / output (harmless executables)
        let to = ProcRunner.run("/bin/sleep", ["5"], timeout: 0.3)
        t.check(to.timedOut && !to.cancelled, "runner: timeout kills the child"); t.reachedCode()
        let cf = CancelFlag(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cf.set() }
        let cr = ProcRunner.run("/bin/sleep", ["5"], timeout: 10, cancel: cf)
        t.check(cr.cancelled && !cr.timedOut, "runner: cancel (SIGTERM)")
        let ok = ProcRunner.run("/bin/echo", ["hi there"], timeout: 5)
        t.check(ok.status == 0 && ok.output == "hi there\n", "runner: output and status")
        t.check(ProcRunner.run("/nonexistent/x", [], timeout: 1).launchError != nil, "runner: launch error reported")

        // native checks
        t.check(NativeChecks.parseSIP("System Integrity Protection status: enabled.") == .good && NativeChecks.parseSIP("System Integrity Protection status: disabled.") == .attention && NativeChecks.parseSIP("") == .unknown, "SIP on/off/unknown")
        t.check(NativeChecks.parseGatekeeper("assessments enabled") == .good && NativeChecks.parseGatekeeper("assessments disabled") == .attention, "Gatekeeper on/off")
        t.check(NativeChecks.parseFileVault("FileVault is On.") == .good && NativeChecks.parseFileVault("FileVault is Off.") == .attention, "FileVault on/off")
        t.check(NativeChecks.parseFirewall("Firewall is enabled. (State = 1)") == .good && NativeChecks.parseFirewall("Firewall is disabled. (State = 0)") == .attention, "firewall on/off")
        let xp = f.root + "/XProtect.plist"; (["CFBundleShortVersionString": "5301"] as NSDictionary).write(toFile: xp, atomically: true)
        t.check(NativeChecks.xprotectVersion(plists: [f.root + "/nope.plist", xp]) == "5301" && NativeChecks.xprotectVersion(plists: [f.root + "/nope.plist"]) == nil, "XProtect version from plist with fallback")
        let fr = FakeRunner(); fr.outputs = ["csrutil": "System Integrity Protection status: disabled.", "spctl": "assessments enabled", "fdesetup": "FileVault is On.", "socketfilterfw": "Firewall is disabled. (State = 0)"]
        let cs = NativeChecks.run(fr, xprotect: [xp])
        t.check(cs.map(\.posture) == [.attention, .good, .good, .attention, .good], "native checks via fake runner (\(cs.map(\.posture)))"); t.reachedCode()

        // persistence audit
        func plist(_ dir: String, _ name: String, _ d: [String: Any]) { (d as NSDictionary).write(toFile: f.dir(dir) + "/" + name + ".plist", atomically: true) }
        let good = f.file("tools/good"), unsigned = f.file("tools/unsigned"), adhoc = f.file("tools/adhoc"), tmpProg = f.file("tmp/dropper"), hidden = f.file("home/Library/Application Support/.x7f3/agent")
        let ua = "home/Library/LaunchAgents"
        plist(ua, "a.good", ["Label": "a.good", "Program": good]); plist(ua, "b.unsigned", ["Label": "b.unsigned", "Program": unsigned])
        plist(ua, "c.adhoc", ["Label": "c.adhoc", "Program": adhoc]); plist(ua, "d.missing", ["Label": "d.missing", "Program": "/nonexistent/prog"])
        plist(ua, "e.hidden", ["Label": "e.hidden", "Program": hidden]); plist(ua, "f.sh", ["Label": "f.sh", "Program": "/bin/sh"])
        let roots = StartupRoots(userAgents: f.home + "/Library/LaunchAgents", systemAgents: f.root + "/none1", systemDaemons: f.root + "/none2")
        let signer: @Sendable (String) -> SignState = { $0.hasSuffix("unsigned") ? .unsigned : $0.hasSuffix("adhoc") ? .adhoc : .signed }
        let items = StartupScanner.scan(roots, control: NoControl())
        let fs = PersistenceAudit.audit(items, tmp: [f.root + "/tmp"], signer: signer)
        func sev(_ l: String) -> [Severity] { fs.filter { $0.label == l }.map(\.severity) }
        t.check(sev("a.good").isEmpty && sev("f.sh").isEmpty, "audit: signed and system programs not flagged")
        t.check(sev("b.unsigned") == [.high] && sev("c.adhoc") == [.medium] && sev("d.missing") == [.medium], "audit: unsigned/adhoc/missing flagged"); t.reachedCode()
        t.check(sev("e.hidden").contains(.high), "audit: hidden Application Support dir flagged")
        t.check(PersistenceAudit.unusual("/tmp/x") && PersistenceAudit.unusual("/private/var/tmp/x") && !PersistenceAudit.unusual("/Applications/A.app/x") && tmpProg.count > 0, "audit: unusual-location rule")
        t.check(PersistenceAudit.parseCodesign("code object is not signed at all") == .unsigned && PersistenceAudit.parseCodesign("Signature=adhoc") == .adhoc && PersistenceAudit.parseCodesign("Authority=Developer ID") == .signed, "codesign output parsing")
        t.check(fs.first?.severity == .high, "audit: sorted by severity")

        // model: scan via FakeEngine, exclusions, removal, engine change
        let victim = f.file("home/Downloads/bad.bin", kb: 4), other = f.file("home/Downloads/keep/ex.bin", kb: 1)
        f.dir("home/Downloads/keep")
        let fake = FakeEngine(canned: [Detection(path: victim, signature: "Fake.A", size: 4096), Detection(path: other, signature: "Fake.B", size: 1024)])
        let excl = f.home + "/Downloads/keep"
        let m = ProtectionModel(engine: fake, runner: fr, roots: roots, signer: signer, exclusions: { [excl] })
        await m.scan(.custom(f.home + "/Downloads"))
        t.check(m.detections.map(\.path) == [victim] && !m.scanning && m.scannedAt != nil, "scan: results kept, excluded detection dropped"); t.reachedCode()
        t.check(Scopes.allowed([f.home + "/Downloads/keep/sub", f.home + "/Downloads"], exclusions: [excl]) == [f.home + "/Downloads"], "excluded scan paths skipped")
        t.check(Scopes.paths(.quick, home: f.home) == [f.home + "/Downloads", f.home + "/Library/LaunchAgents"], "quick scope = existing standard folders")
        m.selected = [victim]; m.removeSelected()
        let log = ActionLog.all()
        t.check(!FileManager.default.fileExists(atPath: victim) && log.count == 1 && log[0].path == victim && (log[0].trashedTo ?? "").hasPrefix(f.home + "/.Trash"), "removal goes to fake Trash and is logged")
        t.check(m.detections.isEmpty && m.stale, "handleEngineChange dropped detection and set stale")
        if let e = log.first { try? Engine.undo(e) }
        t.check(FileManager.default.fileExists(atPath: victim), "removal undoable")
        m.stale = false; m.detections = [Detection(path: victim, signature: "x")]; m.handleEngineChange(op: "undo", paths: [victim])
        t.check(m.stale && m.detections.count == 1, "undo flags stale without dropping")
        let denied = ProtectionModel(engine: fake, runner: fr, roots: roots, signer: signer, exclusions: { [] }); denied.detections = [Detection(path: "/System/Library", signature: "x")]; denied.selected = ["/System/Library"]; denied.removeSelected()
        t.check(denied.message != nil && FileManager.default.fileExists(atPath: "/System/Library"), "Safety refuses protected path removal")
    }
}

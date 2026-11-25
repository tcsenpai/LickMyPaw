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
    let installer = ClamInstaller()
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
        installer.onReady = { [weak self] in self?.refreshStatus() }
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
                Text(TTF("Saved results from %@ (%@): press Rescan to refresh", S, DateFormatter.localizedString(from: t, dateStyle: .none, timeStyle: .short), makeRelativeFormatter().localizedString(for: t, relativeTo: Date()))).font(.caption2).opacity(0.5)
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
                    Button(TT("Install automatically", S)) { withAnimation(spring) { m.installer.confirming = true } }.buttonStyle(PinkButton()).disabled(m.installer.running)
                }
                InstallAutoView(inst: m.installer)
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
                if !m.detections.isEmpty { Text(TT("Signature matches can be false positives: review before removing", S)).font(.caption).foregroundStyle(.yellow) }
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
                Text(TTF("Saved results from %@ (%@): press Rescan to refresh", S, DateFormatter.localizedString(from: t, dateStyle: .none, timeStyle: .short), makeRelativeFormatter().localizedString(for: t, relativeTo: Date()))).font(.caption2).opacity(0.5)
                if m.stale { Text(TT("Updated after recent actions: Rescan to be sure", S)).font(.caption).foregroundStyle(.yellow) }
            }.padding(14).glass(16)
        }
    }
}

private struct InstallAutoView: View {
    @ObservedObject var inst: ClamInstaller
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if inst.confirming && !inst.running {
                Text(TT("This will run, in order:", S)).font(.callout.weight(.semibold))
                Text("1. brew install clamav\n2. " + TT("create freshclam.conf from the sample (enables it by commenting out the 'Example' line)", S) + "\n3. freshclam: " + TT("downloads the signatures: hundreds of MB, can take several minutes", S))
                    .font(.system(.caption, design: .monospaced)).opacity(0.85)
                HStack {
                    Button(TT("Cancel", S)) { withAnimation(spring) { inst.confirming = false } }.buttonStyle(SoftButton())
                    Button(TT("Install", S)) { Task { await inst.run() } }.buttonStyle(PinkButton())
                }
            }
            if !inst.steps.isEmpty {
                ForEach(inst.steps) { st in
                    HStack(spacing: 8) {
                        switch st.state {
                        case .running: ProgressView().controlSize(.small).tint(.white).frame(width: 16, height: 16)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
                        case .pending: Image(systemName: "circle").opacity(0.5)
                        }
                        Text(TT(st.name, S)).font(.callout)
                    }.transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            if inst.running || !inst.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(inst.log.enumerated()), id: \.offset) { Text($0.element).id($0.offset) }
                        }.font(.system(.caption2, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(height: 130).padding(8).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: inst.log.count) { _ in if let l = inst.log.indices.last { proxy.scrollTo(l, anchor: .bottom) } }
                }
            }
            if inst.running { Button(TT("Cancel", S)) { inst.cancel() }.buttonStyle(SoftButton()) }
            if inst.finished { Label(TT("ClamAV is ready", S), systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.callout.weight(.semibold)) }
            if let f = inst.failure, !inst.running {
                Text(f).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                if !inst.steps.isEmpty { Button(TT("Retry", S)) { Task { await inst.run() } }.buttonStyle(PinkButton()) }
            }
        }.animation(spring, value: inst.confirming)
    }
}

private struct ConfirmSheet: View {
    @ObservedObject var m: ProtectionModel
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TTF("Move %d file(s) to Trash?", S, m.selected.count)).font(.headline)
            Text(TT("Signature matches can be false positives: review before removing", S)).font(.callout).foregroundStyle(.yellow)
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
        await installTests(t, f)
        let denied = ProtectionModel(engine: fake, runner: fr, roots: roots, signer: signer, exclusions: { [] }); denied.detections = [Detection(path: "/System/Library", signature: "x")]; denied.selected = ["/System/Library"]; denied.removeSelected()
        t.check(denied.message != nil && FileManager.default.fileExists(atPath: "/System/Library"), "Safety refuses protected path removal")
    }

    final class FakeInstallRunner: InstallRunner, @unchecked Sendable {
        let l = NSLock(); var calls: [[String]] = [], envs: [[String: String]] = [], failAt: Int?, blockUntilCancel = false, killed = false
        func run(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval, cancel: CancelFlag, onLine: @escaping @Sendable (String) -> Void) -> ProcResult {
            l.lock(); calls.append([exe] + args); envs.append(env); let n = calls.count - 1; l.unlock()
            if blockUntilCancel { while !cancel.isSet { Thread.sleep(forTimeInterval: 0.02) }; l.lock(); killed = true; l.unlock(); var r = ProcResult(); r.cancelled = true; return r }
            onLine("fake line \(n)")
            var r = ProcResult(); r.status = (failAt == n) ? 1 : 0; return r
        }
        var count: Int { l.lock(); defer { l.unlock() }; return calls.count }
    }
    @MainActor static func installTests(_ t: TestCtx, _ f: Fixture) async {
        let brew = f.file("hb/bin/brew", kb: 1); chmod(brew, 0o755)
        let pre = f.root + "/hb", conf = pre + "/etc/clamav/freshclam.conf"
        f.dir("hb/etc/clamav")
        try? "# header\nExample\nDatabaseDirectory /x\n".write(toFile: conf + ".sample", atomically: true, encoding: .utf8)
        func make(_ r: FakeInstallRunner, uid: uid_t = 501, brews: [String]? = nil) -> ClamInstaller {
            let i = ClamInstaller(); i.runner = r; i.uid = { uid }; i.brewCandidates = brews ?? [brew]; return i
        }
        // plan: argv arrays, order, no shell
        let plan = ClamInstall.plan(brew: brew)
        let argvs = plan.compactMap { s -> [String]? in if case .process(let e, let a, _) = s.action { return [e] + a } else { return nil } }
        t.check(argvs == [[brew, "install", "clamav"], [pre + "/bin/freshclam"]] && !argvs.joined().contains("sh") && !argvs.joined().contains("-c"), "install plan: argv arrays, no sh / -c")
        t.check(plan.count == 3 && { if case .conf = plan[1].action { return true } else { return false } }(), "install plan: brew -> conf -> freshclam"); t.reachedCode()
        t.check(ClamInstall.prefix(ofBrew: "/opt/homebrew/bin/brew") == "/opt/homebrew" && ClamInstall.prefix(ofBrew: "/usr/local/bin/brew") == "/usr/local", "prefix from brew location")
        let env = ClamInstall.environment(prefix: pre, base: ["PATH": "/evil"])
        t.check(env["HOMEBREW_NO_AUTO_UPDATE"] == "1" && env["HOMEBREW_NO_ANALYTICS"] == "1" && env["PATH"]!.hasPrefix(pre + "/bin:") && env["PATH"]!.hasSuffix("/usr/bin:/bin"), "environment: brew vars and sane PATH")

        // happy path
        let r1 = FakeInstallRunner(), i1 = make(r1); var ready = 0; i1.onReady = { ready += 1 }
        await i1.run()
        t.check(r1.calls == [[brew, "install", "clamav"], [pre + "/bin/freshclam"]] && i1.steps.map(\.state) == [.ok, .ok, .ok] && i1.finished && ready == 1 && i1.failure == nil, "run: brew, conf (in Swift), freshclam; ready triggers recheck"); t.reachedCode()
        t.check(r1.envs.allSatisfy { $0["HOMEBREW_NO_AUTO_UPDATE"] == "1" && ($0["PATH"] ?? "").contains(pre + "/bin") } && i1.log.contains("fake line 0"), "run: env passed to runner, log streamed")
        let c1 = (try? String(contentsOfFile: conf, encoding: .utf8)) ?? ""
        t.check(c1.contains("#Example") && !c1.contains("\nExample") && c1.contains("DatabaseDirectory /x"), "conf: created from sample with Example commented out")

        // idempotent re-run: existing conf is never overwritten
        try? "Example\nuser-edited\n".write(toFile: conf, atomically: true, encoding: .utf8)
        let r2 = FakeInstallRunner(), i2 = make(r2); await i2.run()
        t.check(i2.finished && (try? String(contentsOfFile: conf, encoding: .utf8)) == "Example\nuser-edited\n", "re-run: existing conf untouched, steps ok")

        // failure of step 1 stops later steps; retry resumes from it
        try? FileManager.default.removeItem(atPath: conf)
        let r3 = FakeInstallRunner(); r3.failAt = 0; let i3 = make(r3); await i3.run()
        t.check(r3.count == 1 && i3.steps.map(\.state) == [.failed, .pending, .pending] && i3.failure != nil && !FileManager.default.fileExists(atPath: conf) && !i3.finished, "failure of step 1 stops later steps")
        r3.failAt = nil; await i3.run()
        t.check(r3.calls[1] == [brew, "install", "clamav"] && i3.finished && i3.steps.map(\.state) == [.ok, .ok, .ok], "retry resumes from the failed step")

        // missing brew: message with brew.sh, no process started
        let r4 = FakeInstallRunner(), i4 = make(r4, brews: [f.root + "/nobrew"]); await i4.run()
        t.check(r4.count == 0 && (i4.failure ?? "").contains("https://brew.sh") && i4.steps.isEmpty, "missing brew: brew.sh message, nothing started")

        // root refused
        let r5 = FakeInstallRunner(), i5 = make(r5, uid: 0); await i5.run()
        t.check(r5.count == 0 && i5.failure != nil && !i5.finished, "uid 0 refused, nothing started")

        // cancel kills the running child and marks the step cancelled
        try? FileManager.default.removeItem(atPath: conf)
        let r6 = FakeInstallRunner(); r6.blockUntilCancel = true; let i6 = make(r6)
        let job = Task { await i6.run() }
        while r6.count == 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        i6.cancel(); await job.value
        t.check(r6.killed && i6.steps.first?.state == .cancelled && !i6.running && !i6.finished && r6.count == 1, "cancel: child killed, step marked cancelled")
    }
}

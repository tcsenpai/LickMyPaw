import SwiftUI
import AppKit

private let S = "Maintenance"

// MARK: - core: a FIXED command table. No user string ever reaches a command line.

struct MaintCommand: Equatable {
    let exe: String
    let args: [String]
    var display: String { ([exe] + args).map(MaintCommand.quote).joined(separator: " ") }
    static func quote(_ s: String) -> String {
        s.range(of: "^[A-Za-z0-9_./=:@%+-]+$", options: .regularExpression) != nil ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum MaintID: String, CaseIterable { case flushDNS, reindexSpotlight, rebuildLaunchServices, clearFontCaches, verifyDisk, listSnapshots, thinSnapshots }

struct MaintTask: Identifiable {
    enum Risk { case none, low, medium }
    let id: MaintID
    let icon: String
    let title: String, detail: String, riskNote: String
    let risk: Risk
    let admin: Bool
    let commands: [MaintCommand]
    let readOnly: Bool
    let slow: Bool
    /// Thinning deletes Time Machine snapshots: needs an explicit extra confirmation.
    var destructive: Bool { id == .thinSnapshots }
}

enum Maintenance {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    /// Typed thinning parameters (bytes to reclaim, urgency 1-4). Constants, never user input.
    static let thinBytes = 10_000_000_000, thinUrgency = 4

    static let tasks: [MaintTask] = [
        MaintTask(id: .flushDNS, icon: "network", title: TT("Flush DNS cache", S),
                  detail: TT("Forgets cached website addresses. Helps when a site resolves to an old address.", S),
                  riskNote: TT("Harmless. The next visit to each site is a little slower.", S), risk: .none, admin: true,
                  commands: [MaintCommand(exe: "/usr/bin/dscacheutil", args: ["-flushcache"]), MaintCommand(exe: "/usr/bin/killall", args: ["-HUP", "mDNSResponder"])], readOnly: false, slow: false),
        MaintTask(id: .reindexSpotlight, icon: "magnifyingglass", title: TT("Reindex Spotlight", S),
                  detail: TT("Erases the Spotlight index of the startup disk so macOS builds it again. Helps when search misses files.", S),
                  riskNote: TT("Search is incomplete and the Mac works harder for a while (minutes to hours).", S), risk: .low, admin: true,
                  commands: [MaintCommand(exe: "/usr/bin/mdutil", args: ["-E", "/"])], readOnly: false, slow: false),
        MaintTask(id: .rebuildLaunchServices, icon: "square.stack.3d.up", title: TT("Rebuild Launch Services database", S),
                  detail: TT("Rebuilds the list of which app opens which file type. Fixes duplicate or wrong entries in Open With.", S),
                  riskNote: TT("Your own choices of default apps can reset. Finder may need a relaunch.", S), risk: .low, admin: false,
                  commands: [MaintCommand(exe: lsregister, args: ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])], readOnly: false, slow: false),
        MaintTask(id: .clearFontCaches, icon: "textformat", title: TT("Clear font caches", S),
                  detail: TT("Removes the font cache so macOS rebuilds it. Fixes garbled or missing fonts.", S),
                  riskNote: TT("Apps may be slow to open the first time. Restart your Mac afterwards.", S), risk: .low, admin: true,
                  commands: [MaintCommand(exe: "/usr/bin/atsutil", args: ["databases", "-remove"])], readOnly: false, slow: false),
        MaintTask(id: .verifyDisk, icon: "internaldrive", title: TT("Verify startup disk", S),
                  detail: TT("Checks the file system of the startup disk. Read-only: it changes nothing.", S),
                  riskNote: TT("Safe. Can take a few minutes and slow the Mac down meanwhile.", S), risk: .none, admin: false,
                  commands: [MaintCommand(exe: "/usr/sbin/diskutil", args: ["verifyVolume", "/"])], readOnly: true, slow: true),
        MaintTask(id: .listSnapshots, icon: "clock.arrow.circlepath", title: TT("List local Time Machine snapshots", S),
                  detail: TT("Shows the snapshots Time Machine keeps on this disk. They can use a lot of space.", S),
                  riskNote: TT("Safe. Read-only.", S), risk: .none, admin: false,
                  commands: [MaintCommand(exe: "/usr/bin/tmutil", args: ["listlocalsnapshots", "/"])], readOnly: true, slow: false),
        MaintTask(id: .thinSnapshots, icon: "scissors", title: TT("Thin local Time Machine snapshots", S),
                  detail: TT("Deletes old local snapshots to free about 10 GB. Your backups on the backup disk are not touched.", S),
                  riskNote: TT("Deleted snapshots cannot be restored: you lose those local restore points.", S), risk: .medium, admin: true,
                  commands: [MaintCommand(exe: "/usr/bin/tmutil", args: ["thinlocalsnapshots", "/", String(thinBytes), String(thinUrgency)])], readOnly: false, slow: false),
    ]
    static func task(_ id: MaintID) -> MaintTask { tasks.first { $0.id == id }! }

    /// AppleScript source for the standard macOS admin prompt. Built ONLY from the fixed command table (shell-quoted, then AppleScript-escaped).
    static func adminScript(_ cmds: [MaintCommand]) -> String {
        let shell = cmds.map(\.display).joined(separator: " && ")
        let esc = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(esc)\" with administrator privileges"
    }
}

struct MaintResult: Equatable { let ok: Bool; let output: String; let date: Date }

// MARK: - model

@MainActor final class MaintenanceModel: ObservableObject {
    static let shared = MaintenanceModel()
    @Published var results: [MaintID: MaintResult] = [:]
    @Published var running: MaintID?
    @Published var message: String?
    var runner: CommandRunner
    init(runner: CommandRunner = SystemCommandRunner()) { self.runner = runner }

    /// The exact lines the consent panel shows: what really runs (the osascript wrapper for admin tasks, the plain commands otherwise).
    func preview(_ id: MaintID) -> [String] {
        let t = Maintenance.task(id)
        return t.admin ? [MaintCommand(exe: "/usr/bin/osascript", args: ["-e", Maintenance.adminScript(t.commands)]).display] : t.commands.map(\.display)
    }

    /// Synchronous core (the view calls it off the main thread). `confirmed` is the consent panel's Run button; destructive tasks refuse without it.
    nonisolated static func execute(_ id: MaintID, confirmed: Bool, runner: CommandRunner) -> MaintResult {
        let t = Maintenance.task(id)
        guard confirmed else { return MaintResult(ok: false, output: "Refused: not confirmed", date: Date()) }
        var out = "", ok = true
        if t.admin {
            let r = runner.run("/usr/bin/osascript", ["-e", Maintenance.adminScript(t.commands)], timeout: 120)
            out = r.output; ok = r.status == 0
        } else {
            for c in t.commands {
                let r = runner.run(c.exe, c.args, timeout: t.slow ? 1800 : 120)
                out += r.output; if r.status != 0 { ok = false; break }
            }
        }
        return MaintResult(ok: ok, output: out.trimmingCharacters(in: .whitespacesAndNewlines), date: Date())
    }

    func run(_ id: MaintID, confirmed: Bool) async {
        guard running == nil else { return }
        guard confirmed else { message = TT("Confirmation needed", S); return }
        running = id; message = nil
        let r = runner
        let res = await Task.detached { MaintenanceModel.execute(id, confirmed: true, runner: r) }.value
        withAnimation(spring) { results[id] = res; running = nil }
    }
}

// MARK: - view

struct MaintenanceView: View {
    @ObservedObject private var m = MaintenanceModel.shared
    @State private var pending: MaintID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(TT("Maintenance", S)).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(TT("Each task shows the exact command before it runs. Tasks that need an administrator use the standard macOS password prompt.", S)).font(.caption).opacity(0.65)
                if let msg = m.message { Text(msg).font(.callout).foregroundStyle(.orange) }
                ForEach(Maintenance.tasks) { card($0) }
            }.padding(20)
        }
        .foregroundStyle(.white)
        .sheet(item: Binding(get: { pending.map { Pending(id: $0) } }, set: { pending = $0?.id })) { p in ConsentSheet(m: m, id: p.id) { pending = nil } }
    }

    private struct Pending: Identifiable { let id: MaintID }

    private func card(_ t: MaintTask) -> some View {
        let r = m.results[t.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: t.icon).font(.system(size: 20)).frame(width: 30).foregroundStyle(Color(hex: 0xFF8AD1))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(t.title).font(.body.weight(.semibold))
                        if t.admin { badge(TT("Asks for your password", S), .gray) }
                        if t.readOnly { badge(TT("Read-only", S), .green) }
                    }
                    Text(t.detail).font(.callout).opacity(0.8)
                    Label(t.riskNote, systemImage: t.risk == .medium ? "exclamationmark.triangle.fill" : "info.circle").font(.caption)
                        .foregroundStyle(t.risk == .medium ? Color.orange : Color.white.opacity(0.6))
                }
                Spacer()
                Button { pending = t.id } label: { SpinnerLabel(title: TT("Run", S), busy: m.running == t.id) }.buttonStyle(SoftButton()).disabled(m.running != nil)
            }
            if let r {
                VStack(alignment: .leading, spacing: 3) {
                    Label(r.ok ? TT("Done", S) : TT("Failed", S), systemImage: r.ok ? "checkmark.circle" : "xmark.octagon").font(.caption.weight(.semibold)).foregroundStyle(r.ok ? Color.green : .red)
                    if !r.output.isEmpty {
                        Text(r.output).font(.system(.caption, design: .monospaced)).opacity(0.75).lineLimit(8).textSelection(.enabled)
                    }
                }
            }
        }.padding(14).glass(16)
    }

    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 2).background(c.opacity(0.35), in: Capsule())
    }
}

private struct ConsentSheet: View {
    @ObservedObject var m: MaintenanceModel
    let id: MaintID
    let close: () -> Void
    var body: some View {
        let t = Maintenance.task(id)
        VStack(alignment: .leading, spacing: 12) {
            Text(TTF("Run: %@", S, t.title)).font(.headline)
            Text(t.admin ? TT("This exact command will run with administrator privileges. macOS will ask for your password.", S) : TT("This exact command will run as your user.", S)).font(.callout).opacity(0.85)
            Text(m.preview(id).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            Text(t.riskNote).font(.callout).foregroundStyle(t.risk == .medium ? Color.orange : Color.white.opacity(0.7))
            if t.destructive { Text(TT("This cannot be undone.", S)).font(.callout.weight(.semibold)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(TT("Cancel", S)) { close() }.buttonStyle(SoftButton())
                Button(t.destructive ? TT("Delete snapshots", S) : TT("Run", S)) { close(); Task { await m.run(id, confirmed: true) } }.buttonStyle(PinkButton())
            }
        }.padding(24).frame(width: 520).foregroundStyle(.white).background(Background())
    }
}

// MARK: - self test

final class FakeMaintRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [String])] = []
    var status: Int32 = 0, output = "ok"
    var calls: [(String, [String])] { lock.lock(); defer { lock.unlock() }; return _calls }
    func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        lock.lock(); _calls.append((exe, args)); lock.unlock(); return (status, output)
    }
}

enum MaintenanceSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let tasks = Maintenance.tasks
        t.check(Set(tasks.map(\.id)) == Set(MaintID.allCases) && tasks.count == MaintID.allCases.count, "command table covers every task once"); t.reachedCode()
        t.check(tasks.allSatisfy { $0.commands.allSatisfy { $0.exe.hasPrefix("/") && !$0.exe.contains(" ") } }, "every executable is an absolute fixed path")
        t.check(tasks.filter(\.readOnly).allSatisfy { !$0.admin } && tasks.filter(\.admin).allSatisfy { !$0.readOnly }, "read-only tasks never ask for admin")
        t.check(Maintenance.task(.verifyDisk).commands == [MaintCommand(exe: "/usr/sbin/diskutil", args: ["verifyVolume", "/"])] && Maintenance.task(.listSnapshots).commands.first?.args == ["listlocalsnapshots", "/"], "verify and list are the read-only forms")
        t.check(Maintenance.task(.thinSnapshots).destructive && tasks.filter(\.destructive).count == 1, "only thinning is destructive")

        // quoting and AppleScript escaping
        t.check(MaintCommand(exe: "/bin/x", args: ["a b", "it's", "plain-1"]).display == "/bin/x 'a b' 'it'\\''s' plain-1", "shell quoting of odd arguments")
        let evil = Maintenance.adminScript([MaintCommand(exe: "/bin/echo", args: ["a\"b\\c"])])
        t.check(evil == "do shell script \"/bin/echo 'a\\\"b\\\\c'\" with administrator privileges", "AppleScript escaping of quote and backslash")
        let dns = Maintenance.adminScript(Maintenance.task(.flushDNS).commands)
        t.check(dns == "do shell script \"/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder\" with administrator privileges", "admin script built from the table, chained with &&")

        // runner protocol: fake only, never the real commands
        let fake = FakeMaintRunner()
        let m = MaintenanceModel(runner: fake)
        let pv = m.preview(.flushDNS)
        t.check(pv.count == 1 && pv[0].hasPrefix("/usr/bin/osascript -e ") && pv[0].contains("dscacheutil") && pv[0].contains("with administrator privileges"), "consent panel shows the exact osascript command for admin tasks")
        t.check(m.preview(.verifyDisk) == ["/usr/sbin/diskutil verifyVolume /"], "consent panel shows plain commands for non-admin tasks")

        await m.run(.thinSnapshots, confirmed: false)
        t.check(fake.calls.isEmpty && m.results[.thinSnapshots] == nil, "nothing runs without confirmation")
        t.check(!MaintenanceModel.execute(.thinSnapshots, confirmed: false, runner: fake).ok && fake.calls.isEmpty, "execute() refuses unconfirmed too")

        t.reachedCode(); await m.run(.flushDNS, confirmed: true)
        t.check(fake.calls.count == 1 && fake.calls[0].0 == "/usr/bin/osascript" && fake.calls[0].1.first == "-e" && fake.calls[0].1[1] == dns, "admin task goes through osascript with the table script")
        t.check(m.results[.flushDNS]?.ok == true && m.running == nil, "result recorded, runner released")

        await m.run(.verifyDisk, confirmed: true)
        t.check(fake.calls.count == 2 && fake.calls[1].0 == "/usr/sbin/diskutil" && fake.calls[1].1 == ["verifyVolume", "/"], "read-only task runs its command directly")

        fake.output = "com.apple.TimeMachine.2026-01-01-120000.local"
        await m.run(.listSnapshots, confirmed: true)
        t.check(m.results[.listSnapshots]?.output.contains("TimeMachine") == true && fake.calls.last?.1 == ["listlocalsnapshots", "/"], "snapshot listing output kept")

        fake.status = 1; fake.output = "User canceled"
        await m.run(.reindexSpotlight, confirmed: true)
        t.check(m.results[.reindexSpotlight]?.ok == false && m.results[.reindexSpotlight]?.output == "User canceled", "failed or cancelled admin prompt reported as failure")

        let before = fake.calls.count
        await m.run(.thinSnapshots, confirmed: true)
        t.check(fake.calls.count == before + 1 && fake.calls.last?.1[1].contains("thinlocalsnapshots / 10000000000 4") == true, "thinning runs only after confirmation, with the typed constants")
        let all = fake.calls.map(\.0)
        t.check(all.allSatisfy { ["/usr/bin/osascript", "/usr/sbin/diskutil", "/usr/bin/tmutil"].contains($0) }, "only fake runner was used (\(all.count) calls)")
    }
}

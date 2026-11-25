import SwiftUI
import AppKit

private let S = "Startup"

struct StartupView: View {
    @ObservedObject private var m = StartupModel.shared

    private var groups: [(String, [StartupItem])] {
        let ok = m.items.filter { !$0.broken }
        return [(TT("User agents", S), ok.filter { $0.kind == .userAgent }),
                (TT("System agents", S), ok.filter { $0.kind == .systemAgent }),
                (TT("System daemons", S), ok.filter { $0.kind == .systemDaemon }),
                (TT("Broken", S), m.items.filter(\.broken))].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                note
                Spacer()
                Button(TT("Rescan", S)) { m.scan() }.buttonStyle(SoftButton()).disabled(m.scanning)
            }
            if let msg = m.message { Text(msg).font(.callout).foregroundStyle(.orange) }
            if m.scanning && m.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.0) { g in
                            Text(g.0).font(.headline).opacity(0.85)
                            ForEach(g.1) { StartupRow(item: $0, m: m).transition(.opacity.combined(with: .move(edge: .leading))) }
                        }
                        if m.items.isEmpty { Text(TT("No launch items found", S)).opacity(0.6) }
                    }.padding(.bottom, 20)
                }
            }
        }
        .padding(20).foregroundStyle(.white)
        .animation(spring, value: m.items)
        .onAppear { m.scanIfNeeded() }
    }

    @ViewBuilder private var note: some View {
        if let t = m.savedAt {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let f = DateFormatter(); let _ = f.timeStyle = .short
                let ago = RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date())
                VStack(alignment: .leading, spacing: 2) {
                    Text(TTF("Saved results from %@ (%@) — press Rescan to refresh", S, f.string(from: t), ago)).font(.caption).opacity(0.65)
                    if m.stale { Text(TT("Updated after recent actions — Rescan to be sure", S)).font(.caption).foregroundStyle(.yellow) }
                }
            }
        }
    }
}

private struct StartupRow: View {
    let item: StartupItem
    @ObservedObject var m: StartupModel

    private var badge: (String, Color) {
        if item.broken { return (TT("Broken", S), .red) }
        if item.kind != .userAgent { return (TT("Admin needed", S), .gray) }
        if item.disabled { return (TT("Disabled", S), .orange) }
        if item.loaded { return (item.runAtLoad || item.keepAlive ? TT("Running", S) : TT("Loaded", S), .green) }
        return (TT("Not loaded", S), .gray)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.appPath ?? item.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                Text(item.label + (item.appName == nil || item.vendor.isEmpty ? "" : " · " + item.vendor)).font(.caption).opacity(0.6).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(badge.0).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                .background(badge.1.opacity(0.35), in: Capsule())
            if item.editable && !item.broken {
                Toggle("", isOn: Binding(get: { !item.disabled }, set: { _ in m.toggle(item) })).labelsHidden().toggleStyle(.switch)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "folder") }
                .buttonStyle(SoftButton()).help(TT("Show in Finder", S))
            if item.broken && item.kind == .userAgent && !item.label.hasPrefix("com.apple.") {
                Button { m.trash(item) } label: { Image(systemName: "trash") }.buttonStyle(SoftButton()).help(TT("Move to Trash", S))
            }
        }.padding(10).glass(14)
    }
}

// MARK: - self test

final class FakeLaunchAgentControl: LaunchAgentControl, @unchecked Sendable {
    var calls: [String] = []
    var loaded = Set<String>(), disabled = Set<String>()
    func isLoaded(label: String) -> Bool { loaded.contains(label) }
    func isDisabled(label: String) -> Bool { disabled.contains(label) }
    func disable(label: String) -> Result<Void, EngineError> { calls.append("disable \(label)"); disabled.insert(label); loaded.remove(label); return .success(()) }
    func enable(label: String) -> Result<Void, EngineError> { calls.append("enable \(label)"); disabled.remove(label); return .success(()) }
}

enum StartupSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        let exe = f.file("Apps/Foo.app/Contents/MacOS/foo"), bin = f.file("bin/tool")
        func plist(_ dir: String, _ name: String, _ d: [String: Any]) -> String {
            let p = f.dir(dir) + "/" + name + ".plist"; (d as NSDictionary).write(toFile: p, atomically: true); return p
        }
        let ua = "home/Library/LaunchAgents"
        _ = plist(ua, "com.foo.run", ["Label": "com.foo.run", "ProgramArguments": [exe, "-x"], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false]])
        _ = plist(ua, "org.bar.plain", ["Label": "org.bar.plain", "Program": bin, "Disabled": true])
        let brokenP = plist(ua, "com.gone.helper", ["Label": "com.gone.helper", "ProgramArguments": ["/nonexistent/helper"]])
        _ = plist(ua, "com.apple.thing", ["Label": "com.apple.thing", "Program": bin])
        _ = plist("sys/LaunchAgents", "com.sys.agent", ["Label": "com.sys.agent", "Program": bin])
        _ = plist("sys/LaunchDaemons", "com.sys.daemon", ["Label": "com.sys.daemon", "Program": "/nonexistent/d"])
        let roots = StartupRoots(userAgents: f.home + "/Library/LaunchAgents", systemAgents: f.root + "/sys/LaunchAgents", systemDaemons: f.root + "/sys/LaunchDaemons")
        let ctl = FakeLaunchAgentControl(); ctl.loaded = ["com.foo.run"]
        let items = StartupScanner.scan(roots, control: ctl); t.reachedCode()
        func it(_ l: String) -> StartupItem? { items.first { $0.label == l } }
        let run = it("com.foo.run")
        t.check(items.count == 6, "inventory lists user + system roots (\(items.count))")
        t.check(run?.runAtLoad == true && run?.keepAlive == true && run?.program == exe && run?.loaded == true, "parses RunAtLoad/KeepAlive/ProgramArguments[0], loaded from control")
        t.check(run?.appName == "Foo" && run?.vendor == "Foo" && it("org.bar.plain")?.vendor == "Bar", "owner app + vendor guess")
        t.check(it("org.bar.plain")?.plistDisabled == true && it("org.bar.plain")?.disabled == true && it("org.bar.plain")?.broken == false, "Disabled key parsed, Program used")
        t.check(it("com.gone.helper")?.broken == true && run?.broken == false, "missing program flagged Broken")
        t.check(it("com.sys.agent")?.kind == .systemAgent && it("com.sys.daemon")?.kind == .systemDaemon && it("com.sys.agent")?.editable == false, "system roots listed read-only")
        t.check(it("com.apple.thing")?.editable == false, "com.apple.* not editable")

        let m = StartupModel(control: ctl, roots: roots); m.items = items
        m.toggle(it("com.sys.agent")!); m.toggle(it("com.sys.daemon")!); m.toggle(it("com.apple.thing")!)
        t.check(ctl.calls.isEmpty, "system items and Apple labels never reach disable/enable")
        m.toggle(it("com.foo.run")!)
        t.check(ctl.calls == ["disable com.foo.run"] && m.items.first { $0.label == "com.foo.run" }?.disabled == true && m.items.first { $0.label == "com.foo.run" }?.loaded == false, "disable calls control and refreshes state")
        m.toggle(m.items.first { $0.label == "com.foo.run" }!)
        t.check(ctl.calls == ["disable com.foo.run", "enable com.foo.run"] && m.items.first { $0.label == "com.foo.run" }?.disabled == false, "enable follows, in order")
        t.check(FileManager.default.fileExists(atPath: ua.isEmpty ? "" : f.root + "/" + ua + "/com.foo.run.plist"), "toggling never deletes files")

        m.trash(it("com.sys.daemon")!); m.trash(it("com.foo.run")!)
        t.check(FileManager.default.fileExists(atPath: roots.systemDaemons + "/com.sys.daemon.plist") && FileManager.default.fileExists(atPath: roots.userAgents + "/com.foo.run.plist"), "trash refused for system and healthy items")
        m.trash(it("com.gone.helper")!)
        let log = ActionLog.all()
        t.check(!FileManager.default.fileExists(atPath: brokenP) && log.count == 1 && log[0].path == brokenP && (log[0].trashedTo ?? "").hasPrefix(f.home + "/.Trash"), "broken plist trashed to fake Trash and logged")
        t.check(!m.items.contains { $0.label == "com.gone.helper" } && m.stale, "handleEngineChange dropped trashed item and set stale")
        if let e = log.first { try? Engine.undo(e) }
        t.check(FileManager.default.fileExists(atPath: brokenP), "trash is undoable")
        m.stale = false; m.handleEngineChange(op: "undo", paths: [brokenP])
        t.check(m.stale, "undo flags stale")
    }
}

import SwiftUI
import AppKit

/// The macOS Trash, always one click away: size, show in Finder, empty (permanent, so it asks first).
/// Everything LickMyPaw removes goes to the Trash (undoable) — space is only really freed once it is emptied.
enum TrashBin {
    static var path: String { Env.trashDir }
    /// Empties the Trash. Injectable for tests. Default: ask Finder (handles per-volume trashes, needs the Automation permission once).
    nonisolated(unsafe) static var emptier: @Sendable () async -> Result<Void, EngineError> = { await finderEmpty() }

    /// nil = cannot be read (no Full Disk Access).
    static func size() -> Int64? {
        guard (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil else { return nil }
        return Scanner.scan(path: path, progress: Progress()).size
    }
    static func show() { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    static func finderEmpty() async -> Result<Void, EngineError> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
                if let err {
                    let code = err[NSAppleScript.errorNumber] as? Int ?? 0
                    let msg = code == -1743 ? TT("Allow LickMyPaw to control Finder in System Settings → Privacy & Security → Automation.", "Trash")
                                            : (err[NSAppleScript.errorMessage] as? String ?? "error \(code)")
                    cont.resume(returning: .failure(EngineError(message: msg)))
                } else { cont.resume(returning: .success(())) }
            }
        }
    }
}

@MainActor final class TrashModel: ObservableObject {
    static let shared = TrashModel()
    @Published var size: Int64?          // nil = unreadable
    @Published var loaded = false
    @Published var emptying = false
    @Published var message: String?
    private var token: NSObjectProtocol?

    init() {
        // queue: nil + hop to the main actor (queue: .main deadlocks when Engine.trash posts from the main thread)
        token = NotificationCenter.default.addObserver(forName: Engine.didChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
    func refresh() async {
        if Demo.enabled { return }
        let s = await Task.detached(priority: .utility) { TrashBin.size() }.value
        size = s; loaded = true
    }
    func empty() async {
        emptying = true; message = nil
        switch await TrashBin.emptier() {
        case .success: message = TT("Trash emptied", "Trash")
        case .failure(let e): message = TTF("Could not empty the Trash: %@", "Trash", e.message)
        }
        emptying = false
        await refresh()
    }
}

struct TrashButton: View {
    @ObservedObject var m = TrashModel.shared
    @State private var open = false
    @State private var confirm = false

    var body: some View {
        Button { open.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: (m.size ?? 0) > 0 ? "trash.fill" : "trash").font(.system(size: 18)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(open ? 0.22 : 0)))
                if let s = m.size, s > 0 {
                    Text(fmt(s)).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Color(hex: 0xFF3FA4))).offset(x: 6, y: -2)
                }
            }
        }
        .buttonStyle(.plain).help(TT("Trash", "Trash"))
        .popover(isPresented: $open, arrowEdge: .trailing) { content.padding(16).frame(width: 290) }
        .task { await m.refresh() }
        .onChange(of: open) { if $0 { confirm = false; Task { await m.refresh() } } }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TT("Trash", "Trash")).font(.system(size: 16, weight: .bold, design: .rounded))
            if let s = m.size { Text(s > 0 ? TTF("%@ in Trash", "Trash", fmt(s)) : TT("Trash is empty", "Trash")).opacity(0.8) }
            else if m.loaded { Text(TT("Size unavailable — grant Full Disk Access to see it", "Trash")).font(.caption).opacity(0.7) }
            if let msg = m.message { Text(msg).font(.caption).foregroundStyle(Color(hex: 0xFF8FC8)).fixedSize(horizontal: false, vertical: true) }
            if confirm {
                Text(TT("Permanently delete everything in the Trash? This cannot be undone.", "Trash")).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(T("Cancel")) { withAnimation(spring) { confirm = false } }.buttonStyle(SoftButton())
                    Button { confirm = false; Task { await m.empty() } } label: { Text(TT("Empty Trash", "Trash")) }.buttonStyle(PinkButton())
                }
            } else {
                HStack {
                    Button(TT("Show Trash", "Trash")) { TrashBin.show() }.buttonStyle(SoftButton())
                    Button { withAnimation(spring) { confirm = true } } label: { SpinnerLabel(title: m.emptying ? TT("Emptying…", "Trash") : TT("Empty Trash…", "Trash"), busy: m.emptying) }
                        .buttonStyle(SoftButton()).disabled(m.emptying || m.size == 0)
                }
            }
        }
    }
}

enum TrashSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        let saved = TrashBin.emptier; defer { TrashBin.emptier = saved }
        t.check(TrashBin.size() == nil, "missing/unreadable Trash reports nil (not 0)"); t.reachedCode()
        f.file("home/.Trash/a.bin", kb: 512); f.file("home/.Trash/sub/b.bin", kb: 256)
        let s = TrashBin.size() ?? -1
        t.check(s >= 768 << 10 && s < 900 << 10, "Trash size counts nested files (\(s))")
        let m = TrashModel(); await m.refresh()
        t.check(m.loaded && m.size == s, "model refresh reads size")
        nonisolated(unsafe) var called = 0
        TrashBin.emptier = { called += 1; try? FileManager.default.removeItem(atPath: Env.trashDir + "/a.bin"); try? FileManager.default.removeItem(atPath: Env.trashDir + "/sub"); return .success(()) }
        await m.empty()
        t.check(called == 1 && (m.size ?? -1) == 0 && m.message == TT("Trash emptied", "Trash"), "empty() calls the emptier once, refreshes size to 0, reports success")
        TrashBin.emptier = { .failure(EngineError(message: "boom")) }
        await m.empty()
        t.check(m.message == TTF("Could not empty the Trash: %@", "Trash", "boom") && !m.emptying, "failure is reported and the spinner stops")
        // Engine events refresh the size
        f.file("home/.Trash/c.bin", kb: 100)
        Engine.announce("trash", [f.home + "/x"])
        for _ in 0..<20 where (m.size ?? 0) == 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        t.check((m.size ?? 0) >= 100 << 10, "Engine.didChange refreshes the Trash size")
    }
}

import Foundation
import SwiftUI

struct CleanGroup: Identifiable {
    let target: CleanupTarget
    let items: [CleanItem]
    var id: String { target.id }
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
}

@MainActor final class CleanupModel: ObservableObject {
    enum Phase { case idle, scanning, ready, cleaning, done }
    @Published var phase = Phase.idle
    @Published var groups: [CleanGroup] = []
    @Published var selected = Set<String>()
    @Published var expanded = Set<String>()
    @Published var freed: Int64 = 0
    @Published var failures: [String] = []
    @Published var batch: [ActionEntry] = []
    @Published var undone = false

    /// Process-wide cache: results live for the whole app session (in memory only).
    static let shared = CleanupModel()
    @Published var scannedAt: Date?
    @Published var stale = false
    @Published var now = Date()      // bumped on appear so the relative time refreshes
    var hasScanned: Bool { scannedAt != nil }
    var scanTask: Task<Void, Never>?
    var cleanTask: Task<Void, Never>?
    private let scanFn: @Sendable () -> [CleanGroup]
    private var ownPaths = Set<String>()   // paths this module is trashing itself: not "stale"

    nonisolated static func defaultScan() -> [CleanGroup] {
        let running = CleanupTargets.runningIDs()
        return CleanupTargets.all.map { CleanGroup(target: $0, items: CleanupTargets.items($0, running: running).sorted { $0.size > $1.size }) }.filter { !$0.items.isEmpty }
    }

    init(scanFn: @escaping @Sendable () -> [CleanGroup] = CleanupModel.defaultScan) {
        self.scanFn = scanFn
        NotificationCenter.default.addObserver(forName: Engine.didChange, object: nil, queue: nil) { [weak self] n in   // queue: .main would deadlock when posted from main
            let op = n.userInfo?["op"] as? String ?? "", paths = n.userInfo?["paths"] as? [String] ?? []
            Task { @MainActor in self?.handleEngineChange(op: op, paths: paths) }
        }
    }

    var selectedItems: [CleanItem] { groups.flatMap(\.items).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    /// Page appeared: auto-scan only the very first time; otherwise keep the cache.
    func appear() {
        now = Date()
        if !hasScanned && phase == .idle { scan() }
    }

    func scan() {
        phase = .scanning; undone = false
        let f = scanFn
        scanTask = Task {
            let gs = await Task.detached { f() }.value
            let old = Set(groups.flatMap(\.items).map(\.id)), prev = selected
            groups = gs
            selected = Set(gs.flatMap(\.items).filter { prev.contains($0.id) || (!old.contains($0.id) && $0.risk == .low) }.map(\.id))
            scannedAt = Date(); now = scannedAt!; stale = false
            withAnimation(spring) { phase = .ready }
        }
    }

    /// Drop items under trashed paths (or gone from disk); flag stale unless the change is our own clean.
    func handleEngineChange(op: String, paths: [String]) {
        guard hasScanned else { return }
        prune(paths)
        if op == "undo" || !paths.allSatisfy({ ownPaths.contains($0) }) { stale = true }
    }

    private func prune(_ trashed: [String]) {
        let fm = FileManager.default
        groups = groups.compactMap { g in
            let its = g.items.filter { i in !trashed.contains { i.path == $0 || i.path.hasPrefix($0 + "/") } && fm.fileExists(atPath: i.path) }
            return its.isEmpty ? nil : CleanGroup(target: g.target, items: its)
        }
        selected.formIntersection(groups.flatMap(\.items).map(\.id))
    }

    static func relative(_ from: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(from)))
        if s < 60 { return TT("just now", "Cleanup") }
        if s < 3600 { return TTF("%d min ago", "Cleanup", s / 60) }
        if s < 86400 { return TTF("%d h ago", "Cleanup", s / 3600) }
        return TTF("%d d ago", "Cleanup", s / 86400)
    }

    var savedNote: String? {
        guard let t = scannedAt else { return nil }
        let df = DateFormatter(); df.dateStyle = .none; df.timeStyle = .short
        return TTF("Saved results from %@ (%@) — press Rescan to refresh", "Cleanup", df.string(from: t), Self.relative(t, now: now))
    }

    /// Trash each selected item (Safety automatic mode, logged, undoable). Returns (entries, failures).
    nonisolated static func clean(_ items: [CleanItem]) -> ([ActionEntry], [String]) {
        var ok: [ActionEntry] = [], bad: [String] = []
        for i in items {
            do { ok.append(try Engine.trash(i.path, size: i.size, mode: .automatic)) } catch { bad.append("\(i.name): \(error.localizedDescription)") }
        }
        return (ok, bad)
    }

    func clean() {
        let items = selectedItems; phase = .cleaning
        ownPaths = Set(items.map(\.path))
        cleanTask = Task {
            let (ok, bad) = await Task.detached { CleanupModel.clean(items) }.value
            batch = ok; failures = bad; freed = ok.reduce(0) { $0 + $1.size }
            prune([])   // in place, no rescan
            withAnimation(spring) { phase = .done }
        }
    }

    func undo() {
        for e in batch { try? Engine.undo(e) }
        stale = true   // restored items are not in the list: rescan to see them
        withAnimation(spring) { undone = true }
    }

    func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
}

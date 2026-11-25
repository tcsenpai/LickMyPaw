import Foundation
import SwiftUI

struct RemoveResult { var batch: [ActionEntry]; var failures: [String]; var freed: Int64; var undone = false }

@MainActor final class ClutterModel: ObservableObject {
    static let shared = ClutterModel()
    nonisolated static let floorBytes: Int64 = 1 << 20   // inventory keeps files >= 1 MB (the smallest filter either tab offers)

    enum Tab { case large, dups }
    @Published var tab = Tab.large
    @Published var root = Env.home
    @Published var files: [CFile] = []
    @Published var scannedAt: Date?
    @Published var scanning = false
    @Published var scanStats = (bytes: Int64(0), files: 0)
    @Published var stale = false
    @Published var minSize: Int64 = 100 << 20
    @Published var ageDays = 0
    @Published var selected = Set<String>()          // Large & Old selection

    @Published var groups: [DupGroup] = []
    @Published var dupMin: Int64 = 1 << 20
    @Published var dupAt: Date?
    @Published var dupScanning = false
    @Published var dupSelected = Set<String>()       // copies to remove; never all copies of a group
    @Published var result: RemoveResult?
    @Published var removing = false

    private var progress = Progress()
    private var obs: NSObjectProtocol?

    init() {
        obs = NotificationCenter.default.addObserver(forName: Engine.didChange, object: nil, queue: nil) { [weak self] n in
            let op = n.userInfo?["op"] as? String ?? "", paths = n.userInfo?["paths"] as? [String] ?? []
            Task { @MainActor in self?.handleEngineChange(op: op, paths: paths) }
        }
    }

    var visible: [CFile] { LargeOld.filter(files, minSize: minSize, ageDays: ageDays) }
    var selectedLarge: [CFile] { visible.filter { selected.contains($0.path) } }
    var selectedDup: [CFile] { groups.flatMap(\.files).filter { dupSelected.contains($0.path) } }

    // MARK: scanning (manual only; results live for the app session)
    func scan() { Task { await runScan() } }
    func cancel() { progress.cancelled = true }

    func runScan() async {
        guard !scanning else { return }
        scanning = true; stale = false; progress = Progress()
        let p = progress, r = root
        let ticker = Task { while !Task.isCancelled { scanStats = p.snapshot; try? await Task.sleep(nanoseconds: 200_000_000) } }
        let found = await Task.detached { LargeOld.walk(r, floor: ClutterModel.floorBytes, progress: p) }.value
        ticker.cancel()
        if !p.cancelled { files = found; scannedAt = Date(); selected = []; groups = []; dupSelected = []; dupAt = nil }
        scanning = false
    }

    func findDuplicates() { Task { await runDuplicates() } }
    func runDuplicates(minSize: Int64? = nil) async {
        guard !dupScanning else { return }
        if let m = minSize { dupMin = m }
        dupScanning = true; progress = Progress()
        let p = progress, fs = files, m = dupMin
        let g = await Task.detached { Duplicates.find(fs, minSize: m, progress: p) }.value
        if !p.cancelled { groups = g; dupSelected = []; dupAt = Date(); stale = false }
        dupScanning = false
    }

    // MARK: selection
    func toggle(_ path: String) { if selected.contains(path) { selected.remove(path) } else { selected.insert(path) } }

    /// Returns false (and changes nothing) when it would select every copy of the group: one copy always stays.
    @discardableResult func toggleDup(_ path: String) -> Bool {
        if dupSelected.contains(path) { dupSelected.remove(path); return true }
        guard let g = groups.first(where: { $0.files.contains { $0.path == path } }) else { return false }
        guard g.files.filter({ dupSelected.contains($0.path) }).count < g.files.count - 1 else { return false }
        dupSelected.insert(path); return true
    }
    func autoSelect(keepOldest: Bool) {
        dupSelected = Set(groups.flatMap { g -> [String] in
            let keep = keepOldest ? g.oldest.path : g.shortest.path
            return g.files.map(\.path).filter { $0 != keep }
        })
    }

    // MARK: removal (Trash + undo log only)
    func remove(_ items: [CFile]) async {
        guard !removing, !items.isEmpty else { return }
        removing = true
        let (ok, bad) = await Task.detached { () -> ([ActionEntry], [String]) in
            var ok: [ActionEntry] = [], bad: [String] = []
            for i in items {
                do { ok.append(try Engine.trash(i.path, size: i.size, mode: .userSelected)) } catch { bad.append("\(i.name): \(error.localizedDescription)") }
            }
            return (ok, bad)
        }.value
        handleEngineChange(op: "trash", paths: ok.map(\.path))
        withAnimation(spring) { result = RemoveResult(batch: ok, failures: bad, freed: ok.reduce(0) { $0 + $1.size }) }
        removing = false
    }

    func undo() {
        guard var r = result else { return }
        for e in r.batch { try? Engine.undo(e) }
        r.undone = true
        withAnimation(spring) { result = r }
    }

    /// Engine.didChange: drop vanished files, fix totals/selections, flag stale (never auto-rescans).
    func handleEngineChange(op: String, paths: [String]) {
        guard !paths.isEmpty, scannedAt != nil else { return }
        func gone(_ f: String) -> Bool { paths.contains { f == $0 || f.hasPrefix($0 + "/") } }
        if op == "trash" {
            files.removeAll { gone($0.path) }
            groups = groups.compactMap { g in
                var g = g; g.files.removeAll { gone($0.path) }
                return g.files.count > 1 ? g : nil
            }
            let alive = Set(files.map(\.path))
            selected.formIntersection(alive)
            dupSelected = dupSelected.filter { p in groups.contains { $0.files.contains { $0.path == p } } }
            // never leave a group with every copy selected
            for g in groups where g.files.allSatisfy({ dupSelected.contains($0.path) }) { dupSelected.remove(g.files[0].path) }
        }
        stale = true
    }
}

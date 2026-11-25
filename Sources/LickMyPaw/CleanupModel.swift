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

    var selectedItems: [CleanItem] { groups.flatMap(\.items).filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func scan() {
        phase = .scanning; undone = false
        Task {
            let running = CleanupTargets.runningIDs()
            let gs = await Task.detached { CleanupTargets.all.map { CleanGroup(target: $0, items: CleanupTargets.items($0, running: running).sorted { $0.size > $1.size }) }.filter { !$0.items.isEmpty } }.value
            groups = gs
            selected = Set(gs.flatMap(\.items).filter { $0.risk == .low }.map(\.id))
            withAnimation(spring) { phase = .ready }
        }
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
        Task {
            let (ok, bad) = await Task.detached { CleanupModel.clean(items) }.value
            batch = ok; failures = bad; freed = ok.reduce(0) { $0 + $1.size }
            withAnimation(spring) { phase = .done }
        }
    }

    func undo() {
        for e in batch { try? Engine.undo(e) }
        withAnimation(spring) { undone = true }
    }

    func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
}

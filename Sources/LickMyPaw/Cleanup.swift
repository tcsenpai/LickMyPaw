import SwiftUI

private func C(_ k: String) -> String { TT(k, "Cleanup") }

struct CleanupView: View {
    @ObservedObject private var m = CleanupModel.shared
    @State private var confirm = false

    var body: some View {
        ZStack {
            Background()
            VStack(spacing: 16) {
                HStack {
                    Text(C("Cleanup")).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Spacer()
                    if m.phase == .ready || m.phase == .done || m.phase == .idle {
                        Button(m.hasScanned ? C("Rescan") : C("Scan")) { m.scan() }.buttonStyle(SoftButton())
                    }
                }
                notes
                content
                if m.phase == .ready { bar }
            }.padding(24)
        }
        .onAppear { m.appear() }
        .sheet(isPresented: $confirm) { confirmSheet }
    }

    @ViewBuilder private var notes: some View {
        if let n = m.savedNote {
            VStack(alignment: .leading, spacing: 2) {
                Text(n)
                if m.stale { Text(C("Updated after recent actions — Rescan to be sure")) }
            }.font(.caption).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var content: some View {
        switch m.phase {
        case .idle, .scanning, .cleaning:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(.white)
                Text(m.phase == .cleaning ? C("Cleaning…") : C("Scanning…")).foregroundStyle(.white.opacity(0.8))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if m.groups.isEmpty { Text(C("Nothing to clean")).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ScrollView { VStack(spacing: 12) { ForEach(m.groups) { card($0) } } } }
        case .done:
            VStack(spacing: 14) {
                Text(TTF("Freed %@", "Cleanup", fmt(m.freed))).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                if !m.failures.isEmpty { Text(TTF("%d items could not be cleaned", "Cleanup", m.failures.count)).foregroundStyle(.white.opacity(0.7)) }
                if m.undone { Text(C("Restored")).foregroundStyle(.white.opacity(0.8)) }
                else if !m.batch.isEmpty { Button(C("Undo")) { m.undo() }.buttonStyle(PinkButton()) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func card(_ g: CleanGroup) -> some View {
        let open = m.expanded.contains(g.id)
        return VStack(spacing: 0) {
            Button {
                withAnimation(spring) { if open { m.expanded.remove(g.id) } else { m.expanded.insert(g.id) } }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: g.target.icon).font(.system(size: 18)).foregroundStyle(.white).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(C(g.target.name)).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        Text(C(g.target.category)).font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Text(fmt(g.total)).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.white.opacity(0.6))
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                VStack(spacing: 0) {
                    ForEach(g.items) { i in
                        Button { m.toggle(i.id) } label: {
                            HStack {
                                Image(systemName: m.selected.contains(i.id) ? "checkmark.square.fill" : "square").foregroundStyle(.white)
                                Text(i.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.white.opacity(0.9))
                                Spacer()
                                Text(fmt(i.size)).foregroundStyle(.white.opacity(0.6))
                            }.font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.bottom, 10).transition(.opacity)
            }
        }.glass()
    }

    private var bar: some View {
        HStack {
            Text(TTF("%d items selected  |  %@", "Cleanup", m.selected.count, fmt(m.selectedSize))).foregroundStyle(.white)
            Spacer()
            Button(C("Clean")) { confirm = true }.buttonStyle(PinkButton()).disabled(m.selected.isEmpty)
        }.padding(.horizontal, 18).padding(.vertical, 12).glass()
    }

    private var confirmSheet: some View {
        let sel = Set(m.selectedItems.map(\.targetID))
        return VStack(alignment: .leading, spacing: 12) {
            Text(C("Move to Trash?")).font(.title2.bold())
            ForEach(m.groups.filter { sel.contains($0.id) }) { g in
                let its = g.items.filter { m.selected.contains($0.id) }
                HStack { Text(C(g.target.name)); Spacer(); Text(fmt(its.reduce(0) { $0 + $1.size })).foregroundStyle(.secondary) }
            }
            Divider()
            HStack { Text(C("Total")).bold(); Spacer(); Text(fmt(m.selectedSize)).bold() }
            Text(C("Items go to the Trash and can be undone.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(C("Cancel")) { confirm = false }
                Button(C("Clean")) { confirm = false; m.clean() }.buttonStyle(PinkButton())
            }
        }.padding(24).frame(width: 380)
    }
}

enum CleanupSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        let savedRun = CleanupTargets.runningIDs, savedEx = UserDefaults.standard.stringArray(forKey: "exclusions")
        defer { CleanupTargets.runningIDs = savedRun; UserDefaults.standard.set(savedEx, forKey: "exclusions") }
        CleanupTargets.runningIDs = { ["com.test.running"] }
        UserDefaults.standard.removeObject(forKey: "exclusions")

        f.file("home/Library/Caches/com.test.a/x.bin", kb: 100)
        f.file("home/Library/Caches/com.test.b/y.bin", kb: 50)
        f.file("home/Library/Caches/com.test.running/z.bin", kb: 10)
        f.file("home/Library/Caches/com.apple.fragile/k.bin", kb: 10)
        f.file("home/Library/Caches/Homebrew/dl.bin", kb: 30)
        f.file("home/Library/Developer/Xcode/DerivedData/Proj-abc/b.o", kb: 200)
        f.file("home/.npm/_cacache/content/n.bin", kb: 64)
        let outside = f.file("home/Documents/keep.txt")
        let run = CleanupTargets.runningIDs()
        func items(_ id: String) -> [CleanItem] { CleanupTargets.items(CleanupTargets.all.first { $0.id == id }!, running: run) }

        let caches = items("caches"); t.reachedCode()
        t.check(Set(caches.map(\.name)) == ["com.test.a", "com.test.b"], "caches: A and B only (running, fragile, Homebrew excluded): \(caches.map(\.name))")
        t.check(caches.first { $0.name == "com.test.a" }?.size == 100 << 10, "cache size is allocated bytes of the app dir")
        t.check(items("derived").map(\.name) == ["Proj-abc"] && items("npm").count == 1 && items("brew").count == 1, "DerivedData, npm, Homebrew enumerated")
        t.check(CleanupTargets.fragile("com.apple.Safari") && !CleanupTargets.fragile("com.apple.dt.Xcode"), "fragile list")

        UserDefaults.standard.set([f.home + "/Library/Caches/com.test.b"], forKey: "exclusions")
        t.check(items("caches").map(\.name) == ["com.test.a"], "Prefs.exclusions honored")
        UserDefaults.standard.removeObject(forKey: "exclusions")

        let a = caches.first { $0.name == "com.test.a" }!, b = caches.first { $0.name == "com.test.b" }!
        let (ok, bad) = CleanupModel.clean([a]); t.reachedCode()
        t.check(ok.count == 1 && bad.isEmpty && ok[0].size == a.size, "clean trashes the selected item")
        let fm = FileManager.default
        t.check(!fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path), "unselected item untouched")
        t.check(fm.fileExists(atPath: Env.trashDir + "/com.test.a") && ActionLog.all().count == 1, "item in fake Trash and logged")
        t.check(fm.fileExists(atPath: outside) && fm.fileExists(atPath: f.home + "/Library/Caches/com.apple.fragile"), "nothing outside selection touched")
        let (_, bad2) = CleanupModel.clean([CleanItem(path: outside, name: "keep.txt", size: 1, targetID: "x", risk: .low)])
        t.check(bad2.count == 1 && fm.fileExists(atPath: outside), "automatic mode refuses a path outside the allow-list")
        try? Engine.undo(ok[0])
        t.check(fm.fileExists(atPath: a.path), "undo restores")

        // --- session cache ---
        final class Box: @unchecked Sendable { var n = 0 }
        let sc = Box()
        let m = CleanupModel(scanFn: { sc.n += 1; return CleanupModel.defaultScan() })
        m.appear(); await m.scanTask?.value; t.reachedCode()
        m.appear(); m.appear(); await m.scanTask?.value
        t.check(sc.n == 1 && m.hasScanned && m.scannedAt != nil && !m.stale && m.phase == .ready, "opening twice scans exactly once (\(sc.n))")
        m.scan(); await m.scanTask?.value
        t.check(sc.n == 2, "explicit rescan scans again")
        let ids = m.groups.flatMap(\.items)
        let ia = ids.first { $0.name == "com.test.b" }!, ib = ids.first { $0.name == "com.test.a" }!
        m.toggle(ia.id)   // user deselects b
        let selBefore = m.selected
        m.handleEngineChange(op: "trash", paths: [ib.path])
        t.check(!m.groups.flatMap(\.items).contains { $0.id == ib.id } && m.stale, "foreign trash removes item and sets stale")
        t.check(m.selected == selBefore.subtracting([ib.id]) && !m.selected.contains(ia.id), "other selection preserved")
        t.check(sc.n == 2, "no rescan after engine change")
        let now = Date()
        t.check(CleanupModel.relative(now, now: now) == TT("just now", "Cleanup") && CleanupModel.relative(now.addingTimeInterval(-59), now: now) == TT("just now", "Cleanup")
                && CleanupModel.relative(now.addingTimeInterval(-180), now: now) == TTF("%d min ago", "Cleanup", 3)
                && CleanupModel.relative(now.addingTimeInterval(-7300), now: now) == TTF("%d h ago", "Cleanup", 2)
                && CleanupModel.relative(now.addingTimeInterval(-200_000), now: now) == TTF("%d d ago", "Cleanup", 2), "relative time text")
        let sc2 = Box()
        let m2 = CleanupModel(scanFn: { sc2.n += 1; return CleanupModel.defaultScan() })
        m2.appear(); await m2.scanTask?.value
        let before = m2.selectedItems.count
        m2.clean(); await m2.cleanTask?.value
        try? await Task.sleep(nanoseconds: 300_000_000)   // let Engine.didChange deliver
        t.check(sc2.n == 1 && m2.phase == .done && !m2.stale && before > 0, "own clean: no rescan, not stale")
        t.check(!m2.batch.isEmpty && m2.groups.allSatisfy { g in g.items.allSatisfy { fm.fileExists(atPath: $0.path) } }, "own clean updates list in place")
        m2.undo(); t.check(m2.stale && m2.undone, "undo marks stale")
    }
}

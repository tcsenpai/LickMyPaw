import SwiftUI
import AppKit

private func C(_ k: String) -> String { TT(k, "Clutter") }

private let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()
private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
private let relFmt = makeRelativeFormatter()

private func reveal(_ p: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
private func icon(_ f: CFile) -> NSImage { Icons.icon(Node(name: f.name, path: f.path, isDir: false)) }

struct ClutterView: View {
    @ObservedObject private var m = ClutterModel.shared
    @State private var confirm = false
    private let maxRows = 300   // shortcut: only the biggest 300 rows are drawn; refine filters to see more

    var body: some View {
        ZStack {
            Background()
            VStack(spacing: 14) {
                header
                if m.scannedAt == nil && !m.scanning { empty } else {
                    note
                    if m.scanning { scanningView } else { tabContent }
                }
                if let r = m.result { resultBar(r) }
                else if bottomCount > 0 { bar }
            }.padding(24)
        }
        .sheet(isPresented: $confirm) { confirmSheet }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(C("Clutter")).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Spacer()
            Text((m.root as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.head)
            Button(C("Choose folder…")) { pick() }.buttonStyle(SoftButton()).disabled(m.scanning)
            if m.scanning { Button { m.cancel() } label: { SpinnerLabel(title: C("Cancel"), busy: true) }.buttonStyle(SoftButton()) }
            else { Button(m.scannedAt == nil ? C("Scan") : C("Rescan")) { m.scan() }.buttonStyle(PinkButton()) }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.full").font(.system(size: 44)).foregroundStyle(.white.opacity(0.7))
            Text(C("Find large, old and duplicate files")).font(.title3.bold()).foregroundStyle(.white)
            Text(C("Press Scan to look through the chosen folder. Nothing is scanned automatically.")).foregroundStyle(.white.opacity(0.65))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.white)
            Text(m.dupScanning ? C("Comparing files…") : TTF("Scanning… %d files, %@", "Clutter", m.scanStats.files, fmt(m.scanStats.bytes))).foregroundStyle(.white.opacity(0.8))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var note: some View {
        VStack(spacing: 4) {
            if let at = m.scannedAt {
                Text(TTF("Saved results from %@ (%@): press Rescan to refresh", "Clutter", timeFmt.string(from: at), relFmt.localizedString(for: at, relativeTo: Date())))
            }
            if m.stale { Text(C("Updated after recent actions: Rescan to be sure")).foregroundStyle(Color(hex: 0xFFB3E1)) }
        }.font(.caption).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var tabContent: some View {
        HStack(spacing: 8) {
            tabButton(C("Large & Old"), .large); tabButton(C("Duplicates"), .dups); Spacer()
        }
        if m.tab == .large { large } else { dups }
    }

    private func tabButton(_ t: String, _ tab: ClutterModel.Tab) -> some View {
        Button(t) { withAnimation(spring) { m.tab = tab } }.buttonStyle(SoftButton())
            .opacity(m.tab == tab ? 1 : 0.55).overlay(Capsule().strokeBorder(.white.opacity(m.tab == tab ? 0.6 : 0)))
    }

    // MARK: Large & Old
    private var large: some View {
        let rows = m.visible
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker(C("Size"), selection: $m.minSize) {
                    ForEach([Int64(50 << 20), 100 << 20, 500 << 20, 1 << 30], id: \.self) { Text("≥ " + fmt($0)).tag($0) }
                }.frame(width: 160)
                Picker(C("Not modified"), selection: $m.ageDays) {
                    Text(C("Any age")).tag(0); Text(C("90 days")).tag(90); Text(C("1 year")).tag(365); Text(C("2 years")).tag(730)
                }.frame(width: 190)
                Spacer()
                Text(TTF("%d files  |  %@", "Clutter", rows.count, fmt(rows.reduce(0) { $0 + $1.size }))).foregroundStyle(.white.opacity(0.7)).font(.caption)
            }.colorScheme(.dark)
            if rows.isEmpty { Text(C("No files match these filters")).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView { LazyVStack(spacing: 6) { ForEach(rows.prefix(maxRows)) { f in
                    HStack(spacing: 10) {
                        Button { m.toggle(f.path) } label: { Image(systemName: m.selected.contains(f.path) ? "checkmark.square.fill" : "square").foregroundStyle(.white) }.buttonStyle(.plain)
                        Image(nsImage: icon(f)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.white)
                            Text((f.folder as NSString).abbreviatingWithTildeInPath).font(.caption).lineLimit(1).truncationMode(.head).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        Text(dateFmt.string(from: f.mtime)).font(.caption).foregroundStyle(.white.opacity(0.55))
                        Text(fmt(f.size)).frame(width: 80, alignment: .trailing).foregroundStyle(.white.opacity(0.9))
                        Button { reveal(f.path) } label: { Image(systemName: "magnifyingglass.circle") }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).help(C("Show in Finder"))
                    }.font(.system(size: 13, design: .rounded)).padding(.horizontal, 12).padding(.vertical, 7).glass(14)
                } } }
            }
        }
    }

    // MARK: Duplicates
    private var dups: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker(C("Min size"), selection: $m.dupMin) {
                    ForEach([Int64(1 << 20), 10 << 20, 50 << 20, 100 << 20], id: \.self) { Text("≥ " + fmt($0)).tag($0) }
                }.frame(width: 170).colorScheme(.dark)
                Button(m.dupAt == nil ? C("Find duplicates") : C("Search again")) { m.findDuplicates() }.buttonStyle(SoftButton()).disabled(m.dupScanning)
                Spacer()
                if !m.groups.isEmpty {
                    Menu(C("Auto-select")) {
                        Button(C("Keep oldest")) { withAnimation(spring) { m.autoSelect(keepOldest: true) } }
                        Button(C("Keep shortest path")) { withAnimation(spring) { m.autoSelect(keepOldest: false) } }
                        Button(C("Clear selection")) { withAnimation(spring) { m.dupSelected = [] } }
                    }.menuStyle(.borderlessButton).fixedSize().colorScheme(.dark)
                    Text(TTF("%d groups  |  %@ reclaimable", "Clutter", m.groups.count, fmt(m.groups.reduce(0) { $0 + $1.wasted }))).foregroundStyle(.white.opacity(0.7)).font(.caption)
                }
            }
            if m.dupAt == nil { Text(C("Duplicates are matched by size, then a 64 KB sample, then a full SHA-256.")).foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if m.groups.isEmpty { Text(C("No duplicates found")).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ScrollView { LazyVStack(spacing: 12) { ForEach(m.groups.prefix(maxRows)) { card($0) } } } }
        }
    }

    private func card(_ g: DupGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(TTF("%d copies × %@", "Clutter", g.files.count, fmt(g.size))).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Spacer()
                Text(TTF("%@ reclaimable", "Clutter", fmt(g.wasted))).font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            ForEach(g.files) { f in
                let on = m.dupSelected.contains(f.path)
                HStack(spacing: 10) {
                    Button { withAnimation(spring) { _ = m.toggleDup(f.path) } } label: { Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(.white) }.buttonStyle(.plain)
                    Image(nsImage: icon(f)).resizable().frame(width: 22, height: 22)
                    Text((f.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.white.opacity(on ? 0.6 : 0.95))
                    Spacer()
                    Text(dateFmt.string(from: f.mtime)).font(.caption).foregroundStyle(.white.opacity(0.55))
                    Button { reveal(f.path) } label: { Image(systemName: "magnifyingglass.circle") }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8)).help(C("Show in Finder"))
                }.font(.system(size: 13, design: .rounded))
            }
            Text(C("At least one copy of every group always stays.")).font(.caption2).foregroundStyle(.white.opacity(0.4))
        }.padding(14).glass()
    }

    // MARK: removal
    private var items: [CFile] { m.tab == .large ? m.selectedLarge : m.selectedDup }
    private var bottomCount: Int { items.count }

    private var bar: some View {
        HStack {
            Text(TTF("%d items selected  |  %@", "Clutter", items.count, fmt(items.reduce(0) { $0 + $1.size }))).foregroundStyle(.white)
            Spacer()
            Button(C("Move to Trash")) { confirm = true }.buttonStyle(PinkButton()).disabled(m.removing)
        }.padding(.horizontal, 18).padding(.vertical, 12).glass()
    }

    private func resultBar(_ r: RemoveResult) -> some View {
        HStack {
            Text(r.undone ? C("Restored") : TTF("Moved to Trash: %@", "Clutter", fmt(r.freed))).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
            if !r.failures.isEmpty { Text(TTF("%d items could not be removed", "Clutter", r.failures.count)).font(.caption).foregroundStyle(.white.opacity(0.7)) }
            Spacer()
            if !r.undone && !r.batch.isEmpty { Button(C("Undo")) { m.undo() }.buttonStyle(PinkButton()) }
            Button(C("Dismiss")) { withAnimation(spring) { m.result = nil } }.buttonStyle(SoftButton())
        }.padding(.horizontal, 18).padding(.vertical, 12).glass()
    }

    private var confirmSheet: some View {
        let its = items
        return VStack(alignment: .leading, spacing: 12) {
            Text(C("Move to Trash?")).font(.title2.bold())
            ScrollView { VStack(alignment: .leading, spacing: 3) { ForEach(its.prefix(40)) { f in
                HStack { Text(f.name).lineLimit(1).truncationMode(.middle); Spacer(); Text(fmt(f.size)).foregroundStyle(.secondary) }.font(.system(size: 12))
            } } }.frame(maxHeight: 180)
            if its.count > 40 { Text(TTF("…and %d more", "Clutter", its.count - 40)).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack { Text(C("Total")).bold(); Spacer(); Text(fmt(its.reduce(0) { $0 + $1.size })).bold() }
            Text(C("Items go to the Trash and can be undone.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(C("Cancel")) { confirm = false }
                Button(C("Move to Trash")) { confirm = false; Task { await m.remove(its) } }.buttonStyle(PinkButton())
            }
        }.padding(24).frame(width: 420)
    }

    private func pick() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: m.root)
        if p.runModal() == .OK, let u = p.url { m.root = u.path }
    }
}

enum ClutterSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        let fm = FileManager.default
        func w(_ rel: String, _ d: Data) -> String { let p = f.root + "/" + rel; try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true); fm.createFile(atPath: p, contents: d); return p }

        // Large & Old
        let bigNew = f.file("home/docs/big-new.bin", kb: 2048, daysOld: 1)
        let bigOld = f.file("home/docs/big-old.bin", kb: 2048, daysOld: 400)
        let smallOld = f.file("home/docs/small-old.bin", kb: 1100, daysOld: 800)
        f.file("home/docs/tiny.bin", kb: 10, daysOld: 900)
        f.file("home/proj/node_modules/x/huge.bin", kb: 3000)
        f.file("home/.hidden/h.bin", kb: 3000)
        f.file("home/Tool.app/Contents/Resources/h.bin", kb: 3000)
        f.file("home/Library/Caches/c.bin", kb: 3000)
        f.symlink("home/docs/link.bin", to: bigNew)
        let m = ClutterModel(); m.root = f.home
        await m.runScan(); t.reachedCode()
        let paths = Set(m.files.map(\.path))
        t.check(paths == [bigNew, bigOld, smallOld] || paths.isSuperset(of: [bigNew, bigOld, smallOld]), "scan finds files >= 1 MB")
        t.check(!paths.contains { $0.contains("node_modules") || $0.contains("/.hidden/") || $0.contains(".app/") || $0.contains("/Library/") || $0.hasSuffix("link.bin") }, "skip list: node_modules, hidden, packages, ~/Library, symlinks")
        let now = Date()
        t.check(Set(LargeOld.filter(m.files, minSize: 1 << 20, ageDays: 0, now: now).map(\.path)) == [bigNew, bigOld, smallOld], "size only")
        t.check(Set(LargeOld.filter(m.files, minSize: 2 << 20, ageDays: 0, now: now).map(\.path)) == [bigNew, bigOld], "min size 2 MB drops 1.1 MB file")
        t.check(LargeOld.filter(m.files, minSize: 2 << 20, ageDays: 365, now: now).map(\.path) == [bigOld], "size AND >= 1 year old")
        t.check(Set(LargeOld.filter(m.files, minSize: 1 << 20, ageDays: 730, now: now).map(\.path)) == [smallOld], "2 years old only")
        t.check(LargeOld.filter(m.files, minSize: 1 << 20, ageDays: 0, now: now).first!.size == 2048 << 10, "sorted by size desc")

        // Duplicates
        let a1 = f.file("home/d/a/dup.bin", kb: 1500, daysOld: 30), a2 = f.file("home/d/b/dup-copy.bin", kb: 1500, daysOld: 10), a3 = f.file("home/d/c/deeper/dup3.bin", kb: 1500, daysOld: 5)
        var d1 = Data(repeating: 7, count: 1500 << 10), d2 = d1
        d1[d1.count - 1] = 1; d2[d2.count - 1] = 2        // same size, identical first 64 KB, different tail
        let x1 = w("home/e/x1.bin", d1), x2 = w("home/e/x2.bin", d2)
        let h1 = f.file("home/h/orig.bin", kb: 1700), h2 = f.hardlink("home/h/hard.bin", to: h1)
        f.symlink("home/h/sym.bin", to: h1)
        await m.runScan()
        await m.runDuplicates(minSize: 1 << 20)
        t.reachedCode()
        let g = m.groups.first { $0.files.contains { $0.path == a1 } }
        t.check(g != nil && Set(g!.files.map(\.path)) == [a1, a2, a3], "identical contents in 3 places = one group")
        t.check(!m.groups.contains { $0.files.contains { $0.path == x1 || $0.path == x2 } }, "same size + same first 64 KB but different tail NOT grouped")
        t.check(!m.groups.contains { $0.files.contains { $0.path == h1 || $0.path == h2 } }, "hard links and symlinks are not duplicates")
        t.check(m.groups.allSatisfy { $0.files.count >= 2 }, "every group has >= 2 copies")
        // same 1700 KB? bigOld/bigNew (2048 KB, identical 0x5a bytes) are duplicates of each other too
        t.check(m.groups.contains { Set($0.files.map(\.path)) == [bigNew, bigOld] }, "fixture twins found (full hash confirms)")

        // selection guarantee
        m.dupSelected = []
        t.check(m.toggleDup(a1) && m.toggleDup(a2), "select two of three copies")
        t.check(!m.toggleDup(a3) && !m.dupSelected.contains(a3), "cannot select the last remaining copy")
        m.toggleDup(a1); t.check(m.toggleDup(a3) && !m.toggleDup(a1), "swap is allowed, all-copies still refused")
        m.autoSelect(keepOldest: true)
        t.check(!m.dupSelected.contains(a1) && m.dupSelected.contains(a2) && m.dupSelected.contains(a3), "auto-select keep-oldest keeps the oldest")
        t.check(m.groups.allSatisfy { g in g.files.contains { !m.dupSelected.contains($0.path) } }, "auto-select leaves a copy in every group")
        m.autoSelect(keepOldest: false)
        t.check(m.groups.allSatisfy { g in !m.dupSelected.contains(g.shortest.path) }, "auto-select keep-shortest keeps the shortest path")

        // removal + undo + engine change
        m.autoSelect(keepOldest: true)
        let victims = m.selectedDup
        await m.remove(victims); t.reachedCode()
        t.check(fm.fileExists(atPath: a1) && !fm.fileExists(atPath: a2) && !fm.fileExists(atPath: a3), "removal trashes selected copies only")
        t.check(fm.fileExists(atPath: Env.trashDir + "/dup-copy.bin") && ActionLog.all().count == victims.count, "in fake Trash and logged")
        t.check(!m.files.contains { $0.path == a2 } && !m.groups.contains { $0.files.contains { $0.path == a1 } } && m.stale, "vanished files dropped, groups pruned, stale flagged")
        t.check(m.result?.batch.count == victims.count, "result keeps the batch")
        m.undo()
        t.check(fm.fileExists(atPath: a2) && fm.fileExists(atPath: a3) && m.result?.undone == true, "undo restores")
        let before = m.files.count
        m.handleEngineChange(op: "trash", paths: [bigOld])
        t.check(m.files.count == before - 1 && !m.files.contains { $0.path == bigOld }, "handleEngineChange drops externally trashed file")
        m.stale = false; m.handleEngineChange(op: "undo", paths: [bigOld]); t.check(m.stale, "undo elsewhere flags stale")
        t.check((try? Engine.trash("/System", mode: .userSelected)) == nil, "safety still gates removal")
    }
}

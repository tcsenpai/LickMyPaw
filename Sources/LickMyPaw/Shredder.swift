import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let S = "Shredder"

// MARK: - core

/// Overwrite-then-unlink. HONEST LIMIT: on APFS (copy-on-write, snapshots, clones) and on SSDs (wear levelling) overwriting in place
/// does not guarantee the old bytes are gone from the flash. It raises the bar against casual recovery; it is not forensic erasure.
/// For real protection use FileVault (encrypted disk) and erase the key by erasing the disk.
enum Shredder {
    struct Result { let path: String; let ok: Bool; let error: String?; let size: Int64 }

    /// Test seams: called after each overwrite pass (pass index 0 = random, 1 = zeros) and right before the unlink.
    nonisolated(unsafe) static var afterPass: ((Int, String) -> Void)?
    nonisolated(unsafe) static var beforeUnlink: ((String) -> Void)?

    /// Why a path cannot be shredded, or nil when it can. Safety.check always runs.
    static func refusal(_ path: String) -> String? {
        let v = Safety.check(path)
        if !v.ok { return v.reason }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "not found" }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return st.st_nlink > 1 ? "has other hard links (overwriting would change those names too)" : nil
        case S_IFLNK: return nil   // only the link itself is removed, the target is never opened
        case S_IFDIR: return nil   // handled by expand(): the user selected this folder
        default: return "not a regular file"
        }
    }

    /// The user's selection expanded to the files below any selected folder (symlinks are not followed). Folders come last-first for rmdir.
    static func expand(_ roots: [String]) -> (files: [String], dirs: [String]) {
        var files: [String] = [], dirs: [String] = []
        let fm = FileManager.default
        func walk(_ p: String) {
            var st = stat()
            guard lstat(p, &st) == 0 else { return }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                for c in ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted() { walk(p + "/" + c) }
                dirs.append(p)
            } else { files.append(p) }
        }
        roots.forEach(walk)
        return (files, dirs)   // dirs are post-order: children before parents
    }

    private static func overwrite(_ fd: Int32, size: Int64, random: Bool) throws {
        var left = size, off: Int64 = 0
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while left > 0 {
            let n = Int(min(Int64(buf.count), left))
            if random { var g = SystemRandomNumberGenerator(); for i in 0..<n { buf[i] = UInt8.random(in: 0...255, using: &g) } } else { for i in 0..<n { buf[i] = 0 } }
            var done = 0
            while done < n {
                let w = buf.withUnsafeBytes { pwrite(fd, $0.baseAddress! + done, n - done, off + Int64(done)) }
                if w < 0 { throw EngineError(message: String(cString: strerror(errno))) }
                done += w
            }
            off += Int64(n); left -= Int64(n)
        }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
    }

    /// One pass of random bytes, one pass of zeros, then unlink. Throws before touching anything when refused.
    static func shredFile(_ path: String) throws -> Int64 {
        if let why = refusal(path) { throw EngineError(message: "Refused: \(why): \(path)") }
        var st = stat(); lstat(path, &st)
        if (st.st_mode & S_IFMT) == S_IFLNK { try unlinkChecked(path); return 0 }
        let size = Int64(st.st_size)
        let fd = open(path, O_WRONLY | O_NOFOLLOW)   // no O_TRUNC: the blocks must be rewritten, not released
        guard fd >= 0 else { throw EngineError(message: String(cString: strerror(errno))) }
        defer { close(fd) }
        try overwrite(fd, size: size, random: true); afterPass?(0, path)
        try overwrite(fd, size: size, random: false); afterPass?(1, path)
        beforeUnlink?(path)
        try unlinkChecked(path)
        return size
    }
    private static func unlinkChecked(_ p: String) throws { if unlink(p) != 0 { throw EngineError(message: String(cString: strerror(errno))) } }

    /// Shred the selection. Each removed file gets an irreversible ActionLog entry. Empty folders the user selected are removed afterwards.
    @discardableResult static func shred(_ selection: [String]) -> [Result] {
        var out: [Result] = []
        // A selected root must itself pass the gate (a protected folder is never expanded into its contents).
        let roots = selection.filter { p in
            if let why = refusal(p) { out.append(Result(path: p, ok: false, error: "Refused: \(why)", size: 0)); return false }
            return true
        }
        let (files, dirs) = expand(roots)
        for p in files {
            do {
                let size = try shredFile(p)
                ActionLog.append(ActionEntry(ts: Date().timeIntervalSince1970, op: "shred", path: p, trashedTo: nil, size: size))
                out.append(Result(path: p, ok: true, error: nil, size: size))
            } catch { out.append(Result(path: p, ok: false, error: error.localizedDescription, size: 0)) }
        }
        for d in dirs where Safety.check(d).ok && rmdir(d) == 0 {}   // fails harmlessly when something is left inside
        let done = out.filter(\.ok).map(\.path)
        if !done.isEmpty { Engine.announce("shred", done) }
        return out
    }
}

// MARK: - model

struct ShredEntry: Identifiable, Equatable {
    let path: String
    var size: Int64
    let refusal: String?
    var id: String { path }
}

@MainActor final class ShredderModel: ObservableObject {
    static let shared = ShredderModel()
    @Published var entries: [ShredEntry] = []
    @Published var results: [Shredder.Result] = []
    @Published var message: String?

    var shreddable: [ShredEntry] { entries.filter { $0.refusal == nil } }
    var total: Int64 { shreddable.reduce(0) { $0 + $1.size } }

    func add(_ paths: [String]) {
        for p in paths where !entries.contains(where: { $0.path == p }) {
            let std = URL(fileURLWithPath: p).standardizedFileURL.path
            entries.append(ShredEntry(path: std, size: allocSize(std), refusal: Shredder.refusal(std)))
        }
        results = []; message = nil
    }
    func remove(_ e: ShredEntry) { entries.removeAll { $0.id == e.id } }

    func shred() {
        let sel = shreddable.map(\.path)
        guard !sel.isEmpty else { return }
        let r = Shredder.shred(sel)
        let ok = r.filter(\.ok).count
        results = r.filter { !$0.ok }
        entries.removeAll { e in !FileManager.default.fileExists(atPath: e.path) }
        message = TTF("Shredded %d file(s). This cannot be undone.", S, ok)
    }
}

// MARK: - view

struct ShredderView: View {
    @ObservedObject private var m = ShredderModel.shared
    @State private var confirm = false
    @State private var targeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(TT("Shredder", S)).font(.system(size: 30, weight: .bold, design: .rounded))
                honesty
                dropZone
                if let msg = m.message { Text(msg).font(.callout).foregroundStyle(.orange) }
                ForEach(m.results, id: \.path) { r in
                    Text("\((r.path as NSString).lastPathComponent): \(r.error ?? "")").font(.caption).foregroundStyle(.red)
                }
                if !m.entries.isEmpty { list }
            }.padding(20)
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $confirm) { ConfirmSheet(m: m, isPresented: $confirm) }
    }

    private var honesty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(TT("Be aware of the limit", S), systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            Text(TT("The file is overwritten once with random data and once with zeros, then deleted. On APFS and SSDs this is not guaranteed to erase every copy (snapshots, wear levelling). It stops casual recovery. For real protection use FileVault.", S)).font(.caption).opacity(0.8)
        }.padding(12).glass(14)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "flame.fill").font(.system(size: 30)).foregroundStyle(Color(hex: 0xFF8AD1))
            Text(TT("Drop files or folders here", S)).font(.body.weight(.medium))
            Button(TT("Choose…", S)) { choose() }.buttonStyle(PinkButton())
        }.frame(maxWidth: .infinity).padding(26).glass(20)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0xFF8AD1).opacity(targeted ? 0.9 : 0.25), style: StrokeStyle(lineWidth: 2, dash: [7])))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in m.add([u.path]) } } }
            }
            return true
        }
    }

    private func choose() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        if p.runModal() == .OK { m.add(p.urls.map(\.path)) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(m.entries) { e in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: e.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((e.path as NSString).lastPathComponent).lineLimit(1)
                        Text(e.refusal.map { TTF("Refused: %@", S, TT($0, S)) } ?? (e.path as NSString).deletingLastPathComponent).font(.caption)
                            .foregroundStyle(e.refusal == nil ? Color.white.opacity(0.6) : .red).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(fmt(e.size)).opacity(0.8)
                    Button { m.remove(e) } label: { Image(systemName: "xmark") }.buttonStyle(SoftButton())
                }.padding(8).glass(12)
            }
            HStack {
                Text(TTF("Total: %@", S, fmt(m.total))).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button(TT("Clear list", S)) { m.entries = [] }.buttonStyle(SoftButton())
                Button(TT("Shred…", S)) { confirm = true }.buttonStyle(PinkButton()).disabled(m.shreddable.isEmpty)
            }
        }
    }
}

private struct ConfirmSheet: View {
    @ObservedObject var m: ShredderModel
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TTF("Shred %d item(s)?", S, m.shreddable.count)).font(.headline)
            Text(TT("This cannot be undone. The files do not go to the Trash and cannot be restored from History.", S)).font(.callout.weight(.semibold)).foregroundStyle(.red)
            Text(TT("On APFS and SSDs the overwrite is not guaranteed to remove every copy of the data.", S)).font(.callout).opacity(0.8)
            ScrollView { VStack(alignment: .leading, spacing: 3) { ForEach(m.shreddable) { Text($0.path).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle) } } }.frame(maxHeight: 160)
            HStack {
                Spacer()
                Button(TT("Cancel", S)) { isPresented = false }.buttonStyle(SoftButton())
                Button(TT("Shred forever", S)) { m.shred(); isPresented = false }.buttonStyle(PinkButton())
            }
        }.padding(24).frame(width: 520).foregroundStyle(.white).background(Background())
    }
}

// MARK: - self test

enum ShredderSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        defer { Shredder.afterPass = nil; Shredder.beforeUnlink = nil }
        let fm = FileManager.default
        let victim = f.file("home/secret/a.bin", kb: 3000)   // > 1 MiB chunk, exercises the loop; filled with 0x5a
        let original = fm.contents(atPath: victim)!
        var passes: [(Int, Data)] = [], atUnlink: Data?
        Shredder.afterPass = { i, p in passes.append((i, fm.contents(atPath: p) ?? Data())) }
        Shredder.beforeUnlink = { p in atUnlink = fm.contents(atPath: p) }
        let r = Shredder.shred([victim]); t.reachedCode()
        t.check(r.count == 1 && r[0].ok && !fm.fileExists(atPath: victim), "file shredded and unlinked")
        t.check(passes.count == 2 && passes[0].0 == 0 && passes[1].0 == 1, "two passes ran: random then zeros")
        let p0 = passes.first?.1 ?? Data(), p1 = passes.last?.1 ?? Data()
        t.check(p0.count == original.count && p0 != original, "random pass replaced the original contents in place")
        t.check(p0.count == original.count && Set(p0.prefix(4096)).count > 100, "random pass is random (many distinct byte values)")
        t.check(p1.count == original.count && p1.allSatisfy { $0 == 0 }, "zero pass wiped every byte")
        t.check(atUnlink == p1 && atUnlink != original, "contents were already overwritten when unlink happened")
        let log = ActionLog.all()
        t.check(log.count == 1 && log[0].op == "shred" && log[0].path == victim && log[0].trashedTo == nil && log[0].size == Int64(original.count), "ActionLog entry marked shred, irreversible (no Trash copy)")
        t.check((try? Engine.undo(log[0])) == nil, "shred entries cannot be undone")

        t.reachedCode()
        // refusals: nothing is touched
        passes = []
        let protectedFile = f.file("home/Documents/keep.txt", kb: 1)   // Documents itself is protected, files inside are fine
        let hard = f.hardlink("home/h2.bin", to: f.file("home/h1.bin", kb: 1))
        let link = f.symlink("home/ln", to: protectedFile)
        t.check(Shredder.refusal("/System/Library/CoreServices/Finder.app") != nil && Shredder.refusal("/etc/hosts") != nil, "Safety refusals: system paths")
        t.check(Shredder.refusal(f.home) != nil, "Safety refusal: home root (\(Shredder.refusal(f.home) ?? "nil"))")
        t.check(Shredder.refusal(f.home + "/Documents") != nil, "Safety refusal: protected folder (\(Shredder.refusal(f.home + "/Documents") ?? "nil"))")
        t.check((try? Shredder.shredFile("/etc/hosts")) == nil && passes.isEmpty, "shredFile refuses a system file before opening it")
        t.check(Shredder.refusal(hard)?.contains("hard links") == true, "hard-linked file refused")
        let rr = Shredder.shred([hard, "/System/Library", f.root + "/missing"])
        t.check(rr.count == 3 && rr.allSatisfy { !$0.ok } && fm.fileExists(atPath: hard) && fm.fileExists(atPath: "/System/Library"), "refused/missing selections reported, left intact")

        // symlinks are never followed; directories only expand to what the user selected
        let rl = Shredder.shred([link])
        t.check(rl.count == 1 && rl[0].ok && !fm.fileExists(atPath: link) && (try? fm.destinationOfSymbolicLink(atPath: link)) == nil && fm.fileExists(atPath: protectedFile) && fm.contents(atPath: protectedFile)!.allSatisfy { $0 == 0x5a }, "symlink removed, its target untouched")
        let folder = f.dir("home/proj")
        f.file("home/proj/one.txt", kb: 2); f.file("home/proj/sub/two.txt", kb: 2)
        let outside = f.file("home/outside.txt", kb: 2)
        f.symlink("home/proj/escape", to: outside)
        let rf = Shredder.shred([folder])
        t.check(rf.filter(\.ok).count == 3 && !fm.fileExists(atPath: folder), "selected folder: files shredded, symlink unlinked, empty folders removed")
        t.check(fm.fileExists(atPath: outside) && fm.contents(atPath: outside)!.allSatisfy { $0 == 0x5a }, "a symlink inside the folder does not lead outside the selection")
        let rh = Shredder.shred([f.home, f.home + "/Documents"])
        t.check(rh.count == 2 && rh.allSatisfy { !$0.ok } && fm.fileExists(atPath: protectedFile) && fm.fileExists(atPath: outside), "a protected folder selected as a whole is refused, never expanded")

        // model flow
        let m = ShredderModel()
        let a = f.file("home/m/a.bin", kb: 4), b = f.file("home/m/b.bin", kb: 4)
        m.add([a, b, "/etc/hosts"])
        t.check(m.entries.count == 3 && m.shreddable.count == 2 && m.entries.first { $0.path.hasSuffix("/etc/hosts") }?.refusal != nil && m.total > 0, "review list flags refused entries and totals the rest")
        m.add([a]); t.check(m.entries.count == 3, "no duplicate entries")
        m.remove(m.entries[1]); m.shred()
        t.check(!fm.fileExists(atPath: a) && fm.fileExists(atPath: b) && fm.fileExists(atPath: "/etc/hosts") && m.message != nil, "model shreds only what is left in the list")
    }
}

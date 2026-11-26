import Foundation

/// Agent-facing CLI, same binary as the GUI:  LickMyPaw <scan|big|trash|help> ...  (JSON on stdout, errors on stderr)
enum CLI {
    static let usage = """
    lickmypaw: disk space analyzer (CLI for agents). Output is JSON on stdout.
      lickmypaw scan <path> [--depth 2] [--top 15] [--min 10M]   size tree, children sorted desc
      lickmypaw big  <path> [--files|--dirs] [--limit 30] [--min 100M]   flat ranking of largest items
      lickmypaw trash <path>... [--yes]                          move to Trash (dry-run without --yes)
      lickmypaw update --check                                   current vs latest release (the one explicit network call)
    Sizes = allocated bytes (like du). --min accepts K/M/G. Does not cross mount points; symlinks skipped.
    Files < 512K are folded into "N small files" entries (aggregate=true).
    """

    static func runIfRequested() -> Bool {
        var a = Array(CommandLine.arguments.dropFirst())
        guard let cmd = a.first, ["scan", "big", "trash", "update", "help", "--help", "-h"].contains(cmd) else { return false }
        a.removeFirst()
        func opt(_ n: String) -> String? { a.firstIndex(of: n).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        let flags: Set<String> = ["--files", "--dirs", "--yes"]
        let valueOpts: Set<String> = ["--depth", "--top", "--min", "--limit"]
        var pos: [String] = [], i = 0
        while i < a.count { if valueOpts.contains(a[i]) { i += 2 } else { if !flags.contains(a[i]) { pos.append(a[i]) }; i += 1 } }
        switch cmd {
        case "scan", "big":
            guard let p = pos.first else { fail("missing <path>") }
            let path = abs(p)
            guard FileManager.default.fileExists(atPath: path) else { fail("not found: \(path)") }
            let prog = Progress(), t0 = Date()
            let root = Scanner.scan(path: path, progress: prog)
            let (_, files) = prog.snapshot
            let minB = opt("--min").flatMap(parseSize) ?? 0
            let meta: [String: Any] = ["path": path, "size": root.size, "files": files, "seconds": (Date().timeIntervalSince(t0) * 100).rounded() / 100]
            if cmd == "scan" {
                let depth = Int(opt("--depth") ?? "") ?? 2, top = Int(opt("--top") ?? "") ?? 15
                var out = meta; out["tree"] = dict(root, depth: depth, top: top, min: minB)
                emit(out)
            } else {
                let limit = Int(opt("--limit") ?? "") ?? 30
                let onlyFiles = a.contains("--files"), onlyDirs = a.contains("--dirs")
                var all: [Node] = [], stack = [root]
                while let n = stack.popLast() {
                    for c in n.children { if c.isDir { stack.append(c) }; all.append(c) }
                }
                // dirs ranking would be dominated by ancestors; keep "leaf-most": dirs with no child dir bigger than half of them
                let items = all.filter { n in
                    guard n.size >= minB else { return false }
                    if onlyFiles { return !n.isDir && !n.isAggregate }
                    if onlyDirs { return n.isDir && !n.children.contains { $0.isDir && $0.size * 2 > n.size } }
                    return !n.isAggregate && !(n.isDir && n.children.contains { $0.size * 2 > n.size })
                }.sorted { $0.size > $1.size }.prefix(limit)
                var out = meta
                out["items"] = items.map { ["path": $0.path, "size": $0.size, "human": fmt($0.size), "type": $0.isDir ? "dir" : "file"] as [String: Any] }
                emit(out)
            }
        case "trash":
            guard !pos.isEmpty else { fail("missing <path>") }
            let yes = a.contains("--yes")
            var res: [[String: Any]] = []
            for p in pos {
                let path = abs(p)
                guard FileManager.default.fileExists(atPath: path) else { res.append(["path": path, "status": "not_found"]); continue }
                if !yes { res.append(["path": path, "status": "dry_run"]); continue }
                do { try Engine.trash(path); res.append(["path": path, "status": "trashed"]) }
                catch { res.append(["path": path, "status": "error", "error": error.localizedDescription]) }
            }
            emit(["results": res, "dry_run": !yes])
        case "update":
            guard a.contains("--check") else { fail("usage: lickmypaw update --check") }
            let bv = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            nonisolated(unsafe) var res: (code: Int32, json: [String: Any]) = (1, [:])
            let sem = DispatchSemaphore(value: 0)
            Task.detached { res = await UpdateCLI.check(current: SemVer(bv), bundleVersion: bv); sem.signal() }
            sem.wait()
            emit(res.json); if res.code != 0 { exit(res.code) }
        default: print(usage)
        }
        return true
    }

    static func dict(_ n: Node, depth: Int, top: Int, min: Int64) -> [String: Any] {
        var d: [String: Any] = ["name": n.name, "path": n.path, "size": n.size, "human": fmt(n.size), "type": n.isAggregate ? "aggregate" : (n.isDir ? "dir" : "file")]
        if n.isDir && depth > 0 {
            let kids = n.children.filter { $0.size >= min }
            d["children"] = kids.prefix(top).map { dict($0, depth: depth - 1, top: top, min: min) }
            let rest = kids.dropFirst(top).reduce(Int64(0)) { $0 + $1.size }
            if rest > 0 { d["other_size"] = rest }
        }
        return d
    }
    static func abs(_ p: String) -> String { URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.path }
    static func parseSize(_ s: String) -> Int64? {
        guard let l = s.uppercased().last else { return nil }
        let mult: [Character: Int64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40]
        if let m = mult[l] { return Double(s.dropLast()).map { Int64($0 * Double(m)) } }
        return Int64(s)
    }
    static func emit(_ o: Any) {
        let d = try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
        print(String(data: d, encoding: .utf8)!)
    }
    static func fail(_ m: String) -> Never {
        FileHandle.standardError.write(Data("{\"error\":\"\(m)\"}\n".utf8)); exit(2)
    }
}

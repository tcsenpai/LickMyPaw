import Foundation

struct ActionEntry: Codable, Identifiable {
    var id: String { "\(ts)-\(path)" }
    let ts: Double
    let op: String            // "trash"
    let path: String
    let trashedTo: String?
    let size: Int64
    var undone: Bool = false
}

struct EngineError: LocalizedError { let message: String; var errorDescription: String? { message } }

enum ActionLog {
    static var url: URL { URL(fileURLWithPath: Env.supportDir + "/actions.jsonl") }
    static func all() -> [ActionEntry] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { try? JSONDecoder().decode(ActionEntry.self, from: Data($0.utf8)) }
    }
    static func rewrite(_ es: [ActionEntry]) {
        try? FileManager.default.createDirectory(atPath: Env.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        let s = es.compactMap { try? enc.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n") + (es.isEmpty ? "" : "\n")
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
    static func append(_ e: ActionEntry) { var a = all(); a.append(e); rewrite(a) }
}

/// Every deletion: Safety check -> move to Trash (never rm) -> log -> undoable.
enum Engine {
    @discardableResult
    static func trash(_ path: String, size: Int64 = 0, mode: SafetyMode = .userSelected) throws -> ActionEntry {
        let v = Safety.check(path, mode: mode)
        guard v.ok else { throw EngineError(message: "Refused: \(v.reason): \(path)") }
        let fm = FileManager.default
        var dest: String?
        if Env.fake {   // tests: "Trash" lives inside the fake home
            try fm.createDirectory(atPath: Env.trashDir, withIntermediateDirectories: true)
            var d = Env.trashDir + "/" + (path as NSString).lastPathComponent
            var i = 1; while fm.fileExists(atPath: d) { d = Env.trashDir + "/" + (path as NSString).lastPathComponent + " \(i)"; i += 1 }
            try fm.moveItem(atPath: path, toPath: d); dest = d
        } else {
            var out: NSURL?
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
            dest = (out as URL?)?.path
        }
        let e = ActionEntry(ts: Date().timeIntervalSince1970, op: "trash", path: path, trashedTo: dest, size: size)
        ActionLog.append(e)
        return e
    }

    static func undo(_ e: ActionEntry) throws {
        guard let t = e.trashedTo, FileManager.default.fileExists(atPath: t) else { throw EngineError(message: "Nothing to restore (already emptied?)") }
        guard !FileManager.default.fileExists(atPath: e.path) else { throw EngineError(message: "Original location is occupied") }
        try FileManager.default.moveItem(atPath: t, toPath: e.path)
        var all = ActionLog.all()
        if let i = all.firstIndex(where: { $0.ts == e.ts && $0.path == e.path }) { all[i].undone = true; ActionLog.rewrite(all) }
    }
}

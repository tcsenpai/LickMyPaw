import Foundation
import CryptoKit

struct DupGroup: Identifiable, Hashable, Sendable {
    let id: String            // full SHA-256 + size
    let size: Int64
    var files: [CFile]        // >= 2 real copies
    var wasted: Int64 { size * Int64(files.count - 1) }
    var oldest: CFile { files.min { ($0.mtime, $0.path) < ($1.mtime, $1.path) }! }
    var shortest: CFile { files.min { ($0.path.count, $0.path) < ($1.path.count, $1.path) }! }
}

enum Duplicates {
    static let partialBytes = 64 * 1024

    private static func hash(_ path: String, limit: Int?) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        var left = limit ?? Int.max
        while left > 0 {
            let chunk = autoreleasepool { try? h.read(upToCount: min(left, 1 << 20)) }
            guard let c = chunk, !c.isEmpty else { break }
            sha.update(data: c); left -= c.count
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Ino: Hashable { let dev: dev_t; let ino: ino_t }

    /// Pipeline: group by size -> drop symlinks / hard links of each other -> partial hash (first 64 KB) -> full SHA-256 only on survivors.
    static func find(_ files: [CFile], minSize: Int64, progress: Progress) -> [DupGroup] {
        var bySize: [Int64: [CFile]] = [:]
        for f in files where f.size >= minSize { bySize[f.size, default: []].append(f) }
        var groups: [DupGroup] = []
        for (size, cands) in bySize where cands.count > 1 {
            if progress.cancelled { return [] }
            var seen = Set<Ino>(), real: [CFile] = []
            for f in cands {   // lstat: regular files only; same dev+inode = hard link, not a real duplicate
                var st = stat()
                guard lstat(f.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, seen.insert(Ino(dev: st.st_dev, ino: st.st_ino)).inserted else { continue }
                real.append(f)
            }
            guard real.count > 1 else { continue }
            var byPartial: [String: [CFile]] = [:]
            for f in real { if let k = hash(f.path, limit: partialBytes) { byPartial[k, default: []].append(f) } }
            for (_, p) in byPartial where p.count > 1 {
                var byFull: [String: [CFile]] = [:]
                for f in p {
                    if progress.cancelled { return [] }
                    if let k = hash(f.path, limit: nil) { byFull[k, default: []].append(f); progress.add(bytes: size, files: 1) }
                }
                for (k, g) in byFull where g.count > 1 { groups.append(DupGroup(id: k + "-\(size)", size: size, files: g.sorted { $0.path < $1.path })) }
            }
        }
        return groups.sorted { ($0.wasted, $1.id) > ($1.wasted, $0.id) }
    }
}

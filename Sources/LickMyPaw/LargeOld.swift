import Foundation

struct CFile: Identifiable, Hashable, Sendable {
    let path: String
    let size: Int64
    let mtime: Date
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

enum LargeOld {
    /// Package-like extensions treated as opaque (never descended, never listed).
    static let packageExts: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "bundle", "framework", "plugin", "xcodeproj", "xcworkspace", "playground", "sparsebundle", "sparseimage"]
    /// Skip list: hidden files/dirs (.git, .Trash, .cache, ...), node_modules internals, packages/bundles,
    /// ~/Library (app data, not user clutter), symlinks (never followed or listed).
    static func skipDir(_ path: String, name: String, isPackage: Bool) -> Bool {
        isPackage || name == "node_modules" || packageExts.contains((name as NSString).pathExtension.lowercased()) || path == Env.home + "/Library"
    }

    /// Walk `root` and return every regular file >= floor bytes. Cancellable via progress.cancelled.
    static func walk(_ root: String, floor: Int64, progress: Progress) -> [CFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        var out: [CFile] = []
        let real = realpath(root, nil).map { String(cString: $0) } ?? root   // enumerator reports resolved paths (/private/var...); keep the caller's spelling
        func fix(_ p: String) -> String { p.hasPrefix(real) ? root + p.dropFirst(real.count) : p }
        for case let u as URL in en {
            if progress.cancelled { break }
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if skipDir(fix(u.path), name: u.lastPathComponent, isPackage: v.isPackage ?? false) { en.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true else { continue }   // symlinks and specials: skipped
            let sz = Int64(v.fileSize ?? 0)
            progress.add(bytes: sz, files: 1)
            if sz >= floor { out.append(CFile(path: fix(u.path), size: sz, mtime: v.contentModificationDate ?? .distantPast)) }
        }
        return out
    }

    /// size >= minSize AND (ageDays == 0 or not modified for >= ageDays). Biggest first.
    static func filter(_ files: [CFile], minSize: Int64, ageDays: Int, now: Date = Date()) -> [CFile] {
        let cutoff = now.addingTimeInterval(-Double(ageDays) * 86400)
        return files.filter { $0.size >= minSize && (ageDays == 0 || $0.mtime <= cutoff) }.sorted { $0.size > $1.size }
    }
}

import Foundation

final class Node: Identifiable, Hashable, @unchecked Sendable {
    let name: String
    let path: String
    let isDir: Bool
    let isAggregate: Bool          // "N small files" pseudo-node
    var size: Int64
    var count = 0                  // aggregate only: number of folded files
    var children: [Node] = []
    weak var parent: Node?
    init(name: String, path: String, isDir: Bool, size: Int64 = 0, aggregate: Bool = false) {
        self.name = name; self.path = path; self.isDir = isDir; self.size = size; self.isAggregate = aggregate
    }
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    static func == (a: Node, b: Node) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { isAggregate ? TF("%d small files", count) : name }
}

final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: Int64 = 0, _files: Int = 0
    var cancelled = false
    func add(bytes: Int64, files: Int) { lock.lock(); _bytes += bytes; _files += files; lock.unlock() }
    var snapshot: (Int64, Int) { lock.lock(); defer { lock.unlock() }; return (_bytes, _files) }
}

/// Per-scan state: device, exclusion snapshot, and the (dev,fileid) set that makes hard links count once.
private final class ScanCtx: @unchecked Sendable {
    struct Key: Hashable { let dev: dev_t; let id: UInt64 }
    let dev: dev_t, excl: [String]
    private let lock = NSLock()
    private var seen = Set<Key>()
    init(dev: dev_t) {
        self.dev = dev
        excl = Prefs.exclusions.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }
    func isExcluded(_ p: String) -> Bool {
        for x in excl where p == x || (p.hasPrefix(x) && p.utf8[p.utf8.index(p.utf8.startIndex, offsetBy: x.utf8.count)] == UInt8(ascii: "/")) { return true }
        return false
    }
    /// true the first time a (dev,fileid) is seen
    func first(_ dev: dev_t, _ id: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return seen.insert(Key(dev: dev, id: id)).inserted }
}

enum Scanner {
    /// Files smaller than this are folded into one aggregate node per directory (keeps memory low on millions of files).
    static let keepThreshold: Int64 = 512 * 1024

    static func scan(path: String, progress: Progress) -> Node {
        var st = stat()
        let dev: dev_t = (stat(path, &st) == 0) ? st.st_dev : 0
        let name = (path as NSString).lastPathComponent
        let root = Node(name: name.isEmpty ? path : name, path: path, isDir: true)
        scanDir(root, ctx: ScanCtx(dev: dev), depth: 0, progress: progress)
        return root
    }

    private static func scanDir(_ node: Node, ctx: ScanCtx, depth: Int, progress: Progress) {
        if progress.cancelled { return }
        guard let entries = listDir(node.path) else { return }
        var dirs: [Node] = [], files: [Node] = []
        var smallBytes: Int64 = 0, smallCount = 0, bytes: Int64 = 0, count = 0
        let base = node.path == "/" ? "" : node.path
        for e in entries {
            let path = base + "/" + e.name
            if !ctx.excl.isEmpty && ctx.isExcluded(path) { continue }
            if e.isDir {
                if e.dev != ctx.dev { continue }             // don't cross mount points
                let n = Node(name: e.name, path: path, isDir: true); n.parent = node
                dirs.append(n)
            } else {
                if e.link != 0 && !ctx.first(e.dev, e.link) { continue }   // extra hard link: already counted
                bytes += e.size; count += 1
                if e.size >= keepThreshold {
                    let n = Node(name: e.name, path: path, isDir: false, size: e.size); n.parent = node
                    files.append(n)
                } else { smallBytes += e.size; smallCount += 1 }
            }
        }
        progress.add(bytes: bytes, files: count)

        if depth < 4 && dirs.count > 1 {
            DispatchQueue.concurrentPerform(iterations: dirs.count) { scanDir(dirs[$0], ctx: ctx, depth: depth + 1, progress: progress) }
        } else {
            for c in dirs { scanDir(c, ctx: ctx, depth: depth + 1, progress: progress) }
        }
        var kids = dirs + files
        if smallCount > 0 {
            let a = Node(name: "\(smallCount) small files", path: node.path, isDir: false, size: smallBytes, aggregate: true)
            a.parent = node; a.count = smallCount; kids.append(a)
        }
        kids.removeAll { $0.size == 0 }
        kids.sort { $0.size > $1.size }
        node.children = kids
        node.size = kids.reduce(0) { $0 + $1.size }
    }
}

struct Entry { let name: String; let isDir: Bool; let dev: dev_t; let size: Int64; var link: UInt64 = 0 }  // link = fileid when nlink>1 (hard link), else 0

/// Lists a directory (symlinks/specials returned as non-dir with allocated size 0 for links).
/// Fast path: getattrlistbulk (many entries per syscall, no per-file stat). Fallback: readdir+fstatat.
func listDir(_ path: String) -> [Entry]? {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if fd < 0 { return nil }
    defer { close(fd) }
    var al = attrlist()
    al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
    al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
    let cap = 256 * 1024
    let buf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 8)
    defer { buf.deallocate() }
    var out: [Entry] = []
    var first = true
    while true {
        let n = getattrlistbulk(fd, &al, buf, cap, UInt64(FSOPT_PACK_INVAL_ATTRS))
        if n < 0 { if first { return listDirSlow(path) }; break }
        if n == 0 { break }
        first = false
        var p = buf
        for _ in 0..<Int(n) {
            let len = Int(p.loadUnaligned(as: UInt32.self))
            var q = p + 4
            let ret = q.loadUnaligned(as: attribute_set_t.self); q += MemoryLayout<attribute_set_t>.size
            let ref = q.loadUnaligned(as: attrreference_t.self)
            let name = String(cString: (q + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)); q += MemoryLayout<attrreference_t>.size
            let dev = q.loadUnaligned(as: dev_t.self); q += 4
            let type = q.loadUnaligned(as: UInt32.self); q += 4
            let fid = q.loadUnaligned(as: UInt64.self); q += 8
            var size: Int64 = 0, link: UInt64 = 0
            if type == 1 /*VREG*/ {   // PACK_INVAL_ATTRS: both file attrs are always packed, in bit order
                if ret.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0, q.loadUnaligned(as: UInt32.self) > 1 { link = fid }
                q += 4
                if ret.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { size = q.loadUnaligned(as: Int64.self) }
            }
            if type == 2 /*VDIR*/ { out.append(Entry(name: name, isDir: true, dev: dev, size: 0)) }
            else if type == 1 { out.append(Entry(name: name, isDir: false, dev: dev, size: size, link: link)) }
            p += len
        }
    }
    return out
}

private func listDirSlow(_ path: String) -> [Entry]? {
    guard let d = opendir(path) else { return nil }
    defer { closedir(d) }
    let dfd = dirfd(d)
    var out: [Entry] = []
    while let e = readdir(d) {
        let name = withUnsafePointer(to: &e.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        var st = stat()
        if fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { continue }
        let fmt = st.st_mode & S_IFMT
        if fmt == S_IFDIR { out.append(Entry(name: name, isDir: true, dev: st.st_dev, size: 0)) }
        else if fmt == S_IFREG { out.append(Entry(name: name, isDir: false, dev: st.st_dev, size: Int64(st.st_blocks) * 512, link: st.st_nlink > 1 ? UInt64(st.st_ino) : 0)) }
    }
    return out
}

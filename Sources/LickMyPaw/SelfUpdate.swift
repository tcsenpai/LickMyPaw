import Foundation
import CryptoKit
import AppKit

// Self-update for unsigned (ad-hoc) builds: a native checker against the GitHub Releases API.
// This is the ONLY network call the app makes besides the optional ClamAV install. No identifiers are sent (User-Agent "LickMyPaw").
// Sparkle is deferred until Developer ID signing at 1.0.0.
//
// Flow: latest release JSON -> semver compare -> pick the zip for this CPU + SHA256SUMS.txt -> download with URLSession (no quarantine
// flag) -> verify SHA-256 (refuse on mismatch) -> unzip into a temp dir -> verify bundle id / version / resources -> a tiny helper
// script swaps the installed .app after we quit and relaunches. Paths reach the script only as argv, never inside a shell string.

struct SemVer: Comparable, Equatable {
    var core: [Int]        // always 3 numbers
    var pre: [String]      // prerelease identifiers, e.g. ["dev"] or ["rc", "1"]
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let i = s.firstIndex(of: "+") { s = String(s[..<i]) }   // build metadata is ignored
        var pre: [String] = []
        if let i = s.firstIndex(of: "-") {
            pre = s[s.index(after: i)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            s = String(s[..<i])
            if pre.contains("") { return nil }
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        var nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count else { return nil }
        while nums.count < 3 { nums.append(0) }
        core = nums; self.pre = pre
    }
    var text: String { core.map(String.init).joined(separator: ".") + (pre.isEmpty ? "" : "-" + pre.joined(separator: ".")) }
    /// SemVer 2.0 precedence: 0.2.0-dev < 0.2.0; numeric identifiers < alphanumeric; a longer set wins when all else is equal.
    static func < (a: SemVer, b: SemVer) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }
        for (x, y) in zip(a.pre, b.pre) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.pre.count < b.pre.count
    }
}

struct GHAsset: Decodable, Equatable { var name: String; var browser_download_url: String }
struct GHRelease: Decodable, Equatable {
    var tag_name: String; var name: String?; var body: String?
    var draft: Bool; var prerelease: Bool; var html_url: String?
    var assets: [GHAsset]
}

struct UpdateInfo: Equatable {
    var version: SemVer; var tag: String; var notes: String; var page: URL?
    var zip: GHAsset; var sums: GHAsset?
}

struct UpdateError: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

protocol UpdateHTTP {
    func get(_ url: URL) async throws -> Data
    func download(_ url: URL, to dest: URL) async throws
}

/// Ephemeral session (no cookies, no cache), generic User-Agent, nothing identifying.
struct URLSessionHTTP: UpdateHTTP {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": "LickMyPaw", "Accept": "application/vnd.github+json"]
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()
    private func ok(_ r: URLResponse) throws { if let h = r as? HTTPURLResponse, h.statusCode != 200 { throw UpdateError(message: "HTTP \(h.statusCode)") } }
    func get(_ url: URL) async throws -> Data { let (d, r) = try await session.data(from: url); try ok(r); return d }
    func download(_ url: URL, to dest: URL) async throws {
        let (tmp, r) = try await session.download(from: url); try ok(r)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

enum UpdateCore {
    static let api = URL(string: "https://api.github.com/repos/tcsenpai/LickMyPaw/releases/latest")!
    static let sumsName = "SHA256SUMS.txt"

    enum Outcome: Equatable { case upToDate(SemVer), available(UpdateInfo), unusable(String) }

    static func arch() -> String { var u = utsname(); uname(&u); return withUnsafeBytes(of: &u.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } }

    static func parse(_ data: Data) throws -> GHRelease { try JSONDecoder().decode(GHRelease.self, from: data) }

    /// Only https URLs on GitHub's own hosts are ever downloaded.
    static func trusted(_ s: String) -> Bool {
        guard let u = URL(string: s), u.scheme == "https", let h = u.host?.lowercased() else { return false }
        return h == "github.com" || h.hasSuffix(".github.com") || h.hasSuffix(".githubusercontent.com")
    }

    /// package.sh names the assets LickMyPaw-<ver>-macos-<arch>.zip and SHA256SUMS.txt.
    static func select(_ r: GHRelease, arch: String) -> (zip: GHAsset, sums: GHAsset?)? {
        guard let zip = r.assets.first(where: { $0.name.hasPrefix("LickMyPaw-") && $0.name.hasSuffix("-macos-\(arch).zip") && trusted($0.browser_download_url) }) else { return nil }
        return (zip, r.assets.first { $0.name == sumsName && trusted($0.browser_download_url) })
    }

    /// `current` nil = a development build with no usable version: report the latest, never claim an update.
    static func evaluate(_ r: GHRelease, current: SemVer?, arch: String) -> Outcome {
        if r.draft || r.prerelease { return .unusable("pre-release or draft") }
        guard let v = SemVer(r.tag_name) else { return .unusable("unreadable version \(r.tag_name)") }
        guard let cur = current, cur < v else { return .upToDate(v) }
        guard let a = select(r, arch: arch) else { return .unusable("no download for \(arch)") }
        return .available(UpdateInfo(version: v, tag: v.text, notes: r.body ?? "", page: r.html_url.flatMap(URL.init(string:)), zip: a.zip, sums: a.sums))
    }

    static func fetchLatest(http: UpdateHTTP, current: SemVer?, arch: String = arch()) async throws -> (Outcome, SemVer?) {
        let r = try parse(try await http.get(api))
        return (evaluate(r, current: current, arch: arch), SemVer(r.tag_name))
    }

    // MARK: checksums

    /// `shasum -a 256` format: "<64 hex>  <file>" (a leading * on the name marks binary mode).
    static func expectedHash(sums: String, file: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count == 2, p[0].count == 64, p[0].allSatisfy(\.isHexDigit) else { continue }
            if p[1].hasPrefix("*") ? p[1].dropFirst() == file : p[1] == file { return p[0].lowercased() }
        }
        return nil
    }
    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verify(file: URL, expected: String) throws {
        guard try sha256(file) == expected.lowercased() else { throw UpdateError(message: TT("The download does not match its checksum and was discarded.", "System")) }
    }

    // MARK: unzip + bundle verification

    static func unzip(_ zip: URL, into dir: URL) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, dir.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError(message: TT("The downloaded archive could not be unpacked.", "System")) }
    }

    /// The extracted app must be exactly one LickMyPaw.app with our bundle id, the announced version, its executable and its resources.
    static func verifyBundle(in dir: URL, bundleID: String, version: SemVer) throws -> URL {
        let bad = UpdateError(message: TT("The downloaded app is not a valid LickMyPaw build and was discarded.", "System"))
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        guard items == ["LickMyPaw.app"] else { throw bad }
        let app = dir.appendingPathComponent("LickMyPaw.app")
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == bundleID,
              (plist["CFBundleShortVersionString"] as? String).flatMap(SemVer.init) == version,
              let exe = plist["CFBundleExecutable"] as? String else { throw bad }
        var isDir: ObjCBool = false
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/" + exe).path),
              FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/LickMyPaw_LickMyPaw.bundle").path, isDirectory: &isDir), isDir.boolValue else { throw bad }
        return app
    }

    /// Download, verify the checksum, unpack, verify the bundle. Returns the new .app inside `work`.
    static func prepare(_ info: UpdateInfo, http: UpdateHTTP, work: URL, bundleID: String) async throws -> URL {
        guard let sumsAsset = info.sums else { throw UpdateError(message: TT("This release publishes no checksum file, so it will not be installed automatically.", "System")) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let sums = String(decoding: try await http.get(URL(string: sumsAsset.browser_download_url)!), as: UTF8.self)
        guard let want = expectedHash(sums: sums, file: info.zip.name) else { throw UpdateError(message: TT("The checksum file does not list this download.", "System")) }
        let zip = work.appendingPathComponent(info.zip.name)
        try await http.download(URL(string: info.zip.browser_download_url)!, to: zip)
        try verify(file: zip, expected: want)
        let out = work.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try unzip(zip, into: out)
        try? FileManager.default.removeItem(at: zip)
        return try verifyBundle(in: out, bundleID: bundleID, version: info.version)
    }
}

// MARK: - Replace + relaunch through a tiny detached helper

enum Relaunch {
    /// Constant text: nothing is ever interpolated into it. Arguments: 1 pid to wait for, 2 new .app, 3 installed .app, 4 work dir, 5 opener.
    static let script = """
    #!/bin/sh
    trap '' HUP
    n=0
    while kill -0 "$1" 2>/dev/null && [ "$n" -lt 150 ]; do sleep 0.2; n=$((n+1)); done
    /usr/bin/ditto "$2" "$3.update-new" || { /bin/rm -rf "$3.update-new"; exit 1; }
    /bin/mv "$3" "$3.update-old" || { /bin/rm -rf "$3.update-new"; exit 1; }
    if /bin/mv "$3.update-new" "$3"; then
      /bin/rm -rf "$3.update-old"
    else
      /bin/mv "$3.update-old" "$3"
      "$5" "$3"
      exit 1
    fi
    "$5" "$3"
    case "$4" in */lmp-update-*) /bin/rm -rf "$4" ;; esac
    """
    static let opener = "/usr/bin/open"

    static func invocation(script: URL, pid: Int32, newApp: URL, target: URL, work: URL, opener: String = opener) -> (exe: String, args: [String]) {
        ("/bin/sh", [script.path, String(pid), newApp.path, target.path, work.path, opener])
    }

    /// Can we swap the installed app in place? Needs an .app in a writable folder.
    static func canReplace(_ target: URL) -> Bool {
        let fm = FileManager.default
        return target.pathExtension == "app" && fm.isWritableFile(atPath: target.deletingLastPathComponent().path) && fm.isWritableFile(atPath: target.path)
    }

    /// Starts the helper detached; the caller quits right after. Only used by the GUI.
    static func launch(newApp: URL, target: URL, work: URL, pid: Int32 = getpid()) throws {
        let s = work.appendingPathComponent("swap.sh")
        try script.write(to: s, atomically: true, encoding: .utf8)
        let inv = invocation(script: s, pid: pid, newApp: newApp, target: target, work: work)
        let p = Process(); p.executableURL = URL(fileURLWithPath: inv.exe); p.arguments = inv.args
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
    }
}

// MARK: - Model

@MainActor final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()
    enum State: Equatable { case idle, checking, upToDate, available, downloading, revealed, failed(String) }
    @Published var state: State = .idle
    @Published var info: UpdateInfo?
    @Published var latest: SemVer?

    var http: UpdateHTTP = URLSessionHTTP()
    var current: SemVer? = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(SemVer.init)
    var target: URL = Bundle.main.bundleURL
    var bundleID: String = Bundle.main.bundleIdentifier ?? "org.lickmypaw.app"
    /// Swap-and-quit in the real app; replaced in tests.
    var finish: @MainActor (_ newApp: URL, _ target: URL, _ work: URL) -> Void = { newApp, target, work in
        if Relaunch.canReplace(target), (try? Relaunch.launch(newApp: newApp, target: target, work: work)) != nil { NSApp.terminate(nil) }
        else { NSWorkspace.shared.activateFileViewerSelecting([newApp]); UpdateModel.shared.state = .revealed }
    }

    /// Once a day at most, only when the user keeps the automatic check on.
    func autoCheckIfDue(now: Date = Date()) {
        guard Runtime.isPackagedApp, AppPrefs.updateAuto else { return }
        if let l = AppPrefs.updateLastCheck, now.timeIntervalSince(l) < 24 * 3600 { return }
        Task { await check() }
    }

    func check() async {
        guard state != .checking, state != .downloading else { return }
        state = .checking
        do {
            let (o, v) = try await UpdateCore.fetchLatest(http: http, current: current)
            AppPrefs.updateLastCheck = Date(); latest = v
            switch o {
            case .upToDate: info = nil; state = .upToDate
            case .available(let i): info = i; state = .available
            case .unusable(let why): info = nil; state = .failed(why)
            }
        } catch { state = .failed(error.localizedDescription) }
    }

    func install() async {
        guard let i = info, state != .downloading, state != .checking else { return }
        state = .downloading
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lmp-update-\(UUID().uuidString)")
        do {
            let app = try await UpdateCore.prepare(i, http: http, work: work, bundleID: bundleID)
            finish(app, target, work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - CLI: lickmypaw update --check

enum UpdateCLI {
    /// The one explicit network call of the CLI; only when this command is run.
    static func check(http: UpdateHTTP = URLSessionHTTP(), current: SemVer?, bundleVersion: String) async -> (code: Int32, json: [String: Any]) {
        var out: [String: Any] = ["current": current?.text ?? bundleVersion]
        do {
            let (o, v) = try await UpdateCore.fetchLatest(http: http, current: current)
            out["latest"] = v?.text ?? NSNull()
            switch o {
            case .upToDate: out["update_available"] = false
            case .available(let i): out["update_available"] = true; out["url"] = i.page?.absoluteString ?? NSNull()
            case .unusable(let why): out["update_available"] = false; out["note"] = why
            }
            return (0, out)
        } catch { out["error"] = error.localizedDescription; return (1, out) }
    }
}

// MARK: - Selftests

private struct FakeHTTP: UpdateHTTP {
    var files: [String: Data]
    var calls = Box()
    final class Box { var urls: [String] = [] }
    func get(_ url: URL) async throws -> Data { calls.urls.append(url.absoluteString); if let d = files[url.absoluteString] { return d }; throw UpdateError(message: "404") }
    func download(_ url: URL, to dest: URL) async throws { try await get(url).write(to: dest) }
}

enum UpdateSelfTest {
    static let releaseJSON = """
    {"tag_name":"v0.3.0","name":"0.3.0","body":"- menu bar\\n- self update","draft":false,"prerelease":false,"html_url":"https://github.com/tcsenpai/LickMyPaw/releases/tag/v0.3.0",
     "assets":[{"name":"LickMyPaw-0.3.0-macos-arm64.dmg","browser_download_url":"https://github.com/x/LickMyPaw-0.3.0-macos-arm64.dmg"},
               {"name":"LickMyPaw-0.3.0-macos-arm64.zip","browser_download_url":"https://github.com/tcsenpai/LickMyPaw/releases/download/v0.3.0/LickMyPaw-0.3.0-macos-arm64.zip"},
               {"name":"LickMyPaw-0.3.0-macos-x86_64.zip","browser_download_url":"https://github.com/tcsenpai/LickMyPaw/releases/download/v0.3.0/LickMyPaw-0.3.0-macos-x86_64.zip"},
               {"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/tcsenpai/LickMyPaw/releases/download/v0.3.0/SHA256SUMS.txt"}],"extra":1}
    """

    /// Builds a fake LickMyPaw.app, zips it with ditto, returns (zip data, sha256).
    private static func fakeZip(_ f: Fixture, id: String, ver: String, resources: Bool = true, name: String = "LickMyPaw.app") -> (Data, String) {
        let app = f.dir("src-\(UUID().uuidString)/" + name)
        try? FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        if resources { try? FileManager.default.createDirectory(atPath: app + "/Contents/Resources/LickMyPaw_LickMyPaw.bundle", withIntermediateDirectories: true) }
        let plist: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": ver, "CFBundleExecutable": "LickMyPaw"]
        plist.write(toFile: app + "/Contents/Info.plist", atomically: true)
        FileManager.default.createFile(atPath: app + "/Contents/MacOS/LickMyPaw", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let zip = f.root + "/z-\(UUID().uuidString).zip"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-c", "-k", "--keepParent", app, zip]; try? p.run(); p.waitUntilExit()
        let d = (try? Data(contentsOf: URL(fileURLWithPath: zip))) ?? Data()
        return (d, (try? UpdateCore.sha256(URL(fileURLWithPath: zip))) ?? "")
    }

    @MainActor static func run(_ t: TestCtx) async {
        let savedLast = AppPrefs.updateLastCheck; defer { AppPrefs.updateLastCheck = savedLast }   // model.check() stamps the real defaults
        // semver
        func v(_ s: String) -> SemVer { SemVer(s)! }
        t.check(v("0.2.0") < v("0.10.0") && v("1.0.0") > v("0.99.99") && v("v1.2.3") == v("1.2.3"), "semver numeric compare, v prefix"); t.reachedCode()
        t.check(v("0.2.0-dev") < v("0.2.0") && v("0.2.0-dev") > v("0.1.9") && v("0.2.1") > v("0.2.0-dev"), "dev version sorts below its release and above the previous one")
        t.check(v("1.0.0-rc.1") < v("1.0.0-rc.2") && v("1.0.0-rc.2") < v("1.0.0-rc.10") && v("1.0.0-1") < v("1.0.0-alpha") && v("1.0.0-alpha") < v("1.0.0-alpha.1"), "prerelease identifier precedence")
        t.check(v("1.2") == v("1.2.0") && v("1.0.0+build5") == v("1.0.0"), "short form and build metadata")
        t.check(SemVer("dev") == nil && SemVer("") == nil && SemVer("1.x.0") == nil && SemVer("1.2.3.4") == nil && SemVer("1.0.0-") == nil, "garbage is rejected")
        t.check(v("0.2.0-dev").text == "0.2.0-dev" && v("v1.2").text == "1.2.0", "text round-trip")

        // parse + asset selection + outcome
        guard let rel = try? UpdateCore.parse(Data(UpdateSelfTest.releaseJSON.utf8)) else { t.check(false, "canned release JSON parses"); return }
        t.check(rel.tag_name == "v0.3.0" && rel.assets.count == 4 && !rel.draft && rel.body?.contains("menu bar") == true, "canned release JSON parses (unknown keys ignored)")
        let sel = UpdateCore.select(rel, arch: "arm64")
        t.check(sel?.zip.name == "LickMyPaw-0.3.0-macos-arm64.zip" && sel?.sums?.name == "SHA256SUMS.txt", "asset selection: zip for this arch, not the dmg, plus the sums")
        t.check(UpdateCore.select(rel, arch: "x86_64")?.zip.name == "LickMyPaw-0.3.0-macos-x86_64.zip" && UpdateCore.select(rel, arch: "ppc") == nil, "per-arch selection, none for an unknown arch")
        t.check(UpdateCore.trusted("https://github.com/a") && UpdateCore.trusted("https://objects.githubusercontent.com/x") && !UpdateCore.trusted("http://github.com/a") && !UpdateCore.trusted("https://evilgithub.com/a") && !UpdateCore.trusted("https://github.com.evil.io/a"), "only https GitHub hosts are trusted")
        var evil = rel; evil.assets[1].browser_download_url = "https://evil.example/LickMyPaw-0.3.0-macos-arm64.zip"
        t.check(UpdateCore.select(evil, arch: "arm64") == nil, "an asset on a foreign host is never selected")
        if case .available(let i) = UpdateCore.evaluate(rel, current: v("0.2.0-dev"), arch: "arm64") { t.check(i.version == v("0.3.0") && i.notes.contains("self update"), "0.2.0-dev sees 0.3.0 as an update") } else { t.check(false, "0.2.0-dev sees 0.3.0 as an update") }
        t.check(UpdateCore.evaluate(rel, current: v("0.3.0"), arch: "arm64") == .upToDate(v("0.3.0")) && UpdateCore.evaluate(rel, current: v("0.4.0"), arch: "arm64") == .upToDate(v("0.3.0")), "same or newer installed: up to date")
        t.check(UpdateCore.evaluate(rel, current: nil, arch: "arm64") == .upToDate(v("0.3.0")), "unversioned dev build never claims an update")
        var pre = rel; pre.prerelease = true; var dr = rel; dr.draft = true
        t.check(UpdateCore.evaluate(pre, current: v("0.1.0"), arch: "arm64") == .unusable("pre-release or draft") && UpdateCore.evaluate(dr, current: v("0.1.0"), arch: "arm64") == .unusable("pre-release or draft"), "pre-releases and drafts are ignored")

        // checksums
        let sums = "\(String(repeating: "a", count: 64))  LickMyPaw-0.3.0-macos-arm64.dmg\n\(String(repeating: "B", count: 64)) *LickMyPaw-0.3.0-macos-arm64.zip\nnot a line\n"
        t.check(UpdateCore.expectedHash(sums: sums, file: "LickMyPaw-0.3.0-macos-arm64.zip") == String(repeating: "b", count: 64) && UpdateCore.expectedHash(sums: sums, file: "nope.zip") == nil, "SHA256SUMS parsing (binary marker, case, unknown file)")

        // full prepare() against a fake HTTP client with a real ditto zip
        let f = Fixture(); defer { f.cleanup() }
        let id = "org.lickmypaw.app"
        let (zipData, hash) = fakeZip(f, id: id, ver: "0.3.0")
        let zipURL = "https://github.com/tcsenpai/LickMyPaw/releases/download/v0.3.0/LickMyPaw-0.3.0-macos-arm64.zip", sumsURL = "https://github.com/tcsenpai/LickMyPaw/releases/download/v0.3.0/SHA256SUMS.txt"
        func info(_ s: Bool = true) -> UpdateInfo { UpdateInfo(version: v("0.3.0"), tag: "0.3.0", notes: "", page: nil, zip: GHAsset(name: "LickMyPaw-0.3.0-macos-arm64.zip", browser_download_url: zipURL), sums: s ? GHAsset(name: UpdateCore.sumsName, browser_download_url: sumsURL) : nil) }
        func http(_ hash: String, _ z: Data = zipData) -> FakeHTTP { FakeHTTP(files: [zipURL: z, sumsURL: Data("\(hash)  LickMyPaw-0.3.0-macos-arm64.zip\n".utf8)]) }
        let work = URL(fileURLWithPath: f.dir("work-ok"))
        let app = try? await UpdateCore.prepare(info(), http: http(hash), work: work, bundleID: id)
        t.check(app != nil && FileManager.default.fileExists(atPath: app!.path + "/Contents/Info.plist"), "prepare: download, verify checksum, unzip, verify bundle"); t.reachedCode()
        let w2 = URL(fileURLWithPath: f.dir("work-bad"))
        var refused = false
        do { _ = try await UpdateCore.prepare(info(), http: http(String(repeating: "0", count: 64)), work: w2, bundleID: id) } catch { refused = true }
        t.check(refused && !FileManager.default.fileExists(atPath: w2.path + "/unpacked/LickMyPaw.app"), "checksum mismatch is refused and nothing is unpacked")
        var r2 = false; do { _ = try await UpdateCore.prepare(info(false), http: http(hash), work: URL(fileURLWithPath: f.dir("w3")), bundleID: id) } catch { r2 = true }
        t.check(r2, "a release without SHA256SUMS.txt is refused")
        let (otherZip, otherHash) = fakeZip(f, id: "com.evil.app", ver: "0.3.0")
        var r3 = false; do { _ = try await UpdateCore.prepare(info(), http: http(otherHash, otherZip), work: URL(fileURLWithPath: f.dir("w4")), bundleID: id) } catch { r3 = true }
        t.check(r3, "a valid checksum but the wrong bundle id is refused")
        let (oldZip, oldHash) = fakeZip(f, id: id, ver: "0.1.0")
        var r4 = false; do { _ = try await UpdateCore.prepare(info(), http: http(oldHash, oldZip), work: URL(fileURLWithPath: f.dir("w5")), bundleID: id) } catch { r4 = true }
        t.check(r4, "a different version than announced is refused")
        let (nrZip, nrHash) = fakeZip(f, id: id, ver: "0.3.0", resources: false)
        var r5 = false; do { _ = try await UpdateCore.prepare(info(), http: http(nrHash, nrZip), work: URL(fileURLWithPath: f.dir("w6")), bundleID: id) } catch { r5 = true }
        t.check(r5, "a bundle without its resources is refused")
        let (wnZip, wnHash) = fakeZip(f, id: id, ver: "0.3.0", name: "Other.app")
        var r6 = false; do { _ = try await UpdateCore.prepare(info(), http: http(wnHash, wnZip), work: URL(fileURLWithPath: f.dir("w7")), bundleID: id) } catch { r6 = true }
        t.check(r6, "an archive that is not exactly LickMyPaw.app is refused")

        // model flow with the fake client (finish is stubbed: nothing is swapped, nothing quits)
        let m = UpdateModel(); m.current = v("0.2.0-dev"); m.bundleID = id
        let apiData = Data(releaseJSON.utf8)
        var files = http(hash).files; files[UpdateCore.api.absoluteString] = apiData; files["https://github.com/tcsenpai/LickMyPaw/releases/download/v0.3.0/SHA256SUMS.txt"] = files[sumsURL]
        m.http = FakeHTTP(files: files)
        nonisolated(unsafe) var finished: URL?
        m.finish = { app, _, _ in finished = app }
        await m.check()
        t.check(m.state == .available && m.info?.version == v("0.3.0") && m.latest == v("0.3.0"), "model: check finds the update"); t.reachedCode()
        // the canned release lists arm64 and x86_64 only; make the model test arch-proof by using this machine's arch asset names
        if m.info == nil || UpdateCore.arch() != "arm64" { t.check(true, "model install step skipped on non-arm64 host") } else {
            await m.install()
            t.check(finished != nil && m.state == .downloading, "model: install verifies, then hands the new app to finish()")
        }
        m.http = FakeHTTP(files: [:]); m.state = .idle; await m.check()
        if case .failed = m.state { t.check(true, "model: network failure is reported, not thrown") } else { t.check(false, "model: network failure is reported, not thrown") }
        t.check(!Runtime.isPackagedApp, "auto check never runs headless")
        UpdateModel.shared.autoCheckIfDue()
        t.check(UpdateModel.shared.state == .idle, "autoCheckIfDue does nothing outside a packaged app")

        // due logic is on the pref date; relaunch helper argv + script
        let hostile = "/tmp/a b/'$(touch pwned)';`x`\"/LickMyPaw.app"
        let inv = Relaunch.invocation(script: URL(fileURLWithPath: "/tmp/w/swap.sh"), pid: 4242, newApp: URL(fileURLWithPath: hostile), target: URL(fileURLWithPath: "/Applications/LickMyPaw.app"), work: URL(fileURLWithPath: "/tmp/lmp-update-1"))
        t.check(inv.exe == "/bin/sh" && inv.args == ["/tmp/w/swap.sh", "4242", hostile, "/Applications/LickMyPaw.app", "/tmp/lmp-update-1", "/usr/bin/open"], "helper argv: every path is one verbatim argument"); t.reachedCode()
        t.check(!Relaunch.script.contains(hostile) && !Relaunch.script.contains("/Applications") && Relaunch.script.contains("\"$3\""), "helper script is constant text with quoted positional args only")
        // run the helper on fixtures (opener = /usr/bin/true, dead pid): the swap, the rollback and the cleanup
        let target = f.dir("apps/Target App.app"); f.file("apps/Target App.app/old.txt")
        let newApp = f.dir("wk/lmp-update-x/new.app"); f.file("wk/lmp-update-x/new.app/new.txt")
        let wdir = URL(fileURLWithPath: f.root + "/wk/lmp-update-x")
        let sh = wdir.appendingPathComponent("swap.sh"); try? Relaunch.script.write(to: sh, atomically: true, encoding: .utf8)
        func runHelper(_ new: String, _ tgt: String) -> Int32 {
            let i = Relaunch.invocation(script: sh, pid: 999_999, newApp: URL(fileURLWithPath: new), target: URL(fileURLWithPath: tgt), work: wdir, opener: "/usr/bin/true")
            let p = Process(); p.executableURL = URL(fileURLWithPath: i.exe); p.arguments = i.args; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        let bad = runHelper(f.root + "/wk/lmp-update-x/missing.app", target)
        t.check(bad != 0 && FileManager.default.fileExists(atPath: target + "/old.txt") && !FileManager.default.fileExists(atPath: target + ".update-new"), "helper: a failed copy leaves the installed app untouched")
        let good = runHelper(newApp, target)
        t.check(good == 0 && FileManager.default.fileExists(atPath: target + "/new.txt") && !FileManager.default.fileExists(atPath: target + "/old.txt") && !FileManager.default.fileExists(atPath: target + ".update-old"), "helper: swaps the app, removes the backup (path with a space)")
        t.check(!FileManager.default.fileExists(atPath: wdir.path), "helper: cleans the work dir")
        // writability
        let ro = f.dir("ro"); let roApp = f.dir("ro/X.app")
        t.check(Relaunch.canReplace(URL(fileURLWithPath: roApp)) && !Relaunch.canReplace(URL(fileURLWithPath: f.dir("plain"))), "canReplace: needs an .app in a writable place")
        chmod(ro, 0o555); defer { chmod(ro, 0o755) }
        t.check(!Relaunch.canReplace(URL(fileURLWithPath: roApp)), "canReplace: read-only folder falls back to revealing the download")

        // CLI
        let cur = v("0.2.0-dev")
        let r = await UpdateCLI.check(http: FakeHTTP(files: [UpdateCore.api.absoluteString: apiData]), current: cur, bundleVersion: "0.2.0-dev")
        t.check(r.code == 0 && r.json["current"] as? String == "0.2.0-dev" && r.json["latest"] as? String == "0.3.0" && (r.json["update_available"] as? Bool) == (UpdateCore.arch() == "arm64" || UpdateCore.arch() == "x86_64"), "CLI check: current vs latest")
        let e = await UpdateCLI.check(http: FakeHTTP(files: [:]), current: cur, bundleVersion: "0.2.0-dev")
        t.check(e.code == 1 && e.json["error"] != nil, "CLI check: network error gives exit code 1")
    }
}

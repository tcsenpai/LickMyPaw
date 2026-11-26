import Foundation
import AppKit

// MARK: version compare (pure)

enum Version {
    private enum Tok: Equatable { case num(Int), str(String) }
    private static func tokens(_ s: String) -> [Tok] {
        var out: [Tok] = [], cur = "", digits = true
        func flush() { if !cur.isEmpty { out.append(digits ? .num(Int(cur) ?? Int.max) : .str(cur)) }; cur = "" }
        for c in s.lowercased() {
            if c.isASCII && c.isNumber { if !digits { flush() }; digits = true; cur.append(c) }
            else if c.isLetter { if digits { flush() }; digits = false; cur.append(c) }
            else { flush() }
        }
        flush(); return out
    }
    /// -1 / 0 / 1. "1.0" == "1.0.0"; a letter segment (beta, rc) sorts before a missing one, so 1.0b2 < 1.0.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = tokens(a), y = tokens(b)
        for i in 0..<max(x.count, y.count) {
            let l: Tok? = i < x.count ? x[i] : nil, r: Tok? = i < y.count ? y[i] : nil
            switch (l, r) {
            case (.num(let p)?, .num(let q)?): if p != q { return p < q ? -1 : 1 }
            case (.str(let p)?, .str(let q)?): if p != q { return p < q ? -1 : 1 }
            case (.num?, .str?): return 1
            case (.str?, .num?): return -1
            case (.num(let p)?, nil): if p != 0 { return 1 }
            case (nil, .num(let q)?): if q != 0 { return -1 }
            case (.str?, nil): return -1
            case (nil, .str?): return 1
            default: break
            }
        }
        return 0
    }
}

// MARK: Sparkle appcast (pure)

struct AppcastItem: Equatable { var version: String?, shortVersion: String?, minOS: String?, channel: String? }

enum Appcast {
    enum ParseError: Error { case malformed }

    private final class P: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = [], cur: AppcastItem?, text = "", inField = false
        static let fields: Set<String> = ["sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion", "sparkle:channel"]
        func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if n == "item" { cur = AppcastItem() }
            else if cur != nil && n == "enclosure" {
                if cur!.version == nil { cur!.version = a["sparkle:version"] }
                if cur!.shortVersion == nil { cur!.shortVersion = a["sparkle:shortVersionString"] }
            } else if cur != nil && Self.fields.contains(n) { text = ""; inField = true }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inField { text += s } }
        func parser(_ p: XMLParser, foundCDATA b: Data) { if inField { text += String(decoding: b, as: UTF8.self) } }
        func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inField && cur != nil && Self.fields.contains(n) && !t.isEmpty {
                switch n {
                case "sparkle:version": cur!.version = t
                case "sparkle:shortVersionString": cur!.shortVersion = t
                case "sparkle:minimumSystemVersion": cur!.minOS = t
                default: cur!.channel = t
                }
            }
            if Self.fields.contains(n) { inField = false }
            if n == "item", let c = cur { if c.version != nil || c.shortVersion != nil { items.append(c) }; cur = nil }
        }
    }

    /// Throws on malformed XML (a half-parsed feed must never be read as "no update"). External entities are never resolved.
    static func parse(_ data: Data) throws -> [AppcastItem] {
        let x = XMLParser(data: data), p = P()
        x.delegate = p; x.shouldResolveExternalEntities = false
        guard x.parse(), x.parserError == nil else { throw ParseError.malformed }
        return p.items
    }

    /// Newest stable item this OS can run (channel items are betas: ignored).
    static func newest(_ items: [AppcastItem], os: String) -> AppcastItem? {
        func key(_ i: AppcastItem) -> String { i.version ?? i.shortVersion ?? "" }
        return items.filter { $0.channel == nil && ($0.minOS.map { Version.compare($0, os) <= 0 } ?? true) }
            .max { Version.compare(key($0), key($1)) < 0 }
    }
}

// MARK: brew outdated (pure)

struct OutdatedCask: Equatable { let token: String, installed: String, current: String }

enum BrewOutdated {
    /// `brew outdated --cask --greedy --json=v2`. installed_versions is an array (new brew) or a string (old brew).
    static func parse(_ out: String) -> [OutdatedCask]? {
        // brew may print warnings before the JSON object
        guard let start = out.firstIndex(of: "{"), let d = String(out[start...]).data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let casks = j["casks"] as? [[String: Any]] else { return nil }
        return casks.compactMap { c in
            guard let n = c["name"] as? String else { return nil }
            let inst = (c["installed_versions"] as? [String])?.last ?? (c["installed_versions"] as? String) ?? ""
            return OutdatedCask(token: n, installed: inst, current: c["current_version"] as? String ?? "")
        }
    }
    /// Typed argument guard: only a plain cask token ever reaches brew's argv.
    static func validToken(_ t: String) -> Bool {
        t.range(of: #"^[a-z0-9][a-z0-9@+._-]{0,99}$"#, options: .regularExpression) != nil
    }
    static func slug(_ s: String) -> String {
        String(s.lowercased().map { $0 == " " ? "-" : $0 }.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-+@".contains($0)) })
    }
}

// MARK: inventory + classification

enum UpdateKind: Equatable { case sparkle, appStore, brew, manual }
enum UpdateStatus: Equatable {
    case notChecked, upToDate, available(String)
    case unknown(String)   // English key in the Updater table
}

struct UpdateEntry: Identifiable, Equatable {
    var id: String { path }
    let name: String, fileName: String, bundleID: String, path: String
    var version: String, build: String
    var kind: UpdateKind
    let feed: URL?
    var brewToken: String?
    var status = UpdateStatus.notChecked
}

enum UpdaterInventory {
    /// Info.plist only, no sizes and no network: cheap enough to run on every first open. Fixture-testable via roots.
    static func load(roots: [String] = AppInventory.defaultRoots) -> [UpdateEntry] {
        let fm = FileManager.default
        var out: [UpdateEntry] = []
        for root in roots {
            for e in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where e.hasSuffix(".app") {
                if let u = read(root + "/" + e) { out.append(u) }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// nil for system apps (shipped with macOS: updated by Software Update, not here).
    static func read(_ p: String) -> UpdateEntry? {
        let fm = FileManager.default
        let info = NSDictionary(contentsOfFile: p + "/Contents/Info.plist") as? [String: Any] ?? [:]
        let bid = info["CFBundleIdentifier"] as? String ?? ""
        let file = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
        let receipt = fm.fileExists(atPath: p + "/Contents/_MASReceipt/receipt")
        if Safety.real(p).hasPrefix("/System") || (bid.hasPrefix("com.apple.") && !receipt) { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? "", build = info["CFBundleVersion"] as? String ?? ""
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return UpdateEntry(name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? file, fileName: file, bundleID: bid, path: p,
                           version: short.isEmpty ? build : short, build: build.isEmpty ? short : build,
                           kind: classify(receipt: receipt, hasFeed: feed != nil), feed: feed)
    }

    /// The Mac App Store owns the update when a receipt exists, even if the app also ships Sparkle.
    static func classify(receipt: Bool, hasFeed: Bool) -> UpdateKind { receipt ? .appStore : hasFeed ? .sparkle : .manual }
}

// MARK: network + checks

protocol HTTPClient: Sendable { func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data }

struct URLSessionHTTPClient: HTTPClient {
    struct Failure: Error { let reason: String }
    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.setValue("LickMyPaw", forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession(configuration: .ephemeral).data(for: r)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw Failure(reason: "HTTP \(h.statusCode)") }
        guard d.count <= maxBytes else { throw Failure(reason: "too large") }
        return d
    }
}

enum UpdateChecker {
    static var osVersion: String { let v = ProcessInfo.processInfo.operatingSystemVersion; return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }

    /// Sparkle compares sparkle:version with CFBundleVersion; the short string is the fallback when either build is missing.
    static func decide(build: String, short: String, items: [AppcastItem], os: String) -> UpdateStatus {
        guard let n = Appcast.newest(items, os: os) else { return .unknown("No usable release in the update feed") }
        let newer: Bool
        if let v = n.version, !build.isEmpty { newer = Version.compare(v, build) > 0 }
        else if let s = n.shortVersion ?? n.version, !short.isEmpty { newer = Version.compare(s, short) > 0 }
        else { return .unknown("No usable release in the update feed") }
        return newer ? .available(n.shortVersion ?? n.version ?? "") : .upToDate
    }

    static func sparkle(_ e: UpdateEntry, http: HTTPClient, os: String = osVersion) async -> UpdateStatus {
        guard let feed = e.feed else { return .unknown("No update feed") }
        guard feed.scheme?.lowercased() == "https" else { return .unknown("The update feed is not secure (HTTP)") }
        let data: Data
        do { data = try await http.get(feed, timeout: 15, maxBytes: 5 << 20) } catch { return .unknown("The update feed could not be reached") }
        guard let items = try? Appcast.parse(data) else { return .unknown("The update feed is not valid") }
        return decide(build: e.build, short: e.version, items: items, os: os)
    }
}

protocol AppOpener: Sendable { func openApp(_ path: String); func openAppStore() }
struct WorkspaceOpener: AppOpener {
    func openApp(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    func openAppStore() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/App Store.app")) }
}

// MARK: model

@MainActor final class UpdaterModel: ObservableObject {
    static let shared = UpdaterModel()
    @Published var entries: [UpdateEntry] = []
    @Published var loading = false
    @Published var checking = false
    @Published var checkedAt: Date?
    @Published var now = Date()
    @Published var brewNote: String?          // English key in the Updater table
    @Published var confirming: UpdateEntry?   // brew upgrade awaiting consent
    @Published var running = false
    @Published var log: [String] = []
    @Published var runResult: String?         // English key, nil while idle
    var loader: @Sendable () -> [UpdateEntry] = { UpdaterInventory.load() }
    var http: HTTPClient = URLSessionHTTPClient()
    var runner: InstallRunner = SystemInstallRunner()
    var opener: AppOpener = WorkspaceOpener()
    var brewCandidates = ClamInstall.brewPaths
    var uid: () -> uid_t = { getuid() }
    var os = UpdateChecker.osVersion
    private var loaded = false
    private var cancelFlag = CancelFlag()

    init() {
        NotificationCenter.default.addObserver(forName: Engine.didChange, object: nil, queue: nil) { [weak self] _ in   // queue: .main would deadlock
            Task { @MainActor in self?.dropVanished() }
        }
    }

    func dropVanished() { entries.removeAll { !FileManager.default.fileExists(atPath: $0.path) } }

    /// Local only (reads Info.plist): safe to run when the tab opens. Network happens in check() only.
    func open() async {
        now = Date()
        guard !loaded && !loading else { return }
        loading = true
        let l = loader
        entries = await Task.detached { l() }.value
        loaded = true; loading = false
    }

    /// The ONLY place that touches the network or runs brew, and only from the explicit button.
    func check() async {
        guard !checking else { return }
        await open()
        checking = true; brewNote = nil
        defer { checking = false }
        for i in entries.indices { entries[i].status = .notChecked; if entries[i].kind == .brew { entries[i].kind = entries[i].feed != nil ? .sparkle : .manual }; entries[i].brewToken = nil }

        if let brew = ClamInstall.findBrew(brewCandidates) {
            let runner = self.runner, env = ClamInstall.environment(prefix: ClamInstall.prefix(ofBrew: brew)), flag = CancelFlag()
            let r = await Task.detached { runner.run(brew, ["outdated", "--cask", "--greedy", "--json=v2"], env: env, timeout: 120, cancel: flag, onLine: { _ in }) }.value
            if r.launchError == nil && !r.timedOut, let casks = BrewOutdated.parse(r.output) {
                for c in casks {
                    guard let i = entries.firstIndex(where: { [BrewOutdated.slug($0.name), BrewOutdated.slug($0.fileName)].contains(c.token) && $0.kind != .appStore }) else { continue }
                    entries[i].kind = .brew; entries[i].brewToken = c.token; entries[i].status = .available(c.current)
                }
            } else { brewNote = "Homebrew could not list outdated casks" }
        }

        let http = self.http, os = self.os
        let todo = entries.filter { $0.kind == .sparkle }
        for chunk in stride(from: 0, to: todo.count, by: 4).map({ Array(todo[$0..<min($0 + 4, todo.count)]) }) {
            let res = await withTaskGroup(of: (String, UpdateStatus).self) { g -> [(String, UpdateStatus)] in
                for e in chunk { g.addTask { (e.id, await UpdateChecker.sparkle(e, http: http, os: os)) } }
                var o: [(String, UpdateStatus)] = []; for await r in g { o.append(r) }; return o
            }
            for (id, s) in res { if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].status = s } }
        }
        for i in entries.indices where entries[i].kind == .manual { entries[i].status = .unknown("No update mechanism detected") }
        checkedAt = Date(); now = checkedAt!
    }

    var checkedNote: String? {
        guard let t = checkedAt else { return nil }
        return TTF("Saved results from %@ (%@): press Check for updates to refresh", "Updater", t.formatted(date: .omitted, time: .shortened), AppsModel.relativeTime(t, now: now))
    }

    /// Sparkle: launch the app (its own updater takes over). App Store: open the App Store. Brew has its own command.
    func openUpdate(_ e: UpdateEntry) {
        switch e.kind {
        case .appStore: opener.openAppStore()
        case .sparkle: opener.openApp(e.path)
        case .brew, .manual: break
        }
    }

    func command(_ e: UpdateEntry) -> String? {
        guard e.kind == .brew, let t = e.brewToken, BrewOutdated.validToken(t) else { return nil }
        return "brew upgrade --cask " + t
    }

    /// Only after the consent sheet. Typed argv, never a shell, never as root.
    func runUpgrade(_ e: UpdateEntry) async {
        confirming = nil
        guard !running, e.kind == .brew, let t = e.brewToken, BrewOutdated.validToken(t) else { return }
        log = []; runResult = nil
        guard uid() != 0 else { runResult = "Refusing to run as root. Open the app as a normal user."; return }
        guard let brew = ClamInstall.findBrew(brewCandidates) else { runResult = "Homebrew was not found"; return }
        running = true; cancelFlag = CancelFlag()
        defer { running = false }
        let runner = self.runner, env = ClamInstall.environment(prefix: ClamInstall.prefix(ofBrew: brew)), flag = cancelFlag
        log.append("$ brew upgrade --cask " + t)
        let r = await Task.detached {
            runner.run(brew, ["upgrade", "--cask", t], env: env, timeout: 900, cancel: flag) { l in Task { @MainActor in self.appendLog(l) } }
        }.value
        if r.cancelled { runResult = "Cancelled" }
        else if r.launchError != nil || r.timedOut || r.status != 0 { runResult = "The upgrade failed" }
        else {
            runResult = "Upgraded"
            if let i = entries.firstIndex(where: { $0.id == e.id }), let fresh = UpdaterInventory.read(e.path) {
                entries[i].version = fresh.version; entries[i].build = fresh.build; entries[i].status = .upToDate
            }
        }
    }
    private func appendLog(_ l: String) { log.append(l); if log.count > 200 { log.removeFirst(log.count - 200) } }
    func cancelRun() { cancelFlag.set() }
}

import SwiftUI
import AppKit

private func U(_ k: String) -> String { TT(k, "Updater") }

struct UpdaterView: View {
    @ObservedObject private var m = UpdaterModel.shared

    var body: some View {
        ZStack {
            Background()
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(U("Nothing is contacted until you press Check for updates.")).font(.system(size: 11, design: .rounded)).opacity(0.7)
                    Spacer()
                    Button { Task { await m.check() } } label: { SpinnerLabel(title: U("Check for updates"), busy: m.checking) }
                        .buttonStyle(SoftButton()).disabled(m.checking || m.loading)
                }
                if let n = m.checkedNote {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(n).font(.system(size: 11, design: .rounded)).opacity(0.8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let b = m.brewNote { Text(U(b)).font(.system(size: 11)).foregroundStyle(Color(hex: 0xFF8FC8)).frame(maxWidth: .infinity, alignment: .leading) }
                if m.loading && m.entries.isEmpty { Spacer(); ProgressView(U("Reading applications…")); Spacer() }
                else if m.entries.isEmpty { Spacer(); Text(U("No applications found")).opacity(0.7); Spacer() }
                else { ScrollView { LazyVStack(spacing: 6) { ForEach(sorted) { row($0) } } } }
                if m.running || m.runResult != nil || !m.log.isEmpty { runPanel }
            }.padding(20).foregroundStyle(.white)
        }
        .onAppear { Task { await m.open() } }
        .sheet(item: Binding(get: { m.confirming }, set: { m.confirming = $0 })) { consent($0) }
    }

    private var sorted: [UpdateEntry] {
        func rank(_ e: UpdateEntry) -> Int { if case .available = e.status { return 0 }; return e.kind == .appStore ? 1 : 2 }
        return m.entries.sorted { (rank($0), $0.name.lowercased()) < (rank($1), $1.name.lowercased()) }
    }

    private func kindBadge(_ k: UpdateKind) -> String {
        switch k { case .sparkle: return U("Sparkle"); case .appStore: return U("App Store"); case .brew: return U("Homebrew"); case .manual: return U("Manual") }
    }

    private func statusText(_ e: UpdateEntry) -> (String, Color) {
        switch e.status {
        case .notChecked: return (e.kind == .appStore ? U("Updates come from the App Store") : U("Not checked yet"), .white.opacity(0.6))
        case .upToDate: return (U("Up to date"), .green)
        case .available(let v): return (TTF("Update available: %@", "Updater", v), Color(hex: 0xFF8FC8))
        case .unknown(let r): return (U(r), .white.opacity(0.55))
        }
    }

    private func row(_ e: UpdateEntry) -> some View {
        let (st, col) = statusText(e)
        return HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: e.path)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(TTF("Version %@", "Updater", e.version)).font(.system(size: 11, design: .rounded)).opacity(0.65).lineLimit(1)
            }
            Spacer()
            Text(st).font(.system(size: 12, design: .rounded)).foregroundStyle(col).lineLimit(2).multilineTextAlignment(.trailing).frame(maxWidth: 200, alignment: .trailing)
            Text(kindBadge(e.kind)).font(.system(size: 10, weight: .semibold, design: .rounded)).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(.white.opacity(0.18)))
            actions(e).fixedSize().frame(minWidth: 150, alignment: .trailing)
        }.padding(10).glass(14)
    }

    @ViewBuilder private func actions(_ e: UpdateEntry) -> some View {
        switch e.kind {
        case .appStore: Button(U("Update in App Store")) { m.openUpdate(e) }.buttonStyle(SoftButton())
        case .sparkle:
            if case .available = e.status { Button(U("Open update")) { m.openUpdate(e) }.buttonStyle(PinkButton()) }
        case .brew:
            HStack(spacing: 6) {
                Button(U("Copy command")) { if let c = m.command(e) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) } }.buttonStyle(SoftButton())
                Button(U("Run")) { m.confirming = e }.buttonStyle(PinkButton()).disabled(m.running)
            }
        case .manual: EmptyView()
        }
    }

    private var runPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if m.running { ProgressView().controlSize(.small); Text(U("Running Homebrew…")).font(.system(size: 12, weight: .semibold)) }
                else if let r = m.runResult { Text(U(r)).font(.system(size: 12, weight: .semibold)) }
                Spacer()
                if m.running { Button(U("Cancel")) { m.cancelRun() }.buttonStyle(SoftButton()) }
            }
            ScrollView { Text(m.log.suffix(12).joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).opacity(0.75).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
        }.padding(12).glass(14)
    }

    private func consent(_ e: UpdateEntry) -> some View {
        ZStack {
            Background()
            VStack(alignment: .leading, spacing: 12) {
                Text(TTF("Update %@ with Homebrew?", "Updater", e.name)).font(.system(size: 18, weight: .bold, design: .rounded))
                Text(U("This runs the command below on your Mac. Close the app first if it is open.")).font(.system(size: 12)).opacity(0.75)
                Text(m.command(e) ?? "").font(.system(size: 12, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading).glass(12)
                HStack {
                    Spacer()
                    Button(U("Cancel")) { m.confirming = nil }.buttonStyle(SoftButton())
                    Button(U("Run")) { Task { await m.runUpgrade(e) } }.buttonStyle(PinkButton())
                }
            }.padding(22).foregroundStyle(.white)
        }.frame(width: 440, height: 220)
    }
}

// MARK: selftest

private struct FakeHTTP: HTTPClient {
    final class Log: @unchecked Sendable { var urls: [String] = [] }
    let log = Log()
    let routes: [String: Data]
    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data {
        log.urls.append(url.absoluteString)
        guard let d = routes[url.absoluteString] else { throw URLSessionHTTPClient.Failure(reason: "offline") }
        return d
    }
}

private final class FakeBrew: InstallRunner, @unchecked Sendable {
    var calls: [[String]] = []
    var outdatedJSON = ""
    var upgradeStatus: Int32 = 0
    func run(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval, cancel: CancelFlag, onLine: @escaping @Sendable (String) -> Void) -> ProcResult {
        calls.append(args)
        var r = ProcResult()
        if args.first == "outdated" { r.status = 0; r.output = outdatedJSON }
        else { onLine("==> Upgrading"); r.status = upgradeStatus; r.output = "==> Upgrading" }
        return r
    }
}

private final class FakeOpener: AppOpener, @unchecked Sendable {
    var events: [String] = []
    func openApp(_ path: String) { events.append("app:" + path) }
    func openAppStore() { events.append("store") }
}

enum UpdaterSelfTest {
    static func feed(_ items: String) -> Data { Data("<?xml version=\"1.0\"?><rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>\(items)</channel></rss>".utf8) }

    @MainActor static func run(_ t: TestCtx) async {
        // --- version compare ---
        let cmp: [(String, String, Int)] = [("1.0", "1.0.0", 0), ("1.2", "1.10", -1), ("2.0", "1.9.9", 1), ("1.0b2", "1.0", -1), ("1.0rc1", "1.0b9", 1),
                                            ("1.0", "1.0.1", -1), ("10", "9", 1), ("", "", 0), ("1.0a", "1.0.1", -1), ("3.4.5", "3.4.5", 0)]
        for (a, b, e) in cmp { t.check(Version.compare(a, b) == e && Version.compare(b, a) == -e, "version \(a) vs \(b) = \(e)") }
        t.reachedCode(cmp.count)

        // --- appcast parsing ---
        let ok = feed("""
        <item><title>New</title><enclosure url="https://x/y.zip" sparkle:version="210" sparkle:shortVersionString="2.1"/></item>
        <item><sparkle:version>200</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString></item>
        <item><enclosure sparkle:version="300" sparkle:shortVersionString="3.0b1"/><sparkle:channel>beta</sparkle:channel></item>
        <item><enclosure sparkle:version="400" sparkle:shortVersionString="4.0"/><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
        """)
        let items = (try? Appcast.parse(ok)) ?? []
        t.check(items.count == 4 && items[0].version == "210" && items[0].shortVersion == "2.1", "appcast: enclosure attributes"); t.reachedCode()
        t.check(items[1].version == "200" && items[1].shortVersion == "2.0", "appcast: child elements")
        t.check(items[2].channel == "beta" && items[3].minOS == "99.0", "appcast: channel and minimum OS read")
        t.check(Appcast.newest(items, os: "14.0.0")?.shortVersion == "2.1", "newest ignores beta channel and too-new minimum OS")
        t.check(Appcast.newest(items, os: "99.1.0")?.shortVersion == "4.0", "newest allows it once the OS is new enough")
        t.check((try? Appcast.parse(feed(""))) == [], "empty feed parses to no items")
        t.check((try? Appcast.parse(Data("<rss><channel><item><enclosure sparkle:version=\"1\"".utf8))) == nil, "truncated XML throws")
        t.check((try? Appcast.parse(Data("this is not xml at all".utf8))) == nil, "garbage throws")
        t.check((try? Appcast.parse(Data("<rss><channel><item></rss>".utf8))) == nil, "mismatched tags throw")
        t.check((try? Appcast.parse(Data())) == nil, "empty data throws")
        t.check((try? Appcast.parse(Data("<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><rss><channel><item><title>&x;</title><enclosure sparkle:version=\"5\"/></item></channel></rss>".utf8)))?.count ?? 1 <= 1, "external entities are not resolved")

        // --- decision ---
        let two = [AppcastItem(version: "210", shortVersion: "2.1"), AppcastItem(version: "200", shortVersion: "2.0")]
        t.check(UpdateChecker.decide(build: "200", short: "2.0", items: two, os: "14.0.0") == .available("2.1"), "decide: newer build -> available")
        t.check(UpdateChecker.decide(build: "210", short: "2.1", items: two, os: "14.0.0") == .upToDate, "decide: same build -> up to date")
        t.check(UpdateChecker.decide(build: "999", short: "9.9", items: two, os: "14.0.0") == .upToDate, "decide: installed newer than feed -> up to date")
        t.check(UpdateChecker.decide(build: "", short: "2.0", items: [AppcastItem(version: nil, shortVersion: "2.5")], os: "14.0.0") == .available("2.5"), "decide: short version fallback")
        if case .unknown = UpdateChecker.decide(build: "1", short: "1", items: [], os: "14.0.0") { t.check(true, "decide: empty feed -> unknown") } else { t.check(false, "decide: empty feed -> unknown") }

        // --- brew json ---
        let bj = "Warning: something\n{\"formulae\":[],\"casks\":[{\"name\":\"foo-app\",\"installed_versions\":[\"1.0\"],\"current_version\":\"2.0\"},{\"name\":\"old-style\",\"installed_versions\":\"3.0\",\"current_version\":\"4.0\"},{\"installed_versions\":[\"1\"]}]}"
        let oc = BrewOutdated.parse(bj)
        t.check(oc == [OutdatedCask(token: "foo-app", installed: "1.0", current: "2.0"), OutdatedCask(token: "old-style", installed: "3.0", current: "4.0")], "brew json: array and string installed_versions, nameless skipped"); t.reachedCode()
        t.check(BrewOutdated.parse("{\"formulae\":[],\"casks\":[]}") == [] && BrewOutdated.parse("nope") == nil && BrewOutdated.parse("{\"x\":1}") == nil, "brew json: empty, garbage, wrong shape")
        t.check(BrewOutdated.validToken("visual-studio-code") && BrewOutdated.validToken("font-fira-code@1") && !BrewOutdated.validToken("-evil") && !BrewOutdated.validToken("a b") && !BrewOutdated.validToken("a;rm") && !BrewOutdated.validToken(""), "cask token guard")
        t.check(BrewOutdated.slug("Visual Studio Code") == "visual-studio-code" && BrewOutdated.slug("1Password") == "1password", "app name slug")

        // --- inventory on a fixture, classification ---
        let f = Fixture(); defer { f.cleanup() }
        setenv("LICKMYPAW_HOME", f.home, 1); defer { unsetenv("LICKMYPAW_HOME") }
        func mk(_ name: String, _ bid: String, short: String = "1.0", build: String = "100", extra: [String: Any] = [:], receipt: Bool = false) {
            let c = f.dir("home/Applications/\(name).app/Contents")
            var d: [String: Any] = ["CFBundleIdentifier": bid, "CFBundleName": name, "CFBundleShortVersionString": short, "CFBundleVersion": build]
            for (k, v) in extra { d[k] = v }
            try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0).write(to: URL(fileURLWithPath: c + "/Info.plist"))
            if receipt { f.file("home/Applications/\(name).app/Contents/_MASReceipt/receipt") }
        }
        mk("Spark", "com.t.spark", short: "2.0", build: "200", extra: ["SUFeedURL": "https://t.example/spark.xml"])
        mk("Store", "com.t.store", receipt: true)
        mk("StoreSpark", "com.t.ss", extra: ["SUFeedURL": "https://t.example/ss.xml"], receipt: true)
        mk("Plain", "com.t.plain")
        mk("Insecure", "com.t.ins", extra: ["SUFeedURL": "http://t.example/i.xml"])
        mk("Broken", "com.t.broken", extra: ["SUFeedURL": "https://t.example/broken.xml"])
        mk("Gone", "com.t.gone", extra: ["SUFeedURL": "https://t.example/gone.xml"])
        mk("Foo App", "com.t.foo", short: "1.0", extra: ["SUFeedURL": "https://t.example/foo.xml"])
        mk("Safari", "com.apple.Safari")
        mk("Pages", "com.apple.iWork.Pages", receipt: true)
        let roots = [f.home + "/Applications"]
        let inv = UpdaterInventory.load(roots: roots)
        let byName = Dictionary(uniqueKeysWithValues: inv.map { ($0.name, $0) })
        t.check(inv.count == 9 && byName["Safari"] == nil && byName["Pages"] != nil, "inventory: 9 apps, macOS-shipped Safari skipped, Pages (receipt) kept (\(inv.map(\.name)))"); t.reachedCode()
        t.check(byName["Spark"]?.kind == .sparkle && byName["Spark"]?.build == "200" && byName["Spark"]?.version == "2.0", "classify: Sparkle with versions")
        t.check(byName["Store"]?.kind == .appStore && byName["StoreSpark"]?.kind == .appStore, "classify: receipt wins, even over Sparkle")
        t.check(byName["Plain"]?.kind == .manual && byName["Plain"]?.feed == nil, "classify: no mechanism -> manual")
        t.check(byName["Insecure"]?.kind == .sparkle && byName["Insecure"]?.feed?.scheme == "http", "classify: http feed kept as Sparkle (refused at check time)")
        t.check(UpdaterInventory.classify(receipt: false, hasFeed: false) == .manual && UpdaterInventory.classify(receipt: true, hasFeed: true) == .appStore, "classify table")

        // --- model: nothing before the explicit check; fakes only ---
        let http = FakeHTTP(routes: [
            "https://t.example/spark.xml": feed("<item><enclosure sparkle:version=\"210\" sparkle:shortVersionString=\"2.1\"/></item>"),
            "https://t.example/broken.xml": Data("<rss><channel><item>".utf8),
            "https://t.example/foo.xml": feed("<item><enclosure sparkle:version=\"100\" sparkle:shortVersionString=\"1.0\"/></item>"),
        ])
        let brew = FakeBrew(); let op = FakeOpener()
        let bdir = f.dir("fakebrew/bin"); let bexe = bdir + "/brew"; f.file("fakebrew/bin/brew")
        chmod(bexe, 0o755)
        brew.outdatedJSON = "{\"formulae\":[],\"casks\":[{\"name\":\"foo-app\",\"installed_versions\":[\"1.0\"],\"current_version\":\"1.5\"},{\"name\":\"plain\",\"installed_versions\":[\"1.0\"],\"current_version\":\"2.0\"},{\"name\":\"store\",\"installed_versions\":[\"1.0\"],\"current_version\":\"9\"}]}"
        final class Cnt: @unchecked Sendable { var n = 0 }
        let loads = Cnt()
        let m = UpdaterModel()
        m.loader = { loads.n += 1; return UpdaterInventory.load(roots: roots) }
        m.http = http; m.runner = brew; m.opener = op; m.brewCandidates = [bexe]; m.uid = { 501 }; m.os = "14.0.0"
        await m.open(); await m.open()
        t.check(loads.n == 1 && m.entries.count == 9 && http.log.urls.isEmpty && brew.calls.isEmpty && m.checkedAt == nil, "open lists apps locally: no network, no brew, one load"); t.reachedCode()
        await m.check()
        let me = Dictionary(uniqueKeysWithValues: m.entries.map { ($0.name, $0) })
        t.check(me["Spark"]?.status == .available("2.1") && me["Spark"]?.kind == .sparkle, "check: Sparkle update found")
        t.check(me["Foo App"]?.kind == .brew && me["Foo App"]?.brewToken == "foo-app" && me["Foo App"]?.status == .available("1.5"), "check: brew cask outdated overrides Sparkle")
        t.check(me["Plain"]?.kind == .brew && me["Plain"]?.status == .available("2.0"), "check: manual app matched to a cask by name")
        t.check(me["Store"]?.kind == .appStore && me["Store"]?.status == .notChecked, "check: App Store app is never scripted nor guessed")
        if case .unknown = me["Broken"]?.status ?? .notChecked { t.check(true, "check: malformed appcast -> unknown") } else { t.check(false, "check: malformed appcast -> unknown") }
        if case .unknown = me["Gone"]?.status ?? .notChecked { t.check(true, "check: unreachable feed -> unknown") } else { t.check(false, "check: unreachable feed -> unknown") }
        t.check(me["Insecure"]?.status == .unknown("The update feed is not secure (HTTP)") && !http.log.urls.contains { $0.hasPrefix("http:") }, "check: http feed refused, never requested")
        t.check(brew.calls == [["outdated", "--cask", "--greedy", "--json=v2"]] && m.checkedAt != nil && m.checkedNote != nil, "check: one brew outdated call, saved-results note set")
        let n1 = http.log.urls.count
        await m.open()
        t.check(http.log.urls.count == n1 && loads.n == 1, "reopening keeps the session cache (no refetch)")

        // brew absent: no brew calls at all
        let m2 = UpdaterModel(); m2.loader = { UpdaterInventory.load(roots: roots) }; m2.http = http; m2.runner = brew; m2.brewCandidates = ["/nonexistent/brew"]; m2.os = "14.0.0"
        brew.calls = []
        await m2.check()
        t.check(brew.calls.isEmpty && m2.entries.first { $0.name == "Spark" }?.status == .available("2.1") && m2.entries.first { $0.name == "Plain" }?.kind == .manual, "no brew installed: runner never called, Sparkle still works")
        // brew output garbage: note, no crash
        let m3 = UpdaterModel(); m3.loader = { UpdaterInventory.load(roots: roots) }; m3.http = http; m3.runner = brew; m3.brewCandidates = [bexe]; m3.os = "14.0.0"
        brew.outdatedJSON = "boom"
        await m3.check()
        t.check(m3.brewNote != nil && m3.entries.first { $0.name == "Spark" }?.status == .available("2.1"), "unparseable brew output -> note, rest unaffected")

        // --- actions ---
        m.openUpdate(me["Spark"]!); m.openUpdate(me["Store"]!); m.openUpdate(me["Foo App"]!)
        t.check(op.events == ["app:" + me["Spark"]!.path, "store"], "open update: Sparkle opens the app, App Store opens the store, brew opens nothing")
        t.check(m.command(me["Foo App"]!) == "brew upgrade --cask foo-app" && m.command(me["Spark"]!) == nil, "command only for brew entries")
        brew.calls = []; brew.upgradeStatus = 0
        var evil = me["Foo App"]!; evil.brewToken = "x; rm -rf ~"
        await m.runUpgrade(evil)
        t.check(brew.calls.isEmpty, "invalid cask token never reaches brew")
        await m.runUpgrade(me["Spark"]!)
        t.check(brew.calls.isEmpty, "non-brew entry never runs brew")
        m.uid = { 0 }; await m.runUpgrade(me["Foo App"]!)
        t.check(brew.calls.isEmpty && m.runResult != nil, "refuses to run as root")
        m.uid = { 501 }
        await m.runUpgrade(me["Foo App"]!)
        t.check(brew.calls == [["upgrade", "--cask", "foo-app"]] && m.runResult == "Upgraded" && m.log.first == "$ brew upgrade --cask foo-app", "run: typed argv, success reported"); t.reachedCode()
        t.check(m.entries.first { $0.name == "Foo App" }?.status == .upToDate, "run success marks the app up to date")
        brew.upgradeStatus = 1
        await m.runUpgrade(me["Plain"]!)
        t.check(m.runResult == "The upgrade failed" && m.entries.first { $0.name == "Plain" }?.status == .available("2.0"), "run failure reported, status unchanged")
        let gone = m.entries.first { $0.name == "Gone" }!
        try? FileManager.default.removeItem(atPath: gone.path); m.dropVanished()
        t.check(!m.entries.contains { $0.id == gone.id }, "trashed app drops out of the list")
    }
}

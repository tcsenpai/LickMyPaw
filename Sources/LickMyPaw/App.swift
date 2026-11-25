import SwiftUI
import AppKit

enum Page { case home, prowl }

let spring = Animation.spring(response: 0.45, dampingFraction: 0.86)

@MainActor final class Model: ObservableObject {
    @Published var page: Page = .home
    @Published var root: Node?
    @Published var current: Node?
    @Published var checked: Set<Node> = []
    @Published var scanning = false
    @Published var scannedBytes: Int64 = 0
    @Published var scannedFiles = 0
    @Published var elapsed: Double = 0
    @Published var lastScanSeconds: Double?
    @Published var error: String?
    @Published var forward: [Node] = []
    private var progress: Progress?

    var volume: (name: String, total: Int64, free: Int64)? {
        guard let p = root?.path,
              let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let t = v.volumeTotalCapacity, let f = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (v.volumeName ?? T("Disk"), Int64(t), f)
    }

    func scan(_ path: String) {
        progress?.cancelled = true
        let p = Progress(); progress = p
        scanning = true; root = nil; current = nil; checked = []; forward = []; scannedBytes = 0; scannedFiles = 0; error = nil
        let t0 = Date()
        Task.detached(priority: .userInitiated) {
            let tree = Scanner.scan(path: path, progress: p)
            await MainActor.run { [weak self] in
                guard let self, self.progress === p, !p.cancelled else { return }
                self.root = tree; self.current = tree; self.scanning = false
                (self.scannedBytes, self.scannedFiles) = p.snapshot
                self.lastScanSeconds = Date().timeIntervalSince(t0)
            }
        }
        Task { [weak self] in
            while let self, self.scanning, self.progress === p {
                (self.scannedBytes, self.scannedFiles) = p.snapshot
                self.elapsed = Date().timeIntervalSince(t0)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func cancel() { progress?.cancelled = true; scanning = false }
    func reset() { cancel(); root = nil; current = nil; checked = []; forward = [] }

    func open(_ n: Node) { if n.isDir { current = n; checked = []; forward = [] } }
    func up() { if let c = current, let p = c.parent { forward.append(c); current = p; checked = [] } }
    func goForward() { if let n = forward.popLast() { current = n; checked = [] } }

    func toggle(_ n: Node) { if checked.contains(n) { checked.remove(n) } else if !n.isAggregate { checked.insert(n) } }
    func selectAll() { checked = Set((current?.children ?? []).filter { !$0.isAggregate }) }
    var checkedSize: Int64 { checked.reduce(0) { $0 + $1.size } }

    func reveal(_ n: Node) { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }

    func trash(_ n: Node) {
        guard !n.isAggregate else { return }
        do {
            try FileManager.default.trashItem(at: n.url, resultingItemURL: nil)
            var a = n.parent
            while let p = a { p.size -= n.size; a = p.parent }
            n.parent?.children.removeAll { $0 === n }
            checked.remove(n)
            objectWillChange.send()
        } catch { self.error = TF("Could not move %@ to the Trash: %@", n.name, error.localizedDescription) }
    }
    func trashChecked() { for n in checked { trash(n) }; checked = [] }
}

// MARK: - Look

struct Background: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1d0642), Color(hex: 0x3b0f8f), Color(hex: 0x4c12b8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: 0x8a3dff, opacity: 0.45), .clear], center: .init(x: 0.75, y: 0.55), startRadius: 0, endRadius: 520)
        }.ignoresSafeArea()
    }
}

extension View {
    func glass(_ radius: CGFloat = 22) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
    }
}

struct PinkButton: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(enabled ? 1 : 0.45))
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xFF3FA4), Color(hex: 0xD41FBF)], startPoint: .leading, endPoint: .trailing)).opacity(enabled ? 1 : 0.28))
            .scaleEffect(c.isPressed ? 0.97 : 1)
    }
}

struct SoftButton: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(c.isPressed ? 0.28 : 0.16)))
    }
}

struct GaugeRing: View {
    let fraction: Double
    @State private var shown = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 16)
            Circle().trim(from: 0, to: shown ? fraction : 0)
                .stroke(AngularGradient(colors: [Color(hex: 0xFF3FA4), Color(hex: 0x9b5cff)], center: .center), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((fraction * 100).rounded()))%").font(.system(size: 30, weight: .bold, design: .rounded))
                Text(T("used")).font(.system(size: 12, design: .rounded)).opacity(0.7)
            }.foregroundStyle(.white)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.1).delay(0.15)) { shown = true } }
    }
}

struct PulseOrb: View {
    @State private var on = false
    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 2)
                    .scaleEffect(on ? 1.5 : 0.4).opacity(on ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.6), value: on)
            }
            Circle().fill(RadialGradient(colors: [.white.opacity(0.9), Color(hex: 0x9b5cff)], center: .topLeading, startRadius: 0, endRadius: 40)).frame(width: 34, height: 34)
        }.onAppear { on = true }
    }
}

struct ModuleCard: View {
    let icon: String, title: String, text: String, active: Bool, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.system(size: 22)).frame(width: 46, height: 46)
                        .background(active ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xFF3FA4), Color(hex: 0x7a3df0)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.white.opacity(0.12)),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Spacer()
                    Text(active ? T("Open") : T("Soon")).font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Color.white.opacity(active ? 0.25 : 0.1)))
                }
                Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(text).font(.system(size: 12.5, design: .rounded)).opacity(0.7).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(active ? 1 : 0.55)).padding(18).frame(height: 150).glass(24)
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(active && hover ? 0.5 : 0), lineWidth: 1.5))
            .scaleEffect(hover && active ? 1.025 : 1).offset(y: hover && active ? -2 : 0)
        }.buttonStyle(.plain).disabled(!active)
        .onHover { hover = $0 }.animation(.spring(response: 0.3, dampingFraction: 0.75), value: hover)
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    @State private var review = false

    var stateKey: Int { m.current != nil ? 2 : (m.scanning ? 1 : 0) }

    var body: some View {
        ZStack {
            Background()
            HStack(spacing: 0) {
                sidebar
                ZStack {
                    if m.page == .home { home.transition(.opacity.combined(with: .scale(scale: 0.985))) }
                    else { prowlPage.transition(.opacity.combined(with: .scale(scale: 0.985))) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).animation(spring, value: m.page)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 620)
        .onAppear { let a = CommandLine.arguments; if let i = a.firstIndex(of: "--open"), i + 1 < a.count { m.scan(a[i + 1]) } }
        .alert(T("Error"), isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") { m.error = nil }
        } message: { Text(m.error ?? "") }
        .sheet(isPresented: $review) { reviewSheet }
    }

    // MARK: navigation

    var prowlPage: some View {
        ZStack {
            if let cur = m.current { browser(cur).transition(.opacity) }
            else if m.scanning { scanningView.transition(.opacity) }
            else { welcome.transition(.opacity) }
        }.animation(spring, value: stateKey)
    }

    var sidebar: some View {
        VStack(spacing: 10) {
            navItem("house.fill", "Home", page: .home)
            navItem("circle.hexagongrid.fill", "Prowl", page: .prowl)
            Rectangle().fill(.white.opacity(0.12)).frame(width: 28, height: 1).padding(.vertical, 4)
            ForEach(Self.future, id: \.1) { navItem($0.0, $0.1, page: nil) }
            Spacer()
        }.padding(.top, 52).frame(width: 74).background(Color.black.opacity(0.18)).ignoresSafeArea()
    }

    static let future = [("sparkles", "Purr"), ("trash.fill", "Cleanup"), ("shield.lefthalf.filled", "Protection"),
                         ("bolt.fill", "Performance"), ("square.grid.2x2.fill", "Applications")]

    func navItem(_ icon: String, _ title: String, page: Page?) -> some View {
        let on = page != nil && m.page == page
        return Button { if let p = page { m.page = p } } label: {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.white.opacity(page == nil ? 0.35 : 1))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(on ? 0.22 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(on ? 0.25 : 0)))
                .animation(spring, value: on)
        }.buttonStyle(.plain).help(page == nil ? TF("%@ — coming soon", T(title)) : T(title))
    }

    // MARK: home

    func quickScan(_ path: String) { m.page = .prowl; m.scan(path) }

    var home: some View {
        let v = diskInfo()
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(first.isEmpty ? T("Hello") : TF("Hello, %@", first)).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(T("Here's how your Mac is doing")).foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 24) {
                    GaugeRing(fraction: v.total > 0 ? Double(v.total - v.free) / Double(v.total) : 0).frame(width: 150, height: 150)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(v.name).font(.system(size: 14, weight: .medium, design: .rounded)).opacity(0.7)
                        Text(TF("%@ free", fmt(v.free))).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(TF("%@ used of %@", fmt(v.total - v.free), fmt(v.total))).opacity(0.7)
                        HStack(spacing: 10) {
                            Button(T("Analyze Home folder")) { quickScan(NSHomeDirectory()) }.buttonStyle(PinkButton())
                            Button(T("Entire disk")) { quickScan("/System/Volumes/Data") }.buttonStyle(SoftButton())
                        }.padding(.top, 6)
                    }
                    Spacer()
                }.padding(24).glass(28)
                Text(T("Tools")).font(.system(size: 18, weight: .semibold, design: .rounded)).padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                    ModuleCard(icon: "circle.hexagongrid.fill", title: "Prowl", text: T("Visual map of your storage: find and remove what weighs the most."), active: true) { m.page = .prowl }
                    ModuleCard(icon: "sparkles", title: "Purr", text: T("Quick check of cleanup, protection and performance."), active: false) {}
                    ModuleCard(icon: "trash.fill", title: T("Cleanup"), text: T("Useless caches, logs and system files."), active: false) {}
                    ModuleCard(icon: "shield.lefthalf.filled", title: T("Protection"), text: T("Scan for malware and privacy threats."), active: false) {}
                    ModuleCard(icon: "bolt.fill", title: T("Performance"), text: T("Processes, login items, maintenance."), active: false) {}
                    ModuleCard(icon: "square.grid.2x2.fill", title: T("Applications"), text: T("Uninstall and update apps."), active: false) {}
                }
            }.foregroundStyle(.white).padding(.horizontal, 30).padding(.vertical, 40)
        }
    }

    func diskInfo() -> (name: String, total: Int64, free: Int64) {
        let u = URL(fileURLWithPath: "/")
        let v = try? u.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (v?.volumeName ?? T("Disk"), Int64(v?.volumeTotalCapacity ?? 0), v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: screens

    var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 46)).foregroundStyle(.white).frame(width: 96, height: 96)
                .background(LinearGradient(colors: [Color(hex: 0xFF3FA4), Color(hex: 0x7a3df0)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            Text("Prowl").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(T("Find out what's taking up space on your disk")).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 12) {
                Button(T("Home folder")) { m.scan(NSHomeDirectory()) }.buttonStyle(PinkButton())
                Button(T("Entire disk")) { m.scan("/System/Volumes/Data") }.buttonStyle(SoftButton())
                Button(T("Choose folder…")) { pick() }.buttonStyle(SoftButton())
            }
            Text(T("To include the whole disk, grant the app «Full Disk Access» in System Settings."))
                .font(.caption).foregroundStyle(.white.opacity(0.45))
        }
    }

    var scanningView: some View {
        VStack(spacing: 14) {
            PulseOrb().frame(width: 90, height: 90)
            Text(T("Scanning…")).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            Text(TF("%@ · %@ files · %@s", fmt(m.scannedBytes), m.scannedFiles.formatted(), String(format: "%.1f", m.elapsed)))
                .monospacedDigit().foregroundStyle(.white.opacity(0.7))
            Button(T("Cancel")) { m.reset() }.buttonStyle(SoftButton())
        }
    }

    func browser(_ cur: Node) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Text("Prowl").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                HStack {
                    Button { m.reset() } label: { Label(T("Start Over"), systemImage: "chevron.left").font(.system(size: 14, weight: .semibold, design: .rounded)) }
                        .buttonStyle(.plain).foregroundStyle(.white).padding(.leading, 16)
                    Spacer()
                    Button { if let r = m.root { m.scan(r.path) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(SoftButton()).help(T("Rescan"))
                }
            }.frame(height: 32).padding(.top, 6)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) { diskCard; listCard(cur) }.frame(width: 360)
                VStack(spacing: 8) {
                    pathBar(cur)
                    BubbleView(parent: cur, checked: m.checked, onOpen: { n in withAnimation(spring) { m.open(n) } }, onToggle: { n in withAnimation(.easeOut(duration: 0.15)) { m.toggle(n) } }, onReveal: { m.reveal($0) })
                        .id(cur.id.hashValue ^ cur.children.count).transition(.opacity)
                    bottomBar
                }
            }.padding([.horizontal, .bottom], 16)
        }
    }

    var diskCard: some View {
        let v = m.volume
        let used = v.map { $0.total - $0.free } ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(v?.name ?? T("Disk")).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                if let v { Text(TF("%@ of %@ used", fmt(used), fmt(v.total))).font(.system(size: 12, design: .rounded)).opacity(0.85) }
            }
            ProgressView(value: Double(used), total: Double(max(v?.total ?? 1, 1))).tint(.white)
        }.foregroundStyle(.white).padding(16).glass()
    }

    func listCard(_ cur: Node) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: Icons.icon(cur)).resizable().scaledToFit().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cur.displayName).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(TF("%@  |  %d items", fmt(cur.size), cur.children.count)).font(.system(size: 12, design: .rounded)).opacity(0.8)
                }
            }
            Menu {
                Button(T("None")) { m.checked = [] }
                Button(T("All")) { m.selectAll() }
            } label: { Text(TF("Select: %@", m.checked.isEmpty ? T("None") : "\(m.checked.count)") + "  ⌄").font(.system(size: 13, design: .rounded)) }
                .menuStyle(.borderlessButton).fixedSize()
            ScrollView {
                LazyVStack(spacing: 2) { ForEach(cur.children) { n in row(n).transition(.opacity.combined(with: .move(edge: .leading))) } }
                    .animation(spring, value: cur.children.count)
            }
        }.foregroundStyle(.white).padding(16).glass().frame(maxHeight: .infinity)
    }

    func row(_ n: Node) -> some View {
        let on = m.checked.contains(n)
        return HStack(spacing: 10) {
            if n.isAggregate { Color.clear.frame(width: 18) } else {
                Button { withAnimation(.easeOut(duration: 0.15)) { m.toggle(n) } } label: { Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 16)).foregroundStyle(on ? Color(hex: 0xFF3FA4) : .white.opacity(0.7)).scaleEffect(on ? 1.1 : 1) }.buttonStyle(.plain)
            }
            Image(nsImage: Icons.icon(n)).resizable().scaledToFit().frame(width: 26, height: 26)
            Text(n.displayName).font(.system(size: 14, design: .rounded)).lineLimit(1)
            Spacer(minLength: 4)
            Text(fmt(n.size)).font(.system(size: 12, design: .rounded)).monospacedDigit().opacity(0.8)
        }
        .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        .background(on ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: on)
        .onTapGesture(count: 2) { if n.isDir { withAnimation(spring) { m.open(n) } } else { m.reveal(n) } }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { m.toggle(n) } }
        .contextMenu {
            if n.isDir { Button(T("Open")) { m.open(n) } }
            if !n.isAggregate {
                Button(T("Show in Finder")) { m.reveal(n) }
                Button(on ? T("Deselect") : T("Select")) { m.toggle(n) }
            }
        }
    }

    func pathBar(_ cur: Node) -> some View {
        var chain: [Node] = []; var n: Node? = cur
        while let x = n { chain.insert(x, at: 0); n = x.parent }
        return HStack(spacing: 6) {
            Button { withAnimation(spring) { m.up() } } label: { Image(systemName: "chevron.left").frame(width: 14) }.buttonStyle(SoftButton()).disabled(cur.parent == nil)
            Button { withAnimation(spring) { m.goForward() } } label: { Image(systemName: "chevron.right").frame(width: 14) }.buttonStyle(SoftButton()).disabled(m.forward.isEmpty)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(chain) { c in
                        Button { withAnimation(spring) { m.open(c) } } label: { HStack(spacing: 4) { Image(nsImage: Icons.icon(c)).resizable().frame(width: 16, height: 16); Text(c.name).font(.system(size: 13, design: .rounded)) } }
                            .buttonStyle(.plain).opacity(c === cur ? 1 : 0.7)
                        if c !== cur { Image(systemName: "chevron.right").font(.system(size: 9)).opacity(0.5) }
                    }
                }
            }
            Spacer(minLength: 0)
        }.foregroundStyle(.white).padding(.top, 2)
    }

    var bottomBar: some View {
        HStack {
            Text(m.checked.isEmpty ? T("No items selected") : TF("%d items selected", m.checked.count))
            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 16)
            Text(fmt(m.checkedSize)).monospacedDigit()
            Spacer()
            if let t = m.lastScanSeconds { Text(TF("scan %@s · %@ files", String(format: "%.1f", t), m.scannedFiles.formatted())).font(.caption).opacity(0.5) }
            Button(T("Review and Remove")) { review = true }.buttonStyle(PinkButton()).disabled(m.checked.isEmpty)
        }.font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(.white).padding(.top, 4)
    }

    var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T("Review and Remove")).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(T("These items will be moved to the Trash (recoverable):")).font(.callout).opacity(0.75)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(m.checked.sorted { $0.size > $1.size }) { n in
                        HStack(spacing: 10) {
                            Image(nsImage: Icons.icon(n)).resizable().frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(n.displayName).lineLimit(1)
                                Text(n.path).font(.caption2).opacity(0.55).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(); Text(fmt(n.size)).monospacedDigit()
                        }.padding(8).glass(12)
                    }
                }
            }.frame(maxHeight: 260)
            HStack {
                Text(TF("Total: %@", fmt(m.checkedSize))).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button(T("Cancel")) { review = false }.buttonStyle(SoftButton())
                Button(T("Move to Trash")) { m.trashChecked(); review = false }.buttonStyle(PinkButton())
            }
        }.foregroundStyle(.white).padding(22).frame(width: 520).background(Background())
    }

    func pick() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        if p.runModal() == .OK, let u = p.url { m.scan(u.path) }
    }
}

@main struct LickMyPawApp: App {
    init() {
        if CLI.runIfRequested() { exit(0) }
        if CommandLine.arguments.contains("--i18n-check") {   // headless: same keys resolved through each language bundle
            for l in ["en", "it", "fr", "es"] {
                let b = Bundle(path: Bundle.module.path(forResource: l, ofType: "lproj")!)!
                let g = { (k: String) in NSLocalizedString(k, bundle: b, comment: "") }
                print(l, "|", g("Start Over"), "|", g("Review and Remove"), "|", g("Other items"), "|", String(format: g("%d small files"), 3))
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest") { Task { @MainActor in await selfTest() }; dispatchMain() }
        let a = CommandLine.arguments   // headless GUI check: LickMyPaw --render <path> <out.png>
        if let i = a.firstIndex(of: "--render"), i + 2 < a.count {
            MainActor.assumeIsolated {
                let root = Scanner.scan(path: a[i + 1], progress: Progress())
                let v = ZStack { Background(); BubbleView(parent: root, checked: Set(root.children.prefix(1)), onOpen: { _ in }, onToggle: { _ in }, scrollable: false) }.frame(width: 900, height: 600)
                let r = ImageRenderer(content: v); r.scale = 1
                guard let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { print("render failed"); exit(1) }
                try? png.write(to: URL(fileURLWithPath: a[i + 2])); print("bubbles=\(makeBubbles(root, size: CGSize(width: 900, height: 600)).count) -> \(a[i + 2])")
            }
            exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("LickMyPaw") { ContentView().ignoresSafeArea() }.windowStyle(.hiddenTitleBar)
    }
}

/// Headless check of the interactive logic the window drives: scan -> open -> up -> select -> trash.
@MainActor func selfTest() async {
    var fails = 0
    func check(_ c: Bool, _ m: String) { print(c ? "ok   " : "FAIL ", m); if !c { fails += 1 } }
    let fm = FileManager.default
    let d = NSTemporaryDirectory() + "sl-\(getpid())"
    try? fm.createDirectory(atPath: d + "/a/sub", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: d + "/b", withIntermediateDirectories: true)
    func w(_ p: String, _ mb: Int) { fm.createFile(atPath: d + p, contents: Data(repeating: 7, count: mb << 20)) }
    w("/a/big", 2); w("/a/sub/f", 1); w("/b/c", 1)
    let m = Model(); m.scan(d)
    for _ in 0..<100 where m.scanning || m.root == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
    check(m.root != nil && m.current === m.root, "scan finishes, current = root")
    check(m.root!.size >= 4 << 20 && m.root!.size < 5 << 20, "root size ~4MB (\(fmt(m.root!.size)))")
    check(m.root!.children.first?.name == "a", "children sorted desc (a first)")
    let a = m.root!.children[0]; m.open(a)
    check(m.current === a && a.children.first?.name == "big", "open(a) drills in")
    let bs = makeBubbles(a, size: CGSize(width: 800, height: 500))
    check(bs.count == 2 && bs.allSatisfy { $0.center.x - $0.r >= -1 && $0.center.x + $0.r <= 801 && $0.center.y - $0.r >= -1 && $0.center.y + $0.r <= 501 }, "bubbles fit in view")
    let big3 = makeBubbles(m.root!, size: CGSize(width: 800, height: 500))
    check(big3.count == 2, "bubbles for root")
    let sub = a.children.first { $0.name == "sub" }!; m.open(sub); m.up()
    check(m.current === a && m.forward.last === sub, "up() returns to parent, forward stack has sub")
    m.goForward(); check(m.current === sub, "goForward() returns to sub"); m.up(); m.forward = []
    let big = a.children.first { $0.name == "big" }!; let before = m.root!.size
    m.toggle(big); check(m.checked.contains(big) && m.checkedSize == big.size, "toggle selects file")
    m.trashChecked()
    check(!fm.fileExists(atPath: d + "/a/big") && m.checked.isEmpty, "trashChecked moved file off disk")
    check(m.root!.size == before - big.size && !a.children.contains { $0 === big }, "sizes updated up the chain")
    try? fm.removeItem(atPath: d)
    print(fails == 0 ? "SELFTEST PASS" : "SELFTEST FAIL"); exit(fails == 0 ? 0 : 1)
}

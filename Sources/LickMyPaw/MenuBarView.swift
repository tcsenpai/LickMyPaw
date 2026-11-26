import SwiftUI
import AppKit
import Combine
import UserNotifications

private let S = "System"

// MARK: - Model: samples only while the popover is open (see the budget in MenuBarCore.swift)

@MainActor final class MenuBarModel: ObservableObject {
    @Published var sample: SysStats.Sample?
    weak var window: NSWindow?          // the popover's window: if it is no longer visible the timer stops itself
    private var timer: Timer?
    private var prev: SysStats.CPUTicks?
    private var disk: (free: Int64, total: Int64) = (0, 0)
    private var ticks = 0

    var isSampling: Bool { timer != nil }
    var timerInterval: TimeInterval { timer?.timeInterval ?? 0 }
    var timerTolerance: TimeInterval { timer?.tolerance ?? 0 }

    func start() {
        guard timer == nil else { return }
        if Demo.enabled { sample = Demo.menuSample; return }   // screenshots: fake numbers, no timer, no sampling
        disk = SysStats.disk() ?? (0, 0); ticks = 0
        sample = SysStats.sample(prev: &prev, disk: disk)
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() { timer?.invalidate(); timer = nil; prev = nil }
    private func tick() {
        if let w = window, !w.isVisible { stop(); return }   // safety net in case onDisappear never fires
        ticks += 1
        if ticks % 15 == 0 { disk = SysStats.disk() ?? disk }   // the expensive read: every 30 s
        sample = SysStats.sample(prev: &prev, disk: disk)
    }
}

/// Hands the hosting NSWindow to the model.
private struct WindowProbe: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { onWindow(v.window) }; return v }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - Popover

struct MenuBarView: View {
    @StateObject private var m = MenuBarModel()
    @ObservedObject private var trash = TrashModel.shared
    @ObservedObject private var update = UpdateModel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var confirm = false

    private func bar(_ f: Double, _ c: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(c).frame(width: max(4, g.size.width * min(max(f, 0), 1)))
            }
        }.frame(height: 6)
    }
    private func row(_ icon: String, _ title: String, _ detail: String, _ f: Double, _ c: Color = Color(hex: 0xFF3FA4)) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Image(systemName: icon).frame(width: 18); Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)); Spacer(); Text(detail).font(.system(size: 12, design: .rounded)).opacity(0.8) }
            bar(f, c)
        }
    }
    private func level(_ l: Int) -> (String, Color) {
        l >= 4 ? (TT("Critical", S), Color(hex: 0xFF5A5A)) : (l >= 2 ? (TT("Warning", S), Color(hex: 0xFFB84D)) : (TT("Normal", S), Color(hex: 0x6FE3A1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LickMyPaw").font(.system(size: 15, weight: .bold, design: .rounded))
            if let s = m.sample {
                row("internaldrive", TT("Disk", S), TTF("%@ free of %@", S, fmt(s.diskFree), fmt(s.diskTotal)), s.diskTotal > 0 ? 1 - Double(s.diskFree) / Double(s.diskTotal) : 0)
                let (lt, lc) = level(s.memLevel)
                row("memorychip", TT("Memory", S), TTF("%@ of %@ · %@", S, fmt(s.memUsed), fmt(s.memTotal), lt), s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0, lc)
                row("cpu", TT("CPU", S), TTF("%d%% in use", S, Int((s.cpu * 100).rounded())), s.cpu)
            }
            Divider().overlay(Color.white.opacity(0.2))
            VStack(alignment: .leading, spacing: 6) {
                if let s = trash.size { Text(s > 0 ? TTF("%@ in Trash", "Trash", fmt(s)) : TT("Trash is empty", "Trash")).font(.system(size: 12, design: .rounded)).opacity(0.85) }
                if let msg = trash.message { Text(msg).font(.caption).foregroundStyle(Color(hex: 0xFF8FC8)).fixedSize(horizontal: false, vertical: true) }
                if confirm {
                    Text(TT("Permanently delete everything in the Trash? This cannot be undone.", "Trash")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(T("Cancel")) { withAnimation(spring) { confirm = false } }.buttonStyle(SoftButton())
                        Button(TT("Empty Trash", "Trash")) { confirm = false; Task { await trash.empty() } }.buttonStyle(PinkButton())
                    }
                } else {
                    Button { withAnimation(spring) { confirm = true } } label: { SpinnerLabel(title: trash.emptying ? TT("Emptying…", "Trash") : TT("Empty Trash…", "Trash"), busy: trash.emptying) }
                        .buttonStyle(SoftButton()).disabled(trash.emptying || (trash.size ?? 0) == 0)
                }
            }
            if update.state == .available, let i = update.info {
                Button { show(page: "settings") } label: { Label(TTF("Update available: %@", S, i.tag), systemImage: "arrow.down.circle.fill") }.buttonStyle(SoftButton())
            }
            Divider().overlay(Color.white.opacity(0.2))
            HStack {
                Button(TT("Run Smart Care", S)) { show(page: "purr") }.buttonStyle(PinkButton())
                Button(TT("Open LickMyPaw", S)) { show(page: nil) }.buttonStyle(SoftButton())
            }
            Button(TT("Quit LickMyPaw", S)) { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 12, design: .rounded)).opacity(0.7)
        }
        .padding(16).frame(width: 320).foregroundStyle(.white)
        .background(Background())
        .background(WindowProbe { m.window = $0 })
        .onAppear { m.start(); Task { await trash.refresh() } }   // one Trash walk per open, never on the 2 s timer
        .onDisappear { m.stop(); confirm = false }
    }

    private func show(page: String?) {
        AppLife.showMain { openWindow(id: "main") }
        if let p = page { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Nav.go(p) } }   // the window may have just been created
    }
}

// MARK: - Notifications (UserNotifications is only ever touched in a packaged app)

enum NotifyCenter {
    static var available: Bool { Runtime.isPackagedApp }

    static func title(_ k: NotifyKind) -> String { k == .disk ? TT("Your disk is almost full", S) : TT("The Trash is getting big", S) }
    static func body(_ k: NotifyKind, bytes: Int64) -> String {
        k == .disk ? TTF("Only %@ left. Open LickMyPaw to free some space.", S, fmt(bytes)) : TTF("%@ in the Trash. Empty it to get the space back.", S, fmt(bytes))
    }

    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
    }
    private static let presenter = Presenter()

    /// Asks for permission. Called only when the user turns notifications on in Settings.
    static func requestAuth() async -> Bool {
        guard available else { return false }
        let c = UNUserNotificationCenter.current(); c.delegate = presenter
        return (try? await c.requestAuthorization(options: [.alert])) ?? false
    }
    static func send(_ k: NotifyKind, bytes: Int64) {
        guard available else { return }
        let c = UNUserNotificationCenter.current(); c.delegate = presenter
        let n = UNMutableNotificationContent(); n.title = title(k); n.body = body(k, bytes: bytes)
        c.add(UNNotificationRequest(identifier: "lickmypaw." + k.rawValue, content: n, trigger: nil))
    }
}

// MARK: - App lifecycle: Dock/menu bar behavior and the background tick

@MainActor enum AppLife {
    private static var tickTimer: Timer?
    private static var observers: [NSObjectProtocol] = []
    private static var trashSink: AnyCancellable?

    static func start() {
        // queue: nil + hop to the main actor (queue: .main can deadlock)
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { n in
                let closing = name == NSWindow.willCloseNotification ? (n.object as AnyObject?).map(ObjectIdentifier.init) : nil
                Task { @MainActor in refreshPolicy(closing: closing) }
            })
        }
        // Trash notifications are event driven: only when the Trash model refreshes for its own reasons. No scan is ever scheduled.
        trashSink = TrashModel.shared.$size.dropFirst().compactMap { $0 }.sink { size in Task { @MainActor in evaluate(trash: size) } }
        reconfigure()
        tick()
    }

    /// Menu bar on and no window left: no Dock icon, the app lives in the menu bar. Anything else: a normal app.
    static func refreshPolicy(closing: ObjectIdentifier? = nil) {
        let n = NSApp.windows.filter { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) && ObjectIdentifier($0) != closing }.count
        let want: NSApplication.ActivationPolicy = ActivationRule.policy(menuBarOn: AppPrefs.menuBar, visibleWindows: n) == .accessory ? .accessory : .regular
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    static func showMain(open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) } else { open() }
    }

    /// (Re)installs the 5 minute tick only if a feature needs it; otherwise there is no timer at all.
    static func reconfigure() {
        tickTimer?.invalidate(); tickTimer = nil
        guard Runtime.isPackagedApp, BackgroundTick.needed(cfg: AppPrefs.config, updateAuto: AppPrefs.updateAuto) else { return }
        let t = Timer(timeInterval: BackgroundTick.interval, repeats: true) { _ in Task { @MainActor in tick() } }
        t.tolerance = BackgroundTick.tolerance
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    static func tick() {
        guard Runtime.isPackagedApp else { return }
        BackgroundTick.run(cfg: AppPrefs.config, disk: SysStats.disk, now: Date(), last: AppPrefs.lastNotified, mark: AppPrefs.setLastNotified, send: { NotifyCenter.send($0, bytes: $1) })
        UpdateModel.shared.autoCheckIfDue()
    }

    private static func evaluate(trash: Int64) {
        guard Runtime.isPackagedApp, AppPrefs.notify else { return }
        Notifier.evaluate(cfg: AppPrefs.config, disk: nil, trash: trash, now: Date(), last: AppPrefs.lastNotified, mark: AppPrefs.setLastNotified, send: { NotifyCenter.send($0, bytes: $1) })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { Task { @MainActor in AppLife.start() } }
    /// Clicking the Dock icon / relaunching while only the menu bar item is alive brings the Dock presence back.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool { NSApp.setActivationPolicy(.regular); return true }
}

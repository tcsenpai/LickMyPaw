import SwiftUI
import AppKit

/// Read-only permission probes. Never prompts, never writes.
enum Permissions {
    enum Status { case granted, denied, unknown }

    /// TCC-protected paths that exist on every Mac; readable only with Full Disk Access. Injectable for tests.
    nonisolated(unsafe) static var fdaProbePaths: [String] = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari",
    ]

    /// granted: some path opened. denied: open failed with EPERM/EACCES. unknown: nothing probed conclusively (e.g. paths missing).
    static func fullDiskAccess() -> Status {
        var denied = false
        for p in fdaProbePaths {
            let fd = open(p, O_RDONLY)
            if fd >= 0 { close(fd); return .granted }
            if errno == EPERM || errno == EACCES { denied = true }
        }
        return denied ? .denied : .unknown
    }

    static let fdaPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static let dismissKey = "fdaDismissedVersion"
    static func dismissedForThisVersion(_ d: UserDefaults = .standard) -> Bool { d.string(forKey: dismissKey) == appVersion }
    static func dismiss(_ d: UserDefaults = .standard) { d.set(appVersion, forKey: dismissKey) }

    @MainActor static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

private let PT = "Permissions"

/// Shown on Home only while Full Disk Access is missing (and not dismissed for this version).
struct PermissionsBanner: View {
    @State private var status = Permissions.fullDiskAccess()
    @State private var dismissed = Permissions.dismissedForThisVersion()
    @State private var showGuide = false

    var body: some View {
        Group {
            if status != .granted && !dismissed {
                HStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 22)).foregroundStyle(Color(hex: 0xFF8AD1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(OnboardingState.needsOnboarding() ? TT("Finish setup", PT) : TT("Grant Full Disk Access to scan your whole disk", PT))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text(TT("Without it, protected folders are skipped.", PT)).font(.system(size: 12)).opacity(0.7)
                    }
                    Spacer()
                    Button(TT("Set up…", PT)) { showGuide = true }.buttonStyle(PinkButton())
                }
                .foregroundStyle(.white).padding(16).glass()
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(spring, value: dismissed)
        .animation(spring, value: status)
        .sheet(isPresented: $showGuide, onDismiss: { status = Permissions.fullDiskAccess() }) {
            FDAGuideView(onNotNow: { Permissions.dismiss(); OnboardingState.markCompleted(); dismissed = true; showGuide = false },
                         onClose: { OnboardingState.markCompleted(); showGuide = false })
        }
    }
}

struct FDAGuideView: View {
    var onNotNow: () -> Void
    var onClose: () -> Void
    @State private var status = Permissions.fullDiskAccess()
    private var granted: Bool { status == .granted }

    var body: some View {
        ZStack {
            Background()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "lock.shield.fill")
                        .font(.system(size: 34)).foregroundStyle(granted ? Color.green : Color(hex: 0xFF8AD1))
                        .scaleEffect(granted ? 1.15 : 1)
                    Text(TT("Full Disk Access", PT)).font(.system(size: 22, weight: .bold, design: .rounded))
                }
                VStack(alignment: .leading, spacing: 12) {
                    step(1, TT("Open System Settings > Privacy & Security > Full Disk Access.", PT))
                    step(2, TT("Switch on LickMyPaw in the list (use + to add it if missing).", PT))
                    step(3, TT("Come back here: this window updates by itself.", PT))
                }.padding(16).glass()
                HStack {
                    Image(systemName: granted ? "checkmark" : "hourglass").foregroundStyle(granted ? Color.green : .white.opacity(0.7))
                    Text(granted ? TT("Access granted", PT) : TT("Waiting for permission…", PT)).font(.system(size: 13, weight: .medium))
                }
                HStack {
                    Button(TT("Open System Settings", PT)) { NSWorkspace.shared.open(Permissions.fdaPane) }.buttonStyle(SoftButton())
                    Spacer()
                    if granted {
                        Button(TT("Relaunch LickMyPaw", PT)) { Permissions.relaunch() }.buttonStyle(PinkButton())
                    } else {
                        Button(TT("Not now", PT), action: onNotNow).buttonStyle(SoftButton())
                    }
                }
                if granted { Button(TT("Later", PT), action: onClose).buttonStyle(.plain).font(.system(size: 12)).opacity(0.6) }
            }
            .foregroundStyle(.white).padding(26)
        }
        .frame(width: 480, height: 400)
        .animation(spring, value: granted)
        .task {
            while !Task.isCancelled && !granted {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                status = Permissions.fullDiskAccess()
            }
        }
    }

    private func step(_ n: Int, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded)).frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.18)))
            Text(s).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum PermissionsSelfTest {
    @MainActor static func run(_ t: TestCtx) async {
        let saved = Permissions.fdaProbePaths
        defer { Permissions.fdaProbePaths = saved }
        let tmp = NSTemporaryDirectory() + "lmp-perm-\(getpid())"
        FileManager.default.createFile(atPath: tmp, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        Permissions.fdaProbePaths = [tmp]; t.reachedCode()
        t.check(Permissions.fullDiskAccess() == .granted, "readable fixture -> granted")
        Permissions.fdaProbePaths = [tmp + ".nope"]
        t.check(Permissions.fullDiskAccess() == .unknown, "nonexistent -> unknown")
        chmod(tmp, 0)
        Permissions.fdaProbePaths = [tmp]
        t.check(geteuid() == 0 || Permissions.fullDiskAccess() == .denied, "unreadable -> denied")
        Permissions.fdaProbePaths = [tmp + ".nope", tmp]
        t.check(geteuid() == 0 || Permissions.fullDiskAccess() == .denied, "missing + unreadable -> denied")
        Permissions.fdaProbePaths = []
        t.check(Permissions.fullDiskAccess() == .unknown, "no paths -> unknown")

        var s = OnboardingState(); t.reachedCode()
        t.check(s.step == .welcome, "starts at welcome")
        s.next(); t.check(s.step == .permissions, "welcome -> permissions")
        s.next(); t.check(s.isDone, "permissions -> done")
        s.next(); t.check(s.isDone, "done is terminal")
        var k = OnboardingState(); k.skip(); t.check(k.isDone, "skip -> done")
        t.check(OnboardingState.needsOnboarding(stored: 0, current: 1), "stored 0 < 1 needs")
        t.check(!OnboardingState.needsOnboarding(stored: 1, current: 1), "stored == current no")
        t.check(OnboardingState.needsOnboarding(stored: 1, current: 2), "version bump needs again")

        let d = UserDefaults.standard
        let o1 = d.object(forKey: OnboardingState.key), o2 = d.object(forKey: Permissions.dismissKey)
        defer { d.set(o1, forKey: OnboardingState.key); d.set(o2, forKey: Permissions.dismissKey) }
        d.removeObject(forKey: OnboardingState.key); d.removeObject(forKey: Permissions.dismissKey)
        t.check(OnboardingState.needsOnboarding(d), "fresh defaults need onboarding")
        OnboardingState.markCompleted(d)
        t.check(!OnboardingState.needsOnboarding(d), "persisted completion")
        t.check(!Permissions.dismissedForThisVersion(d), "not dismissed initially")
        Permissions.dismiss(d)
        t.check(Permissions.dismissedForThisVersion(d), "dismiss remembered for version")
        d.set("0.0.0-old", forKey: Permissions.dismissKey)
        t.check(!Permissions.dismissedForThisVersion(d), "dismissal expires on new version")

        var sets: [String: Set<String>] = [:]
        for l in ["en", "it", "fr", "es"] {
            guard let p = L10n.resourceBundle.path(forResource: "Permissions", ofType: "strings", inDirectory: nil, forLocalization: l),
                  let dict = NSDictionary(contentsOfFile: p) as? [String: String] else { t.check(false, "load \(l) Permissions.strings"); continue }
            sets[l] = Set(dict.keys); t.reachedCode()
        }
        t.check(sets.count == 4 && Set(sets.values).count == 1 && !(sets["en"]?.isEmpty ?? true), "Permissions.strings same keys in en/it/fr/es")
    }
}

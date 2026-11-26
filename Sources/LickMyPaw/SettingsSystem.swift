import SwiftUI
import AppKit
import ServiceManagement

private let S = "System"

/// The glass card used by Settings (SettingsView.card forwards here so these sections look identical).
struct SettingsCard<C: View>: View {
    let title: String
    @ViewBuilder let content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).glass(22)
    }
}

private func hint(_ s: String) -> some View { Text(s).font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true) }

/// Settings sections: menu bar, launch at login, notifications, updates.
struct SystemSettingsView: View {
    @AppStorage("menubar.enabled") private var menuBar = true
    @AppStorage("notify.enabled") private var notify = false
    @AppStorage("notify.diskPercent") private var diskPercent = 10.0
    @AppStorage("notify.diskGB") private var diskGB = 10.0
    @AppStorage("notify.trashGB") private var trashGB = 5.0
    @AppStorage("update.auto") private var auto = true
    @State private var login = LoginState.off
    @State private var note: String?
    @ObservedObject private var up = UpdateModel.shared

    private var loginBinding: Binding<Bool> {
        Binding(get: { login.toggleOn }, set: { on in
            if let e = LoginItem.set(on) { note = TTF("Could not change the login item: %@", S, e) } else { note = nil }
            login = LoginItem.state
        })
    }
    private var notifyBinding: Binding<Bool> {
        Binding(get: { notify }, set: { on in
            guard on else { notify = false; AppLife.reconfigure(); return }
            Task {   // permission is asked only now, when the user turns the feature on
                let ok = await NotifyCenter.requestAuth()
                notify = ok; note = ok ? nil : TT("Notifications are not allowed for LickMyPaw. Enable them in System Settings → Notifications.", S)
                AppLife.reconfigure()
            }
        })
    }
    private var loginText: String {
        switch login {
        case .on: return TT("LickMyPaw starts when you log in.", S)
        case .needsApproval: return TT("Waiting for your approval in System Settings → General → Login Items.", S)
        case .notFound: return TT("Launch at login is only available from the installed app.", S)
        case .off: return TT("LickMyPaw does not start at login.", S)
        }
    }

    var body: some View {
        Group {
            SettingsCard(title: TT("Menu bar", S)) {
                Toggle(TT("Show LickMyPaw in the menu bar", S), isOn: $menuBar)
                    .onChange(of: menuBar) { _ in AppLife.refreshPolicy() }
                hint(TT("Disk, memory, CPU and Trash at a glance. It only measures while the menu is open.", S))
                Toggle(TT("Launch at login", S), isOn: loginBinding).disabled(login == .notFound)
                hint(loginText)
                if login == .needsApproval { Button(TT("Open Login Items settings", S)) { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(SoftButton()) }
                if let note { hint(note) }
            }
            SettingsCard(title: TT("Notifications", S)) {
                Toggle(TT("Notify me about disk space and the Trash", S), isOn: notifyBinding)
                hint(TT("At most one notification a day for each. Only the free space is checked in the background, every few minutes.", S))
                if notify {
                    Stepper(value: $diskPercent, in: 1...50, step: 1) { Text(TTF("Disk below %d%% free", S, Int(diskPercent))) }
                    Stepper(value: $diskGB, in: 1...500, step: 1) { Text(TTF("or below %d GB free", S, Int(diskGB))) }
                    Stepper(value: $trashGB, in: 0...200, step: 1) { Text(trashGB == 0 ? TT("Trash size: never notify", S) : TTF("Trash larger than %d GB", S, Int(trashGB))) }
                }
            }
            SettingsCard(title: TT("Updates", S)) {
                HStack(spacing: 12) {
                    Button { Task { await up.check() } } label: { SpinnerLabel(title: TT("Check for updates", S), busy: up.state == .checking) }
                        .buttonStyle(PinkButton()).disabled(up.state == .checking || up.state == .downloading)
                    UpdateStatusLine()
                }
                Toggle(TT("Check automatically once a day", S), isOn: $auto).onChange(of: auto) { _ in AppLife.reconfigure() }
                hint(TT("This is the only network request LickMyPaw makes by itself: it asks GitHub for the latest release. Nothing identifies you.", S))
            }
        }
        .onAppear { login = Runtime.isPackagedApp ? LoginItem.state : .notFound }
    }
}

/// One line for the current update state, with the install button when something is available.
struct UpdateStatusLine: View {
    @ObservedObject private var up = UpdateModel.shared
    @State private var sheet = false
    var body: some View {
        HStack(spacing: 10) {
            switch up.state {
            case .idle, .checking: EmptyView()
            case .upToDate: Text(TTF("You are up to date (%@).", S, up.latest?.text ?? "")).opacity(0.8)
            case .available:
                if let i = up.info { Text(TTF("Version %@ is available.", S, i.tag)); Button(TT("What's new", S)) { sheet = true }.buttonStyle(SoftButton()) }
            case .downloading: ProgressView().controlSize(.small).tint(.white); Text(TT("Downloading and verifying…", S)).opacity(0.8)
            case .revealed: Text(TT("The new version is in Finder. Drag it to Applications to finish.", S)).opacity(0.8)
            case .failed(let m): Text(TTF("Update problem: %@", S, m)).foregroundStyle(Color(hex: 0xFF8FC8))
            }
        }.font(.system(size: 12, design: .rounded)).sheet(isPresented: $sheet) { UpdateSheet(close: { sheet = false }) }
    }
}

struct UpdateSheet: View {
    @ObservedObject private var up = UpdateModel.shared
    let close: () -> Void
    private var notes: AttributedString {
        let raw = up.info?.notes ?? ""
        return (try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(raw)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TTF("LickMyPaw %@ is available", S, up.info?.tag ?? "")).font(.system(size: 17, weight: .bold, design: .rounded))
            ScrollView { Text(notes.characters.isEmpty ? AttributedString(TT("No release notes.", S)) : notes).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 200).padding(10).glass(14)
            hint(TT("The download is checked against the published SHA-256 before anything is replaced. LickMyPaw quits, swaps itself and starts again.", S))
            HStack {
                Spacer()
                Button(TT("Later", S)) { close() }.buttonStyle(SoftButton())
                Button(TT("Download and install", S)) { close(); Task { await up.install() } }.buttonStyle(PinkButton()).disabled(up.state == .downloading)
            }
        }.padding(22).frame(width: 480).foregroundStyle(.white).background(Background())
    }
}

/// A slim banner at the top of the window when an update was found.
private struct UpdateBannerModifier: ViewModifier {
    @ObservedObject private var up = UpdateModel.shared
    @State private var sheet = false
    @AppStorage("update.dismissedTag") private var dismissed = ""   // remembered, so a closed banner stays closed for that version
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if up.state == .available, let i = up.info, dismissed != i.tag {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(TTF("LickMyPaw %@ is available", S, i.tag)).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Button(TT("What's new", S)) { sheet = true }.buttonStyle(SoftButton())
                    Button { withAnimation(spring) { dismissed = i.tag } } label: { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }.buttonStyle(.plain).opacity(0.8)
                }.foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 8).background(Capsule().fill(Color(hex: 0xD41FBF))).padding(.top, 10).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(spring, value: up.state)
        .sheet(isPresented: $sheet) { UpdateSheet(close: { sheet = false }) }
    }
}
extension View { func updateBanner() -> some View { modifier(UpdateBannerModifier()) } }

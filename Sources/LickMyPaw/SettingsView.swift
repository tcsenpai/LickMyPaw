import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var lang = Prefs.languageOverride ?? ""
    @State private var excl = Prefs.exclusions
    @State private var history = ActionLog.all().reversed() as [ActionEntry]
    @State private var note: String?
    @State private var err: String?
    private let langs: [(String, String)] = [("", ""), ("en", "English"), ("it", "Italiano"), ("fr", "Français"), ("es", "Español")]
    private let S = "Settings"

    private func card<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
            c()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).glass(22)
    }
    private func reload() { withAnimation(spring) { excl = Prefs.exclusions; history = ActionLog.all().reversed() } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                card(TT("Language", S)) {
                    Picker("", selection: $lang) {
                        ForEach(langs, id: \.0) { Text($0.0.isEmpty ? TT("System default", S) : $0.1).tag($0.0) }
                    }.labelsHidden().frame(width: 200)
                    .onChange(of: lang) { v in Prefs.languageOverride = v.isEmpty ? nil : v; withAnimation(spring) { note = TT("Restart LickMyPaw to apply the language.", S) } }
                    if let note { Text(note).font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.7)).transition(.opacity) }
                }
                card(TT("Exclusions", S)) {
                    Text(TT("Folders LickMyPaw will never touch or delete.", S)).font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                    if excl.isEmpty { Text(TT("No excluded folders.", S)).foregroundStyle(.white.opacity(0.5)) }
                    ForEach(excl, id: \.self) { p in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.white.opacity(0.7))
                            Text(p).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(TT("Remove", S)) { Prefs.removeExclusion(p); reload() }.buttonStyle(SoftButton())
                        }.padding(8).glass(12)
                    }
                    Button(TT("Add folder…", S)) {
                        let o = NSOpenPanel(); o.canChooseDirectories = true; o.canChooseFiles = false; o.allowsMultipleSelection = false
                        guard o.runModal() == .OK, let u = o.url else { return }
                        if let why = Prefs.addExclusion(u.path) { err = TTF("Cannot exclude this folder: %@", S, TT(why, S)) }
                        reload()
                    }.buttonStyle(PinkButton())
                }
                card(TT("History", S)) {
                    if history.isEmpty { Text(TT("No actions yet.", S)).foregroundStyle(.white.opacity(0.5)) }
                    ForEach(history) { e in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((e.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(Date(timeIntervalSince1970: e.ts).formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer()
                            Text(fmt(e.size)).foregroundStyle(.white.opacity(0.8))
                            Text(e.undone ? TT("Restored", S) : TT("Moved to Trash", S)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                            Button(TT("Undo", S)) {
                                do { try Engine.undo(e) } catch { self.err = error.localizedDescription }
                                reload()
                            }.buttonStyle(SoftButton()).disabled(e.undone)
                        }.padding(8).glass(12)
                    }
                }
                card(TT("About", S)) {
                    Text("LickMyPaw").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(TTF("Version %@", S, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                    Text(TT("Open source – MIT", S))
                    Text(TT("Icon: Black Cat Paw by lesnivila (CC0)", S)).foregroundStyle(.white.opacity(0.7))
                }
            }.padding(24)
        }
        .font(.system(size: 13, design: .rounded)).foregroundStyle(.white)
        .alert(TT("Something went wrong", S), isPresented: Binding(get: { err != nil }, set: { if !$0 { err = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(err ?? "") }
    }
}

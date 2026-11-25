import SwiftUI

/// Performance page = tabs. Each tab is owned by its module file (StartupView.swift, ProcessesView.swift).
struct PerformanceView: View {
    enum Tab: String, CaseIterable { case startup = "Startup", processes = "Processes" }
    @State private var tab: Tab = Demo.perfProcesses ? .processes : .startup
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button(T(t.rawValue)) { withAnimation(spring) { tab = t } }
                        .buttonStyle(SoftButton()).opacity(tab == t ? 1 : 0.55)
                }
                Spacer()
            }.padding([.horizontal, .top], 20)
            Group { if tab == .startup { StartupView() } else { ProcessesView() } }
                .transition(.opacity)
        }.foregroundStyle(.white)
    }
}

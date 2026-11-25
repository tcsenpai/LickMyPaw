import SwiftUI

/// STUB (plan 12 login items / launch agents). Owner replaces this file (may add Startup*.swift).
struct StartupView: View {
    var body: some View { Text(T("Startup")).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
enum StartupSelfTest { @MainActor static func run(_ t: TestCtx) async { /* TODO */ } }

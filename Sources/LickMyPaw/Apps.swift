import SwiftUI

/// STUB (T94/T95/T96). Replace with AppInventory + leftover matcher + uninstall flow + view.
struct AppsView: View {
    var body: some View { Text(T("Applications")).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

enum AppsSelfTest { @MainActor static func run(_ t: TestCtx) async { /* TODO */ } }

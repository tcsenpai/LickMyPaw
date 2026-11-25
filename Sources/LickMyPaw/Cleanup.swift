import SwiftUI

/// STUB (T39/T40/T41/T46). Replace with the Cleanup module (targets, exclusions, view, clean flow via Engine.trash(mode: .automatic)).
struct CleanupView: View {
    var body: some View { Text(T("Cleanup")).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

enum CleanupSelfTest { @MainActor static func run(_ t: TestCtx) async { /* TODO */ } }

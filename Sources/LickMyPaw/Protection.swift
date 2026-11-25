import SwiftUI

/// STUB (Protection: ClamAV engine integration + native security checks). Owner replaces this file (may add Protection*.swift).
struct ProtectionView: View {
    var body: some View { Text(T("Protection")).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
enum ProtectionSelfTest { @MainActor static func run(_ t: TestCtx) async { /* TODO */ } }

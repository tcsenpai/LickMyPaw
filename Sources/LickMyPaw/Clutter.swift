import SwiftUI

/// STUB (large & old files + duplicates; plans 07 and 08). The owner replaces this file (and may add Clutter*.swift).
/// ClutterView = tabs 'Large & Old' / 'Duplicates'.
struct ClutterView: View {
    var body: some View { Text(T("Clutter")).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
enum ClutterSelfTest { @MainActor static func run(_ t: TestCtx) async { /* TODO */ } }

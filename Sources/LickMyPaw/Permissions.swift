import SwiftUI

/// STUB (T21/T132/T133). Contract: PermissionsBanner shows on Home when Full Disk Access is missing; EmptyView otherwise.
struct PermissionsBanner: View { var body: some View { EmptyView() } }

enum PermissionsSelfTest { @MainActor static func run(_ t: TestCtx) async { /* TODO */ } }

// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native iPhone workspace.

import SwiftUI

struct RootView: View {
    @State private var chat = ChatModel.shared

    var body: some View {
        NativeShell()
            // WebKit's worker must remain attached while the native host is
            // running. The engine is created against this one-point anchor;
            // SwiftUI keeps it in the hierarchy for the host lifetime.
            .overlay(alignment: .bottomTrailing) {
                VisibleAnchorView(anchor: chat.anchor)
                    .frame(width: 2, height: 2)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
    }
}

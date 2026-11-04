// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native iPhone workspace.

import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var chat = ChatModel.shared

    var body: some View {
        NativeShell()
            // HomeSpec is monochrome: links, toggles, prominent buttons and
            // alert actions take the primary ink instead of system blue.
            .tint(HomeSpec.textPrimary)
            // WebKit's worker must remain attached while the native host is
            // running. The engine is created against this one-point anchor;
            // SwiftUI keeps it in the hierarchy for the host lifetime.
            .overlay(alignment: .bottomTrailing) {
                VisibleAnchorView(anchor: chat.anchor)
                    .frame(width: 2, height: 2)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .onChange(of: scenePhase) { _, newPhase in
                Task { await chat.scenePhaseChanged(newPhase) }
            }
    }
}

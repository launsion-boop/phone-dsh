// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native iPhone workspace.

import SwiftUI

struct RootView: View {
    #if DEBUG
    @State private var preview = PreviewScreen.requested.flatMap { $0.isAppShellPreview ? nil : $0 }
    #endif

    var body: some View {
        Group {
            if AppShellMode.current == .v4 {
                AppShell()
            } else {
                LegacyRootView()
            }
        }
        #if DEBUG
        .fullScreenCover(item: $preview) { screen in
            NavigationStack { screen.body }
        }
        #endif
    }
}

private struct LegacyRootView: View {
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
    }
}

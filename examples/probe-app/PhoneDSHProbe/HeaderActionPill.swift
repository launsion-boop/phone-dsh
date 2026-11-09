// SPDX-License-Identifier: MIT

import SwiftUI

/// The 92×44 floating header capsule shared by the DSH session page and the
/// Bot page: the device-connections button on the leading side and the “…”

/// menu on the trailing side. Both pages pass their own accessibility ids and
/// menu contents; the visual values stay exactly the same.
struct HeaderActionPill<MenuContent: View>: View {
    var hasOnlineDevices: Bool
    /// False on a PC workspace: the paired computer owns the sessions, and
    /// phone device connections stay a phone-only affordance (D2).
    var showsConnect: Bool = true
    var connectIdentifier: String?
    var menuIdentifier: String?
    var showsMenuActivityDot: Bool
    var onConnect: () -> Void
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 0) {
            if showsConnect {
                Button {
                    onConnect()
                } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 46, height: HomeSpec.navButton)
                    .overlay(alignment: .topTrailing) {
                        // A device is online: a 6pt success dot on the icon.
                        if hasOnlineDevices {
                            Circle()
                                .fill(HomeSpec.success)
                                .frame(width: 6, height: 6)
                                .offset(x: -10, y: 11)
                        }
                    }
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel(hasOnlineDevices ? "连接设备，有在线设备" : "连接设备")
                .modifier(HeaderOptionalAccessibilityIdentifier(identifier: connectIdentifier))
            }
            menuButton
        }
        .foregroundStyle(HomeSpec.primaryButton)
        .frame(width: HomeSpec.navPillWidth, height: HomeSpec.navButton)
        .background(HomeSpec.surface, in: Capsule())
        .homeFloatingShadow()
    }

    private var menuButton: some View {
        Menu {
            menu()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 46, height: HomeSpec.navButton)
                    .contentShape(Rectangle())
                if showsMenuActivityDot {
                    Circle()
                        .fill(HomeSpec.textSecondary)
                        .frame(width: 6, height: 6)
                        .offset(x: -10, y: 11)
                }
            }
            .accessibilityLabel("更多")
        }
        .modifier(HeaderOptionalAccessibilityIdentifier(identifier: menuIdentifier))
    }
}

private struct HeaderOptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

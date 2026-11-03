// SPDX-License-Identifier: MIT

import SwiftUI

struct AppDock: View {
    let selection: AppTab
    let badges: [AppTab: Int]
    let onSelect: (AppTab) -> Void

    @ScaledMetric(relativeTo: .caption2) private var labelSize = HomeSpec.tabLabelSize

    var body: some View {
        HStack(spacing: AppDockMetrics.groupSpacing) {
            Button { onSelect(.chat) } label: {
                PhoneDSHLogo(size: AppDockMetrics.logoSize)
                    .clipShape(Circle())
                    .frame(width: AppDockMetrics.height, height: AppDockMetrics.height)
                    .background(selection == .chat ? HomeSpec.userBubble : HomeSpec.surface, in: Circle())
                    .overlay(Circle().strokeBorder(
                        selection == .chat ? HomeSpec.textPrimary : HomeSpec.borderList,
                        lineWidth: selection == .chat ? 1.5 : 0.75))
                    .overlay(alignment: .topTrailing) {
                        badgeDot(for: .chat)
                            .offset(x: -2, y: 2)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(AppDockButtonStyle())
            .accessibilityLabel(AppTab.chat.title)
            .accessibilityValue(accessibilityValue(for: .chat))
            .accessibilityAddTraits(selection == .chat ? .isSelected : [])
            .accessibilityIdentifier(AppTab.chat.accessibilityIdentifier)

            HStack(spacing: 2) {
                ForEach([AppTab.dsh, .discover, .profile]) { tab in
                    dockButton(tab)
                }
            }
            .padding(AppDockMetrics.groupPadding)
            .frame(maxWidth: .infinity)
            .background(HomeSpec.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(HomeSpec.borderList, lineWidth: 0.75))
        }
        .padding(.horizontal, AppDockMetrics.horizontalInset)
        .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.dock")
    }

    private func dockButton(_ tab: AppTab) -> some View {
        Button { onSelect(tab) } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: AppDockMetrics.iconSize,
                                  weight: selection == tab ? .medium : .regular))
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .topTrailing) { dockBadge(tab) }
                Text(tab.title)
                    .font(.system(size: min(labelSize, AppDockMetrics.maximumLabelSize),
                                  weight: selection == tab ? .medium : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(selection == tab ? HomeSpec.textPrimary : HomeSpec.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: AppDockMetrics.itemHeight)
            .background(selection == tab ? HomeSpec.userBubble : Color.clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(AppDockButtonStyle())
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue(for: tab))
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }

    @ViewBuilder
    private func dockBadge(_ tab: AppTab) -> some View {
        if tab == .dsh, let count = badges[tab], count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(AppDockMetrics.attentionInk)
                .padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 18)
                .background(AppDockMetrics.attention, in: Capsule())
                .overlay(Capsule().strokeBorder(HomeSpec.surface, lineWidth: 1.5))
                .offset(x: 12, y: -7)
                .accessibilityHidden(true)
        } else {
            badgeDot(for: tab)
                .offset(x: 7, y: -3)
        }
    }

    @ViewBuilder
    private func badgeDot(for tab: AppTab) -> some View {
        if tab != .dsh, let count = badges[tab], count > 0 {
            Circle()
                .fill(AppDockMetrics.attention)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(HomeSpec.surface, lineWidth: 2))
                .accessibilityHidden(true)
        }
    }

    private func accessibilityValue(for tab: AppTab) -> String {
        var values: [String] = []
        if selection == tab {
            values.append(NativeText("已选中", "Selected"))
        }
        let count = badges[tab] ?? 0
        if count > 0 {
            if tab == .dsh {
                values.append(String(format: NativeText("%d 项需要处理", "%d items need attention"), count))
            } else {
                values.append(NativeText("有需要处理的事项", "Needs attention"))
            }
        }
        return values.joined(separator: NativeText("，", ", "))
    }
}

private struct AppDockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    AppDock(selection: .chat, badges: [.dsh: 2, .discover: 1]) { _ in }
        .padding(.vertical, 20)
        .background(HomeSpec.page)
}

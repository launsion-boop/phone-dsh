// SPDX-License-Identifier: MIT

import SwiftUI

struct AppDock: View {
    let selection: AppTab
    let badges: [AppTab: Int]
    let onSelect: (AppTab) -> Void

    var body: some View {
        HStack(spacing: AppDockMetrics.groupSpacing) {
            Button { onSelect(.chat) } label: {
                Image(systemName: AppTab.chat.systemImage)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(selection == .chat ? HomeSpec.primaryButtonInk : HomeSpec.textPrimary)
                    .frame(width: AppDockMetrics.height, height: AppDockMetrics.height)
                    .background(selection == .chat ? HomeSpec.primaryButton : HomeSpec.surface, in: Circle())
                    .overlay(Circle().strokeBorder(HomeSpec.textPrimary, lineWidth: selection == .chat ? 2 : 0))
                    .overlay(alignment: .topTrailing) { badgeDot(for: .chat) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppTab.chat.title)
            .accessibilityValue(accessibilityValue(for: .chat))
            .accessibilityAddTraits(selection == .chat ? .isSelected : [])
            .accessibilityIdentifier(AppTab.chat.accessibilityIdentifier)

            HStack(spacing: 0) {
                ForEach([AppTab.dsh, .discover, .profile]) { tab in
                    dockButton(tab)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .frame(height: AppDockMetrics.height)
            .background(HomeSpec.surface, in: Capsule())
        }
        .padding(.horizontal, AppDockMetrics.horizontalInset)
        .homeFloatingShadow()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.dock")
    }

    private func dockButton(_ tab: AppTab) -> some View {
        Button { onSelect(tab) } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 19, weight: selection == tab ? .semibold : .regular))
                    .overlay(alignment: .topTrailing) { dockBadge(tab) }
                Text(tab.title)
                    .font(.system(size: HomeSpec.tabLabelSize, weight: selection == tab ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(HomeSpec.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(selection == tab ? HomeSpec.userBubble : Color.clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(HomeSpec.textPrimary, lineWidth: selection == tab ? 1.5 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue(for: tab))
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }

    @ViewBuilder
    private func dockBadge(_ tab: AppTab) -> some View {
        if tab == .dsh, let count = badges[tab], count > 0 {
            Text("\(min(count, 99))")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(HomeSpec.primaryButtonInk)
                .frame(minWidth: 18, minHeight: 18)
                .background(HomeSpec.primaryButton, in: Capsule())
                .offset(x: 14, y: -8)
        } else {
            badgeDot(for: tab)
                .offset(x: 8, y: -3)
        }
    }

    @ViewBuilder
    private func badgeDot(for tab: AppTab) -> some View {
        if tab != .dsh, let count = badges[tab], count > 0 {
            Circle()
                .fill(HomeSpec.primaryButton)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(HomeSpec.surface, lineWidth: 2))
                .accessibilityHidden(true)
        }
    }

    private func accessibilityValue(for tab: AppTab) -> String {
        let count = badges[tab] ?? 0
        guard count > 0 else { return selection == tab ? NativeText("已选中", "Selected") : "" }
        if tab == .dsh {
            return String(format: NativeText("%d 项需要处理", "%d items need attention"), count)
        }
        return NativeText("有需要处理的事项", "Needs attention")
    }
}

#Preview {
    AppDock(selection: .chat, badges: [.dsh: 2, .discover: 1]) { _ in }
        .padding(.vertical, 20)
        .background(HomeSpec.page)
}

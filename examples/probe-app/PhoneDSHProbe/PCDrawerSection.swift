// SPDX-License-Identifier: MIT
// Drawer pieces for the two workspaces (D2): the 手机 | PC segment above the
// 新会话 capsule and the PC-only empty states (unpaired / offline / long
// offline). Styling follows HomeSpec: 16pt chrome inset, white surface, 1A1A1A
// ink, capsule geometry.

import PhoneDSHPCLink
import ProbeKit
import SwiftUI
import UIKit

/// The PC list region's empty/offline state. `onPair` opens `PCPairingPage`.
struct PCDrawerStateView: View {
    @Environment(\.workspaceModels) private var models
    var onPair: () -> Void

    var body: some View {
        switch models.drawerPhase {
        case .phone:
            EmptyView()
        case .pair:
            VStack(spacing: 14) {
                stateCard(
                    title: "连接电脑",
                    message: "配对后，这台手机可以在电脑上继续会话：同样的界面，数据来自电脑上的 DSH。",
                    primaryTitle: "连接电脑",
                    primaryAction: onPair)
                VStack(alignment: .leading, spacing: 8) {
                    Text(PCLinkInstallGuide.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                    PCPluginInstallGuide()
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
        case .offline:
            VStack(spacing: 10) {
                stateCard(
                    title: "电脑离线",
                    message: PCLinkWorkspaceText.offlineReason(offlineReason),
                    primaryTitle: "重试",
                    primaryAction: { Task { await models.pcLink.retry() } })
                if models.pcLink.longOffline {
                    Text(PCLinkWorkspaceText.longOffline)
                        .font(.system(size: 13))
                        .foregroundStyle(HomeSpec.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                    Text("可在 我的 › 已连接的电脑 里手动解除配对。")
                        .font(.system(size: 12))
                        .foregroundStyle(HomeSpec.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
        case .ready:
            EmptyView()
        }
    }

    private var offlineReason: PCLinkOfflineReason {
        if case .offline(let reason) = models.pcLink.connection { return reason }
        return .notStarted
    }

    private func stateCard(title: String, message: String,
                           primaryTitle: String, primaryAction: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(HomeSpec.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(HomeSpec.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(primaryTitle, action: primaryAction)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(HomeSpec.primaryButtonInk)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(HomeSpec.primaryButton, in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(20)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        .padding(.horizontal, 8)
    }
}

/// A compact always-on header strip when the PC's DSH version is outside the
/// tested range (warning only, never a block — plan v2 §5).
struct PCVersionWarningBar: View {
    let warning: PCLinkVersionWarning

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NativePagePalette.warning)
            Text(warning.message)
                .font(.system(size: 12))
                .foregroundStyle(HomeSpec.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(NativePagePalette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// The DSH tab's content while the PC segment has no pairing record. It keeps
/// the same header geometry so switching segments does not jump, and offers
/// only the pairing entry (never the phone conversation).
struct PCWorkspaceChatPlaceholder: View {
    @Environment(\.workspaceModels) private var models
    var openDrawer: () -> Void
    var drawerExpanded: Bool = false
    @State private var showPairing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: openDrawer) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(HomeSpec.primaryButton)
                        .frame(width: 44, height: 44)
                        .background(HomeSpec.surface, in: Circle())
                        .homeFloatingShadow()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("会话列表")
                VStack(alignment: .leading, spacing: 1) {
                    Text("PC 工作区")
                        .font(.system(size: HomeSpec.navTitleSize, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                    Text(models.pcLink.peerName.isEmpty ? "未配对" : models.pcLink.peerName)
                        .font(.system(size: HomeSpec.navSubtitleSize))
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HomeSpec.chromeInset)
            .padding(.top, HomeSpec.navTop)
            .frame(height: HomeSpec.navTop + HomeSpec.navButton)

            Spacer(minLength: 0)
            if !models.isPhoneSelected {
                PCDrawerStateView(onPair: { showPairing = true })
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 12)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HomeSpec.page)
        .sheet(isPresented: $showPairing) {
            NavigationStack { PCPairingPage() }
        }
    }
}

/// Settings pages for MCP/model/Agent presets are phone-owned in v1. When the
/// drawer is on the PC segment they still edit the phone, so the page header
/// says so (plan v2 §6.1). A safe-area inset keeps it out of the List's rows
/// and therefore out of the page-structure contract.
struct PhoneOwnedSettingsNotice: View {
    @Environment(\.workspaceModels) private var models

    var body: some View {
        if !models.isPhoneSelected {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.system(size: 12, weight: .semibold))
                Text("这些设置属于手机。PC 工作区的 MCP、模型和 Agent 预设由电脑上的 DSH 管理。")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(HomeSpec.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(HomeSpec.userBubble.opacity(0.6))
        }
    }
}

private struct PhoneOwnedSettingsNoticeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            PhoneOwnedSettingsNotice()
        }
    }
}

extension View {
    func phoneOwnedSettingsNotice() -> some View {
        modifier(PhoneOwnedSettingsNoticeModifier())
    }
}


// MARK: - Install guide (pclink-pacing)

/// The single copy-paste install/pairing guide shown in the PC unpaired empty
/// state and the pairing page. The strings live in `PCLinkInstallGuide`
/// (ProbeKit) next to the relay origin configuration, not in this view.
struct PCPluginInstallGuide: View {
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PCLinkInstallGuide.requirement)
                .font(.system(size: 13))
                .foregroundStyle(HomeSpec.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            commandRow(PCLinkInstallGuide.installCommand, label: "安装插件")
            Text(PCLinkInstallGuide.restartHint)
                .font(.system(size: 12))
                .foregroundStyle(HomeSpec.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            commandRow(PCLinkInstallGuide.pairingCommand, label: "运行配对")
        }
        .padding(12)
        .background(HomeSpec.userBubble.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
    }

    private func commandRow(_ command: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    UIPasteboard.general.string = command
                    copied = command
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if copied == command { copied = nil }
                    }
                } label: {
                    Image(systemName: copied == command ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(copied == command ? NativePagePalette.success : HomeSpec.textSecondary)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied == command ? "\(label)命令已复制" : "复制\(label)命令")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HomeSpec.surface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

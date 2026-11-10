// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native iPhone workspace.

import PhoneDSHPCLink
import ProbeKit
import SwiftUI

struct RootView: View {
    @State private var chat = ChatModel.shared
    @Environment(\.workspaceModels) private var models

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
            .overlay(alignment: .top) {
                if let notice = models.pcLink.notice {
                    pairingNotice(notice)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .alert("电脑已解除与此手机的配对",
                   isPresented: Binding(
                    get: { models.pcLink.unpairedPrompt != nil },
                    set: { if !$0 { models.pcLink.keepLocalRecordDespiteUnpaired() } })) {
                Button("保留本机记录", role: .cancel) {
                    models.pcLink.keepLocalRecordDespiteUnpaired()
                }
                Button("解除并删除记录", role: .destructive) {
                    Task { try? await models.pcLink.acknowledgePCUnpair() }
                }
            } message: {
                Text("电脑已经删除这台手机的配对记录。确认后本机记录也会删除；保留记录不会自动恢复连接。")
            }
    }

    /// §4.6 new-pairing notice: name + the new phone's fingerprint, warning
    /// that an unexpected pairing means "revoke all and rotate identity".
    private func pairingNotice(_ notice: PCLinkNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PCLinkWorkspaceText.noticeBanner(notice))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { models.pcLink.dismissNotice() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HomeSpec.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭通知")
            }
            Text(PCLinkNotice.warning)
                .font(.system(size: 12))
                .foregroundStyle(HomeSpec.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
        .homeFloatingShadow()
    }
}

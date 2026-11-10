// SPDX-License-Identifier: MIT
// 我的 › 已连接的电脑 (D2, singular). One paired PC: name, DSH version,
// liveness, this phone's fingerprint and unpairing. A new pairing is blocked
// while a record exists (§4.6: the phone allows exactly one PC).

import PhoneDSHPCLink
import ProbeKit
import SwiftUI

struct ConnectedComputerPage: View {
    @Environment(\.workspaceModels) private var models

    @State private var showPairing = false
    @State private var confirmUnpair = false
    @State private var showAlreadyPaired = false
    @State private var unpairError: String?

    private var record: PCLinkPairingRecord? { models.pcLink.record }

    var body: some View {
        List {
            if let record {
                connectedSection(record)
                securitySection(record)
                actionsSection
            } else {
                emptySection
            }
        }
        .homeGroupedList()
        .navigationTitle("已连接的电脑")
        .navigationBarTitleDisplayMode(.inline)
        .task { models.pcLink.markConnectionScreenOpened() }
        .sheet(isPresented: $showPairing) {
            NavigationStack { PCPairingPage() }
        }
        .alert("解除配对？", isPresented: $confirmUnpair) {
            Button("取消", role: .cancel) {}
            Button("解除配对", role: .destructive) {
                Task {
                    do { try await models.pcLink.unpair() }
                    catch { unpairError = error.localizedDescription }
                }
            }
        } message: {
            Text("只会删除这台手机上的配对记录。电脑上的记录仍然有效；请同时在电脑上运行 pclink unpair，或先撤销全部配对再 rotate-identity。")
        }
        .alert("这台手机已经配对了一台电脑", isPresented: $showAlreadyPaired) {
            Button("知道了", role: .cancel) {}
            Button("解除当前配对") { confirmUnpair = true }
        } message: {
            Text("同一时间只配对一台电脑。先解除当前电脑，才能配对新电脑。")
        }
        .alert("解除没有完成", isPresented: Binding(
            get: { unpairError != nil }, set: { if !$0 { unpairError = nil } })) {
            Button("知道了", role: .cancel) { unpairError = nil }
        } message: {
            Text(unpairError ?? "")
        }
    }

    private func connectedSection(_ record: PCLinkPairingRecord) -> some View {
        Section {
            row("电脑名称", record.peerName)
            row("DSH 版本", dshVersionText)
            HStack {
                Text("在线状态")
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(models.pcLink.isOnline ? HomeSpec.success : HomeSpec.textPlaceholder)
                        .frame(width: 7, height: 7)
                    Text(connectionText)
                }
                .foregroundStyle(HomeSpec.textSecondary)
            }
            .frame(minHeight: 44)
            if models.pcLink.longOffline {
                Text(PCLinkWorkspaceText.longOffline)
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("电脑")
        } footer: {
            if let warning = models.pcLink.versionWarning {
                // Persistent, in range or not: an out-of-range PC is a warning,
                // never a silent or blocked connection (§5.6/CCR-2).
                Text(warning.message)
            } else if models.pcLink.isOnline {
                Text("这台手机连接的是电脑上的 DSH 工作区，会话、审批和文件都在电脑上。")
            } else {
                Text("电脑离线时停在「PC」分段，不会自动切回手机。")
            }
        }
    }

    private func securitySection(_ record: PCLinkPairingRecord) -> some View {
        Section {
            row("本机指纹", models.pcLink.ownFingerprint)
            row("配对方式", PCLinkWorkspaceText.pairingMode(record.pairingMode))
            row("配对时间", PCLinkWorkspaceText.pairedAtDisplay(record.pairedAt))
            row("中继", record.relayOrigin)
        } header: {
            Text("本机")
        } footer: {
            Text("本机指纹用于核对这台手机；扫码或手动码本身就是配对确认，电脑不会再要求输入指纹。")
        }
    }

    private var actionsSection: some View {
        Section {
            Button("配对新电脑") {
                showAlreadyPaired = true
            }
            .frame(minHeight: 44)
            Button("解除配对", role: .destructive) {
                confirmUnpair = true
            }
            .frame(minHeight: 44)
        }
    }

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("还没有连接电脑")
                    .font(.system(size: 17, weight: .semibold))
                Text("在电脑上运行 pclink pair 打开配对，然后用这台手机扫码或粘贴配对链接。")
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("连接电脑") { showPairing = true }
                    .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(HomeSpec.primaryButton, in: Capsule())
                    .foregroundStyle(HomeSpec.primaryButtonInk)
            }
            .padding(.vertical, 8)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(HomeSpec.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
    }

    private var connectionText: String {
        if models.pcLink.isOnline { return "在线" }
        if case .offline(let reason) = models.pcLink.connection {
            return PCLinkWorkspaceText.offlineReason(reason)
        }
        return "离线"
    }

    /// Exact DSH version from the verified `peer.hello` (CCR-2). The tested
    /// range only adds the "未验证" suffix; it never hides the actual build.
    private var dshVersionText: String {
        if let version = models.pcLink.pcDSHVersion {
            return models.pcLink.versionWarning == nil ? version : "\(version)（未验证）"
        }
        return "未获取（电脑离线）"
    }
}

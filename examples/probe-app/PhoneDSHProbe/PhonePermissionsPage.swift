// SPDX-License-Identifier: MIT

import ContactsUI
import ProbeKit
import SwiftUI
import UIKit

struct PhonePermissionsPage: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PhonePermissionStore.shared
    @StateObject private var requester = PhonePermissionRequester.shared
    @State private var confirmation: PhoneCapability?
    @State private var disableNotice: PhoneCapability?
    @State private var audit: [PhoneCapabilityAuditRecord] = []
    private let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
    }

    var body: some View {
        permissionList
            .navigationTitle("手机权限")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await refresh() }
            }
            .alert("允许使用这项能力？", isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } })) {
                Button("取消", role: .cancel) { confirmation = nil }
                Button("继续") { continueRequest() }
            } message: {
                Text(confirmation?.purpose ?? "")
            }
            .alert("已停用应用内使用", isPresented: Binding(
                get: { disableNotice != nil },
                set: { if !$0 { disableNotice = nil } })) {
                Button("知道了") { disableNotice = nil }
                Button("去系统设置") { openSettings() }
            } message: {
                Text("这只停用 Phone DSH 的\(disableNotice?.title ?? "")能力，不会撤销系统权限。撤销或修改系统授权请前往系统设置。")
            }
    }

    private var permissionList: some View {
        List {
            introductionSection
            capabilitySections
            auditSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
    }

    private var introductionSection: some View {
        Section {
            Text("开关只控制 Phone DSH 是否使用能力，不会撤销系统权限。系统授权只在你点击对应项目并确认用途后请求。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.white)
        }
    }

    private var capabilitySections: some View {
        ForEach(PhoneCapabilityGroup.allCases, id: \.self) { group in
            Section(group.title) {
                ForEach(group.capabilities) { capability in
                    row(capability)
                        .opacity(status(capability).blocksInteraction ? 0.4 : 1)
                        .listRowSeparatorTint(ChatPage.hairline)
                        .listRowBackground(Color.white)
                }
            }
        }
    }

    @ViewBuilder
    private var auditSection: some View {
        Section("最近使用审计") {
            if audit.isEmpty {
                Text("暂无使用记录")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.white)
            } else {
                ForEach(Array(audit.prefix(20).enumerated()), id: \.offset) { _, record in
                    PhoneCapabilityAuditRow(record: record)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ capability: PhoneCapability) -> some View {
        let current = status(capability)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    activate(capability)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: capability.systemImage)
                            .font(.title3)
                            .foregroundStyle(ChatPage.accent)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capability.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(capability.purpose)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(statusText(capability, status: current))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(statusColor(current))
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(current.blocksInteraction || capability.isReadOnlyAlwaysOn)

                Toggle("启用\(capability.title)", isOn: Binding(
                    get: { store.isEnabled(capability) && current.permitsUse },
                    set: { enabled in
                        if enabled { activate(capability) }
                        else {
                            store.setEnabled(false, for: capability)
                            disableNotice = capability
                        }
                    }))
                    .labelsHidden()
                    .disabled(current.blocksInteraction || capability.isReadOnlyAlwaysOn
                              || requester.requesting == capability)
            }
            if current == .denied {
                Button("去系统设置") { openSettings() }
                    .font(.footnote.weight(.medium))
            }
            if case .limited = current {
                limitedManagement(capability)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func limitedManagement(_ capability: PhoneCapability) -> some View {
        switch capability {
        case .photos:
            Button("管理可访问照片") { requester.presentLimitedPhotosPicker() }
                .font(.footnote.weight(.medium))
        case .contacts:
            if #available(iOS 18.0, *) {
                ContactAccessButton(queryString: "") { _ in
                    Task { await refresh() }
                }
                .contactAccessButtonCaption(.defaultText)
                .frame(minHeight: 32)
            }
        default:
            EmptyView()
        }
    }

    private func status(_ capability: PhoneCapability) -> CapabilityStatus {
        if preview { return PhonePermissionPreviewData.statuses[capability] ?? .notDetermined }
        return requester.statuses[capability] ?? .notDetermined
    }

    private func statusText(_ capability: PhoneCapability, status: CapabilityStatus) -> String {
        if capability == .device { return "常开" }
        if capability == .localNetwork, status == .notDetermined { return "未验证 · 点击测试" }
        if capability == .localNetwork, status == .denied { return "可能已拒绝" }
        if capability == .biometrics, status == .authorized { return "已允许 · 写操作前确认" }
        return status.text
    }

    private func statusColor(_ status: CapabilityStatus) -> Color {
        switch status {
        case .authorized: return .green
        case .limited, .notDetermined, .requested: return ChatPage.warning
        case .denied: return ChatPage.danger
        case .restricted, .unavailable: return .secondary
        }
    }

    private func activate(_ capability: PhoneCapability) {
        guard !capability.isReadOnlyAlwaysOn else { return }
        let current = status(capability)
        if current == .denied {
            openSettings()
        } else if capability == .biometrics {
            Task { @MainActor in
                if await requester.confirmBiometricWrite(tool: "敏感写操作") {
                    store.setEnabled(true, for: capability)
                }
            }
        } else if current.permitsUse {
            store.setEnabled(true, for: capability)
        } else if current.canRequest {
            confirmation = capability
        }
    }

    private func continueRequest() {
        guard let capability = confirmation else { return }
        confirmation = nil
        Task { await request(capability) }
    }

    private func request(_ capability: PhoneCapability) async {
        let result = await requester.request(capability)
        store.setEnabled(result.permitsUse, for: capability)
        await loadAudit()
    }

    private func refresh() async {
        if preview {
            audit = PhonePermissionPreviewData.audit
            return
        }
        await requester.refresh()
        await loadAudit()
    }

    private func loadAudit() async {
        audit = await PhoneCapabilityAudit.shared.recent(limit: 20)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct PhoneCapabilityAuditRow: View {
    let record: PhoneCapabilityAuditRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.tool)
                    .font(.system(.subheadline, design: .monospaced))
                Spacer()
                Text(record.outcome)
                    .font(.caption)
                    .foregroundStyle(record.outcome == "success" ? Color.green : Color.orange)
            }
            Text("\(record.capability.title) · \(record.at.formatted(date: .abbreviated, time: .shortened)) · egress \(record.egress ? "true" : "false")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowSeparatorTint(ChatPage.hairline)
        .listRowBackground(Color.white)
    }
}

#Preview {
    NavigationStack { PhonePermissionsPage(preview: true) }
}

// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

struct ConnectorDetailPage<Configuration: View>: View {
    let descriptor: DiscoverConnectorDescriptor
    let model: DiscoverConnectorModel
    let useInChat: () -> Void
    let configuration: Configuration

    init(descriptor: DiscoverConnectorDescriptor, model: DiscoverConnectorModel,
         useInChat: @escaping () -> Void, @ViewBuilder configuration: () -> Configuration) {
        self.descriptor = descriptor
        self.model = model
        self.useInChat = useInChat
        self.configuration = configuration()
    }

    private var record: ConnectorRecord? { model.records[descriptor.id] }
    private var grant: ConnectorGrant? { model.grants[descriptor.id] }

    var body: some View {
        List {
            Section(NativeText("用途与能力", "Purpose and capabilities")) {
                Text(descriptor.supported)
                Text(descriptor.unsupported)
                    .foregroundStyle(HomeSpec.textSecondary)
                Text(descriptor.example)
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textSecondary)
            }

            Section(NativeText("账号与连接", "Account and connection")) {
                LabeledContent(NativeText("状态", "State"),
                               value: record.map { nativeConnectorStateTitle($0.state) } ?? NativeText("读取中", "Loading"))
                LabeledContent(NativeText("账号", "Account"), value: NativeText("未配置", "Not configured"))
                LabeledContent(NativeText("最近核验", "Last verified")) {
                    if let date = record?.lastVerifiedAt {
                        Text(date, style: .relative)
                    } else {
                        Text(NativeText("尚未核验", "Not verified"))
                    }
                }
                if let issue = record?.issue {
                    Text(issue)
                        .font(.system(size: 13))
                        .foregroundStyle(NativeParityTokens.warning)
                }
                configuration
            }

            Section(NativeText("数据范围与授权", "Data scope and grant")) {
                LabeledContent(NativeText("Grant", "Grant"),
                               value: grant.map { "v\($0.version)" } ?? NativeText("未授权", "No grant"))
                Text(NativeText("读取、草稿与发送等能力分别授权；当前没有真实 grant。", "Read, draft and send capabilities have separate grants. No real grant is present."))
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                if record?.state == .connected || record?.state == .needsAttention || record?.state == .expired {
                    Button(NativeText("撤销授权", "Revoke grant"), role: .destructive) {
                        Task { await model.revoke(descriptor.id) }
                    }
                }
            }

            Section(NativeText("同步", "Synchronization")) {
                Text(NativeText("首版仅前台与手动同步，不显示实时状态。", "The first version syncs in the foreground or manually; it does not claim real-time status."))
                LabeledContent(NativeText("最近同步游标", "Last sync cursor"), value: NativeText("尚未同步", "Not synced"))
            }

            Section(NativeText("凭据", "Credentials")) {
                Text(NativeText("OAuth token 与 PAT 只应存于 Keychain，由原生宿主注入，不回显，也不进入 Worker、日志或截图。",
                                "OAuth tokens and PATs belong only in Keychain and are injected natively; they are never displayed or sent to Worker, logs or screenshots."))
                    .font(.system(size: 14))
            }

            Section {
                Button(NativeText("在 Chat 中使用", "Use in Chat"), action: useInChat)
                    .buttonStyle(HomePrimaryButtonStyle())
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } footer: {
                Text(NativeText("只返回 Chat 并保留来源上下文，不会自动发送示例。", "Returns to Chat with source context; it never sends the example automatically."))
            }
        }
        .homeGroupedList()
        .navigationTitle(descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .accessibilityIdentifier("discover.connector.detail.\(descriptor.id)")
    }
}

extension ConnectorDetailPage where Configuration == EmptyView {
    init(descriptor: DiscoverConnectorDescriptor, model: DiscoverConnectorModel,
         useInChat: @escaping () -> Void) {
        self.init(descriptor: descriptor, model: model, useInChat: useInChat) { EmptyView() }
    }
}

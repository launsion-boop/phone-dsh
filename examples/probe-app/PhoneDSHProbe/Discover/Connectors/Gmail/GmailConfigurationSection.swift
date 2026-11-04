// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

public struct GmailConfigurationPresentation: Equatable, Sendable {
    public var isOAuthConfigured: Bool
    public var account: String?
    public var state: ConnectorState
    public var readScope: String
    public var writeGrants: GmailWriteGrantSelection
    public var retainsRawBody: Bool
    public var derivedSummaryRetentionDays: Int
    public var lastSyncCursor: String?
    public var lastVerifiedAt: Date?
    public var issue: String?

    public init(isOAuthConfigured: Bool, account: String?, state: ConnectorState,
                readScope: String = GmailScope.readOnly,
                writeGrants: GmailWriteGrantSelection = GmailWriteGrantSelection(),
                retainsRawBody: Bool = false, derivedSummaryRetentionDays: Int = 7,
                lastSyncCursor: String? = nil, lastVerifiedAt: Date? = nil, issue: String? = nil) {
        self.isOAuthConfigured = isOAuthConfigured
        self.account = account
        self.state = state
        self.readScope = readScope
        self.writeGrants = writeGrants
        self.retainsRawBody = retainsRawBody
        self.derivedSummaryRetentionDays = derivedSummaryRetentionDays
        self.lastSyncCursor = lastSyncCursor
        self.lastVerifiedAt = lastVerifiedAt
        self.issue = issue
    }

    public var maskedAccount: String {
        guard let account, let at = account.firstIndex(of: "@"), at > account.startIndex else { return "未连接" }
        let name = account[..<at]
        return "\(name.prefix(1))***\(account[at...])"
    }
}

public struct GmailConfigurationSection: View {
    private let presentation: GmailConfigurationPresentation
    private let onConnect: () -> Void
    private let onRevoke: () -> Void
    private let onOpenChat: () -> Void
    private let onChangeGrants: ((GmailWriteGrantSelection) -> Void)?

    public init(presentation: GmailConfigurationPresentation, onConnect: @escaping () -> Void,
                onRevoke: @escaping () -> Void, onOpenChat: @escaping () -> Void,
                onChangeGrants: ((GmailWriteGrantSelection) -> Void)? = nil) {
        self.presentation = presentation
        self.onConnect = onConnect
        self.onRevoke = onRevoke
        self.onOpenChat = onOpenChat
        self.onChangeGrants = onChangeGrants
    }

    public var body: some View {
        Section("Gmail") {
            LabeledContent("账号", value: presentation.maskedAccount)
            LabeledContent("状态", value: presentation.state.rawValue)
            if !presentation.isOAuthConfigured {
                Text("尚未配置 OAuth 客户端").foregroundStyle(.secondary)
                Button("连接 Gmail") {}.disabled(true)
            } else {
                Button(presentation.state == .connected ? "重新授权" : "连接 Gmail", action: onConnect)
            }
            LabeledContent("读取范围", value: presentation.readScope)
            grantToggle("自动创建/更新草稿", \.drafts)
            grantToggle("自动在线程内回复", \.reply)
            grantToggle("自动发送新邮件", \.sendNew)
            grantToggle("自动转发（默认关闭）", \.forward)
            LabeledContent("原始正文", value: presentation.retainsRawBody ? "按所选范围保存" : "不长期保存")
            LabeledContent("派生摘要", value: "保留 \(presentation.derivedSummaryRetentionDays) 天，到期清理")
            LabeledContent("最近同步游标", value: presentation.lastSyncCursor ?? "尚未同步")
            if let lastVerifiedAt = presentation.lastVerifiedAt {
                LabeledContent("最近核验", value: lastVerifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let issue = presentation.issue {
                Text(issue).foregroundStyle(.red)
            }
            Text("仅前台或手动同步。Token 只存 Keychain，不进入 Worker、日志或截图。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("在 Chat 中使用", action: onOpenChat)
            Button("撤销授权并删除 Token", role: .destructive, action: onRevoke)
        }
    }

    private func grantToggle(_ title: String, _ keyPath: WritableKeyPath<GmailWriteGrantSelection, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { presentation.writeGrants[keyPath: keyPath] }, set: { enabled in
            var updated = presentation.writeGrants
            updated[keyPath: keyPath] = enabled
            onChangeGrants?(updated)
        })).disabled(onChangeGrants == nil)
    }
}

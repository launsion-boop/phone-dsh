// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI

public struct GitHubConnectorConfigurationSection: View {
    @ObservedObject private var model: GitHubConnectorModel
    @State private var pat = ""
    @State private var repositories = ""

    public init(model: GitHubConnectorModel) {
        self.model = model
    }

    public var body: some View {
        Section("GitHub") {
            LabeledContent("状态", value: model.record.state.rawValue)
            if let account = model.maskedAccount {
                LabeledContent("账号", value: account)
            }
            if let grant = model.grant {
                LabeledContent("授权仓库", value: grant.scope.repositories.joined(separator: ", "))
                LabeledContent("范围", value: scopeText(grant))
            }
            if let verified = model.record.lastVerifiedAt {
                LabeledContent("最近核验", value: verified.formatted(date: .abbreviated, time: .shortened))
            }
            if let issue = model.record.issue {
                Text(issue).foregroundStyle(.red)
            }
            if model.record.state != .connected {
                SecureField("fine-grained PAT", text: $pat)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .privacySensitive()
                TextField("授权仓库，例如 owner/repo", text: $repositories, axis: .vertical)
                Toggle("允许委托内评论", isOn: $model.allowsComments)
                Toggle("允许委托内创建 Issue", isOn: $model.allowsIssueCreation)
                Button("核验并连接") {
                    Task { await model.connect(pat: pat, repositoriesText: repositories) }
                }
                .disabled(model.busy || pat.isEmpty)
            } else {
                Button("撤权并删除本机 PAT", role: .destructive) {
                    Task { await model.revoke() }
                }
                .disabled(model.busy)
            }
            if model.busy { ProgressView() }
            Text("示例：读取 owner/repo 的 PR 12，并只告诉我新的阻塞。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { await model.refresh() }
        .onChange(of: model.record.state) { state in
            if state == .connected || state == .revoked { pat = "" }
        }
    }

    private func scopeText(_ grant: ConnectorGrant) -> String {
        var values = ["只读"]
        if grant.allowedActions.contains(.githubComment) { values.append("评论") }
        if grant.allowedActions.contains(.githubCreateIssue) { values.append("创建 Issue") }
        return values.joined(separator: "、")
    }
}

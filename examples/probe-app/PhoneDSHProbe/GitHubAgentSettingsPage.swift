// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the one write-capable GitHub credential.
//
// The Discover connector keeps its own read-only Keychain record. This page is
// deliberately separate: a token here can commit, create branches and open pull
// requests, so it needs an explicit save plus a separate write opt-in.

import PhoneDSH
import SwiftUI

struct GitHubAgentSettingsPage: View {
    private let store = KeychainModelProviderSecretStore(service: GitHubAgentSettings.service)

    @State private var token = ""
    @State private var hasToken = false
    @State private var allowWrites = UserDefaults.standard.bool(
        forKey: GitHubAgentSettings.allowWritesKey)
    @State private var message: String?
    @State private var errorText: String?
    @State private var saving = false

    var body: some View {
        List {
            Section {
                SecureField(
                    NativeText("粘贴 fine-grained token", "Paste a fine-grained token"),
                    text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                Button {
                    save()
                } label: {
                    HStack {
                        Text(NativeText("保存 token", "Save token"))
                        if saving { Spacer(); ProgressView() }
                    }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                if hasToken {
                    Button(NativeText("删除 token", "Delete token"), role: .destructive) {
                        delete()
                    }
                }
            } header: {
                Text(NativeText("Agent GitHub token", "Agent GitHub token"))
            } footer: {
                Text(NativeText(
                    "读取与代码搜索需要 token；写入还需要打开下面的开关，且 token 要有 Contents: write 与 Pull requests: write。Discover 里的只读连接器不会授权写入。",
                    "Reads and code search use this token; writes also need the switch below, and the token needs Contents: write and Pull requests: write. The read-only Discover connector never grants writes."))
            }

            Section {
                Toggle(NativeText("允许 Agent 写入 GitHub", "Allow the agent to write to GitHub"),
                       isOn: $allowWrites)
                    .onChange(of: allowWrites) { _, value in
                        UserDefaults.standard.set(value, forKey: GitHubAgentSettings.allowWritesKey)
                        message = NativeText("重启引擎后生效", "Restart the engine to apply")
                    }
            } footer: {
                Text(NativeText(
                    "关闭时 github 仍可读取和搜索，但 commit / branch / pr 会被拒绝。",
                    "When off, github can still read and search; commit / branch / pr are refused."))
            }

            Section {
                Button {
                    Task { await ChatModel.shared.restartEngine() }
                } label: {
                    Text(NativeText("重启引擎使设置生效", "Restart the engine to apply"))
                        .frame(minHeight: 40, alignment: .leading)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(SessionsPage.ink)
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("GitHub Agent", "GitHub agent"))
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
    }

    private func reload() {
        do {
            hasToken = (try store.secret(for: GitHubAgentSettings.account))?.isEmpty == false
        } catch {
            hasToken = false
        }
        allowWrites = UserDefaults.standard.bool(forKey: GitHubAgentSettings.allowWritesKey)
    }

    private func save() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isNewline }) else {
            errorText = NativeText("token 不能为空，也不能跨行", "The token must be one non-empty line")
            return
        }
        saving = true
        defer { saving = false }
        do {
            try store.setSecret(value, for: GitHubAgentSettings.account)
            token = ""
            hasToken = true
            errorText = nil
            message = NativeText("已保存；重启引擎后生效", "Saved; restart the engine to apply")
        } catch {
            errorText = NativeText("无法写入钥匙串", "Could not write to the Keychain")
        }
    }

    private func delete() {
        do {
            try store.deleteSecret(for: GitHubAgentSettings.account)
            hasToken = false
            errorText = nil
            message = NativeText("已删除；重启引擎后生效", "Deleted; restart the engine to apply")
        } catch {
            errorText = NativeText("无法删除钥匙串记录", "Could not delete the Keychain record")
        }
    }
}

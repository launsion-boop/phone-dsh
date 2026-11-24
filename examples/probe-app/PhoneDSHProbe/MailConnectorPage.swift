// SPDX-License-Identifier: MIT
// Mailboxes the agent may read and send from: QQ Mail and NetEase with a
// client authorization code, Gmail with an app password. The code is checked
// against IMAP and SMTP before it is saved, and is kept only in the Keychain.

import PhoneDSHMail
import ProbeKit
import SwiftUI
import UIKit

/// Asks the user, in the foreground app, before the agent sends a message.
/// Without a visible window (background, Bot wake) the answer is "no".
struct MailSendApprover: MailSendApproving {
    func approve(account: MailAccount, draft: MailDraft) async -> Bool {
        await Task { @MainActor in
            guard UIApplication.shared.applicationState == .active,
                  let presenter = PhoneCapabilityViewPresenter.topViewController() else { return false }
            return await Self.ask(presenter, account: account, draft: draft)
        }.value
    }

    @MainActor
    private static func ask(_ presenter: UIViewController, account: MailAccount, draft: MailDraft) async -> Bool {
        await withCheckedContinuation { continuation in
            var lines = ["发件人：\(account.address)", "收件人：\(draft.to.joined(separator: ", "))"]
            if !draft.cc.isEmpty { lines.append("抄送：\(draft.cc.joined(separator: ", "))") }
            if !draft.bcc.isEmpty { lines.append("密送：\(draft.bcc.joined(separator: ", "))") }
            lines.append("主题：\(draft.subject)")
            let preview = draft.body.count > 600 ? String(draft.body.prefix(600)) + "…" : draft.body
            lines.append("")
            lines.append(preview)
            let alert = UIAlertController(title: NativeText("发送这封邮件？", "Send this email?"),
                                          message: lines.joined(separator: "\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NativeText("取消", "Cancel"), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: NativeText("发送", "Send"), style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alert, animated: true)
        }
    }
}

@MainActor
@Observable
final class MailConnectorModel {
    static let shared = MailConnectorModel()

    private(set) var accounts: [MailAccount] = []
    private(set) var verifying = false
    var errorText: String?

    private let store: MailAccountStore
    private let service: MailService

    init(store: MailAccountStore = .shared, service: MailService = MailService()) {
        self.store = store
        self.service = service
        accounts = store.accounts()
    }

    func accounts(for provider: MailProvider) -> [MailAccount] {
        accounts.filter { $0.provider == provider }
    }

    /// Log in to IMAP and SMTP with the code, then save it.
    func add(provider: MailProvider, address: String, secret: String) async -> Bool {
        errorText = nil
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        // Codes are shown in groups; spaces are never part of them.
        let trimmedSecret = secret.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let account = MailAccount(address: trimmedAddress, provider: provider)
        guard provider.servers(for: account.address) != nil else {
            errorText = NativeText("请输入\(provider.displayName)地址（\(provider.domains.joined(separator: "、"))）。",
                                   "Enter a \(provider.displayName) address (\(provider.domains.joined(separator: ", "))).")
            return false
        }
        guard !trimmedSecret.isEmpty else {
            errorText = NativeText("请填写\(provider.secretName)。", "Enter the \(provider.secretName).")
            return false
        }
        verifying = true
        defer { verifying = false }
        do {
            try await service.verify(account, secret: trimmedSecret)
            try store.save(account, secret: trimmedSecret)
            accounts = store.accounts()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func remove(_ account: MailAccount) {
        do {
            try store.remove(account.address)
            accounts = store.accounts()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct MailConnectorPage: View {
    let provider: MailProvider
    @State private var model = MailConnectorModel.shared
    @State private var address = ""
    @State private var secret = ""
    @State private var pendingRemoval: MailAccount?

    var body: some View {
        List {
            let connected = model.accounts(for: provider)
            if !connected.isEmpty {
                Section {
                    ForEach(connected) { account in
                        HStack {
                            Label(account.address, systemImage: "checkmark.circle")
                            Spacer()
                            Button(NativeText("断开", "Disconnect"), role: .destructive) { pendingRemoval = account }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text(NativeText("已连接", "Connected"))
                } footer: {
                    Text(NativeText("对话里的 DSH 可以搜索、阅读这些邮箱的邮件；发信前会在手机上请你确认。",
                                    "DSH can search and read these mailboxes in chat; it asks you on this phone before sending."))
                }
            }

            Section {
                TextField(NativeText("邮箱地址", "Email address"), text: $address)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mail.\(provider.rawValue).address")
                SecureField(provider.secretName, text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mail.\(provider.rawValue).secret")
                Button {
                    Task {
                        if await model.add(provider: provider, address: address, secret: secret) {
                            address = ""
                            secret = ""
                        }
                    }
                } label: {
                    if model.verifying {
                        HStack(spacing: 10) { ProgressView(); Text(NativeText("正在验证…", "Verifying…")) }
                    } else {
                        Label(NativeText("连接", "Connect"), systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .disabled(model.verifying)
                .accessibilityIdentifier("mail.\(provider.rawValue).connect")
            } header: {
                Text(connected.isEmpty ? NativeText("连接邮箱", "Connect a mailbox")
                                       : NativeText("再添加一个", "Add another"))
            } footer: {
                Text(Self.help(provider))
            }

            if let error = model.errorText {
                Section {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mail.\(provider.rawValue).error")
                }
            }
        }
        .homeGroupedList()
        .navigationTitle(provider.displayName)
        .confirmationDialog(NativeText("断开这个邮箱？", "Disconnect this mailbox?"),
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button(NativeText("断开", "Disconnect"), role: .destructive) {
                if let account = pendingRemoval { model.remove(account) }
                pendingRemoval = nil
            }
        } message: {
            Text(NativeText("将删除本机保存的授权码，DSH 不再能读取或发送这个邮箱的邮件。",
                            "The saved code is deleted from this phone; DSH can no longer read or send from this mailbox."))
        }
    }

    static func help(_ provider: MailProvider) -> String {
        switch provider {
        case .qq:
            return NativeText("在 QQ 邮箱网页版「设置 › 账号」里开启 IMAP/SMTP 服务，按提示生成授权码后填在这里。授权码不是 QQ 密码，只保存在本机钥匙串。",
                              "In QQ Mail on the web, open Settings › Account, turn on IMAP/SMTP and generate an authorization code. It is not your QQ password and is kept only in this phone's keychain.")
        case .netease:
            return NativeText("支持 163、126、yeah.net。在网易邮箱网页版「设置 › POP3/SMTP/IMAP」里开启 IMAP/SMTP 服务并获取授权码。授权码只保存在本机钥匙串。",
                              "Works with 163, 126 and yeah.net. In NetEase Mail on the web, open Settings › POP3/SMTP/IMAP, turn on IMAP/SMTP and get an authorization code. It is kept only in this phone's keychain.")
        case .gmail:
            return NativeText("需要先开启 Google 账号的两步验证，然后在 Google 账号「安全性 › 应用专用密码」里生成一个密码填在这里。它只保存在本机钥匙串。",
                              "Turn on 2-Step Verification for your Google Account, then create an app password under Security › App passwords and enter it here. It is kept only in this phone's keychain.")
        }
    }
}

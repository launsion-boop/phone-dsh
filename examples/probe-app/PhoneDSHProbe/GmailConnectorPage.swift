// SPDX-License-Identifier: MIT

import Observation
import ProbeKit
import SwiftUI

@MainActor
@Observable
final class GmailMailbox {
    static let shared = GmailMailbox()

    enum Account {
        case unconfigured
        case disconnected
        case connecting
        case connected(email: String, id: UUID)
        case disconnecting
        case reconnect
    }

    private(set) var account: Account = GmailSignIn.isConfigured ? .disconnected : .unconfigured
    private(set) var messages: [GmailAPI.Summary] = []
    private(set) var nextPage: String?
    private(set) var loading = false
    private(set) var notice: String?
    var query = ""

    private let api = GmailAPI()
    private var activeQuery = ""
    private var requestID = UUID()

    func restore() async {
        guard case .disconnected = account else { return }
        account = .connecting
        notice = nil
        do {
            guard try await GmailSignIn.restore() else {
                account = .disconnected
                return
            }
            try await checkAccount()
        } catch {
            failConnection(error)
        }
    }

    func connect() async {
        switch account {
        case .disconnected: break
        case .reconnect: break
        default: return
        }
        account = .connecting
        notice = nil
        do {
            try await GmailSignIn.connect()
            try await checkAccount()
        } catch {
            failConnection(error)
        }
    }

    private func checkAccount() async throws {
        let token = try await GmailSignIn.accessToken()
        account = .connected(email: try await api.accountEmail(token: token), id: UUID())
        await search()
    }

    func search(append: Bool = false) async {
        guard case .connected = account else { return }
        let pageToken: String?
        if append {
            guard let nextPage, !loading else { return }
            pageToken = nextPage
        } else {
            activeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            pageToken = nil
            clearSearch()
        }
        let id = UUID()
        requestID = id
        loading = true
        notice = nil
        defer {
            if requestID == id { loading = false }
        }
        do {
            let token = try await GmailSignIn.accessToken()
            guard id == requestID else { return }
            let page = try await api.search(activeQuery, pageToken: pageToken, token: token)
            guard id == requestID else { return }
            let existing = Set(messages.map(\.id))
            messages += page.messages.filter { !existing.contains($0.id) }
            nextPage = page.nextPageToken
        } catch {
            guard id == requestID, !Task.isCancelled else { return }
            if !handleAuthorizationError(error) {
                notice = readErrorMessage(error)
            }
        }
    }

    func read(_ id: String) async throws -> GmailAPI.Message {
        guard case .connected(_, let connection) = account else { throw GmailSignIn.Failure.notAuthorized }
        do {
            let token = try await GmailSignIn.accessToken()
            guard isCurrent(connection) else { throw CancellationError() }
            let message = try await api.message(id: id, token: token)
            guard isCurrent(connection) else { throw CancellationError() }
            try Task.checkCancellation()
            return message
        } catch {
            if isCurrent(connection), !Task.isCancelled {
                handleAuthorizationError(error)
            }
            throw error
        }
    }

    func disconnect() async {
        guard case .connected = account else { return }
        account = .disconnecting
        clearSearch()
        query = ""
        notice = nil
        let revoked = await GmailSignIn.disconnect()
        account = .disconnected
        if !revoked {
            notice = NativeText(
                "已在此手机断开。若要撤销 Google 授权，请到 Google 账号的第三方连接页面移除 Phone DSH。",
                "Disconnected on this phone. To revoke access, remove Phone DSH in your Google Account connections."
            )
        }
    }

    func readErrorMessage(_ error: Error) -> String {
        if needsAuthorization(error) {
            return NativeText("Gmail 授权已失效，请重新连接。", "Reconnect Gmail to continue.")
        }
        switch error as? GmailError {
        case .forbidden:
            return NativeText(
                "Google 拒绝了这次 Gmail 请求。请检查账号权限、Gmail API 配额和配置。",
                "Google denied this Gmail request. Check account permissions, Gmail API quota and setup."
            )
        case .notFound:
            return NativeText("找不到这封邮件。", "This email is no longer available.")
        default:
            return NativeText("暂时无法读取 Gmail，请稍后重试。", "Could not read Gmail. Try again.")
        }
    }

    private func failConnection(_ error: Error) {
        if GmailSignIn.isCancellation(error) {
            account = .disconnected
        } else if !handleAuthorizationError(error) {
            account = .disconnected
            notice = readErrorMessage(error)
        }
    }

    @discardableResult
    private func handleAuthorizationError(_ error: Error) -> Bool {
        if case GmailSignIn.Failure.readPermissionRequired = error {
            clearSearch()
            account = .reconnect
            notice = NativeText(
                "请点击“连接 Google 账号”，并在 Google 页面勾选 Gmail 读取权限。",
                "Tap Connect Google account and select Gmail read access on the Google page."
            )
            return true
        }
        if needsAuthorization(error) {
            loseAuthorization()
            return true
        }
        return false
    }

    private func isCurrent(_ connection: UUID) -> Bool {
        guard case .connected(_, let id) = account else { return false }
        return id == connection
    }

    private func needsAuthorization(_ error: Error) -> Bool {
        if case GmailSignIn.Failure.notAuthorized = error { return true }
        return (error as? GmailError) == .unauthorized || GmailSignIn.isInvalidGrant(error)
    }

    private func loseAuthorization() {
        GmailSignIn.signOut()
        clearSearch()
        account = .reconnect
        notice = NativeText("Gmail 授权已失效，请重新连接。", "Reconnect Gmail to continue.")
    }

    private func clearSearch() {
        requestID = UUID()
        loading = false
        messages = []
        nextPage = nil
    }
}

struct GmailConnectorPage: View {
    private let mailbox = GmailMailbox.shared
    @State private var selected: GmailAPI.Summary?
    @State private var confirmDisconnect = false

    var body: some View {
        List {
            accountSection
            if let notice = mailbox.notice {
                Section {
                    Text(verbatim: notice).foregroundStyle(.secondary)
                }
            }
            if case .connected = mailbox.account {
                mailSection
            }
        }
        .homeGroupedList()
        .navigationTitle("Gmail")
        .navigationBarTitleDisplayMode(.inline)
        .task { await mailbox.restore() }
        .sheet(item: $selected) { summary in
            NavigationStack {
                GmailMessagePage(summary: summary, mailbox: mailbox)
            }
        }
        .alert(NativeText("断开 Gmail？", "Disconnect Gmail?"), isPresented: $confirmDisconnect) {
            Button(NativeText("断开连接", "Disconnect"), role: .destructive) {
                Task { await mailbox.disconnect() }
            }
            Button(NativeText("取消", "Cancel"), role: .cancel) {}
        }
    }

    private var accountSection: some View {
        Section {
            switch mailbox.account {
            case .unconfigured:
                Label(NativeText("当前版本未配置 Gmail 登录", "Gmail sign-in is not configured in this build"), systemImage: "info.circle")
            case .disconnected, .reconnect:
                Button {
                    Task { await mailbox.connect() }
                } label: {
                    Label(NativeText("连接 Google 账号", "Connect Google account"), systemImage: "person.crop.circle.badge.plus")
                }
            case .connecting:
                ProgressView(NativeText("正在连接 Gmail…", "Connecting to Gmail…"))
            case .disconnecting:
                ProgressView(NativeText("正在断开 Gmail…", "Disconnecting Gmail…"))
            case .connected(let email, _):
                Label(email, systemImage: "checkmark.circle")
                    .accessibilityLabel(NativeText("已连接", "Connected") + " " + email)
                Button(NativeText("断开连接", "Disconnect"), role: .destructive) {
                    confirmDisconnect = true
                }
            }
        } header: {
            Text(NativeText("Google 账号", "Google account"))
        } footer: {
            Text(NativeText("此连接只用于在手机上搜索和阅读邮件。", "This connection lets you search and read mail on this phone."))
        }
    }

    private var mailSection: some View {
        Section {
            @Bindable var model = mailbox
            HStack {
                TextField(NativeText("发件人、主题或关键词", "Sender, subject or keyword"), text: $model.query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { Task { await mailbox.search() } }
                Button(NativeText("搜索", "Search")) {
                    Task { await mailbox.search() }
                }
                .buttonStyle(.borderless)
            }
            ForEach(mailbox.messages) { message in
                Button { selected = message } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: message.subject.isEmpty ? NativeText("无主题", "No subject") : message.subject)
                            .foregroundStyle(HomeSpec.textPrimary)
                            .lineLimit(2)
                        Text(verbatim: message.sender)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("gmail.message.row")
            }
            if mailbox.loading {
                ProgressView()
            } else {
                if mailbox.messages.isEmpty, mailbox.notice == nil {
                    Text(NativeText("没有找到邮件。", "No messages found.")).foregroundStyle(.secondary)
                }
                if mailbox.nextPage != nil {
                    Button(NativeText("加载更多", "Load more")) {
                        Task { await mailbox.search(append: true) }
                    }
                }
            }
        } header: {
            Text(NativeText("邮件", "Mail"))
        }
    }
}

private struct GmailMessagePage: View {
    let summary: GmailAPI.Summary
    let mailbox: GmailMailbox
    @Environment(\.dismiss) private var dismiss
    @State private var message: GmailAPI.Message?
    @State private var errorMessage: String?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: summary.subject.isEmpty ? NativeText("无主题", "No subject") : summary.subject)
                    .font(.headline)
                Text(verbatim: summary.sender).font(.subheadline)
                if let date = summary.date {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.footnote)
                }
            }
            .textSelection(.enabled)
            .padding()
            Divider()
            if let message {
                switch message.body {
                case .plain(let text):
                    ScrollView {
                        Text(verbatim: text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .accessibilityIdentifier("gmail.message.body")
                case .html(let html):
                    GmailHTMLPreview(html: html)
                        .accessibilityIdentifier("gmail.message.body")
                case .unavailable:
                    Text(NativeText("这封邮件没有可预览的正文。", "This message has no previewable body."))
                        .padding()
                }
            } else if let errorMessage {
                Text(verbatim: errorMessage).padding()
                Button(NativeText("重试", "Retry")) { attempt += 1 }
                    .padding(.horizontal)
            } else {
                ProgressView().padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(NativeText("邮件正文", "Message"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NativeText("完成", "Done")) { dismiss() }
            }
        }
        .task(id: attempt) {
            errorMessage = nil
            do {
                message = try await mailbox.read(summary.id)
            } catch {
                guard !Task.isCancelled else { return }
                if case .reconnect = mailbox.account {
                    dismiss()
                } else {
                    errorMessage = mailbox.readErrorMessage(error)
                }
            }
        }
    }
}

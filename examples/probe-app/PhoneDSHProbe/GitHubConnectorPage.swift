// SPDX-License-Identifier: MIT

import Observation
import PhoneDSH
import ProbeKit
import SwiftUI

@MainActor
@Observable
final class GitHubConnectorModel {
    static let shared = GitHubConnectorModel()

    enum State {
        case disconnected
        case connecting
        case connected(
            login: String,
            repos: [GitHubConnectorAPI.Repository],
            nextPage: Int?,
            notice: String?
        )
    }

    private(set) var state: State = .disconnected
    private(set) var connectionNotice: String?
    private(set) var loading = false
    private(set) var needsDeleteRetry = false
    private(set) var canRetryRestore = false

    private let api = GitHubConnectorAPI()
    private let secrets = KeychainModelProviderSecretStore(service: "dev.phone-dsh.probe.github")
    private static let tokenReference = "access-token"
    private var epoch = UUID()

    func restore() async {
        guard case .disconnected = state, !needsDeleteRetry else { return }
        canRetryRestore = false
        let stored: String?
        do {
            stored = try secrets.secret(for: Self.tokenReference)
        } catch {
            connectionNotice = Self.readFailure
            canRetryRestore = true
            return
        }
        guard let token = stored, GitHubConnectorAPI.isValidToken(token) else {
            if stored != nil { connectionNotice = Self.invalidStoredToken }
            return
        }
        await authenticate(token: token, persist: false)
    }

    func connect(token: String) async {
        guard case .disconnected = state, !needsDeleteRetry else { return }
        guard GitHubConnectorAPI.isValidToken(token) else {
            connectionNotice = Self.invalidToken
            return
        }
        await authenticate(token: token, persist: true)
    }

    private func authenticate(token: String, persist: Bool) async {
        let id = UUID()
        epoch = id
        connectionNotice = nil
        canRetryRestore = false
        loading = false
        state = .connecting
        do {
            let login = try await api.account(token: token).login
            guard epoch == id else { return }
            guard !Task.isCancelled else {
                state = .disconnected
                return
            }
            if persist {
                do {
                    try secrets.setSecret(token, for: Self.tokenReference)
                } catch {
                    guard epoch == id else { return }
                    state = .disconnected
                    connectionNotice = Self.saveFailure
                    return
                }
            }
            guard epoch == id else { return }
            needsDeleteRetry = false
            state = .connected(login: login, repos: [], nextPage: nil, notice: nil)
            await loadRepositories(page: 1, append: false, token: token, id: id)
        } catch {
            guard epoch == id else { return }
            state = .disconnected
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if !persist, (error as? GitHubConnectorError) == .unauthorized {
                clearConnection(notice: Self.reconnectNotice)
            } else {
                connectionNotice = Self.notice(for: error)
                canRetryRestore = !persist
            }
        }
    }

    func loadMore() async {
        guard case .connected(_, _, let nextPage, let notice) = state,
              notice == nil, let nextPage, !loading
        else { return }
        guard let token = storedToken() else { return }
        let id = UUID()
        epoch = id
        await loadRepositories(page: nextPage, append: true, token: token, id: id)
    }

    func retry() async {
        guard case .connected(_, let repos, let nextPage, let notice) = state,
              notice != nil, !loading
        else { return }
        let page: Int
        if repos.isEmpty {
            page = 1
        } else if let nextPage {
            page = nextPage
        } else {
            return
        }
        guard let token = storedToken() else { return }
        let id = UUID()
        epoch = id
        await loadRepositories(page: page, append: !repos.isEmpty, token: token, id: id)
    }

    private func loadRepositories(page: Int, append: Bool, token: String, id: UUID) async {
        guard epoch == id,
              case .connected(let login, let current, let nextPage, _) = state
        else { return }
        loading = true
        defer { if epoch == id { loading = false } }
        do {
            let result = try await api.repositories(page: page, token: token)
            guard epoch == id, case .connected = state else { return }
            var repositories = append ? current : result.repositories
            if append {
                let existing = Set(repositories.map(\.id))
                repositories += result.repositories.filter { !existing.contains($0.id) }
            }
            state = .connected(
                login: login, repos: repositories, nextPage: result.nextPage, notice: nil
            )
        } catch {
            guard epoch == id else { return }
            if Task.isCancelled || error is CancellationError {
                state = .disconnected
                return
            }
            if (error as? GitHubConnectorError) == .unauthorized {
                clearConnection(notice: Self.reconnectNotice)
            } else {
                state = .connected(
                    login: login, repos: current, nextPage: nextPage, notice: Self.notice(for: error)
                )
            }
        }
    }

    func disconnect() {
        guard case .connected = state else { return }
        clearConnection(notice: nil)
    }

    private func clearConnection(notice: String?) {
        epoch = UUID()
        loading = false
        canRetryRestore = false
        state = .disconnected
        connectionNotice = notice
        do {
            try secrets.deleteSecret(for: Self.tokenReference)
            needsDeleteRetry = false
        } catch {
            needsDeleteRetry = true
            connectionNotice = Self.deleteFailure
        }
    }

    func retryDelete() {
        guard needsDeleteRetry else { return }
        do {
            try secrets.deleteSecret(for: Self.tokenReference)
            needsDeleteRetry = false
            if case .disconnected = state { connectionNotice = nil }
        } catch {
            connectionNotice = Self.deleteFailure
        }
    }

    private func storedToken() -> String? {
        do {
            if let token = try secrets.secret(for: Self.tokenReference),
               GitHubConnectorAPI.isValidToken(token) {
                return token
            }
        } catch {
            // Fall through to the reconnect state; never surface a raw error.
        }
        epoch = UUID()
        loading = false
        state = .disconnected
        connectionNotice = Self.reconnectNotice
        return nil
    }

    private static func notice(for error: Error) -> String {
        guard let error = error as? GitHubConnectorError else { return genericFailure }
        switch error {
        case .unauthorized:
            return reconnectNotice
        case .rateLimited:
            return NativeText(
                "GitHub 暂时限制了请求频率，请稍后重试。",
                "GitHub is temporarily rate limiting requests. Try again later."
            )
        case .forbidden:
            return NativeText(
                "GitHub 拒绝访问。请确认令牌已选择仓库，并授予 Metadata 只读权限。",
                "GitHub denied access. Check that the token selects repositories and grants read-only Metadata."
            )
        case .invalidResponse:
            return NativeText(
                "GitHub 返回了无法读取的数据，请稍后重试。",
                "GitHub returned unreadable data. Try again later."
            )
        case .serviceUnavailable:
            return genericFailure
        }
    }

    private static let genericFailure = NativeText(
        "暂时无法连接 GitHub，请稍后重试。", "Could not reach GitHub. Try again later."
    )
    private static let reconnectNotice = NativeText(
        "GitHub 授权已失效，请重新连接。", "Reconnect GitHub to continue."
    )
    private static let invalidToken = NativeText(
        "请输入以 github_pat_ 开头、无空白的细粒度令牌。",
        "Enter a fine-grained token beginning with github_pat_ with no whitespace."
    )
    private static let invalidStoredToken = NativeText(
        "本机保存的 GitHub 令牌格式无效，请重新连接。",
        "The saved GitHub token is invalid. Reconnect GitHub."
    )
    private static let readFailure = NativeText(
        "无法读取本机保存的 GitHub 令牌，请重试。",
        "Could not read the saved GitHub token on this phone. Try again."
    )
    private static let saveFailure = NativeText(
        "已验证令牌，但无法保存到钥匙串。请重试。",
        "The token was verified, but it could not be saved to the keychain. Try again."
    )
    private static let deleteFailure = NativeText(
        "已清除本机 GitHub 数据，但未能删除钥匙串里的令牌。请重试。",
        "GitHub data was cleared on this phone, but the keychain token could not be removed. Try again."
    )
}

struct GitHubConnectorPage: View {
    private let model = GitHubConnectorModel.shared
    @State private var token = ""
    @State private var confirmDisconnect = false

    private static let tokenPage = URL(
        string: "https://github.com/settings/personal-access-tokens/new"
    )!

    var body: some View {
        List {
            switch model.state {
            case .disconnected:
                tokenSection
            case .connecting:
                connectingSection
            case .connected(let login, let repos, let nextPage, let notice):
                accountSection(login)
                if let notice {
                    noticeSection(notice) { await model.retry() }
                }
                repositorySection(repos, nextPage: nextPage, notice: notice)
            }
            if let notice = model.connectionNotice {
                if model.canRetryRestore {
                    noticeSection(notice) { await model.restore() }
                } else {
                    noticeSection(notice)
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.restore() }
        .onDisappear { token = "" }
        .alert(NativeText("断开 GitHub？", "Disconnect GitHub?"), isPresented: $confirmDisconnect) {
            Button(NativeText("断开连接", "Disconnect"), role: .destructive) {
                model.disconnect()
            }
            Button(NativeText("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(NativeText("本机保存的 GitHub 令牌会被删除。",
                            "The GitHub token saved on this phone will be deleted."))
        }
    }

    private var tokenSection: some View {
        Section {
            SecureField(
                NativeText("github_pat_ 开头的细粒度令牌", "Fine-grained token starting with github_pat_"),
                text: $token
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("github.token")

            Button {
                let candidate = token
                Task {
                    await model.connect(token: candidate)
                    if case .connected = model.state { token = "" }
                }
            } label: {
                Label(NativeText("连接 GitHub", "Connect GitHub"),
                      systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(token.isEmpty || model.needsDeleteRetry)

            Link(destination: Self.tokenPage) {
                Label(NativeText("创建令牌", "Create token"), systemImage: "key")
            }
            .accessibilityIdentifier("github.createToken")
        } header: {
            Text(NativeText("GitHub 令牌", "GitHub token"))
        } footer: {
            Text(NativeText(
                "在 GitHub 创建 fine-grained token 时选择要读取的仓库，并只授予 Metadata 只读权限。令牌只保存在本机钥匙串。",
                "Create a fine-grained token on GitHub, select the repositories to read, and grant only read-only Metadata. The token stays in this phone's keychain."
            ))
        }
    }

    private var connectingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(NativeText("正在验证 GitHub 令牌…", "Verifying the GitHub token…"))
            }
        } header: {
            Text(NativeText("GitHub 令牌", "GitHub token"))
        } footer: {
            Text(NativeText("正在读取账号和仓库。", "Reading the account and repositories."))
        }
    }

    private func accountSection(_ login: String) -> some View {
        Section {
            Label(login, systemImage: "checkmark.circle")
                .accessibilityLabel(NativeText("已连接", "Connected") + " " + login)
            Button(role: .destructive) {
                confirmDisconnect = true
            } label: {
                Label(NativeText("断开连接", "Disconnect"),
                      systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Text(NativeText("GitHub 账号", "GitHub account"))
        } footer: {
            Text(NativeText("只读取登录名和仓库元数据。",
                            "Reads the login name and repository metadata only."))
        }
    }

    private func repositorySection(
        _ repos: [GitHubConnectorAPI.Repository], nextPage: Int?, notice: String?
    ) -> some View {
        Section {
            if repos.isEmpty {
                if model.loading {
                    ProgressView()
                } else if notice == nil {
                    Text(NativeText("没有可读取的仓库。", "No repositories available."))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(repos) { repo in
                    Link(destination: repo.htmlURL) {
                        HStack(spacing: 12) {
                            Image(systemName: "book.closed")
                                .foregroundStyle(HomeSpec.textSecondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: repo.name)
                                    .foregroundStyle(HomeSpec.textPrimary)
                                    .lineLimit(1)
                                Text(verbatim: repo.fullName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("github.repo.row")
                }
                if model.loading { ProgressView() }
            }
            if nextPage != nil, notice == nil, !model.loading {
                Button(NativeText("加载更多", "Load more")) {
                    Task { await model.loadMore() }
                }
            }
        } header: {
            Text(NativeText("仓库", "Repositories"))
        } footer: {
            Text(NativeText("按最近更新排序，每页 30 个。",
                            "Sorted by recently updated, 30 per page."))
        }
    }

    private func noticeSection(_ notice: String, retry: (() async -> Void)? = nil) -> some View {
        Section {
            Text(verbatim: notice)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button(NativeText("重试", "Retry")) {
                    Task { await retry() }
                }
                .disabled(model.loading)
            }
            if model.needsDeleteRetry {
                Button(NativeText("重试删除令牌", "Retry deleting token")) {
                    model.retryDelete()
                }
            }
        }
    }
}

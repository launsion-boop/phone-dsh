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
    private(set) var revocationFailed = false

    var isConfigured: Bool { Self.configuration != nil }
    var installationURL: URL? { Self.configuration?.installationURL }
    var revocationSettingsURL: URL? {
        revocationFailed ? GitHubOAuthConfiguration.authorizedAppSettingsURL : nil
    }

    private static let configuration = GitHubOAuthConfiguration(
        infoDictionary: Bundle.main.infoDictionary
    )
    private let api = GitHubConnectorAPI()
    private let webAuthorization = GitHubWebAuthorization()
    private let secrets = KeychainModelProviderSecretStore(service: "dev.phone-dsh.probe.github")
    private static let tokenReference = "access-token"
    private var epoch = UUID()
    private var activeToken: String?
    private var expiresAt: Date?
    private var connectTask: Task<Void, Never>?
    private var failedRepositoryLoad: (page: Int, append: Bool)?

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
        guard let token = stored else { return }
        guard GitHubConnectorAPI.isValidToken(token) else {
            // The previous build stored a fine-grained PAT in the same slot.
            // It cannot be used with the app-token API path, so discard it and
            // leave the page on the OAuth connect button.
            do {
                try secrets.deleteSecret(for: Self.tokenReference)
                needsDeleteRetry = false
                connectionNotice = Self.legacyTokenDiscarded
            } catch {
                needsDeleteRetry = true
                connectionNotice = Self.deleteFailure
            }
            return
        }
        guard isConfigured else { return }
        await authenticate(token: token, persist: false, expiresAt: nil)
    }

    func connect() {
        guard case .disconnected = state, !needsDeleteRetry else { return }
        guard let configuration = Self.configuration else {
            connectionNotice = Self.unconfiguredNotice
            return
        }

        connectTask?.cancel()
        let id = UUID()
        epoch = id
        activeToken = nil
        expiresAt = nil
        connectionNotice = nil
        canRetryRestore = false
        revocationFailed = false
        loading = false
        state = .connecting

        connectTask = Task { [weak self] in
            guard let self else { return }
            await self.authorize(configuration: configuration, id: id)
        }
    }

    /// Stop a session and exchange that have not completed. Called when the
    /// page goes away; it never changes an established connection.
    func cancelAuthorization() {
        guard case .connecting = state else { return }
        epoch = UUID()
        connectTask?.cancel()
        connectTask = nil
        webAuthorization.cancel()
        activeToken = nil
        expiresAt = nil
        loading = false
        canRetryRestore = false
        connectionNotice = nil
        state = .disconnected
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

    /// Re-read the first repository page after the user adds or removes
    /// repositories on GitHub's installation page.
    func refresh() async {
        guard case .connected(let login, let repos, let nextPage, _) = state, !loading
        else { return }
        guard let token = storedToken() else { return }
        let id = UUID()
        epoch = id
        state = .connected(login: login, repos: repos, nextPage: nextPage, notice: nil)
        await loadRepositories(page: 1, append: false, token: token, id: id)
    }

    func retry() async {
        guard case .connected = state, let request = failedRepositoryLoad, !loading else { return }
        guard let token = storedToken() else { return }
        let id = UUID()
        epoch = id
        await loadRepositories(page: request.page, append: request.append, token: token, id: id)
    }

    /// Clear the local token and results immediately, then ask the broker to
    /// revoke the token. A failed revoke leaves a GitHub app-settings link.
    func disconnect() {
        guard case .connected = state else { return }
        let token = activeToken
        let id = clearConnection(notice: nil)
        revocationFailed = false

        guard let token else { return }
        guard let configuration = Self.configuration else {
            revocationFailed = true
            connectionNotice = Self.revocationFailure
            return
        }
        let flow = GitHubOAuthFlow(configuration: configuration)
        Task { [weak self] in
            do {
                try await flow.revoke(token: token)
            } catch {
                guard let self, self.epoch == id else { return }
                self.revocationFailed = true
                if self.connectionNotice == nil {
                    self.connectionNotice = Self.revocationFailure
                }
            }
        }
    }

    private func authorize(configuration: GitHubOAuthConfiguration, id: UUID) async {
        do {
            let attempt = try GitHubOAuthPKCE.makeAttempt()
            guard epoch == id else { return }
            guard let url = configuration.authorizationURL(
                state: attempt.state, codeChallenge: attempt.challenge
            ) else { throw GitHubOAuthError.invalidConfiguration }

            let callbackURL = try await webAuthorization.start(
                url: url, callbackScheme: GitHubOAuthConfiguration.callbackScheme
            )
            guard epoch == id else { return }

            let callback = try GitHubOAuthCallbackValidator.validate(
                callbackURL, expectedState: attempt.state
            )
            switch callback {
            case .accessDenied:
                state = .disconnected
                loading = false
                connectionNotice = Self.authorizationDenied
            case .code(let code):
                let token = try await GitHubOAuthFlow(configuration: configuration)
                    .exchange(code: code, codeVerifier: attempt.verifier)
                guard epoch == id else { return }
                await authenticate(
                    token: token.accessToken,
                    persist: true,
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
                )
            }
        } catch let error as GitHubWebAuthorizationError {
            guard epoch == id else { return }
            state = .disconnected
            loading = false
            connectionNotice = error == .cancelled ? nil : Self.genericFailure
        } catch let error as GitHubOAuthError {
            guard epoch == id else { return }
            state = .disconnected
            loading = false
            connectionNotice = error == .cancelled ? nil : Self.oauthNotice(for: error)
        } catch is CancellationError {
            guard epoch == id else { return }
            state = .disconnected
            loading = false
        } catch {
            guard epoch == id else { return }
            state = .disconnected
            loading = false
            connectionNotice = Self.genericFailure
        }
    }

    private func authenticate(token: String, persist: Bool, expiresAt: Date?) async {
        guard GitHubConnectorAPI.isValidToken(token) else {
            state = .disconnected
            connectionNotice = Self.legacyTokenDiscarded
            return
        }

        let id = UUID()
        epoch = id
        connectionNotice = nil
        canRetryRestore = false
        revocationFailed = false
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
            activeToken = token
            self.expiresAt = expiresAt
            state = .connected(login: login, repos: [], nextPage: nil, notice: nil)
            await loadRepositories(page: 1, append: false, token: token, id: id)
        } catch {
            guard epoch == id else { return }
            state = .disconnected
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if (error as? GitHubConnectorError) == .unauthorized {
                clearConnection(notice: Self.reconnectNotice)
            } else {
                connectionNotice = Self.connectorNotice(for: error)
                canRetryRestore = !persist
            }
        }
    }

    private func loadRepositories(page: Int, append: Bool, token: String, id: UUID) async {
        guard epoch == id,
              case .connected(let login, let current, let nextPage, _) = state
        else { return }
        loading = true
        failedRepositoryLoad = nil
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
                activeToken = nil
                expiresAt = nil
                state = .disconnected
                return
            }
            if (error as? GitHubConnectorError) == .unauthorized {
                clearConnection(notice: Self.reconnectNotice)
            } else {
                failedRepositoryLoad = (page, append)
                state = .connected(
                    login: login, repos: current, nextPage: nextPage,
                    notice: Self.connectorNotice(for: error)
                )
            }
        }
    }

    private func clearConnection(notice: String?) -> UUID {
        let id = UUID()
        epoch = id
        loading = false
        failedRepositoryLoad = nil
        canRetryRestore = false
        activeToken = nil
        expiresAt = nil
        state = .disconnected
        connectionNotice = notice
        do {
            try secrets.deleteSecret(for: Self.tokenReference)
            needsDeleteRetry = false
        } catch {
            needsDeleteRetry = true
            connectionNotice = Self.deleteFailure
        }
        return id
    }

    func retryDelete() {
        guard needsDeleteRetry else { return }
        do {
            try secrets.deleteSecret(for: Self.tokenReference)
            needsDeleteRetry = false
            if case .disconnected = state, !revocationFailed {
                connectionNotice = nil
            }
        } catch {
            connectionNotice = Self.deleteFailure
        }
    }

    private func storedToken() -> String? {
        if let expiresAt, expiresAt <= Date() {
            clearConnection(notice: Self.reconnectNotice)
            return nil
        }
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
        activeToken = nil
        expiresAt = nil
        state = .disconnected
        connectionNotice = Self.reconnectNotice
        return nil
    }

    private static func connectorNotice(for error: Error) -> String {
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
                "GitHub 拒绝访问。请确认 GitHub App 已获得仓库权限，然后重新连接。",
                "GitHub denied access. Check that the GitHub App can read repositories, then reconnect."
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

    private static func oauthNotice(for error: GitHubOAuthError) -> String {
        switch error {
        case .invalidConfiguration:
            return unconfiguredNotice
        case .invalidToken:
            return invalidAuthorization
        case .invalidState, .invalidCode, .invalidVerifier, .invalidCallback,
             .stateMismatch, .invalidRequest, .authorizationFailed:
            return authorizationFailure
        case .invalidResponse, .serviceUnavailable, .randomUnavailable:
            return genericFailure
        case .cancelled:
            return genericFailure
        }
    }

    private static let genericFailure = NativeText(
        "暂时无法连接 GitHub，请稍后重试。", "Could not reach GitHub. Try again later."
    )
    private static let reconnectNotice = NativeText(
        "GitHub 授权已失效，请重新连接。", "Reconnect GitHub to continue."
    )
    private static let authorizationFailure = NativeText(
        "GitHub 授权未能完成，请重试。", "GitHub authorization could not be completed. Try again."
    )
    private static let invalidAuthorization = NativeText(
        "GitHub 返回了无效的授权，请重试。", "GitHub returned an invalid authorization. Try again."
    )
    private static let authorizationDenied = NativeText(
        "你取消了 GitHub 授权。", "GitHub authorization was cancelled."
    )
    private static let unconfiguredNotice = NativeText(
        "此构建未配置 GitHub OAuth 服务。", "This build is not configured for GitHub OAuth."
    )
    private static let legacyTokenDiscarded = NativeText(
        "已清除旧的 GitHub 令牌，请重新连接。",
        "The old GitHub token was cleared. Reconnect GitHub."
    )
    private static let readFailure = NativeText(
        "无法读取本机保存的 GitHub 令牌，请重试。",
        "Could not read the saved GitHub token on this phone. Try again."
    )
    private static let saveFailure = NativeText(
        "已验证授权，但无法保存到钥匙串。请重试。",
        "The authorization was verified, but it could not be saved to the keychain. Try again."
    )
    private static let deleteFailure = NativeText(
        "已清除本机 GitHub 数据，但未能删除钥匙串里的令牌。请重试。",
        "GitHub data was cleared on this phone, but the keychain token could not be removed. Try again."
    )
    private static let revocationFailure = NativeText(
        "本机已断开 GitHub，但未能撤销服务器上的授权。可在 GitHub 应用设置中撤销。",
        "GitHub was disconnected on this phone, but the server could not revoke the authorization. Revoke it in GitHub app settings."
    )
}

struct GitHubConnectorPage: View {
    private let model = GitHubConnectorModel.shared
    @State private var confirmDisconnect = false

    var body: some View {
        List {
            switch model.state {
            case .disconnected:
                disconnectedSection
            case .connecting:
                connectingSection
            case .connected(let login, let repos, let nextPage, let notice):
                accountSection(login)
                repositoryAccessSection
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
        .onDisappear { model.cancelAuthorization() }
        .alert(NativeText("断开 GitHub？", "Disconnect GitHub?"), isPresented: $confirmDisconnect) {
            Button(NativeText("断开连接", "Disconnect"), role: .destructive) {
                model.disconnect()
            }
            Button(NativeText("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(NativeText(
                "Phone DSH 会清除本机连接，并请求 GitHub 撤销本次访问。",
                "Phone DSH clears this connection and asks GitHub to revoke this session."
            ))
        }
    }

    private var disconnectedSection: some View {
        Section {
            if !model.isConfigured {
                Text(NativeText(
                    "此版本暂未启用 GitHub 连接。",
                    "GitHub connection is unavailable in this build."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("github.unconfigured")
            }

            Button {
                model.connect()
            } label: {
                Label(NativeText("连接 GitHub", "Connect GitHub"),
                      systemImage: "person.crop.circle.badge.plus")
            }
            .accessibilityIdentifier("github.connect")
            .disabled(!model.isConfigured || model.needsDeleteRetry)
        } header: {
            Text(NativeText("GitHub 账号", "GitHub account"))
        } footer: {
            if model.isConfigured {
                Text(NativeText(
                    "连接后，在 GitHub 选择允许 Phone DSH 读取的仓库。",
                    "Connect to GitHub, then choose the repositories Phone DSH can read."
                ))
            } else {
                Text(NativeText(
                    "请在此构建中配置 GitHub OAuth 后再连接。",
                    "Set up GitHub OAuth in this build before connecting."
                ))
            }
        }
    }

    private var connectingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(NativeText("正在等待 GitHub 授权…", "Waiting for GitHub authorization…"))
            }
        } header: {
            Text(NativeText("GitHub 账号", "GitHub account"))
        } footer: {
            Text(NativeText("授权完成后会读取账号和你选择的仓库。",
                            "The account and your selected repositories are read after authorization."))
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
            .accessibilityIdentifier("github.disconnect")
        } header: {
            Text(NativeText("GitHub 账号", "GitHub account"))
        } footer: {
            Text(NativeText("只读取登录名和你选择的仓库元数据。",
                            "Reads the login name and metadata of the repositories you selected."))
        }
    }

    private var repositoryAccessSection: some View {
        Section {
            if let installationURL = model.installationURL {
                Link(destination: installationURL) {
                    Label(NativeText("在 GitHub 选择仓库", "Choose repositories on GitHub"),
                          systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("github.install")
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label(NativeText("刷新仓库", "Refresh repositories"),
                      systemImage: "arrow.clockwise")
            }
            .disabled(model.loading)
            .accessibilityIdentifier("github.refresh")
        } header: {
            Text(NativeText("仓库授权", "Repository access"))
        } footer: {
            Text(NativeText(
                "在 GitHub 上安装或配置 GitHub App 并选择仓库，然后刷新这里。",
                "Install or configure the GitHub App on GitHub, choose repositories, then refresh here."
            ))
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
                .accessibilityIdentifier("github.loadMore")
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
            if let settingsURL = model.revocationSettingsURL {
                Link(destination: settingsURL) {
                    Label(NativeText("打开 GitHub 应用设置", "Open GitHub app settings"),
                          systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("github.appSettings")
            }
        }
    }
}

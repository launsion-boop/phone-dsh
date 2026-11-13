// SPDX-License-Identifier: MIT

import Observation
import PhoneDSH
import ProbeKit
import SwiftUI

@MainActor
@Observable
final class FeishuConnectorModel {
    static let shared = FeishuConnectorModel()

    enum State {
        case disconnected
        case connecting
        case connected(name: String, files: [FeishuConnectorAPI.File], notice: String?)
    }

    private(set) var state: State = .disconnected
    private(set) var connectionNotice: String?
    private(set) var loading = false
    private(set) var needsDeleteRetry = false
    private(set) var canRetryRestore = false
    private(set) var revocationFailed = false

    var isConfigured: Bool { Self.configuration != nil }

    private static let configuration = FeishuOAuthConfiguration(
        infoDictionary: Bundle.main.infoDictionary
    )
    private let api = FeishuConnectorAPI()
    private let webAuthorization = FeishuWebAuthorization()
    private let secrets = KeychainModelProviderSecretStore(service: "dev.phone-dsh.probe.feishu")
    private static let accessReference = "access-token"
    private static let refreshReference = "refresh-token"
    private var epoch = UUID()
    private var activeToken: String?
    private var connectTask: Task<Void, Never>?

    func restore() async {
        guard case .disconnected = state, !needsDeleteRetry else { return }
        canRetryRestore = false

        let stored: String?
        do {
            stored = try secrets.secret(for: Self.accessReference)
        } catch {
            connectionNotice = Self.readFailure
            canRetryRestore = true
            return
        }
        guard isConfigured else { return }
        if let token = stored, FeishuConnectorAPI.isValidToken(token) {
            await authenticate(token: token, persist: false, allowRefresh: true)
            return
        }
        // The access token is gone or unusable, but a refresh token may still
        // reopen the connection without another browser round trip.
        await restoreFromRefreshToken()
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
        loading = false
        canRetryRestore = false
        connectionNotice = nil
        state = .disconnected
    }

    /// Re-read the cloud space after the user changes files or permissions in
    /// Feishu.
    func refresh() async {
        guard case .connected(let name, let files, _) = state, !loading else { return }
        guard let token = activeToken else { return }
        let id = UUID()
        epoch = id
        state = .connected(name: name, files: files, notice: nil)
        await loadFiles(token: token, id: id)
    }

    func retry() async {
        guard case .connected = state, !loading, let token = activeToken else { return }
        let id = UUID()
        epoch = id
        await loadFiles(token: token, id: id)
    }

    /// Clear the local tokens immediately, then ask the broker to revoke the
    /// Feishu token. A failed revoke leaves a fixed notice, never a raw error.
    func disconnect() {
        guard case .connected = state else { return }
        let token = activeToken
        let refreshToken = try? secrets.secret(for: Self.refreshReference)
        let id = clearConnection(notice: nil)
        revocationFailed = false

        guard let token else { return }
        guard let configuration = Self.configuration else {
            revocationFailed = true
            connectionNotice = Self.revocationFailure
            return
        }
        let flow = FeishuOAuthFlow(configuration: configuration)
        Task { [weak self] in
            do {
                try await flow.revoke(token: token)
                if let value = refreshToken, FeishuConnectorAPI.isValidToken(value) {
                    // Revoking the access token leaves the refresh grant alive;
                    // revoke it too so "disconnect" really ends the session.
                    try await flow.revoke(token: value)
                }
            } catch {
                guard let self, self.epoch == id else { return }
                self.revocationFailed = true
                if self.connectionNotice == nil {
                    self.connectionNotice = Self.revocationFailure
                }
            }
        }
    }

    func retryDelete() {
        guard needsDeleteRetry else { return }
        do {
            try secrets.deleteSecret(for: Self.accessReference)
            try secrets.deleteSecret(for: Self.refreshReference)
            needsDeleteRetry = false
            if case .disconnected = state, !revocationFailed {
                connectionNotice = nil
            }
        } catch {
            connectionNotice = Self.deleteFailure
        }
    }

    private func authorize(configuration: FeishuOAuthConfiguration, id: UUID) async {
        do {
            let attempt = try FeishuOAuthPKCE.makeAttempt()
            guard epoch == id else { return }
            guard let url = configuration.authorizationURL(
                state: attempt.state, codeChallenge: attempt.challenge
            ) else { throw FeishuOAuthError.invalidConfiguration }

            let callbackURL = try await webAuthorization.start(
                url: url, callbackScheme: FeishuOAuthConfiguration.callbackScheme
            )
            guard epoch == id else { return }

            let callback = try FeishuOAuthCallbackValidator.validate(
                callbackURL, expectedState: attempt.state
            )
            switch callback {
            case .accessDenied:
                state = .disconnected
                loading = false
                connectionNotice = Self.authorizationDenied
            case .code(let code):
                let token = try await FeishuOAuthFlow(configuration: configuration)
                    .exchange(code: code, codeVerifier: attempt.verifier)
                guard epoch == id else { return }
                if let refresh = token.refreshToken {
                    try? secrets.setSecret(refresh, for: Self.refreshReference)
                }
                await authenticate(token: token.accessToken, persist: true, allowRefresh: false)
            }
        } catch let error as FeishuWebAuthorizationError {
            guard epoch == id else { return }
            state = .disconnected
            loading = false
            connectionNotice = error == .cancelled ? nil : Self.genericFailure
        } catch let error as FeishuOAuthError {
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

    private func authenticate(token: String, persist: Bool, allowRefresh: Bool) async {
        guard FeishuConnectorAPI.isValidToken(token) else {
            state = .disconnected
            connectionNotice = Self.reconnectNotice
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
            let account = try await api.account(token: token)
            guard epoch == id else { return }
            guard !Task.isCancelled else {
                state = .disconnected
                return
            }
            if persist {
                do {
                    try secrets.setSecret(token, for: Self.accessReference)
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
            state = .connected(name: account.name, files: [], notice: nil)
            await loadFiles(token: token, id: id)
        } catch {
            guard epoch == id else { return }
            state = .disconnected
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if (error as? FeishuConnectorError) == .unauthorized {
                if allowRefresh, await restoreFromRefreshToken() { return }
                clearConnection(notice: Self.reconnectNotice)
            } else {
                connectionNotice = Self.connectorNotice(for: error)
                canRetryRestore = !persist
            }
        }
    }

    /// Ask the broker for a fresh access token. Returns true when the session
    /// is usable again; false leaves the page on the connect button.
    @discardableResult
    private func restoreFromRefreshToken() async -> Bool {
        guard case .disconnected = state else { return false }
        guard let configuration = Self.configuration else { return false }
        let stored = try? secrets.secret(for: Self.refreshReference)
        guard let refreshToken = stored, FeishuConnectorAPI.isValidToken(refreshToken) else {
            return false
        }
        let id = UUID()
        epoch = id
        connectionNotice = nil
        loading = false
        state = .connecting
        do {
            let token = try await FeishuOAuthFlow(configuration: configuration)
                .refresh(refreshToken: refreshToken)
            guard epoch == id else { return true }
            if let next = token.refreshToken {
                try? secrets.setSecret(next, for: Self.refreshReference)
            }
            await authenticate(token: token.accessToken, persist: true, allowRefresh: false)
            return true
        } catch {
            guard epoch == id else { return true }
            if case .connecting = state {
                state = .disconnected
            }
            connectionNotice = Self.reconnectNotice
            return false
        }
    }

    private func loadFiles(token: String, id: UUID) async {
        guard epoch == id,
              case .connected(let name, let current, _) = state
        else { return }
        loading = true
        defer { if epoch == id { loading = false } }
        do {
            let files = try await api.files(token: token)
            guard epoch == id, case .connected = state else { return }
            state = .connected(name: name, files: files, notice: nil)
        } catch {
            guard epoch == id else { return }
            if Task.isCancelled || error is CancellationError {
                activeToken = nil
                state = .disconnected
                return
            }
            if (error as? FeishuConnectorError) == .unauthorized {
                if await restoreFromRefreshToken() { return }
                clearConnection(notice: Self.reconnectNotice)
            } else {
                state = .connected(
                    name: name, files: current, notice: Self.connectorNotice(for: error)
                )
            }
        }
    }

    private func clearConnection(notice: String?) -> UUID {
        let id = UUID()
        epoch = id
        loading = false
        canRetryRestore = false
        activeToken = nil
        state = .disconnected
        connectionNotice = notice
        do {
            try secrets.deleteSecret(for: Self.accessReference)
            try secrets.deleteSecret(for: Self.refreshReference)
            needsDeleteRetry = false
        } catch {
            needsDeleteRetry = true
            connectionNotice = Self.deleteFailure
        }
        return id
    }

    private static func connectorNotice(for error: Error) -> String {
        guard let error = error as? FeishuConnectorError else { return genericFailure }
        switch error {
        case .unauthorized:
            return reconnectNotice
        case .rateLimited:
            return NativeText(
                "飞书暂时限制了请求频率，请稍后重试。",
                "Feishu is temporarily rate limiting requests. Try again later."
            )
        case .forbidden:
            return NativeText(
                "飞书拒绝访问。请在飞书开放平台确认应用已开通云文档读取权限，然后重新连接。",
                "Feishu denied access. Check that the app may read cloud documents, then reconnect."
            )
        case .invalidResponse:
            return NativeText(
                "飞书返回了无法读取的数据，请稍后重试。",
                "Feishu returned unreadable data. Try again later."
            )
        case .serviceUnavailable:
            return genericFailure
        }
    }

    private static func oauthNotice(for error: FeishuOAuthError) -> String {
        switch error {
        case .invalidConfiguration:
            return unconfiguredNotice
        case .notConfigured:
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
        "暂时无法连接飞书，请稍后重试。", "Could not reach Feishu. Try again later."
    )
    private static let reconnectNotice = NativeText(
        "飞书授权已失效，请重新连接。", "Reconnect Feishu to continue."
    )
    private static let authorizationFailure = NativeText(
        "飞书授权未能完成，请重试。", "Feishu authorization could not be completed. Try again."
    )
    private static let invalidAuthorization = NativeText(
        "飞书返回了无效的授权，请重试。", "Feishu returned an invalid authorization. Try again."
    )
    private static let authorizationDenied = NativeText(
        "你取消了飞书授权。", "Feishu authorization was cancelled."
    )
    private static let unconfiguredNotice = NativeText(
        "此构建未配置飞书连接服务。", "This build is not configured for the Feishu connector."
    )
    private static let readFailure = NativeText(
        "无法读取本机保存的飞书令牌，请重试。",
        "Could not read the saved Feishu token on this phone. Try again."
    )
    private static let saveFailure = NativeText(
        "已验证授权，但无法保存到钥匙串。请重试。",
        "The authorization was verified, but it could not be saved to the keychain. Try again."
    )
    private static let deleteFailure = NativeText(
        "已清除本机飞书数据，但未能删除钥匙串里的令牌。请重试。",
        "Feishu data was cleared on this phone, but the keychain token could not be removed. Try again."
    )
    private static let revocationFailure = NativeText(
        "本机已断开飞书，但未能撤销服务器上的授权。可在飞书中取消应用授权。",
        "Feishu was disconnected on this phone, but the server could not revoke the authorization. Revoke the app in Feishu."
    )
}

struct FeishuConnectorPage: View {
    private let model = FeishuConnectorModel.shared
    @State private var confirmDisconnect = false

    var body: some View {
        List {
            switch model.state {
            case .disconnected:
                disconnectedSection
            case .connecting:
                connectingSection
            case .connected(let name, let files, let notice):
                accountSection(name)
                if let notice {
                    noticeSection(notice) { await model.retry() }
                }
                filesSection(files)
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
        .navigationTitle("飞书")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.restore() }
        .onDisappear { model.cancelAuthorization() }
        .alert(NativeText("断开飞书？", "Disconnect Feishu?"), isPresented: $confirmDisconnect) {
            Button(NativeText("断开连接", "Disconnect"), role: .destructive) {
                model.disconnect()
            }
            Button(NativeText("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(NativeText(
                "Phone DSH 会清除本机令牌，并请求飞书撤销本次授权。",
                "Phone DSH clears the tokens on this phone and asks Feishu to revoke this authorization."
            ))
        }
    }

    private var disconnectedSection: some View {
        Section {
            if !model.isConfigured {
                Text(NativeText(
                    "此版本暂未启用飞书连接。",
                    "The Feishu connector is unavailable in this build."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("feishu.unconfigured")
            }

            Button {
                model.connect()
            } label: {
                Label(NativeText("连接飞书", "Connect Feishu"),
                      systemImage: "person.crop.circle.badge.plus")
            }
            .accessibilityIdentifier("feishu.connect")
            .disabled(!model.isConfigured || model.needsDeleteRetry)
        } header: {
            Text(NativeText("飞书账号", "Feishu account"))
        } footer: {
            if model.isConfigured {
                Text(NativeText(
                    "连接后在飞书完成授权，Phone DSH 只读取你的云文档清单。",
                    "Authorize in Feishu; Phone DSH only reads your cloud space listing."
                ))
            } else {
                Text(NativeText(
                    "请在此构建中配置飞书连接服务后再连接。",
                    "Set up the Feishu connector service in this build before connecting."
                ))
            }
        }
    }

    private var connectingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(NativeText("正在等待飞书授权…", "Waiting for Feishu authorization…"))
            }
        } header: {
            Text(NativeText("飞书账号", "Feishu account"))
        } footer: {
            Text(NativeText("授权完成后会读取账号和云文档清单。",
                            "The account and the cloud space listing are read after authorization."))
        }
    }

    private func accountSection(_ name: String) -> some View {
        Section {
            Label(name, systemImage: "checkmark.circle")
                .accessibilityLabel(NativeText("已连接", "Connected") + " " + name)
            Button(role: .destructive) {
                confirmDisconnect = true
            } label: {
                Label(NativeText("断开连接", "Disconnect"),
                      systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("feishu.disconnect")
        } header: {
            Text(NativeText("飞书账号", "Feishu account"))
        } footer: {
            Text(NativeText("只读取登录人姓名和你云空间根目录的文档清单。",
                            "Reads the signed-in name and the file listing of your cloud space root."))
        }
    }

    private func filesSection(_ files: [FeishuConnectorAPI.File]) -> some View {
        Section {
            if files.isEmpty {
                if model.loading {
                    ProgressView()
                } else {
                    Text(NativeText("没有可读取的云文档。", "No cloud documents available."))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(files) { file in
                    fileRow(file)
                        .accessibilityIdentifier("feishu.file.row")
                }
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Label(NativeText("刷新云文档", "Refresh documents"),
                      systemImage: "arrow.clockwise")
            }
            .disabled(model.loading)
            .accessibilityIdentifier("feishu.refresh")
        } header: {
            Text(NativeText("云文档", "Cloud documents"))
        } footer: {
            Text(NativeText("按最近编辑排序，只列出根目录，不下载文件内容。",
                            "Sorted by last edited; root only, and no file content is downloaded."))
        }
    }

    @ViewBuilder
    private func fileRow(_ file: FeishuConnectorAPI.File) -> some View {
        if let url = file.url {
            Link(destination: url) {
                fileRowLabel(file, showsArrow: true)
            }
        } else {
            fileRowLabel(file, showsArrow: false)
        }
    }

    private func fileRowLabel(_ file: FeishuConnectorAPI.File, showsArrow: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: glyph(for: file.type))
                .foregroundStyle(HomeSpec.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: file.name)
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                Text(verbatim: file.typeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if showsArrow {
                Image(systemName: "arrow.up.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func glyph(for type: String) -> String {
        switch type {
        case "doc", "docx": return "doc.text"
        case "sheet": return "tablecells"
        case "bitable": return "square.grid.2x2"
        case "mindnote": return "brain"
        case "folder": return "folder"
        case "shortcut": return "arrowshape.turn.up.right"
        default: return "doc"
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
                Button(NativeText("重试删除令牌", "Retry deleting tokens")) {
                    model.retryDelete()
                }
            }
        }
    }
}

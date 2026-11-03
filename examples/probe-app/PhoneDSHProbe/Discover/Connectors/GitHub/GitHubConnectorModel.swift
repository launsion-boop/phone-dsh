// SPDX-License-Identifier: MIT

import Combine
import Foundation
import ProbeKit

@MainActor
public final class GitHubConnectorModel: ObservableObject {
    @Published public private(set) var record: ConnectorRecord
    @Published public private(set) var grant: ConnectorGrant?
    @Published public private(set) var maskedAccount: String?
    @Published public var allowsComments = false
    @Published public var allowsIssueCreation = false
    @Published public private(set) var busy = false

    private let registry: PersistentConnectorRegistry
    private let client: GitHubClient
    private let credentials: any ConnectorCredentialStore
    private let credentialRef: String

    public init(registry: PersistentConnectorRegistry,
                client: GitHubClient,
                credentials: any ConnectorCredentialStore,
                credentialRef: String = "github.pat") {
        self.registry = registry
        self.client = client
        self.credentials = credentials
        self.credentialRef = credentialRef
        record = ConnectorRecord(connectorID: GitHubToolBridge.connectorID, state: .disconnected)
    }

    public func refresh() async {
        record = await registry.state(of: GitHubToolBridge.connectorID)
        grant = await registry.grant(of: GitHubToolBridge.connectorID)
    }

    public func connect(pat: String, repositoriesText: String) async {
        guard !pat.isEmpty else {
            record = ConnectorRecord(connectorID: GitHubToolBridge.connectorID,
                                     state: .needsAttention, issue: "请输入 fine-grained PAT")
            return
        }
        let repositories = Array(Set(repositoriesText
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map(String.init))).sorted()
        guard !repositories.isEmpty else {
            record = ConnectorRecord(connectorID: GitHubToolBridge.connectorID,
                                     state: .needsAttention, issue: "请至少选择一个授权仓库")
            return
        }
        busy = true
        defer { busy = false }
        do {
            try credentials.saveCredential(pat, for: credentialRef)
            var actions: Set<MandateAction> = [.read]
            if allowsComments { actions.insert(.githubComment) }
            if allowsIssueCreation { actions.insert(.githubCreateIssue) }
            let grant = ConnectorGrant(connectorID: GitHubToolBridge.connectorID, version: (grant?.version ?? 0) + 1,
                                       allowedActions: actions,
                                       scope: GrantScope(repositories: repositories))
            record = try await registry.connect(GitHubToolBridge.connectorID, grant: grant,
                                                credentialRef: credentialRef) {
                do {
                    _ = try await client.verify(repositories: repositories)
                } catch let error as GitHubClientError {
                    throw ConnectorVerificationFailure(state: error == .unauthorized ? .expired : .needsAttention,
                                                       issue: error.message)
                }
            }
            let actor = try await client.verify(repositories: [])
            maskedAccount = Self.mask(actor.login)
            self.grant = grant
        } catch let error as ConnectorRegistryError {
            try? credentials.deleteCredential(for: credentialRef)
            await refresh()
            if case .verificationFailed = error { return }
            record = ConnectorRecord(connectorID: GitHubToolBridge.connectorID,
                                     state: .needsAttention, issue: "GitHub 连接失败，请重试")
        } catch {
            try? credentials.deleteCredential(for: credentialRef)
            record = ConnectorRecord(connectorID: GitHubToolBridge.connectorID,
                                     state: .needsAttention, issue: "GitHub 连接失败，请重试")
        }
    }

    public func revoke() async {
        busy = true
        defer { busy = false }
        do {
            try await registry.revoke(GitHubToolBridge.connectorID)
            maskedAccount = nil
            await refresh()
        } catch {
            record = ConnectorRecord(connectorID: GitHubToolBridge.connectorID,
                                     state: .needsAttention,
                                     issue: "撤权清理未完成，请解锁设备后重试")
        }
    }

    private static func mask(_ account: String) -> String {
        guard let first = account.first else { return "已核验账号" }
        return "\(first)***"
    }
}

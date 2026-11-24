// SPDX-License-Identifier: MIT
// MCPConnectorService: connect / disconnect the hosted MCP connectors in
// `PhoneMCPConnectorCatalog` (docs/design-connectors-2026-11-24.md §5).
//
// OAuth runs here, in the app process. The token is written only to the
// connector Keychain service and handed to the gateway through a
// `PhoneMCPOAuthTokenSource` on the live `MCPEgressPolicy`. The Worker row is
// written through `MCPSettingsModel`, so it reuses the existing staged-grant
// transaction (stage → phone/mcpUpsert → commit, or rollback) and carries only
// the host-managed placeholder for `Authorization`.

import Foundation
import Observation
import PhoneDSH
import PhoneDSHAgentCore
import ProbeKit

enum MCPConnectorState: Equatable {
    case notConnected
    case connecting
    case connected
    /// A stored grant exists but its refresh token was rejected.
    case needsReauth
}

@MainActor
@Observable
final class MCPConnectorService {
    static let shared = MCPConnectorService()

    private(set) var states: [String: MCPConnectorState] = [:]
    private(set) var errorText: [String: String] = [:]

    @ObservationIgnored private let store: PhoneMCPOAuthStore
    @ObservationIgnored private let client: PhoneMCPOAuthClient
    @ObservationIgnored private let authorization = GitHubWebAuthorization()
    @ObservationIgnored private let livePolicy: @MainActor () -> MCPEgressPolicy?
    @ObservationIgnored private let makeModel: @MainActor () -> MCPSettingsModel

    init(store: PhoneMCPOAuthStore = PhoneMCPOAuthStore(),
         client: PhoneMCPOAuthClient = PhoneMCPOAuthClient(clientName: "Phone DSH"),
         livePolicy: @escaping @MainActor () -> MCPEgressPolicy? = {
             ChatModel.shared.isStarted ? ChatModel.shared.mcpAccessPolicy : nil
         },
         makeModel: @escaping @MainActor () -> MCPSettingsModel = {
             MCPSettingsModel(settings: .shared,
                              isHostRunning: { ChatModel.shared.isStarted },
                              makeTransport: { try await ChatModel.shared.transportForManagement() },
                              refreshPolicy: { ChatModel.shared.refreshMCPAccessPolicy() })
         }) {
        self.store = store
        self.client = client
        self.livePolicy = livePolicy
        self.makeModel = makeModel
        for connector in PhoneMCPConnectorCatalog.all {
            states[connector.id] = ((try? store.record(for: connector.id)) ?? nil) == nil
                ? .notConnected : .connected
        }
    }

    func state(_ connector: PhoneMCPConnector) -> MCPConnectorState {
        states[connector.id] ?? .notConnected
    }

    /// Called by ChatModel after each host launch creates its policy, so a
    /// saved grant is usable again without the user reconnecting.
    func installSources(into policy: MCPEgressPolicy) {
        for connector in PhoneMCPConnectorCatalog.all {
            guard let record = (try? store.record(for: connector.id)) ?? nil else {
                policy.setDynamicCredentialSource(nil, serverName: connector.serverName)
                continue
            }
            policy.setDynamicCredentialSource(makeSource(connector, record: record),
                                              serverName: connector.serverName)
        }
    }

    func connect(_ connector: PhoneMCPConnector) async {
        guard state(connector) != .connecting else { return }
        errorText[connector.id] = nil
        guard ChatModel.shared.isStarted else {
            errorText[connector.id] = NativeText("请先启动本地引擎，再连接。", "Start the local engine first.")
            return
        }
        states[connector.id] = .connecting
        do {
            let record = try await authorize(connector)
            try store.save(record, for: connector.id)
            livePolicy()?.setDynamicCredentialSource(makeSource(connector, record: record),
                                                     serverName: connector.serverName)
            let model = makeModel()
            await model.save(Self.draft(for: connector), allowReservedServerName: true)
            if let failure = model.errorText {
                // The Worker row did not commit: drop the grant we just made so
                // no token is left without a row that uses it.
                livePolicy()?.setDynamicCredentialSource(nil, serverName: connector.serverName)
                try? store.delete(connector.id)
                states[connector.id] = .notConnected
                errorText[connector.id] = failure
                return
            }
            states[connector.id] = .connected
        } catch GitHubWebAuthorizationError.cancelled {
            let hadGrant = ((try? store.record(for: connector.id)) ?? nil) != nil
            states[connector.id] = hadGrant ? .needsReauth : .notConnected
        } catch {
            states[connector.id] = .notConnected
            errorText[connector.id] = error.localizedDescription
        }
    }

    func disconnect(_ connector: PhoneMCPConnector) async {
        errorText[connector.id] = nil
        let model = makeModel()
        await model.refresh()
        if let row = model.rows.first(where: { $0.serverName == connector.serverName }) {
            await model.remove(row)
            if let failure = model.errorText {
                errorText[connector.id] = failure
                return
            }
        } else if let failure = model.errorText, ChatModel.shared.isStarted {
            errorText[connector.id] = failure
            return
        }
        livePolicy()?.setDynamicCredentialSource(nil, serverName: connector.serverName)
        do {
            try store.delete(connector.id)
            states[connector.id] = .notConnected
        } catch {
            errorText[connector.id] = error.localizedDescription
        }
    }

    // MARK: Internals

    private func authorize(_ connector: PhoneMCPConnector) async throws -> PhoneMCPOAuthRecord {
        let redirect = PhoneMCPConnectorCatalog.redirectURI(for: connector)
        // Reuse a stored client registration; rediscover only when absent.
        let registration: PhoneMCPOAuthRegistration
        if let existing = (try? store.record(for: connector.id)) ?? nil,
           existing.registration.redirectURI == redirect {
            registration = existing.registration
        } else {
            let metadata = try await client.discover(resource: connector.url)
            registration = try await client.register(metadata, redirectURI: redirect, scope: connector.scope)
        }
        let attempt = client.begin(registration, scope: connector.scope)
        let callback = try await authorization.start(url: attempt.url,
                                                     callbackScheme: PhoneMCPConnectorCatalog.callbackScheme)
        return try await client.finish(attempt, callback: callback)
    }

    private func makeSource(_ connector: PhoneMCPConnector,
                            record: PhoneMCPOAuthRecord) -> PhoneMCPOAuthTokenSource {
        let id = connector.id
        return PhoneMCPOAuthTokenSource(
            connectorID: id, record: record, store: store, client: client,
            onReauthorizationRequired: {
                Task { @MainActor in MCPConnectorService.shared.markNeedsReauth(id) }
            })
    }

    private func markNeedsReauth(_ connectorID: String) {
        states[connectorID] = .needsReauth
    }

    static func draft(for connector: PhoneMCPConnector) -> MCPServerDraft {
        MCPServerDraft(serverName: connector.serverName,
                       url: connector.url.absoluteString,
                       enabled: true,
                       toolCallTimeoutMs: "60000",
                       headers: [MCPHeaderDraft(name: "Authorization",
                                                envName: connector.envName,
                                                value: "",
                                                hasStoredValue: false)])
    }
}

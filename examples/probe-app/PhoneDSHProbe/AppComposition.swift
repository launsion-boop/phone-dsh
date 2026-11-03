// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhoneDSH
import PhoneDSHShell
import ProbeKit

struct CompositeConnectorToolInvoker: ConnectorToolInvoker {
    let descriptors: [ConnectorToolDescriptor]
    private let invokers: [any ConnectorToolInvoker]

    init(invokers: [any ConnectorToolInvoker]) {
        self.invokers = invokers
        descriptors = invokers.flatMap(\.descriptors)
    }

    func invoke(_ name: String, argumentsJSON: String, caller: ToolCaller) async -> ToolInvocationResult {
        guard let invoker = invokers.first(where: { $0.descriptors.contains(where: { $0.internalName == name }) }) else {
            return ToolInvocationResult(toolCallID: "", contentJSON: #"{"error":"unknown_tool"}"#, isError: true)
        }
        return await invoker.invoke(name, argumentsJSON: argumentsJSON, caller: caller)
    }
}

struct ReadOnlyConnectorPhoneBridge: PhoneToolBridge {
    let supportsContext = false
    let handles: Set<String>
    private let base: any PhoneToolBridge

    init(base: any PhoneToolBridge & ConnectorToolInvoker) {
        self.base = base
        handles = Set(base.descriptors.filter { $0.effect == .read }.map(\.internalName))
    }

    func callTool(name: String, arguments: String) async throws -> String {
        let tool = name.hasPrefix("phone.") ? String(name.dropFirst("phone.".count)) : name
        guard handles.contains(tool) else {
            return try PhoneToolEnvelope.failure(tool: tool, error: .unknownTool(tool))
        }
        return try await base.callTool(name: tool, arguments: arguments)
    }
}

struct PersonalAgentContextProvider: MainContextProviding {
    let conversations: ConversationStore
    let memories: MemoryStore
    let followUps: FollowUpStore
    let operations: any OperationLedger

    func snapshot(for turn: MainTurnInput) async throws -> MainConversationSnapshot {
        async let conversation = conversations.context(conversationID: turn.conversationID, recentLimit: 80)
        async let memory = memories.context(for: MemoryContextRequest(
            authenticatedPrincipal: turn.principal, conversationID: turn.conversationID,
            source: .phone, replyTo: .phoneChat, grantVersion: 0, query: turn.text))
        async let followUpRecords = followUps.records()
        let pending = await operations.pending()
        let context = try await conversation
        let recent = context.recentMessages.filter { $0.turnID != turn.turnID }.map {
            MainConversationMessage(id: $0.id, sequence: Int($0.sequence),
                                    role: $0.role == .user ? .user : .assistant,
                                    text: $0.text, createdAt: $0.createdAt)
        }
        let summary = context.summary.map {
            MainConversationSummary(summaryID: $0.id,
                                    coveredRange: Int($0.coveredRange.lowerBound)...Int($0.coveredRange.upperBound),
                                    revision: $0.revision, sourceCursor: String($0.sourceCursor), text: $0.text)
        }
        let memoryDocuments = try await memory.records.map {
            MainContextDocument(id: $0.id.uuidString, sourceRef: $0.source.reference,
                                revision: $0.revision, text: $0.text)
        }
        return MainConversationSnapshot(
            currentText: turn.text, mandate: turn.mandate,
            followUps: try await followUpRecords.map(\.followUp),
            pendingQuestions: context.pendingQuestions, messages: recent, rollingSummary: summary,
            memory: memoryDocuments,
            currentArtifacts: context.recentMessages.flatMap(\.artifacts).map {
                MainArtifactContext(id: $0.id, title: $0.title, locator: $0.locator)
            },
            pendingReconciliations: pending.map { "\($0.intent.toolName): \($0.phase.rawValue)" },
            responseStylePrompt: PersonalAgentTextPolicy.conciseSystemPrompt)
    }
}

@MainActor
@Observable
final class AppComposition {
    static let shared = try! AppComposition()

    let root: URL
    let credentials: KeychainConnectorCredentialStore
    let connectorStore: SQLiteConnectorStore
    let registry: PersistentConnectorRegistry
    let operations: FileOperationLedger
    let ingress: MainIngress
    let writeGate: DefaultWriteGate
    let githubClient: GitHubClient
    let githubBridge: GitHubToolBridge
    let gmailTransport: GmailURLSessionTransport
    let gmailTokens: GmailTokenManager
    let gmailClient: GmailClient
    let gmailOAuth: GmailOAuthCoordinator
    let gmailBridge: GmailToolBridge
    let connectorTools: CompositeConnectorToolInvoker
    let dshToolBridge: CompositePhoneToolBridge
    let domain: SQLiteDomainStore
    let conversations: ConversationStore
    let memories: MemoryStore
    let followUps: FollowUpStore
    let agent: NativeMainAgentAdapter
    let personalModel: PersonalAgentModel
    let followUpCoordinator: FollowUpCoordinator
    let chatAttention: ChatAttentionSource

    convenience init() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        try self.init(root: support.appendingPathComponent("PersonalAgent", isDirectory: true))
    }

    init(root: URL) throws {
        self.root = root
        credentials = KeychainConnectorCredentialStore()
        connectorStore = try SQLiteConnectorStore(databaseURL: root.appendingPathComponent("connectors/registry.sqlite"))
        registry = try PersistentConnectorRegistry(store: connectorStore, credentials: credentials)
        operations = try FileOperationLedger(root: root)
        ingress = try MainIngress(root: root)
        writeGate = try DefaultWriteGate(root: root)

        githubClient = GitHubClient(transport: URLSessionConnectorHTTPTransport(), credentials: credentials)
        githubBridge = GitHubToolBridge(client: githubClient, registry: registry,
                                        writeGate: writeGate, ledger: operations)

        gmailTransport = GmailURLSessionTransport()
        let oauthConfiguration = GmailOAuthConfiguration.loadFromInfoBundle()
        let tokenConfiguration = oauthConfiguration ?? GmailOAuthConfiguration(
            clientID: "", redirectURI: URL(string: "phonedsh://gmail-oauth")!, scopes: [GmailScope.readOnly])
        gmailTokens = GmailTokenManager(configuration: tokenConfiguration,
                                        store: GmailKeychainTokenStore(), transport: gmailTransport)
        gmailClient = GmailClient(tokens: gmailTokens, transport: gmailTransport)
        gmailOAuth = GmailOAuthCoordinator(configuration: oauthConfiguration,
                                           sessions: GmailASWebAuthenticationSessionProvider(), tokens: gmailTokens)
        let gmailGrants = GmailRegistryGrantProvider(registry: registry)
        let gmailWrites = GmailWriteCoordinator(client: gmailClient, gate: writeGate, ledger: operations,
                                                grants: gmailGrants)
        gmailBridge = GmailToolBridge(client: gmailClient, grants: gmailGrants, writes: gmailWrites)
        connectorTools = CompositeConnectorToolInvoker(invokers: [githubBridge, gmailBridge])
        dshToolBridge = CompositePhoneToolBridge(bridges: [
            OfficeToolBridge(presenter: OfficePresenter()), PhoneCapabilityBridge(),
            ReadOnlyConnectorPhoneBridge(base: githubBridge), ReadOnlyConnectorPhoneBridge(base: gmailBridge),
        ])

        domain = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        conversations = ConversationStore(domain: domain)
        memories = MemoryStore(domain: domain)
        followUps = FollowUpStore(domain: domain)
        let context = PersonalAgentContextProvider(conversations: conversations, memories: memories,
                                                   followUps: followUps, operations: operations)
        agent = try NativeMainAgentAdapter(clientResolver: NativeMainGatewayClientProvider(),
                                           toolInvoker: connectorTools, contextProvider: context)
        personalModel = PersonalAgentModel(conversationID: Self.conversationID(), principal: "phone-owner",
                                           agent: agent, conversations: conversations, memories: memories,
                                           followUps: followUps, operations: operations, ingress: ingress)
        personalModel.isModelConfigured = Self.modelIsConfigured()

        let incremental = GmailIncrementalSynchronizer(client: gmailClient,
                                                       store: GmailFileIncrementalStore(root: root))
        followUpCoordinator = FollowUpCoordinator(store: followUps, checkers: [
            GitHubFollowUpChecker(client: githubClient, store: connectorStore),
            GmailFollowUpChecker(client: gmailClient, incremental: incremental),
        ], notifier: NotificationRouter(sender: PersonalAgentNotificationSender()))
        chatAttention = ChatAttentionSource(conversationID: personalModel.conversationID,
                                            conversations: conversations, followUps: followUps, operations: operations)
    }

    func connectGmail() async throws {
        try await gmailOAuth.signIn()
        let profile = try await gmailClient.profile()
        let scopes = GmailOAuthConfiguration.loadFromInfoBundle()?.scopes ?? [GmailScope.readOnly]
        let previous = await registry.grant(of: "gmail")
        let grant = ConnectorGrant(connectorID: "gmail", version: (previous?.version ?? 0) + 1,
                                   allowedActions: [.read],
                                   scope: GrantScope(gmailAccount: profile.emailAddress, rawScopes: scopes))
        _ = try await registry.connect("gmail", grant: grant, credentialRef: "gmail.oauth") {}
    }

    func revoke(_ connectorID: String) async throws {
        if connectorID == "gmail" { try await gmailTokens.revoke() }
        try await registry.revoke(connectorID)
    }

    func refreshModelConfiguration() {
        personalModel.isModelConfigured = Self.modelIsConfigured()
    }

    func requestNotificationAuthorization() async throws -> Bool {
        try await PersonalAgentNotificationSender().requestAuthorization()
    }

    func recoverOperations() async {
        _ = try? await operations.recoverAfterProcessRestart()
        let gmail = GmailSendReconciler(client: gmailClient, ledger: operations)
        let github = GitHubWriteReconciler(client: githubClient)
        for record in await operations.pending() {
            if record.intent.toolName.hasPrefix("gmail.") {
                _ = await gmail.reconcile(record)
            } else if record.intent.toolName == "github.issue.comment",
                      let receipt = try? await github.reconcile(record) {
                _ = try? await operations.reconcile(record.id, receipt: receipt)
            }
        }
    }

    private static func conversationID() -> UUID {
        let key = "personal-agent.main-conversation-id"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    private static func modelIsConfigured() -> Bool {
        do {
            let settings = PhoneModelProviderSettings.shared
            guard let profile = try settings.load().selected else { return false }
            try AnthropicProviderSupport.validate(profile)
            return try settings.apiKeyStatus(for: profile.id) == .present
        } catch {
            return false
        }
    }
}

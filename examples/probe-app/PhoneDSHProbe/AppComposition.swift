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
    let suggestionStore: SuggestionStore?
    let accountID: String
    let assistantName: @Sendable () -> String

    init(conversations: ConversationStore, memories: MemoryStore, followUps: FollowUpStore,
         operations: any OperationLedger, suggestionStore: SuggestionStore? = nil,
         accountID: String = "local", assistantName: @escaping @Sendable () -> String = { "小肥鱼" }) {
        self.conversations = conversations
        self.memories = memories
        self.followUps = followUps
        self.operations = operations
        self.suggestionStore = suggestionStore
        self.accountID = accountID
        self.assistantName = assistantName
    }

    func snapshot(for turn: MainTurnInput) async throws -> MainConversationSnapshot {
        async let conversation = conversations.context(conversationID: turn.conversationID, recentLimit: 80)
        async let memory = memories.context(for: MemoryContextRequest(
            authenticatedPrincipal: turn.principal, conversationID: turn.conversationID,
            source: .phone, replyTo: .phoneChat, grantVersion: 0, query: turn.text))
        async let followUpRecords = followUps.records(principal: turn.principal, accountScope: accountID)
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
                                revision: $0.revision, text: $0.text, kind: $0.kind.rawValue,
                                scope: $0.scope, origin: $0.origin.rawValue,
                                observedAt: $0.source.observedAt, validFrom: $0.validFrom,
                                expiresAt: $0.expiresAt)
        }
        let preferences = try await memories.active(principal: turn.principal)
        let ownerName = preferences.first(where: { $0.field == .displayName })?.text
        let language = preferences.first(where: { $0.field == .language })?.text ?? configuredLanguage
        let preferredZone = preferences.first(where: { $0.field == .timeZone })?.text
        let timeZone = preferredZone.flatMap(TimeZone.init(identifier:))?.identifier ?? TimeZone.current.identifier
        let scopes: [MainDelegatedScope] = try turn.mandate.map { mandate in
            var targets = mandate.targets.gmailThreadIDs + mandate.targets.recipientIdentities
            if let repository = mandate.targets.repository { targets.append(repository) }
            targets.append(contentsOf: mandate.targets.issueOrPRNumbers.map { String($0) })
            return [MainDelegatedScope(id: mandate.mandateID.uuidString, version: mandate.version,
                                       principal: mandate.principal,
                                       actions: mandate.allowedActions.map(\.rawValue).sorted(),
                                       targets: targets, expiry: mandate.validUntil)]
        } ?? []
        let history = await suggestionStore?.suppressionHistory() ?? []
        let suggestionsHealthy = await suggestionStore?.isHealthy ?? true
        let interaction = MainInteractionState(
            pendingClarifications: context.pendingQuestions,
            unresolvedOperations: pending.map { "\($0.intent.toolName): \($0.phase.rawValue)" },
            suggestionHistory: history,
            storageError: suggestionsHealthy ? nil : "suggestion_store_unreadable")
        let runtime = try MainRuntimeContext(
            assistantName: assistantName(), userName: ownerName, preferredLanguage: language,
            userTimezone: timeZone, delegatedScopes: scopes,
            interactionState: interaction)
        return MainConversationSnapshot(
            currentText: turn.text, mandate: turn.mandate,
            followUps: try await followUpRecords.map(\.followUp),
            pendingQuestions: context.pendingQuestions, messages: recent, rollingSummary: summary,
            memory: memoryDocuments,
            currentArtifacts: context.recentMessages.flatMap(\.artifacts).map {
                MainArtifactContext(id: $0.id, title: $0.title, locator: $0.locator)
            },
            pendingReconciliations: pending.map { "\($0.intent.toolName): \($0.phase.rawValue)" },
            responseStylePrompt: PersonalAgentTextPolicy.conciseSystemPrompt,
            runtimeContext: runtime, currentLanguage: language)
    }

    private var configuredLanguage: String {
        switch NativeChatPreferences.shared.language {
        case .zh: return "zh-Hans"
        case .en: return "en"
        case .system: return Locale.preferredLanguages.first ?? "en"
        }
    }
}

@MainActor
@Observable
final class AppComposition {
    static let shared = try! AppComposition()
    static var scheduleProviderFactory: (() -> (any PersonalScheduleProviding)?)?

    let root: URL
    let credentials: any ConnectorCredentialStore
    let connectorStore: SQLiteConnectorStore
    let registry: PersistentConnectorRegistry
    let operations: FileOperationLedger
    let breaker: CircuitBreaker
    let gmailBindings: GmailAccountBindingStore
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
    let localTools: LocalCapabilityToolInvoker
    let dshToolBridge: CompositePhoneToolBridge
    let domain: SQLiteDomainStore
    let conversations: ConversationStore
    let memories: MemoryStore
    let followUps: FollowUpStore
    let agent: NativeMainAgentAdapter
    let suggestionGenerator: NativeSuggestionGenerator
    let suggestionStore: SuggestionStore
    let personalModel: PersonalAgentModel
    let followUpCoordinator: FollowUpCoordinator
    let chatAttention: ChatAttentionSource

    convenience init() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        try self.init(root: support.appendingPathComponent("PersonalAgent", isDirectory: true))
    }

    init(root: URL,
         credentials: any ConnectorCredentialStore = KeychainConnectorCredentialStore(),
         githubTransport: any ConnectorHTTPTransport = URLSessionConnectorHTTPTransport()) throws {
        self.root = root
        self.credentials = credentials
        connectorStore = try SQLiteConnectorStore(databaseURL: root.appendingPathComponent("connectors/registry.sqlite"))
        registry = try PersistentConnectorRegistry(store: connectorStore, credentials: credentials)
        operations = try FileOperationLedger(root: root)
        breaker = try CircuitBreaker(root: root)
        gmailBindings = GmailAccountBindingStore()
        ingress = try MainIngress(root: root)
        writeGate = DefaultWriteGate(tokens: try MandateTokenStore(root: root), breaker: breaker,
                                     evidenceAudits: try EvidenceAuditStore(root: root))

        githubClient = GitHubClient(transport: githubTransport, credentials: credentials)
        githubBridge = GitHubToolBridge(client: githubClient, registry: registry,
                                        writeGate: writeGate, ledger: operations, breaker: breaker)

        gmailTransport = GmailURLSessionTransport()
        let oauthScopes = [GmailScope.readOnly, GmailScope.compose]
        let oauthConfiguration = GmailOAuthConfiguration.loadFromInfoBundle(scopes: oauthScopes)
        let tokenConfiguration = oauthConfiguration ?? GmailOAuthConfiguration(
            clientID: "", redirectURI: URL(string: "phonedsh://gmail-oauth")!, scopes: oauthScopes)
        gmailTokens = GmailTokenManager(configuration: tokenConfiguration,
                                        store: GmailKeychainTokenStore(), transport: gmailTransport)
        gmailClient = GmailClient(tokens: gmailTokens, transport: gmailTransport)
        gmailOAuth = GmailOAuthCoordinator(configuration: oauthConfiguration,
                                           sessions: GmailASWebAuthenticationSessionProvider(), tokens: gmailTokens)
        let gmailGrants = GmailRegistryGrantProvider(registry: registry)
        let gmailWrites = GmailWriteCoordinator(client: gmailClient, gate: writeGate, ledger: operations,
                                                grants: gmailGrants, bindings: gmailBindings, breaker: breaker)
        gmailBridge = GmailToolBridge(client: gmailClient, grants: gmailGrants, writes: gmailWrites)
        dshToolBridge = CompositePhoneToolBridge(bridges: [
            OfficeToolBridge(presenter: OfficePresenter()), PhoneCapabilityBridge(),
            ReadOnlyConnectorPhoneBridge(base: githubBridge), ReadOnlyConnectorPhoneBridge(base: gmailBridge),
        ])

        domain = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        conversations = ConversationStore(domain: domain)
        memories = MemoryStore(domain: domain)
        followUps = FollowUpStore(domain: domain)
        suggestionStore = SuggestionStore(rootDirectory: root)
        localTools = LocalCapabilityToolInvoker(
            profile: PersonalAgentProfileStore(), memories: memories, followUps: followUps,
            suggestionHistory: SuggestionStoreHistoryAdapter(store: suggestionStore),
            schedules: Self.scheduleProviderFactory?())
        connectorTools = CompositeConnectorToolInvoker(invokers: [githubBridge, gmailBridge, localTools])
        let context = PersonalAgentContextProvider(
            conversations: conversations, memories: memories, followUps: followUps, operations: operations,
            suggestionStore: suggestionStore, accountID: "local",
            assistantName: {
                UserDefaults.standard.string(forKey: "personalAgent.displayName") ?? "小肥鱼"
            })
        agent = try NativeMainAgentAdapter(clientResolver: NativeMainGatewayClientProvider(),
                                           toolInvoker: connectorTools, contextProvider: context)
        suggestionGenerator = NativeSuggestionGenerator(clientResolver: NativeMainGatewayClientProvider(),
                                                        contextProvider: context,
                                                        capabilities: connectorTools.descriptors.map(\.internalName))
        personalModel = PersonalAgentModel(conversationID: Self.conversationID(), principal: "phone-owner",
                                           agent: agent, conversations: conversations, memories: memories,
                                           followUps: followUps, operations: operations, ingress: ingress,
                                           suggestionGenerator: suggestionGenerator, suggestionStore: suggestionStore,
                                           userLanguage: { NativeText("zh-Hans", "en") })
        personalModel.isModelConfigured = Self.modelIsConfigured()

        let incremental = GmailIncrementalSynchronizer(client: gmailClient,
                                                       store: GmailFileIncrementalStore(root: root))
        followUpCoordinator = FollowUpCoordinator(store: followUps, checkers: [
            GitHubFollowUpChecker(client: githubClient, store: connectorStore),
            GmailFollowUpChecker(client: gmailClient, incremental: incremental),
        ], notifier: NotificationRouter(sender: PersonalAgentNotificationSender()),
           principal: personalModel.principal, accountScope: personalModel.accountID)
        chatAttention = ChatAttentionSource(conversationID: personalModel.conversationID,
                                            conversations: conversations, followUps: followUps, operations: operations,
                                            principal: personalModel.principal, accountScope: personalModel.accountID)
    }

    func connectGmail(writeGrants: GmailWriteGrantSelection = GmailWriteGrantSelection()) async throws {
        try await gmailOAuth.signIn()
        let profile = try await gmailClient.profile()
        try gmailBindings.bind(principal: personalModel.principal, account: profile.emailAddress)
        let scopes = try await gmailTokens.tokenScopes()
        let previous = await registry.grant(of: "gmail")
        let grant = ConnectorGrant(connectorID: "gmail", version: (previous?.version ?? 0) + 1,
                                   allowedActions: gmailActions(writeGrants, scopes: scopes),
                                   scope: GrantScope(gmailAccount: profile.emailAddress, rawScopes: scopes))
        _ = try await registry.connect("gmail", grant: grant, credentialRef: "gmail.oauth") {}
    }

    func updateGmailGrants(_ selection: GmailWriteGrantSelection) async throws {
        guard let previous = await registry.grant(of: "gmail"),
              let account = previous.scope.gmailAccount,
              gmailBindings.isBound(principal: personalModel.principal, account: account) else {
            throw ConnectorRegistryError.verificationFailed("请先连接并绑定 Gmail 账号")
        }
        let scopes = try await gmailTokens.tokenScopes()
        let updated = ConnectorGrant(connectorID: "gmail", version: previous.version + 1,
                                     allowedActions: gmailActions(selection, scopes: scopes),
                                     scope: GrantScope(gmailAccount: account, rawScopes: scopes),
                                     rateLimit: previous.rateLimit, paused: previous.paused)
        _ = try await registry.connect("gmail", grant: updated, credentialRef: "gmail.oauth") {}
    }

    private func gmailActions(_ selection: GmailWriteGrantSelection, scopes: [String]) -> Set<MandateAction> {
        var actions: Set<MandateAction> = [.read]
        guard scopes.contains(GmailScope.compose) else { return actions }
        if selection.drafts { actions.insert(.gmailCreateDraft) }
        if selection.reply { actions.insert(.gmailReplyInThread) }
        if selection.sendNew { actions.insert(.gmailSendNew) }
        if selection.forward { actions.insert(.gmailForward) }
        return actions
    }

    func revoke(_ connectorID: String) async throws {
        if connectorID == "gmail" { try await gmailTokens.revoke() }
        try await registry.revoke(connectorID)
    }

    func preferredOwnerName() async throws -> String? {
        try await memories.active(principal: personalModel.principal)
            .first(where: { $0.field == .displayName })?.text
    }

    func savePreferredOwnerName(_ value: String) async throws {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try await memories.active(principal: personalModel.principal)
            .first(where: { $0.field == .displayName })
        if let existing {
            if text.isEmpty {
                try await memories.archive(existing.id)
            } else if existing.text != text {
                _ = try await memories.supersede(existing.id, with: text)
            }
        } else if !text.isEmpty {
            let record = MemoryRecord(principal: personalModel.principal, kind: .longTerm,
                                      field: .displayName, text: text,
                                      source: MemorySource(kind: .phone, reference: "profile.displayName",
                                                           detail: "用户在首次引导或个人设置中明确保存"),
                                      origin: .userExplicit, status: .active)
            try await memories.save(record)
        }
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
                let result = await gmail.reconcile(record)
                let resolved = if case .reconciled = result { true } else { false }
                try? await breaker.setUnknown(connectorID: "gmail", operationID: record.id, isUnknown: !resolved)
                if resolved { try? await breaker.recordProviderSuccess(connectorID: "gmail") }
            } else if record.intent.toolName.hasPrefix("github.") {
                let receipt = try? await github.reconcile(record)
                if let receipt { _ = try? await operations.reconcile(record.id, receipt: receipt) }
                try? await breaker.setUnknown(connectorID: "github", operationID: record.id,
                                              isUnknown: receipt == nil)
                if receipt != nil { try? await breaker.recordProviderSuccess(connectorID: "github") }
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

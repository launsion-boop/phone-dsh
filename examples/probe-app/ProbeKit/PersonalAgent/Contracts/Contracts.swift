// SPDX-License-Identifier: MIT

import Foundation

public enum SourceKind: String, Codable, Sendable { case phone, device, connector, dsh }

public enum ReplyTarget: Codable, Sendable, Hashable {
    case phoneChat
    case device(String)
    case dshSession(String)
}

public struct SourceEnvelope: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let principal: String
    public let source: SourceKind
    public let deviceID: String?
    public let connectorID: String?
    public let replyTo: ReplyTarget
    public let grantVersion: Int
    public let receivedAt: Date

    public init(requestID: UUID, principal: String, source: SourceKind, deviceID: String? = nil,
                connectorID: String? = nil, replyTo: ReplyTarget, grantVersion: Int, receivedAt: Date) {
        self.requestID = requestID
        self.principal = principal
        self.source = source
        self.deviceID = deviceID
        self.connectorID = connectorID
        self.replyTo = replyTo
        self.grantVersion = grantVersion
        self.receivedAt = receivedAt
    }
}

public enum MandateAction: String, Codable, Sendable {
    case read, githubComment, githubCreateIssue, githubPush, githubOpenPR
    case gmailCreateDraft, gmailReplyInThread, gmailSendNew, gmailForward
}

public enum TargetOrigin: String, Codable, Sendable {
    case userNamed, uiSelected, structuredFilter, modelInferred
}

public struct EvidenceRef: Codable, Sendable, Hashable {
    public let id: String
    public let kind: String
    public let locator: String

    public init(id: String, kind: String, locator: String) {
        self.id = id
        self.kind = kind
        self.locator = locator
    }
}

public struct MandateTargets: Codable, Sendable, Equatable {
    public var gmailThreadIDs: [String]
    public var recipientIdentities: [String]
    public var repository: String?
    public var issueOrPRNumbers: [Int]
    public var origin: TargetOrigin

    public init(gmailThreadIDs: [String] = [], recipientIdentities: [String] = [], repository: String? = nil,
                issueOrPRNumbers: [Int] = [], origin: TargetOrigin) {
        self.gmailThreadIDs = gmailThreadIDs
        self.recipientIdentities = recipientIdentities
        self.repository = repository
        self.issueOrPRNumbers = issueOrPRNumbers
        self.origin = origin
    }
}

public struct WorkMandate: Codable, Sendable, Equatable {
    public let mandateID: UUID
    public let version: Int
    public let requestID: UUID
    public let principal: String
    public let source: SourceKind
    public let goal: String
    public let allowedActions: Set<MandateAction>
    public let allowedEvidenceRefs: Set<EvidenceRef>
    public let targets: MandateTargets
    public let validUntil: Date

    public init(mandateID: UUID, version: Int, requestID: UUID, principal: String, source: SourceKind,
                goal: String, allowedActions: Set<MandateAction>, allowedEvidenceRefs: Set<EvidenceRef>,
                targets: MandateTargets, validUntil: Date) {
        self.mandateID = mandateID
        self.version = version
        self.requestID = requestID
        self.principal = principal
        self.source = source
        self.goal = goal
        self.allowedActions = allowedActions
        self.allowedEvidenceRefs = allowedEvidenceRefs
        self.targets = targets
        self.validUntil = validUntil
    }
}

public enum MainStatusPhase: String, Codable, Sendable { case preparing, reading, writing, reconciling }

public struct StatusLine: Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let phase: MainStatusPhase

    public init(id: UUID = UUID(), text: String, phase: MainStatusPhase) {
        self.id = id
        self.text = text
        self.phase = phase
    }
}

public struct ToolInvocation: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ToolInvocationResult: Codable, Sendable, Equatable {
    public let toolCallID: String
    public let contentJSON: String
    public let isError: Bool

    public init(toolCallID: String, contentJSON: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.contentJSON = contentJSON
        self.isError = isError
    }
}

public struct PendingQuestion: Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let choices: [String]

    public init(id: UUID = UUID(), text: String, choices: [String] = []) {
        self.id = id
        self.text = text
        self.choices = choices
    }
}

public struct AssistantMessage: Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let evidenceRefs: Set<EvidenceRef>

    public init(id: UUID = UUID(), text: String, evidenceRefs: Set<EvidenceRef> = []) {
        self.id = id
        self.text = text
        self.evidenceRefs = evidenceRefs
    }
}

public enum MainFailure: Error, Sendable, Equatable {
    case unsupportedProtocol(String)
    case notConfigured
    case cancelled
    case toolLimitExceeded
    case provider(String)
    case invalidResponse(String)
}

public enum MainEvent: Sendable {
    case status(StatusLine)
    case textDelta(String)
    case toolCall(ToolInvocation)
    case toolResult(ToolInvocationResult)
    case question(PendingQuestion)
    case completed(AssistantMessage)
    case failed(MainFailure)
}

public struct MainTurnInput: Sendable {
    public let turnID: UUID
    public let requestID: UUID
    public let principal: String
    public let conversationID: UUID
    public let text: String
    public let mandate: WorkMandate?

    public init(turnID: UUID = UUID(), requestID: UUID, principal: String, conversationID: UUID,
                text: String, mandate: WorkMandate? = nil) {
        self.turnID = turnID
        self.requestID = requestID
        self.principal = principal
        self.conversationID = conversationID
        self.text = text
        self.mandate = mandate
    }
}

public protocol MainAgentPort: Sendable {
    func run(turn: MainTurnInput) -> AsyncThrowingStream<MainEvent, Error>
    func cancel(turnID: UUID) async
}

public enum ToolEffect: String, Codable, Sendable { case read, write, irreversible }

public struct ConnectorToolDescriptor: Sendable, Equatable {
    public let internalName: String
    public let connectorID: String
    public let effect: ToolEffect
    public let mandateAction: MandateAction?
    public let inputSchemaJSON: String
    public let summary: String

    public init(internalName: String, connectorID: String, effect: ToolEffect,
                mandateAction: MandateAction? = nil, inputSchemaJSON: String, summary: String) {
        self.internalName = internalName
        self.connectorID = connectorID
        self.effect = effect
        self.mandateAction = mandateAction
        self.inputSchemaJSON = inputSchemaJSON
        self.summary = summary
    }
}

public enum ToolCaller: Sendable {
    case personalAgent(mandate: WorkMandate)
    case delegatedDSH(mandateToken: String)
    case dshDirect
}

public protocol ConnectorToolInvoker: Sendable {
    var descriptors: [ConnectorToolDescriptor] { get }
    func invoke(_ name: String, argumentsJSON: String, caller: ToolCaller) async -> ToolInvocationResult
}

public enum ConnectorState: String, Codable, Sendable {
    case disconnected, connecting, connected, needsAttention, expired, revoked, error
}

public struct GrantScope: Codable, Sendable, Equatable {
    public var repositories: [String]
    public var gmailAccount: String?
    public var rawScopes: [String]

    public init(repositories: [String] = [], gmailAccount: String? = nil, rawScopes: [String] = []) {
        self.repositories = repositories
        self.gmailAccount = gmailAccount
        self.rawScopes = rawScopes
    }
}

public struct RateLimit: Codable, Sendable, Equatable {
    public var maxOperationsPerHour: Int
    public var maxRecipients: Int
    public var maxAttachmentBytes: Int

    public init(maxOperationsPerHour: Int = 20, maxRecipients: Int = 3, maxAttachmentBytes: Int = 10_000_000) {
        self.maxOperationsPerHour = maxOperationsPerHour
        self.maxRecipients = maxRecipients
        self.maxAttachmentBytes = maxAttachmentBytes
    }
}

public struct ConnectorGrant: Codable, Sendable, Equatable {
    public let connectorID: String
    public let version: Int
    public let allowedActions: Set<MandateAction>
    public let scope: GrantScope
    public let rateLimit: RateLimit
    public let paused: Bool

    public init(connectorID: String, version: Int, allowedActions: Set<MandateAction>, scope: GrantScope,
                rateLimit: RateLimit = RateLimit(), paused: Bool = false) {
        self.connectorID = connectorID
        self.version = version
        self.allowedActions = allowedActions
        self.scope = scope
        self.rateLimit = rateLimit
        self.paused = paused
    }
}

public struct ConnectorRecord: Codable, Sendable, Equatable {
    public let connectorID: String
    public let state: ConnectorState
    public let lastVerifiedAt: Date?
    public let issue: String?

    public init(connectorID: String, state: ConnectorState, lastVerifiedAt: Date? = nil, issue: String? = nil) {
        self.connectorID = connectorID
        self.state = state
        self.lastVerifiedAt = lastVerifiedAt
        self.issue = issue
    }
}

public protocol ConnectorRegistry: Sendable {
    func state(of connectorID: String) async -> ConnectorRecord
    func grant(of connectorID: String) async -> ConnectorGrant?
    func updates() -> AsyncStream<ConnectorRecord>
    func revoke(_ connectorID: String) async throws
}

public struct TargetCandidate: Sendable, Equatable {
    public let id: String
    public let title: String
    public let evidence: EvidenceRef

    public init(id: String, title: String, evidence: EvidenceRef) {
        self.id = id
        self.title = title
        self.evidence = evidence
    }
}

public struct GateDenial: Sendable, Equatable, Error {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct OperationIntent: Codable, Sendable, Equatable {
    public let id: UUID
    public let toolName: String
    public let argumentsJSON: String
    public let digest: String
    public let mandateID: UUID

    public init(id: UUID = UUID(), toolName: String, argumentsJSON: String, digest: String, mandateID: UUID) {
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.digest = digest
        self.mandateID = mandateID
    }
}

public enum GateDecision: Sendable, Equatable {
    case allow(OperationIntent)
    case requireTargetSelection([TargetCandidate])
    case downgradeToDraft(reason: String)
    case requireDSHApproval
    case deny(GateDenial)
}

public protocol WriteGate: Sendable {
    func authorize(tool: ConnectorToolDescriptor, argumentsJSON: String,
                   caller: ToolCaller, grant: ConnectorGrant) async -> GateDecision
}

public enum OperationPhase: String, Codable, Sendable {
    case prepared, undoWindow, committing, committed, unknown, reconciled, cancelled, failed
}

public struct ProviderReceipt: Codable, Sendable, Equatable {
    public let providerObjectID: String
    public let url: String?
    public let rawJSON: String

    public init(providerObjectID: String, url: String? = nil, rawJSON: String) {
        self.providerObjectID = providerObjectID
        self.url = url
        self.rawJSON = rawJSON
    }
}

public struct OperationRecord: Codable, Sendable, Equatable {
    public let id: UUID
    public let intent: OperationIntent
    public var phase: OperationPhase
    public let createdAt: Date
    public var updatedAt: Date
    public var receipt: ProviderReceipt?
    public var failureReason: String?

    public init(id: UUID = UUID(), intent: OperationIntent, phase: OperationPhase = .prepared,
                createdAt: Date = Date(), updatedAt: Date = Date(), receipt: ProviderReceipt? = nil,
                failureReason: String? = nil) {
        self.id = id
        self.intent = intent
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.receipt = receipt
        self.failureReason = failureReason
    }
}

public protocol OperationLedger: Sendable {
    func prepare(_ intent: OperationIntent) async throws -> OperationRecord
    func markCommitting(_ id: UUID) async throws
    func commit(_ id: UUID, receipt: ProviderReceipt) async throws
    func markUnknown(_ id: UUID, reason: String) async throws
    func reconcile(_ id: UUID, receipt: ProviderReceipt?) async throws -> OperationRecord
    func pending() async -> [OperationRecord]
}

public protocol DomainMigration: Sendable {
    var owner: String { get }
    var version: Int { get }
    var tablePrefix: String { get }
    func apply(_ db: DomainDatabase) throws
}

public protocol DomainDatabase: AnyObject {}

public protocol DomainStore: Sendable {
    func register(_ migrations: [DomainMigration]) async throws
    func read<T>(_ body: @Sendable (DomainDatabase) throws -> T) async throws -> T
    func write<T>(_ body: @Sendable (DomainDatabase) throws -> T) async throws -> T
}

public struct FollowUpTarget: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case githubPR, gmailThread }

    public let kind: Kind
    public let repository: String?
    public let number: Int?
    public let threadID: String?

    public init(kind: Kind, repository: String? = nil, number: Int? = nil, threadID: String? = nil) {
        self.kind = kind
        self.repository = repository
        self.number = number
        self.threadID = threadID
    }
}

public struct CheckCondition: Codable, Sendable, Equatable {
    public let expression: String

    public init(expression: String) { self.expression = expression }
}

public struct StopCondition: Codable, Sendable, Equatable {
    public let expression: String

    public init(expression: String) { self.expression = expression }
}

public enum NotificationPolicy: String, Codable, Sendable { case quiet, changesOnly, allResults }

public struct FollowUp: Codable, Sendable, Equatable {
    public let id: UUID
    public var goal: String
    public var target: FollowUpTarget
    public var allowedActions: Set<MandateAction>
    public var waitingReason: String?
    public var nextCheckCondition: CheckCondition
    public var stopCondition: StopCondition
    public var validUntil: Date?
    public var linkedTaskRunIDs: [UUID]
    public var lastVerifiedAt: Date?
    public var notificationPolicy: NotificationPolicy
    public var pausedUntil: Date?

    public init(id: UUID = UUID(), goal: String, target: FollowUpTarget, allowedActions: Set<MandateAction> = [.read],
                waitingReason: String? = nil, nextCheckCondition: CheckCondition, stopCondition: StopCondition,
                validUntil: Date? = nil, linkedTaskRunIDs: [UUID] = [], lastVerifiedAt: Date? = nil,
                notificationPolicy: NotificationPolicy = .changesOnly, pausedUntil: Date? = nil) {
        self.id = id
        self.goal = goal
        self.target = target
        self.allowedActions = allowedActions
        self.waitingReason = waitingReason
        self.nextCheckCondition = nextCheckCondition
        self.stopCondition = stopCondition
        self.validUntil = validUntil
        self.linkedTaskRunIDs = linkedTaskRunIDs
        self.lastVerifiedAt = lastVerifiedAt
        self.notificationPolicy = notificationPolicy
        self.pausedUntil = pausedUntil
    }
}

public struct FollowUpCheckResult: Sendable, Equatable {
    public let changed: Bool
    public let summary: String?
    public let cursor: String?
    public let needsAttention: Bool
    public let lastVerifiedAt: Date

    public init(changed: Bool, summary: String? = nil, cursor: String? = nil,
                needsAttention: Bool = false, lastVerifiedAt: Date = Date()) {
        self.changed = changed
        self.summary = summary
        self.cursor = cursor
        self.needsAttention = needsAttention
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public protocol FollowUpChecker: Sendable {
    var targetKind: FollowUpTarget.Kind { get }
    func check(_ followUp: FollowUp, since cursor: String?) async -> FollowUpCheckResult
}

public enum AttentionOwner: Sendable { case chat, dsh, discover }

public struct AttentionItem: Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let reason: String
    public let route: AppRoute

    public init(id: UUID = UUID(), title: String, reason: String, route: AppRoute) {
        self.id = id
        self.title = title
        self.reason = reason
        self.route = route
    }
}

public protocol AttentionSource: Sendable {
    var owner: AttentionOwner { get }
    func items() -> AsyncStream<[AttentionItem]>
}

public enum ChatFocus: Hashable, Sendable {
    case followUp(UUID)
    case operation(UUID)
    case message(UUID)
}

public enum DiscoverFocus: Hashable, Sendable {
    case connector(String)
    case plugin(String)
    case device(String)
}

public enum ProfileFocus: Hashable, Sendable {
    case memory, model, permissions, privacy, engine
}

public enum AppRoute: Hashable, Sendable {
    case chat(focus: ChatFocus?)
    case dsh(sessionID: String?, approvalID: String?)
    case discover(DiscoverFocus?)
    case profile(ProfileFocus?)
}

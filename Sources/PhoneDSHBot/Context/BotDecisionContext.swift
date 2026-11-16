// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

// MARK: - Frozen G-2 block (spec/bot/v2/decision-material.schema.json)
//
// G-2 @ b4c6ef7d99ea7cbec53697c045e25855d1e2aa79 freezes names and limits:
// `block_id/turn_id/session_id/bot_id/stage/authorization_revision/query_digest/
// goal_digest?/retrieved_at_ms/materials/limits/truncated/canceled` and one
// material `{material_id,ref,path,scope,version,updated_at_ms,snippet,
// evidence[0..2],selection_reason,state,reason?,source_version?}`. This file is
// the host implementation of that block; the Worker plugin is its consumer.

public enum BotDecisionStage: String, Codable, Sendable, Equatable {
    case preStep = "pre_step"
    case preDelivery = "pre_delivery"
}

public enum BotDecisionSelectionReason: String, Codable, Sendable, Equatable {
    case match
    case recipient
    case goal
    case recency
}

/// G-1 `current_status` vocabulary. `unknown` must carry a reason.
public enum BotDecisionMaterialState: String, Codable, Sendable, Equatable {
    case current
    case changed
    case unavailable
    case revoked
    case erased
    case unknown
}

/// G-1 reason vocabulary (closed by the frozen schema).
public enum BotDecisionMaterialReason: String, Codable, Sendable, Equatable {
    case recordUnresolved = "record-unresolved"
    case recordErased = "record-erased"
    case grantRevoked = "grant-revoked"
    case sourceChanged = "source-changed"
    case newerObservationUnversioned = "newer-observation-unversioned"
    case revisionBasisMismatch = "revision-basis-mismatch"
    case noBaseline = "no-baseline"
    case sourceVersionUnknown = "source-version-unknown"
    case cycleDetected = "cycle-detected"
    case scanLimitExceeded = "scan-limit-exceeded"
}

public struct BotDecisionLimits: Codable, Sendable, Equatable {
    public static let maximumMaterials = 6
    public static let maximumCharacters = 2_400
    public static let maximumSnippetCharacters = 300
    public static let maximumDeadlineMilliseconds = 3_000

    public var maxMaterials: Int
    public var maxCharacters: Int
    public var maxSnippetCharacters: Int
    public var deadlineMilliseconds: Int

    public init(maxMaterials: Int = 4, maxCharacters: Int = 1_600,
                maxSnippetCharacters: Int = 240, deadlineMilliseconds: Int = 1_500) {
        self.maxMaterials = maxMaterials
        self.maxCharacters = maxCharacters
        self.maxSnippetCharacters = maxSnippetCharacters
        self.deadlineMilliseconds = deadlineMilliseconds
    }

    public var clamped: BotDecisionLimits {
        BotDecisionLimits(
            maxMaterials: min(max(1, maxMaterials), Self.maximumMaterials),
            maxCharacters: min(max(240, maxCharacters), Self.maximumCharacters),
            maxSnippetCharacters: min(max(60, maxSnippetCharacters), Self.maximumSnippetCharacters),
            deadlineMilliseconds: min(max(100, deadlineMilliseconds), Self.maximumDeadlineMilliseconds))
    }

    enum CodingKeys: String, CodingKey {
        case maxMaterials = "max_materials"
        case maxCharacters = "max_characters"
        case maxSnippetCharacters = "max_snippet_characters"
        case deadlineMilliseconds = "deadline_ms"
    }
}

public struct BotDecisionMaterial: Codable, Sendable, Equatable {
    public var materialID: String
    public var ref: String
    public var path: String
    public var scope: BotMemoryScope
    public var version: Int
    public var updatedAtMS: Int64
    public var snippet: String
    public var evidence: [String]
    public var selectionReason: BotDecisionSelectionReason
    public var state: BotDecisionMaterialState
    public var reason: BotDecisionMaterialReason?

    public init(
        materialID: String,
        ref: String,
        path: String,
        scope: BotMemoryScope,
        version: Int,
        updatedAtMS: Int64,
        snippet: String,
        evidence: [String] = [],
        selectionReason: BotDecisionSelectionReason,
        state: BotDecisionMaterialState,
        reason: BotDecisionMaterialReason? = nil
    ) {
        self.materialID = materialID
        self.ref = ref
        self.path = path
        self.scope = scope
        self.version = version
        self.updatedAtMS = updatedAtMS
        self.snippet = snippet
        self.evidence = evidence
        self.selectionReason = selectionReason
        self.state = state
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case materialID = "material_id"
        case ref
        case path
        case scope
        case version
        case updatedAtMS = "updated_at_ms"
        case snippet
        case evidence
        case selectionReason = "selection_reason"
        case state
        case reason
    }
}

public struct BotDecisionMaterialBlock: Codable, Sendable, Equatable {
    public var blockID: String
    public var turnID: String
    public var sessionID: String
    public var botID: String
    public var stage: BotDecisionStage
    public var authorizationRevision: String
    public var queryDigest: String
    public var goalDigest: String?
    public var retrievedAtMS: Int64
    public var materials: [BotDecisionMaterial]
    public var limits: BotDecisionLimits
    public var truncated: Bool
    public var canceled: Bool

    public init(
        blockID: String,
        turnID: String,
        sessionID: String,
        botID: String,
        stage: BotDecisionStage,
        authorizationRevision: String,
        queryDigest: String,
        goalDigest: String? = nil,
        retrievedAtMS: Int64,
        materials: [BotDecisionMaterial],
        limits: BotDecisionLimits,
        truncated: Bool = false,
        canceled: Bool = false
    ) {
        self.blockID = blockID
        self.turnID = turnID
        self.sessionID = sessionID
        self.botID = botID
        self.stage = stage
        self.authorizationRevision = authorizationRevision
        self.queryDigest = queryDigest
        self.goalDigest = goalDigest
        self.retrievedAtMS = retrievedAtMS
        self.materials = materials
        self.limits = limits
        self.truncated = truncated
        self.canceled = canceled
    }

    enum CodingKeys: String, CodingKey {
        case blockID = "block_id"
        case turnID = "turn_id"
        case sessionID = "session_id"
        case botID = "bot_id"
        case stage
        case authorizationRevision = "authorization_revision"
        case queryDigest = "query_digest"
        case goalDigest = "goal_digest"
        case retrievedAtMS = "retrieved_at_ms"
        case materials
        case limits
        case truncated
        case canceled
    }
}

// MARK: - Host selection request (internal; not the G-2 wire block)

public struct BotDecisionRecipient: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case user
        case bot
    }

    public var kind: Kind
    public var id: String
    public var displayName: String?

    public init(kind: Kind, id: String, displayName: String? = nil) {
        self.kind = kind
        self.id = id
        self.displayName = displayName
    }
}

public struct BotDecisionRequest: Codable, Sendable, Equatable {
    public var stage: BotDecisionStage
    public var botID: String
    public var sessionID: String
    /// `"<sessionID>#<turn>"`; the Worker derives it from `agent/pre-step`.
    public var turnID: String
    public var step: Int
    public var tool: String?
    public var recipient: BotDecisionRecipient?
    public var goal: String?
    /// Raw turn text for retrieval. The frozen block only carries its digest.
    public var query: String
    public var origin: String?
    public var scopes: [BotMemoryScope]
    public var permissionRevision: String
    public var activeMaterialRefs: [String]
    public var activeMaterialVersions: [String: String]
    /// Turn the active block was retrieved for. A different current turn must
    /// invalidate the block (G-2 r2 `turn-changed`).
    public var activeTurnID: String?
    /// Recipient at retrieval time (`kind:id`); a change triggers
    /// `recipient-changed`.
    public var activeRecipientID: String?
    /// Index digest of the goal at retrieval time; a change triggers
    /// `goal-changed`.
    public var activeGoalDigest: String?
    public var limits: BotDecisionLimits

    public init(
        stage: BotDecisionStage,
        botID: String,
        sessionID: String,
        turnID: String,
        step: Int = 1,
        tool: String? = nil,
        recipient: BotDecisionRecipient? = nil,
        goal: String? = nil,
        query: String,
        origin: String? = nil,
        scopes: [BotMemoryScope] = [.user, .agent],
        permissionRevision: String = "",
        activeMaterialRefs: [String] = [],
        activeMaterialVersions: [String: String] = [:],
        activeTurnID: String? = nil,
        activeRecipientID: String? = nil,
        activeGoalDigest: String? = nil,
        limits: BotDecisionLimits = BotDecisionLimits()
    ) {
        self.stage = stage
        self.botID = botID
        self.sessionID = sessionID
        self.turnID = turnID
        self.step = step
        self.tool = tool
        self.recipient = recipient
        self.goal = goal
        self.query = query
        self.origin = origin
        self.scopes = scopes
        self.permissionRevision = permissionRevision
        self.activeMaterialRefs = activeMaterialRefs
        self.activeMaterialVersions = activeMaterialVersions
        self.activeTurnID = activeTurnID
        self.activeRecipientID = activeRecipientID
        self.activeGoalDigest = activeGoalDigest
        self.limits = limits
    }
}

public struct BotDeliveryProposal: Sendable, Equatable {
    public var request: BotDecisionRequest
    public var tool: String
    public var recipient: BotDecisionRecipient?
    public var materialRefs: [String]
    public var argumentDigest: String

    public init(request: BotDecisionRequest, tool: String,
                recipient: BotDecisionRecipient? = nil,
                materialRefs: [String] = [], argumentDigest: String = "") {
        self.request = request
        self.tool = tool
        self.recipient = recipient
        self.materialRefs = materialRefs
        self.argumentDigest = argumentDigest
    }
}

/// G-2 r2 `decision-tool-result.schema.json` reason enum.
public enum BotRegenerationReason: String, Codable, Sendable, Equatable {
    case turnChanged = "turn-changed"
    case authorizationRevisionChanged = "authorization-revision-changed"
    case materialChanged = "material-changed"
    case recipientChanged = "recipient-changed"
    case goalChanged = "goal-changed"
}

/// The frozen model-visible tool result for a refused delivery. It is not a
/// P25 event, a P27 row or a cloud message; the side effect must not run.
public struct BotDecisionToolResult: Codable, Sendable, Equatable {
    public static let code = "decision_context_changed"
    public static let maximumMessageScalars = 300

    public let ok: Bool
    public let code: String
    public let reason: BotRegenerationReason
    public let materials: BotDecisionMaterialBlock
    public let message: String

    public init(reason: BotRegenerationReason, materials: BotDecisionMaterialBlock,
                message: String = "材料已更新，请按新参数重新生成并重走授权") {
        self.ok = false
        self.code = Self.code
        self.reason = reason
        self.materials = materials
        self.message = BotDecisionContextService.boundedScalars(message, Self.maximumMessageScalars)
    }

    enum CodingKeys: String, CodingKey {
        case ok, code, reason, materials, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        guard ok == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .ok, in: container, debugDescription: "ok must be false")
        }
        let code = try container.decode(String.self, forKey: .code)
        guard code == Self.code else {
            throw DecodingError.dataCorruptedError(
                forKey: .code, in: container, debugDescription: "unknown code")
        }
        let message = try container.decode(String.self, forKey: .message)
        guard !message.isEmpty,
              message.unicodeScalars.count <= Self.maximumMessageScalars else {
            throw DecodingError.dataCorruptedError(
                forKey: .message, in: container, debugDescription: "message out of bounds")
        }
        self.ok = false
        self.code = Self.code
        self.reason = try container.decode(BotRegenerationReason.self, forKey: .reason)
        self.materials = try container.decode(BotDecisionMaterialBlock.self, forKey: .materials)
        self.message = message
    }
}

public enum BotDeliveryReview: Sendable, Equatable {
    case proceed
    case regenerate(block: BotDecisionMaterialBlock, reason: BotRegenerationReason)
    case failClosed(code: String)
}

public enum BotDecisionContextError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case crossSessionDenied
    case permissionRevisionMismatch
    case unavailable(String)
    case timeout
    case cancelled
}

// MARK: - Service

/// Host-side selection and pre-delivery revalidation for G-2 decision
/// material. Reuses `BotMemory`'s existing recall index and document store; it
/// never creates a second memory/search/classification system.
public actor BotDecisionContextService {
    public typealias MemoryResolver = @Sendable (String) async throws -> BotMemory
    public typealias PermissionRevisionProvider =
        @Sendable (String, String, BotDecisionRecipient?) async -> String
    /// One material-state lookup. It carries the caller identity as well as
    /// the memory path/version/evidence refs so the production adapter can
    /// resolve P/L's G-1 `source_statuses`/freshness for the right Bot and
    /// session instead of returning a constant.
    public struct BotMaterialStateRequest: Sendable, Equatable {
        public var botID: String
        public var sessionID: String
        public var path: String
        public var version: Int
        public var evidence: [String]

        public init(botID: String, sessionID: String, path: String,
                    version: Int, evidence: [String]) {
            self.botID = botID
            self.sessionID = sessionID
            self.path = path
            self.version = version
            self.evidence = evidence
        }
    }

    /// P/L's G-1 source-state reader. Required: a material block must never
    /// fabricate a state.
    public typealias MaterialStateProvider =
        @Sendable (BotMaterialStateRequest) async -> (BotDecisionMaterialState, BotDecisionMaterialReason?)

    private let memoryForBot: MemoryResolver
    private let permissionRevision: PermissionRevisionProvider
    private let materialState: MaterialStateProvider
    private let workspaceMaterials: WorkspaceDecisionContextService?
    private let now: @Sendable () -> Int64
    private var revisionsByTurn: [String: Int] = [:]

    public init(
        memoryForBot: @escaping MemoryResolver,
        permissionRevision: @escaping PermissionRevisionProvider,
        materialState: @escaping MaterialStateProvider,
        workspaceMaterials: WorkspaceDecisionContextService? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.memoryForBot = memoryForBot
        self.permissionRevision = permissionRevision
        self.materialState = materialState
        self.workspaceMaterials = workspaceMaterials
        self.now = now
    }

    // MARK: materials

    public func materials(for request: BotDecisionRequest) async throws -> BotDecisionMaterialBlock {
        try Self.validate(request)
        guard Task.isCancelled == false else { throw BotDecisionContextError.cancelled }
        let limits = request.limits.clamped
        let requestID = Self.newRequestID()
        // Capture the authorization revision before any slow material/provider
        // query. A revocation that lands while a query is suspended must not
        // pair the old snapshot with the newer revision.
        let startingAuthorization = await permissionRevision(
            request.botID, request.sessionID, request.recipient)
        guard Task.isCancelled == false else { throw BotDecisionContextError.cancelled }

        let query = Self.boundedScalars(request.query, 600)
        let goal = Self.boundedScalars(request.goal ?? "", 600)
        let recipientHint = Self.boundedScalars(request.recipient?.displayName ?? "", 60)
        let search = [query, goal, recipientHint]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !search.isEmpty else {
            return block(request: request, requestID: requestID,
                         authorizationRevision: startingAuthorization, limits: limits,
                         materials: [], omitted: 0)
        }

        let memory: BotMemory
        do {
            memory = try await memoryForBot(request.botID)
        } catch {
            throw BotDecisionContextError.unavailable("memory-unavailable")
        }
        guard Task.isCancelled == false else { throw BotDecisionContextError.cancelled }

        let page: (hits: [BotMemoryRecallHit], total: Int)
        do {
            page = try await memory.recallPage(
                search,
                limit: min(max(limits.maxMaterials * 4, 16), 24),
                scope: nil)
        } catch {
            throw BotDecisionContextError.unavailable("memory-recall-failed")
        }
        let wantedScopes = Set(request.scopes)
        let candidates = page.hits.filter { wantedScopes.contains($0.scope) }

        var materials: [BotDecisionMaterial] = []
        var usedCharacters = 0
        var workspaceTruncated = false
        if let workspaceMaterials, !search.isEmpty {
            let selection = await workspaceMaterials.selection(
                query: query,
                goal: goal.isEmpty ? nil : goal,
                botID: request.botID,
                materialPrefix: requestID,
                limits: BotDecisionLimits(
                    maxMaterials: min(WorkspaceDecisionContextService.maximumMaterials,
                                      limits.maxMaterials),
                    maxCharacters: min(limits.maxCharacters, 960),
                    maxSnippetCharacters: limits.maxSnippetCharacters,
                    deadlineMilliseconds: limits.deadlineMilliseconds))
            materials.append(contentsOf: selection.materials)
            usedCharacters += selection.consumedCharacters
            workspaceTruncated = selection.truncated
        }
        let workspaceCount = materials.count
        for hit in candidates where materials.count < limits.maxMaterials {
            guard Task.isCancelled == false else { throw BotDecisionContextError.cancelled }
            let snippet = Self.sanitizedSnippet(hit.snippet,
                                                limit: limits.maxSnippetCharacters)
            guard !snippet.isEmpty else { continue }
            let evidence = hit.evidence
                .filter { $0.hasPrefix("record://") && $0.unicodeScalars.count <= 128 }
                .prefix(2)
            let ref = Self.ref(path: hit.path, version: hit.version)
            let cost = snippet.unicodeScalars.count
                + ref.unicodeScalars.count + hit.path.unicodeScalars.count
                + evidence.reduce(0) { $0 + $1.unicodeScalars.count } + 64
            if usedCharacters + cost > limits.maxCharacters { continue }
            usedCharacters += cost
            let state = await materialState(BotMaterialStateRequest(
                botID: request.botID, sessionID: request.sessionID,
                path: hit.path, version: hit.version, evidence: hit.evidence))
            materials.append(BotDecisionMaterial(
                materialID: "mat:\(requestID):\(materials.count + 1)",
                ref: ref,
                path: hit.path,
                scope: hit.scope,
                version: hit.version,
                updatedAtMS: hit.updatedAtMS,
                snippet: snippet,
                evidence: Array(evidence),
                selectionReason: Self.selectionReason(hit: hit, goal: goal, recipient: recipientHint),
                state: state.0,
                reason: state.1))
        }
        var omitted = max(0, candidates.count - (materials.count - workspaceCount))
        if workspaceTruncated { omitted += 1 }
        let truncated = omitted > 0 || workspaceTruncated
        let endingAuthorization = await permissionRevision(
            request.botID, request.sessionID, request.recipient)
        guard Task.isCancelled == false else { throw BotDecisionContextError.cancelled }
        let authorizationChanged = endingAuthorization != startingAuthorization
        if authorizationChanged {
            // The provider / grant changed while the snapshot was being
            // assembled. Return a canceled, material-free block carrying the
            // newer revision instead of labelling stale data as fresh.
            return block(request: request, requestID: requestID,
                         authorizationRevision: endingAuthorization, limits: limits,
                         materials: [], omitted: max(omitted, materials.count),
                         truncated: true, canceled: true)
        }
        return block(request: request, requestID: requestID,
                     authorizationRevision: endingAuthorization, limits: limits,
                     materials: materials, omitted: omitted, truncated: truncated)
    }

    // MARK: pre-delivery review

    public func review(_ proposal: BotDeliveryProposal) async throws -> BotDeliveryReview {
        guard proposal.request.stage == .preDelivery else {
            throw BotDecisionContextError.invalidRequest("review requires pre_delivery")
        }
        guard !proposal.tool.isEmpty, proposal.tool.unicodeScalars.count <= 80 else {
            throw BotDecisionContextError.invalidRequest("tool")
        }
        try Self.validate(proposal.request)
        guard Task.isCancelled == false else { throw BotDecisionContextError.cancelled }

        let memory: BotMemory
        do {
            memory = try await memoryForBot(proposal.request.botID)
        } catch {
            throw BotDecisionContextError.unavailable("memory-unavailable")
        }
        let documents: [BotMemoryDocument]
        do {
            documents = try await memory.documents()
        } catch {
            throw BotDecisionContextError.unavailable("memory-documents-failed")
        }
        let byPath = Dictionary(documents.map { ($0.path, $0) },
                                uniquingKeysWith: { first, _ in first })

        if let activeTurn = proposal.request.activeTurnID,
           !activeTurn.isEmpty, activeTurn != proposal.request.turnID {
            return .regenerate(
                block: try await materials(for: deliveryRequest(proposal.request)),
                reason: .turnChanged)
        }
        if let activeRecipient = proposal.request.activeRecipientID,
           activeRecipient != Self.recipientKey(proposal.request.recipient) {
            return .regenerate(
                block: try await materials(for: deliveryRequest(proposal.request)),
                reason: .recipientChanged)
        }
        if let activeGoal = proposal.request.activeGoalDigest,
           activeGoal != Self.goalDigest(proposal.request.goal) {
            return .regenerate(
                block: try await materials(for: deliveryRequest(proposal.request)),
                reason: .goalChanged)
        }
        if !proposal.request.permissionRevision.isEmpty {
            let current = await permissionRevision(
                proposal.request.botID, proposal.request.sessionID, proposal.request.recipient)
            guard Task.isCancelled == false else { throw BotDecisionContextError.cancelled }
            if current != proposal.request.permissionRevision {
                return .regenerate(
                    block: try await materials(for: deliveryRequest(proposal.request)),
                    reason: .authorizationRevisionChanged)
            }
        }

        for ref in proposal.request.activeMaterialRefs {
            if Self.isWorkspaceRef(ref) {
                guard await workspaceRefIsCurrent(ref, botID: proposal.request.botID) else {
                    return .regenerate(
                        block: try await materials(for: deliveryRequest(proposal.request)),
                        reason: .materialChanged)
                }
                continue
            }
            guard let parsed = Self.parseRef(ref),
                  let document = byPath[parsed.path],
                  document.version == parsed.version else {
                return .regenerate(
                    block: try await materials(for: deliveryRequest(proposal.request)),
                    reason: .materialChanged)
            }
        }

        for ref in proposal.materialRefs {
            if Self.isWorkspaceRef(ref) {
                guard await workspaceRefIsCurrent(ref, botID: proposal.request.botID) else {
                    return .regenerate(
                        block: try await materials(for: deliveryRequest(proposal.request)),
                        reason: .materialChanged)
                }
                continue
            }
            guard let parsed = Self.parseRef(ref),
                  let document = byPath[parsed.path],
                  document.version == parsed.version else {
                return .regenerate(
                    block: try await materials(for: deliveryRequest(proposal.request)),
                    reason: .materialChanged)
            }
        }
        return .proceed
    }

    // MARK: private

    private func deliveryRequest(_ request: BotDecisionRequest) -> BotDecisionRequest {
        var copy = request
        copy.stage = .preDelivery
        return copy
    }

    private func block(request: BotDecisionRequest, requestID: String,
                       authorizationRevision: String,
                       limits: BotDecisionLimits,
                       materials: [BotDecisionMaterial],
                       omitted: Int,
                       truncated: Bool? = nil,
                       canceled: Bool = false) -> BotDecisionMaterialBlock {
        let queryDigest = Self.digest(request.query)
        let goalDigest = request.goal.flatMap { goal in
            goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Self.digest(goal)
        }
        return BotDecisionMaterialBlock(
            blockID: "dm:\(requestID)",
            turnID: request.turnID,
            sessionID: request.sessionID,
            botID: request.botID,
            stage: request.stage,
            authorizationRevision: authorizationRevision.isEmpty
                ? "unknown" : authorizationRevision,
            queryDigest: queryDigest,
            goalDigest: goalDigest,
            retrievedAtMS: now(),
            materials: materials,
            limits: limits,
            truncated: truncated ?? (omitted > 0),
            canceled: canceled)
    }

    static func validate(_ request: BotDecisionRequest) throws {
        guard !request.botID.isEmpty, request.botID.unicodeScalars.count <= 128 else {
            throw BotDecisionContextError.invalidRequest("botID")
        }
        guard !request.sessionID.isEmpty, request.sessionID.unicodeScalars.count <= 64 else {
            throw BotDecisionContextError.invalidRequest("sessionID")
        }
        guard !request.turnID.isEmpty, request.turnID.unicodeScalars.count <= 200 else {
            throw BotDecisionContextError.invalidRequest("turnID")
        }
        guard request.step >= 1, request.step <= 10_000 else {
            throw BotDecisionContextError.invalidRequest("step")
        }
        guard request.query.unicodeScalars.count <= 600 else {
            throw BotDecisionContextError.invalidRequest("query too long")
        }
        guard (request.goal?.unicodeScalars.count ?? 0) <= 600 else {
            throw BotDecisionContextError.invalidRequest("goal too long")
        }
        guard request.permissionRevision.unicodeScalars.count <= 128 else {
            throw BotDecisionContextError.invalidRequest("permissionRevision")
        }
        guard !request.scopes.isEmpty,
              request.scopes.allSatisfy({ $0 == .user || $0 == .agent }) else {
            throw BotDecisionContextError.invalidRequest("scopes")
        }
        guard request.activeMaterialRefs.count <= BotDecisionLimits.maximumMaterials,
              request.activeMaterialRefs.allSatisfy({
                  Self.parseRef($0) != nil
                      || (Self.isWorkspaceRef($0)
                          && WorkspaceDecisionContextService.workspaceDigest(fromRef: $0) != nil)
              }) else {
            throw BotDecisionContextError.invalidRequest("activeMaterialRefs")
        }
    }

    static func isWorkspaceRef(_ ref: String) -> Bool {
        ref.hasPrefix("workspace:")
    }

    private func workspaceRefIsCurrent(_ ref: String, botID: String) async -> Bool {
        guard let workspaceMaterials,
              let expected = WorkspaceDecisionContextService.workspaceDigest(fromRef: ref),
              let current = await workspaceMaterials.currentContentSHA256(
                forWorkspaceRef: ref, botID: botID) else { return false }
        return current == expected
    }

    static func ref(path: String, version: Int) -> String {
        "memory:\(path)@v\(version)"
    }

    struct ParsedRef: Equatable {
        var path: String
        var version: Int
    }

    static func parseRef(_ ref: String) -> ParsedRef? {
        guard ref.hasPrefix("memory:"), ref.unicodeScalars.count <= 256 else { return nil }
        let rest = String(ref.dropFirst("memory:".count))
        guard let marker = rest.range(of: "@v", options: .backwards) else { return nil }
        let path = String(rest[..<marker.lowerBound])
        let versionText = String(rest[marker.upperBound...])
        guard Self.validMemoryPath(path),
              let version = Int(versionText), version >= 1, version <= Int(Int32.max),
              String(version) == versionText else { return nil }
        return ParsedRef(path: path, version: version)
    }

    static func validMemoryPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.unicodeScalars.count <= 200,
              !path.contains("\n"), !path.contains("\r"), !path.contains("\\") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2, segments[0] == "user" || segments[0] == "agent" else { return false }
        return segments.allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }

    static func boundedScalars(_ value: String, _ limit: Int) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count > limit else { return value }
        var view = String.UnicodeScalarView()
        view.reserveCapacity(limit)
        for scalar in scalars {
            if view.count >= limit { break }
            view.append(scalar)
        }
        return String(view)
    }

    static func sanitizedSnippet(_ value: String, limit: Int) -> String {
        let folded = value
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return boundedScalars(folded, limit)
    }

    static func selectionReason(hit: BotMemoryRecallHit, goal: String,
                                recipient: String) -> BotDecisionSelectionReason {
        let snippet = hit.snippet
        if !recipient.isEmpty, snippet.range(of: recipient) != nil { return .recipient }
        if !goal.isEmpty, snippet.range(of: goal) != nil { return .goal }
        return hit.matched ? .match : .recency
    }

    static func recipientKey(_ recipient: BotDecisionRecipient?) -> String? {
        guard let recipient else { return nil }
        return "\(recipient.kind.rawValue):\(recipient.id)"
    }

    static func goalDigest(_ goal: String?) -> String? {
        guard let goal, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return digest(goal)
    }

    static func digest(_ value: String) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }

    static func newRequestID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(8))
    }
}

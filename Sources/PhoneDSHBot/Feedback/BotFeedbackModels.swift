// SPDX-License-Identifier: MIT

import Foundation

/// One explicit user reaction to a Bot artifact.
///
/// The four actions are deliberately closed: the host maps every entry point
/// (a `.chat` model tool call, or a host-verified UI action) onto one of them.
/// A correction is not a free-form note; it must name the memory document and
/// the version that was actually applied, so the host can prove the current
/// state changed instead of trusting the model's claim.
public enum BotFeedbackAction: String, Codable, Sendable, CaseIterable {
    case adopt
    case undo
    case correct
    case suppress
}

/// How far a suppression or adoption reaches. There is intentionally no
/// "everything" level: a vague request can never turn off every goal.
public enum BotFeedbackScopeKind: String, Codable, Sendable, CaseIterable {
    /// Only the referenced delivery / artifact.
    case artifact
    /// Every proactive candidate produced by the referenced routine.
    case routine
    /// The host-derived narrow class of the referenced artifact.
    case `class`
    /// The same narrow class in every Bot (user preference).
    case user
}

public enum BotFeedbackArtifactKind: String, Codable, Sendable, CaseIterable {
    case proactive
    case routine
    case memory
    case task
    case delivery
    /// An earlier feedback record, used by `undo`.
    case feedback
}

/// A stable reference to the thing the user reacted to. `version` is the
/// applied artifact version where the artifact is versioned (memory), never a
/// model estimate.
public struct BotFeedbackArtifactRef: Codable, Sendable, Equatable {
    public var kind: BotFeedbackArtifactKind
    public var id: String
    public var version: Int?
    public var deliveryKey: String?

    public init(kind: BotFeedbackArtifactKind, id: String, version: Int? = nil,
                deliveryKey: String? = nil) {
        self.kind = kind
        self.id = id
        self.version = version
        self.deliveryKey = deliveryKey
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, version
        case deliveryKey = "delivery_key"
    }
}

public enum BotFeedbackOriginKind: String, Codable, Sendable {
    /// A real user chat turn: the tool call arrived on a host-issued `.chat`
    /// session. Routine/task/agent/proactive/maintainer/verifier sessions are
    /// not user turns and must be refused by the handler.
    case userChatTurn = "user-chat-turn"
    /// A host-verified UI action. `nonce` is the host-issued user-action nonce.
    case uiAction = "ui-action"
}

public struct BotFeedbackOrigin: Codable, Sendable, Equatable {
    public var kind: BotFeedbackOriginKind
    public var sessionID: String?
    /// Idempotency key. Host-minted for a model call (the MCP call id), or the
    /// host-verified user-action nonce for a UI action.
    public var nonce: String

    public init(kind: BotFeedbackOriginKind, sessionID: String? = nil, nonce: String) {
        self.kind = kind
        self.sessionID = sessionID
        self.nonce = nonce
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case sessionID = "session_id"
        case nonce
    }
}

/// The request body shared by both entry points. `scope` defaults to
/// `.artifact`; the host derives `classKey` from `target` and never accepts a
/// model-supplied class name.
public struct BotFeedback: Codable, Sendable, Equatable {
    /// The Bot whose artifact the user reacted to. Never inferred from text;
    /// the tool handler takes it from the host-issued principal, the UI from
    /// the visible Bot.
    public var botID: String
    public var action: BotFeedbackAction
    public var target: BotFeedbackArtifactRef
    public var scope: BotFeedbackScopeKind
    public var origin: BotFeedbackOrigin
    /// Optional `record://` references the user says are wrong; the corrected
    /// document's own evidence is unioned in by the host.
    public var disputedRefs: [String]
    public var expiresAtMS: Int64?

    public init(botID: String, action: BotFeedbackAction, target: BotFeedbackArtifactRef,
                scope: BotFeedbackScopeKind = .artifact, origin: BotFeedbackOrigin,
                disputedRefs: [String] = [], expiresAtMS: Int64? = nil) {
        self.botID = botID
        self.action = action
        self.target = target
        self.scope = scope
        self.origin = origin
        self.disputedRefs = disputedRefs
        self.expiresAtMS = expiresAtMS
    }

    private enum CodingKeys: String, CodingKey {
        case action, target, scope, origin
        case botID = "bot_id"
        case disputedRefs = "disputed_refs"
        case expiresAtMS = "expires_at_ms"
    }
}

public struct BotFeedbackMemoryApplication: Codable, Sendable, Equatable {
    public var path: String
    public var version: Int
    public var previousVersion: Int

    public init(path: String, version: Int, previousVersion: Int) {
        self.path = path
        self.version = version
        self.previousVersion = previousVersion
    }

    private enum CodingKeys: String, CodingKey {
        case path, version
        case previousVersion = "previous_version"
    }
}

public enum BotFeedbackOutcomeStatus: String, Codable, Sendable {
    case accepted
    case rejected
    case duplicated
}

/// The host's answer to one feedback request. Rejections are explicit codes,
/// never a successful no-op.
public struct BotFeedbackOutcome: Codable, Sendable, Equatable {
    public var status: BotFeedbackOutcomeStatus
    public var feedbackID: String?
    public var action: BotFeedbackAction
    public var target: BotFeedbackArtifactRef
    public var scope: BotFeedbackScopeKind
    public var classKey: String?
    public var code: String?
    public var message: String?
    /// True when this call reversed an earlier record.
    public var reversed: Bool
    /// The id of the record this undo reversed.
    public var reverses: String?
    /// True when the durable event could not be appended yet; the state change
    /// is already committed and the event is retried on the next feedback call.
    public var auditPending: Bool
    public var appliedMemory: BotFeedbackMemoryApplication?

    public init(status: BotFeedbackOutcomeStatus, feedbackID: String? = nil,
                action: BotFeedbackAction, target: BotFeedbackArtifactRef,
                scope: BotFeedbackScopeKind, classKey: String? = nil,
                code: String? = nil, message: String? = nil, reversed: Bool = false,
                reverses: String? = nil, auditPending: Bool = false,
                appliedMemory: BotFeedbackMemoryApplication? = nil) {
        self.status = status
        self.feedbackID = feedbackID
        self.action = action
        self.target = target
        self.scope = scope
        self.classKey = classKey
        self.code = code
        self.message = message
        self.reversed = reversed
        self.reverses = reverses
        self.auditPending = auditPending
        self.appliedMemory = appliedMemory
    }

    public var accepted: Bool { status == .accepted }

    /// G-2 §4 closes the feedback reason vocabulary. Rejections carry one of
    /// those values in `code`; this alias makes the contract name explicit.
    public var reason: String? { code }

    private enum CodingKeys: String, CodingKey {
        case status, action, target, scope, code, message, reversed, reverses
        case feedbackID = "feedback_id"
        case auditPending = "audit_pending"
        case classKey = "class_key"
        case appliedMemory = "applied_memory"
    }
}

/// One audit record. It stores references, ids, versions and closed enums only:
/// never the user's words, never memory bodies.
public struct BotFeedbackRecord: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchema = "bot-feedback/v1"

    public var id: String
    public var schema: String
    public var action: BotFeedbackAction
    public var botID: String
    public var origin: BotFeedbackOrigin
    public var target: BotFeedbackArtifactRef
    public var scopeKind: BotFeedbackScopeKind
    public var scopeKey: String?
    public var classKey: String?
    public var subjects: [String]
    public var applied: BotFeedbackMemoryApplication?
    public var reverses: String?
    public var accepted: Bool
    public var code: String?
    public var atMS: Int64
    public var expiresAtMS: Int64?
    public var nonce: String
    /// Durable event id. The record is written before the event; `eventAppended`
    /// lets a retry repair the crash window without appending twice.
    public var eventID: String?
    public var eventAppended: Bool

    public init(id: String, action: BotFeedbackAction, botID: String,
                origin: BotFeedbackOrigin, target: BotFeedbackArtifactRef,
                scopeKind: BotFeedbackScopeKind, scopeKey: String? = nil,
                classKey: String? = nil, subjects: [String] = [],
                applied: BotFeedbackMemoryApplication? = nil, reverses: String? = nil,
                accepted: Bool, code: String? = nil, atMS: Int64,
                expiresAtMS: Int64? = nil, nonce: String,
                eventID: String? = nil, eventAppended: Bool = false) {
        self.id = id
        self.schema = Self.currentSchema
        self.action = action
        self.botID = botID
        self.origin = origin
        self.target = target
        self.scopeKind = scopeKind
        self.scopeKey = scopeKey
        self.classKey = classKey
        self.subjects = subjects
        self.applied = applied
        self.reverses = reverses
        self.accepted = accepted
        self.code = code
        self.atMS = atMS
        self.expiresAtMS = expiresAtMS
        self.nonce = nonce
        self.eventID = eventID
        self.eventAppended = eventAppended
    }

    private enum CodingKeys: String, CodingKey {
        case id, schema, action, origin, target, subjects, applied, reverses
        case accepted, code, nonce
        case botID = "bot_id"
        case scopeKind = "scope_kind"
        case scopeKey = "scope_key"
        case classKey = "class_key"
        case atMS = "at_ms"
        case expiresAtMS = "expires_at_ms"
        case eventID = "event_id"
        case eventAppended = "event_appended"
    }
}

/// One active-or-revoked suppression. Revocation is a state transition, not a
/// deletion: history stays auditable and an undo can be explained later.
public struct BotFeedbackPreference: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var botID: String
    public var scopeKind: BotFeedbackScopeKind
    public var scopeKey: String
    public var classKey: String
    public var createdAtMS: Int64
    public var expiresAtMS: Int64?
    public var revokedAtMS: Int64?
    public var revokedByFeedbackID: String?

    public init(id: String, botID: String, scopeKind: BotFeedbackScopeKind,
                scopeKey: String, classKey: String, createdAtMS: Int64,
                expiresAtMS: Int64? = nil, revokedAtMS: Int64? = nil,
                revokedByFeedbackID: String? = nil) {
        self.id = id
        self.botID = botID
        self.scopeKind = scopeKind
        self.scopeKey = scopeKey
        self.classKey = classKey
        self.createdAtMS = createdAtMS
        self.expiresAtMS = expiresAtMS
        self.revokedAtMS = revokedAtMS
        self.revokedByFeedbackID = revokedByFeedbackID
    }

    public func isActive(at now: Int64) -> Bool {
        guard revokedAtMS == nil else { return false }
        if let expiresAtMS, now >= expiresAtMS { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case botID = "bot_id"
        case scopeKind = "scope_kind"
        case scopeKey = "scope_key"
        case classKey = "class_key"
        case createdAtMS = "created_at_ms"
        case expiresAtMS = "expires_at_ms"
        case revokedAtMS = "revoked_at_ms"
        case revokedByFeedbackID = "revoked_by_feedback_id"
    }
}

/// An adoption of a concrete delivery. Kept separately so `undo` can retract
/// it without rewriting the audit record.
public struct BotFeedbackAdoption: Codable, Sendable, Equatable {
    public var artifactKey: String
    public var botID: String
    public var feedbackID: String
    public var atMS: Int64
    public var revokedAtMS: Int64?
    public var revokedByFeedbackID: String?

    public init(artifactKey: String, botID: String, feedbackID: String, atMS: Int64,
                revokedAtMS: Int64? = nil, revokedByFeedbackID: String? = nil) {
        self.artifactKey = artifactKey
        self.botID = botID
        self.feedbackID = feedbackID
        self.atMS = atMS
        self.revokedAtMS = revokedAtMS
        self.revokedByFeedbackID = revokedByFeedbackID
    }

    public func isActive() -> Bool { revokedAtMS == nil }

    private enum CodingKeys: String, CodingKey {
        case artifactKey = "artifact_key"
        case botID = "bot_id"
        case feedbackID = "feedback_id"
        case atMS = "at_ms"
        case revokedAtMS = "revoked_at_ms"
        case revokedByFeedbackID = "revoked_by_feedback_id"
    }
}

/// The disputed view produced by a correction. This is what M reads as
/// `path -> refs`; it is not a second memory authority and it never rewrites a
/// historical version.
public struct BotFeedbackCorrection: Codable, Sendable, Equatable {
    public var feedbackID: String
    public var botID: String
    public var path: String
    public var refs: [String]
    public var correctedVersion: Int
    public var supersededVersion: Int
    public var atMS: Int64
    public var retractedAtMS: Int64?
    public var retractedByFeedbackID: String?

    public init(feedbackID: String, botID: String, path: String, refs: [String],
                correctedVersion: Int, supersededVersion: Int, atMS: Int64,
                retractedAtMS: Int64? = nil, retractedByFeedbackID: String? = nil) {
        self.feedbackID = feedbackID
        self.botID = botID
        self.path = path
        self.refs = refs
        self.correctedVersion = correctedVersion
        self.supersededVersion = supersededVersion
        self.atMS = atMS
        self.retractedAtMS = retractedAtMS
        self.retractedByFeedbackID = retractedByFeedbackID
    }

    public func isActive() -> Bool { retractedAtMS == nil }

    private enum CodingKeys: String, CodingKey {
        case path, refs
        case feedbackID = "feedback_id"
        case botID = "bot_id"
        case correctedVersion = "corrected_version"
        case supersededVersion = "superseded_version"
        case atMS = "at_ms"
        case retractedAtMS = "retracted_at_ms"
        case retractedByFeedbackID = "retracted_by_feedback_id"
    }
}

/// Read view for M (`path -> refs`) and R/U (active preferences).
public struct BotFeedbackDisputedRef: Codable, Sendable, Equatable {
    public var path: String
    public var refs: [String]
    public var feedbackID: String
    public var correctedVersion: Int
    public var supersededVersion: Int
    public var atMS: Int64
    /// `active` or `retracted`; M must not use a retracted view.
    public var state: String

    public init(path: String, refs: [String], feedbackID: String, correctedVersion: Int,
                supersededVersion: Int, atMS: Int64, state: String) {
        self.path = path
        self.refs = refs
        self.feedbackID = feedbackID
        self.correctedVersion = correctedVersion
        self.supersededVersion = supersededVersion
        self.atMS = atMS
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case path, refs, state
        case feedbackID = "feedback_id"
        case correctedVersion = "corrected_version"
        case supersededVersion = "superseded_version"
        case atMS = "at_ms"
    }
}

public struct BotFeedbackPreferences: Codable, Sendable, Equatable {
    public var botID: String
    public var generatedAtMS: Int64
    public var active: [BotFeedbackPreference]
    public var recentlyRevoked: [BotFeedbackPreference]

    public init(botID: String, generatedAtMS: Int64, active: [BotFeedbackPreference],
                recentlyRevoked: [BotFeedbackPreference]) {
        self.botID = botID
        self.generatedAtMS = generatedAtMS
        self.active = active
        self.recentlyRevoked = recentlyRevoked
    }

    private enum CodingKeys: String, CodingKey {
        case active
        case botID = "bot_id"
        case generatedAtMS = "generated_at_ms"
        case recentlyRevoked = "recently_revoked"
    }
}

/// Delivery index entry. Created from a real `did` proactive decision; a target
/// that is not here (and cannot be found in the durable event history) is
/// unresolved and can never create a preference.
public struct BotFeedbackDelivery: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var botID: String
    public var dedupeKey: String
    public var decisionID: String?
    public var kind: String
    public var routineID: String?
    public var reminderID: String?
    public var trigger: String?
    public var rowID: String?
    public var atMS: Int64
    public var classKey: String

    public init(botID: String, dedupeKey: String, decisionID: String?, kind: String,
                routineID: String?, reminderID: String?, trigger: String?,
                rowID: String? = nil, atMS: Int64, classKey: String) {
        self.id = "proactive:\(botID):\(dedupeKey)"
        self.botID = botID
        self.dedupeKey = dedupeKey
        self.decisionID = decisionID
        self.kind = kind
        self.routineID = routineID
        self.reminderID = reminderID
        self.trigger = trigger
        self.rowID = rowID
        self.atMS = atMS
        self.classKey = classKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, trigger
        case rowID = "row_id"
        case botID = "bot_id"
        case dedupeKey = "dedupe_key"
        case decisionID = "decision_id"
        case routineID = "routine_id"
        case reminderID = "reminder_id"
        case atMS = "at_ms"
        case classKey = "class_key"
    }
}

public enum BotFeedbackHold: Sendable, Equatable {
    case notHeld
    case held(feedbackID: String, scopeKind: BotFeedbackScopeKind,
              scopeKey: String, classKey: String)

    public var isHeld: Bool {
        if case .held = self { return true }
        return false
    }
}

/// Durable state file envelope.
public struct BotFeedbackState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var schemaVersion: Int
    public var records: [BotFeedbackRecord]
    public var preferences: [BotFeedbackPreference]
    public var adoptions: [BotFeedbackAdoption]
    public var corrections: [BotFeedbackCorrection]
    public var deliveries: [BotFeedbackDelivery]

    public init(schemaVersion: Int = BotFeedbackState.currentVersion,
                records: [BotFeedbackRecord] = [], preferences: [BotFeedbackPreference] = [],
                adoptions: [BotFeedbackAdoption] = [], corrections: [BotFeedbackCorrection] = [],
                deliveries: [BotFeedbackDelivery] = []) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.preferences = preferences
        self.adoptions = adoptions
        self.corrections = corrections
        self.deliveries = deliveries
    }

    public static let empty = BotFeedbackState()

    private enum CodingKeys: String, CodingKey {
        case records, preferences, adoptions, corrections, deliveries
        case schemaVersion = "schema_version"
    }
}

/// would/did collection report. `adoptionRate` is present only when the inputs
/// are real measurements; a would-only shadow or a window shorter than the
/// frozen observation span reports `nil` plus a reason instead of a number.
public struct BotWouldCollectionReport: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public var fromMS: Int64
        public var toMS: Int64
        public var spanDays: Double

        public init(fromMS: Int64, toMS: Int64, spanDays: Double) {
            self.fromMS = fromMS
            self.toMS = toMS
            self.spanDays = spanDays
        }

        private enum CodingKeys: String, CodingKey {
            case fromMS = "from_ms"
            case toMS = "to_ms"
            case spanDays = "span_days"
        }
    }

    public var schemaVersion: Int
    public var botID: String?
    public var window: Window
    public var would: Int
    public var did: Int
    public var heldByFeedback: Int
    public var adopted: Int
    public var undone: Int
    public var suppressed: Int
    public var adoptionRate: Double?
    public var undoRate: Double?
    public var deliveryDensityPerDay: Double?
    public var nonEstimable: [String]
    public var generatedAtMS: Int64

    public init(botID: String?, window: Window, would: Int, did: Int, heldByFeedback: Int,
                adopted: Int, undone: Int, suppressed: Int, adoptionRate: Double?,
                undoRate: Double?, deliveryDensityPerDay: Double?, nonEstimable: [String],
                generatedAtMS: Int64) {
        self.schemaVersion = 1
        self.botID = botID
        self.window = window
        self.would = would
        self.did = did
        self.heldByFeedback = heldByFeedback
        self.adopted = adopted
        self.undone = undone
        self.suppressed = suppressed
        self.adoptionRate = adoptionRate
        self.undoRate = undoRate
        self.deliveryDensityPerDay = deliveryDensityPerDay
        self.nonEstimable = nonEstimable
        self.generatedAtMS = generatedAtMS
    }

    private enum CodingKeys: String, CodingKey {
        case would, did, adopted, undone, suppressed
        case adoptionRate = "adoption_rate"
        case undoRate = "undo_rate"
        case deliveryDensityPerDay = "delivery_density_per_day"
        case schemaVersion = "schema_version"
        case botID = "bot_id"
        case window
        case heldByFeedback = "held_by_feedback"
        case nonEstimable = "non_estimable"
        case generatedAtMS = "generated_at_ms"
    }
}

public enum BotFeedbackStoreError: Error, Sendable, Equatable {
    case unsupportedVersion(Int)
    case corrupted(String)
    case unavailable(String)
}

/// Read-only access to the applied memory version. The Feedback module never
/// writes memory: `UpdateMemory`/`BotMemory.write` remains the only authority.
public struct BotFeedbackMemorySnapshot: Sendable, Equatable {
    public var version: Int
    public var evidence: [String]

    public init(version: Int, evidence: [String]) {
        self.version = version
        self.evidence = evidence
    }
}

public protocol BotFeedbackMemoryReading: Sendable {
    func memorySnapshot(path: String) async throws -> BotFeedbackMemorySnapshot?
}

// MARK: - P18 feedback index (G-2 §3.4)

/// The persisted *cache* under `phone-dsh.bot.feedback.v1`. The only fact
/// source remains the durable `feedback.recorded` events; this file is what the
/// proactive gate reads quickly after a launch. It is rebuilt from events when
/// missing, corrupt or from an unknown version.
public struct BotFeedbackIndexFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let defaultsKey = "phone-dsh.bot.feedback.v1"

    public var v: Int
    public var records: [BotFeedbackIndexRecord]
    public var rebuiltFromCommitSeq: Int

    public init(v: Int = BotFeedbackIndexFile.currentVersion,
                records: [BotFeedbackIndexRecord] = [],
                rebuiltFromCommitSeq: Int = 0) {
        self.v = v
        self.records = records
        self.rebuiltFromCommitSeq = rebuiltFromCommitSeq
    }

    private enum CodingKeys: String, CodingKey {
        case v, records
        case rebuiltFromCommitSeq = "rebuilt_from_commit_seq"
    }
}

public struct BotFeedbackIndexRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case active
        case undone
        case expired
    }

    public struct Target: Codable, Sendable, Equatable {
        public var kind: BotFeedbackArtifactKind
        public var id: String
        public var version: Int?
        public var deliveryKey: String?

        public init(kind: BotFeedbackArtifactKind, id: String, version: Int? = nil,
                    deliveryKey: String? = nil) {
            self.kind = kind
            self.id = id
            self.version = version
            self.deliveryKey = deliveryKey
        }

        private enum CodingKeys: String, CodingKey {
            case kind, id, version
            case deliveryKey = "delivery_key"
        }
    }

    public struct Scope: Codable, Sendable, Equatable {
        public var kind: BotFeedbackScopeKind
        public var key: String

        public init(kind: BotFeedbackScopeKind, key: String) {
            self.kind = kind
            self.key = key
        }
    }

    public var feedbackID: String
    public var action: BotFeedbackAction
    public var target: Target
    public var scope: Scope
    public var classKey: String?
    public var status: Status
    public var createdAtMS: Int64
    public var expiresAtMS: Int64?

    public init(feedbackID: String, action: BotFeedbackAction, target: Target,
                scope: Scope, classKey: String? = nil, status: Status,
                createdAtMS: Int64, expiresAtMS: Int64? = nil) {
        self.feedbackID = feedbackID
        self.action = action
        self.target = target
        self.scope = scope
        self.classKey = classKey
        self.status = status
        self.createdAtMS = createdAtMS
        self.expiresAtMS = expiresAtMS
    }

    private enum CodingKeys: String, CodingKey {
        case feedbackID = "feedback_id"
        case action, target, scope, status
        case classKey = "class_key"
        case createdAtMS = "created_at_ms"
        case expiresAtMS = "expires_at_ms"
    }
}

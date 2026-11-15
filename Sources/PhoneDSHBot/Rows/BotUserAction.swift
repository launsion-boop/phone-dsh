// SPDX-License-Identifier: MIT

import Foundation

public enum BotUserActionKind: String, Codable, Sendable {
    case chat
    case cardAnswer
    case cardDismiss
    case approval
    case stopTask
}

public enum BotApprovalDecision: String, Codable, Sendable {
    case allowOnce
    case always
    case deny
}

public struct BotUserAction: Codable, Sendable, Equatable {
    public var nonce: String
    public var botID: String
    public var kind: BotUserActionKind
    public var text: String?
    public var cardID: String?
    public var optionID: String?
    public var approvalID: String?
    public var decision: BotApprovalDecision?
    public var digest: String?
    public var threadID: String?
    /// `chat` only. nil/empty means a text-only message; a non-empty list may
    /// accompany empty text (the schema allows one or the other).
    public var attachments: [BotAttachment]?

    public init(nonce: String, botID: String, kind: BotUserActionKind, text: String? = nil,
                cardID: String? = nil, optionID: String? = nil,
                approvalID: String? = nil, decision: BotApprovalDecision? = nil,
                digest: String? = nil, threadID: String? = nil,
                attachments: [BotAttachment]? = nil) {
        self.nonce = nonce
        self.botID = botID
        self.kind = kind
        self.text = text
        self.cardID = cardID
        self.optionID = optionID
        self.approvalID = approvalID
        self.decision = decision
        self.digest = digest
        self.threadID = threadID
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case nonce, botID, kind, text, cardID, optionID, approvalID, decision, digest, threadID, attachments
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ value: String) {
            stringValue = value
            intValue = nil
        }

        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: DynamicKey.self)
        if raw.contains(DynamicKey("customText")) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "cardAnswer must not contain customText; free-form replies use kind=chat"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(BotUserActionKind.self, forKey: .kind)
        if kind == .cardAnswer, raw.contains(DynamicKey("text")) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "cardAnswer must not contain text; free-form replies use kind=chat"))
        }
        if kind != .chat, raw.contains(DynamicKey("attachments")) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "only chat actions may carry attachments"))
        }
        nonce = try container.decode(String.self, forKey: .nonce)
        botID = try container.decode(String.self, forKey: .botID)
        self.kind = kind
        text = try container.decodeIfPresent(String.self, forKey: .text)
        cardID = try container.decodeIfPresent(String.self, forKey: .cardID)
        optionID = try container.decodeIfPresent(String.self, forKey: .optionID)
        approvalID = try container.decodeIfPresent(String.self, forKey: .approvalID)
        decision = try container.decodeIfPresent(BotApprovalDecision.self, forKey: .decision)
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        attachments = try container.decodeIfPresent([BotAttachment].self, forKey: .attachments)
    }
}

public enum BotActionResult: Codable, Sendable, Equatable {
    case accepted(eventID: String)
    case duplicate(eventID: String)
    case stale(reason: String)
    case rejected(reason: String)

    public var status: String {
        switch self {
        case .accepted: return "accepted"
        case .duplicate: return "duplicate"
        case .stale: return "stale"
        case .rejected: return "rejected"
        }
    }

    public var eventID: String? {
        switch self {
        case .accepted(let eventID), .duplicate(let eventID): return eventID
        case .stale, .rejected: return nil
        }
    }

    public var reason: String? {
        switch self {
        case .stale(let reason), .rejected(let reason): return reason
        case .accepted, .duplicate: return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case status, eventID, reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "accepted": self = .accepted(eventID: try container.decode(String.self, forKey: .eventID))
        case "duplicate": self = .duplicate(eventID: try container.decode(String.self, forKey: .eventID))
        case "stale": self = .stale(reason: try container.decode(String.self, forKey: .reason))
        case "rejected": self = .rejected(reason: try container.decode(String.self, forKey: .reason))
        case let status:
            throw DecodingError.dataCorruptedError(forKey: .status, in: container,
                                                   debugDescription: "unknown action result status: \(status)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        switch self {
        case .accepted(let eventID), .duplicate(let eventID):
            try container.encode(eventID, forKey: .eventID)
        case .stale(let reason), .rejected(let reason):
            try container.encode(reason, forKey: .reason)
        }
    }
}

public typealias UserAction = BotUserAction
public typealias ActionResult = BotActionResult

public struct BotUserActionPlan: Sendable, Equatable {
    public var event: BotEvent
    public var effects: [BotEffect]

    public init(event: BotEvent, effects: [BotEffect] = []) {
        self.event = event
        self.effects = effects
    }
}

public enum BotUserActionPlanOutcome: Sendable, Equatable {
    case commit(BotUserActionPlan)
    case stale(reason: String)
    case rejected(reason: String)
}

public enum BotUserActionTrust: String, Sendable {
    case ownerDirect = "owner_direct"
}

public protocol BotUserActionPlanning: Actor {
    func plan(_ action: BotUserAction, trust: BotUserActionTrust) async throws -> BotUserActionPlanOutcome
}

/// Prompt-only delivery for a card answer whose durable `card.answered` event
/// already committed, but whose prompt turn never completed (a kill between the
/// pre-commit and the send, or a transport replacement mid-turn).
///
/// The App implements this over the runtime. A dispatcher built without a
/// resumer keeps the pending row instead of clearing it: a committed answer
/// that was never delivered is not a completed action.
public protocol BotCardAnswerPromptResuming: Actor {
    /// Delivers the prompt for an already-committed answer. It MUST NOT write a
    /// second `card.answered` event and MUST use the nonce-derived request id
    /// (`card-answer:<nonce>`) so a retry cannot start a second model turn.
    func resumeCardAnswerPrompt(text: String, nonce: String) async throws
}

/// Terminal-vs-retryable classification for the v4 pending-action outbox.
///
/// The chat planner returns non-throwing `.rejected` for retryable transport
/// failures (a rebind, a timeout, a recovering runtime). Clearing the row on
/// every non-throwing outcome would lose exactly the message this outbox
/// exists to protect, so only terminal outcomes clear it and unknown reasons
/// fail safe by staying pending.
enum BotPendingActionOutcome {
    /// Reasons that are known to be transient. `BotRemoteActionPlanner` returns
    /// several of these as non-throwing `.rejected` outcomes rather than throws.
    static let retryableReasons: Set<String> = [
        "transport_replaced", "turn_not_completed", "collect_idle_timeout",
        "snapshot_timeout", "transport_timeout", "unavailable", "unit_detached",
    ]

    /// Reasons that cannot succeed on replay: the card/approval/task is gone,
    /// the action was invalid, or the user cancelled it. `invalid_*` reasons are
    /// terminal by prefix; this set pins the rest.
    static let terminalReasons: Set<String> = [
        "card_expired", "already_answered", "card_dismissed",
        "unknown_card", "unknown_option", "digest_mismatch",
        "missing_text", "missing_card_id", "missing_card_answer", "missing_thread_id",
        "unexpected_attachments", "too_many_attachments", "unexpected_card_answer_field",
        "only_question_cards_can_be_dismissed", "untrusted_action", "cancelled",
    ]

    static func isTerminal(_ result: BotActionResult) -> Bool {
        switch result {
        case .accepted, .duplicate: return true
        case .stale(let reason), .rejected(let reason): return isTerminal(reason: reason)
        }
    }

    static func isTerminal(reason: String) -> Bool {
        if retryableReasons.contains(reason) { return false }
        if terminalReasons.contains(reason) { return true }
        if reason.hasPrefix("invalid_") { return true }
        // Unknown planner reasons are retryable by default: dropping them would
        // lose the action on a failure mode this build does not understand.
        return false
    }
}

public actor BotUserActionDispatcher {
    private let store: SQLiteDomainStore
    private let planner: any BotUserActionPlanning
    /// nil until the App wires the runtime's prompt-only resume primitive; a
    /// nil resumer keeps a committed-but-undelivered card answer pending.
    private let cardAnswerPromptResumer: (any BotCardAnswerPromptResuming)?
    private var inFlight: [String: Task<BotActionResult, Error>] = [:]

    public init(store: SQLiteDomainStore, planner: any BotUserActionPlanning,
                cardAnswerPromptResumer: (any BotCardAnswerPromptResuming)? = nil) {
        self.store = store
        self.planner = planner
        self.cardAnswerPromptResumer = cardAnswerPromptResumer
    }

    public func dispatch(_ action: BotUserAction) async throws -> BotActionResult {
        let key = "\(action.botID)\u{0}\(action.nonce)"
        if let task = inFlight[key] { return try await Self.duplicateResult(from: task) }
        if let eventID = try await store.eventID(botID: action.botID, nonce: action.nonce) {
            return try await resolveCommitted(action, eventID: eventID)
        }
        if let task = inFlight[key] { return try await Self.duplicateResult(from: task) }
        if let invalid = BotUserActionValidation.validate(action) {
            // Validation runs before the outbox write, so a row can only be a
            // leftover from an earlier build/attempt. A terminal rejection may
            // clear it; a retryable one stays pending like any other outcome.
            if BotPendingActionOutcome.isTerminal(invalid) {
                try? await store.clearPendingAction(botID: action.botID, nonce: action.nonce)
            }
            return invalid
        }

        let task = Task {
            // Durable-before-remote: the pending row must exist before
            // `planner.plan` can start a turn. A kill mid-turn, or a transport
            // that never answers, then leaves the message in the store for the
            // next launch to replay instead of losing it. `inFlight` is
            // installed synchronously before this task can be observed, so a
            // queued duplicate of the nonce never reaches this row.
            try await store.recordPendingAction(action)
            do {
                let outcome = try await planner.plan(action, trust: .ownerDirect)
                let result: BotActionResult
                switch outcome {
                case .commit(let plan):
                    try await store.checkCrashPoint("abort-after-plan")
                    result = try await store.performAndRecord(action: action, plan: plan)
                case .stale(let reason):
                    result = .stale(reason: reason)
                case .rejected(let reason):
                    result = .rejected(reason: reason)
                }
                if BotPendingActionOutcome.isTerminal(result) {
                    try await store.clearPendingAction(botID: action.botID, nonce: action.nonce)
                } else {
                    // A retryable non-throwing outcome (the planner reports a
                    // rebind/timeout this way) is not a completed action: keep
                    // the row and count the attempt.
                    try? await store.bumpPendingActionAttempt(
                        botID: action.botID, nonce: action.nonce)
                }
                return result
            } catch {
                // A thrown error (transport failure, crash hook, store failure)
                // keeps the row for a later replay.
                try? await store.bumpPendingActionAttempt(
                    botID: action.botID, nonce: action.nonce)
                throw error
            }
        }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        return try await task.value
    }

    /// Resolves an action whose nonce event already exists.
    ///
    /// Chat/approval/stop/dismiss are complete once committed: a leftover row is
    /// stale and is dropped. A card answer is different: the planner pre-commits
    /// `card.answered` *before* sending the prompt, so an existing event with a
    /// still-pending row means the prompt may never have been delivered. That
    /// row is kept and the prompt is resumed once through the prompt-only
    /// primitive, never by calling `sendUserMessage` (the duplicate request id
    /// would wait for a turn that cannot start).
    private func resolveCommitted(_ action: BotUserAction,
                                  eventID: String) async throws -> BotActionResult {
        guard try await store.hasPendingAction(botID: action.botID, nonce: action.nonce) else {
            return .duplicate(eventID: eventID)
        }
        guard action.kind == .cardAnswer else {
            try? await store.clearPendingAction(botID: action.botID, nonce: action.nonce)
            return .duplicate(eventID: eventID)
        }
        guard let resumer = cardAnswerPromptResumer else {
            // No prompt-only resume primitive in this build: keep the row so a
            // later launch that can resume it does not lose the answer.
            return .duplicate(eventID: eventID)
        }
        guard let text = try await committedCardAnswerPrompt(action, eventID: eventID) else {
            // The committed event carries no option value/label; there is no
            // prompt to deliver, so the row cannot be safely cleared.
            return .duplicate(eventID: eventID)
        }
        do {
            try await resumer.resumeCardAnswerPrompt(text: text, nonce: action.nonce)
            try await store.clearPendingAction(botID: action.botID, nonce: action.nonce)
            return .duplicate(eventID: eventID)
        } catch {
            try? await store.bumpPendingActionAttempt(
                botID: action.botID, nonce: action.nonce)
            throw error
        }
    }

    /// The prompt text for a committed card answer: the durable option value,
    /// falling back to its label. Only used for the resume prompt; the event
    /// itself stays the authority.
    private func committedCardAnswerPrompt(_ action: BotUserAction,
                                           eventID: String) async throws -> String? {
        guard let event = try await store.event(withId: eventID),
              case .object(let data) = event.data,
              let text = data["value"]?.stringValue ?? data["label"]?.stringValue,
              !text.isEmpty else { return nil }
        return text
    }

    private static func duplicateResult(from task: Task<BotActionResult, Error>) async throws -> BotActionResult {
        let result = try await task.value
        if case .accepted(let eventID) = result { return .duplicate(eventID: eventID) }
        return result
    }
}

enum BotUserActionValidation {
    static func validate(_ action: BotUserAction) -> BotActionResult? {
        guard !action.nonce.isEmpty, !action.botID.isEmpty else { return .rejected(reason: "invalid_action") }
        if action.kind != .chat, action.attachments != nil {
            return .rejected(reason: "unexpected_attachments")
        }
        switch action.kind {
        case .chat:
            let attachments = action.attachments ?? []
            guard attachments.count <= BotAttachmentPolicy.maxCount else {
                return .rejected(reason: "too_many_attachments")
            }
            guard attachments.allSatisfy({ $0.name.isEmpty == false && $0.path.isEmpty == false
                && $0.kind.isEmpty == false && $0.size >= 0 }) else {
                return .rejected(reason: "invalid_attachment")
            }
            let text = (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !attachments.isEmpty else { return .rejected(reason: "missing_text") }
        case .cardAnswer:
            guard action.cardID?.isEmpty == false else { return .rejected(reason: "missing_card_id") }
            guard action.text == nil else {
                return .rejected(reason: "unexpected_card_answer_field")
            }
            guard action.optionID?.isEmpty == false else {
                return .rejected(reason: "missing_card_answer")
            }
        case .cardDismiss:
            guard action.cardID?.isEmpty == false else { return .rejected(reason: "missing_card_id") }
        case .approval:
            guard action.approvalID?.isEmpty == false, action.decision != nil else {
                return .rejected(reason: "invalid_approval")
            }
            guard action.digest?.isEmpty == false else { return .stale(reason: "digest_mismatch") }
        case .stopTask:
            guard action.threadID?.isEmpty == false else { return .rejected(reason: "missing_thread_id") }
        }
        return nil
    }
}

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

public actor BotUserActionDispatcher {
    private let store: SQLiteDomainStore
    private let planner: any BotUserActionPlanning
    private var inFlight: [String: Task<BotActionResult, Error>] = [:]

    public init(store: SQLiteDomainStore, planner: any BotUserActionPlanning) {
        self.store = store
        self.planner = planner
    }

    public func dispatch(_ action: BotUserAction) async throws -> BotActionResult {
        let key = "\(action.botID)\u{0}\(action.nonce)"
        if let task = inFlight[key] { return try await Self.duplicateResult(from: task) }
        if let eventID = try await store.eventID(botID: action.botID, nonce: action.nonce) {
            return .duplicate(eventID: eventID)
        }
        if let task = inFlight[key] { return try await Self.duplicateResult(from: task) }
        if let invalid = BotUserActionValidation.validate(action) { return invalid }

        let task = Task {
            let outcome = try await planner.plan(action, trust: .ownerDirect)
            switch outcome {
            case .commit(let plan):
                try await store.checkCrashPoint("abort-after-plan")
                return try await store.performAndRecord(action: action, plan: plan)
            case .stale(let reason):
                return .stale(reason: reason)
            case .rejected(let reason):
                return .rejected(reason: reason)
            }
        }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        return try await task.value
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

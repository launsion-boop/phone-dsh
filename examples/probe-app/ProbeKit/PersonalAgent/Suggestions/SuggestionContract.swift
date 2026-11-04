// SPDX-License-Identifier: MIT

import Foundation

public enum SuggestionKind: String, Codable, Sendable {
    case none
    case nextSteps = "next_steps"
    case clarification
}

public enum SuggestionOutcome: String, Codable, Sendable {
    case shown
    case selected
    case dismissed
    case declined
    case superseded
    case expired
    case unknown
}

public struct SuggestionOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let userRequest: String

    enum CodingKeys: String, CodingKey {
        case id, label
        case userRequest = "user_request"
    }

    public init(id: String, label: String, userRequest: String) {
        self.id = id
        self.label = label
        self.userRequest = userRequest
    }
}

public struct SuggestionProposal: Codable, Sendable, Equatable {
    public let kind: SuggestionKind
    public let question: String?
    public let options: [SuggestionOption]
    public let allowCustom: Bool
    public let dismissOnMoveOn: Bool
    public let multiSelect: Bool

    enum CodingKeys: String, CodingKey {
        case kind, question, options
        case allowCustom = "allow_custom"
        case dismissOnMoveOn = "dismiss_on_move_on"
        case multiSelect = "multi_select"
    }

    public init(kind: SuggestionKind, question: String? = nil, options: [SuggestionOption] = [],
                allowCustom: Bool = false, dismissOnMoveOn: Bool = false, multiSelect: Bool = false) {
        self.kind = kind
        self.question = question
        self.options = options
        self.allowCustom = allowCustom
        self.dismissOnMoveOn = dismissOnMoveOn
        self.multiSelect = multiSelect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(SuggestionKind.self, forKey: .kind)
        question = try container.decodeIfPresent(String.self, forKey: .question)
        options = try container.decodeIfPresent([SuggestionOption].self, forKey: .options) ?? []
        allowCustom = try container.decodeIfPresent(Bool.self, forKey: .allowCustom) ?? false
        dismissOnMoveOn = try container.decodeIfPresent(Bool.self, forKey: .dismissOnMoveOn) ?? false
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }

    public func validate(maxOptions: Int = 4) throws {
        guard !multiSelect else { throw SuggestionValidationError.invalid("multi_select must be false") }
        switch kind {
        case .none:
            guard question == nil, options.isEmpty, !allowCustom, !dismissOnMoveOn else {
                throw SuggestionValidationError.invalid("none must not contain card fields")
            }
        case .nextSteps:
            try validateQuestion()
            guard (1...maxOptions).contains(options.count) else {
                throw SuggestionValidationError.invalid("next_steps requires one to four options")
            }
            guard dismissOnMoveOn else {
                throw SuggestionValidationError.invalid("next_steps requires dismiss_on_move_on=true")
            }
            try validateOptions()
        case .clarification:
            try validateQuestion()
            guard options.count <= maxOptions else {
                throw SuggestionValidationError.invalid("clarification has too many options")
            }
            guard !dismissOnMoveOn else {
                throw SuggestionValidationError.invalid("clarification requires dismiss_on_move_on=false")
            }
            guard !options.isEmpty || allowCustom else {
                throw SuggestionValidationError.invalid("a clarification without options requires allow_custom=true")
            }
            try validateOptions()
        }
    }

    private func validateQuestion() throws {
        guard let question, Self.isBounded(question, maximum: 500) else {
            throw SuggestionValidationError.invalid("question must contain 1...500 characters")
        }
    }

    private func validateOptions() throws {
        var ids = Set<String>()
        for option in options {
            guard option.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
                  Self.isBounded(option.label, maximum: 160),
                  Self.isBounded(option.userRequest, maximum: 2_000) else {
                throw SuggestionValidationError.invalid("invalid option ID or visible string")
            }
            guard ids.insert(option.id).inserted else {
                throw SuggestionValidationError.invalid("duplicate option ID")
            }
        }
    }

    private static func isBounded(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= maximum
    }
}

public enum SuggestionValidationError: Error, Sendable, Equatable {
    case invalid(String)
}

public struct SuggestionSuppressionKey: Codable, Sendable, Equatable, Hashable {
    public let action: String
    public let target: String

    public init(action: String, target: String) {
        self.action = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var canonical: String {
        Self.canonical(action: action, target: target)
    }

    public static func canonical(action: String, target: String) -> String {
        let normalized = SuggestionSuppressionKey(action: action, target: target)
        let action = Data(normalized.action.utf8).base64EncodedString()
        let target = Data(normalized.target.utf8).base64EncodedString()
        return "v1:\(action):\(target)"
    }
}

public struct SuggestionScope: Codable, Sendable, Equatable, Hashable {
    public let conversationID: UUID
    public let principal: String
    public let accountID: String

    public init(conversationID: UUID, principal: String, accountID: String) {
        self.conversationID = conversationID
        self.principal = principal
        self.accountID = accountID
    }
}

public struct SuggestionHostMetadata: Sendable {
    public let accountID: String
    public let cardID: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let suppressionKeysByOptionID: [String: [SuggestionSuppressionKey]]
    public let suppressionHistory: [String]
    public let userLanguage: String?

    public init(accountID: String, cardID: UUID = UUID(), createdAt: Date = Date(),
                expiresAt: Date? = nil,
                suppressionKeysByOptionID: [String: [SuggestionSuppressionKey]] = [:],
                suppressionHistory: [String] = [], userLanguage: String? = nil) {
        self.accountID = accountID
        self.cardID = cardID
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(15 * 60)
        self.suppressionKeysByOptionID = suppressionKeysByOptionID
        self.suppressionHistory = suppressionHistory
        self.userLanguage = userLanguage
    }
}

public struct SuggestionCard: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let cardID: UUID
    public let conversationID: UUID
    public let turnID: UUID
    public let principal: String
    public let accountID: String
    public let createdAt: Date
    public let expiresAt: Date
    public let suppressionKeys: [SuggestionSuppressionKey]
    public let kind: SuggestionKind
    public let question: String
    public let options: [SuggestionOption]
    public let allowCustom: Bool
    public let dismissOnMoveOn: Bool
    public let multiSelect: Bool
    public let originalMandate: WorkMandate?
    public internal(set) var outcome: SuggestionOutcome

    public var id: UUID { cardID }
    public var scope: SuggestionScope {
        SuggestionScope(conversationID: conversationID, principal: principal, accountID: accountID)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, cardID, conversationID, turnID, principal, accountID, createdAt, expiresAt
        case suppressionKeys, kind, question, options, originalMandate, outcome
        case allowCustom = "allow_custom"
        case dismissOnMoveOn = "dismiss_on_move_on"
        case multiSelect = "multi_select"
    }

    public init(schemaVersion: Int = Self.currentSchemaVersion, cardID: UUID = UUID(),
                conversationID: UUID, turnID: UUID, principal: String, accountID: String,
                createdAt: Date = Date(), expiresAt: Date? = nil,
                suppressionKeys: [SuggestionSuppressionKey], kind: SuggestionKind,
                question: String, options: [SuggestionOption], allowCustom: Bool,
                dismissOnMoveOn: Bool, multiSelect: Bool = false,
                originalMandate: WorkMandate? = nil, outcome: SuggestionOutcome = .shown) {
        self.schemaVersion = schemaVersion
        self.cardID = cardID
        self.conversationID = conversationID
        self.turnID = turnID
        self.principal = principal
        self.accountID = accountID
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(15 * 60)
        self.suppressionKeys = suppressionKeys
        self.kind = kind
        self.question = question
        self.options = options
        self.allowCustom = allowCustom
        self.dismissOnMoveOn = dismissOnMoveOn
        self.multiSelect = multiSelect
        self.originalMandate = originalMandate
        self.outcome = outcome
    }

    public init(proposal: SuggestionProposal, turn: MainTurnInput, metadata: SuggestionHostMetadata) throws {
        try proposal.validate()
        guard proposal.kind != .none, let question = proposal.question else {
            throw SuggestionValidationError.invalid("none cannot be materialized as a card")
        }
        let keys = proposal.options.flatMap { option -> [SuggestionSuppressionKey] in
            metadata.suppressionKeysByOptionID[option.id] ?? [Self.semanticSuppressionKey(option)]
        }
        self.init(schemaVersion: Self.currentSchemaVersion, cardID: metadata.cardID,
                  conversationID: turn.conversationID, turnID: turn.turnID, principal: turn.principal,
                  accountID: metadata.accountID, createdAt: metadata.createdAt, expiresAt: metadata.expiresAt,
                  suppressionKeys: Array(Set(keys)).sorted { $0.canonical < $1.canonical },
                  kind: proposal.kind, question: question, options: proposal.options,
                  allowCustom: proposal.allowCustom, dismissOnMoveOn: proposal.dismissOnMoveOn,
                  multiSelect: proposal.multiSelect, originalMandate: turn.mandate)
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion, kind != .none,
              !principal.isEmpty, !accountID.isEmpty, expiresAt > createdAt,
              suppressionKeys.allSatisfy({ !$0.action.isEmpty && !$0.target.isEmpty }) else {
            throw SuggestionValidationError.invalid("invalid host-owned card metadata")
        }
        try SuggestionProposal(kind: kind, question: question, options: options,
                               allowCustom: allowCustom, dismissOnMoveOn: dismissOnMoveOn,
                               multiSelect: multiSelect).validate()
    }

    private static func semanticSuppressionKey(_ option: SuggestionOption) -> SuggestionSuppressionKey {
        let draft = RuleBasedMandateFactory().draft(userText: option.userRequest)
        let action = draft.allowedActions.map(\.rawValue).sorted().joined(separator: "+")
        let targets = draft.targets
        var targetParts = [targets.repository ?? "", targets.gmailThreadIDs.sorted().joined(separator: ","),
                           targets.recipientIdentities.sorted().joined(separator: ","),
                           targets.issueOrPRNumbers.sorted().map(String.init).joined(separator: ",")]
        if targetParts.allSatisfy(\.isEmpty) {
            targetParts = [option.userRequest.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return SuggestionSuppressionKey(action: action, target: targetParts.joined(separator: "|"))
    }
}

public struct SuggestionLifecycleEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let cardID: UUID
    public let outcome: SuggestionOutcome
    public let createdAt: Date

    public init(id: UUID = UUID(), cardID: UUID, outcome: SuggestionOutcome, createdAt: Date) {
        self.id = id
        self.cardID = cardID
        self.outcome = outcome
        self.createdAt = createdAt
    }
}

public struct SuggestionSelection: Codable, Sendable, Equatable {
    public let selectionEventID: UUID
    public let cardID: UUID
    public let cardVersion: Int
    public let optionID: String
    public let visibleLabel: String?
    public let userRequest: String
    public let conversationID: UUID
    public let principal: String
    public let accountID: String
    public let createdAt: Date
    public let originalMandate: WorkMandate?

    public init(selectionEventID: UUID, cardID: UUID, cardVersion: Int, optionID: String,
                visibleLabel: String = "", userRequest: String, conversationID: UUID, principal: String, accountID: String,
                createdAt: Date, originalMandate: WorkMandate? = nil) {
        self.selectionEventID = selectionEventID
        self.cardID = cardID
        self.cardVersion = cardVersion
        self.optionID = optionID
        self.visibleLabel = visibleLabel
        self.userRequest = userRequest
        self.conversationID = conversationID
        self.principal = principal
        self.accountID = accountID
        self.createdAt = createdAt
        self.originalMandate = originalMandate
    }
}

public struct SuggestionSelectionResult: Sendable, Equatable {
    public let selection: SuggestionSelection
    public let shouldSend: Bool

    public var userRequest: String { selection.userRequest }
    public var textToSend: String {
        guard let label = selection.visibleLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return selection.userRequest }
        return label
    }
}

public struct SuggestionPolicy: Sendable, Equatable {
    public let maxOptions: Int
    public let dismissCooldown: TimeInterval
    public let declineCooldown: TimeInterval
    public let stopAfterExplicitDeclines: Int
    public let multiSelectEnabled: Bool

    public init(maxOptions: Int = 4, dismissCooldown: TimeInterval = 7 * 24 * 60 * 60,
                declineCooldown: TimeInterval = 30 * 24 * 60 * 60,
                stopAfterExplicitDeclines: Int = 2, multiSelectEnabled: Bool = false) {
        self.maxOptions = maxOptions
        self.dismissCooldown = dismissCooldown
        self.declineCooldown = declineCooldown
        self.stopAfterExplicitDeclines = stopAfterExplicitDeclines
        self.multiSelectEnabled = multiSelectEnabled
    }
}

public enum SuggestionGenerationDiagnostic: String, Sendable, Equatable {
    case unavailable
    case invalidResponse = "invalid_response"
    case pendingClarification = "pending_clarification"
    case staleContext = "stale_context"
}

public enum SuggestionGenerationResult: Sendable, Equatable {
    case none
    case card(SuggestionCard)
    case suppressed(SuggestionGenerationDiagnostic)
}

public protocol StructuredSuggestionGenerating: Sendable {
    func generateCard(turn: MainTurnInput, answer: AssistantMessage,
                      metadata: SuggestionHostMetadata) async -> SuggestionGenerationResult
}

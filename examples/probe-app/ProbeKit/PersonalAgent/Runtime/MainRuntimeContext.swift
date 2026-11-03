// SPDX-License-Identifier: MIT

import Foundation

public struct MainDelegatedScope: Codable, Sendable, Equatable {
    public let id: String
    public let version: Int
    public let principal: String
    public let actions: [String]
    public let targets: [String]
    public let expiry: Date

    public init(id: String, version: Int, principal: String, actions: [String], targets: [String], expiry: Date) {
        self.id = id
        self.version = version
        self.principal = principal
        self.actions = actions
        self.targets = targets
        self.expiry = expiry
    }
}

public enum MainCapabilityAvailability: String, Codable, Sendable {
    case available
    case unavailable
}

public struct MainCapability: Codable, Sendable, Equatable {
    public let name: String
    public let effect: ToolEffect
    public let availability: MainCapabilityAvailability
    public let approvalRequired: Bool

    public init(name: String, effect: ToolEffect, availability: MainCapabilityAvailability = .available,
                approvalRequired: Bool) {
        self.name = name
        self.effect = effect
        self.availability = availability
        self.approvalRequired = approvalRequired
    }

    enum CodingKeys: String, CodingKey {
        case name, effect, availability
        case approvalRequired = "approval_required"
    }
}

public struct MainInteractionState: Codable, Sendable, Equatable {
    public let pendingClarifications: [PendingQuestion]
    public let pendingApprovals: [String]
    public let unresolvedOperations: [String]
    public let suggestionHistory: [String]
    public let storageError: String?

    public init(pendingClarifications: [PendingQuestion] = [], pendingApprovals: [String] = [],
                unresolvedOperations: [String] = [], suggestionHistory: [String] = [], storageError: String? = nil) {
        self.pendingClarifications = pendingClarifications
        self.pendingApprovals = pendingApprovals
        self.unresolvedOperations = unresolvedOperations
        self.suggestionHistory = suggestionHistory
        self.storageError = storageError
    }

    public static let verifiedEmpty = MainInteractionState()

    enum CodingKeys: String, CodingKey {
        case pendingClarifications = "pending_clarifications"
        case pendingApprovals = "pending_approvals"
        case unresolvedOperations = "unresolved_operations"
        case suggestionHistory = "suggestion_history"
        case storageError = "storage_error"
    }
}

public struct MainSuggestionPolicy: Codable, Sendable, Equatable {
    public let maxOptions: Int
    public let dismissCooldownDays: Int
    public let declineCooldownDays: Int
    public let stopAfterExplicitDeclines: Int
    public let multiSelectEnabled: Bool

    public init(maxOptions: Int = 4, dismissCooldownDays: Int = 7, declineCooldownDays: Int = 30,
                stopAfterExplicitDeclines: Int = 2, multiSelectEnabled: Bool = false) throws {
        guard (1...4).contains(maxOptions), dismissCooldownDays >= 0, declineCooldownDays >= 0,
              stopAfterExplicitDeclines > 0 else {
            throw MainFailure.invalidResponse("invalid Personal Agent suggestion policy")
        }
        self.maxOptions = maxOptions
        self.dismissCooldownDays = dismissCooldownDays
        self.declineCooldownDays = declineCooldownDays
        self.stopAfterExplicitDeclines = stopAfterExplicitDeclines
        self.multiSelectEnabled = multiSelectEnabled
    }

    enum CodingKeys: String, CodingKey {
        case maxOptions = "max_options"
        case dismissCooldownDays = "dismiss_cooldown_days"
        case declineCooldownDays = "decline_cooldown_days"
        case stopAfterExplicitDeclines = "stop_after_explicit_declines"
        case multiSelectEnabled = "multi_select_enabled"
    }
}

public struct MainRuntimeContext: Codable, Sendable, Equatable {
    public static let defaultAssistantName = "小肥鱼"
    public static let defaultPreferredLanguage = "zh-Hans"

    public let schemaVersion: String
    public let assistantName: String
    public let userName: String?
    public let preferredLanguage: String
    public let now: Date
    public let userTimezone: String?
    public let delegatedScopes: [MainDelegatedScope]
    public let capabilities: [MainCapability]
    public let interactionState: MainInteractionState
    public let suggestionPolicy: MainSuggestionPolicy

    public init(assistantName: String? = nil, userName: String? = nil, preferredLanguage: String? = nil,
                now: Date = Date(), userTimezone: String? = TimeZone.current.identifier,
                delegatedScopes: [MainDelegatedScope] = [], capabilities: [MainCapability] = [],
                interactionState: MainInteractionState = .verifiedEmpty,
                suggestionPolicy: MainSuggestionPolicy? = nil) throws {
        if let userTimezone {
            guard TimeZone(identifier: userTimezone) != nil else {
                throw MainFailure.invalidResponse("invalid IANA user timezone")
            }
        }
        let language = preferredLanguage ?? Self.defaultPreferredLanguage
        guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MainFailure.invalidResponse("preferred language cannot be empty")
        }
        self.schemaVersion = "personal-agent-context.v1"
        self.assistantName = assistantName ?? Self.defaultAssistantName
        self.userName = userName
        self.preferredLanguage = language
        self.now = now
        self.userTimezone = userTimezone
        self.delegatedScopes = delegatedScopes.filter { $0.expiry > now }
        self.capabilities = capabilities
        self.interactionState = interactionState
        self.suggestionPolicy = try suggestionPolicy ?? MainSuggestionPolicy()
    }

    public func resolving(currentLanguage: String? = nil,
                          descriptors: [ConnectorToolDescriptor]? = nil) throws -> MainRuntimeContext {
        let resolvedCapabilities = try descriptors.map(Self.registeredCapabilities(from:)) ?? capabilities
        return try MainRuntimeContext(
            assistantName: assistantName, userName: userName,
            preferredLanguage: currentLanguage ?? preferredLanguage, now: now, userTimezone: userTimezone,
            delegatedScopes: delegatedScopes, capabilities: resolvedCapabilities,
            interactionState: interactionState, suggestionPolicy: suggestionPolicy)
    }

    public func encodedEnvelope() throws -> String {
        let data = try Self.encoder.encode(Envelope(runtimeContext: self))
        guard let string = String(data: data, encoding: .utf8) else {
            throw MainFailure.invalidResponse("runtime_context is not UTF-8")
        }
        return string
    }

    public static func registeredCapabilities(from descriptors: [ConnectorToolDescriptor]) throws -> [MainCapability] {
        let codec = try ToolNameCodec(descriptors: descriptors)
        return try descriptors.sorted { $0.internalName < $1.internalName }.map { descriptor in
            let name = try codec.modelName(for: descriptor.internalName)
            return MainCapability(name: name, effect: descriptor.effect,
                                  approvalRequired: descriptor.effect != .read)
        }
    }

    private struct Envelope: Encodable {
        let runtimeContext: MainRuntimeContext

        enum CodingKeys: String, CodingKey {
            case runtimeContext = "runtime_context"
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case assistantName = "assistant_name"
        case userName = "user_name"
        case preferredLanguage = "preferred_language"
        case now
        case userTimezone = "user_timezone"
        case delegatedScopes = "delegated_scopes"
        case capabilities
        case interactionState = "interaction_state"
        case suggestionPolicy = "suggestion_policy"
    }
}

// SPDX-License-Identifier: MIT

import Foundation

public struct PersonalAgentProfile: Codable, Sendable, Equatable {
    public let assistantName: String

    public init(assistantName: String) {
        self.assistantName = assistantName
    }
}

public protocol PersonalAgentProfileProviding: Sendable {
    func profile() throws -> PersonalAgentProfile
    func renameAssistant(to name: String) throws -> PersonalAgentProfile
}

public final class PersonalAgentProfileStore: PersonalAgentProfileProviding, @unchecked Sendable {
    public static let assistantNameKey = "personalAgent.displayName"
    public static let defaultAssistantName = "小肥鱼"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func profile() throws -> PersonalAgentProfile {
        lock.lock()
        defer { lock.unlock() }
        let stored = defaults.string(forKey: Self.assistantNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PersonalAgentProfile(assistantName: stored?.isEmpty == false
            ? stored! : Self.defaultAssistantName)
    }

    public func renameAssistant(to name: String) throws -> PersonalAgentProfile {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 80 else {
            throw LocalCapabilityError.invalidArguments("assistant name must contain 1...80 characters")
        }
        lock.lock()
        defer { lock.unlock() }
        defaults.set(normalized, forKey: Self.assistantNameKey)
        guard defaults.synchronize(),
              defaults.string(forKey: Self.assistantNameKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == normalized else {
            throw LocalCapabilityError.persistenceFailed("assistant name was not persisted")
        }
        return PersonalAgentProfile(assistantName: normalized)
    }
}

public enum SuggestionHistoryOutcome: String, Codable, Sendable, CaseIterable {
    case shown, selected, dismissed, declined, superseded, expired
}

public struct SuggestionHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let principal: String
    public let accountScope: String?
    public let canonicalKey: String
    public let outcome: SuggestionHistoryOutcome
    public let occurredAt: Date

    public init(id: UUID = UUID(), principal: String, accountScope: String? = nil,
                canonicalKey: String, outcome: SuggestionHistoryOutcome, occurredAt: Date = Date()) {
        self.id = id
        self.principal = principal
        self.accountScope = accountScope
        self.canonicalKey = canonicalKey
        self.outcome = outcome
        self.occurredAt = occurredAt
    }
}

public protocol SuggestionHistoryProviding: Sendable {
    func suggestionHistory(principal: String, accountScope: String?, canonicalKey: String?,
                           limit: Int) async throws -> [SuggestionHistoryEntry]
    @discardableResult
    func recordSuggestion(_ entry: SuggestionHistoryEntry) async throws -> SuggestionHistoryEntry
}

public enum PersonalScheduleRule: Sendable, Equatable {
    case after(seconds: Int)
    case at(Date)
    case every(seconds: Int)
    case daily(time: String, timeZone: String)
    case weekly(time: String, timeZone: String, weekdays: [Int])
    case cron(expression: String, timeZone: String)

    public var timeZone: String? {
        switch self {
        case .daily(_, let timeZone), .weekly(_, let timeZone, _), .cron(_, let timeZone):
            return timeZone
        case .after, .at, .every:
            return nil
        }
    }
}

public struct PersonalSchedule: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let title: String
    public let prompt: String
    public let rule: PersonalScheduleRule
    public let status: String
    public let nextRunAt: Date?
    public let nextRunStatus: String
    public let latestDeliveryAt: Date?

    public init(id: String, sessionID: String, title: String, prompt: String,
                rule: PersonalScheduleRule, status: String, nextRunAt: Date?,
                nextRunStatus: String, latestDeliveryAt: Date? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.prompt = prompt
        self.rule = rule
        self.status = status
        self.nextRunAt = nextRunAt
        self.nextRunStatus = nextRunStatus
        self.latestDeliveryAt = latestDeliveryAt
    }

    public var acceptsDuplicate: Bool {
        switch status.lowercased() {
        case "active", "paused", "scheduled": return true
        default: return false
        }
    }
}

public struct PersonalScheduleCreateRequest: Sendable {
    public let principal: String
    public let accountScope: String?
    public let sessionID: String
    public let title: String
    public let prompt: String
    public let rule: PersonalScheduleRule

    public init(principal: String, accountScope: String? = nil, sessionID: String,
                title: String, prompt: String, rule: PersonalScheduleRule) {
        self.principal = principal
        self.accountScope = accountScope
        self.sessionID = sessionID
        self.title = title
        self.prompt = prompt
        self.rule = rule
    }
}

public struct PersonalScheduleUpdateRequest: Sendable {
    public let principal: String
    public let accountScope: String?
    public let current: PersonalSchedule
    public let title: String?
    public let prompt: String?
    public let rule: PersonalScheduleRule?

    public init(principal: String, accountScope: String? = nil, current: PersonalSchedule,
                title: String? = nil, prompt: String? = nil, rule: PersonalScheduleRule? = nil) {
        self.principal = principal
        self.accountScope = accountScope
        self.current = current
        self.title = title
        self.prompt = prompt
        self.rule = rule
    }
}

public struct PersonalScheduleDeleteRequest: Sendable {
    public let principal: String
    public let accountScope: String?
    public let current: PersonalSchedule

    public init(principal: String, accountScope: String? = nil, current: PersonalSchedule) {
        self.principal = principal
        self.accountScope = accountScope
        self.current = current
    }
}

public struct PersonalScheduleDeleteResult: Sendable, Equatable {
    public let id: String
    public let cancelled: Bool
    public let status: String

    public init(id: String, cancelled: Bool, status: String) {
        self.id = id
        self.cancelled = cancelled
        self.status = status
    }
}

public protocol PersonalScheduleProviding: Sendable {
    func listSchedules(principal: String, accountScope: String?) async throws -> [PersonalSchedule]
    @discardableResult
    func createSchedule(_ request: PersonalScheduleCreateRequest) async throws -> PersonalSchedule
    @discardableResult
    func updateSchedule(_ request: PersonalScheduleUpdateRequest) async throws -> PersonalSchedule
    @discardableResult
    func deleteSchedule(_ request: PersonalScheduleDeleteRequest) async throws -> PersonalScheduleDeleteResult
}

public enum LocalCapabilityError: Error, Sendable, Equatable {
    case invalidArguments(String)
    case unavailable(String)
    case notFound(String)
    case persistenceFailed(String)
    case verificationFailed(String)
}

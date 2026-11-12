// SPDX-License-Identifier: MIT

import Foundation

public struct BotWatchdogConfig: Codable, Sendable, Equatable {
    public var heartbeatTimeoutMs: Int64
    public var turnDeadlineMs: Int64
    public var taskDeadlineMs: Int64
    public var routineDeadlineMs: Int64
    public var repeatedToolCalls: Int
    public var repeatedToolErrors: Int
    public var maxUnitTokens: Int
    public var maxUnitCostUsd: Double
    public var goalMaxTotalTokens: Int
    public var goalMaxTotalCostUsd: Double
    public var tickMs: Int64
    public var historyLimit: Int
    public var maxUnits: Int

    public init(
        heartbeatTimeoutMs: Int64 = 120_000,
        turnDeadlineMs: Int64 = 900_000,
        taskDeadlineMs: Int64 = 600_000,
        routineDeadlineMs: Int64 = 660_000,
        repeatedToolCalls: Int = 5,
        repeatedToolErrors: Int = 3,
        maxUnitTokens: Int = 200_000,
        maxUnitCostUsd: Double = 2,
        goalMaxTotalTokens: Int = 0,
        goalMaxTotalCostUsd: Double = 0,
        tickMs: Int64 = 5_000,
        historyLimit: Int = 200,
        maxUnits: Int = 1_000
    ) {
        self.heartbeatTimeoutMs = heartbeatTimeoutMs
        self.turnDeadlineMs = turnDeadlineMs
        self.taskDeadlineMs = taskDeadlineMs
        self.routineDeadlineMs = routineDeadlineMs
        self.repeatedToolCalls = repeatedToolCalls
        self.repeatedToolErrors = repeatedToolErrors
        self.maxUnitTokens = maxUnitTokens
        self.maxUnitCostUsd = maxUnitCostUsd
        self.goalMaxTotalTokens = goalMaxTotalTokens
        self.goalMaxTotalCostUsd = goalMaxTotalCostUsd
        self.tickMs = tickMs
        self.historyLimit = historyLimit
        self.maxUnits = maxUnits
    }

    public static let `default` = Self()

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case heartbeatTimeoutMs
        case turnDeadlineMs
        case taskDeadlineMs
        case routineDeadlineMs
        case repeatedToolCalls
        case repeatedToolErrors
        case maxUnitTokens
        case maxUnitCostUsd
        case goalMaxTotalTokens
        case goalMaxTotalCostUsd
        case tickMs
        case historyLimit
        case maxUnits
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        for key in raw.allKeys where !known.contains(key.stringValue) {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath + [key],
                debugDescription: "unknown watchdog config member \(key.stringValue)"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func failure(_ key: CodingKeys, _ message: String) -> DecodingError {
            .dataCorrupted(.init(
                codingPath: decoder.codingPath + [AnyCodingKey(stringValue: key.rawValue)],
                debugDescription: message))
        }

        func integer<T: BinaryInteger>(_ key: CodingKeys, _ fallback: T) throws -> T {
            let rawKey = AnyCodingKey(stringValue: key.rawValue)
            guard raw.contains(rawKey) else { return fallback }
            let value = try container.decode(Int64.self, forKey: key)
            guard value >= 0, let converted = T(exactly: value) else {
                throw failure(key, "watchdog config \(key.rawValue) must be a non-negative integer")
            }
            return converted
        }

        func number(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            let rawKey = AnyCodingKey(stringValue: key.rawValue)
            guard raw.contains(rawKey) else { return fallback }
            let value = try container.decode(Double.self, forKey: key)
            guard value.isFinite, value >= 0 else {
                throw failure(key, "watchdog config \(key.rawValue) must be a non-negative finite number")
            }
            return value
        }

        heartbeatTimeoutMs = try integer(.heartbeatTimeoutMs, 120_000)
        turnDeadlineMs = try integer(.turnDeadlineMs, 900_000)
        taskDeadlineMs = try integer(.taskDeadlineMs, 600_000)
        routineDeadlineMs = try integer(.routineDeadlineMs, 660_000)
        repeatedToolCalls = try integer(.repeatedToolCalls, 5)
        repeatedToolErrors = try integer(.repeatedToolErrors, 3)
        maxUnitTokens = try integer(.maxUnitTokens, 200_000)
        maxUnitCostUsd = try number(.maxUnitCostUsd, 2)
        goalMaxTotalTokens = try integer(.goalMaxTotalTokens, 0)
        goalMaxTotalCostUsd = try number(.goalMaxTotalCostUsd, 0)
        tickMs = try integer(.tickMs, 5_000)
        historyLimit = try integer(.historyLimit, 200)
        maxUnits = try integer(.maxUnits, 1_000)
    }

    public func deadlineMs(for kind: BotWatchdogUnitKind, override: Int64? = nil) -> Int64 {
        if let override, override > 0 { return override }
        switch kind {
        case .turn: return turnDeadlineMs
        case .task: return taskDeadlineMs
        case .routine: return routineDeadlineMs
        case .goal: return 0
        }
    }
}

public enum BotWatchdogUnitKind: String, Codable, Sendable, CaseIterable {
    case turn
    case task
    case routine
    case goal
}

public enum BotWatchdogCheck: String, Codable, Sendable, CaseIterable {
    case deadline
    case heartbeat
    case repeatedToolSignature = "repeated_tool_signature"
    case repeatedToolError = "repeated_tool_error"
    case quota
    case webcontentTerminated = "webcontent_terminated"
    case thermalPressure = "thermal_pressure"
    case batteryPressure = "battery_pressure"
}

public enum BotMobileWatchdogEvent: String, Codable, Sendable, CaseIterable {
    case webcontentTerminated = "webcontent_terminated"
    case thermalPressure = "thermal_pressure"
    case batteryPressure = "battery_pressure"

    public var check: BotWatchdogCheck {
        switch self {
        case .webcontentTerminated: return .webcontentTerminated
        case .thermalPressure: return .thermalPressure
        case .batteryPressure: return .batteryPressure
        }
    }
}

public struct BotWatchdogMobileDescriptor: Codable, Sendable, Equatable {
    public let check: BotWatchdogCheck
    public let eventType: String
    public let observeOnly: Bool
    public let oncePerUnit: Bool

    public init(check: BotWatchdogCheck) {
        self.check = check
        self.eventType = "watchdog.flagged"
        self.observeOnly = true
        self.oncePerUnit = true
    }

    public static let frozen = BotMobileWatchdogEvent.allCases.map { Self(check: $0.check) }
}

public struct BotWatchdogUnit: Sendable, Equatable {
    public var kind: BotWatchdogUnitKind
    public var id: String
    public var botId: String?
    public var sessionId: String?
    public var startedAt: Int64
    public var lastEventAt: Int64?
    public var deadlineAt: Int64?
    public var repeatedToolSignatureCount: Int
    public var lastToolSignature: String?
    public var repeatedToolErrorCount: Int
    public var lastToolErrorSignature: String?
    public var pendingApproval: Int
    public var tokens: Int
    public var costUsd: Double

    public init(
        kind: BotWatchdogUnitKind = .turn,
        id: String = "unit",
        botId: String? = nil,
        sessionId: String? = nil,
        startedAt: Int64 = 0,
        lastEventAt: Int64? = nil,
        deadlineAt: Int64? = nil,
        repeatedToolSignatureCount: Int = 0,
        lastToolSignature: String? = nil,
        repeatedToolErrorCount: Int = 0,
        lastToolErrorSignature: String? = nil,
        pendingApproval: Int = 0,
        tokens: Int = 0,
        costUsd: Double = 0
    ) {
        self.kind = kind
        self.id = id
        self.botId = botId
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.deadlineAt = deadlineAt
        self.repeatedToolSignatureCount = repeatedToolSignatureCount
        self.lastToolSignature = lastToolSignature
        self.repeatedToolErrorCount = repeatedToolErrorCount
        self.lastToolErrorSignature = lastToolErrorSignature
        self.pendingApproval = pendingApproval
        self.tokens = tokens
        self.costUsd = costUsd
    }
}

public struct BotWatchdogFinding: Codable, Sendable, Equatable {
    public let check: BotWatchdogCheck
    public let evidence: BotJSONValue

    public init(check: BotWatchdogCheck, evidence: [String: BotJSONValue]) {
        self.check = check
        self.evidence = .object(evidence)
    }

    public init(check: BotWatchdogCheck, evidence: BotJSONValue) {
        self.check = check
        self.evidence = evidence
    }
}

public struct BotWatchdogFlag: Sendable, Equatable {
    public let unitKind: BotWatchdogUnitKind
    public let unitId: String
    public let botId: String?
    public let sessionId: String?
    public let check: BotWatchdogCheck
    public let evidence: BotJSONValue
    public let at: Int64
    public let eventId: String
    public let commitSeq: Int?
}

func botWatchdogNumber(_ value: Int64) -> BotJSONValue { .number(Double(value)) }
func botWatchdogNumber(_ value: Int) -> BotJSONValue { .number(Double(value)) }
func botWatchdogNumber(_ value: Double) -> BotJSONValue { .number(value) }
func botWatchdogString(_ value: String?) -> BotJSONValue { value.map(BotJSONValue.string) ?? .null }

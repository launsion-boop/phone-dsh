// SPDX-License-Identifier: MIT
#if BOT_RESIDENCY_SPIKE

import Foundation

public struct BotResidencyConfiguration: Codable, Sendable {
    public var runID: String
    public var durationSeconds: Int
    public var eventCount: Int
    public var killCount: Int
    public var seed: UInt64

    public init(runID: String, durationSeconds: Int, eventCount: Int, killCount: Int, seed: UInt64) {
        self.runID = runID
        self.durationSeconds = durationSeconds
        self.eventCount = eventCount
        self.killCount = killCount
        self.seed = seed
    }

    public static func parse(_ arguments: [String] = ProcessInfo.processInfo.arguments) throws -> Self {
        func value(_ name: String) throws -> String {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                throw BotResidencyConfigurationError.missing(name)
            }
            return arguments[index + 1]
        }
        let runID = try value("--run-id")
        guard runID.range(of: #"^[a-zA-Z0-9-]{1,80}$"#, options: .regularExpression) != nil else {
            throw BotResidencyConfigurationError.invalid("run-id")
        }
        guard let duration = Int(try value("--duration-seconds")), duration > 0 else {
            throw BotResidencyConfigurationError.invalid("duration-seconds")
        }
        guard let events = Int(try value("--events")), events > 0, events <= 1000 else {
            throw BotResidencyConfigurationError.invalid("events")
        }
        guard let kills = Int(try value("--kill-webcontent")), kills >= 0, kills <= 100 else {
            throw BotResidencyConfigurationError.invalid("kill-webcontent")
        }
        guard let seed = UInt64(try value("--seed")) else {
            throw BotResidencyConfigurationError.invalid("seed")
        }
        return Self(runID: runID, durationSeconds: duration, eventCount: events,
                    killCount: kills, seed: seed)
    }
}

public enum BotResidencyConfigurationError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .missing(let name): return "missing launch argument \(name)"
        case .invalid(let name): return "invalid launch argument --\(name)"
        }
    }
}

public struct BotResidencyScheduledAction: Codable, Sendable {
    public var id: String
    public var offsetSeconds: Double

    public init(id: String, offsetSeconds: Double) {
        self.id = id
        self.offsetSeconds = offsetSeconds
    }
}

public struct BotResidencyPlan: Codable, Sendable {
    public var configuration: BotResidencyConfiguration
    public var startedAt: String
    public var events: [BotResidencyScheduledAction]
    public var kills: [BotResidencyScheduledAction]

    public init(configuration: BotResidencyConfiguration, startedAt: String,
                events: [BotResidencyScheduledAction], kills: [BotResidencyScheduledAction]) {
        self.configuration = configuration
        self.startedAt = startedAt
        self.events = events
        self.kills = kills
    }
}

public struct BotResidencyEventRecord: Codable, Sendable {
    public var id: String
    public var index: Int
    public var requestID: String
    public var scheduledOffsetSeconds: Double
    public var injectedAt: String?
    public var acceptedAt: String?
    public var deliveredAt: String?
    public var deliveryLatencySeconds: Double?
    public var promptAttempts: Int = 0
    public var turnIDs: [String] = []
    public var userSequenceNumbers: [UInt64] = []
    public var successfulToolResults: Int = 0
    public var failedToolResults: Int = 0
    public var finalAssistantMessages: Int = 0
    public var turnEndCount: Int = 0
    public var lastError: String?

    public init(id: String, index: Int, requestID: String, scheduledOffsetSeconds: Double) {
        self.id = id
        self.index = index
        self.requestID = requestID
        self.scheduledOffsetSeconds = scheduledOffsetSeconds
    }
}

public struct BotResidencyRecoveryRecord: Codable, Sendable {
    public var index: Int
    public var terminatedAt: String
    public var wasForeground: Bool
    public var helloBefore: UInt64
    public var helloAfter: UInt64?
    public var recoveredAt: String?
    public var recoverySeconds: Double?
    public var recoveryWorkSeconds: Double?
    public var restartReason: String?
    public var p6Deferred: Bool
    public var p6Violation: Bool

    public init(index: Int, terminatedAt: String, wasForeground: Bool,
                helloBefore: UInt64, p6Deferred: Bool) {
        self.index = index
        self.terminatedAt = terminatedAt
        self.wasForeground = wasForeground
        self.helloBefore = helloBefore
        self.p6Deferred = p6Deferred
        self.p6Violation = false
    }
}

public struct BotResidencyState: Codable, Sendable {
    public var runID: String
    public var updatedAt: String
    public var phase: String
    public var runStartedAt: String?
    public var durationReachedAt: String?
    public var webContentPID: Int?
    public var webContentPIDStatus: String
    public var workerHelloCount: UInt64
    public var webContentTerminations: UInt64
    public var injectedEvents: Int
    public var deliveredEvents: Int
    public var pendingEvents: Int
    public var modelRequestCount: Int
    public var detail: String?

    public init(runID: String, updatedAt: String, phase: String) {
        self.runID = runID
        self.updatedAt = updatedAt
        self.phase = phase
        self.webContentPIDStatus = "not-read"
        self.workerHelloCount = 0
        self.webContentTerminations = 0
        self.injectedEvents = 0
        self.deliveredEvents = 0
        self.pendingEvents = 0
        self.modelRequestCount = 0
    }
}

public struct BotResidencyAppReport: Codable, Sendable {
    public var schema = "phonedsh-bot-residency-app/1"
    public var configuration: BotResidencyConfiguration
    public var status: String
    public var reason: String?
    public var runStartedAt: String?
    public var runEndedAt: String?
    public var durationReachedAt: String?
    public var lockEndedAt: String?
    public var observedLockSeconds: Double
    public var protectedDataLockObserved: Bool
    public var protectedDataUnlockObserved: Bool
    public var p6DeferredCount: Int
    public var p6ViolationCount: Int
    public var helloFailureCount: Int
    public var p15FailureCount: Int
    public var modelRequestCount: Int
    public var events: [BotResidencyEventRecord]
    public var recoveries: [BotResidencyRecoveryRecord]

    public init(configuration: BotResidencyConfiguration, status: String, reason: String?,
                runStartedAt: String?, runEndedAt: String?, durationReachedAt: String?,
                lockEndedAt: String?, observedLockSeconds: Double,
                protectedDataLockObserved: Bool, protectedDataUnlockObserved: Bool,
                p6DeferredCount: Int, p6ViolationCount: Int,
                helloFailureCount: Int, p15FailureCount: Int, modelRequestCount: Int,
                events: [BotResidencyEventRecord], recoveries: [BotResidencyRecoveryRecord]) {
        self.configuration = configuration
        self.status = status
        self.reason = reason
        self.runStartedAt = runStartedAt
        self.runEndedAt = runEndedAt
        self.durationReachedAt = durationReachedAt
        self.lockEndedAt = lockEndedAt
        self.observedLockSeconds = observedLockSeconds
        self.protectedDataLockObserved = protectedDataLockObserved
        self.protectedDataUnlockObserved = protectedDataUnlockObserved
        self.p6DeferredCount = p6DeferredCount
        self.p6ViolationCount = p6ViolationCount
        self.helloFailureCount = helloFailureCount
        self.p15FailureCount = p15FailureCount
        self.modelRequestCount = modelRequestCount
        self.events = events
        self.recoveries = recoveries
    }
}

public struct BotResidencyLogEntry: Codable, Sendable {
    public var at: String
    public var monotonicSeconds: Double
    public var kind: String
    public var id: String?
    public var turnID: String?
    public var seq: UInt64?
    public var count: Int?
    public var seconds: Double?
    public var detail: String?

    public init(at: String, monotonicSeconds: Double, kind: String, id: String? = nil,
                turnID: String? = nil, seq: UInt64? = nil, count: Int? = nil,
                seconds: Double? = nil, detail: String? = nil) {
        self.at = at
        self.monotonicSeconds = monotonicSeconds
        self.kind = kind
        self.id = id
        self.turnID = turnID
        self.seq = seq
        self.count = count
        self.seconds = seconds
        self.detail = detail
    }
}

@MainActor
public final class BotResidencyEvidenceStore {
    public let root: URL
    private let encoder: JSONEncoder

    public init(runID: String) throws {
        let documents = try FileManager.default.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        root = documents.appendingPathComponent("BotResidencySpike", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: root.path)
    }

    public var workspace: URL {
        root.appendingPathComponent("workspace", isDirectory: true)
    }

    public func append(_ entry: BotResidencyLogEntry) {
        do {
            var data = try encoder.encode(entry)
            data.append(Data("\n".utf8))
            let url = root.appendingPathComponent("app-events.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw BotResidencyEvidenceError.cannotCreateLog
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try? FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ], ofItemAtPath: url.path)
        } catch {
            NSLog("bot-residency evidence append failed: %@", String(describing: error))
        }
    }

    public func writeState(_ state: BotResidencyState) {
        write(state, name: "state.json")
    }

    public func writePlan(_ plan: BotResidencyPlan) {
        write(plan, name: "plan.json")
    }

    public func writeReport(_ report: BotResidencyAppReport) {
        write(report, name: "app-report.json")
    }

    private func write<T: Encodable>(_ value: T, name: String) {
        do {
            let data = try encoder.encode(value)
            let url = root.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ], ofItemAtPath: url.path)
        } catch {
            NSLog("bot-residency evidence write failed: %@", String(describing: error))
        }
    }
}

public enum BotResidencyTime {
    public static func string(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
#endif

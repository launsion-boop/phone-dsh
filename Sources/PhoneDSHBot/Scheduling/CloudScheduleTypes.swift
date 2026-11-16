// SPDX-License-Identifier: MIT

import Foundation

/// Wire-independent domain types for the reliable cloud scheduler client.
///
/// Frozen contract: `spec/cloud/v1` (G-3, `contracts/G-3.md`). The cloud may
/// only carry opaque ids, times, revisions and closed receipt enums;
/// `CloudScheduleSpec` deliberately contains schedule timing only, so a
/// routine's prompt/title/completion criteria cannot leak into a request.

public enum CloudScheduleOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case delivered
    case skipped
    case failed
    case cancelled
    case unknown
}

/// Frozen closed reason set (`bot-cloud-ack/v1`). It carries no user text.
public enum CloudScheduleReason: String, Codable, Sendable, Equatable, CaseIterable {
    case overlap
    case quiet
    case disabled
    case revoked
    case needsReconciliation = "needs_reconciliation"
    case crash
    case timeout
    case unavailable
    case localAttempt = "local_attempt"
    case superseded
    case userStopped = "user_stopped"
    case runFailed = "run_failed"
}

/// Timing-only projection of `RoutineSchedule` using the frozen wire names.
public struct CloudScheduleSpec: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case interval
        case daily
        case weekly
        case cron
    }

    public var kind: Kind
    public var intervalMinutes: Int?
    public var phaseMinutes: Int?
    public var localTime: String?
    public var weekdays: [Int]?
    public var cron: String?
    public var timezone: String

    public init(kind: Kind, intervalMinutes: Int? = nil, phaseMinutes: Int? = nil,
                localTime: String? = nil, weekdays: [Int]? = nil,
                cron: String? = nil, timezone: String) {
        self.kind = kind
        self.intervalMinutes = intervalMinutes
        self.phaseMinutes = phaseMinutes
        self.localTime = localTime
        self.weekdays = weekdays
        self.cron = cron
        self.timezone = timezone
    }

    /// Maps the local routine schedule onto the frozen wire shape.
    ///
    /// `phaseMinutes` is deliberately not projected: the frozen wire defines it
    /// as a 0–59 minute-of-hour offset while the local `RoutineSchedule`
    /// carries an arbitrary interval offset. The client refuses to register a
    /// phased routine until the two semantics are frozen as one; local
    /// best-effort scheduling keeps running such a routine without cloud.
    public init(_ schedule: RoutineSchedule) {
        var weekdays = schedule.weekdays
        weekdays?.sort()
        self.init(kind: Kind(rawValue: schedule.kind.rawValue) ?? .interval,
                  intervalMinutes: schedule.everyMinutes,
                  phaseMinutes: nil,
                  localTime: schedule.time,
                  weekdays: weekdays,
                  cron: schedule.expr,
                  timezone: schedule.timezone)
    }
}

public struct CloudScheduleRemoval: Codable, Sendable, Equatable {
    public var routineID: String
    public var revision: Int64

    public init(routineID: String, revision: Int64) {
        self.routineID = routineID
        self.revision = revision
    }
}

public struct CloudScheduleRegistration: Codable, Sendable, Equatable {
    public var routineID: String
    public var botID: String
    public var revision: Int64
    public var enabled: Bool
    public var schedule: CloudScheduleSpec
    public var catchUp: String
    public var authorizationRef: String?
    /// `register` for the first cloud revision, `update` afterwards.
    public var operation: String

    public init(routineID: String, botID: String, revision: Int64, enabled: Bool,
                schedule: CloudScheduleSpec, catchUp: String = "latest",
                authorizationRef: String? = nil, operation: String = "register") {
        self.routineID = routineID
        self.botID = botID
        self.revision = revision
        self.enabled = enabled
        self.schedule = schedule
        self.catchUp = catchUp
        self.authorizationRef = authorizationRef
        self.operation = operation
    }
}

public struct CloudScheduleSyncRequest: Codable, Sendable, Equatable {
    public var deviceID: String
    public var botID: String
    public var registrations: [CloudScheduleRegistration]
    public var removed: [CloudScheduleRemoval]

    public init(deviceID: String, botID: String,
                registrations: [CloudScheduleRegistration] = [],
                removed: [CloudScheduleRemoval] = []) {
        self.deviceID = deviceID
        self.botID = botID
        self.registrations = registrations
        self.removed = removed
    }
}

public struct CloudScheduleSyncRejection: Codable, Sendable, Equatable {
    public var routineID: String
    public var code: String
    public var currentRevision: Int64?

    public init(routineID: String, code: String, currentRevision: Int64? = nil) {
        self.routineID = routineID
        self.code = code
        self.currentRevision = currentRevision
    }
}

public struct CloudScheduleSyncResponse: Codable, Sendable, Equatable {
    public var serverTimeMS: Int64
    public var accepted: [CloudScheduleRegistration]
    public var removedAccepted: [String]
    /// Server revision after a DELETE (the frozen schedule-response echoes it).
    public var removedRevisions: [String: Int64]
    public var rejected: [CloudScheduleSyncRejection]

    public init(serverTimeMS: Int64, accepted: [CloudScheduleRegistration] = [],
                removedAccepted: [String] = [], removedRevisions: [String: Int64] = [:],
                rejected: [CloudScheduleSyncRejection] = []) {
        self.serverTimeMS = serverTimeMS
        self.accepted = accepted
        self.removedAccepted = removedAccepted
        self.removedRevisions = removedRevisions
        self.rejected = rejected
    }
}

public struct CloudScheduleLease: Codable, Sendable, Equatable {
    public var leaseID: String
    public var attempt: Int
    public var expiresAtMS: Int64

    public init(leaseID: String, attempt: Int, expiresAtMS: Int64) {
        self.leaseID = leaseID
        self.attempt = attempt
        self.expiresAtMS = expiresAtMS
    }
}

/// One occurrence as the frozen wire defines it. `occurrenceKey` is the
/// phone-side idempotency key; it is also the source of the deterministic
/// `local_run_id` (`cloud-<occurrence_key>`).
public struct CloudScheduleEvent: Codable, Sendable, Equatable {
    public var eventID: String
    public var deviceID: String
    public var botID: String
    public var routineID: String
    public var occurrenceKey: String
    public var occurrenceAtMS: Int64
    public var scheduledForMS: Int64
    public var scheduleRevision: Int64
    public var lease: CloudScheduleLease

    public init(eventID: String, deviceID: String, botID: String, routineID: String,
                occurrenceKey: String, occurrenceAtMS: Int64, scheduledForMS: Int64,
                scheduleRevision: Int64, lease: CloudScheduleLease) {
        self.eventID = eventID
        self.deviceID = deviceID
        self.botID = botID
        self.routineID = routineID
        self.occurrenceKey = occurrenceKey
        self.occurrenceAtMS = occurrenceAtMS
        self.scheduledForMS = scheduledForMS
        self.scheduleRevision = scheduleRevision
        self.lease = lease
    }

    public var localRunID: String { RoutineScheduler.cloudRunId(occurrenceKey: occurrenceKey) }
}

public struct CloudSchedulePollRequest: Codable, Sendable, Equatable {
    public var deviceID: String
    public var botID: String
    public var limit: Int
    public var leaseSeconds: Int

    public init(deviceID: String, botID: String, limit: Int, leaseSeconds: Int) {
        self.deviceID = deviceID
        self.botID = botID
        self.limit = limit
        self.leaseSeconds = leaseSeconds
    }
}

public struct CloudSchedulePollResponse: Codable, Sendable, Equatable {
    public var serverTimeMS: Int64
    public var events: [CloudScheduleEvent]

    public init(serverTimeMS: Int64, events: [CloudScheduleEvent] = []) {
        self.serverTimeMS = serverTimeMS
        self.events = events
    }
}

public struct CloudScheduleReceiptRequest: Codable, Sendable, Equatable {
    public var deviceID: String
    public var eventID: String
    public var receiptID: String
    public var occurrenceKey: String
    public var outcome: CloudScheduleOutcome
    public var reason: CloudScheduleReason?
    public var completedAtMS: Int64
    public var localRunID: String

    public init(deviceID: String, eventID: String, receiptID: String,
                occurrenceKey: String, outcome: CloudScheduleOutcome,
                reason: CloudScheduleReason?, completedAtMS: Int64, localRunID: String) {
        self.deviceID = deviceID
        self.eventID = eventID
        self.receiptID = receiptID
        self.occurrenceKey = occurrenceKey
        self.outcome = outcome
        self.reason = reason
        self.completedAtMS = completedAtMS
        self.localRunID = localRunID
    }
}

public struct CloudScheduleReceiptResponse: Codable, Sendable, Equatable {
    public var accepted: Bool
    public var duplicate: Bool
    public var state: String?

    public init(accepted: Bool, duplicate: Bool = false, state: String? = nil) {
        self.accepted = accepted
        self.duplicate = duplicate
        self.state = state
    }
}

public struct CloudScheduleReconcileRequest: Codable, Sendable, Equatable {
    public var deviceID: String
    public var sinceMS: Int64
    public var limit: Int

    public init(deviceID: String, sinceMS: Int64, limit: Int) {
        self.deviceID = deviceID
        self.sinceMS = sinceMS
        self.limit = limit
    }
}

public struct CloudScheduleReconcileResponse: Codable, Sendable, Equatable {
    public var serverTimeMS: Int64
    public var events: [CloudScheduleEvent]
    public var nextCursorMS: Int64

    public init(serverTimeMS: Int64, events: [CloudScheduleEvent] = [],
                nextCursorMS: Int64 = 0) {
        self.serverTimeMS = serverTimeMS
        self.events = events
        self.nextCursorMS = nextCursorMS
    }
}

public struct CloudScheduleCancelRequest: Codable, Sendable, Equatable {
    public var deviceID: String
    public var routineID: String
    public var expectedRevision: Int64

    public init(deviceID: String, routineID: String, expectedRevision: Int64) {
        self.deviceID = deviceID
        self.routineID = routineID
        self.expectedRevision = expectedRevision
    }
}

public struct CloudScheduleEventCancelRequest: Codable, Sendable, Equatable {
    public var deviceID: String
    public var eventID: String
    public var reason: String

    public init(deviceID: String, eventID: String, reason: String) {
        self.deviceID = deviceID
        self.eventID = eventID
        self.reason = reason
    }
}

/// Stable, closed failures the client distinguishes. Unknown server codes map
/// to `.invalidRequest`/`.server` and are surfaced as diagnostics, never
/// silently treated as success.
public enum CloudScheduleTransportError: Error, Sendable, Equatable {
    case unauthenticated
    case forbidden
    case notFound
    case conflict(code: String, currentRevision: Int64?)
    case rateLimited(retryAfterMS: Int64?)
    case invalidRequest(code: String)
    case server(retryable: Bool, retryAfterMS: Int64?)
    case transport(String)
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .transport:
            return true
        case .server(let retryable, _):
            return retryable
        case .unauthenticated, .forbidden, .notFound, .conflict, .invalidRequest, .cancelled:
            return false
        }
    }

    public var diagnosticCode: String {
        switch self {
        case .unauthenticated: return "unauthenticated"
        case .forbidden: return "forbidden"
        case .notFound: return "not_found"
        case .conflict(let code, _): return "conflict:\(code)"
        case .rateLimited: return "rate_limited"
        case .invalidRequest(let code): return "invalid_request:\(code)"
        case .server: return "server"
        case .transport: return "transport"
        case .cancelled: return "cancelled"
        }
    }
}

/// Transport seam. The production implementation speaks the frozen
/// `spec/cloud/v1` HTTP contract with `URLSession`; unit and failure-injection
/// tests replace it without touching the client state machine.
public protocol CloudScheduleTransport: Sendable {
    func sync(_ request: CloudScheduleSyncRequest) async throws -> CloudScheduleSyncResponse
    func poll(_ request: CloudSchedulePollRequest) async throws -> CloudSchedulePollResponse
    func acknowledge(_ request: CloudScheduleReceiptRequest) async throws -> CloudScheduleReceiptResponse
    func reconcile(_ request: CloudScheduleReconcileRequest) async throws -> CloudScheduleReconcileResponse
    func cancelRoutine(_ request: CloudScheduleCancelRequest) async throws
    func cancelEvent(_ request: CloudScheduleEventCancelRequest) async throws
}

/// Local goal/permission split: the cloud may only wake a routine when this
/// returns nil. Assembly composes routine.cloud_schedule with the native
/// source consent (N) and proactive suppression (F); the default implementation
/// only checks the routine-local permission.
public protocol CloudScheduleAuthorizing: Sendable {
    func refusal(for routine: Routine) async -> CloudScheduleReason?
}

public struct CloudScheduleAuthorizer: CloudScheduleAuthorizing {
    public init() {}

    public func refusal(for routine: Routine) async -> CloudScheduleReason? {
        guard routine.enabled else { return .disabled }
        guard routine.cloudSchedule?.enabled == true else { return .revoked }
        return nil
    }
}

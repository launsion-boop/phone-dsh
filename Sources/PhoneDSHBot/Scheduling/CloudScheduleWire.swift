// SPDX-License-Identifier: MIT
//
// Frozen wire codec for `spec/cloud/v1` (G-3B, `contracts/G-3.md`). Message
// shapes are closed: only opaque ids, ms times, revisions and closed enums.
// A routine's prompt/title/result can never be encoded here because these
// types have no such field, and the validator rejects those names.

import Foundation

enum CloudScheduleWire {
    static let scheduleRequestSchema = "bot-cloud-schedule-request/v1"
    static let scheduleResponseSchema = "bot-cloud-schedule-response/v1"
    static let pollRequestSchema = "bot-cloud-poll-request/v1"
    static let pollResponseSchema = "bot-cloud-poll-response/v1"
    static let ackSchema = "bot-cloud-ack/v1"
    static let reconcileRequestSchema = "bot-cloud-reconcile-request/v1"
    static let reconcileResponseSchema = "bot-cloud-reconcile-response/v1"

    struct ScheduleSpec: Codable, Equatable {
        var kind: String
        var timezone: String
        var intervalMinutes: Int?
        var localTime: String?
        var weekdays: [Int]?
        var cron: String?
        var phaseMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case kind, timezone, weekdays, cron
            case intervalMinutes = "interval_minutes"
            case localTime = "local_time"
            case phaseMinutes = "phase_minutes"
        }
    }

    struct ScheduleRequest: Codable, Equatable {
        var schema: String = CloudScheduleWire.scheduleRequestSchema
        var op: String
        var deviceID: String
        var botID: String
        var routineID: String
        var revision: Int64
        var enabled: Bool
        var schedule: ScheduleSpec
        var catchUp: String
        var authorizationRef: String?

        enum CodingKeys: String, CodingKey {
            case schema, op, revision, enabled, schedule
            case deviceID = "device_id"
            case botID = "bot_id"
            case routineID = "routine_id"
            case catchUp = "catch_up"
            case authorizationRef = "authorization_ref"
        }
    }

    struct ScheduleResponse: Codable, Equatable {
        var schema: String
        var scheduleID: String
        var revision: Int64
        var nextDueAtMS: Int64?

        enum CodingKeys: String, CodingKey {
            case schema, revision
            case scheduleID = "schedule_id"
            case nextDueAtMS = "next_due_at_ms"
        }
    }

    struct PollRequest: Codable, Equatable {
        var schema: String = CloudScheduleWire.pollRequestSchema
        var deviceID: String
        var botID: String?
        var limit: Int
        var leaseSeconds: Int

        enum CodingKeys: String, CodingKey {
            case schema, limit
            case deviceID = "device_id"
            case botID = "bot_id"
            case leaseSeconds = "lease_s"
        }
    }

    struct Lease: Codable, Equatable {
        var leaseID: String
        var attempt: Int
        var expiresAtMS: Int64

        enum CodingKeys: String, CodingKey {
            case attempt
            case leaseID = "lease_id"
            case expiresAtMS = "expires_at_ms"
        }
    }

    struct Event: Codable, Equatable {
        var eventID: String
        var deviceID: String
        var botID: String
        var routineID: String
        var occurrenceKey: String
        var occurrenceAtMS: Int64
        var scheduledForMS: Int64
        var scheduleRevision: Int64
        var lease: Lease
        var state: String?
        var receipt: TerminalReceipt?

        struct TerminalReceipt: Codable, Equatable {
            var receiptID: String
            var outcome: String
            var reason: String?

            enum CodingKeys: String, CodingKey {
                case outcome, reason
                case receiptID = "receipt_id"
            }
        }

        enum CodingKeys: String, CodingKey {
            case lease, state, receipt
            case eventID = "event_id"
            case deviceID = "device_id"
            case botID = "bot_id"
            case routineID = "routine_id"
            case occurrenceKey = "occurrence_key"
            case occurrenceAtMS = "occurrence_at_ms"
            case scheduledForMS = "scheduled_for_ms"
            case scheduleRevision = "schedule_revision"
        }
    }

    struct PollResponse: Codable, Equatable {
        var schema: String
        var events: [Event]
        var serverTimeMS: Int64

        enum CodingKeys: String, CodingKey {
            case schema, events
            case serverTimeMS = "server_time_ms"
        }
    }

    struct AckReceipt: Codable, Equatable {
        var receiptID: String
        var occurrenceKey: String
        var outcome: String
        var reason: String?
        var completedAtMS: Int64
        var localRunID: String?

        enum CodingKeys: String, CodingKey {
            case outcome, reason
            case receiptID = "receipt_id"
            case occurrenceKey = "occurrence_key"
            case completedAtMS = "completed_at_ms"
            case localRunID = "local_run_id"
        }
    }

    struct AckRequest: Codable, Equatable {
        var schema: String = CloudScheduleWire.ackSchema
        var deviceID: String
        var eventID: String
        var receipt: AckReceipt

        enum CodingKeys: String, CodingKey {
            case schema, receipt
            case deviceID = "device_id"
            case eventID = "event_id"
        }
    }

    struct ReconcileRequest: Codable, Equatable {
        var schema: String = CloudScheduleWire.reconcileRequestSchema
        var deviceID: String
        var sinceMS: Int64
        var limit: Int
        var includeTerminal: Bool

        enum CodingKeys: String, CodingKey {
            case schema, limit
            case deviceID = "device_id"
            case sinceMS = "since_ms"
            case includeTerminal = "include_terminal"
        }
    }

    struct ReconcileResponse: Codable, Equatable {
        var schema: String
        var events: [Event]
        var nextCursorMS: Int64
        var serverTimeMS: Int64

        enum CodingKeys: String, CodingKey {
            case schema, events
            case nextCursorMS = "next_cursor_ms"
            case serverTimeMS = "server_time_ms"
        }
    }

    struct AckResponse: Codable, Equatable {
        var schema: String
        var accepted: Bool
        var duplicate: Bool
        var state: String?
        var serverTimeMS: Int64

        enum CodingKeys: String, CodingKey {
            case schema, accepted, duplicate, state
            case serverTimeMS = "server_time_ms"
        }
    }

    struct ErrorReceipt: Codable, Equatable {
        var receiptID: String
        var outcome: String

        enum CodingKeys: String, CodingKey {
            case outcome
            case receiptID = "receipt_id"
        }
    }

    struct ErrorBody: Codable, Equatable {
        var schema: String?
        var code: String?
        var state: String?
        var receipt: ErrorReceipt?
        var serverTimeMS: Int64?
        var message: String?
        var retryable: Bool?
        var retryAfterMS: Int64?
        var revision: Int64?

        enum CodingKeys: String, CodingKey {
            case schema, code, state, receipt, message, retryable, revision
            case serverTimeMS = "server_time_ms"
            case retryAfterMS = "retry_after_ms"
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func spec(from schedule: CloudScheduleSpec) -> ScheduleSpec {
        ScheduleSpec(kind: schedule.kind.rawValue,
                     timezone: schedule.timezone,
                     intervalMinutes: schedule.intervalMinutes,
                     localTime: schedule.localTime,
                     weekdays: schedule.weekdays,
                     cron: schedule.cron,
                     phaseMinutes: schedule.phaseMinutes)
    }

    static func event(from wire: Event) -> CloudScheduleEvent {
        CloudScheduleEvent(
            eventID: wire.eventID, deviceID: wire.deviceID, botID: wire.botID,
            routineID: wire.routineID, occurrenceKey: wire.occurrenceKey,
            occurrenceAtMS: wire.occurrenceAtMS, scheduledForMS: wire.scheduledForMS,
            scheduleRevision: wire.scheduleRevision,
            lease: CloudScheduleLease(leaseID: wire.lease.leaseID,
                                      attempt: wire.lease.attempt,
                                      expiresAtMS: wire.lease.expiresAtMS),
            state: wire.state)
    }

    static func outcome(from raw: String) -> CloudScheduleOutcome? {
        CloudScheduleOutcome(rawValue: raw)
    }

    static func reason(from raw: String?) -> CloudScheduleReason? {
        guard let raw else { return nil }
        return CloudScheduleReason(rawValue: raw)
    }
}

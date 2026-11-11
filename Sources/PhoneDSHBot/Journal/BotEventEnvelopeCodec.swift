// SPDX-License-Identifier: MIT

import Foundation

public enum BotEventValidationMode: Sendable {
    case append
    case stored
}

public struct BotEventValidationError: Error, Sendable, Equatable {
    public let code: String
    public let field: String
    public let message: String

    public init(code: String, field: String, message: String) {
        self.code = code
        self.field = field
        self.message = message
    }

    static func invalid(_ field: String, _ message: String) -> Self {
        Self(code: "INVALID_EVENT", field: field, message: message)
    }
}

public struct BotEventEnvelopeCodec: Sendable {
    public static let durableEventTypes: Set<String> = [
        "conversation.turn_started", "conversation.user_message", "conversation.assistant_message",
        "conversation.tool_call", "conversation.tool_result", "conversation.turn_ended",
        "conversation.automation_run", "approval.requested", "approval.decided", "grant.created",
        "grant.added", "grant.consumed", "grant.revoked", "grant.migrated", "card.presented",
        "card.answered", "card.dismissed",
        "ui.system_event", "ui.notice", "ui.send_to_user", "transcript.rollback",
        "transcript.row_deleted", "transcript.imported", "bot.greeting_seeded", "bot.created",
        "comm.outbound", "comm.inbound", "comm.reply", "comm.failed", "agent.comm",
        "task.created", "task.started",
        "task.updated", "task.stop_requested", "task.settled", "task.resumed", "background.started",
        "background.stop_requested", "background.settled", "routine.defined", "routine.updated",
        "routine.deleted", "routine.run_started", "routine.run_finished", "memory.written",
        "memory.forgotten", "memory.document_written", "memory.document_deleted",
        "memory.imported", "memory.review_requested", "memory.review_resolved",
        "memory.maintenance_started", "memory.maintenance_finished",
        "memory.maintenance_rolled_back",
        "effect.enqueued", "effect.attempted", "effect.acked", "effect.failed", "effect.dead_lettered",
        "effect.reconciliation_required", "effect.cancel_requested", "effect.canceled", "runtime.started",
        "runtime.exited", "proactive.considered", "ledger.usage_recorded", "watchdog.flagged",
        "verification.reported", "redaction.applied", "erasure",
    ]

    public static let ephemeralEventTypes: Set<String> = [
        "model.delta", "model.started", "model.settled", "tool.progress", "agent.status", "fish.action",
        "runtime.stderr", "runtime.notification", "projection.invalidated", "journal.backpressure",
        "approval.card_available",
    ]

    private static let localOriginSources: Set<String> = [
        "ipc", "card-bridge", "mcp", "scheduler", "task-manager", "memory-service", "comm-service",
        "projector", "effect-runner", "runtime", "user", "watchdog", "background-supervisor",
    ]

    private static let principalKinds: Set<String> = [
        "chat", "task", "routine", "verifier", "team", "proactive", "watchdog", "maintainer", "ipc",
    ]

    public init() {}

    public static func isEphemeral(_ type: String) -> Bool {
        ephemeralEventTypes.contains(type)
    }

    public static func isDurable(_ type: String) -> Bool {
        durableEventTypes.contains(type)
    }

    public static func validate(_ event: BotEvent, mode: BotEventValidationMode = .stored) throws {
        guard event.schemaVersion <= BotEvent.currentSchemaVersion else {
            throw BotEventValidationError(
                code: "SCHEMA_TOO_NEW", field: "schemaVersion",
                message: "schemaVersion \(event.schemaVersion) is newer than \(BotEvent.currentSchemaVersion); reader is read-only")
        }
        guard event.schemaVersion == BotEvent.currentSchemaVersion else {
            throw BotEventValidationError.invalid("schemaVersion", "schemaVersion must be 1")
        }
        guard !event.eventId.isEmpty else {
            throw BotEventValidationError.invalid("eventId", "eventId must not be empty")
        }
        guard !event.traceId.isEmpty else {
            throw BotEventValidationError.invalid("traceId", "traceId must not be empty")
        }
        guard event.time >= 0 else {
            throw BotEventValidationError.invalid("time", "time must not be negative")
        }
        guard principalKinds.contains(event.principal.kind) else {
            throw BotEventValidationError.invalid("principal.kind", "unknown principal kind")
        }
        switch event.origin {
        case let .dsh(sessionId, seq):
            guard !sessionId.isEmpty, seq >= 0 else {
                throw BotEventValidationError.invalid("origin", "DSH origin requires sessionId and non-negative seq")
            }
        case let .local(source):
            guard localOriginSources.contains(source) else {
                throw BotEventValidationError.invalid("origin.source", "unknown local origin source")
            }
        }
        if let attempt = event.attempt, attempt < 1 {
            throw BotEventValidationError.invalid("attempt", "attempt must be a positive integer")
        }
        if let turnId = event.turnId, turnId.isEmpty {
            throw BotEventValidationError.invalid("turnId", "turnId must not be empty")
        }
        if let runId = event.runId, runId.isEmpty {
            throw BotEventValidationError.invalid("runId", "runId must not be empty")
        }
        if let batch = event.batch {
            guard !batch.id.isEmpty, batch.total >= 1, batch.index >= 0, batch.index < batch.total else {
                throw BotEventValidationError.invalid("batch", "invalid batch reference")
            }
        }
        if let ignorable = event.ignorable, !ignorable {
            throw BotEventValidationError.invalid("ignorable", "ignorable may only be true or omitted")
        }
        guard case .object = event.data else {
            throw BotEventValidationError.invalid("data", "event data must be an object")
        }

        let ephemeral = isEphemeral(event.type)
        if ephemeral {
            guard event.commitSeq == nil else {
                throw BotEventValidationError(
                    code: "EPHEMERAL_HAS_COMMIT_SEQ", field: "commitSeq",
                    message: "ephemeral events must not carry commitSeq")
            }
            return
        }

        if !isDurable(event.type), event.ignorable != true {
            throw BotEventValidationError(
                code: "UNKNOWN_REQUIRED_EVENT", field: "type",
                message: "unknown event type \"\(event.type)\" is not ignorable; refusing to skip it")
        }

        switch mode {
        case .append:
            guard event.commitSeq == nil else {
                throw BotEventValidationError(
                    code: "COMMIT_SEQ_ASSIGNED_BY_STORE", field: "commitSeq",
                    message: "commitSeq is assigned by SQLite and must not be provided")
            }
        case .stored:
            guard let commitSeq = event.commitSeq else {
                throw BotEventValidationError(
                    code: "MISSING_COMMIT_SEQ", field: "commitSeq",
                    message: "durable events require a commitSeq")
            }
            guard commitSeq >= 1 else {
                throw BotEventValidationError.invalid("commitSeq", "commitSeq must be positive")
            }
        }
    }

    public func encode(_ event: BotEvent) throws -> Data {
        try Self.validate(event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(event)
    }

    public func decode(_ data: Data) throws -> BotEvent {
        let event = try JSONDecoder().decode(BotEvent.self, from: data)
        try Self.validate(event)
        return event
    }

    /// Canonical JSON bytes of one event payload (`data`). The payload digest
    /// is computed over exactly these bytes; the header keeps the metadata and
    /// the digest so a cleared payload can never be reconstructed.
    public func encodeData(_ data: BotJSONValue) throws -> Data {
        guard case .object = data else {
            throw BotEventValidationError.invalid("data", "event data must be an object")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(data)
    }

    public func decodeData(_ data: Data) throws -> BotJSONValue {
        let value = try JSONDecoder().decode(BotJSONValue.self, from: data)
        guard case .object = value else {
            throw BotEventValidationError.invalid("data", "event data must be an object")
        }
        return value
    }
}

extension BotEvent {
    func assigningCommitSeq(_ commitSeq: Int?) -> Self {
        Self(schemaVersion: schemaVersion, type: type, eventId: eventId, commitSeq: commitSeq, time: time,
             origin: origin, traceId: traceId, principal: principal, causationId: causationId,
             correlationId: correlationId, turnId: turnId, runId: runId, attempt: attempt, batch: batch,
             ignorable: ignorable, data: data)
    }

    func assigningBatch(_ batch: BotEventBatchRef?) -> Self {
        Self(schemaVersion: schemaVersion, type: type, eventId: eventId, commitSeq: commitSeq, time: time,
             origin: origin, traceId: traceId, principal: principal, causationId: causationId,
             correlationId: correlationId, turnId: turnId, runId: runId, attempt: attempt, batch: batch,
             ignorable: ignorable, data: data)
    }
}

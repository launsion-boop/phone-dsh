// SPDX-License-Identifier: MIT

import Foundation

public enum BotEffectState: String, Codable, Sendable, Equatable {
    case pending
    case leased
    case failed
    case acked
    case deadLetter = "dead_letter"
    case needsReconciliation = "needs_reconciliation"
    case cancelRequested = "cancel_requested"
    case canceled
}

public struct BotEffectRecord: Sendable, Equatable {
    public let effect: BotEffect
    public let state: BotEffectState
    public let attempt: Int
    public let attempts: Int
    public let enqueuedCommitSeq: Int
    public let leaseOwner: String?
    public let leaseExpiresAt: Int64?
    public let startedAt: Int64?
    public let lastError: String?
    public let errorClass: String?
    public let resultRef: String?
    public let appliedAt: Int64?
    public let reconciliationReason: String?
    public let updatedAt: Int64

    public var effectKey: String { effect.effectKey }
    public var generation: Int { effect.generation }
}

public struct BotEffectInboxEntry: Codable, Sendable, Equatable {
    public let receiver: String
    public let effectKey: String
    public let generation: Int
    public let attempt: Int
    public let appliedAt: Int64
    public let resultRef: String?
}

public struct BotEffectInboxResult: Sendable, Equatable {
    public let deduped: Bool
    public let resultRef: String?
    public let entry: BotEffectInboxEntry
}

private let terminalEffectStates: Set<BotEffectState> = [.acked, .deadLetter, .canceled]
private let reconciliationReasons: Set<String> = ["unknown-outcome", "generation-conflict", "receiver-mismatch"]

extension SQLiteDomainStore: BotEffectOutbox {
    @discardableResult
    public func enqueue(_ effect: BotEffect) async throws -> String {
        try withTransaction {
            try enqueueEffectInTransaction(effect)
        }
    }

    func enqueueEffectInTransaction(_ effect: BotEffect) throws -> String {
        try validateEffect(effect)
        let existing = try effectRecord(forKey: effect.effectKey)
        if let existing, effect.generation <= existing.generation {
            return existing.effectKey
        }
        let now = clock()
        let notBefore = effect.notBefore ?? now
        let data = effectData(effect, notBefore: notBefore)
        let sequence = try insertDurableEvents([
            makeEffectEvent(type: "effect.enqueued", data: data, at: now),
        ])[0]
        try database.execute(
            """
            INSERT OR REPLACE INTO bot_effects(
                effect_key, kind, operation, target, canonical_resource, args_digest, payload_digest,
                logical_key, idempotent, retry_policy, max_attempts, generation, not_before, state,
                attempt, attempts, enqueued_commit_seq, lease_owner, lease_expires_at, started_at,
                last_error, error_class, result_ref, applied_at, reconciliation_reason, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(effect.effectKey), .text(effect.kind), .text(effect.operation), .text(effect.target),
                .text(effect.canonicalResource), .text(effect.argsDigest), .text(effect.payloadDigest),
                .text(effect.logicalKey), .integer(effect.idempotent ? 1 : 0), .text(effect.retryPolicy),
                .integer(Int64(effect.maxAttempts)), .integer(Int64(effect.generation)), .integer(notBefore),
                .text(BotEffectState.pending.rawValue), .integer(0), .integer(0), .integer(Int64(sequence)),
                .null, .null, .null, .null, .null, .null, .null, .null, .integer(now),
            ])
        try checkCrashPoint("effect-enqueued")
        return effect.effectKey
    }

    public func effect(_ effectKey: String) throws -> BotEffectRecord? {
        try ensureOpen()
        return try effectRecord(forKey: effectKey)
    }

    public func effects(state: BotEffectState? = nil) throws -> [BotEffectRecord] {
        try ensureOpen()
        let rows: [[String: SQLiteValue]]
        if let state {
            rows = try database.query(
                "SELECT * FROM bot_effects WHERE state = ? ORDER BY enqueued_commit_seq, effect_key",
                bindings: [.text(state.rawValue)])
        } else {
            rows = try database.query("SELECT * FROM bot_effects ORDER BY enqueued_commit_seq, effect_key")
        }
        return try rows.map(decodeEffectRecord)
    }

    public func lease(owner: String, now: Int64) async throws -> BotEffectLease? {
        try await leaseNext(owner: owner, now: now, ttlMs: defaultLeaseTTLms)
    }

    public func leaseNext(owner: String, now: Int64, ttlMs: Int64) async throws -> BotEffectLease? {
        guard !owner.isEmpty, now >= 0, ttlMs > 0 else {
            throw SQLiteDomainStoreError.invalidConfiguration("lease owner, now and ttl are invalid")
        }
        return try withTransaction {
            let rows = try database.query(
                """
                SELECT * FROM bot_effects
                WHERE ((state IN ('pending', 'failed') AND (not_before IS NULL OR not_before <= ?))
                    OR (state IN ('leased', 'cancel_requested') AND lease_expires_at <= ?))
                ORDER BY COALESCE(not_before, 0), enqueued_commit_seq, effect_key
                """,
                bindings: [.integer(now), .integer(now)])
            for row in rows {
                let record = try decodeEffectRecord(row)
                if record.state == .cancelRequested {
                    let data: [String: BotJSONValue] = [
                        "effectKey": .string(record.effectKey),
                        "reason": .string("unknown-outcome"),
                        "at": .number(Double(now)),
                    ]
                    _ = try insertDurableEvents([
                        makeEffectEvent(type: "effect.reconciliation_required", data: data, at: now),
                    ])
                    try markReconciliationRow(record.effectKey, reason: "unknown-outcome", now: now)
                    continue
                }
                if record.state == .leased {
                    if record.attempts >= record.effect.maxAttempts {
                        let data: [String: BotJSONValue] = [
                            "effectKey": .string(record.effectKey),
                            "reason": .string("unknown-outcome"),
                            "at": .number(Double(now)),
                        ]
                        _ = try insertDurableEvents([
                            makeEffectEvent(type: "effect.reconciliation_required", data: data, at: now),
                        ])
                        try markReconciliationRow(record.effectKey, reason: "unknown-outcome", now: now)
                        continue
                    }
                    let attempt = record.attempt + 1
                    let generation = record.generation + 1
                    let lease = BotEffectLease(
                        effectKey: record.effectKey, attempt: attempt, leaseOwner: owner,
                        leaseExpiresAt: now + ttlMs, generation: generation)
                    try writeLease(lease, previous: record, now: now)
                    return lease
                }

                if record.attempts >= record.effect.maxAttempts {
                    let lastError = sanitizedError(record.lastError ?? "max attempts exceeded")
                    let data: [String: BotJSONValue] = [
                        "effectKey": .string(record.effectKey),
                        "attempts": .number(Double(record.attempts)),
                        "lastError": .string(lastError),
                        "at": .number(Double(now)),
                    ]
                    _ = try insertDurableEvents([
                        makeEffectEvent(type: "effect.dead_lettered", data: data, at: now),
                    ])
                    try database.execute(
                        """
                        UPDATE bot_effects SET state = 'dead_letter', last_error = ?, lease_owner = NULL,
                            lease_expires_at = NULL, updated_at = ? WHERE effect_key = ?
                        """,
                        bindings: [.text(lastError), .integer(now), .text(record.effectKey)])
                    continue
                }

                let lease = BotEffectLease(
                    effectKey: record.effectKey, attempt: record.attempt + 1, leaseOwner: owner,
                    leaseExpiresAt: now + ttlMs, generation: record.generation)
                try writeLease(lease, previous: record, now: now)
                return lease
            }
            return nil
        }
    }

    public func renew(_ lease: BotEffectLease, now: Int64, ttlMs: Int64? = nil) async throws -> BotEffectLease {
        let ttl = ttlMs ?? defaultLeaseTTLms
        guard now >= 0, ttl > 0 else {
            throw SQLiteDomainStoreError.invalidConfiguration("renewal time and ttl are invalid")
        }
        return try withTransaction {
            let record = try requireEffect(lease.effectKey)
            try requireActiveLease(lease, record: record, states: [.leased])
            let renewed = BotEffectLease(
                effectKey: lease.effectKey, attempt: lease.attempt, leaseOwner: lease.leaseOwner,
                leaseExpiresAt: now + ttl, generation: lease.generation)
            let data = attemptedData(renewed, startedAt: record.startedAt ?? now, now: now)
            _ = try insertDurableEvents([makeEffectEvent(type: "effect.attempted", data: data, at: now)])
            try database.execute(
                "UPDATE bot_effects SET lease_expires_at = ?, updated_at = ? WHERE effect_key = ?",
                bindings: [.integer(renewed.leaseExpiresAt), .integer(now), .text(lease.effectKey)])
            return renewed
        }
    }

    public func ack(_ lease: BotEffectLease, resultRef: String?) async throws {
        try withTransaction {
            let record = try requireEffect(lease.effectKey)
            if record.state == .acked, record.generation == lease.generation, record.attempt == lease.attempt {
                return
            }
            try requireActiveLease(lease, record: record, states: [.leased, .cancelRequested])
            let now = clock()
            var data: [String: BotJSONValue] = [
                "effectKey": .string(lease.effectKey),
                "attempt": .number(Double(lease.attempt)),
                "appliedAt": .number(Double(now)),
                "generation": .number(Double(lease.generation)),
            ]
            if let resultRef { data["resultRef"] = .string(resultRef) }
            _ = try insertDurableEvents([makeEffectEvent(type: "effect.acked", data: data, at: now)])
            try database.execute(
                """
                UPDATE bot_effects SET state = 'acked', result_ref = ?, applied_at = ?, lease_owner = NULL,
                    lease_expires_at = NULL, not_before = NULL, reconciliation_reason = NULL, updated_at = ?
                WHERE effect_key = ?
                """,
                bindings: [resultRef.map(SQLiteValue.text) ?? .null, .integer(now), .integer(now), .text(lease.effectKey)])
        }
    }

    public func ackReconciled(
        effectKey: String, generation: Int, attempt: Int, resultRef: String?
    ) async throws {
        try withTransaction {
            let record = try requireEffect(effectKey)
            guard record.state == .needsReconciliation,
                  record.generation == generation, record.attempt == attempt else {
                throw SQLiteDomainStoreError.invalidTransition("effect is not awaiting this reconciliation")
            }
            let now = clock()
            var data: [String: BotJSONValue] = [
                "effectKey": .string(effectKey), "attempt": .number(Double(attempt)),
                "appliedAt": .number(Double(now)), "generation": .number(Double(generation)),
                "reconciled": .bool(true),
            ]
            if let resultRef { data["resultRef"] = .string(resultRef) }
            _ = try insertDurableEvents([makeEffectEvent(type: "effect.acked", data: data, at: now)])
            try database.execute(
                """
                UPDATE bot_effects SET state = 'acked', result_ref = ?, applied_at = ?, lease_owner = NULL,
                    lease_expires_at = NULL, not_before = NULL, reconciliation_reason = NULL, updated_at = ?
                WHERE effect_key = ?
                """,
                bindings: [resultRef.map(SQLiteValue.text) ?? .null, .integer(now), .integer(now), .text(effectKey)])
        }
    }

    public func retryNeedsReconciliation(_ effectKey: String, notBefore: Int64? = nil) async throws {
        let record = try requireEffect(effectKey)
        guard record.state == .needsReconciliation else {
            throw SQLiteDomainStoreError.invalidTransition("effect does not need reconciliation")
        }
        let old = record.effect
        let replacement = BotEffect(
            effectKey: old.effectKey, kind: old.kind, operation: old.operation, target: old.target,
            canonicalResource: old.canonicalResource, argsDigest: old.argsDigest,
            payloadDigest: old.payloadDigest, logicalKey: old.logicalKey, idempotent: old.idempotent,
            retryPolicy: old.retryPolicy, maxAttempts: old.maxAttempts, generation: old.generation + 1,
            notBefore: notBefore ?? clock())
        _ = try await enqueue(replacement)
    }

    public func fail(_ lease: BotEffectLease, errorClass: String, reason: String) async throws {
        guard ["transient", "permanent", "unknown"].contains(errorClass) else {
            throw SQLiteDomainStoreError.invalidTransition("invalid errorClass: \(errorClass)")
        }
        try withTransaction {
            let record = try requireEffect(lease.effectKey)
            try requireActiveLease(lease, record: record, states: [.leased, .cancelRequested])
            let now = clock()
            let safeError = sanitizedError(reason)
            var failed: [String: BotJSONValue] = [
                "effectKey": .string(lease.effectKey), "attempt": .number(Double(lease.attempt)),
                "errorClass": .string(errorClass), "error": .string(safeError),
            ]
            var events: [BotEvent] = []
            var nextAttemptAt: Int64?
            let unknown = errorClass == "unknown"
            let dead = errorClass == "permanent" || record.attempts >= record.effect.maxAttempts
            if !unknown && !dead {
                nextAttemptAt = now + retryDelayMs(policy: record.effect.retryPolicy, attempt: lease.attempt)
                failed["nextAttemptAt"] = .number(Double(nextAttemptAt!))
            }
            events.append(makeEffectEvent(type: "effect.failed", data: failed, at: now))
            if unknown {
                events.append(makeEffectEvent(
                    type: "effect.reconciliation_required",
                    data: [
                        "effectKey": .string(lease.effectKey), "reason": .string("unknown-outcome"),
                        "at": .number(Double(now)),
                    ], at: now))
            } else if dead {
                events.append(makeEffectEvent(
                    type: "effect.dead_lettered",
                    data: [
                        "effectKey": .string(lease.effectKey), "attempts": .number(Double(record.attempts)),
                        "lastError": .string(safeError), "at": .number(Double(now)),
                    ], at: now))
            }
            _ = try insertDurableEvents(events)

            if unknown {
                try database.execute(
                    """
                    UPDATE bot_effects SET state = 'needs_reconciliation', last_error = ?, error_class = ?,
                        reconciliation_reason = 'unknown-outcome', lease_owner = NULL, lease_expires_at = NULL,
                        not_before = NULL, updated_at = ? WHERE effect_key = ?
                    """,
                    bindings: [.text(safeError), .text(errorClass), .integer(now), .text(lease.effectKey)])
            } else if dead {
                try database.execute(
                    """
                    UPDATE bot_effects SET state = 'dead_letter', last_error = ?, error_class = ?,
                        lease_owner = NULL, lease_expires_at = NULL, not_before = NULL, updated_at = ?
                    WHERE effect_key = ?
                    """,
                    bindings: [.text(safeError), .text(errorClass), .integer(now), .text(lease.effectKey)])
            } else {
                try database.execute(
                    """
                    UPDATE bot_effects SET state = 'failed', last_error = ?, error_class = ?, not_before = ?,
                        lease_owner = NULL, lease_expires_at = NULL, updated_at = ? WHERE effect_key = ?
                    """,
                    bindings: [
                        .text(safeError), .text(errorClass), .integer(nextAttemptAt!), .integer(now),
                        .text(lease.effectKey),
                    ])
            }
            try checkCrashPoint("effect-failed")
        }
    }

    public func markNeedsReconciliation(_ effectKey: String, reason: String) async throws {
        guard reconciliationReasons.contains(reason) else {
            throw SQLiteDomainStoreError.invalidTransition("invalid reconciliation reason: \(reason)")
        }
        try withTransaction {
            let record = try requireEffect(effectKey)
            if record.state == .needsReconciliation { return }
            guard !terminalEffectStates.contains(record.state) else {
                throw SQLiteDomainStoreError.invalidTransition("terminal effect cannot need reconciliation")
            }
            let now = clock()
            let data: [String: BotJSONValue] = [
                "effectKey": .string(effectKey), "reason": .string(reason), "at": .number(Double(now)),
            ]
            _ = try insertDurableEvents([
                makeEffectEvent(type: "effect.reconciliation_required", data: data, at: now),
            ])
            try markReconciliationRow(effectKey, reason: reason, now: now)
        }
    }

    public func requestCancel(_ effectKey: String, reason: String) async throws {
        try withTransaction {
            let record = try requireEffect(effectKey)
            if terminalEffectStates.contains(record.state) || record.state == .cancelRequested { return }
            guard record.state != .needsReconciliation else {
                throw SQLiteDomainStoreError.invalidTransition("reconciliation must be resolved before cancellation")
            }
            let now = clock()
            if record.state == .leased {
                let data: [String: BotJSONValue] = [
                    "effectKey": .string(effectKey), "reason": .string(reason), "at": .number(Double(now)),
                ]
                _ = try insertDurableEvents([
                    makeEffectEvent(type: "effect.cancel_requested", data: data, at: now),
                ])
                try database.execute(
                    "UPDATE bot_effects SET state = 'cancel_requested', updated_at = ? WHERE effect_key = ?",
                    bindings: [.integer(now), .text(effectKey)])
            } else {
                try writeCanceled(effectKey, reason: reason, now: now)
            }
        }
    }

    public func confirmCancel(_ lease: BotEffectLease, reason: String) async throws {
        try withTransaction {
            let record = try requireEffect(lease.effectKey)
            try requireActiveLease(lease, record: record, states: [.cancelRequested])
            try writeCanceled(lease.effectKey, reason: reason, now: clock())
        }
    }

    public func inboxEntry(receiver: String, effectKey: String) throws -> BotEffectInboxEntry? {
        try ensureOpen()
        let rows = try database.query(
            """
            SELECT receiver, effect_key, generation, attempt, applied_at, result_ref FROM bot_effect_inbox
            WHERE receiver = ? AND effect_key = ? ORDER BY generation DESC LIMIT 1
            """,
            bindings: [.text(receiver), .text(effectKey)])
        guard let row = rows.first else { return nil }
        return try decodeInboxEntry(row)
    }

    func recordInbox(
        receiver: String, lease: BotEffectLease, appliedAt: Int64, resultRef: String?
    ) throws -> BotEffectInboxEntry {
        try withTransaction {
            let record = try requireEffect(lease.effectKey)
            try requireActiveLease(lease, record: record, states: [.leased, .cancelRequested])
            if let existing = try inboxEntry(receiver: receiver, effectKey: lease.effectKey),
               existing.generation >= lease.generation {
                return existing
            }
            try database.execute(
                """
                INSERT INTO bot_effect_inbox(receiver, effect_key, generation, attempt, applied_at, result_ref)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(receiver), .text(lease.effectKey), .integer(Int64(lease.generation)),
                    .integer(Int64(lease.attempt)), .integer(appliedAt),
                    resultRef.map(SQLiteValue.text) ?? .null,
                ])
            try checkCrashPoint("inbox-insert")
            return BotEffectInboxEntry(
                receiver: receiver, effectKey: lease.effectKey, generation: lease.generation,
                attempt: lease.attempt, appliedAt: appliedAt, resultRef: resultRef)
        }
    }

    func effectRecord(forKey effectKey: String) throws -> BotEffectRecord? {
        let rows = try database.query("SELECT * FROM bot_effects WHERE effect_key = ?", bindings: [.text(effectKey)])
        guard let row = rows.first else { return nil }
        return try decodeEffectRecord(row)
    }

    private func requireEffect(_ effectKey: String) throws -> BotEffectRecord {
        guard let record = try effectRecord(forKey: effectKey) else {
            throw SQLiteDomainStoreError.unknownEffect(effectKey)
        }
        return record
    }

    private func requireActiveLease(
        _ lease: BotEffectLease, record: BotEffectRecord, states: Set<BotEffectState>
    ) throws {
        guard lease.generation == record.generation,
              lease.attempt == record.attempt,
              lease.leaseOwner == record.leaseOwner else {
            throw SQLiteDomainStoreError.staleLease(lease.effectKey)
        }
        guard states.contains(record.state) else {
            throw SQLiteDomainStoreError.invalidTransition(
                "effect \(lease.effectKey) is \(record.state.rawValue), not leased")
        }
    }

    private func writeLease(_ lease: BotEffectLease, previous: BotEffectRecord, now: Int64) throws {
        let attempts = max(previous.attempts, lease.attempt)
        let data = attemptedData(lease, startedAt: now, now: now)
        _ = try insertDurableEvents([makeEffectEvent(type: "effect.attempted", data: data, at: now)])
        try database.execute(
            """
            UPDATE bot_effects SET state = 'leased', generation = ?, attempt = ?, attempts = ?,
                lease_owner = ?, lease_expires_at = ?, started_at = ?, not_before = NULL,
                reconciliation_reason = NULL, updated_at = ? WHERE effect_key = ?
            """,
            bindings: [
                .integer(Int64(lease.generation)), .integer(Int64(lease.attempt)), .integer(Int64(attempts)),
                .text(lease.leaseOwner), .integer(lease.leaseExpiresAt), .integer(now), .integer(now),
                .text(lease.effectKey),
            ])
        try checkCrashPoint("effect-leased")
    }

    private func attemptedData(_ lease: BotEffectLease, startedAt: Int64, now: Int64) -> [String: BotJSONValue] {
        [
            "effectKey": .string(lease.effectKey), "attempt": .number(Double(lease.attempt)),
            "leaseOwner": .string(lease.leaseOwner), "leaseExpiresAt": .number(Double(lease.leaseExpiresAt)),
            "startedAt": .number(Double(startedAt)), "generation": .number(Double(lease.generation)),
        ]
    }

    private func markReconciliationRow(_ effectKey: String, reason: String, now: Int64) throws {
        try database.execute(
            """
            UPDATE bot_effects SET state = 'needs_reconciliation', reconciliation_reason = ?,
                lease_owner = NULL, lease_expires_at = NULL, not_before = NULL, updated_at = ?
            WHERE effect_key = ?
            """,
            bindings: [.text(reason), .integer(now), .text(effectKey)])
        try checkCrashPoint("effect-reconciliation")
    }

    private func writeCanceled(_ effectKey: String, reason: String, now: Int64) throws {
        let data: [String: BotJSONValue] = [
            "effectKey": .string(effectKey), "reason": .string(reason), "at": .number(Double(now)),
        ]
        _ = try insertDurableEvents([makeEffectEvent(type: "effect.canceled", data: data, at: now)])
        try database.execute(
            """
            UPDATE bot_effects SET state = 'canceled', last_error = ?, lease_owner = NULL,
                lease_expires_at = NULL, not_before = NULL, updated_at = ? WHERE effect_key = ?
            """,
            bindings: [.text(reason), .integer(now), .text(effectKey)])
    }

    private func effectData(_ effect: BotEffect, notBefore: Int64) -> [String: BotJSONValue] {
        [
            "effectKey": .string(effect.effectKey), "kind": .string(effect.kind),
            "operation": .string(effect.operation), "target": .string(effect.target),
            "payloadDigest": .string(effect.payloadDigest), "idempotent": .bool(effect.idempotent),
            "retryPolicy": .string(effect.retryPolicy), "maxAttempts": .number(Double(effect.maxAttempts)),
            "generation": .number(Double(effect.generation)), "notBefore": .number(Double(notBefore)),
        ]
    }

    private func makeEffectEvent(type: String, data: [String: BotJSONValue], at: Int64) -> BotEvent {
        let effectKey: String
        if case let .string(value)? = data["effectKey"] {
            effectKey = value
        } else {
            effectKey = "unknown"
        }
        return BotEvent(
            type: type, eventId: "evt:\(UUID().uuidString.lowercased())", time: at,
            origin: .local(source: "effect-runner"), traceId: "trace-effect:\(effectKey)",
            principal: BotPrincipal(botId: nil, sessionId: nil, kind: "ipc"),
            causationId: nil, correlationId: effectKey, data: .object(data))
    }

    private func decodeEffectRecord(_ row: [String: SQLiteValue]) throws -> BotEffectRecord {
        guard let effectKey = row["effect_key"]?.text,
              let kind = row["kind"]?.text,
              let operation = row["operation"]?.text,
              let target = row["target"]?.text,
              let canonicalResource = row["canonical_resource"]?.text,
              let argsDigest = row["args_digest"]?.text,
              let payloadDigest = row["payload_digest"]?.text,
              let logicalKey = row["logical_key"]?.text,
              let idempotent = row["idempotent"]?.bool,
              let retryPolicy = row["retry_policy"]?.text,
              let maxAttempts = row["max_attempts"]?.integer,
              let generation = row["generation"]?.integer,
              let stateText = row["state"]?.text,
              let state = BotEffectState(rawValue: stateText),
              let attempt = row["attempt"]?.integer,
              let attempts = row["attempts"]?.integer,
              let enqueuedCommitSeq = row["enqueued_commit_seq"]?.integer,
              let updatedAt = row["updated_at"]?.integer else {
            throw SQLiteDomainStoreError.corrupted("invalid bot_effects row")
        }
        let effect = BotEffect(
            effectKey: effectKey, kind: kind, operation: operation, target: target,
            canonicalResource: canonicalResource, argsDigest: argsDigest, payloadDigest: payloadDigest,
            logicalKey: logicalKey, idempotent: idempotent, retryPolicy: retryPolicy,
            maxAttempts: Int(maxAttempts), generation: Int(generation),
            notBefore: row["not_before"]?.integer)
        return BotEffectRecord(
            effect: effect, state: state, attempt: Int(attempt), attempts: Int(attempts),
            enqueuedCommitSeq: Int(enqueuedCommitSeq), leaseOwner: row["lease_owner"]?.text,
            leaseExpiresAt: row["lease_expires_at"]?.integer, startedAt: row["started_at"]?.integer,
            lastError: row["last_error"]?.text, errorClass: row["error_class"]?.text,
            resultRef: row["result_ref"]?.text, appliedAt: row["applied_at"]?.integer,
            reconciliationReason: row["reconciliation_reason"]?.text, updatedAt: updatedAt)
    }

    private func decodeInboxEntry(_ row: [String: SQLiteValue]) throws -> BotEffectInboxEntry {
        guard let receiver = row["receiver"]?.text,
              let effectKey = row["effect_key"]?.text,
              let generation = row["generation"]?.integer,
              let attempt = row["attempt"]?.integer,
              let appliedAt = row["applied_at"]?.integer else {
            throw SQLiteDomainStoreError.corrupted("invalid bot_effect_inbox row")
        }
        return BotEffectInboxEntry(
            receiver: receiver, effectKey: effectKey, generation: Int(generation), attempt: Int(attempt),
            appliedAt: appliedAt, resultRef: row["result_ref"]?.text)
    }
}

private func validateEffect(_ effect: BotEffect) throws {
    guard !effect.effectKey.isEmpty, !effect.kind.isEmpty, !effect.operation.isEmpty,
          !effect.logicalKey.isEmpty, !effect.retryPolicy.isEmpty else {
        throw SQLiteDomainStoreError.invalidTransition("effect identity and retry policy are required")
    }
    guard effect.generation >= 1, effect.maxAttempts >= 1 else {
        throw SQLiteDomainStoreError.invalidTransition("effect generation and maxAttempts must be positive")
    }
    if let notBefore = effect.notBefore, notBefore < 0 {
        throw SQLiteDomainStoreError.invalidTransition("notBefore must not be negative")
    }
}

private func retryDelayMs(policy: String, attempt: Int) -> Int64 {
    guard policy == "network-idempotent" else { return 0 }
    let exponent = max(0, min(8, attempt - 1))
    return min(Int64(1_000 * (1 << exponent)), 300_000)
}

private func sanitizedError(_ error: String) -> String {
    var result = error
    for pattern in [#"\bsk-[A-Za-z0-9_-]{8,}\b"#, #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*"#] {
        if let regex = try? NSRegularExpression(pattern: pattern) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
        }
    }
    return String(result.prefix(500))
}

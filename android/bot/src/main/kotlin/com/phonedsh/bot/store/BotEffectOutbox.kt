// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.util.UUID

/** `bot_effects` state strings (`store.md` §9.1). */
public enum class BotEffectState(public val wire: String) {
    PENDING("pending"),
    LEASED("leased"),
    FAILED("failed"),
    ACKED("acked"),
    DEAD_LETTER("dead_letter"),
    NEEDS_RECONCILIATION("needs_reconciliation"),
    CANCEL_REQUESTED("cancel_requested"),
    CANCELED("canceled"),
    ;

    public val isTerminal: Boolean
        get() = this == ACKED || this == DEAD_LETTER || this == CANCELED

    public companion object {
        public fun fromWire(value: String): BotEffectState =
            entries.firstOrNull { it.wire == value }
                ?: throw corrupted("unknown bot_effects.state: $value")
    }
}

/** The enqueue input (`store.md` §9.2; Swift `BotEffect`). */
public data class BotEffect(
    public val effectKey: String,
    public val kind: String,
    public val operation: String,
    public val target: String,
    public val canonicalResource: String,
    public val argsDigest: String,
    public val payloadDigest: String,
    public val logicalKey: String,
    public val idempotent: Boolean,
    public val retryPolicy: String,
    public val maxAttempts: Int,
    public val generation: Int,
    public val notBefore: Long?,
) {
    public companion object {
        public fun fromJson(value: JsonValue): BotEffect {
            val members = (value as? JsonObject)?.members
                ?: throw invalidTransition("effect must be an object")
            val canonicalResource = members.text("canonicalResource")
                ?: throw invalidTransition("effect canonicalResource is required")
            val idempotent = (members["idempotent"] as? JsonBool)?.value ?: false
            val policy = members.text("retryPolicy")
                ?: if (idempotent) "local-idempotent" else "local-nonidempotent"
            val maxAttempts = members["maxAttempts"]?.let {
                (it as? JsonNumber)?.asLongOrNull()?.toInt()
                    ?: throw invalidTransition("effect maxAttempts must be an integer")
            } ?: defaultMaxAttempts(policy, idempotent)
            return BotEffect(
                effectKey = members.text("effectKey")
                    ?: throw invalidTransition("effect effectKey is required"),
                kind = members.text("kind") ?: "generic",
                operation = members.text("operation")
                    ?: throw invalidTransition("effect operation is required"),
                target = members.text("target") ?: canonicalResource,
                canonicalResource = canonicalResource,
                argsDigest = members.text("argsDigest")
                    ?: throw invalidTransition("effect argsDigest is required"),
                payloadDigest = members.text("payloadDigest") ?: members.text("argsDigest")
                    ?: throw invalidTransition("effect argsDigest is required"),
                logicalKey = members.text("logicalKey")
                    ?: throw invalidTransition("effect logicalKey is required"),
                idempotent = idempotent,
                retryPolicy = policy,
                maxAttempts = maxAttempts,
                generation = members["generation"]?.let {
                    (it as? JsonNumber)?.asLongOrNull()?.toInt()
                        ?: throw invalidTransition("effect generation must be an integer")
                } ?: 1,
                notBefore = members["notBefore"]?.let {
                    if (it is JsonNull) null
                    else (it as? JsonNumber)?.asLongOrNull()
                        ?: throw invalidTransition("effect notBefore must be an integer")
                },
            )
        }

        public fun defaultMaxAttempts(policy: String, idempotent: Boolean): Int = when (policy) {
            "network-idempotent" -> 5
            "local-idempotent" -> 2
            "local-nonidempotent", "network-nonidempotent" -> 1
            else -> if (idempotent) 2 else 1
        }
    }
}

public data class BotEffectLease(
    public val effectKey: String,
    public val attempt: Int,
    public val leaseOwner: String,
    public val leaseExpiresAt: Long,
    public val generation: Int,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "effectKey" to JsonString(effectKey),
            "attempt" to number(attempt.toLong()),
            "leaseOwner" to JsonString(leaseOwner),
            "leaseExpiresAt" to number(leaseExpiresAt),
            "generation" to number(generation.toLong()),
        ),
    )

    public companion object {
        public fun fromJson(value: JsonValue): BotEffectLease {
            val members = (value as? JsonObject)?.members
                ?: throw invalidTransition("lease must be an object")
            return BotEffectLease(
                effectKey = members.text("effectKey")
                    ?: throw invalidTransition("lease effectKey is required"),
                attempt = members["attempt"]?.let { (it as? JsonNumber)?.asLongOrNull()?.toInt() } ?: 0,
                leaseOwner = members.text("leaseOwner")
                    ?: throw invalidTransition("lease leaseOwner is required"),
                leaseExpiresAt = members["leaseExpiresAt"]?.let {
                    (it as? JsonNumber)?.asLongOrNull()
                } ?: 0,
                generation = members["generation"]?.let {
                    (it as? JsonNumber)?.asLongOrNull()?.toInt()
                } ?: 0,
            )
        }
    }
}

public data class BotEffectRecord(
    public val effect: BotEffect,
    public val state: BotEffectState,
    public val attempt: Int,
    public val attempts: Int,
    public val enqueuedCommitSeq: Long?,
    public val leaseOwner: String?,
    public val leaseExpiresAt: Long?,
    public val startedAt: Long?,
    public val lastError: String?,
    public val errorClass: String?,
    public val resultRef: String?,
    public val appliedAt: Long?,
    public val reconciliationReason: String?,
    public val updatedAt: Long,
) {
    public val effectKey: String get() = effect.effectKey
    public val generation: Int get() = effect.generation
}

public data class BotEffectInboxEntry(
    public val receiver: String,
    public val effectKey: String,
    public val generation: Int,
    public val attempt: Int,
    public val appliedAt: Long,
    public val resultRef: String?,
)

public data class BotEffectInboxResult(
    public val deduped: Boolean,
    public val resultRef: String?,
    public val entry: BotEffectInboxEntry,
)

/**
 * The effect outbox state machine (`store.md` §9). Every transition and its
 * durable event(s) run in the enclosing store transaction.
 */
public class BotEffectOutbox(private val store: BotDomainStore) {
    private val driver: BotSqlDriver get() = store.driver

    // §9.2 -----------------------------------------------------------------

    public fun enqueue(effect: BotEffect): String =
        store.inTransaction { enqueueEffectInTransaction(effect) }

    internal fun enqueueEffectInTransaction(effect: BotEffect): String {
        validateEffect(effect)
        val existing = effectRecord(effect.effectKey)
        if (existing != null && effect.generation <= existing.generation) return existing.effectKey
        val now = store.clock()
        val notBefore = effect.notBefore ?: now
        val sequence = insertDurableEvents(
            listOf(makeEffectEvent("effect.enqueued", effectData(effect, notBefore), now)),
        ).single()
        driver.execute(
            """
            INSERT OR REPLACE INTO bot_effects(
                effect_key, kind, operation, target, canonical_resource, args_digest, payload_digest,
                logical_key, idempotent, retry_policy, max_attempts, generation, not_before, state,
                attempt, attempts, enqueued_commit_seq, lease_owner, lease_expires_at, started_at,
                last_error, error_class, result_ref, applied_at, reconciliation_reason, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """.trimIndent(),
            listOf(
                SqlValue.Text(effect.effectKey), SqlValue.Text(effect.kind),
                SqlValue.Text(effect.operation), SqlValue.Text(effect.target),
                SqlValue.Text(effect.canonicalResource), SqlValue.Text(effect.argsDigest),
                SqlValue.Text(effect.payloadDigest), SqlValue.Text(effect.logicalKey),
                SqlValue.Integer(if (effect.idempotent) 1 else 0), SqlValue.Text(effect.retryPolicy),
                SqlValue.Integer(effect.maxAttempts.toLong()), SqlValue.Integer(effect.generation.toLong()),
                SqlValue.Integer(notBefore), SqlValue.Text(BotEffectState.PENDING.wire),
                SqlValue.Integer(0), SqlValue.Integer(0), SqlValue.Integer(sequence),
                SqlValue.Null, SqlValue.Null, SqlValue.Null, SqlValue.Null,
                SqlValue.Null, SqlValue.Null, SqlValue.Null, SqlValue.Null,
                SqlValue.Integer(now),
            ),
        )
        store.checkCrashPoint("effect-enqueued")
        return effect.effectKey
    }

    public fun effect(effectKey: String): BotEffectRecord? {
        store.ensureOpen()
        return effectRecord(effectKey)
    }

    public fun effects(state: BotEffectState? = null): List<BotEffectRecord> {
        store.ensureOpen()
        val rows = if (state == null) {
            driver.query("SELECT * FROM bot_effects ORDER BY enqueued_commit_seq, effect_key")
        } else {
            driver.query(
                "SELECT * FROM bot_effects WHERE state = ? ORDER BY enqueued_commit_seq, effect_key",
                listOf(SqlValue.Text(state.wire)),
            )
        }
        return rows.map(::decodeEffectRecord)
    }

    // §9.3 -----------------------------------------------------------------

    public fun lease(owner: String, now: Long): BotEffectLease? =
        leaseNext(owner, now, store.defaultLeaseTtlMs)

    public fun leaseNext(owner: String, now: Long, ttlMs: Long): BotEffectLease? {
        if (owner.isEmpty() || now < 0 || ttlMs <= 0) {
            throw invalidConfiguration("lease owner, now and ttl are invalid")
        }
        return store.inTransaction {
            val rows = driver.query(
                """
                SELECT * FROM bot_effects
                WHERE ((state IN ('pending', 'failed') AND (not_before IS NULL OR not_before <= ?))
                    OR (state IN ('leased', 'cancel_requested') AND lease_expires_at <= ?))
                ORDER BY COALESCE(not_before, 0), enqueued_commit_seq, effect_key
                """.trimIndent(),
                listOf(SqlValue.Integer(now), SqlValue.Integer(now)),
            )
            for (row in rows) {
                val record = decodeEffectRecord(row)
                if (record.state == BotEffectState.CANCEL_REQUESTED) {
                    val data = JsonObject(
                        linkedMapOf(
                            "effectKey" to JsonString(record.effectKey),
                            "reason" to JsonString("unknown-outcome"),
                            "at" to number(now),
                        ),
                    )
                    insertDurableEvents(
                        listOf(makeEffectEvent("effect.reconciliation_required", data, now)),
                    )
                    markReconciliationRow(record.effectKey, "unknown-outcome", now)
                    continue
                }
                if (record.state == BotEffectState.LEASED) {
                    if (record.attempts >= record.effect.maxAttempts) {
                        val data = JsonObject(
                            linkedMapOf(
                                "effectKey" to JsonString(record.effectKey),
                                "reason" to JsonString("unknown-outcome"),
                                "at" to number(now),
                            ),
                        )
                        insertDurableEvents(
                            listOf(makeEffectEvent("effect.reconciliation_required", data, now)),
                        )
                        markReconciliationRow(record.effectKey, "unknown-outcome", now)
                        continue
                    }
                    val lease = BotEffectLease(
                        effectKey = record.effectKey,
                        attempt = record.attempt + 1,
                        leaseOwner = owner,
                        leaseExpiresAt = now + ttlMs,
                        generation = record.generation + 1,
                    )
                    writeLease(lease, record, now)
                    return@inTransaction lease
                }

                if (record.attempts >= record.effect.maxAttempts) {
                    val lastError = sanitizedError(record.lastError ?: "max attempts exceeded")
                    val data = JsonObject(
                        linkedMapOf(
                            "effectKey" to JsonString(record.effectKey),
                            "attempts" to number(record.attempts.toLong()),
                            "lastError" to JsonString(lastError),
                            "at" to number(now),
                        ),
                    )
                    insertDurableEvents(listOf(makeEffectEvent("effect.dead_lettered", data, now)))
                    driver.execute(
                        "UPDATE bot_effects SET state = 'dead_letter', last_error = ?, " +
                            "lease_owner = NULL, lease_expires_at = NULL, updated_at = ? " +
                            "WHERE effect_key = ?",
                        listOf(
                            SqlValue.Text(lastError), SqlValue.Integer(now),
                            SqlValue.Text(record.effectKey),
                        ),
                    )
                    continue
                }

                val lease = BotEffectLease(
                    effectKey = record.effectKey,
                    attempt = record.attempt + 1,
                    leaseOwner = owner,
                    leaseExpiresAt = now + ttlMs,
                    generation = record.generation,
                )
                writeLease(lease, record, now)
                return@inTransaction lease
            }
            null
        }
    }

    // §9.4 -----------------------------------------------------------------

    public fun renew(lease: BotEffectLease, now: Long, ttlMs: Long? = null): BotEffectLease {
        val ttl = ttlMs ?: store.defaultLeaseTtlMs
        if (now < 0 || ttl <= 0) throw invalidConfiguration("renewal time and ttl are invalid")
        return store.inTransaction {
            val record = requireEffect(lease.effectKey)
            requireActiveLease(lease, record, setOf(BotEffectState.LEASED))
            val renewed = BotEffectLease(
                effectKey = lease.effectKey,
                attempt = lease.attempt,
                leaseOwner = lease.leaseOwner,
                leaseExpiresAt = now + ttl,
                generation = lease.generation,
            )
            val data = attemptedData(renewed, record.startedAt ?: now)
            insertDurableEvents(listOf(makeEffectEvent("effect.attempted", data, now)))
            driver.execute(
                "UPDATE bot_effects SET lease_expires_at = ?, updated_at = ? WHERE effect_key = ?",
                listOf(
                    SqlValue.Integer(renewed.leaseExpiresAt), SqlValue.Integer(now),
                    SqlValue.Text(lease.effectKey),
                ),
            )
            renewed
        }
    }

    public fun ack(lease: BotEffectLease, resultRef: String?) {
        store.inTransaction {
            val record = requireEffect(lease.effectKey)
            if (record.state == BotEffectState.ACKED &&
                record.generation == lease.generation &&
                record.attempt == lease.attempt
            ) {
                return@inTransaction
            }
            requireActiveLease(
                lease, record,
                setOf(BotEffectState.LEASED, BotEffectState.CANCEL_REQUESTED),
            )
            val now = store.clock()
            val data = JsonObject(
                linkedMapOf<String, JsonValue>(
                    "effectKey" to JsonString(lease.effectKey),
                    "attempt" to number(lease.attempt.toLong()),
                    "appliedAt" to number(now),
                    "generation" to number(lease.generation.toLong()),
                ).apply {
                    resultRef?.let { put("resultRef", JsonString(it)) }
                },
            )
            insertDurableEvents(listOf(makeEffectEvent("effect.acked", data, now)))
            driver.execute(
                "UPDATE bot_effects SET state = 'acked', result_ref = ?, applied_at = ?, " +
                    "lease_owner = NULL, lease_expires_at = NULL, not_before = NULL, " +
                    "reconciliation_reason = NULL, updated_at = ? WHERE effect_key = ?",
                listOf(
                    if (resultRef != null) SqlValue.Text(resultRef) else SqlValue.Null,
                    SqlValue.Integer(now), SqlValue.Integer(now), SqlValue.Text(lease.effectKey),
                ),
            )
        }
    }

    public fun ackReconciled(effectKey: String, generation: Int, attempt: Int, resultRef: String?) {
        store.inTransaction {
            val record = requireEffect(effectKey)
            if (record.state != BotEffectState.NEEDS_RECONCILIATION ||
                record.generation != generation || record.attempt != attempt
            ) {
                throw invalidTransition("effect is not awaiting this reconciliation")
            }
            val now = store.clock()
            val data = JsonObject(
                linkedMapOf<String, JsonValue>(
                    "effectKey" to JsonString(effectKey),
                    "attempt" to number(attempt.toLong()),
                    "appliedAt" to number(now),
                    "generation" to number(generation.toLong()),
                    "reconciled" to JsonBool(true),
                ).apply {
                    resultRef?.let { put("resultRef", JsonString(it)) }
                },
            )
            insertDurableEvents(listOf(makeEffectEvent("effect.acked", data, now)))
            driver.execute(
                "UPDATE bot_effects SET state = 'acked', result_ref = ?, applied_at = ?, " +
                    "lease_owner = NULL, lease_expires_at = NULL, not_before = NULL, " +
                    "reconciliation_reason = NULL, updated_at = ? WHERE effect_key = ?",
                listOf(
                    if (resultRef != null) SqlValue.Text(resultRef) else SqlValue.Null,
                    SqlValue.Integer(now), SqlValue.Integer(now), SqlValue.Text(effectKey),
                ),
            )
        }
    }

    public fun retryNeedsReconciliation(effectKey: String, notBefore: Long? = null) {
        store.inTransaction {
            val record = requireEffect(effectKey)
            if (record.state != BotEffectState.NEEDS_RECONCILIATION) {
                throw invalidTransition("effect does not need reconciliation")
            }
            val old = record.effect
            enqueueEffectInTransaction(
                old.copy(
                    generation = old.generation + 1,
                    notBefore = notBefore ?: store.clock(),
                ),
            )
        }
    }

    public fun fail(lease: BotEffectLease, errorClass: String, reason: String) {
        if (errorClass !in setOf("transient", "permanent", "unknown")) {
            throw invalidTransition("invalid errorClass: $errorClass")
        }
        store.inTransaction {
            val record = requireEffect(lease.effectKey)
            requireActiveLease(
                lease, record,
                setOf(BotEffectState.LEASED, BotEffectState.CANCEL_REQUESTED),
            )
            val now = store.clock()
            val safeError = sanitizedError(reason)
            val safeClass = errorClass
            val failedMembers = linkedMapOf<String, JsonValue>(
                "effectKey" to JsonString(lease.effectKey),
                "attempt" to number(lease.attempt.toLong()),
                "errorClass" to JsonString(safeClass),
                "error" to JsonString(safeError),
            )
            val events = ArrayList<BotEvent>()
            var nextAttemptAt: Long? = null
            val unknown = safeClass == "unknown"
            val dead = safeClass == "permanent" || record.attempts >= record.effect.maxAttempts
            if (!unknown && !dead) {
                nextAttemptAt = now + retryDelayMs(record.effect.retryPolicy, lease.attempt)
                failedMembers["nextAttemptAt"] = number(nextAttemptAt)
            }
            events += makeEffectEvent("effect.failed", JsonObject(failedMembers), now)
            if (unknown) {
                events += makeEffectEvent(
                    "effect.reconciliation_required",
                    JsonObject(
                        linkedMapOf(
                            "effectKey" to JsonString(lease.effectKey),
                            "reason" to JsonString("unknown-outcome"),
                            "at" to number(now),
                        ),
                    ),
                    now,
                )
            } else if (dead) {
                events += makeEffectEvent(
                    "effect.dead_lettered",
                    JsonObject(
                        linkedMapOf(
                            "effectKey" to JsonString(lease.effectKey),
                            "attempts" to number(record.attempts.toLong()),
                            "lastError" to JsonString(safeError),
                            "at" to number(now),
                        ),
                    ),
                    now,
                )
            }
            insertDurableEvents(events)

            if (unknown) {
                driver.execute(
                    "UPDATE bot_effects SET state = 'needs_reconciliation', last_error = ?, " +
                        "error_class = ?, reconciliation_reason = 'unknown-outcome', " +
                        "lease_owner = NULL, lease_expires_at = NULL, not_before = NULL, " +
                        "updated_at = ? WHERE effect_key = ?",
                    listOf(
                        SqlValue.Text(safeError), SqlValue.Text(safeClass),
                        SqlValue.Integer(now), SqlValue.Text(lease.effectKey),
                    ),
                )
            } else if (dead) {
                driver.execute(
                    "UPDATE bot_effects SET state = 'dead_letter', last_error = ?, error_class = ?, " +
                        "lease_owner = NULL, lease_expires_at = NULL, not_before = NULL, " +
                        "updated_at = ? WHERE effect_key = ?",
                    listOf(
                        SqlValue.Text(safeError), SqlValue.Text(safeClass),
                        SqlValue.Integer(now), SqlValue.Text(lease.effectKey),
                    ),
                )
            } else {
                driver.execute(
                    "UPDATE bot_effects SET state = 'failed', last_error = ?, error_class = ?, " +
                        "not_before = ?, lease_owner = NULL, lease_expires_at = NULL, " +
                        "updated_at = ? WHERE effect_key = ?",
                    listOf(
                        SqlValue.Text(safeError), SqlValue.Text(safeClass),
                        SqlValue.Integer(nextAttemptAt!!), SqlValue.Integer(now),
                        SqlValue.Text(lease.effectKey),
                    ),
                )
            }
            store.checkCrashPoint("effect-failed")
        }
    }

    public fun markNeedsReconciliation(effectKey: String, reason: String) {
        if (reason !in setOf("unknown-outcome", "generation-conflict", "receiver-mismatch")) {
            throw invalidTransition("invalid reconciliation reason: $reason")
        }
        store.inTransaction {
            val record = requireEffect(effectKey)
            if (record.state == BotEffectState.NEEDS_RECONCILIATION) return@inTransaction
            if (record.state.isTerminal) {
                throw invalidTransition("terminal effect cannot need reconciliation")
            }
            val now = store.clock()
            val data = JsonObject(
                linkedMapOf(
                    "effectKey" to JsonString(effectKey),
                    "reason" to JsonString(reason),
                    "at" to number(now),
                ),
            )
            insertDurableEvents(listOf(makeEffectEvent("effect.reconciliation_required", data, now)))
            markReconciliationRow(effectKey, reason, now)
        }
    }

    public fun requestCancel(effectKey: String, reason: String) {
        store.inTransaction {
            val record = requireEffect(effectKey)
            if (record.state.isTerminal || record.state == BotEffectState.CANCEL_REQUESTED) {
                return@inTransaction
            }
            if (record.state == BotEffectState.NEEDS_RECONCILIATION) {
                throw invalidTransition("reconciliation must be resolved before cancellation")
            }
            val now = store.clock()
            if (record.state == BotEffectState.LEASED) {
                val data = JsonObject(
                    linkedMapOf(
                        "effectKey" to JsonString(effectKey),
                        "reason" to JsonString(reason),
                        "at" to number(now),
                    ),
                )
                insertDurableEvents(listOf(makeEffectEvent("effect.cancel_requested", data, now)))
                driver.execute(
                    "UPDATE bot_effects SET state = 'cancel_requested', updated_at = ? " +
                        "WHERE effect_key = ?",
                    listOf(SqlValue.Integer(now), SqlValue.Text(effectKey)),
                )
            } else {
                writeCanceled(effectKey, reason, now)
            }
        }
    }

    public fun confirmCancel(lease: BotEffectLease, reason: String) {
        store.inTransaction {
            val record = requireEffect(lease.effectKey)
            requireActiveLease(lease, record, setOf(BotEffectState.CANCEL_REQUESTED))
            writeCanceled(lease.effectKey, reason, store.clock())
        }
    }

    // §9.6 -----------------------------------------------------------------

    public fun inboxEntry(receiver: String, effectKey: String): BotEffectInboxEntry? {
        store.ensureOpen()
        val row = driver.query(
            "SELECT receiver, effect_key, generation, attempt, applied_at, result_ref " +
                "FROM bot_effect_inbox WHERE receiver = ? AND effect_key = ? " +
                "ORDER BY generation DESC LIMIT 1",
            listOf(SqlValue.Text(receiver), SqlValue.Text(effectKey)),
        ).firstOrNull() ?: return null
        return decodeInboxEntry(row)
    }

    /**
     * Persistent receiver-side dedupe. The dedupe check precedes the lease
     * check, so a replay after an ack or a reopen still returns the stored
     * result instead of `invalidTransition`.
     */
    public fun applyInbox(
        receiver: String,
        lease: BotEffectLease,
        resultRef: String?,
        handler: (BotEffectLease) -> String?,
    ): BotEffectInboxResult = store.inTransaction {
        val existing = inboxEntry(receiver, lease.effectKey)
        if (existing != null && existing.generation >= lease.generation) {
            return@inTransaction BotEffectInboxResult(true, existing.resultRef, existing)
        }
        val record = requireEffect(lease.effectKey)
        requireActiveLease(
            lease, record,
            setOf(BotEffectState.LEASED, BotEffectState.CANCEL_REQUESTED),
        )
        val applied = handler(lease)
        val now = store.clock()
        driver.execute(
            "INSERT INTO bot_effect_inbox(receiver, effect_key, generation, attempt, applied_at, result_ref) " +
                "VALUES (?, ?, ?, ?, ?, ?)",
            listOf(
                SqlValue.Text(receiver), SqlValue.Text(lease.effectKey),
                SqlValue.Integer(lease.generation.toLong()), SqlValue.Integer(lease.attempt.toLong()),
                SqlValue.Integer(now), if (applied != null) SqlValue.Text(applied) else SqlValue.Null,
            ),
        )
        store.checkCrashPoint("inbox-insert")
        BotEffectInboxResult(
            false, applied,
            BotEffectInboxEntry(receiver, lease.effectKey, lease.generation, lease.attempt, now, applied),
        )
    }

    // W4-C2-1 --------------------------------------------------------------

    /**
     * An effect leased from a kind with no registered executor is released
     * back to `pending`; it is never dead-lettered. The next attempt waits for
     * the store's retry delay, like a transient failure.
     */
    public fun releaseWithoutExecutor(lease: BotEffectLease, now: Long = store.clock()): BotEffectRecord =
        store.inTransaction {
            val record = requireEffect(lease.effectKey)
            requireActiveLease(lease, record, setOf(BotEffectState.LEASED))
            val next = now + retryDelayMs(record.effect.retryPolicy, lease.attempt)
            driver.execute(
                "UPDATE bot_effects SET state = 'pending', not_before = ?, last_error = ?, " +
                    "lease_owner = NULL, lease_expires_at = NULL, updated_at = ? WHERE effect_key = ?",
                listOf(
                    SqlValue.Integer(next), SqlValue.Text("no registered executor"),
                    SqlValue.Integer(now), SqlValue.Text(lease.effectKey),
                ),
            )
            effectRecord(lease.effectKey)!!
        }

    /**
     * The catalogue has no executor for this kind: this is permanent, with the
     * frozen code `unknown_effect_kind`, and it must not be retried forever.
     */
    public fun failUnknownKind(lease: BotEffectLease, reason: String = "unknown_effect_kind") {
        val record = requireEffect(lease.effectKey)
        fail(lease, "permanent", "unknown_effect_kind: $reason")
        val after = effectRecord(record.effectKey) ?: return
        if (after.state != BotEffectState.DEAD_LETTER) {
            throw invalidTransition("unknown effect kind did not dead-letter")
        }
    }

    // helpers --------------------------------------------------------------

    internal fun effectRecord(effectKey: String): BotEffectRecord? {
        val row = driver.query(
            "SELECT * FROM bot_effects WHERE effect_key = ?",
            listOf(SqlValue.Text(effectKey)),
        ).firstOrNull() ?: return null
        return decodeEffectRecord(row)
    }

    private fun requireEffect(effectKey: String): BotEffectRecord =
        effectRecord(effectKey) ?: throw unknownEffect(effectKey)

    private fun requireActiveLease(
        lease: BotEffectLease,
        record: BotEffectRecord,
        states: Set<BotEffectState>,
    ) {
        if (lease.generation != record.generation ||
            lease.attempt != record.attempt ||
            lease.leaseOwner != record.leaseOwner
        ) {
            throw staleLease(lease.effectKey)
        }
        if (record.state !in states) {
            throw invalidTransition(
                "effect ${lease.effectKey} is ${record.state.wire}, not leased",
            )
        }
    }

    private fun writeLease(lease: BotEffectLease, previous: BotEffectRecord, now: Long) {
        val attempts = maxOf(previous.attempts, lease.attempt)
        val data = attemptedData(lease, now)
        insertDurableEvents(listOf(makeEffectEvent("effect.attempted", data, now)))
        driver.execute(
            "UPDATE bot_effects SET state = 'leased', generation = ?, attempt = ?, attempts = ?, " +
                "lease_owner = ?, lease_expires_at = ?, started_at = ?, not_before = NULL, " +
                "reconciliation_reason = NULL, updated_at = ? WHERE effect_key = ?",
            listOf(
                SqlValue.Integer(lease.generation.toLong()), SqlValue.Integer(lease.attempt.toLong()),
                SqlValue.Integer(attempts.toLong()), SqlValue.Text(lease.leaseOwner),
                SqlValue.Integer(lease.leaseExpiresAt), SqlValue.Integer(now),
                SqlValue.Integer(now), SqlValue.Text(lease.effectKey),
            ),
        )
        store.checkCrashPoint("effect-leased")
    }

    private fun attemptedData(lease: BotEffectLease, startedAt: Long): JsonObject = JsonObject(
        linkedMapOf(
            "effectKey" to JsonString(lease.effectKey),
            "attempt" to number(lease.attempt.toLong()),
            "leaseOwner" to JsonString(lease.leaseOwner),
            "leaseExpiresAt" to number(lease.leaseExpiresAt),
            "startedAt" to number(startedAt),
            "generation" to number(lease.generation.toLong()),
        ),
    )

    private fun markReconciliationRow(effectKey: String, reason: String, now: Long) {
        driver.execute(
            "UPDATE bot_effects SET state = 'needs_reconciliation', reconciliation_reason = ?, " +
                "lease_owner = NULL, lease_expires_at = NULL, not_before = NULL, updated_at = ? " +
                "WHERE effect_key = ?",
            listOf(SqlValue.Text(reason), SqlValue.Integer(now), SqlValue.Text(effectKey)),
        )
        store.checkCrashPoint("effect-reconciliation")
    }

    private fun writeCanceled(effectKey: String, reason: String, now: Long) {
        val data = JsonObject(
            linkedMapOf(
                "effectKey" to JsonString(effectKey),
                "reason" to JsonString(reason),
                "at" to number(now),
            ),
        )
        insertDurableEvents(listOf(makeEffectEvent("effect.canceled", data, now)))
        driver.execute(
            "UPDATE bot_effects SET state = 'canceled', last_error = ?, lease_owner = NULL, " +
                "lease_expires_at = NULL, not_before = NULL, updated_at = ? WHERE effect_key = ?",
            listOf(SqlValue.Text(reason), SqlValue.Integer(now), SqlValue.Text(effectKey)),
        )
    }

    private fun effectData(effect: BotEffect, notBefore: Long): JsonObject = JsonObject(
        linkedMapOf(
            "effectKey" to JsonString(effect.effectKey),
            "kind" to JsonString(effect.kind),
            "operation" to JsonString(effect.operation),
            "target" to JsonString(effect.target),
            "payloadDigest" to JsonString(effect.payloadDigest),
            "idempotent" to JsonBool(effect.idempotent),
            "retryPolicy" to JsonString(effect.retryPolicy),
            "maxAttempts" to number(effect.maxAttempts.toLong()),
            "generation" to number(effect.generation.toLong()),
            "notBefore" to number(notBefore),
        ),
    )

    private fun makeEffectEvent(type: String, data: JsonObject, at: Long): BotEvent {
        val effectKey = (data.members["effectKey"] as? JsonString)?.value ?: "unknown"
        return BotEvent(
            schemaVersion = 1,
            type = type,
            eventId = "evt:${UUID.randomUUID().toString().lowercase()}",
            commitSeq = null,
            time = at,
            origin = BotEventOrigin.Local("effect-runner"),
            traceId = "trace-effect:$effectKey",
            principal = BotPrincipal(null, null, "ipc", emptyList()),
            causationId = null,
            correlationId = effectKey,
            data = data,
        )
    }

    internal fun insertDurableEvents(events: List<BotEvent>): List<Long> {
        if (events.isEmpty()) return emptyList()
        val start = store.headCommitSeqInternal() + 1
        val prepared = if (events.size > 1) {
            val batchId = "batch:${UUID.randomUUID().toString().lowercase()}"
            events.mapIndexed { index, event ->
                event.withBatch(BotEventBatch(batchId, index, events.size))
            }
        } else {
            events
        }
        val result = ArrayList<Long>(prepared.size)
        prepared.forEachIndexed { index, event ->
            val sequence = start + index
            store.insertEvent(event, sequence)
            result += sequence
        }
        return result
    }

    private fun decodeEffectRecord(row: SqlRow): BotEffectRecord {
        val effectKey = row.text("effect_key")
            ?: throw corrupted("invalid bot_effects row")
        val kind = row.text("kind") ?: throw corrupted("invalid bot_effects row")
        val operation = row.text("operation") ?: throw corrupted("invalid bot_effects row")
        val target = row.text("target") ?: throw corrupted("invalid bot_effects row")
        val canonicalResource = row.text("canonical_resource")
            ?: throw corrupted("invalid bot_effects row")
        val argsDigest = row.text("args_digest") ?: throw corrupted("invalid bot_effects row")
        val payloadDigest = row.text("payload_digest") ?: throw corrupted("invalid bot_effects row")
        val logicalKey = row.text("logical_key") ?: throw corrupted("invalid bot_effects row")
        val idempotent = row.integer("idempotent") ?: throw corrupted("invalid bot_effects row")
        val retryPolicy = row.text("retry_policy") ?: throw corrupted("invalid bot_effects row")
        val maxAttempts = row.integer("max_attempts") ?: throw corrupted("invalid bot_effects row")
        val generation = row.integer("generation") ?: throw corrupted("invalid bot_effects row")
        val stateText = row.text("state") ?: throw corrupted("invalid bot_effects row")
        val state = BotEffectState.fromWire(stateText)
        val attempt = row.integer("attempt") ?: throw corrupted("invalid bot_effects row")
        val attempts = row.integer("attempts") ?: throw corrupted("invalid bot_effects row")
        val updatedAt = row.integer("updated_at") ?: throw corrupted("invalid bot_effects row")
        return BotEffectRecord(
            effect = BotEffect(
                effectKey = effectKey,
                kind = kind,
                operation = operation,
                target = target,
                canonicalResource = canonicalResource,
                argsDigest = argsDigest,
                payloadDigest = payloadDigest,
                logicalKey = logicalKey,
                idempotent = idempotent != 0L,
                retryPolicy = retryPolicy,
                maxAttempts = maxAttempts.toInt(),
                generation = generation.toInt(),
                notBefore = row.integer("not_before"),
            ),
            state = state,
            attempt = attempt.toInt(),
            attempts = attempts.toInt(),
            enqueuedCommitSeq = row.integer("enqueued_commit_seq"),
            leaseOwner = row.text("lease_owner"),
            leaseExpiresAt = row.integer("lease_expires_at"),
            startedAt = row.integer("started_at"),
            lastError = row.text("last_error"),
            errorClass = row.text("error_class"),
            resultRef = row.text("result_ref"),
            appliedAt = row.integer("applied_at"),
            reconciliationReason = row.text("reconciliation_reason"),
            updatedAt = updatedAt,
        )
    }

    private fun decodeInboxEntry(row: SqlRow): BotEffectInboxEntry = BotEffectInboxEntry(
        receiver = row.text("receiver") ?: throw corrupted("invalid bot_effect_inbox row"),
        effectKey = row.text("effect_key") ?: throw corrupted("invalid bot_effect_inbox row"),
        generation = row.integer("generation")?.toInt()
            ?: throw corrupted("invalid bot_effect_inbox row"),
        attempt = row.integer("attempt")?.toInt() ?: throw corrupted("invalid bot_effect_inbox row"),
        appliedAt = row.integer("applied_at") ?: throw corrupted("invalid bot_effect_inbox row"),
        resultRef = row.text("result_ref"),
    )

    private fun validateEffect(effect: BotEffect) {
        if (effect.effectKey.isEmpty() || effect.kind.isEmpty() || effect.operation.isEmpty() ||
            effect.logicalKey.isEmpty() || effect.retryPolicy.isEmpty()
        ) {
            throw invalidTransition("effect identity and retry policy are required")
        }
        if (effect.generation < 1 || effect.maxAttempts < 1) {
            throw invalidTransition("effect generation and maxAttempts must be positive")
        }
        effect.notBefore?.let {
            if (it < 0) throw invalidTransition("notBefore must not be negative")
        }
    }

    private fun retryDelayMs(policy: String, attempt: Int): Long {
        if (policy != "network-idempotent") return 0
        val exponent = maxOf(0, minOf(8, attempt - 1))
        return minOf(1_000L shl exponent, 300_000L)
    }

    private fun sanitizedError(error: String): String {
        var result = SK_PATTERN.replace(error, "[redacted]")
        result = BEARER_PATTERN.replace(result, "[redacted]")
        return result.take(500)
    }

    private companion object {
        private val SK_PATTERN = Regex("\\bsk-[A-Za-z0-9_-]{8,}\\b")
        private val BEARER_PATTERN = Regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/-]+=*\\b")
    }
}

private fun Map<String, JsonValue>.text(key: String): String? =
    (this[key] as? JsonString)?.value

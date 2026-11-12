// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal

// ---------------------------------------------------------------------------
// Model (memory-maintenance-start / memory-maintenance / rollback schemas)
// ---------------------------------------------------------------------------

public enum class BotMemoryMaintenanceTrigger(public val wire: String) {
    WRITES("writes"),
    INDEX("index"),
    CONTRADICTION("contradiction"),
    MANUAL("manual"),
    ;

    public companion object {
        public fun parse(value: String?): BotMemoryMaintenanceTrigger? =
            entries.firstOrNull { it.wire == value }
    }
}

public enum class BotMemoryMaintenanceStatus(public val wire: String) {
    COMMITTED("committed"),
    CANCELLED("cancelled"),
    FAILED("failed"),
    ROLLED_BACK("rolled_back"),
    ROLLBACK_FAILED("rollback_failed"),
    ;

    public companion object {
        public fun parse(value: String?): BotMemoryMaintenanceStatus? =
            entries.firstOrNull { it.wire == value }
    }
}

public enum class BotMemoryMaintenanceCandidateReason(public val wire: String) {
    MOST_READ("most-read"),
    MOST_CHANGED("most-changed"),
    LEAST_VERIFIED("least-verified"),
    OVERLONG("overlong"),
    INBOX("inbox"),
    CONTRADICTION("contradiction"),
    INDEX("index"),
    ;

    public companion object {
        public fun parse(value: String?): BotMemoryMaintenanceCandidateReason? =
            entries.firstOrNull { it.wire == value }
    }
}

public enum class BotMemoryMaintenanceFailureCode(public val wire: String) {
    EVIDENCE_UNRESOLVED("maintenance-evidence-unresolved"),
    INDEX_TOO_LONG("maintenance-index-too-long"),
    DOCUMENT_LONGER_THAN_EVIDENCE("maintenance-document-longer-than-evidence"),
    CHANGE_BUDGET_EXCEEDED("maintenance-change-budget-exceeded"),
    BUDGET_EXCEEDED("maintenance-budget-exceeded"),
    ROLLBACK_CONFLICT("maintenance-rollback-conflict"),
    ;

    public companion object {
        public fun parse(value: String?): BotMemoryMaintenanceFailureCode? =
            entries.firstOrNull { it.wire == value }
    }
}

public data class BotMemoryMaintenanceCandidate(
    public val path: String,
    public val reasons: List<BotMemoryMaintenanceCandidateReason>,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "path" to JsonString(path),
            "reasons" to JsonArray(reasons.map { JsonString(it.wire) }),
        ),
    )
}

public data class BotMemoryMaintenanceChange(
    public val path: String,
    public val scope: BotMemoryScope,
    public val beforeVersion: Int,
    public val afterVersion: Int,
    public val deleted: Boolean,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "path" to JsonString(path),
            "scope" to JsonString(scope.wire),
            "before_version" to JsonNumber(beforeVersion.toString()),
            "after_version" to JsonNumber(afterVersion.toString()),
            "deleted" to JsonBool(deleted),
        ),
    )
}

public data class BotMemoryMaintenanceChecks(
    public val referencesResolve: Boolean,
    public val indexWithinLimit: Boolean,
    public val documentsNotLongerThanEvidence: Boolean,
    public val changeBudgetWithinLimit: Boolean,
) {
    public val passedAll: Boolean
        get() = referencesResolve && indexWithinLimit &&
            documentsNotLongerThanEvidence && changeBudgetWithinLimit

    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "references_resolve" to JsonBool(referencesResolve),
            "index_within_limit" to JsonBool(indexWithinLimit),
            "documents_not_longer_than_evidence" to JsonBool(documentsNotLongerThanEvidence),
            "change_budget_within_limit" to JsonBool(changeBudgetWithinLimit),
        ),
    )

    public companion object {
        public val passed: BotMemoryMaintenanceChecks = BotMemoryMaintenanceChecks(
            referencesResolve = true,
            indexWithinLimit = true,
            documentsNotLongerThanEvidence = true,
            changeBudgetWithinLimit = true,
        )
    }
}

public data class BotMemoryMaintenanceBudget(
    public val runTokens: Int,
    public val dailyTokens: Int,
    public val tokensUsed: Int = 0,
    public val changedDocuments: Int = 0,
    public val changedScalars: Int = 0,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "run_tokens" to JsonNumber(runTokens.toString()),
            "daily_tokens" to JsonNumber(dailyTokens.toString()),
            "tokens_used" to JsonNumber(tokensUsed.toString()),
            "changed_documents" to JsonNumber(changedDocuments.toString()),
            "changed_scalars" to JsonNumber(changedScalars.toString()),
        ),
    )
}

public data class BotMemoryMaintenanceStartBudget(
    public val runTokens: Int,
    public val dailyTokens: Int,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "run_tokens" to JsonNumber(runTokens.toString()),
            "daily_tokens" to JsonNumber(dailyTokens.toString()),
        ),
    )
}

public data class BotMemoryMaintenanceStart(
    public val batchId: String,
    public val botId: String,
    public val trigger: BotMemoryMaintenanceTrigger,
    public val startedAtMs: Long,
    public val maintainerSessionId: String,
    public val candidates: List<BotMemoryMaintenanceCandidate>,
    public val budget: BotMemoryMaintenanceStartBudget,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "batch_id" to JsonString(batchId),
            "bot_id" to JsonString(botId),
            "trigger" to JsonString(trigger.wire),
            "started_at_ms" to JsonNumber(startedAtMs.toString()),
            "maintainer_session_id" to JsonString(maintainerSessionId),
            "candidates" to JsonArray(candidates.map { it.toJson() }),
            "budget" to budget.toJson(),
        ),
    )

    public companion object {
        private val allowed = setOf(
            "batch_id", "bot_id", "trigger", "started_at_ms",
            "maintainer_session_id", "candidates", "budget",
        )

        public fun fromJson(value: JsonValue?): BotMemoryMaintenanceStart {
            val members = BotMemoryJson.objectMembers(value, "maintenanceStart")
            BotMemoryJson.rejectUnknown(members, "maintenanceStart", allowed)
            val batchId = BotMemoryJson.string(members["batch_id"], "batch_id")
            requireBatchId(batchId)
            val botId = BotMemoryJson.string(members["bot_id"], "bot_id")
            if (botId.isEmpty()) throw BotJsonException("bot_id must not be empty")
            val trigger = BotMemoryMaintenanceTrigger.parse(
                BotMemoryJson.string(members["trigger"], "trigger"),
            ) ?: throw BotJsonException("trigger is not a maintenance trigger")
            val started = BotMemoryJson.integer64(members["started_at_ms"], "started_at_ms")
            if (started < 0) throw BotJsonException("started_at_ms must not be negative")
            val session = BotMemoryJson.string(
                members["maintainer_session_id"], "maintainer_session_id",
            )
            if (!MAINTAINER_SESSION.matches(session)) {
                throw BotJsonException("maintainer_session_id is not a maintainer session")
            }
            val candidatesRaw = BotMemoryJson.array(members["candidates"], "candidates")
            if (candidatesRaw.size > 12) {
                throw BotJsonException("candidates may have at most 12 entries")
            }
            val candidates = candidatesRaw.mapIndexed { index, item ->
                val candidate = BotMemoryJson.objectMembers(item, "candidates[$index]")
                BotMemoryJson.rejectUnknown(candidate, "candidates[$index]", setOf("path", "reasons"))
                val path = BotMemoryJson.string(candidate["path"], "candidates[$index].path")
                if (BotMemoryText.scalarCount(path) !in 3..200) {
                    throw BotJsonException("candidates[$index].path has an invalid length")
                }
                val reasonsRaw = BotMemoryJson.array(candidate["reasons"], "candidates[$index].reasons")
                if (reasonsRaw.isEmpty() || reasonsRaw.size > 4) {
                    throw BotJsonException("candidates[$index].reasons must have 1..4 items")
                }
                val reasons = reasonsRaw.map { reason ->
                    BotMemoryMaintenanceCandidateReason.parse(
                        BotMemoryJson.string(reason, "candidates[$index].reasons"),
                    ) ?: throw BotJsonException("unknown candidate reason")
                }
                if (reasons.toSet().size != reasons.size) {
                    throw BotJsonException("candidates[$index].reasons must be unique")
                }
                BotMemoryMaintenanceCandidate(path, reasons)
            }
            val budget = BotMemoryJson.objectMembers(members["budget"], "budget")
            BotMemoryJson.rejectUnknown(budget, "budget", setOf("run_tokens", "daily_tokens"))
            val run = BotMemoryJson.integer(budget["run_tokens"], "budget.run_tokens")
            val daily = BotMemoryJson.integer(budget["daily_tokens"], "budget.daily_tokens")
            if (run < 1 || daily < 1) throw BotJsonException("maintenance budget must be positive")
            return BotMemoryMaintenanceStart(
                batchId = batchId,
                botId = botId,
                trigger = trigger,
                startedAtMs = started,
                maintainerSessionId = session,
                candidates = candidates,
                budget = BotMemoryMaintenanceStartBudget(run, daily),
            )
        }
    }
}

public data class BotMemoryMaintenanceBatch(
    public val batchId: String,
    public val botId: String,
    public val status: BotMemoryMaintenanceStatus,
    public val trigger: BotMemoryMaintenanceTrigger,
    public val startedAtMs: Long,
    public val finishedAtMs: Long,
    public val maintainerSessionId: String,
    public val changes: List<BotMemoryMaintenanceChange>,
    public val checks: BotMemoryMaintenanceChecks,
    public val budget: BotMemoryMaintenanceBudget,
    public val failureCode: String?,
    public val notification: Boolean,
    public val userScopeOwner: Boolean,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "batch_id" to JsonString(batchId),
            "bot_id" to JsonString(botId),
            "status" to JsonString(status.wire),
            "trigger" to JsonString(trigger.wire),
            "started_at_ms" to JsonNumber(startedAtMs.toString()),
            "finished_at_ms" to JsonNumber(finishedAtMs.toString()),
            "maintainer_session_id" to JsonString(maintainerSessionId),
            "changes" to JsonArray(changes.map { it.toJson() }),
            "checks" to checks.toJson(),
            "budget" to budget.toJson(),
            "failure_code" to (failureCode?.let(::JsonString) ?: JsonNull),
            "notification" to JsonBool(notification),
            "user_scope_owner" to JsonBool(userScopeOwner),
        ),
    )

    public companion object {
        private val allowed = setOf(
            "batch_id", "bot_id", "status", "trigger", "started_at_ms", "finished_at_ms",
            "maintainer_session_id", "changes", "checks", "budget", "failure_code",
            "notification", "user_scope_owner",
        )

        public fun fromJson(value: JsonValue?): BotMemoryMaintenanceBatch {
            val members = BotMemoryJson.objectMembers(value, "maintenanceBatch")
            BotMemoryJson.rejectUnknown(members, "maintenanceBatch", allowed)
            val batchId = BotMemoryJson.string(members["batch_id"], "batch_id")
            requireBatchId(batchId)
            val botId = BotMemoryJson.string(members["bot_id"], "bot_id")
            if (botId.isEmpty()) throw BotJsonException("bot_id must not be empty")
            val status = BotMemoryMaintenanceStatus.parse(
                BotMemoryJson.string(members["status"], "status"),
            ) ?: throw BotJsonException("status is not a maintenance status")
            val trigger = BotMemoryMaintenanceTrigger.parse(
                BotMemoryJson.string(members["trigger"], "trigger"),
            ) ?: throw BotJsonException("trigger is not a maintenance trigger")
            val started = BotMemoryJson.integer64(members["started_at_ms"], "started_at_ms")
            val finished = BotMemoryJson.integer64(members["finished_at_ms"], "finished_at_ms")
            if (started < 0 || finished < 0) throw BotJsonException("timestamps must not be negative")
            val session = BotMemoryJson.string(
                members["maintainer_session_id"], "maintainer_session_id",
            )
            if (!MAINTAINER_SESSION.matches(session)) {
                throw BotJsonException("maintainer_session_id is not a maintainer session")
            }
            val changesRaw = BotMemoryJson.array(members["changes"], "changes")
            if (changesRaw.size > 100) throw BotJsonException("changes may have at most 100 entries")
            val changes = changesRaw.mapIndexed { index, item ->
                val change = BotMemoryJson.objectMembers(item, "changes[$index]")
                BotMemoryJson.rejectUnknown(
                    change, "changes[$index]",
                    setOf("path", "scope", "before_version", "after_version", "deleted"),
                )
                val path = BotMemoryJson.string(change["path"], "changes[$index].path")
                if (BotMemoryText.scalarCount(path) !in 3..200) {
                    throw BotJsonException("changes[$index].path has an invalid length")
                }
                val scope = BotMemoryScope.parse(BotMemoryJson.string(change["scope"], "changes[$index].scope"))
                    ?: throw BotJsonException("changes[$index].scope must be agent or user")
                val before = BotMemoryJson.integer(change["before_version"], "changes[$index].before_version")
                val after = BotMemoryJson.integer(change["after_version"], "changes[$index].after_version")
                if (before < 0 || after < 1) {
                    throw BotJsonException("changes[$index] has an invalid version")
                }
                BotMemoryMaintenanceChange(
                    path, scope, before, after,
                    BotMemoryJson.boolean(change["deleted"], "changes[$index].deleted"),
                )
            }
            val checksMembers = BotMemoryJson.objectMembers(members["checks"], "checks")
            BotMemoryJson.rejectUnknown(
                checksMembers, "checks",
                setOf(
                    "references_resolve", "index_within_limit",
                    "documents_not_longer_than_evidence", "change_budget_within_limit",
                ),
            )
            val checks = BotMemoryMaintenanceChecks(
                referencesResolve = BotMemoryJson.boolean(
                    checksMembers["references_resolve"], "checks.references_resolve",
                ),
                indexWithinLimit = BotMemoryJson.boolean(
                    checksMembers["index_within_limit"], "checks.index_within_limit",
                ),
                documentsNotLongerThanEvidence = BotMemoryJson.boolean(
                    checksMembers["documents_not_longer_than_evidence"],
                    "checks.documents_not_longer_than_evidence",
                ),
                changeBudgetWithinLimit = BotMemoryJson.boolean(
                    checksMembers["change_budget_within_limit"],
                    "checks.change_budget_within_limit",
                ),
            )
            val budgetMembers = BotMemoryJson.objectMembers(members["budget"], "budget")
            BotMemoryJson.rejectUnknown(
                budgetMembers, "budget",
                setOf(
                    "run_tokens", "daily_tokens", "tokens_used",
                    "changed_documents", "changed_scalars",
                ),
            )
            val run = BotMemoryJson.integer(budgetMembers["run_tokens"], "budget.run_tokens")
            val daily = BotMemoryJson.integer(budgetMembers["daily_tokens"], "budget.daily_tokens")
            if (run < 1 || daily < 1) throw BotJsonException("maintenance budget must be positive")
            val tokens = BotMemoryJson.integer(budgetMembers["tokens_used"], "budget.tokens_used")
            val changedDocs = BotMemoryJson.integer(
                budgetMembers["changed_documents"], "budget.changed_documents",
            )
            val changedScalars = BotMemoryJson.integer(
                budgetMembers["changed_scalars"], "budget.changed_scalars",
            )
            if (tokens < 0 || changedDocs < 0 || changedScalars < 0) {
                throw BotJsonException("budget counters must not be negative")
            }
            val failure = when (val raw = members["failure_code"]) {
                null -> throw BotJsonException("failure_code is required")
                is JsonNull -> null
                is JsonString -> BotMemoryMaintenanceFailureCode.parse(raw.value)?.wire
                    ?: throw BotJsonException("failure_code is not a maintenance failure code")
                else -> throw BotJsonException("failure_code must be a string or null")
            }
            return BotMemoryMaintenanceBatch(
                batchId = batchId,
                botId = botId,
                status = status,
                trigger = trigger,
                startedAtMs = started,
                finishedAtMs = finished,
                maintainerSessionId = session,
                changes = changes,
                checks = checks,
                budget = BotMemoryMaintenanceBudget(
                    run, daily, tokens, changedDocs, changedScalars,
                ),
                failureCode = failure,
                notification = BotMemoryJson.boolean(members["notification"], "notification"),
                userScopeOwner = BotMemoryJson.boolean(
                    members["user_scope_owner"], "user_scope_owner",
                ),
            )
        }
    }
}

public data class BotMemoryMaintenanceRestore(
    public val path: String,
    public val fromVersion: Int,
    public val toVersion: Int,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "path" to JsonString(path),
            "from_version" to JsonNumber(fromVersion.toString()),
            "to_version" to JsonNumber(toVersion.toString()),
        ),
    )
}

public data class BotMemoryMaintenanceRollback(
    public val batchId: String,
    public val botId: String,
    public val rolledBackAtMs: Long,
    public val restored: List<BotMemoryMaintenanceRestore>,
    public val conflicts: List<String>,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "batch_id" to JsonString(batchId),
            "bot_id" to JsonString(botId),
            "rolled_back_at_ms" to JsonNumber(rolledBackAtMs.toString()),
            "restored" to JsonArray(restored.map { it.toJson() }),
            "conflicts" to JsonArray(conflicts.map(::JsonString)),
        ),
    )

    public companion object {
        private val allowed = setOf(
            "batch_id", "bot_id", "rolled_back_at_ms", "restored", "conflicts",
        )

        public fun fromJson(value: JsonValue?): BotMemoryMaintenanceRollback {
            val members = BotMemoryJson.objectMembers(value, "maintenanceRollback")
            BotMemoryJson.rejectUnknown(members, "maintenanceRollback", allowed)
            val batchId = BotMemoryJson.string(members["batch_id"], "batch_id")
            requireBatchId(batchId)
            val botId = BotMemoryJson.string(members["bot_id"], "bot_id")
            if (botId.isEmpty()) throw BotJsonException("bot_id must not be empty")
            val at = BotMemoryJson.integer64(members["rolled_back_at_ms"], "rolled_back_at_ms")
            if (at < 0) throw BotJsonException("rolled_back_at_ms must not be negative")
            val restoredRaw = BotMemoryJson.array(members["restored"], "restored")
            if (restoredRaw.size > 100) throw BotJsonException("restored may have at most 100 entries")
            val restored = restoredRaw.mapIndexed { index, item ->
                val entry = BotMemoryJson.objectMembers(item, "restored[$index]")
                BotMemoryJson.rejectUnknown(
                    entry, "restored[$index]", setOf("path", "from_version", "to_version"),
                )
                val path = BotMemoryJson.string(entry["path"], "restored[$index].path")
                if (BotMemoryText.scalarCount(path) !in 3..200) {
                    throw BotJsonException("restored[$index].path has an invalid length")
                }
                val from = BotMemoryJson.integer(entry["from_version"], "restored[$index].from_version")
                val to = BotMemoryJson.integer(entry["to_version"], "restored[$index].to_version")
                if (from < 1 || to < 1) throw BotJsonException("restored versions must be positive")
                BotMemoryMaintenanceRestore(path, from, to)
            }
            val conflictsRaw = BotMemoryJson.array(members["conflicts"], "conflicts")
            if (conflictsRaw.size > 100) throw BotJsonException("conflicts may have at most 100 entries")
            val conflicts = conflictsRaw.mapIndexed { index, item ->
                val path = BotMemoryJson.string(item, "conflicts[$index]")
                if (BotMemoryText.scalarCount(path) !in 3..200) {
                    throw BotJsonException("conflicts[$index] has an invalid length")
                }
                path
            }
            return BotMemoryMaintenanceRollback(batchId, botId, at, restored, conflicts)
        }
    }
}

public data class BotMemoryMaintenanceSettings(
    public val enabled: Boolean = false,
    public val runTokenBudget: Int = 32_000,
    public val dailyTokenBudget: Int = 96_000,
) {
    public companion object {
        public const val DEFAULTS_KEY: String = "phone-dsh.bot.memory-maintenance.v1"
        public val standard: BotMemoryMaintenanceSettings = BotMemoryMaintenanceSettings()
    }
}

internal val BATCH_ID_PATTERN = Regex("^mm-[a-z0-9-]{8,64}$")
internal val MAINTAINER_SESSION = Regex("^gb-maintainer-[A-Za-z0-9._-]{1,64}$")

internal fun requireBatchId(value: String) {
    if (!BATCH_ID_PATTERN.matches(value)) throw BotJsonException("batch_id is not a maintenance batch id")
}

// ---------------------------------------------------------------------------
// Mechanical checks (v2 §4.4)
// ---------------------------------------------------------------------------

public data class BotMemoryMaintenanceCheckDocument(
    public val path: String,
    public val content: String,
    public val evidence: List<String> = emptyList(),
)

public data class BotMemoryMaintenanceCheckRecord(
    public val botId: String,
    public val trust: BotMemoryTrust? = null,
    public val text: String = "",
)

public data class BotMemoryMaintenanceCheckInput(
    public val botId: String,
    public val isMainBot: Boolean = true,
    public val documents: List<BotMemoryMaintenanceCheckDocument> = emptyList(),
    public val records: Map<String, BotMemoryMaintenanceCheckRecord> = emptyMap(),
    public val changedDocuments: Int = 0,
    public val changedScalars: Int = 0,
    public val indexOverrides: Map<String, Int> = emptyMap(),
)

/**
 * The host-only mechanical check. Order matches §4.4 and the Python reference
 * `maintenance_check`, so `memory-maintenance.json` drives both ends.
 */
public object BotMemoryMaintenanceChecker {
    public const val MAXIMUM_CHANGED_DOCUMENTS: Int = 12
    public const val MAXIMUM_CHANGED_SCALARS: Int = 24_000
    public const val INDEX_TRIGGER_SCALARS: Int = 1_350

    /**
     * The same check, but returns the schema-level string (including the two
     * write-boundary failures) exactly as the shared Python reference does.
     */
    public fun checkCode(input: BotMemoryMaintenanceCheckInput): String? {
        for (document in input.documents) {
            val path = document.path
            val parsed = ArrayList<BotMemoryMaintenanceCheckRecord>()
            for (raw in document.evidence) {
                val reference = BotMemoryEvidence.parse(raw)
                    ?: return "maintenance-evidence-unresolved"
                val record = input.records[reference.canonical]
                    ?: return "maintenance-evidence-unresolved"
                if (record.botId != input.botId) return "maintenance-evidence-unresolved"
                parsed += record
            }
            if (BotMemoryPath.scopeOf(path) == BotMemoryScope.USER) {
                if (!input.isMainBot) return "memory-scope-denied"
                if (parsed.none { it.trust == BotMemoryTrust.USER }) return "memory-evidence-required"
            }
            if (BotMemoryPath.isIndex(path)) {
                val actual = input.indexOverrides[path]
                    ?: BotMemoryText.scalarCount(document.content)
                if (actual > BotMemoryLimits.INDEX) return "maintenance-index-too-long"
            }
            if (document.evidence.isNotEmpty()) {
                val original = parsed.sumOf { BotMemoryText.scalarCount(it.text) }
                if (BotMemoryText.scalarCount(document.content) > original) {
                    return "maintenance-document-longer-than-evidence"
                }
            }
        }
        if (input.changedDocuments > MAXIMUM_CHANGED_DOCUMENTS ||
            input.changedScalars > MAXIMUM_CHANGED_SCALARS
        ) {
            return "maintenance-change-budget-exceeded"
        }
        return null
    }

    public fun rollbackConflict(
        batch: BotMemoryMaintenanceBatch,
        rollback: BotMemoryMaintenanceRollback,
    ): String? {
        if (rollback.batchId != batch.batchId || rollback.botId != batch.botId) {
            return "maintenance-rollback-conflict"
        }
        val after = batch.changes.associate { it.path to it.afterVersion }
        for (item in rollback.restored) {
            if (after[item.path] != item.fromVersion || item.toVersion <= item.fromVersion) {
                return "maintenance-rollback-conflict"
            }
        }
        return null
    }
}

// ---------------------------------------------------------------------------
// Batch store / rollback
// ---------------------------------------------------------------------------

/** Durable batch lifecycle over the P25 event log (v2 §4.3). */
public class BotMemoryMaintenanceBatchStore(
    private val eventLog: BotMemoryEventLog,
    private val memory: BotMemory,
    private val botId: String,
    private val isMainBot: Boolean = true,
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    public fun begin(start: BotMemoryMaintenanceStart): BotMemoryMaintenanceStart {
        // Re-run the frozen codec so an invalid batch never reaches the log.
        BotMemoryMaintenanceStart.fromJson(start.toJson())
        if (start.botId != botId) {
            throw BotJsonException("maintenance batch belongs to ${start.botId}, not $botId")
        }
        append(
            type = STARTED_TYPE,
            eventId = "$STARTED_TYPE:${start.batchId}",
            data = start.toJson(),
            at = start.startedAtMs,
            sessionId = start.maintainerSessionId,
            batchId = start.batchId,
        )
        return start
    }

    public fun batches(): List<BotMemoryMaintenanceBatch> =
        allDurableEvents().mapNotNull { event ->
            if (event.type != FINISHED_TYPE) return@mapNotNull null
            runCatching { BotMemoryMaintenanceBatch.fromJson(event.data) }.getOrNull()
        }.filter { it.botId == botId }

    public fun lastBatch(): BotMemoryMaintenanceBatch? = batches().lastOrNull()

    public fun rollbackRecords(): List<BotMemoryMaintenanceRollback> =
        allDurableEvents().mapNotNull { event ->
            if (event.type != ROLLED_BACK_TYPE) return@mapNotNull null
            runCatching { BotMemoryMaintenanceRollback.fromJson(event.data) }.getOrNull()
        }.filter { it.botId == botId }

    public fun lastRollback(batchId: String): BotMemoryMaintenanceRollback? =
        rollbackRecords().lastOrNull { it.batchId == batchId }

    public fun changes(batchId: String): List<BotMemoryMaintenanceChange> =
        collapseChanges(batchWrites(batchId))

    public fun rollback(batchId: String): BotMemoryMaintenanceRollback? {
        val batch = batches().lastOrNull { it.batchId == batchId } ?: return null
        val beforeVersions = LinkedHashMap<String, Int>()
        for (event in batchWrites(batchId)) {
            val data = event.data as? JsonObject ?: continue
            val path = (data.members["path"] as? JsonString)?.value ?: continue
            if (beforeVersions.containsKey(path)) continue
            val expected = (data.members["expected_version"] as? JsonNumber)
                ?.asLongOrNull()?.toInt() ?: continue
            beforeVersions[path] = expected
        }
        return rollback(
            batchId = batchId,
            changes = batch.changes,
            beforeVersions = beforeVersions,
            sessionId = batch.maintainerSessionId,
        )
    }

    /**
     * Runs the four checks, rolls the whole batch back on any failure, then
     * writes `memory.maintenance_finished`. `turnStatus` is the real turn
     * outcome (`completed`/`cancelled`/other), never a self-report.
     */
    public fun evaluateAndFinish(
        batchId: String,
        trigger: BotMemoryMaintenanceTrigger,
        startedAtMs: Long,
        maintainerSessionId: String,
        turnStatus: String?,
        checkInput: BotMemoryMaintenanceCheckInput,
        budget: BotMemoryMaintenanceBudget,
        dailyTokensUsed: Int = 0,
        userScopeOwner: Boolean = true,
    ): BotMemoryMaintenanceBatch {
        val changes = changes(batchId)
        val writes = batchWrites(batchId)
        val lastContent = LinkedHashMap<String, String>()
        val lastEvidence = LinkedHashMap<String, List<String>>()
        for (event in writes.sortedBy { it.commitSeq ?: 0L }) {
            val data = event.data as? JsonObject ?: continue
            val path = (data.members["path"] as? JsonString)?.value ?: continue
            if (event.type == "memory.document_written") {
                lastContent[path] = (data.members["content"] as? JsonString)?.value ?: ""
                lastEvidence[path] = (data.members["evidence"] as? JsonArray)?.values
                    ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
            } else if (event.type == "memory.document_deleted") {
                lastContent[path] = ""
                lastEvidence[path] = (data.members["evidence"] as? JsonArray)?.values
                    ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
            }
        }
        val writtenScalars = lastContent.values.sumOf { BotMemoryText.scalarCount(it) }
        val documents = if (checkInput.documents.isNotEmpty()) {
            checkInput.documents
        } else {
            lastContent.map { (path, content) ->
                BotMemoryMaintenanceCheckDocument(path, content, lastEvidence[path] ?: emptyList())
            }
        }
        val effectiveInput = checkInput.copy(
            documents = documents,
            changedDocuments = changes.size,
            changedScalars = writtenScalars,
        )
        var failureCode = BotMemoryMaintenanceChecker.checkCode(effectiveInput)
        if (failureCode == null &&
            (budget.tokensUsed > budget.runTokens || dailyTokensUsed > budget.dailyTokens)
        ) {
            failureCode = BotMemoryMaintenanceFailureCode.BUDGET_EXCEEDED.wire
        }
        val checks = BotMemoryMaintenanceChecks(
            referencesResolve = failureCode != "maintenance-evidence-unresolved",
            indexWithinLimit = failureCode != "maintenance-index-too-long",
            documentsNotLongerThanEvidence =
                failureCode != "maintenance-document-longer-than-evidence",
            changeBudgetWithinLimit = failureCode != "maintenance-change-budget-exceeded",
        )

        val beforeVersions = LinkedHashMap<String, Int>()
        for (event in writes) {
            val data = event.data as? JsonObject ?: continue
            val path = (data.members["path"] as? JsonString)?.value ?: continue
            if (beforeVersions.containsKey(path)) continue
            val expected = (data.members["expected_version"] as? JsonNumber)
                ?.asLongOrNull()?.toInt() ?: continue
            beforeVersions[path] = expected
        }
        var status = when {
            failureCode != null -> BotMemoryMaintenanceStatus.ROLLED_BACK
            turnStatus == "cancelled" -> BotMemoryMaintenanceStatus.CANCELLED
            turnStatus == "completed" -> BotMemoryMaintenanceStatus.COMMITTED
            else -> BotMemoryMaintenanceStatus.FAILED
        }
        var effectiveFailure = when {
            failureCode == null -> null
            else -> BotMemoryMaintenanceFailureCode.parse(failureCode)?.wire
                ?: BotMemoryMaintenanceFailureCode.EVIDENCE_UNRESOLVED.wire
        }
        if (failureCode != null) {
            val rollback = rollback(
                batchId = batchId,
                changes = changes,
                beforeVersions = beforeVersions,
                sessionId = maintainerSessionId,
            )
            if (rollback.conflicts.isNotEmpty()) {
                status = BotMemoryMaintenanceStatus.ROLLBACK_FAILED
            }
        }
        val changedIndex = changes.any {
            it.path == "user/INDEX.md" || it.path == "agent/INDEX.md"
        }
        val changedUser = changes.any { it.scope == BotMemoryScope.USER }
        val notification = failureCode == null &&
            (status == BotMemoryMaintenanceStatus.COMMITTED ||
                status == BotMemoryMaintenanceStatus.CANCELLED) &&
            (changedIndex || changedUser)
        val finishedAt = now()
        val batch = BotMemoryMaintenanceBatch(
            batchId = batchId,
            botId = botId,
            status = status,
            trigger = trigger,
            startedAtMs = startedAtMs,
            finishedAtMs = finishedAt,
            maintainerSessionId = maintainerSessionId,
            changes = changes,
            checks = checks,
            budget = budget.copy(
                changedDocuments = changes.size,
                changedScalars = writtenScalars,
            ),
            failureCode = effectiveFailure,
            notification = notification,
            userScopeOwner = userScopeOwner && isMainBot,
        )
        BotMemoryMaintenanceBatch.fromJson(batch.toJson())
        append(
            type = FINISHED_TYPE,
            eventId = "$FINISHED_TYPE:$batchId",
            data = batch.toJson(),
            at = finishedAt,
            sessionId = maintainerSessionId,
            batchId = batchId,
        )
        if (status == BotMemoryMaintenanceStatus.COMMITTED ||
            status == BotMemoryMaintenanceStatus.CANCELLED
        ) {
            resolveReviewRequests(
                changes = changes,
                batchId = batchId,
                sessionId = maintainerSessionId,
            )
        }
        return batch
    }

    private fun resolveReviewRequests(
        changes: List<BotMemoryMaintenanceChange>,
        batchId: String,
        sessionId: String?,
    ) {
        val pending = BotMemoryMaintenancePlanner.pendingReviewPaths(allDurableEvents())
        for (change in changes) {
            if (change.path !in pending) continue
            val at = now()
            val data = JsonObject(
                linkedMapOf(
                    "path" to JsonString(change.path),
                    "batch_id" to JsonString(batchId),
                    "outcome" to JsonString(if (change.deleted) "dropped" else "resolved"),
                ),
            )
            append(
                type = "memory.review_resolved",
                eventId = "memory.review_resolved:$batchId:${change.path}",
                data = data,
                at = at,
                sessionId = sessionId,
                batchId = batchId,
            )
        }
    }

    private fun rollback(
        batchId: String,
        changes: List<BotMemoryMaintenanceChange>,
        beforeVersions: Map<String, Int>,
        sessionId: String?,
    ): BotMemoryMaintenanceRollback {
        val restored = ArrayList<BotMemoryMaintenanceRestore>()
        val conflicts = ArrayList<String>()
        val context = BotMemoryWriteContext(
            botId = botId,
            sessionId = null,
            authorKind = BotMemoryAuthorKind.UI,
            source = BotMemorySource(BotMemorySourceKind.AGENT_MESSAGE, role = "ui"),
            trust = null,
            isMainBot = true,
            batchId = null,
            isHostRollback = true,
        )
        for (change in changes.sortedBy { it.path }) {
            val live = (memory.read(change.path) as? BotMemoryReadResult.Document)?.version
            val before = beforeVersions[change.path] ?: change.beforeVersion
            if (change.deleted) {
                if (live != null) {
                    conflicts += change.path
                    continue
                }
                if (before == 0) continue
                val result = memory.write(
                    BotMemoryWriteRequest(
                        action = BotMemoryAction.RESTORE,
                        path = change.path,
                        expectedVersion = 0,
                        restoreVersion = before,
                    ),
                    context,
                )
                if (result is BotMemoryWriteResult.Success) {
                    restored += BotMemoryMaintenanceRestore(
                        change.path, change.afterVersion, result.version,
                    )
                } else {
                    conflicts += change.path
                }
                continue
            }
            if (live == null || live.version != change.afterVersion) {
                conflicts += change.path
                continue
            }
            if (before == 0) {
                val result = memory.forget(change.path, live.version)
                if (result.ok && result.version != null) {
                    restored += BotMemoryMaintenanceRestore(
                        change.path, change.afterVersion, result.version,
                    )
                } else {
                    conflicts += change.path
                }
            } else {
                val result = memory.write(
                    BotMemoryWriteRequest(
                        action = BotMemoryAction.RESTORE,
                        path = change.path,
                        expectedVersion = live.version,
                        restoreVersion = before,
                    ),
                    context,
                )
                if (result is BotMemoryWriteResult.Success) {
                    restored += BotMemoryMaintenanceRestore(
                        change.path, change.afterVersion, result.version,
                    )
                } else {
                    conflicts += change.path
                }
            }
        }
        val record = BotMemoryMaintenanceRollback(
            batchId = batchId,
            botId = botId,
            rolledBackAtMs = now(),
            restored = restored,
            conflicts = conflicts,
        )
        BotMemoryMaintenanceRollback.fromJson(record.toJson())
        append(
            type = ROLLED_BACK_TYPE,
            eventId = "$ROLLED_BACK_TYPE:$batchId:${record.rolledBackAtMs}",
            data = record.toJson(),
            at = record.rolledBackAtMs,
            sessionId = sessionId,
            batchId = batchId,
        )
        return record
    }

    private fun batchWrites(batchId: String): List<BotEvent> =
        allDurableEvents().filter {
            it.correlationId == "memory-maintenance:$batchId" &&
                (it.type == "memory.document_written" || it.type == "memory.document_deleted")
        }

    private fun collapseChanges(events: List<BotEvent>): List<BotMemoryMaintenanceChange> {
        val order = ArrayList<String>()
        val byPath = LinkedHashMap<String, BotMemoryMaintenanceChange>()
        for (event in events.sortedBy { it.commitSeq ?: 0L }) {
            val data = event.data as? JsonObject ?: continue
            val members = data.members
            val path = (members["path"] as? JsonString)?.value ?: continue
            val scope = BotMemoryScope.parse((members["scope"] as? JsonString)?.value) ?: continue
            val expected = (members["expected_version"] as? JsonNumber)?.asLongOrNull()?.toInt() ?: continue
            val version = (members["version"] as? JsonNumber)?.asLongOrNull()?.toInt() ?: continue
            val deleted = event.type == "memory.document_deleted"
            val existing = byPath[path]
            if (existing != null) {
                byPath[path] = existing.copy(afterVersion = version, deleted = deleted)
            } else {
                order += path
                byPath[path] = BotMemoryMaintenanceChange(
                    path, scope, expected, version, deleted,
                )
            }
        }
        return order.mapNotNull { byPath[it] }
    }

    private fun append(
        type: String,
        eventId: String,
        data: JsonValue,
        at: Long,
        sessionId: String?,
        batchId: String,
    ) {
        eventLog.append(
            BotEvent(
                schemaVersion = 1,
                type = type,
                eventId = eventId,
                commitSeq = null,
                time = maxOf(0, at),
                origin = BotEventOrigin.Local("memory-service"),
                traceId = "memory-maintenance:$batchId",
                principal = BotPrincipal(botId, sessionId, "maintainer", emptyList()),
                causationId = null,
                correlationId = "memory-maintenance:$batchId",
                data = data,
            ),
        )
    }

    private fun allDurableEvents(): List<BotEvent> {
        val result = ArrayList<BotEvent>()
        var cursor = 0
        while (true) {
            val page = eventLog.events(cursor, 500)
            if (page.isEmpty()) return result
            result += page
            val last = page.last().commitSeq ?: return result
            cursor = last.toInt()
            if (page.size < 500) return result
        }
    }

    public companion object {
        public const val STARTED_TYPE: String = "memory.maintenance_started"
        public const val FINISHED_TYPE: String = "memory.maintenance_finished"
        public const val ROLLED_BACK_TYPE: String = "memory.maintenance_rolled_back"
    }
}

// ---------------------------------------------------------------------------
// Trigger / candidate selection (v2 §4.6)
// ---------------------------------------------------------------------------

public object BotMemoryMaintenancePlanner {
    public const val MAXIMUM_CANDIDATES: Int = 12
    public const val WRITES_TRIGGER: Int = 40
    public const val INDEX_TRIGGER_SCALARS: Int = 1_350
    public const val OVERLONG_DOCUMENT_SCALARS: Int = 4_000

    public fun trigger(events: List<BotEvent>, documents: List<BotMemoryDocument>): BotMemoryMaintenanceTrigger? {
        if (pendingReviewPaths(events).isNotEmpty()) {
            return BotMemoryMaintenanceTrigger.CONTRADICTION
        }
        val indexScalars = documents.filter { BotMemoryPath.isIndex(it.path) }
            .maxOfOrNull { BotMemoryText.scalarCount(it.content) } ?: 0
        if (indexScalars >= INDEX_TRIGGER_SCALARS) return BotMemoryMaintenanceTrigger.INDEX
        val lastFinished = events.lastOrNull { it.type == BotMemoryMaintenanceBatchStore.FINISHED_TYPE }
            ?.commitSeq ?: 0L
        val writes = events.count {
            (it.commitSeq ?: 0L) > lastFinished &&
                (it.type == "memory.document_written" || it.type == "memory.document_deleted")
        }
        if (writes > WRITES_TRIGGER) return BotMemoryMaintenanceTrigger.WRITES
        return null
    }

    public fun candidates(
        events: List<BotEvent>,
        documents: List<BotMemoryDocument>,
        isMainBot: Boolean,
    ): List<BotMemoryMaintenanceCandidate> {
        val ordered = ArrayList<String>()
        val reasons = LinkedHashMap<String, MutableList<BotMemoryMaintenanceCandidateReason>>()

        fun add(path: String, reason: BotMemoryMaintenanceCandidateReason) {
            if (ordered.size >= 64) return
            if (!reasons.containsKey(path)) ordered += path
            val current = reasons.getOrPut(path) { ArrayList() }
            if (!current.contains(reason)) current += reason
        }

        val inbox = documents.filter { it.path.startsWith("agent/inbox/") }
            .groupBy { document ->
                document.path.substring("agent/inbox/".length).substringBefore("/")
            }
        for (session in inbox.keys.sorted()) {
            inbox[session]?.map { it.path }?.sorted()?.firstOrNull()?.let {
                add(it, BotMemoryMaintenanceCandidateReason.INBOX)
            }
        }
        for (path in pendingReviewPaths(events).sorted()) {
            add(path, BotMemoryMaintenanceCandidateReason.CONTRADICTION)
        }
        for (document in documents) {
            if (BotMemoryPath.isIndex(document.path) &&
                BotMemoryText.scalarCount(document.content) >= INDEX_TRIGGER_SCALARS
            ) {
                add(document.path, BotMemoryMaintenanceCandidateReason.INDEX)
            }
        }
        val readCounts = LinkedHashMap<String, Int>()
        for (event in events) {
            if (event.type != "conversation.tool_call") continue
            val data = event.data as? JsonObject ?: continue
            val name = (data.members["name"] as? JsonString)?.value ?: ""
            if (name != "ReadMemory" && !name.endsWith("__ReadMemory")) continue
            val arguments = (data.members["arguments"] as? JsonString)?.value ?: continue
            val parsed = runCatching { JsonValue.parse(arguments) as? JsonObject }.getOrNull() ?: continue
            val path = (parsed.members["path"] as? JsonString)?.value ?: continue
            readCounts[path] = (readCounts[path] ?: 0) + 1
        }
        for ((path, _) in readCounts.entries.sortedWith(
            compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key },
        )) {
            if (documents.any { it.path == path }) {
                add(path, BotMemoryMaintenanceCandidateReason.MOST_READ)
            }
        }
        val changeCounts = LinkedHashMap<String, Int>()
        for (event in events) {
            if (event.type != "memory.document_written") continue
            val data = event.data as? JsonObject ?: continue
            val path = (data.members["path"] as? JsonString)?.value ?: continue
            changeCounts[path] = (changeCounts[path] ?: 0) + 1
        }
        for ((path, _) in changeCounts.entries.sortedWith(
            compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key },
        )) {
            if (documents.any { it.path == path }) {
                add(path, BotMemoryMaintenanceCandidateReason.MOST_CHANGED)
            }
        }
        val verified = batches(events).lastOrNull {
            it.status == BotMemoryMaintenanceStatus.COMMITTED
        }?.changes?.map { it.path }?.toSet() ?: emptySet()
        for (document in documents
            .filter { it.evidence.isNotEmpty() && it.path !in verified }
            .sortedBy { it.updatedAtMs }
        ) {
            add(document.path, BotMemoryMaintenanceCandidateReason.LEAST_VERIFIED)
        }
        for (document in documents
            .filter { BotMemoryText.scalarCount(it.content) > OVERLONG_DOCUMENT_SCALARS }
        ) {
            add(document.path, BotMemoryMaintenanceCandidateReason.OVERLONG)
        }
        return ordered
            .filter { isMainBot || BotMemoryPath.scopeOf(it) != BotMemoryScope.USER }
            .take(MAXIMUM_CANDIDATES)
            .map { path ->
                BotMemoryMaintenanceCandidate(path, reasons[path].orEmpty().take(4))
            }
    }

    public fun pendingReviewPaths(events: List<BotEvent>): Set<String> {
        val pending = HashSet<String>()
        for (event in events.sortedBy { it.commitSeq ?: 0L }) {
            val data = event.data as? JsonObject ?: continue
            val path = (data.members["path"] as? JsonString)?.value ?: continue
            when (event.type) {
                "memory.review_requested" -> pending += path
                "memory.review_resolved" -> pending -= path
            }
        }
        return pending
    }

    private fun batches(events: List<BotEvent>): List<BotMemoryMaintenanceBatch> =
        events.mapNotNull { event ->
            if (event.type != BotMemoryMaintenanceBatchStore.FINISHED_TYPE) return@mapNotNull null
            runCatching { BotMemoryMaintenanceBatch.fromJson(event.data) }.getOrNull()
        }
}

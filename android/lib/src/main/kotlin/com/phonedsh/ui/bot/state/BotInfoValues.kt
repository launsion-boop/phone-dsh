// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJsonException
import java.time.ZoneId

/** `memories[].scope` (P09 `info.schema.json`). */
public enum class BotMemoryScope(public val wire: String) {
    AGENT("agent"),
    USER("user"),
    ;

    public companion object {
        public fun fromWire(value: String): BotMemoryScope =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown memory scope: $value")
    }
}

/** `presence.level` (P09 `info.schema.json`). */
public enum class RoutinePresenceLevel(public val wire: String) {
    FOREGROUND("foreground"),
    BACKGROUND_KEEP_ALIVE("backgroundKeepAlive"),
    SCHEDULED_NOTIFICATION("scheduledNotification"),
    ;

    public companion object {
        public fun fromWire(value: String): RoutinePresenceLevel =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown routine presence level: $value")
    }
}

/** `proactiveSettings.mode` (P09 `info.schema.json`). */
public enum class ProactiveMode(public val wire: String) {
    OFF("off"),
    WOULD("would"),
    ON("on"),
    ;

    public companion object {
        public fun fromWire(value: String): ProactiveMode =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown proactive mode: $value")
    }
}

/** One historical version of a memory document. */
public data class BotMemoryVersionInfo(
    public val id: String,
    public val version: Long,
    public val content: String,
    public val deleted: Boolean,
    public val deletionReason: String?,
    public val updatedAt: Long,
    public val author: String,
    public val evidence: List<String>,
) {
    public companion object {
        public fun fromJson(value: JsonValue): BotMemoryVersionInfo {
            val members = JsonSupport.objectMembers(value, "memoryVersion")
            return BotMemoryVersionInfo(
                id = nonEmptyId(members, "memoryVersion"),
                version = JsonSupport.requiredNonNegativeLong(members, "version", "memoryVersion.version"),
                content = JsonSupport.requiredString(members, "content", "memoryVersion.content"),
                deleted = JsonSupport.requiredBool(members, "deleted", "memoryVersion.deleted"),
                deletionReason = JsonSupport.optionalString(
                    members, "deletionReason", "memoryVersion.deletionReason"),
                updatedAt = JsonSupport.requiredNonNegativeLong(
                    members, "updatedAt", "memoryVersion.updatedAt"),
                author = JsonSupport.requiredString(members, "author", "memoryVersion.author"),
                evidence = JsonSupport.requiredStringArray(
                    members, "evidence", "memoryVersion.evidence"),
            )
        }
    }
}

/** One memory document and its versions (order is the projection's order). */
public data class BotMemoryDocumentInfo(
    public val id: String,
    public val path: String,
    public val scope: BotMemoryScope,
    public val content: String,
    public val version: Long,
    public val updatedAt: Long,
    public val author: String,
    public val evidence: List<String>,
    public val versions: List<BotMemoryVersionInfo>,
) {
    public companion object {
        public fun fromJson(value: JsonValue): BotMemoryDocumentInfo {
            val members = JsonSupport.objectMembers(value, "memory")
            return BotMemoryDocumentInfo(
                id = nonEmptyId(members, "memory"),
                path = nonEmptyString(members, "path", "memory.path"),
                scope = BotMemoryScope.fromWire(
                    JsonSupport.requiredString(members, "scope", "memory.scope")),
                content = JsonSupport.requiredString(members, "content", "memory.content"),
                version = JsonSupport.requiredNonNegativeLong(members, "version", "memory.version"),
                updatedAt = JsonSupport.requiredNonNegativeLong(
                    members, "updatedAt", "memory.updatedAt"),
                author = JsonSupport.requiredString(members, "author", "memory.author"),
                evidence = JsonSupport.requiredStringArray(members, "evidence", "memory.evidence"),
                versions = JsonSupport.array(members["versions"], "memory.versions").map {
                    BotMemoryVersionInfo.fromJson(it)
                },
            )
        }
    }
}

/** One routine summary row (`info.schema.json` `routines[]`). */
public data class BotRoutineInfo(
    public val id: String,
    public val title: String,
    public val schedule: String,
    public val timeZone: String,
    public val delivery: String,
    public val quiet: Boolean,
    public val urgent: Boolean,
    public val urgentReason: String? = null,
    public val lastResult: String,
    public val enabled: Boolean,
    public val creator: String? = null,
    public val completionCriteria: String? = null,
    public val routineConstraints: String? = null,
    public val runStatus: String? = null,
    public val runID: String? = null,
    public val nextDue: Long? = null,
    public val quietDeferredFrom: Long? = null,
    public val quietDeferredUntil: Long? = null,
    public val creatorDetail: String? = null,
    public val lastResultDetail: String? = null,
) {
    /** A `started` run offers 「取消运行」 (`ui-state.md` §4.12). */
    public val canCancelRun: Boolean get() = runStatus == "started"

    /** `needs-reconciliation` shows exactly one reconciliation block. */
    public val needsReconciliation: Boolean get() = runStatus == "needs-reconciliation"

    public companion object {
        public fun fromJson(value: JsonValue): BotRoutineInfo {
            val members = JsonSupport.objectMembers(value, "routine")
            return BotRoutineInfo(
                id = nonEmptyId(members, "routine"),
                title = JsonSupport.requiredString(members, "title", "routine.title"),
                schedule = JsonSupport.requiredString(members, "schedule", "routine.schedule"),
                timeZone = JsonSupport.requiredString(members, "timeZone", "routine.timeZone"),
                delivery = JsonSupport.requiredString(members, "delivery", "routine.delivery"),
                quiet = JsonSupport.requiredBool(members, "quiet", "routine.quiet"),
                urgent = JsonSupport.requiredBool(members, "urgent", "routine.urgent"),
                urgentReason = JsonSupport.optionalString(
                    members, "urgentReason", "routine.urgentReason"),
                lastResult = JsonSupport.requiredString(members, "lastResult", "routine.lastResult"),
                enabled = JsonSupport.requiredBool(members, "enabled", "routine.enabled"),
                creator = JsonSupport.optionalString(members, "creator", "routine.creator"),
                completionCriteria = JsonSupport.optionalString(
                    members, "completionCriteria", "routine.completionCriteria"),
                routineConstraints = JsonSupport.optionalString(
                    members, "routineConstraints", "routine.routineConstraints"),
                runStatus = JsonSupport.optionalString(members, "runStatus", "routine.runStatus"),
                runID = JsonSupport.optionalString(members, "runID", "routine.runID"),
                nextDue = JsonSupport.optionalNonNegativeLong(members, "nextDue", "routine.nextDue"),
                quietDeferredFrom = JsonSupport.optionalNonNegativeLong(
                    members, "quietDeferredFrom", "routine.quietDeferredFrom"),
                quietDeferredUntil = JsonSupport.optionalNonNegativeLong(
                    members, "quietDeferredUntil", "routine.quietDeferredUntil"),
                creatorDetail = JsonSupport.optionalString(
                    members, "creatorDetail", "routine.creatorDetail"),
                lastResultDetail = JsonSupport.optionalString(
                    members, "lastResultDetail", "routine.lastResultDetail"),
            )
        }
    }
}

/** One already-human-readable approval record. */
public data class BotApprovalRecord(
    public val id: String,
    public val parameterSummary: String,
    public val decision: String,
    public val decidedAt: Long,
) {
    public companion object {
        public fun fromJson(value: JsonValue): BotApprovalRecord {
            val members = JsonSupport.objectMembers(value, "approvalRecord")
            return BotApprovalRecord(
                id = nonEmptyId(members, "approvalRecord"),
                parameterSummary = JsonSupport.requiredString(
                    members, "parameterSummary", "approvalRecord.parameterSummary"),
                decision = JsonSupport.requiredString(members, "decision", "approvalRecord.decision"),
                decidedAt = JsonSupport.requiredNonNegativeLong(
                    members, "decidedAt", "approvalRecord.decidedAt"),
            )
        }
    }
}

/** A standing grant (`scope != once` — the view filters `once` out). */
public data class BotGrantInfo(
    public val id: String,
    public val tool: String,
    public val operation: String,
    public val resource: String,
    public val scope: String,
    public val sessionID: String?,
    public val createdAt: Long,
    public val source: String,
) {
    public companion object {
        public fun fromJson(value: JsonValue): BotGrantInfo {
            val members = JsonSupport.objectMembers(value, "grant")
            return BotGrantInfo(
                id = nonEmptyId(members, "grant"),
                tool = JsonSupport.requiredString(members, "tool", "grant.tool"),
                operation = JsonSupport.requiredString(members, "operation", "grant.operation"),
                resource = JsonSupport.requiredString(members, "resource", "grant.resource"),
                scope = JsonSupport.requiredString(members, "scope", "grant.scope"),
                sessionID = JsonSupport.optionalString(members, "sessionID", "grant.sessionID"),
                createdAt = JsonSupport.requiredNonNegativeLong(
                    members, "createdAt", "grant.createdAt"),
                source = JsonSupport.requiredString(members, "source", "grant.source"),
            )
        }

        /** The standing grants the info page renders: `scope != once`. */
        public fun standing(grants: List<BotGrantInfo>): List<BotGrantInfo> =
            grants.filter { it.scope != "once" }
    }
}

/** One routine run that needs reconciliation. */
public data class BotReconciliationInfo(
    public val routineID: String,
    public val routineTitle: String,
    public val attempt: Int,
    public val runID: String,
    public val error: String? = null,
    public val effectSummary: String? = null,
    public val effectDetail: String? = null,
) {
    public companion object {
        public fun fromJson(value: JsonValue): BotReconciliationInfo {
            val members = JsonSupport.objectMembers(value, "reconciliation")
            return BotReconciliationInfo(
                routineID = nonEmptyId(members, "reconciliation", "routineID"),
                routineTitle = JsonSupport.requiredString(
                    members, "routineTitle", "reconciliation.routineTitle"),
                attempt = JsonSupport.requiredNonNegativeInt(
                    members, "attempt", "reconciliation.attempt"),
                runID = JsonSupport.requiredString(members, "runID", "reconciliation.runID"),
                error = JsonSupport.optionalString(members, "error", "reconciliation.error"),
                effectSummary = JsonSupport.optionalString(
                    members, "effectSummary", "reconciliation.effectSummary"),
                effectDetail = JsonSupport.optionalString(
                    members, "effectDetail", "reconciliation.effectDetail"),
            )
        }
    }
}

/** One routine deferred by `quiet_defer`. */
public data class RoutinePresenceDeferred(
    public val routineId: String,
    public val title: String,
    public val scheduledFor: Long,
    public val deferredUntil: Long,
) {
    public companion object {
        public fun fromJson(value: JsonValue): RoutinePresenceDeferred {
            val members = JsonSupport.objectMembers(value, "presence.deferred")
            return RoutinePresenceDeferred(
                routineId = nonEmptyId(members, "presence.deferred", "routineId"),
                title = JsonSupport.requiredString(members, "title", "presence.deferred.title"),
                scheduledFor = JsonSupport.requiredNonNegativeLong(
                    members, "scheduledFor", "presence.deferred.scheduledFor"),
                deferredUntil = JsonSupport.requiredNonNegativeLong(
                    members, "deferredUntil", "presence.deferred.deferredUntil"),
            )
        }
    }
}

/** How the host is keeping this Bot's routines alive. */
public data class RoutinePresence(
    public val level: RoutinePresenceLevel = RoutinePresenceLevel.FOREGROUND,
    public val deferred: List<RoutinePresenceDeferred> = emptyList(),
    public val scheduledNotificationCount: Int = 0,
) {
    public companion object {
        public val DEFAULT: RoutinePresence = RoutinePresence()

        public fun fromJson(value: JsonValue): RoutinePresence {
            val members = JsonSupport.objectMembers(value, "presence")
            return RoutinePresence(
                level = RoutinePresenceLevel.fromWire(
                    JsonSupport.requiredString(members, "level", "presence.level")),
                deferred = JsonSupport.array(members["deferred"], "presence.deferred").map {
                    RoutinePresenceDeferred.fromJson(it)
                },
                scheduledNotificationCount = JsonSupport.requiredNonNegativeInt(
                    members, "scheduledNotificationCount", "presence.scheduledNotificationCount"),
            )
        }
    }
}

/** The persisted disturbance settings (`phone-dsh.bot.proactive-settings.v1`). */
public data class ProactiveSettings(
    public val mode: ProactiveMode = ProactiveMode.ON,
    public val dnd: Boolean = false,
    public val quietStart: String = "23:00",
    public val quietEnd: String = "08:00",
    public val routineQuietWeekends: Boolean = false,
    public val timeZone: String = ZoneId.systemDefault().id,
) {
    public companion object {
        private val QUIET_PATTERN = Regex("^[0-9]{1,2}:[0-9]{2}$")

        /** The production default; the time zone is the device zone. */
        public fun productionDefault(): ProactiveSettings = ProactiveSettings()

        public fun fromJson(value: JsonValue): ProactiveSettings {
            val members = JsonSupport.objectMembers(value, "proactiveSettings")
            val quietStart = JsonSupport.requiredString(
                members, "quietStart", "proactiveSettings.quietStart")
            if (!QUIET_PATTERN.matches(quietStart)) {
                throw BotJsonException("proactiveSettings.quietStart must be HH:mm")
            }
            val quietEnd = JsonSupport.requiredString(
                members, "quietEnd", "proactiveSettings.quietEnd")
            if (!QUIET_PATTERN.matches(quietEnd)) {
                throw BotJsonException("proactiveSettings.quietEnd must be HH:mm")
            }
            val timeZone = JsonSupport.requiredString(
                members, "timeZone", "proactiveSettings.timeZone")
            if (timeZone.isEmpty()) {
                throw BotJsonException("proactiveSettings.timeZone must not be empty")
            }
            return ProactiveSettings(
                mode = ProactiveMode.fromWire(
                    JsonSupport.requiredString(members, "mode", "proactiveSettings.mode")),
                dnd = JsonSupport.requiredBool(members, "dnd", "proactiveSettings.dnd"),
                quietStart = quietStart,
                quietEnd = quietEnd,
                routineQuietWeekends = JsonSupport.requiredBool(
                    members, "routineQuietWeekends", "proactiveSettings.routineQuietWeekends"),
                timeZone = timeZone,
            )
        }
    }
}

/** One document changed by a maintenance batch. */
public data class BotMaintenanceChange(
    public val path: String,
    public val scope: BotMemoryScope,
    public val beforeVersion: Long,
    public val afterVersion: Long,
    public val deleted: Boolean,
) {
    public companion object {
        public fun fromJson(value: JsonValue): BotMaintenanceChange {
            val members = JsonSupport.objectMembers(value, "maintenance.change")
            return BotMaintenanceChange(
                path = nonEmptyString(members, "path", "maintenance.change.path"),
                scope = BotMemoryScope.fromWire(
                    JsonSupport.requiredString(members, "scope", "maintenance.change.scope")),
                beforeVersion = JsonSupport.requiredNonNegativeLong(
                    members, "beforeVersion", "maintenance.change.beforeVersion"),
                afterVersion = JsonSupport.requiredNonNegativeLong(
                    members, "afterVersion", "maintenance.change.afterVersion"),
                deleted = JsonSupport.requiredBool(
                    members, "deleted", "maintenance.change.deleted"),
            )
        }
    }
}

/** The last real maintenance batch; never fabricated. */
public data class BotMaintenanceBatchInfo(
    public val batchID: String,
    public val status: String,
    public val trigger: String,
    public val startedAt: Long,
    public val finishedAt: Long,
    public val changedDocuments: Int,
    public val changes: List<BotMaintenanceChange>,
    public val checksPassed: Boolean,
    public val rolledBack: Boolean,
    public val canRollback: Boolean,
    public val tokensUsed: Long,
    public val notification: Boolean,
    public val failureCode: String? = null,
) {
    public companion object {
        public fun fromJson(value: JsonValue): BotMaintenanceBatchInfo {
            val members = JsonSupport.objectMembers(value, "maintenance")
            return BotMaintenanceBatchInfo(
                batchID = nonEmptyId(members, "maintenance", "batchID"),
                status = JsonSupport.requiredString(members, "status", "maintenance.status"),
                trigger = JsonSupport.requiredString(members, "trigger", "maintenance.trigger"),
                startedAt = JsonSupport.requiredNonNegativeLong(
                    members, "startedAt", "maintenance.startedAt"),
                finishedAt = JsonSupport.requiredNonNegativeLong(
                    members, "finishedAt", "maintenance.finishedAt"),
                changedDocuments = JsonSupport.requiredNonNegativeInt(
                    members, "changedDocuments", "maintenance.changedDocuments"),
                changes = JsonSupport.array(members["changes"], "maintenance.changes").map {
                    BotMaintenanceChange.fromJson(it)
                },
                checksPassed = JsonSupport.requiredBool(
                    members, "checksPassed", "maintenance.checksPassed"),
                rolledBack = JsonSupport.requiredBool(
                    members, "rolledBack", "maintenance.rolledBack"),
                canRollback = JsonSupport.requiredBool(
                    members, "canRollback", "maintenance.canRollback"),
                tokensUsed = JsonSupport.requiredNonNegativeLong(
                    members, "tokensUsed", "maintenance.tokensUsed"),
                notification = JsonSupport.requiredBool(
                    members, "notification", "maintenance.notification"),
                failureCode = JsonSupport.optionalString(
                    members, "failureCode", "maintenance.failureCode"),
            )
        }
    }
}

/** One info load result; the view never merges partial sub-loads. */
public data class BotInfoSnapshot(
    public val botName: String,
    public val memories: List<BotMemoryDocumentInfo>,
    public val routines: List<BotRoutineInfo>,
    public val approvals: List<BotApprovalRecord>,
    public val grants: List<BotGrantInfo> = emptyList(),
    public val reconciliations: List<BotReconciliationInfo> = emptyList(),
    public val presence: RoutinePresence = RoutinePresence.DEFAULT,
    public val proactiveSettings: ProactiveSettings = ProactiveSettings.productionDefault(),
    public val maintenance: BotMaintenanceBatchInfo? = null,
    public val maintenanceEnabled: Boolean = false,
    public val maintenanceDailyTokens: Long = 0,
    public val maintenanceDailyBudget: Long = 0,
) {
    /** `maintenanceDailyBudget == 0` renders `—`, never a divide-by-zero. */
    public val maintenanceDailyBudgetPercent: Int?
        get() = if (maintenanceDailyBudget == 0L) null
        else ((maintenanceDailyTokens * 100) / maintenanceDailyBudget).toInt()

    public companion object {
        public fun fromJson(value: JsonValue): BotInfoSnapshot {
            val members = JsonSupport.objectMembers(value, "info")
            val botName = JsonSupport.requiredString(members, "botName", "info.botName")
            if (botName.isEmpty()) throw BotJsonException("info.botName must not be empty")
            val memories = JsonSupport.array(
                members["memories"] ?: throw BotJsonException("missing member memories"),
                "info.memories",
            ).map { BotMemoryDocumentInfo.fromJson(it) }
            val routines = JsonSupport.array(
                members["routines"] ?: throw BotJsonException("missing member routines"),
                "info.routines",
            ).map { BotRoutineInfo.fromJson(it) }
            val approvals = JsonSupport.array(
                members["approvals"] ?: throw BotJsonException("missing member approvals"),
                "info.approvals",
            ).map { BotApprovalRecord.fromJson(it) }
            val grants = JsonSupport.optionalArray(members["grants"], "info.grants")
                ?.map { BotGrantInfo.fromJson(it) } ?: emptyList()
            val reconciliations = JsonSupport.optionalArray(
                members["reconciliations"], "info.reconciliations")
                ?.map { BotReconciliationInfo.fromJson(it) } ?: emptyList()
            val presence = members["presence"]?.let {
                if (it is com.phonedsh.agentcore.JsonNull) RoutinePresence.DEFAULT
                else RoutinePresence.fromJson(it)
            } ?: RoutinePresence.DEFAULT
            val settings = members["proactiveSettings"]?.let {
                if (it is com.phonedsh.agentcore.JsonNull) ProactiveSettings.productionDefault()
                else ProactiveSettings.fromJson(it)
            } ?: ProactiveSettings.productionDefault()
            val maintenance = when (val raw = members["maintenance"]) {
                null, is com.phonedsh.agentcore.JsonNull -> null
                else -> BotMaintenanceBatchInfo.fromJson(raw)
            }
            return BotInfoSnapshot(
                botName = botName,
                memories = memories,
                routines = routines,
                approvals = approvals,
                grants = grants,
                reconciliations = reconciliations,
                presence = presence,
                proactiveSettings = settings,
                maintenance = maintenance,
                maintenanceEnabled = JsonSupport.optionalBool(
                    members, "maintenanceEnabled", "info.maintenanceEnabled") ?: false,
                maintenanceDailyTokens = JsonSupport.optionalNonNegativeLong(
                    members, "maintenanceDailyTokens", "info.maintenanceDailyTokens") ?: 0,
                maintenanceDailyBudget = JsonSupport.optionalNonNegativeLong(
                    members, "maintenanceDailyBudget", "info.maintenanceDailyBudget") ?: 0,
            )
        }
    }
}

/** One of the info page's three independent data-section load states. */
public sealed interface BotInfoLoadState {
    public data object Loading : BotInfoLoadState
    public data object Loaded : BotInfoLoadState
    public data class Failed(public val reason: String) : BotInfoLoadState
}

/**
 * The pure load-state machine behind `BotInfoModel`: memory, routines and
 * approvals each start `loading` (driver, no snapshot), become `loaded` from
 * a snapshot or a successful load, and all become `failed` together. A failed
 * load keeps the previous snapshot visible and never replaces it with zeroes.
 */
public data class BotInfoModelState(
    public val snapshot: BotInfoSnapshot? = null,
    public val memoryState: BotInfoLoadState = BotInfoLoadState.Loaded,
    public val routinesState: BotInfoLoadState = BotInfoLoadState.Loaded,
    public val approvalsState: BotInfoLoadState = BotInfoLoadState.Loaded,
    public val actionError: String? = null,
) {
    public companion object {
        public fun initial(
            snapshot: BotInfoSnapshot? = null,
            hasDriver: Boolean = false,
            fixtureError: String? = null,
        ): BotInfoModelState {
            val state: BotInfoLoadState = when {
                fixtureError != null -> BotInfoLoadState.Failed(fixtureError)
                snapshot == null && hasDriver -> BotInfoLoadState.Loading
                else -> BotInfoLoadState.Loaded
            }
            return BotInfoModelState(
                snapshot = snapshot,
                memoryState = state,
                routinesState = state,
                approvalsState = state,
            )
        }

        public fun loaded(snapshot: BotInfoSnapshot): BotInfoModelState = BotInfoModelState(
            snapshot = snapshot,
            memoryState = BotInfoLoadState.Loaded,
            routinesState = BotInfoLoadState.Loaded,
            approvalsState = BotInfoLoadState.Loaded,
        )

        public fun failed(previous: BotInfoModelState, reason: String): BotInfoModelState =
            previous.copy(
                memoryState = BotInfoLoadState.Failed(reason),
                routinesState = BotInfoLoadState.Failed(reason),
                approvalsState = BotInfoLoadState.Failed(reason),
            )
    }
}

private fun nonEmptyId(
    members: Map<String, JsonValue>,
    path: String,
    key: String = "id",
): String {
    val value = JsonSupport.requiredString(members, key, "$path.$key")
    if (value.isEmpty()) throw BotJsonException("$path.$key must not be empty")
    return value
}

private fun nonEmptyString(
    members: Map<String, JsonValue>,
    key: String,
    path: String,
): String {
    val value = JsonSupport.requiredString(members, key, path)
    if (value.isEmpty()) throw BotJsonException("$path must not be empty")
    return value
}

/** The four info destinations reachable from the Bot page (`BotInfoSection`). */
public enum class BotInfoSection(public val wire: String) {
    MEMORY("memory"),
    ROUTINES("routines"),
    APPROVALS("approvals"),
    GRANTS("grants"),
}

/**
 * A request to present the info page at one section; a routine-due
 * notification also carries the routine row to highlight.
 */
public data class BotInfoPresentationRequest(
    public val section: BotInfoSection? = null,
    public val highlightRoutineID: String? = null,
)

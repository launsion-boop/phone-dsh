// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.content.SharedPreferences
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.authz.BotGrantStore
import com.phonedsh.bot.memory.BotDomainMemoryEventLog
import com.phonedsh.bot.memory.BotMemory
import com.phonedsh.bot.memory.BotMemoryMaintenanceBatchStore
import com.phonedsh.bot.memory.BotMemoryMaintenanceSettings
import com.phonedsh.bot.memory.BotSqlMemoryDocumentStore
import com.phonedsh.bot.proactive.ProactiveSettingsStore
import com.phonedsh.bot.routines.RoutineMachine
import com.phonedsh.bot.routines.RoutinePatch
import com.phonedsh.bot.routines.RoutineScheduler
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.ui.bot.state.BotApprovalRecord
import com.phonedsh.ui.bot.state.BotDrawerIntent
import com.phonedsh.ui.bot.state.BotGrantInfo
import com.phonedsh.ui.bot.state.BotInfoIntent
import com.phonedsh.ui.bot.state.BotInfoSnapshot
import com.phonedsh.ui.bot.state.BotMaintenanceBatchInfo
import com.phonedsh.ui.bot.state.BotMaintenanceChange
import com.phonedsh.ui.bot.state.BotMemoryDocumentInfo
import com.phonedsh.ui.bot.state.BotMemoryScope
import com.phonedsh.ui.bot.state.BotMemoryVersionInfo
import com.phonedsh.ui.bot.state.BotReconciliationInfo
import com.phonedsh.ui.bot.state.BotRoutineInfo
import com.phonedsh.ui.bot.state.ProactiveMode
import com.phonedsh.ui.bot.state.ProactiveSettings
import org.json.JSONObject

/** Projects the same stores the Bot runtime uses. Called on the serialized host I/O lane. */
internal class AppBotInfo(
    private val store: BotDomainStore,
    private val preferences: SharedPreferences,
    private val proactive: ProactiveSettingsStore,
    private val grants: BotGrantStore,
    private val approvalLog: AppBotAuthzEventLog,
    private val routines: RoutineMachine,
    private val scheduler: RoutineScheduler,
    private val roster: AppBotRosterController,
    private val clock: () -> Long,
) {
    fun handle(id: String, intent: BotInfoIntent): BotInfoSnapshot {
        check(roster.state.value.roster.any { it.id == id }) { "找不到这个 Bot" }
        val main = roster.mainBotId() == id
        val memory = BotMemory(BotSqlMemoryDocumentStore.forDomainStore(store, id, clock), id, now = clock)
        val batches = BotMemoryMaintenanceBatchStore(BotDomainMemoryEventLog(store), memory, id, main, clock)
        val key = BotMemoryMaintenanceSettings.DEFAULTS_KEY
        val settings = preferences.getString(key, null)?.let(::JSONObject) ?: JSONObject()
            .put("enabled", BotMemoryMaintenanceSettings.standard.enabled)
            .put("runTokenBudget", BotMemoryMaintenanceSettings.standard.runTokenBudget)
            .put("dailyTokenBudget", BotMemoryMaintenanceSettings.standard.dailyTokenBudget)

        when (intent) {
            BotInfoIntent.Load -> Unit
            is BotInfoIntent.Rename -> roster.apply(BotDrawerIntent.Rename(id, intent.name))
            is BotInfoIntent.SaveProactiveSettings -> with(intent.settings) {
                proactive.save(proactive.load().copy(mode = com.phonedsh.bot.proactive.ProactiveMode.valueOf(mode.name),
                    dnd = dnd, quietStart = quietStart, quietEnd = quietEnd,
                    routineQuietWeekends = routineQuietWeekends, timeZone = timeZone))
            }
            is BotInfoIntent.SetMaintenanceEnabled -> check(preferences.edit()
                .putString(key, settings.put("enabled", intent.enabled).toString()).commit()) { "无法保存记忆整理设置" }
            is BotInfoIntent.Forget -> check(memory.forget(intent.documentPath, Math.toIntExact(intent.version)).ok) { "记忆版本已变化，请刷新" }
            BotInfoIntent.Erase, BotInfoIntent.EraseShared, is BotInfoIntent.EraseDocument ->
                error("会话日志擦除服务不可用，记忆已保留")
            is BotInfoIntent.RevokeGrant -> check(grants.list(id).any { it.id == intent.grantID } && grants.revoke(intent.grantID)) { "授权已失效" }
            is BotInfoIntent.SetRoutineEnabled -> routines.update(id, intent.routineID, RoutinePatch(enabled = intent.enabled), clock())
            is BotInfoIntent.CancelRoutine -> check(id == AppBotRoster.DEFAULT_BOT_ID && scheduler.cancelRunning(intent.routineID).cancelled) { "任务未在运行" }
            is BotInfoIntent.ResolveReconciliation -> checkNotNull(routines.resolveReconciliation(id, intent.routineID, intent.decision.wire, clock()))
            is BotInfoIntent.RollbackMaintenance -> {
                val batch = checkNotNull(batches.lastBatch())
                check(batch.batchId == intent.batchID && batches.lastRollback(batch.batchId) == null)
                check(batches.rollback(batch.batchId)?.conflicts?.isEmpty() == true) { "文档已变更，无法完整回滚" }
            }
        }
        val prefs = proactive.load()
        val rows = routines.list(id)
        val history = batches.batches()
        val last = history.lastOrNull()?.let { batch ->
            val rolledBack = batches.lastRollback(batch.batchId) != null || batch.status.wire in setOf("rolled_back", "rollback_failed")
            BotMaintenanceBatchInfo(batch.batchId, batch.status.wire, batch.trigger.wire, batch.startedAtMs, batch.finishedAtMs,
                batch.changes.size, batch.changes.map {
                    BotMaintenanceChange(it.path, BotMemoryScope.fromWire(it.scope.wire), it.beforeVersion.toLong(), it.afterVersion.toLong(), it.deleted)
                }, batch.checks.passedAll, rolledBack, !rolledBack && batch.changes.isNotEmpty() && batch.status.wire in setOf("committed", "cancelled", "failed"),
                batch.budget.tokensUsed.toLong(), batch.notification, batch.failureCode)
        }
        return BotInfoSnapshot(
            botName = roster.state.value.roster.first { it.id == id }.name,
            memories = memory.documents().map { doc ->
                BotMemoryDocumentInfo(doc.path, doc.path, BotMemoryScope.fromWire(doc.scope.wire), doc.content,
                    doc.version.toLong(), doc.updatedAtMs, doc.author.kind.wire, doc.evidence, memory.versions(doc.path).map {
                        BotMemoryVersionInfo("${doc.path}#${it.version}", it.version.toLong(), it.content, it.deleted,
                            it.deletionReason, it.updatedAtMs, it.author.kind.wire, it.evidence)
                    })
            },
            routines = rows.map {
                BotRoutineInfo(it.id, it.title, it.schedule.expr ?: it.schedule.time ?: it.schedule.everyMinutes?.let { n -> "每 ${n} 分钟" }.orEmpty(),
                    it.schedule.timezone, it.delivery.rawValue, it.delivery.rawValue == "held", it.urgent,
                    it.urgentReason, it.lastResult?.text.orEmpty(), it.enabled, completionCriteria = it.completionCriteria,
                    routineConstraints = it.constraints, runStatus = it.runState?.status?.rawValue, runID = it.runState?.runId,
                    nextDue = it.nextRunAt, quietDeferredFrom = it.quietDefer?.scheduledFor, quietDeferredUntil = it.quietDefer?.until)
            },
            reconciliations = rows.mapNotNull { row ->
                row.runState?.takeIf { it.status.rawValue == "needs-reconciliation" }?.let {
                    BotReconciliationInfo(row.id, row.title, it.attempt, it.runId, it.error)
                }
            },
            approvals = approvalHistory(id),
            grants = grants.list(id).filter { it.scope.wire != "once" }.sortedByDescending { it.createdAt }.map {
                BotGrantInfo(it.id, it.tool, it.operation, it.resource, it.scope.wire, it.sessionId, it.createdAt, it.source)
            },
            proactiveSettings = ProactiveSettings(ProactiveMode.valueOf(prefs.mode.name), prefs.dnd, prefs.quietStart,
                prefs.quietEnd, prefs.routineQuietWeekends, prefs.timeZone),
            maintenance = last, maintenanceEnabled = settings.getBoolean("enabled"),
            maintenanceDailyBudget = settings.getLong("dailyTokenBudget"),
            maintenanceDailyTokens = history.filter { it.finishedAtMs / 86400000L == clock() / 86400000L }.sumOf { it.budget.tokensUsed.toLong() },
        )
    }

    private fun approvalHistory(id: String): List<BotApprovalRecord> {
        val summaries = mutableMapOf<String, String>()
        val records = mutableListOf<BotApprovalRecord>()
        var after = 0L
        while (true) {
            val page = approvalLog.events(after, 256)
            for (event in page.filter { it.principal?.botId == id }) {
                fun text(name: String) = (event.data[name] as? JsonString)?.value
                val approval = text("approvalID") ?: continue
                if (event.type == "approval.requested") summaries[approval] = text("detail") ?: text("action").orEmpty()
                if (event.type == "approval.decided") records += BotApprovalRecord(approval, summaries[approval].orEmpty(),
                    text("decision") ?: text("status").orEmpty(), event.time)
            }
            if (page.size < 256) return records.asReversed()
            after = page.last().sequence
        }
    }
}

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
import com.phonedsh.bot.routines.Routine
import com.phonedsh.bot.routines.RoutineSchedule
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
    private val sessionEraser: BotSessionErasure?,
) {
    fun handle(id: String, intent: BotInfoIntent, onNotice: (String) -> Unit = {}): BotInfoSnapshot {
        check(roster.state.value.roster.any { it.id == id }) { "找不到这个 Bot" }
        val main = roster.mainBotId() == id
        val memory = BotMemory(BotSqlMemoryDocumentStore.forDomainStore(store, id, clock), id, now = clock)
        val batches = BotMemoryMaintenanceBatchStore(BotDomainMemoryEventLog(store), memory, id, main, clock)
        when (intent) {
            BotInfoIntent.Load -> Unit
            is BotInfoIntent.Rename -> roster.apply(BotDrawerIntent.Rename(id, intent.name))
            is BotInfoIntent.SaveProactiveSettings -> with(intent.settings) {
                proactive.save(proactive.load().copy(mode = com.phonedsh.bot.proactive.ProactiveMode.valueOf(mode.name),
                    dnd = dnd, quietStart = quietStart, quietEnd = quietEnd,
                    routineQuietWeekends = routineQuietWeekends, timeZone = timeZone))
            }
            is BotInfoIntent.SetMaintenanceEnabled -> saveMaintenance(readMaintenance().copy(enabled = intent.enabled))
            is BotInfoIntent.Forget -> check(memory.forget(intent.documentPath, Math.toIntExact(intent.version)).ok) { "记忆版本已变化，请刷新" }
            BotInfoIntent.Erase, BotInfoIntent.EraseShared, is BotInfoIntent.EraseDocument -> {
                val service = checkNotNull(sessionEraser) { "会话日志擦除服务不可用，记忆已保留" }
                val result = service.perform { eraser ->
                    when (intent) {
                        is BotInfoIntent.EraseDocument -> memory.erase(intent.documentPath, eraser)
                        BotInfoIntent.EraseShared -> memory.erase(com.phonedsh.bot.memory.BotMemoryScope.USER, eraser)
                        else -> memory.erase(com.phonedsh.bot.memory.BotMemoryScope.AGENT, eraser)
                    }
                }
                check(result.ok) { result.error ?: "抹除记忆失败" }
                if (result.uncoveredRecords.isNotEmpty()) {
                    onNotice("已抹除记忆。另有 ${result.uncoveredRecords.size} 条会话记录无法确认已关闭，已保留。")
                }
                for (bot in roster.state.value.roster) roster.invalidateErasedHistory(bot.id)
            }
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
        val settings = readMaintenance()
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
            routines = rows.map(::routineInfo),
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
            maintenance = last, maintenanceEnabled = settings.enabled,
            maintenanceDailyBudget = settings.dailyTokenBudget.toLong(),
            maintenanceDailyTokens = history.filter { it.finishedAtMs / 86400000L == clock() / 86400000L }.sumOf { it.budget.tokensUsed.toLong() },
        )
    }

    private fun readMaintenance(): BotMemoryMaintenanceSettings {
        val defaults = BotMemoryMaintenanceSettings.standard
        val stored = preferences.getString(BotMemoryMaintenanceSettings.DEFAULTS_KEY, null) ?: return defaults
        return try {
            val json = JSONObject(stored)
            fun budget(key: String): Int {
                val number = json.get(key)
                require(number is Int || number is Long)
                return Math.toIntExact((number as Number).toLong()).coerceAtLeast(1)
            }
            BotMemoryMaintenanceSettings(json.get("enabled") as Boolean, budget("runTokenBudget"), budget("dailyTokenBudget"))
        } catch (_: Exception) {
            defaults
        }
    }

    private fun saveMaintenance(settings: BotMemoryMaintenanceSettings) {
        val json = JSONObject().put("enabled", settings.enabled)
            .put("runTokenBudget", settings.runTokenBudget)
            .put("dailyTokenBudget", settings.dailyTokenBudget)
        check(preferences.edit().putString(BotMemoryMaintenanceSettings.DEFAULTS_KEY, json.toString()).commit()) {
            "无法保存记忆整理设置"
        }
    }

    private fun routineInfo(row: Routine): BotRoutineInfo {
        val schedule = row.schedule
        val description = when (schedule.kind) {
            RoutineSchedule.Kind.INTERVAL -> "每 ${schedule.everyMinutes ?: 0} 分钟"
            RoutineSchedule.Kind.DAILY -> "每天 ${schedule.time ?: "—"}"
            RoutineSchedule.Kind.WEEKLY -> {
                val weekdays = listOf("周日", "周一", "周二", "周三", "周四", "周五", "周六")
                val days = schedule.weekdays.orEmpty().joinToString("、") { weekdays.getOrNull(it - 1) ?: "第 ${it} 天" }
                "每周 ${days.ifEmpty { "—" }} ${schedule.time.orEmpty()}"
            }
            RoutineSchedule.Kind.CRON -> "cron ${schedule.expr ?: "—"}"
        }
        return BotRoutineInfo(
            id = row.id, title = row.title, schedule = description, timeZone = schedule.timezone,
            delivery = row.delivery.rawValue, quiet = row.delivery.rawValue == "held",
            urgent = row.urgent, urgentReason = row.urgentReason, enabled = row.enabled,
            lastResult = row.lastResult?.let { it.text.ifBlank { it.error ?: it.status.rawValue } } ?: "还没有运行结果。",
            creator = row.creator?.authorization?.rawValue, completionCriteria = row.completionCriteria,
            routineConstraints = row.constraints, runStatus = row.runState?.status?.rawValue, runID = row.runState?.runId,
            nextDue = row.nextRunAt, quietDeferredFrom = row.quietDefer?.scheduledFor, quietDeferredUntil = row.quietDefer?.until,
            lastResultDetail = row.lastResult?.error,
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
                if (event.type == "approval.requested") summaries[approval] = text("action") ?: text("detail").orEmpty()
                if (event.type == "approval.decided") records += BotApprovalRecord(approval, summaries[approval].orEmpty(),
                    text("decision") ?: text("status").orEmpty(), event.time)
            }
            if (page.size < 256) return records.asReversed()
            after = page.last().sequence
        }
    }
}

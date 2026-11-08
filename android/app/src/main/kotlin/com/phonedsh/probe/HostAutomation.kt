// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.*
import com.phonedsh.ui.page.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant

/** Native scheduling uses the Worker's existing scheduler, like iOS. */
internal class HostAutomation(
    private val call: suspend (String, JsonObject) -> JsonValue,
    private val sessionID: () -> String?,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val lock = Mutex()
    private var records: Map<String, JsonObject> = emptyMap()
    private val mutable = MutableStateFlow(AutomationFacts())
    val facts: StateFlow<AutomationFacts> = mutable.asStateFlow()

    fun refresh() = launch { refreshNow() }

    private suspend fun refreshNow(): List<AutomationSchedule> {
        val value = call("schedule/catalog", JsonObject(emptyMap()))
        val rows = (value as? JsonArray)?.values
            ?: ((value as? JsonObject)?.get("records") as? JsonArray)?.values
            ?: ((value as? JsonObject)?.get("schedules") as? JsonArray)?.values
            ?: error("schedule catalog has no records")
        records = rows.mapNotNull { raw -> (raw as? JsonObject)?.let { row -> row.text("id")?.let { it to row } } }.toMap()
        val schedules = records.values.mapNotNull(::automationScheduleOf)
        mutable.update { it.copy(snapshot = AutomationSnapshot(schedules, it.snapshot?.history),
            failure = null, writable = FactState.YES, currentSessionID = sessionID()) }
        return schedules
    }

    fun save(draft: AutomationScheduleDraft, requestID: String) = launch(requestID) {
        val old = draft.id?.let { records[it] ?: error("schedule no longer exists") }
        val content = linkedMapOf<String, JsonValue>(
            "title" to JsonString(draft.title.trim()), "prompt" to JsonString(draft.prompt.trim()),
        )
        val savedID = if (old == null) {
            val session = sessionID() ?: error("no active session")
            val request = content + ("sessionId" to JsonString(session)) +
                automationTimingRequest(draft, editing = false).members.filterKeys { it != "kind" }
            val created = call("phone/createSchedule", args(request)) as? JsonObject
            created?.text("id") ?: error("create returned no schedule id")
        } else {
            val id = requireNotNull(draft.id)
            if (draft.changeTiming) content["timing"] = automationTimingRequest(draft, editing = true)
            val updated = call("schedule/edit", args(mapOf(
                "id" to JsonString(id), "action" to JsonString("update"),
                "expectedUpdatedAt" to (old["updatedAt"] ?: JsonNull), "patch" to JsonObject(content),
            ))) as? JsonObject
            check(updated?.text("id") == id && updated["code"] == null) { "schedule revision changed" }
            id
        }
        val refreshed = try {
            refreshNow()
        } catch (_: Exception) {
            mutable.update { it.copy(
                failure = "保存请求已返回，但定时任务目录暂时无法读取；请刷新确认结果。",
                writeReceipt = AutomationWriteReceipt(requestID, failure = "保存结果待核实，请刷新目录。"),
            ) }
            return@launch
        }
        val saved = refreshed.firstOrNull { it.id == savedID }
        if (saved == null) {
            mutable.update { it.copy(
                failure = "保存请求已返回，但目录没有显示新记录；请刷新确认结果。",
                writeReceipt = AutomationWriteReceipt(requestID, failure = "保存结果待核实，请刷新目录。"),
            ) }
            return@launch
        }
        mutable.update { it.copy(writeReceipt = AutomationWriteReceipt(requestID, savedSchedule = saved)) }
    }

    fun delete(id: String) = launch {
        check(id in records) { "schedule no longer exists" }
        val deleted = call("schedule/edit", args(mapOf(
            "id" to JsonString(id), "action" to JsonString("delete"),
        ))) as? JsonObject
        check((deleted?.get("deleted") as? JsonBool)?.value == true) { "schedule delete failed" }
        val refreshed = try {
            refreshNow()
        } catch (_: Exception) {
            mutable.update { it.copy(failure = "删除请求已返回，但目录暂时无法读取；请刷新确认结果。") }
            return@launch
        }
        if (refreshed.any { it.id == id }) {
            mutable.update { it.copy(failure = "删除请求已返回，但该任务仍在目录中；请刷新后重试。") }
        }
    }

    fun history(id: String, before: String? = null) = launch {
        check(id in records) { "schedule no longer exists" }
        val request = linkedMapOf<String, JsonValue>("id" to JsonString(id), "limit" to JsonNumber("50"))
        before?.let { request["before"] = JsonString(it) }
        val result = call("schedule/history", args(request)) as? JsonObject ?: error("history missing")
        val deliveries = (result["records"] as? JsonArray)?.values.orEmpty().mapNotNull { raw ->
            val record = raw as? JsonObject ?: return@mapNotNull null
            AutomationDelivery(record.text("messageId") ?: return@mapNotNull null,
                record.text("deliveredAt").orEmpty(), record.text("scheduledAt").orEmpty(), record.text("prompt"))
        }
        val next = result.text("nextBefore")
        mutable.update { facts ->
            val existing = facts.snapshot?.history?.takeIf { before != null && it.scheduleId == id }?.deliveries.orEmpty()
            facts.copy(snapshot = (facts.snapshot ?: AutomationSnapshot()).copy(history = AutomationHistory(
                scheduleId = id, deliveries = (existing + deliveries).distinctBy { it.id }, hasMore = next != null, before = next,
                notice = if ((result["earlierRecordsUnavailable"] as? JsonBool)?.value == true) "更早的投递记录不可用。" else null,
            )))
        }
    }

    private fun launch(requestID: String? = null, work: suspend () -> Unit) {
        scope.launch(ioDispatcher) {
            lock.withLock {
                try { work() } catch (cancelled: CancellationException) { throw cancelled
                } catch (failure: Exception) {
                    mutable.update { it.copy(failure = "定时任务操作没有完成，请刷新后重试。",
                        writeReceipt = requestID?.let { id -> AutomationWriteReceipt(id, failure = "没有保存成功，请检查计划后重试。") }
                            ?: it.writeReceipt,
                        currentSessionID = sessionID()) }
                }
            }
        }
    }

    private fun args(request: Map<String, JsonValue>) = JsonObject(mapOf("request" to JsonObject(request)))
}

internal fun automationScheduleOf(row: JsonObject): AutomationSchedule? {
    val id = row.text("id") ?: return null
    val rule = AutomationRule.fromWire(row.text("kind")) ?: return null
    val days = (row["weekdays"] as? JsonArray)?.values?.joinToString(",") { (it as? JsonNumber)?.raw.orEmpty() }
    val timing = AutomationTiming(rule, row.numberText("afterSeconds"), row.text("scheduledAt"),
        row.numberText("everySeconds"), row.text("time"), row.text("timeZone"), days, row.text("expression"))
    return AutomationSchedule(id, row.text("title") ?: "提醒", row.text("prompt"),
        status = when (row.text("status")) { "active" -> ScheduleStatus.ACTIVE; "paused", "ended" -> ScheduleStatus.STOPPED; else -> ScheduleStatus.UNKNOWN },
        rule = rule.optionLabel, nextRun = row.text("scheduledAt"),
        latestDelivery = (row["lastDelivery"] as? JsonObject)?.text("deliveredAt"), timing = timing)
}

internal fun automationTimingRequest(draft: AutomationScheduleDraft, editing: Boolean, now: Instant = Instant.now()): JsonObject {
    val kind = if (editing && draft.rule == AutomationRule.AFTER) "at" else draft.rule.wire
    val map = linkedMapOf<String, JsonValue>("kind" to JsonString(kind))
    when (draft.rule) {
        AutomationRule.AFTER -> if (editing) map["at"] = JsonString(now.plusSeconds(draft.afterSeconds.trim().toLong()).toString())
            else map["after_seconds"] = JsonNumber(draft.afterSeconds.trim())
        AutomationRule.AT -> map["at"] = JsonString(draft.at.trim())
        AutomationRule.EVERY -> map["every_seconds"] = JsonNumber(draft.everySeconds.trim())
        AutomationRule.DAILY, AutomationRule.WEEKLY -> map[draft.rule.wire] = JsonObject(linkedMapOf<String, JsonValue>(
            "time" to JsonString(draft.localTime.trim()), "time_zone" to JsonString(draft.timeZone.trim()),
        ).apply { if (draft.rule == AutomationRule.WEEKLY) put("weekdays", JsonArray(
            draft.weekdays.split(',').map { it.trim() }.filter { it.isNotEmpty() }.map(::JsonNumber),
        )) })
        AutomationRule.CRON -> map["cron"] = JsonObject(mapOf("expression" to JsonString(draft.cron.trim()), "time_zone" to JsonString(draft.timeZone.trim())))
    }
    return JsonObject(map)
}

private fun JsonObject.text(key: String): String? = (this[key] as? JsonString)?.value
private fun JsonObject.numberText(key: String): String? = (this[key] as? JsonNumber)?.raw ?: text(key)

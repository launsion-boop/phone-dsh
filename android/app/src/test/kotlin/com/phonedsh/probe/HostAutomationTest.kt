// The native scheduler calls the Worker's existing schedule API.
// SPDX-License-Identifier: MIT

package com.phonedsh.probe

import com.phonedsh.agentcore.*
import com.phonedsh.ui.page.AutomationRule
import com.phonedsh.ui.page.AutomationScheduleDraft
import com.phonedsh.ui.page.FactState
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostAutomationTest {
    @Test
    fun `timing payloads match the iOS create and update shapes`() {
        val createAfter = automationTimingRequest(
            AutomationScheduleDraft(rule = AutomationRule.AFTER, afterSeconds = "600"),
            editing = false,
        )
        assertEquals(
            JsonValue.parse("""{"kind":"after","after_seconds":600}"""),
            createAfter,
        )

        val updateAfter = automationTimingRequest(
            AutomationScheduleDraft(rule = AutomationRule.AFTER, afterSeconds = "60"),
            editing = true,
            now = Instant.parse("2026-11-02T00:00:00Z"),
        )
        assertEquals(
            JsonValue.parse("""{"kind":"at","at":"2026-11-02T00:01:00Z"}"""),
            updateAfter,
        )

        val weekly = automationTimingRequest(
            AutomationScheduleDraft(
                rule = AutomationRule.WEEKLY,
                localTime = "09:00:00",
                timeZone = "Asia/Taipei",
                weekdays = "1, 2,,",
            ),
            editing = false,
        )
        assertEquals(
            JsonValue.parse(
                """{"kind":"weekly","weekly":{"time":"09:00:00","time_zone":"Asia/Taipei","weekdays":[1,2]}}""",
            ),
            weekly,
        )

        val cron = automationTimingRequest(
            AutomationScheduleDraft(rule = AutomationRule.CRON, cron = "0 9 * * 1-5", timeZone = "Etc/UTC"),
            editing = false,
        )
        assertEquals(
            JsonValue.parse(
                """{"kind":"cron","cron":{"expression":"0 9 * * 1-5","time_zone":"Etc/UTC"}}""",
            ),
            cron,
        )
    }

    @Test
    fun `create waits for the catalog reread before emitting a schedule receipt`() {
        val calls = mutableListOf<Pair<String, JsonObject>>()
        var catalog = emptyList<JsonValue>()
        val call: suspend (String, JsonObject) -> JsonValue = { endpoint, args ->
            calls += endpoint to args
            when (endpoint) {
                "phone/createSchedule" -> {
                    val request = args.objectMember("request")
                    val record = scheduleRecord(
                        id = "schedule-1",
                        sessionID = request.text("sessionId")!!,
                        title = request.text("title")!!,
                        prompt = request.text("prompt")!!,
                        kind = "after",
                        afterSeconds = request.numberText("after_seconds")!!,
                    )
                    catalog = listOf(record)
                    JsonObject(mapOf("id" to JsonString("schedule-1")))
                }
                "schedule/catalog" -> JsonArray(catalog)
                else -> error("unexpected endpoint $endpoint")
            }
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val host = HostAutomation(call, { "worker-session" }, scope, Dispatchers.Unconfined)

        host.save(
            AutomationScheduleDraft(title = "周报", prompt = "总结这一周", afterSeconds = "600"),
            requestID = "request-1",
        )

        assertEquals(listOf("phone/createSchedule", "schedule/catalog"), calls.map { it.first })
        val request = calls.first().second.objectMember("request")
        assertEquals("worker-session", request.text("sessionId"))
        assertEquals(600L, (request["after_seconds"] as JsonNumber).asLongOrNull())
        assertFalse("create payload flattens the rule fields like iOS", "kind" in request.members)
        val receipt = requireNotNull(host.facts.value.writeReceipt)
        assertEquals("request-1", receipt.requestID)
        assertEquals("schedule-1", receipt.savedSchedule?.id)
        assertNull(receipt.failure)
        assertEquals(FactState.YES, host.facts.value.writable)
    }

    @Test
    fun `update carries the previous expected record and a conflict never returns success`() {
        val original = scheduleRecord(
            id = "schedule-1",
            sessionID = "worker-session",
            title = "old title",
            prompt = "old prompt",
            kind = "daily",
            time = "09:00:00",
            timeZone = "Asia/Taipei",
        )
        val calls = mutableListOf<Pair<String, JsonObject>>()
        val call: suspend (String, JsonObject) -> JsonValue = { endpoint, args ->
            calls += endpoint to args
            when (endpoint) {
                "schedule/catalog" -> JsonArray(listOf(original))
                "schedule/update" -> JsonObject(mapOf("updated" to JsonBool(false)))
                else -> error("unexpected endpoint $endpoint")
            }
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val host = HostAutomation(call, { "worker-session" }, scope, Dispatchers.Unconfined)
        host.refresh()
        val draft = AutomationScheduleDraft(
            id = "schedule-1",
            title = "new title",
            prompt = "new prompt",
            changeTiming = false,
            rule = AutomationRule.DAILY,
            timeZone = "Asia/Taipei",
        )

        host.save(draft, requestID = "request-2")

        val update = calls.single { it.first == "schedule/update" }.second.objectMember("request")
        assertEquals("schedule-1", update.text("id"))
        assertEquals(
            JsonObject(original.members.filterKeys {
                it in setOf("id", "kind", "title", "prompt", "scheduledAt", "time", "timeZone")
            }),
            update.objectMember("expected"),
        )
        assertFalse("unchanged timing is omitted", "change" in update.members)
        val facts = host.facts.value
        assertEquals("old title", facts.snapshot?.schedules?.single()?.title)
        val receipt = requireNotNull(facts.writeReceipt)
        assertEquals("request-2", receipt.requestID)
        assertNull(receipt.savedSchedule)
        assertNotNull(receipt.failure)
    }

    @Test
    fun `history passes its opaque before cursor and preserves the worker cursor`() {
        val record = scheduleRecord("schedule-1", "worker-session", "Week", "Summary", "weekly")
        val calls = mutableListOf<Pair<String, JsonObject>>()
        val call: suspend (String, JsonObject) -> JsonValue = { endpoint, args ->
            calls += endpoint to args
            when (endpoint) {
                "schedule/catalog" -> JsonArray(listOf(record))
                "schedule/history" -> JsonObject(
                    mapOf(
                        "records" to JsonArray(
                            listOf(
                                JsonObject(
                                    mapOf(
                                        "messageId" to JsonString("delivery-1"),
                                        "scheduledAt" to JsonString("2026-11-01T09:00:00Z"),
                                        "deliveredAt" to JsonString("2026-11-01T09:00:01Z"),
                                    ),
                                ),
                            ),
                        ),
                        "nextBefore" to JsonString("opaque-next"),
                    ),
                )
                else -> error("unexpected endpoint $endpoint")
            }
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val host = HostAutomation(call, { "worker-session" }, scope, Dispatchers.Unconfined)
        host.refresh()

        host.history("schedule-1", before = "opaque-before")

        val request = calls.single { it.first == "schedule/history" }.second.objectMember("request")
        assertEquals("opaque-before", request.text("before"))
        val history = requireNotNull(host.facts.value.snapshot?.history)
        assertEquals("opaque-next", history.before)
        assertTrue(history.hasMore)
        assertEquals("delivery-1", history.deliveries?.single()?.id)
    }

    private fun scheduleRecord(
        id: String,
        sessionID: String,
        title: String,
        prompt: String,
        kind: String,
        afterSeconds: String? = null,
        time: String? = null,
        timeZone: String? = null,
    ): JsonObject = JsonObject(
        linkedMapOf<String, JsonValue>(
            "id" to JsonString(id),
            "sessionId" to JsonString(sessionID),
            "kind" to JsonString(kind),
            "title" to JsonString(title),
            "prompt" to JsonString(prompt),
            "scheduledAt" to JsonString("2026-11-02T09:00:00Z"),
            "status" to JsonString("active"),
        ).apply {
            afterSeconds?.let { put("afterSeconds", JsonNumber(it)) }
            time?.let { put("time", JsonString(it)) }
            timeZone?.let { put("timeZone", JsonString(it)) }
        },
    )

    private fun JsonObject.objectMember(key: String): JsonObject = this[key] as? JsonObject
        ?: error("missing object member $key")

    private fun JsonObject.text(key: String): String? = (this[key] as? JsonString)?.value

    private fun JsonObject.numberText(key: String): String? = (this[key] as? JsonNumber)?.raw
}

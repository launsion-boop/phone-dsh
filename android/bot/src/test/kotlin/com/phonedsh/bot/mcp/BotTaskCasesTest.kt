// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.session.BotSessionKind
import com.phonedsh.bot.wake.BotTurnOrigin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Conformance for `spec/bot/v1/golden/task-cases.phone.json`.
 *
 * The lifecycle cases drive the real `BotMCPToolRuntime` tool layer and the
 * real [BotDSHRemoteRuntime] over [FakeBotTaskTransport]; restore cases seed
 * the real SQLite P25 log with the fixture's `persistedTask` snapshot. No
 * expected record is copied into the test.
 */
class BotTaskCasesTest {
    private fun fixture(): JsonObject = GoldenFixture.rawObject("task-cases.phone")

    private fun list(root: JsonObject, key: String): List<JsonObject> =
        (root.members[key] as? JsonArray)?.values?.mapNotNull { it as? JsonObject }
            ?: emptyList()

    private fun text(value: JsonObject, key: String): String? =
        (value.members[key] as? JsonString)?.value

    private fun bool(value: JsonObject, key: String): Boolean =
        (value.members[key] as? JsonBool)?.value == true

    private fun number(value: JsonObject, key: String): Long? =
        (value.members[key] as? JsonNumber)?.asLongOrNull()

    private fun objectValue(value: JsonValue?): JsonObject =
        value as? JsonObject ?: JsonObject(emptyMap())

    private fun waitUntil(condition: () -> Boolean) {
        runBlocking {
            withTimeout(3_000) {
                while (!condition()) delay(5)
            }
        }
    }

    private fun runLifecycle(caseSpec: JsonObject) {
        val name = text(caseSpec, "name") ?: "?"
        val setup = (caseSpec.members["setup"] as? JsonObject)
        val parentSession = setup?.let { text(it, "parentSessionId") } ?: "gb-main"
        val parentKind = setup?.let { text(it, "parentKind") } ?: "chat"
        val setupKind = BotSessionKind.fromWire(parentKind)
        TaskToolHarness.open().use { harness ->
            taskHarnessScripts(harness.transport, setup)
            setup?.let { spec ->
                for (session in (spec.members["pause"] as? JsonArray)?.values
                    ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
                ) {
                    harness.transport.pause(session)
                }
            }
            val parent = taskCaller(parentSession, setupKind)
            var started: BotTaskRecord? = null
            (setup?.members?.get("start") as? JsonObject)?.let { start ->
                started = runBlocking {
                    harness.remote.start(
                        BotTaskRequest(
                            parent = parent,
                            title = text(start, "taskTitle") ?: "task",
                            prompt = text(start, "prompt") ?: "work",
                            asynchronous = bool(start, "async"),
                            timeoutMs = number(start, "timeoutMs")?.toInt() ?: 30_000,
                        ),
                    )
                }
                val record = started!!
                waitUntil {
                    harness.transport.prompts.any { it.sessionId == record.sessionId }
                }
            }
            setup?.let { spec ->
                for (session in (spec.members["resume"] as? JsonArray)?.values
                    ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
                ) {
                    harness.transport.resume(session)
                }
            }

            val kind = text(caseSpec, "kind") ?: "start"
            val arguments = caseSpec.members["arguments"] ?: JsonObject(emptyMap())
            val expect = objectValue(caseSpec.members["expect"])
            val tool = when (kind) {
                "start" -> "Task"
                "await" -> "AwaitTask"
                else -> "StopSubagent"
            }
            val substituted = if (started == null) {
                arguments
            } else {
                substituteTask(arguments, started!!.taskId, started!!.sessionId)
            }
            var result = runBlocking {
                harness.execute(tool, substituted, taskPrincipal(parentSession, setupKind))
            }
            assertNotEquals("$name: ${result.text()}", true, result.isError)
            val fields = result.structuredContent as JsonObject
            val taskID = text(fields, "task_id") ?: started?.taskId ?: ""
            val sessionID = text(fields, "sessionId") ?: started?.sessionId ?: ""
            val expectedRecord = substituteTask(
                expect.members["record"] ?: JsonObject(emptyMap()),
                taskID,
                sessionID,
            ) as JsonObject
            val actualRecord = JsonObject(fields.members.filterKeys { it != "authorization" })
            assertEquals("$name: task record", expectedRecord, actualRecord)

            (expect.members["authorization"] as? JsonObject)?.let { authorization ->
                val actual = fields.members["authorization"] as? JsonObject
                    ?: throw AssertionError("$name: missing authorization")
                assertFalse(
                    "$name: auth write",
                    (actual.members["canWriteOutsideWorkspace"] as JsonBool).value,
                )
                assertFalse(
                    "$name: auth network",
                    (actual.members["canNetworkWrite"] as JsonBool).value,
                )
                assertFalse(
                    "$name: auth delegate",
                    (actual.members["canDelegateTasks"] as JsonBool).value,
                )
                val root = (actual.members["workspaceRoot"] as JsonString).value
                assertTrue(
                    "$name: workspace root $root",
                    root.endsWith(text(authorization, "workspaceRootSuffix") ?: ""),
                )
                assertEquals(
                    "$name: write directories",
                    number(authorization, "allowedWriteDirectoriesCount")?.toInt(),
                    (actual.members["allowedWriteDirectories"] as JsonArray).values.size,
                )
            } ?: assertNull("$name: StopSubagent has no authorization", fields.members["authorization"])

            if (text(expect, "text") == "@canonicalJSON@") {
                assertEquals(
                    "$name: canonical JSON text",
                    result.structuredContent,
                    JsonValue.parse(result.text() ?: ""),
                )
            }

            for (request in (expect.members["requestIds"] as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
            ) {
                val expected = request
                    .replace("<taskId>", taskID)
                    .replace("<sessionId>", sessionID)
                if (expected.startsWith("task-settled:")) {
                    waitUntil {
                        harness.transport.prompts.any { it.requestId == expected }
                    }
                }
                assertTrue(
                    "$name: missing request id $expected",
                    harness.transport.prompts.any { it.requestId == expected },
                )
            }
            assertEventOrder(name, caseSpec, harness, taskID, sessionID)
            if (bool(expect, "noResult")) {
                assertNull("$name: stopped record keeps no result", fields.members["result"])
            }
            (text(expect, "cancelledSession"))?.let { session ->
                assertTrue(
                    "$name: stop must cancel $session",
                    harness.transport.cancellations.contains(session),
                )
            }
            if (text(expect, "cleanup") == "stop") {
                val record = started
                if (record != null) {
                    runBlocking {
                        harness.remote.stop(record.taskId, parent)
                    }
                }
            }
        }
    }

    private fun assertEventOrder(
        name: String,
        caseSpec: JsonObject,
        harness: TaskToolHarness,
        taskID: String,
        sessionID: String,
    ) {
        val expect = objectValue(caseSpec.members["expect"])
        val order = (expect.members["eventOrder"] as? JsonArray)?.values
            ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
        val events = harness.sqlite.store.events(0, 1_000).filter { it.type.startsWith("task.") }
        var index = 0
        for (event in events) {
            if (index < order.size && event.type == order[index]) index += 1
        }
        assertEquals("$name: task event order", order.size, index)
        for (event in events) {
            if (event.type == "task.started" || event.type == "task.settled") {
                assertFalse(
                    "$name: ${event.type} must carry only record fields",
                    (event.data as JsonObject).members.containsKey("authorization"),
                )
            }
            if (event.type == "task.stop_requested") {
                assertFalse(
                    "$name: stop_requested must not use stop:<taskId>",
                    event.eventId.startsWith("stop:"),
                )
            }
        }
        val persisted = expect.members["persistedTask"] as? JsonObject ?: return
        val snapshots = events.mapNotNull {
            (it.data as? JsonObject)?.members?.get("persistedTask") as? JsonObject
        }
        val latest = snapshots.lastOrNull() ?: throw AssertionError("$name: no persistedTask")
        for ((key, value) in persisted.members) {
            assertEquals(
                "$name: persistedTask.$key",
                substituteTask(value, taskID, sessionID),
                latest.members[key],
            )
        }
    }

    private fun runInvalid(caseSpec: JsonObject) {
        val name = text(caseSpec, "name") ?: "?"
        val setup = caseSpec.members["setup"] as? JsonObject
        val setupSession = setup?.let { text(it, "parentSessionId") } ?: "gb-main"
        val setupKind = BotSessionKind.fromWire(
            setup?.let { text(it, "parentKind") } ?: "chat",
        )
        val executeSession = setup?.let { text(it, "executeSessionId") } ?: setupSession
        TaskToolHarness.open().use { harness ->
            taskHarnessScripts(harness.transport, setup)
            setup?.let { spec ->
                for (session in (spec.members["pause"] as? JsonArray)?.values
                    ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
                ) {
                    harness.transport.pause(session)
                }
            }
            val setupParent = taskCaller(setupSession, setupKind)
            var started: BotTaskRecord? = null
            (setup?.members?.get("start") as? JsonObject)?.let { start ->
                started = runBlocking {
                    harness.remote.start(
                        BotTaskRequest(
                            parent = setupParent,
                            title = text(start, "taskTitle") ?: "task",
                            prompt = text(start, "prompt") ?: "work",
                            asynchronous = bool(start, "async"),
                            timeoutMs = number(start, "timeoutMs")?.toInt() ?: 30_000,
                        ),
                    )
                }
                waitUntil {
                    harness.transport.prompts.any { it.sessionId == started!!.sessionId }
                }
            }
            val kind = text(caseSpec, "kind") ?: "start"
            val tool = when (kind) {
                "start" -> "Task"
                "await" -> "AwaitTask"
                else -> "StopSubagent"
            }
            val arguments = caseSpec.members["arguments"] ?: JsonObject(emptyMap())
            val substituted = started?.let {
                substituteTask(arguments, it.taskId, it.sessionId)
            } ?: arguments
            val result = runBlocking {
                harness.execute(
                    tool,
                    substituted,
                    taskPrincipal(executeSession, setupKind),
                )
            }
            assertTrue("$name: expected failure", result.isError)
            val expected = objectValue(objectValue(caseSpec.members["expect"]).members["structured"])
            val expectedError = objectValue(expected.members["error"])
            assertEquals("$name: code", text(expectedError, "code"), MCPTestSupport.errorCode(result))
            assertEquals(
                "$name: message",
                text(expectedError, "message"),
                MCPTestSupport.errorMessage(result),
            )
            if (text(objectValue(caseSpec.members["expect"]), "cleanup") == "stop") {
                val record = started
                if (record != null) {
                    runBlocking { harness.remote.stop(record.taskId, setupParent) }
                }
            }
        }
    }

    @Test
    fun validTaskCases() {
        for (caseSpec in list(fixture(), "valid")) {
            when (text(caseSpec, "kind")) {
                "start", "await", "stop" -> runLifecycle(caseSpec)
                else -> throw AssertionError("unknown task case kind")
            }
        }
    }

    @Test
    fun invalidTaskCases() {
        for (caseSpec in list(fixture(), "invalid")) {
            runInvalid(caseSpec)
        }
    }

    @Test
    fun restoreCases() {
        for (caseSpec in list(fixture(), "restoreCases")) {
            runRestore(caseSpec)
        }
    }

    private fun runRestore(caseSpec: JsonObject) {
        val name = text(caseSpec, "name") ?: "?"
        TaskToolHarness.open().use { harness ->
            for (event in list(caseSpec, "seedEvents")) {
                seedTaskEvent(
                    store = harness.sqlite.store,
                    type = text(event, "type") ?: "task.updated",
                    eventId = text(event, "eventId") ?: "seed-${event.hashCode()}",
                    principalSessionId = text(event, "principalSessionId") ?: "gb-main",
                    principalKind = text(event, "principalKind") ?: "chat",
                    data = event.members["data"] ?: JsonObject(emptyMap()),
                )
            }
            val wakeScripts = caseSpec.members["wakeScripts"] as? JsonObject
            if (wakeScripts != null) {
                for ((sessionId, groupsValue) in wakeScripts.members) {
                    val groups = (groupsValue as? JsonArray)?.values ?: continue
                    val first = (groups.firstOrNull() as? JsonArray)?.values ?: continue
                    harness.transport.scriptGroup(sessionId, first)
                }
            }
            val expect = objectValue(caseSpec.members["expect"])
            val recordSpec = objectValue(expect.members["record"])
            val parent = taskCaller("gb-main")
            val status = text(expect, "status")
            if (status != null) {
                val taskId = text(recordSpec, "task_id") ?: ""
                val sessionId = text(recordSpec, "sessionId") ?: ""
                val record = runBlocking {
                    harness.remote.await(taskId, 50, parent)
                }
                assertEquals("$name: restored status", status, record.status)
                val expectedRecord = substituteTask(recordSpec, taskId, sessionId)
                assertEquals("$name: restored record", expectedRecord, record.toJson())
            } else {
                val code = text(expect, "errorCode")
                if (code != null) {
                    val error = runCatching {
                        runBlocking {
                            harness.remote.await("task-legacy", 50, parent)
                        }
                    }.exceptionOrNull()
                    assertTrue(
                        "$name: legacy record must not restore",
                        error is BotMCPToolException,
                    )
                    assertEquals(
                        "$name: legacy message",
                        text(expect, "errorMessage"),
                        (error as BotMCPToolException).message,
                    )
                }
            }
            val wake = objectValue(expect.members["wake"])
            val delivered = runBlocking { harness.remote.deliverInterruptedTaskWakes() }
            assertEquals("$name: wake count", number(wake, "delivered")?.toInt() ?: 0, delivered)
            text(wake, "requestId")?.let { requestId ->
                assertTrue(
                    "$name: wake request id",
                    harness.transport.prompts.any { it.requestId == requestId },
                )
                val prompt = harness.transport.prompts.lastOrNull {
                    it.sessionId == text(wake, "sessionId")
                } ?: throw AssertionError("$name: missing wake prompt")
                for (fragment in (wake.members["promptContains"] as? JsonArray)?.values
                    ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
                ) {
                    assertTrue(
                        "$name: prompt is missing $fragment",
                        prompt.prompt.contains(fragment),
                    )
                }
            }
            val second = runBlocking { harness.remote.deliverInterruptedTaskWakes() }
            assertEquals(
                "$name: second wake",
                number(expect, "secondWake")?.toInt() ?: 0,
                second,
            )
            val events = harness.sqlite.store.events(0, 1_000)
            text(expect, "appendedEventSuffix")?.let { suffix ->
                assertTrue(
                    "$name: missing $suffix",
                    events.any { it.eventId.endsWith(suffix) },
                )
            }
            text(expect, "wakePersistedSuffix")?.let { suffix ->
                assertTrue(
                    "$name: missing $suffix",
                    events.any { it.eventId.endsWith(suffix) },
                )
                val marked = events.lastOrNull {
                    it.type == "task.updated" && it.eventId.endsWith(suffix)
                } ?: throw AssertionError("$name: missing wake marker")
                val snapshot = (marked.data as JsonObject).members["persistedTask"] as JsonObject
                assertEquals(
                    "$name: wakeDelivered",
                    JsonBool(true),
                    snapshot.members["wakeDelivered"],
                )
            }
        }
    }

    @Test
    fun requestIdCases() {
        for (caseSpec in list(fixture(), "requestIdCases")) {
            val name = text(caseSpec, "name") ?: "?"
            val taskId = text(caseSpec, "taskId") ?: ""
            val expected = text(caseSpec, "expected") ?: ""
            val approval = text(caseSpec, "approvalId")
            when (text(caseSpec, "prefix")) {
                "task-turn:" -> if (approval == null) {
                    assertEquals(
                        "$name: helper",
                        expected,
                        BotTurnOrigin.taskTurnRequestId(taskId),
                    )
                }
                "task-settled:" -> if (approval == null) {
                    assertEquals(
                        "$name: helper",
                        expected,
                        BotTurnOrigin.taskSettledRequestId(taskId),
                    )
                }
                "task-interrupted:" -> assertEquals(
                    "$name: helper",
                    expected,
                    BotTurnOrigin.taskInterruptedRequestId(taskId),
                )
                else -> throw AssertionError("$name: unknown prefix")
            }
            if (approval != null) {
                assertTrue("$name: suffix", expected.endsWith(":approval:$approval"))
            }
            val origin = BotTurnOrigin.parse(expected)
            assertEquals("$name: origin", text(caseSpec, "origin"), origin.kind.rawValue)
            assertEquals("$name: hidden", bool(caseSpec, "hidden"), origin.hidden)
            assertEquals(
                "$name: memory",
                text(caseSpec, "memorySource"),
                origin.memorySource.rawValue,
            )
        }
    }

    private fun waitForRecord(
        harness: TaskToolHarness,
        taskId: String,
        status: String,
    ) {
        waitUntil { harness.remote.recordFor(taskId)?.status == status }
    }

    @Test
    fun workerRestartInterruptsLiveTasksAndWakesOnce() {
        TaskToolHarness.open().use { harness ->
            harness.transport.pause("gb-created-1")
            val record = runBlocking {
                harness.remote.start(
                    BotTaskRequest(
                        parent = taskCaller(),
                        title = "Restart audit",
                        prompt = "finish",
                        asynchronous = true,
                        timeoutMs = 30_000,
                    ),
                )
            }
            waitUntil { harness.transport.prompts.any { it.sessionId == record.sessionId } }
            val childPrompt = harness.transport.prompts.first {
                it.sessionId == record.sessionId
            }
            assertEquals("task-turn:${record.taskId}", childPrompt.requestId)
            assertTrue(childPrompt.prompt.startsWith("<task_authorization>"))
            assertTrue(childPrompt.prompt.contains("budget_ms: 30000"))
            assertTrue(childPrompt.prompt.contains("</task_contract>"))
            runBlocking { harness.remote.workerRestarted() }
            val interrupted = harness.remote.recordFor(record.taskId)
                ?: throw AssertionError("restored record missing")
            assertEquals("interrupted", interrupted.status)
            assertEquals("worker_restarted", interrupted.error)
            assertTrue(harness.remote.queuedInterruptedTaskIDs().contains(record.taskId))
            assertEquals(1, runBlocking { harness.remote.deliverInterruptedTaskWakes() })
            val wake = harness.transport.prompts.last {
                it.requestId == "task-interrupted:${record.taskId}"
            }
            assertTrue(wake.prompt.contains("Restart audit"))
            assertTrue(wake.prompt.contains("interrupted"))
            assertEquals(0, runBlocking { harness.remote.deliverInterruptedTaskWakes() })
            assertTrue(
                harness.sqlite.store.events(0, 1_000).any {
                    it.eventId == "persisted:wake:${record.taskId}"
                },
            )
        }
    }

    @Test
    fun stoppingAParkedTaskCancelsTheDurableApproval() {
        TaskToolHarness.open().use { harness ->
            harness.transport.script(
                "gb-created-1",
                listOf(
                    BotTaskTurnResult(
                        sessionId = "",
                        status = "waiting_approval",
                        approvalId = "approval-9",
                        text = "half",
                    ),
                ),
            )
            val record = runBlocking {
                harness.remote.start(
                    BotTaskRequest(
                        parent = taskCaller(),
                        title = "Parked audit",
                        prompt = "work",
                        asynchronous = true,
                        timeoutMs = 30_000,
                    ),
                )
            }
            waitForRecord(harness, record.taskId, "waiting_approval")
            val stopped = runBlocking {
                harness.remote.stop(record.taskId, taskCaller())
            }
            assertEquals("stopped", stopped.status)
            assertEquals("half", stopped.partial)
            assertNull(stopped.result)
            assertTrue(
                harness.transport.cancelledApprovals.contains(
                    "approval-9" to "task_stopped",
                ),
            )
            val events = harness.sqlite.store.events(0, 1_000)
            assertTrue(
                events.any { it.eventId == "persisted:stopped:${record.taskId}" },
            )
            assertTrue(events.any { it.eventId == "settled:${record.taskId}" })
            assertEquals(0, runBlocking { harness.remote.deliverInterruptedTaskWakes() })
        }
    }

    @Test
    fun allowedApprovalResumesTheParkedSession() {
        TaskToolHarness.open().use { harness ->
            harness.transport.script(
                "gb-created-1",
                listOf(
                    BotTaskTurnResult(
                        sessionId = "",
                        status = "waiting_approval",
                        approvalId = "approval-9",
                        text = "half",
                    ),
                    BotTaskTurnResult(
                        sessionId = "",
                        status = "completed",
                        text = "resumed",
                    ),
                ),
            )
            val record = runBlocking {
                harness.remote.start(
                    BotTaskRequest(
                        parent = taskCaller(),
                        title = "Resume audit",
                        prompt = "work",
                        asynchronous = true,
                        timeoutMs = 30_000,
                    ),
                )
            }
            waitForRecord(harness, record.taskId, "waiting_approval")
            harness.transport.setDecision("approval-9", BotTaskApprovalDecision.ALLOWED)
            runBlocking { harness.remote.reconcileWaitingApprovals() }
            waitForRecord(harness, record.taskId, "completed")
            val completed = harness.remote.recordFor(record.taskId)!!
            assertEquals("resumed", completed.result)
            val resume = harness.transport.prompts.last {
                it.requestId == "task-turn:${record.taskId}:approval:approval-9"
            }
            assertTrue(resume.prompt.contains("[approval_resume]"))
            assertTrue(
                harness.sqlite.store.events(0, 1_000).any {
                    it.type == "task.resumed" &&
                        it.eventId == "resumed:${record.taskId}"
                },
            )
        }
    }

    @Test
    fun hostParkTurnsTheTransportErrorIntoInterrupted() {
        TaskToolHarness.open().use { harness ->
            harness.transport.turnError = IllegalStateException("session/follow EOF")
            harness.remote.beginHostPark()
            val record = runBlocking {
                harness.remote.start(
                    BotTaskRequest(
                        parent = taskCaller(),
                        title = "Parked worker",
                        prompt = "work",
                        asynchronous = false,
                        timeoutMs = 30_000,
                    ),
                )
            }
            harness.remote.endHostPark()
            assertEquals("interrupted", record.status)
            assertEquals("worker_restarted", record.error)
            assertTrue(
                harness.sqlite.store.events(0, 1_000).any {
                    it.eventId == "persisted:interrupted:${record.taskId}"
                },
            )
        }
    }

    @Test
    fun startingATaskLeavesHeldItemsPending() {
        com.phonedsh.bot.routines.RoutineTestHarness(
            com.phonedsh.bot.routines.FakeClock(1_000),
        ).use { held ->
            val item = com.phonedsh.bot.wake.WakeInboxItem(
                id = "held-agent-1",
                kind = "agent-held",
                fromAgentId = "bot-b",
                fromAgentName = "Bee",
                title = "FYI",
                text = "pending teammate message",
                requestId = "agent:call-held",
                threadId = "thread-held",
                createdAt = 1_000,
            )
            held.inbox.enqueue(item)
            TaskToolHarness.open().use { harness ->
                runBlocking {
                    harness.remote.start(
                        BotTaskRequest(
                            parent = taskCaller(),
                            title = "Held boundary",
                            prompt = "work",
                            asynchronous = false,
                            timeoutMs = 30_000,
                        ),
                    )
                }
                val items = held.inbox.items()
                assertEquals(listOf("held-agent-1"), items.map { it.id })
                assertEquals(com.phonedsh.bot.wake.WakeInboxState.PENDING, items.single().state)
            }
        }
    }

    @Test
    fun chatEpochSuccessorInheritsReadsButOtherSessionsDoNot() {
        TaskToolHarness.open().use { harness ->
            seedTaskEvent(
                store = harness.sqlite.store,
                type = "runtime.started",
                eventId = "runtime-started-main",
                principalSessionId = "gb-main",
                principalKind = "chat",
                data = JsonObject(
                    mapOf("sessionId" to JsonString("gb-main")),
                ),
            )
            seedTaskEvent(
                store = harness.sqlite.store,
                type = "runtime.started",
                eventId = "runtime-started-main-2",
                principalSessionId = "gb-main-2",
                principalKind = "chat",
                data = JsonObject(
                    mapOf("sessionId" to JsonString("gb-main-2")),
                ),
            )
            seedTaskEvent(
                store = harness.sqlite.store,
                type = "task.created",
                eventId = "created:task-epoch",
                principalSessionId = "gb-main",
                principalKind = "chat",
                data = JsonObject(
                    mapOf(
                        "task_id" to JsonString("task-epoch"),
                        "sessionId" to JsonString("gb-task-epoch"),
                        "status" to JsonString("completed"),
                        "title" to JsonString("Epoch task"),
                        "result" to JsonString("done"),
                        "partial" to JsonString("done"),
                        "persistedTask" to JsonObject(
                            mapOf(
                                "taskId" to JsonString("task-epoch"),
                                "sessionId" to JsonString("gb-task-epoch"),
                                "parentSessionId" to JsonString("gb-main"),
                                "parentBotId" to JsonString("main"),
                                "parentIncarnation" to JsonString("inc-main"),
                                "parentKind" to JsonString("chat"),
                                "title" to JsonString("Epoch task"),
                                "prompt" to JsonString("work"),
                                "asynchronous" to JsonBool(true),
                                "timeoutMs" to JsonNumber("30000"),
                                "status" to JsonString("completed"),
                                "createdAt" to JsonNumber("1000"),
                                "wakeDelivered" to JsonBool(false),
                                "partial" to JsonString("done"),
                                "result" to JsonString("done"),
                                "constraints" to JsonArray(emptyList()),
                            ),
                        ),
                    ),
                ),
            )
            harness.transport.setMainSession("gb-main-2")
            val successor = runBlocking {
                harness.remote.await(
                    "task-epoch",
                    50,
                    taskCaller("gb-main-2"),
                )
            }
            assertEquals("completed", successor.status)
            assertEquals("done", successor.result)
            val foreign = runCatching {
                runBlocking {
                    harness.remote.await("task-epoch", 50, taskCaller("gb-other"))
                }
            }.exceptionOrNull()
            assertTrue(foreign is BotMCPToolException)
            assertEquals("Unauthorized", foreign!!.message)
        }
    }
}

// SPDX-License-Identifier: MIT
package com.phonedsh.bot.team

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.mcp.BotMCPCallResult
import com.phonedsh.bot.mcp.BotMCPToolRuntime
import com.phonedsh.bot.mcp.BotUserMessagePort
import com.phonedsh.bot.mcp.FakeAttribution
import com.phonedsh.bot.mcp.MCPTestSupport
import com.phonedsh.bot.mcp.RecordingEventSink
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRoster
import com.phonedsh.bot.rows.BotAgentCommText
import com.phonedsh.bot.rows.BotTeamAgentCommRecord
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * Conformance for `spec/bot/v1/golden/team-cases.phone.json`.
 *
 * Every case drives the real [BotTeamTools] argument parser, target resolver,
 * delivery loop and row writer through [FakeBotTeamHost]; row identity and
 * `agent.comm` events go through the real [BotTeamAgentCommRecord] and the
 * SQLite P25 log. The expected values are read from the vector, never restated.
 */
class BotTeamCasesTest {
    private fun fixture(): JsonObject = GoldenFixture.rawObject("team-cases.phone")

    private fun objectValue(value: JsonValue?): JsonObject =
        value as? JsonObject ?: JsonObject(emptyMap())

    private fun list(root: JsonObject, key: String): List<JsonObject> =
        (root.members[key] as? JsonArray)?.values?.map(::objectValue) ?: emptyList()

    private fun roster(spec: JsonObject): BotRoster {
        val bots = list(spec, "bots").map { entry ->
            BotProfile(
                id = text(entry, "id") ?: "",
                name = text(entry, "name") ?: "",
                hiddenByUser = (entry.members["hiddenByUser"] as? JsonBool)?.value ?: false,
            )
        }
        return BotRoster(bots = bots, mainBotID = text(spec, "mainBotId"))
    }

    private fun text(value: JsonObject, key: String): String? =
        (value.members[key] as? JsonString)?.value

    private fun number(value: JsonObject, key: String): Long? =
        (value.members[key] as? JsonNumber)?.asLongOrNull()

    private fun arguments(caseSpec: JsonObject): JsonValue {
        if ((caseSpec.members["argumentsNotObject"] as? JsonBool)?.value == true) {
            return JsonString(text(caseSpec, "arguments") ?: "")
        }
        return caseSpec.members["arguments"] ?: JsonObject(emptyMap())
    }

    private fun configure(host: FakeBotTeamHost, caseSpec: JsonObject) {
        val config = objectValue(caseSpec.members["host"])
        (config.members["reply"] as? JsonObject)?.let { reply ->
            host.reply = com.phonedsh.bot.team.BotAgentDeliveryReply(
                text = text(reply, "text") ?: "",
                replyEntryId = text(reply, "replyEntryId"),
            )
        }
        number(config, "deliveryDelayMilliseconds")?.let {
            host.deliveryDelayMilliseconds = it.toInt()
        }
        (config.members["deliveryError"] as? JsonObject)?.let {
            host.deliveryError = hostError(it)
        }
        (config.members["enqueueError"] as? JsonObject)?.let {
            host.enqueueError = hostError(it)
        }
        (config.members["createdProfile"] as? JsonObject)?.let {
            host.createdProfileID = text(it, "id")
        }
    }

    private fun hostError(spec: JsonObject): Throwable = when (text(spec, "case")) {
        "deliveryTimeout" -> BotTeamHostError.DeliveryTimeout
        "deliveryFailed" -> BotTeamHostError.DeliveryFailed(text(spec, "message") ?: "")
        "rejected" -> BotTeamHostError.Rejected(text(spec, "message") ?: "")
        "invalidTarget" -> BotTeamHostError.InvalidTarget(text(spec, "message") ?: "")
        "botNotFound" -> BotTeamHostError.BotNotFound(text(spec, "message") ?: "")
        else -> IllegalStateException(text(spec, "message") ?: "host error")
    }

    private fun runCase(caseSpec: JsonObject, isCreate: Boolean) {
        val name = text(caseSpec, "name") ?: "?"
        SqliteBotStore.open().use { sqlite ->
            val now = number(fixture(), "nowMilliseconds") ?: 1_700_000_000_000L
            val host = FakeBotTeamHost(
                initialRoster = roster(objectValue(fixture().members["roster"])),
                sqlite = sqlite,
                now = { now },
            )
            configure(host, caseSpec)
            (caseSpec.members["context"] as? JsonObject)?.let { context ->
                host.setContext(
                    BotAgentCommContext(
                        depth = number(context, "depth")?.toInt() ?: 0,
                        chain = (context.members["chain"] as? JsonArray)?.values
                            ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList<String>(),
                        turn = number(context, "turn")?.toInt() ?: 0,
                        existingRowIDs = (context.members["existingRowIDs"] as? JsonArray)?.values
                            ?.mapNotNull { (it as? JsonString)?.value }?.toSet() ?: emptySet(),
                    ),
                    forBotID = text(caseSpec, "callerBotId") ?: "bot-a",
                )
            }
            for (seed in list(caseSpec, "seedThreads")) {
                host.seedThread(
                    botID = text(seed, "botID") ?: "",
                    requestID = text(seed, "requestID") ?: "",
                    threadID = text(seed, "threadID") ?: "",
                )
            }
            val toolsSpec = objectValue(caseSpec.members["tools"])
            val tools = BotTeamTools(
                host = host,
                timeoutMilliseconds = number(toolsSpec, "timeoutMilliseconds")?.toInt()
                    ?: BotTeamTools.DEFAULT_TIMEOUT_MILLISECONDS,
                now = { now },
            )
            val principal = botTeamPrincipal(text(caseSpec, "callerBotId") ?: "bot-a")
            val toolName = if (isCreate) {
                BotTeamTools.CREATE_TEAMMATE_NAME
            } else {
                BotTeamTools.SEND_TO_AGENT_NAME
            }
            val callId = text(caseSpec, "callId") ?: "create-1"
            val context = com.phonedsh.bot.mcp.BotToolCallContext(
                runtimeId = "phone-worker",
                callId = callId,
                call = com.phonedsh.bot.mcp.BotResolvedToolCall(principal = principal, callId = callId),
            )
            val first = runBlocking {
                tools.executeWithAuthority(toolName, arguments(caseSpec), principal, context, null)
            }
            var result = first
            if ((caseSpec.members["replay"] as? JsonBool)?.value == true) {
                val second = runBlocking {
                    tools.executeWithAuthority(toolName, arguments(caseSpec), principal, context, null)
                }
                assertEquals(
                    "$name: a replay must reuse the thread",
                    (first.structuredContent as? JsonObject)?.members?.get("threadId"),
                    (second.structuredContent as? JsonObject)?.members?.get("threadId"),
                )
                result = second
            }

            val expect = objectValue(caseSpec.members["expect"])
            val expectedError = (expect.members["isError"] as? JsonBool)?.value == true
            if (expectedError) {
                assertTrue("$name: expected failure", result.isError)
                assertStructured(objectValue(expect.members["structured"]), emptyMap(), result, name)
                assertEquals("$name: failure text", text(expect, "text"), botTeamResultText(result))
            } else {
                assertFalse("$name: ${botTeamResultText(result)}", result.isError)
                val patterns = (expect.members["structuredPatterns"] as? JsonObject)?.members
                    ?.mapNotNull { (key, value) -> (value as? JsonString)?.let { key to it.value } }
                    ?.toMap() ?: emptyMap()
                assertStructured(
                    objectValue(expect.members["structured"]),
                    patterns,
                    result,
                    name,
                )
                var expectedText = text(expect, "text") ?: ""
                if (isCreate) {
                    val args = objectValue(caseSpec.members["arguments"])
                    val description = text(args, "description") ?: ""
                    expectedText = expectedText.replace(
                        "<description>",
                        BotAgentCommText.truncateUtf16(description, 300),
                    )
                }
                assertEquals("$name: success text", expectedText, botTeamResultText(result))
            }

            (expect.members["rowIdentity"] as? JsonObject)?.let { identity ->
                val seq = number(identity, "seq") ?: 0
                val rowID = com.phonedsh.bot.rows.BotAgentCommIdentity.outboundRowID(
                    senderAgentID = text(identity, "sender") ?: "",
                    targetID = text(identity, "target") ?: "",
                    requestID = text(identity, "requestId"),
                    seq = seq,
                )
                assertEquals("$name: outbound row id", text(identity, "rowID"), rowID)
                assertEquals(
                    "$name: thread id",
                    text(identity, "threadId"),
                    com.phonedsh.bot.rows.BotAgentCommIdentity.threadID(rowID, seq),
                )
            }

            val expectedRecords = list(expect, "records")
            assertEquals("$name: row count", expectedRecords.size, host.records.size)
            for ((index, expected) in expectedRecords.withIndex()) {
                assertEquals(
                    "$name[$index]: agent-comm row",
                    expected,
                    host.records[index].toJson(),
                )
                if (host.records[index].direction ==
                    com.phonedsh.bot.rows.BotAgentCommDirection.OUTBOUND
                ) {
                    // Every durable record is also an agent.comm event.
                    assertTrue(
                        "$name[$index]: durable agent.comm",
                        sqlite.store.events(0, 100).any {
                            it.eventId == "agent.comm:${host.records[index].rowID}"
                        },
                    )
                }
            }

            val expectedDeliveries = list(expect, "deliveries")
            assertEquals("$name: delivery count", expectedDeliveries.size, host.delivered.size)
            for ((index, expected) in expectedDeliveries.withIndex()) {
                val actual = host.delivered[index]
                assertEquals("$name: delivery target", text(expected, "targetId"), actual.target.id)
                assertEquals(
                    "$name: delivery target name",
                    text(expected, "targetName"),
                    actual.target.name,
                )
                assertEquals(
                    "$name: delivery prompt",
                    text(expected, "promptText"),
                    actual.promptText,
                )
                assertEquals("$name: delivery message", text(expected, "message"), actual.message)
                assertEquals(
                    "$name: delivery title",
                    text(expected, "title"),
                    actual.title,
                )
                assertEquals(
                    "$name: delivery mode",
                    text(expected, "delivery"),
                    actual.delivery,
                )
                assertEquals("$name: delivery hop", number(expected, "hop")?.toInt(), actual.hop)
                assertEquals(
                    "$name: delivery chain",
                    (expected.members["chain"] as? JsonArray)?.values
                        ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList<String>(),
                    actual.chain,
                )
                assertEquals(
                    "$name: delivery request",
                    text(expected, "requestId"),
                    actual.requestId,
                )
                assertEquals(
                    "$name: delivery thread",
                    text(expected, "threadId"),
                    actual.threadId,
                )
            }

            val expectedHeld = list(expect, "held")
            assertEquals("$name: held count", expectedHeld.size, host.heldRequests.size)
            for ((index, expected) in expectedHeld.withIndex()) {
                val request = host.heldRequests[index]
                assertEquals("$name: held bot", text(expected, "botID"), request.botID)
                val handOff = expected.members["handOff"] as? JsonObject
                if (handOff != null) {
                    assertEquals(
                        "$name: held depth",
                        number(handOff, "depth")?.toInt(),
                        request.handOff?.depth,
                    )
                    assertEquals(
                        "$name: held chain",
                        (handOff.members["chain"] as? JsonArray)?.values
                            ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList<String>(),
                        request.handOff?.chain,
                    )
                } else {
                    assertNull("$name: held handOff must be nil", request.handOff)
                }
                val expectedItem = objectValue(expected.members["item"])
                val actualItem = request.item.toJson()
                val expectedFields = LinkedHashMap(expectedItem.members)
                val actualFields = LinkedHashMap(actualItem.members)
                val actualID = (actualFields.remove("id") as? JsonString)?.value
                expectedFields.remove("id")
                assertEquals("$name: held item", expectedFields, actualFields)
                val pattern = text(expected, "idPattern")
                    ?: throw AssertionError("$name: held idPattern")
                assertTrue(
                    "$name: held id $actualID",
                    actualID != null && Regex(pattern).matches(actualID),
                )
            }

            (expect.members["created"] as? JsonObject)?.let { created ->
                assertEquals("$name: created count", 1, host.created.size)
                val actual = host.created.first()
                assertEquals("$name: created name", text(created, "name"), actual.name)
                assertEquals(
                    "$name: description length",
                    number(created, "descriptionLength")?.toInt(),
                    actual.description.length,
                )
                assertTrue(
                    "$name: description prefix",
                    actual.description.startsWith(text(created, "descriptionPrefix") ?: ""),
                )
                assertEquals(
                    "$name: created color",
                    text(created, "color"),
                    actual.color?.wire,
                )
                assertEquals(
                    "$name: created hairstyle",
                    text(created, "hairstyle"),
                    actual.hairstyle?.wire,
                )
                assertEquals("$name: author audit count", 1, host.createdAuthors.size)
                assertNull("$name: direct tool call has no authority", host.createdAuthors.first())
            }
        }
    }

    private fun assertStructured(
        expected: JsonObject,
        patterns: Map<String, String>,
        result: BotMCPCallResult,
        name: String,
    ) {
        val actual = result.structuredContent as? JsonObject
            ?: throw AssertionError("$name: structuredContent is not an object")
        assertEquals("$name: structured keys", expected.members.keys, actual.members.keys)
        for ((key, expectedValue) in expected.members) {
            val actualValue = actual.members[key]
            val pattern = patterns[key]
            if (pattern != null) {
                val value = (actualValue as? JsonString)?.value
                    ?: throw AssertionError("$name: $key is not a string")
                assertTrue("$name: $key $value", Regex(pattern).matches(value))
            } else {
                assertEquals("$name: structured.$key", expectedValue, actualValue)
            }
        }
    }

    @Test
    fun validTeamCases() {
        for (caseSpec in list(fixture(), "valid")) {
            runCase(caseSpec, isCreate = caseSpec.members["callId"] == null)
        }
    }

    @Test
    fun invalidTeamCases() {
        for (caseSpec in list(fixture(), "invalid")) {
            runCase(caseSpec, isCreate = caseSpec.members["callId"] == null)
        }
    }

    @Test
    fun agentCommRowDirectionsAndEventData() {
        val root = fixture()
        for (caseSpec in list(root, "rowCases")) {
            val name = text(caseSpec, "name") ?: "?"
            val record = BotTeamAgentCommRecord.fromJson(caseSpec.members["record"])
                ?: throw AssertionError("$name: record did not decode")
            assertEquals("$name: eventData", caseSpec.members["eventData"], record.eventData())
            if (record.direction == com.phonedsh.bot.rows.BotAgentCommDirection.OUTBOUND) {
                val seq = (number(root, "nowMilliseconds") ?: 0) * 1_000
                assertEquals(
                    "$name: outbound hash",
                    record.rowID,
                    com.phonedsh.bot.rows.BotAgentCommIdentity.outboundRowID(
                        senderAgentID = record.botID,
                        targetID = record.toAgent?.id ?: "",
                        requestID = record.requestID,
                        seq = seq,
                    ),
                )
                assertEquals(
                    "$name: thread",
                    record.threadID,
                    com.phonedsh.bot.rows.BotAgentCommIdentity.threadID(record.rowID, seq),
                )
            }
        }
    }

    @Test
    fun sendToUserBoundary() {
        val root = fixture()
        val sendToUser = objectValue(root.members["sendToUserCases"])
        for (group in listOf("valid", "invalid")) {
            for (caseSpec in list(sendToUser, group)) {
                runSendToUserCase(caseSpec, group)
            }
        }
    }

    private fun runSendToUserCase(caseSpec: JsonObject, group: String) {
        val name = text(caseSpec, "name") ?: "?"
        val session = objectValue(caseSpec.members["session"])
        val kind = text(session, "kind") ?: "chat"
        val sessionID = "gb-${name}"
        val principal = MCPTestSupport.principal(
            botId = "main",
            sessionId = sessionID,
            kind = kind,
        )
        val attribution = FakeAttribution()
        val events = RecordingEventSink()
        val catalog = MCPTestSupport.catalog()
        val runtime = BotMCPToolRuntime(
            catalogProvider = catalog,
            attribution = attribution,
            userMessages = object : BotUserMessagePort {
                override suspend fun sendToUser(
                    context: com.phonedsh.bot.mcp.BotToolCallContext,
                    message: String,
                ): String = "message-${UUID.randomUUID().toString().lowercase()}"
            },
            events = events,
        )
        if ((session.members["suppressed"] as? JsonBool)?.value == true) {
            val cardArgs = com.phonedsh.bot.BotJson.objectOf(
                "question" to JsonString("pick one"),
                "options" to JsonArray(
                    listOf(
                        com.phonedsh.bot.BotJson.objectOf("label" to JsonString("a")),
                        com.phonedsh.bot.BotJson.objectOf("label" to JsonString("b")),
                    ),
                ),
            )
            attribution.register("card-suppress", "ask_user", cardArgs, principal)
            val cardResult = runBlocking {
                runtime.execute("ask_user", cardArgs, JsonString("card-suppress"))
            }
            assertFalse("$name: suppression card failed: ${cardResult.text()}", cardResult.isError)
            assertTrue("$name: suppression armed", runtime.isTextSuppressed(sessionID))
        }
        val arguments = caseSpec.members["arguments"] ?: JsonObject(emptyMap())
        val callId = "send-to-user-$name"
        attribution.register(
            callId = callId,
            tool = "SendToUser",
            arguments = arguments,
            principal = principal,
            isUserTurn = true,
            hiddenTurn = (session.members["hidden"] as? JsonBool)?.value == true,
        )
        val result = runBlocking {
            runtime.execute("SendToUser", arguments, JsonString(callId))
        }
        val expect = objectValue(caseSpec.members["expect"])
        val expectedError = (expect.members["isError"] as? JsonBool)?.value == true
        if (expectedError) {
            assertTrue("$name: expected failure", result.isError)
            assertEquals(
                "$name: code",
                "invalid_arguments",
                MCPTestSupport.errorCode(result),
            )
            assertEquals("$name: message", text(expect, "text"), botTeamResultText(result))
        } else {
            assertFalse("$name: ${botTeamResultText(result)}", result.isError)
            assertEquals(
                "$name: ok",
                JsonBool(true),
                (result.structuredContent as? JsonObject)?.members?.get("ok"),
            )
            val rowId = ((result.structuredContent as? JsonObject)?.members?.get("rowId")
                as? JsonString)?.value
            assertTrue(
                "$name: rowId",
                rowId != null && Regex("^message-[0-9a-f-]+$").matches(rowId),
            )
            val event = events.events.last { it.type == "ui.send_to_user" }
            val data = event.data as JsonObject
            assertEquals("$name: event text", text(expect, "eventText"), text(data, "text"))
            assertEquals("$name: event role", "assistant", text(data, "role"))
            assertEquals("$name: event id", rowId, text(data, "id"))
        }
    }

    @Test
    fun createTeammateRuntimeAuthority() {
        val args = com.phonedsh.bot.BotJson.objectOf(
            "name" to JsonString("Nova"),
            "description" to JsonString("d"),
        )
        val principal = botTeamPrincipal("bot-a")
        val context = com.phonedsh.bot.mcp.BotToolCallContext(
            runtimeId = "phone-worker",
            callId = "create-authority",
            call = com.phonedsh.bot.mcp.BotResolvedToolCall(
                principal = principal,
                callId = "create-authority",
            ),
        )
        FakeBotTeamHost().let { host ->
            val tools = BotTeamTools(host = host, now = { 1_000L })
            val denied = runBlocking {
                tools.executeWithAuthority(
                    BotTeamTools.CREATE_TEAMMATE_NAME,
                    args,
                    principal,
                    context,
                    botTeamAuthority(isUserTurn = false, approvalId = null),
                )
            }
            assertTrue("non-user creation without approval must fail", denied.isError)
            assertEquals(
                "permission_denied",
                com.phonedsh.bot.mcp.MCPTestSupport.errorCode(denied),
            )
            assertEquals(
                "创建队友需要你在当前回合确认",
                com.phonedsh.bot.mcp.MCPTestSupport.errorMessage(denied),
            )
            assertTrue("no Bot may be created", host.created.isEmpty())

            val confirmed = runBlocking {
                tools.executeWithAuthority(
                    BotTeamTools.CREATE_TEAMMATE_NAME,
                    args,
                    principal,
                    context,
                    botTeamAuthority(isUserTurn = false, approvalId = "approval-1"),
                )
            }
            assertFalse(confirmed.isError)
            val author = host.createdAuthors.single()
                ?: throw AssertionError("confirmed author must be recorded")
            assertEquals(
                BotTeammateAuthor.Authorization.USER_CONFIRMED,
                author.authorization,
            )
            assertEquals("approval-1", author.approvalID)
        }
        FakeBotTeamHost().let { host ->
            val tools = BotTeamTools(host = host, now = { 1_000L })
            val userTurn = runBlocking {
                tools.executeWithAuthority(
                    BotTeamTools.CREATE_TEAMMATE_NAME,
                    args,
                    principal,
                    context,
                    botTeamAuthority(isUserTurn = true),
                )
            }
            assertFalse(userTurn.isError)
            val author = host.createdAuthors.single()
                ?: throw AssertionError("user author must be recorded")
            assertEquals(BotTeammateAuthor.Authorization.USER_TURN, author.authorization)
            assertNull(author.approvalID)
        }
    }

    @Test
    fun idempotencyLookupSurvivesAHostRestart() {
        SqliteBotStore.open().use { sqlite ->
            val now = 1_700_000_000_000L
            val args = com.phonedsh.bot.BotJson.objectOf(
                "agent_id" to JsonString("bot-b"),
                "message" to JsonString("once"),
                "priority" to JsonBool(true),
            )
            val principal = botTeamPrincipal("bot-a")
            val context = com.phonedsh.bot.mcp.BotToolCallContext(
                runtimeId = "phone-worker",
                callId = "call-durable",
                call = com.phonedsh.bot.mcp.BotResolvedToolCall(
                    principal = principal,
                    callId = "call-durable",
                ),
            )
            val firstHost = FakeBotTeamHost(sqlite = sqlite, now = { now })
            val firstTools = BotTeamTools(host = firstHost, now = { now })
            val first = runBlocking {
                firstTools.executeWithAuthority(
                    BotTeamTools.SEND_TO_AGENT_NAME,
                    args,
                    principal,
                    context,
                    null,
                )
            }
            assertFalse(first.isError)
            assertEquals(2, firstHost.records.size)

            // A replacement process has the same durable log but no in-memory
            // thread map. The second call must replay the stored thread.
            val secondHost = FakeBotTeamHost(sqlite = sqlite, now = { now })
            val secondTools = BotTeamTools(host = secondHost, now = { now })
            val second = runBlocking {
                secondTools.executeWithAuthority(
                    BotTeamTools.SEND_TO_AGENT_NAME,
                    args,
                    principal,
                    context,
                    null,
                )
            }
            assertFalse(second.isError)
            val firstStructured = first.structuredContent as JsonObject
            val secondStructured = second.structuredContent as JsonObject
            assertEquals(
                firstStructured.members["threadId"],
                secondStructured.members["threadId"],
            )
            assertEquals(JsonBool(true), secondStructured.members["duplicated"])
            assertTrue("no new row across restart", secondHost.records.isEmpty())
            assertTrue("no delivery across restart", secondHost.delivered.isEmpty())
        }
    }
}

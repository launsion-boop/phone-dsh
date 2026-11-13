// SPDX-License-Identifier: MIT
package com.phonedsh.bot.session

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Drives the real session-lifecycle state machines with
 * `spec/bot/v1/golden/session-lifecycle.phone.json`, read from disk.
 *
 * The vector's `transport` object is the request/response transcript; the
 * [VectorTransport] below only executes it and records the request values the
 * state machine produced. No expected value is copied into Kotlin.
 */
class BotSessionLifecycleGoldenTest {
    private val fixture: JsonObject by lazy {
        GoldenFixture.rawObject("session-lifecycle.phone")
    }

    private fun objectList(value: JsonValue?, vararg path: String): List<JsonObject> =
        GoldenFixture.objects(value, *path).map { it as JsonObject }

    // MARK: - Workspace layout

    @Test
    fun everyWorkspaceVectorUsesTheRealLayoutRules() {
        val valid = objectList(fixture, "valid", "workspace")
        assertTrue("session-lifecycle.valid.workspace must not be empty", valid.isNotEmpty())
        for (vector in valid) {
            val botId = GoldenFixture.requireString(vector, "botId")
            val dataDirectory = GoldenFixture.string(vector, "dataDirectory")
                ?: BotSessionWorkspace.DEFAULT_BOT_DATA_DIRECTORY
            assertEquals("safePathComponent(${botId})",
                GoldenFixture.requireString(vector, "safe"),
                BotSessionWorkspace.safePathComponent(botId))
            assertEquals("botRoot(${botId})",
                GoldenFixture.requireString(vector, "root"),
                BotSessionWorkspace.botRoot(botId, dataDirectory))
        }
        val invalid = objectList(fixture, "invalid", "workspace")
        assertTrue("session-lifecycle.invalid.workspace must not be empty", invalid.isNotEmpty())
        for (vector in invalid) {
            val botId = GoldenFixture.requireString(vector, "botId")
            assertEquals("${GoldenFixture.string(vector, "name")}: safe",
                GoldenFixture.requireString(vector, "safe"),
                BotSessionWorkspace.safePathComponent(botId))
            assertEquals("${GoldenFixture.string(vector, "name")}: root",
                GoldenFixture.requireString(vector, "root"),
                BotSessionWorkspace.botRoot(botId))
        }
        println("session-lifecycle.workspace: ${valid.size} valid / ${invalid.size} invalid")
    }

    // MARK: - Token registry

    @Test
    fun everyTokenRegistryCaseRunsTheRealRegistry() {
        val registryVectors = GoldenFixture.objectValue(fixture, "valid", "tokenRegistry")
        val defaults = GoldenFixture.objectValue(registryVectors, "defaults")
        assertEquals(BotSessionTokenRegistry.DEFAULT_TTL_MILLISECONDS,
            GoldenFixture.requireLong(defaults, "defaultTTLMilliseconds"))
        assertEquals(BotSessionTokenRegistry.DEFAULT_MAXIMUM_TOKENS,
            GoldenFixture.requireLong(defaults, "defaultMaximumTokens").toInt())
        assertEquals(BotSessionTokenRegistry.CHAT_TTL_MILLISECONDS,
            GoldenFixture.requireLong(defaults, "chatTTLMilliseconds"))
        assertEquals(BotSessionTokenRegistry.EPHEMERAL_TTL_MILLISECONDS,
            GoldenFixture.requireLong(defaults, "ephemeralTTLMilliseconds"))

        val cases = objectList(registryVectors, "cases")
        assertTrue("tokenRegistry.cases must not be empty", cases.isNotEmpty())
        for (vector in cases) runTokenCase(vector)
        val invalid = objectList(fixture, "invalid", "tokenRegistry")
        assertTrue("tokenRegistry.invalid must not be empty", invalid.isNotEmpty())
        for (vector in invalid) runInvalidTokenCase(vector)
        println("session-lifecycle.tokenRegistry: ${cases.size} valid / ${invalid.size} invalid")
    }

    private class ClockBox(var value: Long)

    private fun runTokenCase(vector: JsonObject) {
        val label = GoldenFixture.requireString(vector, "name")
        val clock = ClockBox(GoldenFixture.long(vector, "clock") ?: 0L)
        val maximum = GoldenFixture.long(vector, "maximumTokens")?.toInt()
            ?: BotSessionTokenRegistry.DEFAULT_MAXIMUM_TOKENS
        val registry = BotSessionTokenRegistry(now = { clock.value }, maximumTokens = maximum)
        val tokens = ArrayList<BotIssuedSessionToken>()
        for ((index, step) in objectList(vector, "steps").withIndex()) {
            val where = "$label[$index]"
            val expect = GoldenFixture.at(step, "expect")
            when (GoldenFixture.requireString(step, "op")) {
                "setClock" -> clock.value = GoldenFixture.requireLong(step, "clock")
                "issue", "issueSession" -> {
                    val kind = BotSessionKind.fromWire(GoldenFixture.requireString(step, "kind"))
                    val issueSession = GoldenFixture.requireString(step, "op") == "issueSession"
                    val token = try {
                        if (issueSession) {
                            registry.issueSession(
                                botId = GoldenFixture.requireString(step, "botId"),
                                sessionId = GoldenFixture.requireString(step, "sessionId"),
                                kind = kind,
                                capabilities = stringList(step, "capabilities"),
                                expiresAt = GoldenFixture.long(step, "expiresAt"),
                                ttlMilliseconds = GoldenFixture.long(step, "ttlMilliseconds"),
                            )
                        } else {
                            registry.issue(
                                botId = GoldenFixture.requireString(step, "botId"),
                                sessionId = GoldenFixture.requireString(step, "sessionId"),
                                kind = kind,
                                capabilities = stringList(step, "capabilities"),
                                expiresAt = GoldenFixture.long(step, "expiresAt"),
                                ttlMilliseconds = GoldenFixture.long(step, "ttlMilliseconds"),
                            )
                        }
                    } catch (error: BotSessionException) {
                        assertEquals("$where: error", GoldenFixture.string(step, "expectError"), error.code)
                        continue
                    }
                    assertEquals("$where: token index",
                        GoldenFixture.requireLong(expect, "tokenIndex"), tokens.size.toLong())
                    tokens.add(token)
                    assertToken(token, expect, where)
                }
                "lookup" -> {
                    val token = token(tokens, step, where)
                    assertEquals("$where: resolves", resolves(expect),
                        registry.lookup(token.token) != null)
                }
                "lookupRaw" -> assertEquals("$where: resolves", resolves(expect),
                    registry.lookup(GoldenFixture.string(step, "token") ?: "") != null)
                "lookupSession" -> {
                    val principal = registry.lookupSession(
                        GoldenFixture.string(step, "sessionId") ?: "")
                    assertEquals("$where: resolves", resolves(expect), principal != null)
                    val tokenIndex = GoldenFixture.long(expect, "tokenIndex")
                    if (principal != null && tokenIndex != null) {
                        assertEquals("$where: session token",
                            tokens[tokenIndex.toInt()].principal.sessionId, principal.sessionId)
                        assertEquals("$where: incarnation",
                            tokens[tokenIndex.toInt()].principal.incarnation, principal.incarnation)
                    }
                }
                "lookupBearer" -> {
                    val token = token(tokens, step, where)
                    val scheme = GoldenFixture.string(step, "scheme") ?: "Bearer"
                    assertEquals("$where: resolves", resolves(expect),
                        registry.lookupBearer("$scheme ${token.token}") != null)
                }
                "lookupBearerRaw" -> assertEquals("$where: resolves", resolves(expect),
                    registry.lookupBearer(GoldenFixture.string(step, "header") ?: "") != null)
                "rotate", "rotateRaw" -> {
                    val old = if (GoldenFixture.requireString(step, "op") == "rotate") {
                        token(tokens, step, where).token
                    } else {
                        GoldenFixture.string(step, "token") ?: ""
                    }
                    val replacement = try {
                        registry.rotate(
                            old,
                            capabilities = GoldenFixture.at(step, "capabilities")
                                ?.let { stringList(step, "capabilities") },
                            expiresAt = GoldenFixture.long(step, "expiresAt"),
                            ttlMilliseconds = GoldenFixture.long(step, "ttlMilliseconds"),
                        )
                    } catch (error: BotSessionException) {
                        assertEquals("$where: error", GoldenFixture.string(step, "expectError"), error.code)
                        continue
                    }
                    val expectedResolves = GoldenFixture.bool(expect, "resolves") ?: true
                    assertEquals("$where: resolves", expectedResolves, replacement != null)
                    val tokenIndex = GoldenFixture.long(expect, "tokenIndex")
                    if (tokenIndex != null) {
                        assertNotNull("$where: replacement", replacement)
                        assertEquals("$where: token index", tokenIndex, tokens.size.toLong())
                        tokens.add(replacement!!)
                        assertToken(replacement, expect, where)
                        if (GoldenFixture.bool(expect, "sameSession") == true) {
                            assertEquals("$where: same session",
                                tokens[0].principal.sessionId, replacement.principal.sessionId)
                        }
                    }
                }
                "revoke" -> {
                    val token = token(tokens, step, where)
                    assertEquals("$where: removed",
                        GoldenFixture.bool(expect, "removed") ?: false, registry.revoke(token.token))
                }
                "revokeRaw" -> assertEquals("$where: removed",
                    GoldenFixture.bool(expect, "removed") ?: false,
                    registry.revoke(GoldenFixture.string(step, "token") ?: ""))
                "revokeSession" -> assertEquals("$where: removed",
                    GoldenFixture.requireLong(expect, "removed").toInt(),
                    registry.revokeSession(GoldenFixture.string(step, "sessionId") ?: ""))
                "revokeBot" -> assertEquals("$where: removed",
                    GoldenFixture.requireLong(expect, "removed").toInt(),
                    registry.revokeBot(GoldenFixture.string(step, "botId") ?: ""))
                "count" -> {
                    val expectedCount = (expect as? JsonNumber)?.asLongOrNull()
                        ?: GoldenFixture.requireLong(expect, "count")
                    assertEquals("$where: count", expectedCount, registry.count().toLong())
                }
                else -> fail("$where: unknown token op")
            }
        }
    }

    private fun runInvalidTokenCase(vector: JsonObject) {
        val label = GoldenFixture.requireString(vector, "name")
        val clock = ClockBox(GoldenFixture.long(vector, "clock") ?: 0L)
        val registry = BotSessionTokenRegistry(now = { clock.value })
        val expect = GoldenFixture.at(vector, "expect")
        when (GoldenFixture.requireString(vector, "op")) {
            "issue" -> {
                try {
                    registry.issue(
                        botId = GoldenFixture.string(vector, "botId") ?: "",
                        sessionId = GoldenFixture.string(vector, "sessionId") ?: "",
                        kind = BotSessionKind.fromWire(GoldenFixture.requireString(vector, "kind")),
                        capabilities = stringList(vector, "capabilities"),
                        expiresAt = GoldenFixture.long(vector, "expiresAt"),
                        ttlMilliseconds = GoldenFixture.long(vector, "ttlMilliseconds"),
                    )
                    fail("$label: expected ${GoldenFixture.string(vector, "expectError")}")
                } catch (error: BotSessionException) {
                    assertEquals("$label: error", GoldenFixture.string(vector, "expectError"), error.code)
                }
            }
            "lookupRaw" -> assertEquals("$label: resolves", resolves(expect),
                registry.lookup(GoldenFixture.string(vector, "token") ?: "") != null)
            "revokeRaw" -> assertEquals("$label: removed",
                GoldenFixture.bool(expect, "removed") ?: false,
                registry.revoke(GoldenFixture.string(vector, "token") ?: ""))
            "rotateRaw" -> assertEquals("$label: resolves", resolves(expect),
                registry.rotate(GoldenFixture.string(vector, "token") ?: "") != null)
            else -> fail("$label: unknown invalid token op")
        }
    }

    private fun assertToken(token: BotIssuedSessionToken, expect: JsonValue?, label: String) {
        val members = (expect as? JsonObject)?.members ?: emptyMap()
        (members["expiresAt"] as? JsonNumber)?.asLongOrNull()?.let {
            assertEquals("$label: expiresAt", it, token.principal.expiresAt)
        }
        (members["tokenPattern"] as? JsonString)?.value?.let {
            assertTrue("$label: token ${token.token}", matchesRegex(token.token, it))
        }
        (members["incarnationPattern"] as? JsonString)?.value?.let {
            assertTrue("$label: incarnation", matchesRegex(token.principal.incarnation, it))
        }
        val principal = (members["principal"] as? JsonObject)?.members ?: return
        (principal["botId"] as? JsonString)?.value?.let {
            assertEquals("$label: botId", it, token.principal.botId)
        }
        (principal["sessionId"] as? JsonString)?.value?.let {
            assertEquals("$label: sessionId", it, token.principal.sessionId)
        }
        (principal["kind"] as? JsonString)?.value?.let {
            assertEquals("$label: kind", it, token.principal.kind.wire)
        }
        (principal["capabilities"] as? JsonArray)?.values?.let {
            assertEquals("$label: capabilities", it.map { item -> (item as JsonString).value },
                token.principal.capabilities)
        }
    }

    private fun token(
        tokens: List<BotIssuedSessionToken>,
        step: JsonObject,
        label: String,
    ): BotIssuedSessionToken {
        val index = GoldenFixture.requireLong(step, "tokenIndex").toInt()
        return tokens.getOrNull(index) ?: throw AssertionError("$label: no token $index")
    }

    private fun resolves(expect: JsonValue?): Boolean =
        GoldenFixture.bool(expect, "resolves") ?: false

    private fun matchesRegex(value: String, pattern: String): Boolean {
        val raw = if (pattern.startsWith("re:")) pattern.substring(3) else pattern
        return Regex(raw).matches(value)
    }

    private fun stringList(value: JsonObject, key: String): List<String> =
        ((GoldenFixture.at(value, key) as? JsonArray)?.values ?: emptyList())
            .map { (it as JsonString).value }

    // MARK: - Session transcripts

    @Test
    fun everySessionTranscriptRunsTheRealStateMachine() {
        val valid = objectList(fixture, "valid", "sessions")
        assertTrue("session-lifecycle.valid.sessions must not be empty", valid.isNotEmpty())
        for (vector in valid) runSessionCase(vector, expectError = false)
        val invalid = objectList(fixture, "invalid", "sessions")
        assertTrue("session-lifecycle.invalid.sessions must not be empty", invalid.isNotEmpty())
        for (vector in invalid) runSessionCase(vector, expectError = true)
        println("session-lifecycle.sessions: ${valid.size} valid / ${invalid.size} invalid")
    }

    private fun runSessionCase(vector: JsonObject, expectError: Boolean) {
        val label = GoldenFixture.requireString(vector, "name")
        val transport = VectorTransport(GoldenFixture.objectValue(vector, "transport"))
        val seeds = objectList(vector, "seedEvents").mapIndexed { index, seed ->
            val principal = GoldenFixture.objectValue(seed, "principal")
            BotSessionStoredEvent(
                type = GoldenFixture.requireString(seed, "type"),
                principal = BotSessionPrincipal(
                    botId = GoldenFixture.string(principal, "botId") ?: "main",
                    sessionId = GoldenFixture.string(principal, "sessionId") ?: "",
                    kind = BotSessionKind.fromWire(
                        GoldenFixture.string(principal, "kind") ?: "chat"),
                    capabilities = emptyList(),
                    expiresAt = 1_000_000,
                    incarnation = "seed" + index.toString().padStart(28, '0'),
                ),
                data = (GoldenFixture.at(seed, "data") as? JsonObject)?.members ?: emptyMap(),
                eventId = "seed-$index",
                time = 1,
                commitSeq = index.toLong() + 1,
            )
        }
        val runtime = BotSessionRuntime(
            transport = transport,
            seedEvents = seeds,
            retryDelayMillis = 0,
            now = { 2_000 },
        )
        val liveFrames = ArrayList<Map<String, String>>()
        runtime.subscribeLiveFrames { frame ->
            val row = LinkedHashMap<String, String>()
            when (frame) {
                BotSessionLiveFrame.StreamStart -> row["kind"] = "streamStart"
                is BotSessionLiveFrame.TextDelta -> {
                    row["kind"] = "textDelta"
                    row["text"] = frame.text
                }
                is BotSessionLiveFrame.Event -> {
                    row["kind"] = "event"
                    row["type"] = frame.type
                }
            }
            synchronized(liveFrames) { liveFrames.add(row) }
        }

        var resultString: String? = null
        var eraseResult: Pair<String, String>? = null
        val results = ArrayList<BotSessionTurnResult>()
        var thrown: Throwable? = null
        try {
            when (GoldenFixture.requireString(vector, "action")) {
                "startMainSession" -> resultString = runtime.startMainSession()
                "sendUserMessage" -> results.add(runtime.sendUserMessage(
                    GoldenFixture.string(vector, "text") ?: ""))
                "sendHiddenInteraction" -> results.add(runtime.sendHiddenInteraction(
                    GoldenFixture.string(vector, "text") ?: "",
                    GoldenFixture.requireString(vector, "requestId")))
                "sendTwoMessages" -> for (text in stringList(vector, "texts")) {
                    results.add(runtime.sendUserMessage(text))
                }
                "switchMainSessionForErasure" -> {
                    val switched = runtime.switchMainSessionForErasure(
                        erasureID = GoldenFixture.requireString(vector, "erasureID"),
                        erasedRecords = stringList(vector, "erasedRecords"),
                    )
                    eraseResult = switched.old to switched.new
                }
                "cancelDuringTurn" -> {
                    val executor = Executors.newSingleThreadExecutor()
                    val future = executor.submit<BotSessionTurnResult> {
                        runtime.sendUserMessage(GoldenFixture.string(vector, "text") ?: "")
                    }
                    try {
                        waitUntil("${label}: prompt was not sent") { transport.promptCount >= 1 }
                        runtime.cancelMainTurn()
                        results.add(future.get(10, TimeUnit.SECONDS))
                    } catch (error: java.util.concurrent.ExecutionException) {
                        thrown = error.cause ?: error
                    } finally {
                        executor.shutdownNow()
                    }
                }
                else -> fail("$label: unknown action")
            }
        } catch (error: Throwable) {
            thrown = error
        }

        val expect = GoldenFixture.objectValue(vector, "expect")
        if (expectError) {
            assertNotNull("$label: expected a failure", thrown)
            val description = thrown!!.message ?: thrown.toString()
            for (fragment in stringList(expect, "errorContains")) {
                assertTrue("$label: \"$description\" must contain \"$fragment\"",
                    description.contains(fragment, ignoreCase = true))
            }
        } else {
            assertEquals("$label: unexpected failure $thrown", null, thrown)
        }

        assertRequests(
            transport, expect, resultString, eraseResult, results, label, liveFrames,
            runtime.appendedEvents())
    }

    private fun assertRequests(
        transport: VectorTransport,
        expect: JsonObject,
        resultString: String?,
        eraseResult: Pair<String, String>?,
        results: List<BotSessionTurnResult>,
        label: String,
        liveFrames: List<Map<String, String>>,
        lifecycleEvents: List<BotSessionLifecycleEvent>,
    ) {
        val created = transport.createdSessionIds.lastOrNull()
        val expectedResult = GoldenFixture.at(expect, "result")
        if (expectedResult is JsonString) {
            assertTrue("$label: result ${resultString ?: ""}",
                matchesRegex(resultString ?: "", expectedResult.value))
        } else if (expectedResult is JsonObject) {
            if (GoldenFixture.at(expectedResult, "status") != null) {
                assertTurnResult("$label: result", results.firstOrNull(), expectedResult)
            } else {
                assertEquals("$label: old", GoldenFixture.requireString(expectedResult, "old"),
                    eraseResult?.first)
                val expectedNew = GoldenFixture.requireString(expectedResult, "new")
                assertEquals("$label: new",
                    if (expectedNew == "\$created") created else expectedNew, eraseResult?.second)
            }
        }
        val expectedResults = objectList(expect, "results")
        if (expectedResults.isNotEmpty()) {
            assertEquals("$label: result count", expectedResults.size, results.size)
            for ((index, expected) in expectedResults.withIndex()) {
                assertTurnResult("$label: results[$index]", results[index], expected as JsonObject)
            }
        }

        assertRequestList("$label: create", transport.createArguments,
            GoldenFixture.at(expect, "createRequests"), created)
        assertRequestShapes(transport, label)
        assertRequestList("$label: claim", transport.claimRequests,
            GoldenFixture.at(expect, "claimRequests"), created)
        assertRequestList("$label: prompt", transport.promptArguments,
            GoldenFixture.at(expect, "promptRequests"), created)
        assertRequestList("$label: cancel", transport.cancelArguments,
            GoldenFixture.at(expect, "cancelRequests"), created)

        val pageRequests = GoldenFixture.at(expect, "pageRequests")
        val expectedPageCount = GoldenFixture.long(expect, "pageRequestCount")
            ?: (pageRequests as? JsonArray)?.values?.size?.toLong()
        if (expectedPageCount != null) {
            assertEquals("$label: page count", expectedPageCount.toInt(), transport.pageArguments.size)
            if (pageRequests is JsonArray) {
                for ((index, expected) in pageRequests.values.withIndex()) {
                    if (index >= transport.pageArguments.size) break
                    assertMatch("$label: page[$index]", expected,
                        transport.pageArguments[index], created)
                }
            }
        }
        GoldenFixture.long(expect, "listRequests")?.let { count ->
            assertEquals("$label: list count", count.toInt(), transport.listArguments.size)
            GoldenFixture.at(expect, "listRequestArgs")?.let {
                assertMatch("$label: list args", it, transport.listArguments.firstOrNull(), created)
            }
        }
        assertEquals("$label: archived", stringList(expect, "archive"), transport.archived)
        assertEquals("$label: unarchived", stringList(expect, "unarchive"), transport.unarchived)

        val followOpen = GoldenFixture.at(expect, "followOpen")
        if (followOpen is JsonArray) {
            assertEquals("$label: follow opens", followOpen.values.size, transport.openFrames.size)
            for ((index, expected) in followOpen.values.withIndex()) {
                if (index >= transport.openFrames.size) break
                assertMatch("$label: follow open[$index]", expected,
                    transport.openFrames[index], created)
            }
        }

        val lifecycleTypes = setOf("runtime.started", "runtime.exited")
        val appended = lifecycleEvents.filter { it.type in lifecycleTypes }
        val expectedEvents = GoldenFixture.at(expect, "events")
        if (expectedEvents is JsonArray) {
            assertEquals("$label: lifecycle event count",
                expectedEvents.values.size, appended.size)
            for ((index, expected) in expectedEvents.values.withIndex()) {
                if (index >= appended.size) break
                val actual = appended[index]
                val expectedObject = expected as JsonObject
                assertEquals("$label: event type", GoldenFixture.requireString(expectedObject, "type"),
                    actual.type)
                assertMatch("$label: event data", GoldenFixture.objectValue(expectedObject, "data"),
                    JsonObject(actual.data), created)
                assertMatch("$label: event principal",
                    GoldenFixture.objectValue(expectedObject, "principal"),
                    JsonObject(linkedMapOf(
                        "botId" to JsonString(actual.principal.botId),
                        "sessionId" to JsonString(actual.principal.sessionId),
                        "kind" to JsonString(actual.principal.kind.wire),
                    )), created)
            }
        }

        val expectedFrames = GoldenFixture.at(expect, "liveFrames")
        if (expectedFrames is JsonArray) {
            assertEquals("$label: live frame count", expectedFrames.values.size, liveFrames.size)
            for ((index, expected) in expectedFrames.values.withIndex()) {
                if (index >= liveFrames.size) break
                val actual = liveFrames[index]
                val expectedObject = expected as JsonObject
                assertEquals("$label: live[$index].kind",
                    GoldenFixture.requireString(expectedObject, "kind"), actual["kind"])
                GoldenFixture.string(expectedObject, "text")?.let {
                    assertEquals("$label: live[$index].text", it, actual["text"])
                }
                GoldenFixture.string(expectedObject, "type")?.let {
                    assertEquals("$label: live[$index].type", it, actual["type"])
                }
            }
        }

        if (GoldenFixture.bool(expect, "claimTokensEqual") == true) {
            val tokens = transport.claimRequests.mapNotNull {
                ((it["request"] as? JsonObject)?.members?.get("sessionToken") as? JsonString)?.value
            }
            assertEquals("$label: claims must reuse the current token", 1, tokens.toSet().size)
        }
    }

    /**
     * `session-lifecycle.md` §3/§6 fixes the exact request members; the
     * vector comparison is a subset match, so check the closed shape too.
     */
    private fun assertRequestShapes(transport: VectorTransport, label: String) {
        for (args in transport.createArguments) {
            assertEquals("$label: session/create top-level", setOf("request"), args.members.keys)
            val request = (args["request"] as JsonObject).members
            assertEquals("$label: session/create members",
                setOf("cwd", "sessionId", "agentPreset"), request.keys)
        }
        for (args in transport.claimRequests) {
            assertEquals("$label: claim top-level", setOf("request"), args.members.keys)
            val request = (args["request"] as JsonObject).members
            assertEquals("$label: claim members",
                setOf("sessionId", "sessionToken"), request.keys)
        }
        for (args in transport.promptArguments) {
            assertEquals("$label: prompt top-level", setOf("request"), args.members.keys)
            val request = (args["request"] as JsonObject).members
            assertEquals("$label: prompt members",
                setOf("requestId", "sessionId", "mode", "content"), request.keys)
            val content = (request["content"] as JsonArray).values
            assertEquals("$label: prompt content shape", 1, content.size)
            assertEquals("$label: prompt block members",
                setOf("type", "text"), (content[0] as JsonObject).members.keys)
        }
        for (args in transport.cancelArguments) {
            assertEquals("$label: cancel top-level", setOf("request"), args.members.keys)
            val request = (args["request"] as JsonObject).members
            assertEquals("$label: cancel members", setOf("sessionId", "cause"), request.keys)
            assertEquals("$label: cancel cause",
                setOf("kind"), (request["cause"] as JsonObject).members.keys)
        }
        for (frame in transport.openFrames) {
            assertEquals("$label: follow open members",
                setOf("type", "streamId", "endpoint", "payload"), frame.members.keys)
        }
    }

    private fun assertRequestList(
        label: String,
        actual: List<JsonObject>,
        expectedValue: JsonValue?,
        created: String?,
    ) {
        val expected = (expectedValue as? JsonArray)?.values ?: return
        assertEquals("$label count", expected.size, actual.size)
        for ((index, value) in expected.withIndex()) {
            if (index >= actual.size) break
            assertMatch("$label[$index]", value, actual[index], created)
        }
    }

    private fun assertTurnResult(
        label: String,
        actual: BotSessionTurnResult?,
        expected: JsonObject,
    ) {
        assertNotNull("$label: missing result", actual)
        assertEquals("$label: status", GoldenFixture.requireString(expected, "status"), actual!!.status)
        assertEquals("$label: text", GoldenFixture.string(expected, "text") ?: "", actual.text)
        assertEquals("$label: turnId", GoldenFixture.string(expected, "turnId"), actual.turnId)
    }

    private fun assertMatch(label: String, expected: JsonValue?, actual: JsonValue?, created: String?) {
        if (expected == null) {
            assertTrue("$label: expected null", actual == null || actual is JsonNull)
            return
        }
        when (expected) {
            is JsonNull -> assertTrue("$label: expected null", actual == null || actual is JsonNull)
            is JsonString -> {
                val text = (actual as? JsonString)?.value
                assertNotNull("$label: expected a string, got $actual", text)
                if (expected.value.startsWith("re:")) {
                    assertTrue("$label: ${text} does not match ${expected.value}",
                        matchesRegex(text!!, expected.value))
                } else if (expected.value == "\$created") {
                    assertEquals("$label: \$created", created, text)
                } else {
                    assertEquals("$label", expected.value, text)
                }
            }
            is JsonObject -> {
                val actualMembers = (actual as? JsonObject)?.members
                assertNotNull("$label: expected an object, got $actual", actualMembers)
                for ((key, value) in expected.members) {
                    assertMatch("$label.$key", value, actualMembers!![key], created)
                }
            }
            is JsonArray -> {
                val actualValues = (actual as? JsonArray)?.values
                assertNotNull("$label: expected an array, got $actual", actualValues)
                assertEquals("$label: array size", expected.values.size, actualValues!!.size)
                for ((index, value) in expected.values.withIndex()) {
                    assertMatch("$label[$index]", value, actualValues[index], created)
                }
            }
            is JsonBool -> assertEquals("$label", expected.value, (actual as? JsonBool)?.value)
            is JsonNumber -> {
                val actualNumber = actual as? JsonNumber
                assertNotNull("$label: expected a number, got $actual", actualNumber)
                assertEquals("$label", expected.raw.toDouble(), actualNumber!!.raw.toDouble(), 0.0)
            }
        }
    }

    private fun waitUntil(message: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (System.nanoTime() < deadline) {
            if (condition()) return
            Thread.sleep(2)
        }
        fail(message)
    }
}

/**
 * Vector-driven [BotSessionTransport]. The transcript is data; this type only
 * executes it, resolves `$requested`/`$requestedPreset`, and records the
 * request values the runtime produced.
 */
private class VectorTransport(script: JsonObject) : BotSessionTransport {
    private val lock = Any()
    private val createResponses: List<JsonValue> =
        (script.members["create"] as? JsonArray)?.values ?: emptyList()
    private val pageResponses: Map<String, JsonValue> =
        (script.members["page"] as? JsonObject)?.members ?: emptyMap()
    private val listItems: List<JsonValue> =
        (script.members["list"] as? JsonArray)?.values ?: emptyList()
    private val claimResponses: List<JsonValue> =
        (script.members["claim"] as? JsonArray)?.values ?: emptyList()
    private val turns: List<List<JsonValue>> =
        (script.members["turns"] as? JsonArray)?.values?.map { value ->
            (value as? JsonArray)?.values ?: emptyList()
        } ?: emptyList()

    private var createIndex = 0
    private var claimIndex = 0
    private var turnIndex = 0
    private var cancellations = 0
    private val createArgs = ArrayList<JsonObject>()
    private val claimArgs = ArrayList<JsonObject>()
    private val pageArgs = ArrayList<JsonObject>()
    private val listArgs = ArrayList<JsonObject>()
    private val promptArgs = ArrayList<JsonObject>()
    private val cancelArgs = ArrayList<JsonObject>()
    private val created = ArrayList<String>()
    private val archiveIDs = ArrayList<String>()
    private val unarchiveIDs = ArrayList<String>()
    private val opens = ArrayList<JsonObject>()

    val createArguments: List<JsonObject> get() = synchronized(lock) { createArgs.toList() }
    val claimRequests: List<JsonObject> get() = synchronized(lock) { claimArgs.toList() }
    val pageArguments: List<JsonObject> get() = synchronized(lock) { pageArgs.toList() }
    val listArguments: List<JsonObject> get() = synchronized(lock) { listArgs.toList() }
    val promptArguments: List<JsonObject> get() = synchronized(lock) { promptArgs.toList() }
    val cancelArguments: List<JsonObject> get() = synchronized(lock) { cancelArgs.toList() }
    val createdSessionIds: List<String> get() = synchronized(lock) { created.toList() }
    val archived: List<String> get() = synchronized(lock) { archiveIDs.toList() }
    val unarchived: List<String> get() = synchronized(lock) { unarchiveIDs.toList() }
    val openFrames: List<JsonObject> get() = synchronized(lock) { opens.toList() }
    val promptCount: Int get() = synchronized(lock) { promptArgs.size }

    override fun call(endpoint: String, args: JsonObject): JsonObject {
        val request = (args["request"] as? JsonObject)?.members ?: emptyMap()
        val requestedID = (request["sessionId"] as? JsonString)?.value ?: ""
        val requestedPreset = (request["agentPreset"] as? JsonString)?.value ?: ""
        return when (endpoint) {
            "session/create" -> {
                synchronized(lock) { createArgs.add(args) }
                val response = synchronized(lock) {
                    val value = createResponses.getOrNull(createIndex) as? JsonObject
                        ?: JsonObject(emptyMap())
                    createIndex += 1
                    value
                }
                throwIfError(response)
                val resolved = resolve(response, requestedID, requestedPreset) as JsonObject
                (resolved["sessionId"] as? JsonString)?.value?.let {
                    synchronized(lock) { created.add(it) }
                }
                resolved
            }
            "session/page" -> {
                synchronized(lock) { pageArgs.add(args) }
                val sessionID = (request["address"] as? JsonObject)
                    ?.members?.get("sessionId")?.let { (it as JsonString).value } ?: ""
                val response = (pageResponses[sessionID] as? JsonObject)
                    ?: JsonObject(linkedMapOf("sessionId" to JsonString(sessionID)))
                throwIfError(response)
                resolve(response, sessionID, requestedPreset) as JsonObject
            }
            "session/list" -> {
                synchronized(lock) { listArgs.add(args) }
                JsonObject(linkedMapOf("items" to JsonArray(listItems)))
            }
            "phone/botClaimSession" -> {
                synchronized(lock) { claimArgs.add(args) }
                val response = synchronized(lock) {
                    val value = claimResponses.getOrNull(claimIndex) as? JsonObject
                        ?: JsonObject(linkedMapOf("ok" to JsonBool(true)))
                    claimIndex += 1
                    value
                }
                throwIfError(response)
                JsonObject(linkedMapOf(
                    "ok" to (response["ok"] ?: JsonBool(true)),
                    "sessionId" to JsonString(requestedID),
                ))
            }
            "workspace/archiveSession" -> {
                val id = (request["sessionId"] as? JsonString)?.value ?: ""
                synchronized(lock) {
                    if (!archiveIDs.contains(id)) archiveIDs.add(id)
                }
                JsonObject(linkedMapOf("archivedSessionIds" to JsonArray(listOf(JsonString(id)))))
            }
            "workspace/unarchiveSession" -> {
                val id = (request["sessionId"] as? JsonString)?.value ?: ""
                synchronized(lock) {
                    archiveIDs.removeAll { it == id }
                    unarchiveIDs.add(id)
                }
                JsonObject(linkedMapOf("archivedSessionIds" to JsonArray(emptyList())))
            }
            "session/prompt" -> {
                synchronized(lock) { promptArgs.add(args) }
                JsonObject(emptyMap())
            }
            "session/cancel" -> {
                synchronized(lock) {
                    cancelArgs.add(args)
                    cancellations += 1
                }
                JsonObject(emptyMap())
            }
            else -> JsonObject(emptyMap())
        }
    }

    override fun openFollow(): BotFollowConnection {
        val frames = synchronized(lock) {
            val value = turns.getOrNull(turnIndex) ?: emptyList()
            turnIndex += 1
            value.map { it as JsonObject }
        }
        return VectorFollow(frames, this)
    }

    fun recordOpen(frame: JsonObject) {
        synchronized(lock) { opens.add(frame) }
    }

    fun waitForCancel() {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (System.nanoTime() < deadline) {
            if (synchronized(lock) { cancellations } > 0) return
            Thread.sleep(1)
        }
    }

    private fun throwIfError(response: JsonObject) {
        val error = response["error"] as? JsonObject ?: return
        throw BotSessionRemoteException(
            code = (error["code"] as? JsonString)?.value ?: "gateway/internal",
            detail = (error["message"] as? JsonString)?.value ?: "",
        )
    }

    private fun resolve(value: JsonValue, requestedID: String, requestedPreset: String): JsonValue =
        when (value) {
            is JsonString -> when (value.value) {
                "\$requested" -> JsonString(requestedID)
                "\$requestedPreset" -> JsonString(requestedPreset)
                else -> value
            }
            is JsonArray -> JsonArray(value.values.map { resolve(it, requestedID, requestedPreset) })
            is JsonObject -> JsonObject(value.members.mapValues {
                resolve(it.value, requestedID, requestedPreset)
            })
            else -> value
        }

    private class VectorFollow(
        private val frames: List<JsonObject>,
        private val transport: VectorTransport,
    ) : BotFollowConnection {
        private var index = 0

        override fun send(frame: JsonObject) {
            transport.recordOpen(frame)
        }

        override fun receive(): JsonObject? {
            while (index < frames.size) {
                val frame = frames[index]
                index += 1
                if ((frame["__awaitCancel"] as? JsonBool)?.value == true) {
                    transport.waitForCancel()
                    continue
                }
                return frame
            }
            return null
        }

        override fun close() = Unit
    }
}

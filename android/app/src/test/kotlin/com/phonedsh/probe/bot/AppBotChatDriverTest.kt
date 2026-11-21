// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.session.BotFollowConnection
import com.phonedsh.bot.session.BotSessionTransport
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.bot.rows.BotUserAction
import com.phonedsh.bot.rows.BotUserActionKind
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.fish.BotFishLifecycle
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * K6a: the production driver over the real P25 store/projector and an explicit
 * local [com.phonedsh.bot.session.BotSessionTransport]. No Android type and no
 * UI renderer is constructed here.
 */
class AppBotChatDriverTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    private lateinit var file: File
    private lateinit var sql: JdbcBotSqlDriver
    private lateinit var store: BotDomainStore
    private lateinit var transport: LocalBotSessionTransport
    private lateinit var driver: AppBotChatDriver
    private val sharedStoreLock = Any()

    @Before
    fun setUp() {
        file = Files.createTempFile("pdsh-app-bot-", ".sqlite").toFile()
        sql = JdbcBotSqlDriver.open(file)
        store = BotDomainStore(sql)
        transport = LocalBotSessionTransport(clock = { 1_000L })
        driver = AppBotChatDriver(
            store = store,
            transport = transport,
            clock = { 1_000L },
            storeLock = sharedStoreLock,
        )
    }

    @After
    fun tearDown() {
        driver.close()
        runCatching { store.close() }
    }

    @Test
    fun historyStartsEmptyAndBecomesTheDurableUserRow() = runBlocking {
        val empty = driver.history(null, 20)
        assertTrue(empty.rows.isEmpty())
        assertNull(empty.nextCursor)

        val action = chat("nonce-1", "你好")
        val result = driver.perform(action)
        assertTrue(result is BotActionResult.Accepted)
        val eventId = (result as BotActionResult.Accepted).eventID
        assertNotNull(store.event(eventId))

        val page = awaitHistory { rows ->
            rows.any { row ->
                row.body.type == BotRowBodyType.TEXT &&
                    (row.body["text"] as? JsonString)?.value == "你好"
            }
        }
        val user = page.rows.first { (it.body["text"] as? JsonString)?.value == "你好" }
        assertEquals("user", user.role)
        assertEquals(eventId, user.provenance.eventIDs.single())
        assertTrue(user.chatActionNonce == null || user.chatActionNonce == "nonce-1")
    }

    @Test
    fun performIsIdempotentPerNonce() = runBlocking {
        val action = chat("nonce-dup", "只发一次")
        val first = driver.perform(action)
        val second = driver.perform(action)
        assertTrue(first is BotActionResult.Accepted)
        assertTrue(second is BotActionResult.Duplicate)
        assertEquals(
            (first as BotActionResult.Accepted).eventID,
            (second as BotActionResult.Duplicate).eventID,
        )
        assertEquals(1, store.events(0, 100).count { it.type == "conversation.user_message" })
    }

    @Test
    fun watchEmitsTheProjectedUserAndAssistantRows() = runBlocking {
        driver.perform(chat("nonce-watch", "watch me"))

        // A watch batch is a delta: the first one may carry only the user row.
        val deltaTexts = withTimeout(10_000) {
            var assistantSeen = false
            var userSeen = false
            driver.watch(0).first { batch ->
                for (row in batch.rows) {
                    when ((row.body["text"] as? JsonString)?.value) {
                        "watch me" -> userSeen = true
                        "收到：watch me" -> assistantSeen = true
                    }
                }
                assistantSeen
            }
            userSeen to assistantSeen
        }
        assertTrue(deltaTexts.first)
        assertTrue(deltaTexts.second)
        val rows = driver.history(null, 50).rows
        assertTrue(rows.any { it.role == "user" })
        assertTrue(rows.any { it.role == "assistant" })
    }

    @Test
    fun presentationTracksTheLiveTurnAndClearsOnTurnEnd() = runBlocking {
        transport.autoComplete = false
        assertEquals(BotFishLifecycle.IDLE, driver.presentation().first().fishState)

        driver.perform(chat("nonce-live", "still running"))
        val running = withTimeout(10_000) {
            driver.presentation().first { it.runningTurnID != null }
        }
        assertEquals("turn-1", running.runningTurnID)
        assertEquals(BotFishLifecycle.THINKING, running.fishState)

        driver.stopCurrentTurn(running.runningTurnID)
        val stopped = withTimeout(10_000) {
            driver.presentation().first { it.runningTurnID == null }
        }
        assertEquals(BotFishLifecycle.IDLE, stopped.fishState)
        assertTrue(transport.calls.contains("session/cancel"))
    }

    @Test
    fun stopWithoutASessionDoesNotOpenOne() = runBlocking {
        driver.stopCurrentTurn("turn-1")
        assertTrue(transport.calls.none { it == "session/create" || it == "session/cancel" })
    }

    @Test
    fun turnProcessesExposeToolNamesButNeverRows() = runBlocking {
        val action = chat("nonce-tools", "tools")
        driver.perform(action)
        awaitHistory { rows -> rows.any { it.role == "assistant" } }
        // The local transport emits no tool calls; the projection must still be
        // an empty map rather than inventing process rows.
        assertTrue(driver.turnProcesses().isEmpty())
    }

    @Test
    fun historyPagesBeforeAnAnchor() = runBlocking {
        repeat(3) { index ->
            driver.perform(chat("nonce-page-$index", "line $index"))
        }
        val all = awaitHistory { it.size >= 3 }
        assertTrue(all.rows.size >= 3)
        val anchor = all.rows[all.rows.size / 2].id
        val page = driver.history(anchor, 1)
        assertEquals(1, page.rows.size)
        assertEquals(all.rows[all.rows.size / 2 - 1].id, page.rows.single().id)
        assertTrue(page.hasMore)
    }

    @Test
    fun coldReopenProjectsPersistedLifecycleAndWorkerJournalOnce() = runBlocking {
        driver.perform(chat("cold-1", "你好"))
        awaitHistory { rows -> rows.any { rowText(it) == "收到：你好" } }
        driver.close()

        // `JdbcBotSqlDriver.close()` deletes its file, so the second connection
        // is the process-reopen analogue while the first store object (the
        // "old process") is still alive. WAL has the durable events committed.
        val reopenedStore = BotDomainStore(JdbcBotSqlDriver.open(file))
        val reopened = AppBotChatDriver(
            store = reopenedStore,
            transport = transport,
            clock = { 2_000L },
            storeLock = sharedStoreLock,
        )
        try {
            val page = awaitHistoryOf(reopened) { rows ->
                rows.any { rowText(it) == "你好" } &&
                    rows.any { rowText(it) == "收到：你好" }
            }
            assertEquals(1, page.rows.count { rowText(it) == "你好" })
            assertEquals(1, page.rows.count { rowText(it) == "收到：你好" })

            val lifecycle = reopenedStore.events(0, 500)
                .filter { it.type == "runtime.started" }
            assertTrue("runtime.started must survive the force-stop", lifecycle.isNotEmpty())
            assertTrue(lifecycle.all { it.principal.botId == "main" })
            assertTrue(lifecycle.all { it.principal.kind == "chat" })
            val data = (lifecycle.last().data as? JsonObject)?.members
            assertNotNull(data?.get("sessionId"))
            assertEquals("chat", lifecycle.last().principal.kind)
            assertTrue(data?.get("cwd") is JsonString)
        } finally {
            reopened.close()
            reopenedStore.close()
        }
    }

    @Test
    fun coldReopenShowsTheMaterializedConversationWithoutAWorker() = runBlocking {
        driver.perform(chat("before-restart", "你好"))
        awaitHistory { rows -> rows.any { rowText(it) == "收到：你好" } }
        driver.close()

        val golden = File(
            System.getProperty("pdsh.repo.root"),
            "spec/bot/v1/golden/projection.phone.json",
        )
        val fixture = JsonValue.parse(golden.readText()) as JsonObject
        val valid = fixture["valid"] as JsonObject
        val conversation = (valid["dshMapping"] as JsonArray).values
            .map { it as JsonObject }
            .single { it["name"] == JsonString("user-assistant") }
        val invalid = (fixture["invalid"] as JsonArray).values
            .map { it as JsonObject }
            .single { it["name"] == JsonString("broken-json") }
        val records = (conversation["records"] as JsonArray).values
        val invalidLine = (invalid["records"] as JsonArray).values
            .map { (it as JsonString).value }
            .single { runCatching { JsonValue.parse(it) }.isFailure }

        val sessions = temporaryFolder.newFolder("sessions")
        val session = sessions.resolve("project/gb-main").apply { mkdirs() }
        val journal = session.resolve("session.v4.jsonl")
        journal.writeText(listOf(records[0], JsonString(invalidLine), records[1])
            .joinToString("\n", postfix = "\n") { (it as JsonString).value })
        session.resolve("session.v3.jsonl").apply {
            writeText(invalidLine)
            check(setLastModified(journal.lastModified() - 1_000))
        }

        val offlineWorker = object : BotSessionTransport {
            override fun call(endpoint: String, args: JsonObject): JsonObject = error("Worker offline")
            override fun openFollow(): BotFollowConnection = error("Worker offline")
        }
        val reopenedStore = BotDomainStore(JdbcBotSqlDriver.open(file))
        val reopened = AppBotChatDriver(
            store = reopenedStore,
            transport = offlineWorker,
            materializedSessions = sessions.toPath(),
        )
        try {
            val page = withTimeout(3_000) {
                reopened.watch(0).first { it.rows.isNotEmpty() }
            }
            assertEquals(listOf("你好", "可见回复"), page.rows.map(::rowText))
        } finally {
            reopened.close()
            reopenedStore.close()
        }
    }

    @Test
    fun legacyMintedWorkerSessionIsRecoveredWithoutADurableLifecycle() = runBlocking {
        driver.perform(chat("legacy-1", "旧消息"))
        awaitHistory { rows -> rows.any { rowText(it) == "收到：旧消息" } }
        driver.close()

        val freshFile = Files.createTempFile("pdsh-app-bot-legacy-", ".sqlite").toFile()
        val freshStore = BotDomainStore(JdbcBotSqlDriver.open(freshFile))
        val recovered = AppBotChatDriver(
            store = freshStore,
            transport = transport,
            clock = { 3_000L },
            storeLock = sharedStoreLock,
        )
        try {
            val page = awaitHistoryOf(recovered) { rows ->
                rows.any { rowText(it) == "收到：旧消息" }
            }
            assertTrue(page.rows.any { rowText(it) == "旧消息" })
            // The pre-fix install has no lifecycle event; recovery must read
            // the Worker journal, not invent or persist a new epoch.
            assertTrue(freshStore.events(0, 100).none { it.type == "runtime.started" })
        } finally {
            recovered.close()
            freshStore.close()
        }
    }

    @Test
    fun twoDriversSharingOneStoreSerializeThroughTheInjectedLock() = runBlocking {
        val secondTransport = LocalBotSessionTransport(clock = { 1_000L })
        val second = AppBotChatDriver(
            store = store,
            transport = secondTransport,
            clock = { 1_000L },
            storeLock = sharedStoreLock,
        )
        try {
            val results = coroutineScope {
                listOf(
                    async(Dispatchers.IO) { driver.perform(chat("shared-a", "one")) },
                    async(Dispatchers.IO) { second.perform(chat("shared-b", "two")) },
                    async(Dispatchers.IO) { driver.perform(chat("shared-c", "three")) },
                    async(Dispatchers.IO) { second.perform(chat("shared-d", "four")) },
                ).awaitAll()
            }
            assertTrue(results.all { it is BotActionResult.Accepted })
            assertEquals(
                4,
                store.events(0, 200).count { it.type == "conversation.user_message" },
            )
        } finally {
            second.close()
        }
    }

    private fun rowText(row: com.phonedsh.bot.rows.BotRow): String? =
        (row.body["text"] as? JsonString)?.value

    private fun chat(nonce: String, text: String): BotUserAction = BotUserAction(
        nonce = nonce,
        botID = "main",
        kind = BotUserActionKind.CHAT,
        text = text,
    )

    private suspend fun awaitHistory(
        predicate: (List<com.phonedsh.bot.rows.BotRow>) -> Boolean,
    ): com.phonedsh.ui.bot.state.BotUIHistoryPage =
        awaitHistoryOf(driver, predicate)

    private suspend fun awaitHistoryOf(
        source: AppBotChatDriver,
        predicate: (List<com.phonedsh.bot.rows.BotRow>) -> Boolean,
    ): com.phonedsh.ui.bot.state.BotUIHistoryPage = withTimeout(10_000) {
        var page = source.history(null, 50)
        while (!predicate(page.rows)) {
            kotlinx.coroutines.delay(10)
            page = source.history(null, 50)
        }
        page
    }
}

// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.bot.rows.BotUserAction
import com.phonedsh.bot.rows.BotUserActionKind
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.fish.BotFishLifecycle
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * K6a: the production driver over the real P25 store/projector and an explicit
 * local [com.phonedsh.bot.session.BotSessionTransport]. No Android type and no
 * UI renderer is constructed here.
 */
class AppBotChatDriverTest {
    private lateinit var file: File
    private lateinit var sql: JdbcBotSqlDriver
    private lateinit var store: BotDomainStore
    private lateinit var transport: LocalBotSessionTransport
    private lateinit var driver: AppBotChatDriver

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

    private fun chat(nonce: String, text: String): BotUserAction = BotUserAction(
        nonce = nonce,
        botID = "main",
        kind = BotUserActionKind.CHAT,
        text = text,
    )

    private suspend fun awaitHistory(
        predicate: (List<com.phonedsh.bot.rows.BotRow>) -> Boolean,
    ): com.phonedsh.ui.bot.state.BotUIHistoryPage = withTimeout(10_000) {
        var page = driver.history(null, 50)
        while (!predicate(page.rows)) {
            kotlinx.coroutines.delay(10)
            page = driver.history(null, 50)
        }
        page
    }
}

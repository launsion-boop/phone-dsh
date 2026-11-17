// SPDX-License-Identifier: MIT
// The read-back that settles an `outcomeUnknown` send (spec/host/v1/README.md
// section 10): present, held by the engine, proven absent, or not provable.
// Port of `examples/probe-app/PhoneDSHSimTests/SendOutboxReadBackTests.swift`,
// case for case.
package com.phonedsh.probe.outbox

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SendOutboxReadBackTest {
    private val created = 1_700_000_100_000L
    private val emptyInbox = obj("next-turn" to arr(), "next-step" to arr())
    private val held = obj("source" to obj("kind" to str("user"), "rpcId" to str("wanted")))

    private fun obj(vararg members: Pair<String, JsonValue>): JsonValue = JsonObject(linkedMapOf(*members))

    private fun arr(vararg values: JsonValue): JsonValue = JsonArray(values.toList())

    private fun str(value: String): JsonValue = JsonString(value)

    private fun num(value: Long): JsonValue = JsonNumber(value.toString())

    private fun page(records: List<JsonValue>, hasMore: Boolean): JsonValue =
        obj("records" to JsonArray(records.map { obj("event" to it) }), "hasMore" to JsonBool(hasMore))

    private fun userMessage(seq: Long, requestId: String, atMs: Long): JsonValue = obj(
        "seq" to num(seq),
        "type" to str("user/message"),
        "time" to num(atMs),
        "data" to obj("source" to obj("kind" to str("user"), "rpcId" to str(requestId))),
    )

    private val noOlderPage: suspend (Long) -> JsonValue = { throw AssertionError("no older page may be read") }

    private fun resolve(
        inbox: JsonValue? = emptyInbox,
        firstPage: JsonValue?,
        maxPages: Int = SendOutboxReadBack.DEFAULT_MAX_PAGES,
        loadEarlier: suspend (Long) -> JsonValue = noOlderPage,
    ): SendOutboxReadBack = runBlocking {
        SendOutboxReadBack.resolve("wanted", created, inbox, firstPage, maxPages, loadEarlier)
    }

    @Test
    fun `a journaled user message is found on the first page`() {
        val first = page(listOf(userMessage(9, "other", created + 1), userMessage(10, "wanted", created + 2)), true)
        assertEquals(SendOutboxReadBack.JOURNALED, resolve(firstPage = first))
    }

    @Test
    fun `a prompt held in either inbox lane is not absent`() {
        for (lane in listOf("next-turn", "next-step")) {
            val inbox = obj(
                "next-turn" to if (lane == "next-turn") arr(held) else arr(),
                "next-step" to if (lane == "next-step") arr(held) else arr(),
            )
            assertEquals(lane, SendOutboxReadBack.HELD, resolve(inbox, page(emptyList(), false)))
        }
    }

    @Test
    fun `a matching held item is found even when the other inbox lane is unreadable`() {
        val inboxes = mapOf(
            "next-step is missing" to obj("next-turn" to arr(held)),
            "next-step is not an array" to obj("next-turn" to arr(held), "next-step" to str("unreadable")),
            "next-turn is missing" to obj("next-step" to arr(held)),
            "next-turn is not an array" to obj("next-turn" to obj(), "next-step" to arr(held)),
        )
        for ((label, inbox) in inboxes) {
            assertEquals(label, SendOutboxReadBack.HELD, resolve(inbox, page(emptyList(), false)))
        }
    }

    @Test
    fun `exhausted history with a known inbox proves absence`() {
        val first = page(listOf(userMessage(4, "other", created + 5)), false)
        assertEquals(SendOutboxReadBack.ABSENT, resolve(firstPage = first))
    }

    @Test
    fun `a readable inbox item without the rpcId still proves absence`() {
        val inbox = obj("next-turn" to arr(obj("source" to obj("kind" to str("user")))), "next-step" to arr())
        val first = page(listOf(userMessage(4, "other", created + 5)), false)
        assertEquals(SendOutboxReadBack.ABSENT, resolve(inbox, first))
    }

    @Test
    fun `a session without a durable log and an empty inbox proves absence`() {
        assertEquals(SendOutboxReadBack.ABSENT, resolve(firstPage = null))
    }

    @Test
    fun `the walk goes past an old timestamp to the beginning`() {
        val fetched = ArrayList<Long>()
        val result = resolve(firstPage = page(listOf(userMessage(90, "recent", created + 10)), true)) { before ->
            fetched.add(before)
            if (before == 90L) {
                page(listOf(userMessage(40, "old", created - 3_600_000)), true)
            } else {
                page(listOf(userMessage(10, "oldest", created - 7_200_000)), false)
            }
        }
        assertEquals("records older than the entry cannot end the walk", listOf(90L, 40L), fetched)
        assertEquals(SendOutboxReadBack.ABSENT, result)
    }

    @Test
    fun `an older page is still searched for the request`() {
        val result = resolve(firstPage = page(listOf(userMessage(90, "recent", created + 10)), true)) {
            page(listOf(userMessage(40, "wanted", created + 1)), false)
        }
        assertEquals(SendOutboxReadBack.JOURNALED, result)
    }

    @Test
    fun `an unknown inbox never proves absence`() {
        for (inbox in listOf<JsonValue?>(null, JsonNull)) {
            assertEquals(SendOutboxReadBack.INCONCLUSIVE, resolve(inbox, page(emptyList(), false)))
        }
    }

    @Test
    fun `history that does not advance or exceeds the bound is inconclusive`() {
        val stuck = resolve(firstPage = page(listOf(userMessage(50, "a", created + 9)), true)) {
            page(listOf(userMessage(50, "a", created + 9)), true)
        }
        assertEquals(SendOutboxReadBack.INCONCLUSIVE, stuck)

        var seq = 1_000L
        var loads = 0
        val bounded = resolve(firstPage = page(listOf(userMessage(seq, "a", created + 9)), true), maxPages = 3) {
            seq -= 1
            loads += 1
            page(listOf(userMessage(seq, "a", created + 9)), true)
        }
        assertEquals(SendOutboxReadBack.INCONCLUSIVE, bounded)
        assertEquals("three pages are read: the first and two older ones", 2, loads)
        assertEquals(40, SendOutboxReadBack.DEFAULT_MAX_PAGES)
    }

    @Test
    fun `a malformed first page cannot prove absence`() {
        val malformed = mapOf(
            "page is not an object" to str("not a page"),
            "page has no records" to obj("hasMore" to JsonBool(false)),
            "records is not an array" to obj("records" to obj(), "hasMore" to JsonBool(false)),
            "page has no hasMore" to obj("records" to arr()),
            "hasMore is not a bool" to obj("records" to arr(), "hasMore" to str("false")),
            "record has no event" to obj("records" to arr(obj("seq" to num(1))), "hasMore" to JsonBool(false)),
            "record is not an object" to obj("records" to arr(str("unreadable")), "hasMore" to JsonBool(false)),
            "event is not an object" to
                obj("records" to arr(obj("event" to str("unreadable"))), "hasMore" to JsonBool(false)),
        )
        for ((label, first) in malformed) {
            assertEquals(label, SendOutboxReadBack.INCONCLUSIVE, resolve(firstPage = first))
        }
    }

    @Test
    fun `a malformed later page cannot prove absence`() {
        val first = page(listOf(userMessage(90, "recent", created + 10)), true)
        val malformed = mapOf(
            "page is not an object" to str("not a page"),
            "page has no records" to obj("hasMore" to JsonBool(false)),
            "records is not an array" to obj("records" to str("unreadable"), "hasMore" to JsonBool(false)),
            "later page has no hasMore" to obj("records" to arr()),
            "hasMore is not a bool" to obj("records" to arr(), "hasMore" to num(0)),
            "record has no event" to obj("records" to arr(obj("seq" to num(40))), "hasMore" to JsonBool(false)),
            "event is not an object" to obj("records" to arr(obj("event" to JsonNull)), "hasMore" to JsonBool(false)),
        )
        for ((label, later) in malformed) {
            var loads = 0
            val result = resolve(firstPage = first) {
                loads += 1
                later
            }
            assertEquals(label, 1, loads)
            assertEquals(label, SendOutboxReadBack.INCONCLUSIVE, result)
        }
    }

    @Test
    fun `a malformed inbox lane cannot prove absence`() {
        val malformed = mapOf(
            "next-turn is not an array" to obj("next-turn" to str("unreadable"), "next-step" to arr()),
            "next-step is not an array" to obj("next-turn" to arr(), "next-step" to obj("id" to str("unreadable"))),
            "next-turn item is not an object" to obj("next-turn" to arr(str("unreadable")), "next-step" to arr()),
            "next-step item is not an object" to obj("next-turn" to arr(), "next-step" to arr(num(1))),
        )
        val first = page(listOf(userMessage(4, "other", created + 5)), false)
        for ((label, inbox) in malformed) {
            assertEquals(label, SendOutboxReadBack.INCONCLUSIVE, resolve(inbox, first))
        }
    }

    @Test
    fun `a missing inbox lane cannot prove absence`() {
        for (inbox in listOf(obj(), obj("next-turn" to arr()), obj("next-step" to arr()))) {
            assertEquals(SendOutboxReadBack.INCONCLUSIVE, resolve(inbox, page(emptyList(), false)))
        }
    }

    @Test
    fun `an unreadable message source cannot prove absence`() {
        val unreadableItems = mapOf(
            "item has no source" to obj(),
            "source is not an object" to obj("source" to str("user")),
            "source has no kind" to obj("source" to obj("rpcId" to str("other"))),
            "source kind is not a string" to obj("source" to obj("kind" to num(1))),
        )
        for ((label, item) in unreadableItems) {
            val inbox = obj("next-turn" to arr(item), "next-step" to arr())
            assertEquals(label, SendOutboxReadBack.INCONCLUSIVE, resolve(inbox, page(emptyList(), false)))
        }

        fun event(vararg members: Pair<String, JsonValue>) = obj("seq" to num(1), "time" to num(created), *members)
        val unreadableEvents = mapOf(
            "event has no type" to event("data" to obj()),
            "event type is not a string" to event("type" to num(1), "data" to obj()),
            "user/message has no data" to event("type" to str("user/message")),
            "user/message data is not an object" to event("type" to str("user/message"), "data" to str("unreadable")),
            "user/message has no source" to event("type" to str("user/message"), "data" to obj()),
            "user/message source is not an object" to
                event("type" to str("user/message"), "data" to obj("source" to str("user"))),
            "user/message source has no kind" to
                event("type" to str("user/message"), "data" to obj("source" to obj("rpcId" to str("other")))),
            "user/message source kind is not a string" to
                event("type" to str("user/message"), "data" to obj("source" to obj("kind" to JsonBool(true)))),
        )
        for ((label, event) in unreadableEvents) {
            assertEquals(label, SendOutboxReadBack.INCONCLUSIVE, resolve(firstPage = page(listOf(event), false)))
        }
    }

    @Test
    fun `positive recognition survives other unreadable records`() {
        val inbox = obj(
            "next-turn" to arr(obj(), held),
            "next-step" to arr(obj("source" to obj("kind" to num(1)))),
        )
        assertEquals(SendOutboxReadBack.HELD, resolve(inbox, page(emptyList(), false)))

        val unknownEvent = obj("seq" to num(1), "time" to num(created))
        val first = page(listOf(unknownEvent, userMessage(2, "wanted", created + 1)), false)
        assertEquals(SendOutboxReadBack.JOURNALED, resolve(firstPage = first))
    }

    @Test
    fun `out of order history timestamps do not hide the request`() {
        val result = resolve(firstPage = page(listOf(userMessage(90, "other", created - 3_600_000)), true)) { before ->
            assertEquals(90L, before)
            page(listOf(userMessage(40, "wanted", created + 1)), false)
        }
        assertEquals(SendOutboxReadBack.JOURNALED, result)
    }

    @Test
    fun `a non-user source with the same rpcId is not the request`() {
        val source = obj("kind" to str("tool"), "rpcId" to str("wanted"))
        val inbox = obj("next-turn" to arr(obj("source" to source)), "next-step" to arr())
        assertEquals(SendOutboxReadBack.ABSENT, resolve(inbox, page(emptyList(), false)))

        val event = obj(
            "seq" to num(1),
            "type" to str("user/message"),
            "time" to num(created),
            "data" to obj("source" to source),
        )
        assertEquals(SendOutboxReadBack.ABSENT, resolve(firstPage = page(listOf(event), false)))
    }

    @Test
    fun `an unreadable sequence cannot skip history`() {
        val malformed = listOf(
            obj("type" to str("turn/start")),
            obj("seq" to JsonNumber("1.5"), "type" to str("turn/start")),
            obj("seq" to num(-1), "type" to str("turn/start")),
            obj("seq" to num(9_007_199_254_740_992L), "type" to str("turn/start")),
            obj("seq" to str("7"), "type" to str("turn/start")),
        )
        for (event in malformed) {
            val first = page(listOf(event, userMessage(90, "other", created + 1)), true)
            val result = resolve(firstPage = first) { page(emptyList(), false) }
            assertEquals(SendOutboxReadBack.INCONCLUSIVE, result)
        }
        // A page that claims more history but has no event to take a cursor from.
        assertEquals(SendOutboxReadBack.INCONCLUSIVE, resolve(firstPage = page(emptyList(), true)))
    }

    @Test
    fun `a read failure is thrown so the caller stays put`() {
        class Cut : Exception()
        try {
            resolve(firstPage = page(listOf(userMessage(50, "a", created + 9)), true)) { throw Cut() }
            fail("a failed page read must not look like absence")
        } catch (thrown: Exception) {
            assertTrue(thrown is Cut)
        }
    }

    @Test
    fun `a cancelled read-back resolves nothing`() {
        try {
            runBlocking {
                coroutineScope {
                    cancel()
                    SendOutboxReadBack.resolve("wanted", created, emptyInbox, page(emptyList(), false)) { JsonNull }
                }
            }
            fail("a cancelled read-back must not return a result")
        } catch (_: CancellationException) {
            // Expected: the entry stays where it is.
        }
    }

    @Test
    fun `the settle delay starts at three seconds doubles and is bounded at 300 seconds`() {
        assertEquals(3_000L, SendOutboxReadBack.settleDelayMs(0))
        assertEquals(3_000L, SendOutboxReadBack.settleDelayMs(1))
        assertEquals(6_000L, SendOutboxReadBack.settleDelayMs(2))
        assertEquals(24_000L, SendOutboxReadBack.settleDelayMs(4))
        assertEquals(192_000L, SendOutboxReadBack.settleDelayMs(7))
        assertEquals(300_000L, SendOutboxReadBack.settleDelayMs(8))
        assertEquals(300_000L, SendOutboxReadBack.settleDelayMs(50))
        assertEquals(3_000L, SendOutboxReadBack.settleDelayMs(-3))
    }
}

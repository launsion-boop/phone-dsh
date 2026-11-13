// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.routines.FakeClock
import com.phonedsh.bot.routines.RoutineError
import com.phonedsh.bot.routines.RoutineTestHarness
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The held-inbox bounds, dedupe, staging state machine and durable replay
 * (D8 §2–§5): 200/20 bounds, request-id dedupe, stage/commit/revert/recover,
 * and `comm.inbound|outbound|reply` as the only snapshot event types.
 */
class WakeInboxStoreTest {
    private val t0 = 1_760_000_000_000L

    private fun item(
        id: String,
        requestId: String? = "req-$id",
        kind: String = "routine-result",
        createdAt: Long = t0,
        text: String = "text-$id",
    ): WakeInboxItem = WakeInboxItem(
        id = id, kind = kind, title = id, text = text, requestId = requestId, createdAt = createdAt,
    )

    @Test
    fun dedupeIsByRequestIdAndSurvivesAReopen() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            val first = harness.inbox.enqueue(item("a"))
            assertEquals(false, first.duplicate)
            // Another item id with the same request id is the same delivery.
            val duplicate = harness.inbox.enqueue(item("b", requestId = "req-a"))
            assertTrue(duplicate.duplicate)
            assertEquals("a", duplicate.item.id)
            assertEquals(1, harness.inbox.items().size)
            // A different request id is a new item.
            val distinct = harness.inbox.enqueue(item("c", requestId = "req-c"))
            assertEquals(false, distinct.duplicate)
            assertEquals(2, harness.reopenedInbox().items().size)
            // Items without a request id are never deduped.
            harness.inbox.enqueue(item("d", requestId = null))
            harness.inbox.enqueue(item("e", requestId = null))
            assertEquals(4, harness.inbox.items().size)
        }
    }

    @Test
    fun theInboxStopsAtTwoHundredItems() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            for (index in 0 until WakeInbox.MAX_ITEMS) {
                harness.inbox.enqueue(item("i$index", requestId = "req-$index"))
            }
            assertEquals(WakeInbox.MAX_ITEMS, harness.inbox.items().size)
            try {
                harness.inbox.enqueue(item("overflow", requestId = "req-overflow"))
                fail("the 201st item must be rejected")
            } catch (error: RoutineError.HeldInboxFull) {
                assertEquals("heldInboxFull", error.code)
                assertEquals(200, error.limit)
                assertEquals(
                    "held inbox is full (200 items); the message was not delivered.",
                    error.message,
                )
            }
            assertEquals(WakeInbox.MAX_ITEMS, harness.inbox.items().size)
            // A duplicate of an existing request id still succeeds on a full inbox.
            assertTrue(harness.inbox.enqueue(item("again", requestId = "req-0")).duplicate)
        }
    }

    @Test
    fun stagePicksByCreatedAtAndIdAndClampsTheLimit() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            for (index in 0 until 25) {
                harness.inbox.enqueue(item("i%02d".format(index), createdAt = t0 + (index % 3)))
            }
            assertNull(harness.inbox.stage(limit = 0, now = t0).key)
            val capped = harness.inbox.stage(limit = 1_000, now = t0 + 10, key = "k1")
            assertEquals(WakeInbox.MAX_STAGE, capped.items.size)
            assertEquals("k1", capped.key)
            assertEquals(capped.items.sortedBy { it.id }, capped.items.sortedBy { it.id })
            assertTrue(capped.items.all { it.state == WakeInboxState.STAGED && it.stagedKey == "k1" })

            // The next stage takes only the remaining five pending items.
            val rest = harness.inbox.stage(limit = 20, now = t0 + 20, key = "k2")
            assertEquals(5, rest.items.size)
            assertEquals(0, harness.inbox.stage(now = t0 + 30).items.size)

            // An empty key is only rejected when there is something to stage
            // (the empty-pending branch returns before the key check).
            harness.inbox.enqueue(item("late", requestId = "req-late"))
            try {
                harness.inbox.stage(now = t0 + 40, key = "")
                fail("an empty staged key must be rejected")
            } catch (error: RoutineError.InvalidHeldItem) {
                assertEquals("stagedKey must not be empty", error.message)
            }
            val pending = harness.inbox.items().filter { it.state == WakeInboxState.PENDING }
            assertEquals(listOf("late"), pending.map { it.id })
        }
    }

    @Test
    fun stageCanFilterByKindAndOrdersByCreatedAtThenId() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.inbox.enqueue(item("z", kind = "agent-held", createdAt = t0 + 2))
            harness.inbox.enqueue(item("a", kind = "agent-held", createdAt = t0 + 2))
            harness.inbox.enqueue(item("m", kind = "routine-result", createdAt = t0 + 1))
            val staged = harness.inbox.stage(now = t0 + 10, key = "agents", kind = "agent-held")
            assertEquals(listOf("a", "z"), staged.items.map { it.id })
            assertEquals(listOf("m"), harness.inbox.items().filter { it.state == WakeInboxState.PENDING }.map { it.id })
        }
    }

    @Test
    fun commitRevertAndRecoverReturnTheStagedItemsToTheRightState() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.inbox.enqueue(item("a"))
            harness.inbox.enqueue(item("b"))
            harness.inbox.enqueue(item("c"))
            harness.inbox.stage(now = t0 + 1, key = "k1")
            harness.inbox.stage(now = t0 + 2, key = "k2")
            assertEquals(0, harness.inbox.commit(null))
            assertEquals(0, harness.inbox.commit(""))
            assertEquals(0, harness.inbox.revert(null))

            assertEquals(3, harness.inbox.recover())
            assertTrue(harness.inbox.items().all { it.state == WakeInboxState.PENDING })
            assertTrue(harness.inbox.items().all { it.stagedAt == null && it.stagedKey == null })

            harness.inbox.stage(now = t0 + 3, key = "k3")
            assertEquals(3, harness.inbox.revert("k3"))
            assertTrue(harness.inbox.items().all { it.state == WakeInboxState.PENDING })

            harness.inbox.stage(now = t0 + 4, key = "k4")
            assertEquals(3, harness.inbox.commit("k4"))
            assertEquals(emptyList<WakeInboxItem>(), harness.inbox.items())
            assertEquals(0, harness.inbox.commit("k4"))
        }
    }

    @Test
    fun recoverCanBeScopedToOneKind() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.inbox.enqueue(item("a", kind = "agent-held"))
            harness.inbox.enqueue(item("b", kind = "routine-result"))
            harness.inbox.stage(now = t0 + 1, key = "k")
            assertEquals(1, harness.inbox.recover(kind = "routine-result"))
            val states = harness.inbox.items().associate { it.id to it.state }
            assertEquals(WakeInboxState.STAGED, states["a"])
            assertEquals(WakeInboxState.PENDING, states["b"])
        }
    }

    @Test
    fun onlyTheFrozenSnapshotEventTypesAreWritten() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.inbox.enqueue(item("a"))
            harness.inbox.stage(now = t0 + 1, key = "k")
            harness.inbox.revert("k")
            harness.inbox.stage(now = t0 + 2, key = "k2")
            harness.inbox.commit("k2")
            assertEquals(
                listOf("comm.inbound", "comm.outbound", "comm.reply", "comm.outbound", "comm.reply"),
                harness.eventTypes(),
            )
            assertEquals(
                listOf(
                    "wake-inbox:enqueue:a",
                    "wake-inbox:stage:k",
                    "wake-inbox:revert:k",
                    "wake-inbox:stage:k2",
                    "wake-inbox:commit:k2",
                ),
                harness.domain.events(0, 100).map { it.eventId },
            )
            for (event in harness.domain.events(0, 100)) {
                assertEquals("main", (event.data as JsonObject).members.let {
                    (it["botId"] as com.phonedsh.agentcore.JsonString).value
                })
            }
        }
    }

    @Test
    fun anUnknownDocumentVersionFailsClosed() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.domain.append(
                com.phonedsh.bot.store.BotEvent(
                    schemaVersion = 1, type = "comm.inbound", eventId = "wake-inbox:future",
                    commitSeq = null, time = t0,
                    origin = com.phonedsh.bot.store.BotEventOrigin.Local("comm-service"),
                    traceId = "trace:future",
                    principal = com.phonedsh.bot.store.BotPrincipal("main", null, "chat", emptyList()),
                    causationId = null, correlationId = "main",
                    data = com.phonedsh.bot.routines.DurableSnapshot.envelope(
                        com.phonedsh.bot.routines.RoutineJson.objectOf(
                            listOf(
                                "version" to com.phonedsh.bot.routines.RoutineJson.number(2),
                                "items" to com.phonedsh.agentcore.JsonArray(emptyList()),
                            ),
                        ),
                        "main",
                    ),
                ),
            )
            try {
                harness.inbox.items()
                fail("version 2 must fail closed")
            } catch (error: com.phonedsh.bot.routines.RoutineDecodeException) {
                assertTrue(error.message!!.contains("unsupported wake inbox snapshot version: 2"))
            }
        }
    }

    @Test
    fun aStagedItemThatWasNeverCommittedIsRecoveredAfterACrash() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.inbox.enqueue(item("a"))
            harness.inbox.stage(now = t0 + 1, key = "k")
            val reopened = harness.reopenedInbox()
            assertEquals(WakeInboxState.STAGED, reopened.items().single().state)
            assertEquals(1, reopened.recover())
            assertNotNull(reopened.items().single())
            assertEquals(WakeInboxState.PENDING, reopened.items().single().state)
        }
    }
}

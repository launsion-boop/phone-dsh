// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.routines.FakeClock
import com.phonedsh.bot.routines.RoutineTestHarness
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

/**
 * Durable write-before-enqueue + replay with dedupe for the device task result
 * notice (v2 §2; `DeviceTaskResultOutbox.swift`).
 */
class DeviceTaskResultTest {
    private val createdAt = 1_760_000_003_000L

    private val notice = DeviceTaskResultNotice(
        deviceID = "device-1",
        deviceDisplayName = "厨房传感器",
        taskID = "task-1",
        idempotencyKey = "settlement-1",
        goal = "检查厨房温度",
        status = DeviceTaskResultNotice.Status.COMPLETED,
        result = "当前 23°C，处于目标区间。",
        createdAt = createdAt,
    )

    private fun independentDigest(deviceID: String, idempotencyKey: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(deviceID.toByteArray(Charsets.UTF_8))
        digest.update(0)
        digest.update(idempotencyKey.toByteArray(Charsets.UTF_8))
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    @Test
    fun theDigestBindsDeviceAndIdempotencyKey() {
        assertEquals(independentDigest("device-1", "settlement-1"), notice.digest)
        assertEquals(notice.digest, notice.copy().digest)
        assertEquals(
            false,
            notice.digest == notice.copy(idempotencyKey = "settlement-2").digest,
        )
        assertEquals(
            false,
            notice.digest == notice.copy(deviceID = "device-2").digest,
        )
        assertEquals("device-task-result:${notice.digest}", DeviceTaskResultOutbox.recordEventID(notice))
        assertEquals(
            "device-task-result-ack:${notice.digest}",
            DeviceTaskResultOutbox.acknowledgementEventID(notice),
        )
    }

    @Test
    fun recordEnqueueAcknowledgeClosesTheWindow() {
        RoutineTestHarness(FakeClock(createdAt)).use { harness ->
            val outbox = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            outbox.record(notice, "main")
            assertEquals(listOf("device-task-result:${notice.digest}"), outbox.pendingEventIDs("main"))
            assertEquals(listOf("comm.inbound"), harness.eventTypes())

            val result = outbox.enqueue(notice, "main", harness.inbox)
            assertFalse(result.duplicate)
            assertEquals(1, harness.inbox.items().size)
            assertEquals(
                listOf("comm.inbound", "comm.inbound", "comm.reply"),
                harness.eventTypes(),
            )
            assertTrue(outbox.pendingEventIDs("main").isEmpty())
            val ack = harness.domain.events(0, 10).last()
            assertEquals(
                "device-task-result:${notice.digest}",
                (ack.data as JsonObject).members.let {
                    (it["deviceTaskResultAck"] as com.phonedsh.agentcore.JsonString).value
                },
            )
            assertEquals("device-task-result:${notice.digest}", ack.causationId)
            assertEquals(notice.requestID, ack.correlationId)
            // No replay after the acknowledgement even if the item is consumed.
            assertEquals(0, outbox.redeliver("main", harness.inbox))
        }
    }

    @Test
    fun recordingTheSameSettlementTwiceWritesOneEvent() {
        RoutineTestHarness(FakeClock(createdAt)).use { harness ->
            val outbox = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            outbox.record(notice, "main")
            val head = harness.eventCount()
            outbox.record(notice, "main")
            assertEquals(head, harness.eventCount())
            assertEquals(listOf("device-task-result:${notice.digest}"), outbox.pendingEventIDs("main"))
        }
    }

    @Test
    fun aCrashBetweenRecordAndEnqueueReplaysExactlyOnce() {
        RoutineTestHarness(FakeClock(createdAt)).use { harness ->
            val crashed = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            crashed.record(notice, "main")
            assertEquals(0, harness.inbox.items().size)

            val restarted = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            assertEquals(1, restarted.redeliver("main", harness.inbox))
            assertTrue(restarted.pendingEventIDs("main").isEmpty())
            assertEquals(1, harness.inbox.items().size)
            assertEquals(notice.itemID, harness.inbox.items()[0].id)
            assertEquals(0, restarted.redeliver("main", harness.inbox))
            assertEquals(1, harness.inbox.items().size)
            assertEquals(1, harness.eventTypes().count { it == "comm.reply" })
        }
    }

    @Test
    fun aCrashBetweenEnqueueAndAckProducesOnlyTheSameItem() {
        RoutineTestHarness(FakeClock(createdAt)).use { harness ->
            val crashed = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            crashed.record(notice, "main")
            // Enqueued but the process died before writing the acknowledgement.
            harness.inbox.enqueue(notice.wakeInboxItem())
            assertEquals(1, harness.inbox.items().size)

            val restarted = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            assertEquals(1, restarted.redeliver("main", harness.inbox))
            assertEquals(1, harness.inbox.items().size)
            assertEquals(notice.itemID, harness.inbox.items()[0].id)
            assertTrue(restarted.pendingEventIDs("main").isEmpty())
            assertEquals(0, restarted.redeliver("main", harness.inbox))
            assertEquals(1, harness.inbox.items().size)
        }
    }

    @Test
    fun anAcknowledgedAndConsumedItemIsNotResurrected() {
        RoutineTestHarness(FakeClock(createdAt)).use { harness ->
            val outbox = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            outbox.enqueue(notice, "main", harness.inbox)
            val staged = harness.inbox.stage(now = createdAt + 1)
            assertNotNull(staged.key)
            assertEquals(1, harness.inbox.commit(staged.key))
            assertEquals(0, harness.inbox.items().size)

            val restarted = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            assertEquals(0, restarted.redeliver("main", harness.inbox))
            assertEquals(0, harness.inbox.items().size)
        }
    }

    @Test
    fun anUnknownOutcomeIsMarkedForReconciliation() {
        RoutineTestHarness(FakeClock(createdAt)).use { harness ->
            val unknown = notice.copy(status = DeviceTaskResultNotice.Status.UNKNOWN_OUTCOME)
            val outbox = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            outbox.record(unknown, "main")
            val record = harness.domain.events(0, 10).first()
            assertEquals(
                true,
                (record.data as JsonObject).members.let { (it["requiresReconciliation"] as JsonBool).value },
            )
            assertEquals("unknown_outcome", (record.data as JsonObject).members.let {
                ((it["deviceTaskResult"] as JsonObject).members["status"] as com.phonedsh.agentcore.JsonString).value
            })
            outbox.enqueue(unknown, "main", harness.inbox)
            assertEquals(1, harness.inbox.items().size)
            assertTrue(outbox.pendingEventIDs("main").isEmpty())
            assertEquals("unknown_outcome", harness.inbox.items()[0].status)
        }
    }

    @Test
    fun pendingReplayIsScopedToOneBot() {
        RoutineTestHarness(FakeClock(createdAt)).use { harness ->
            val outbox = DeviceTaskResultOutbox(harness.domain) { harness.clock.now }
            outbox.record(notice, "main")
            outbox.record(notice.copy(idempotencyKey = "other"), "other")
            assertEquals(1, outbox.pendingEventIDs("main").size)
            assertEquals(1, outbox.pendingEventIDs("other").size)
            assertEquals(1, outbox.redeliver("main", harness.inbox))
            assertTrue(outbox.pendingEventIDs("main").isEmpty())
            assertEquals(1, outbox.pendingEventIDs("other").size)
        }
    }
}

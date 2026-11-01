// P6 — ingress idempotency and ordering (plan §13.7 J2).
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two promises P6 asks the ingress queue to prove:
 *
 *  * the same `request_id` delivered twice executes once (idempotency), even
 *    across a simulated process restart;
 *  * envelopes delivered out of order execute in `seq` order, and a late one is
 *    refused instead of reordering its successor (order).
 *
 * `runBlocking` is used deliberately here: unlike the other fakes in this
 * package, the queue really does suspend (it awaits each delivery), and a test
 * that never yields would claim an ordering guarantee it did not exercise.
 */
class IngressQueueTest {
    private val origin = "device:dev-01"

    private class RecordingSink : IngressSink {
        val delivered = ArrayList<IngressEnvelope>()
        var failOn: String? = null
        var attempts = 0

        override suspend fun deliver(envelope: IngressEnvelope) {
            attempts += 1
            if (envelope.requestId == failOn) throw IllegalStateException("transport down")
            delivered += envelope
        }

        fun requestIds(): List<String> = delivered.map { it.requestId }
    }

    private fun envelope(
        requestId: String,
        seq: Long,
        origin: String = this.origin,
    ): IngressEnvelope = IngressEnvelope(
        origin = origin,
        requestId = requestId,
        seq = seq,
        command = HarnessCommand.Prompt(text = "work for $requestId", requestId = requestId),
    )

    private fun queueWith(
        sink: IngressSink,
        log: IngressLog = InMemoryIngressLog(),
    ): IngressQueue = IngressQueue(log, sink) { 1_700_000_000_000L }

    // ------------------------------------------------------------ idempotency

    @Test
    fun aDuplicateWhileParkedIsAcceptedOnceAndExecutesOnce() {
        val sink = RecordingSink()
        val queue = queueWith(sink)
        queue.adopt(origin, 1)

        assertEquals(IngressAdmission.Accepted, queue.accept(envelope("dev:1", 1)))
        assertEquals(IngressAdmission.Duplicate, queue.accept(envelope("dev:1", 1)))
        assertEquals("only one copy is pending", 1, queue.pendingCount)

        runBlocking { queue.resume() }

        assertEquals(listOf("dev:1"), sink.requestIds())
        assertEquals(0, queue.pendingCount)
    }

    @Test
    fun aDuplicateAfterDeliveryIsDeduplicatedAndNotExecutedAgain() {
        val sink = RecordingSink()
        val queue = queueWith(sink)
        queue.adopt(origin, 1)
        queue.accept(envelope("dev:1", 1))
        runBlocking { queue.resume() }

        assertEquals(IngressAdmission.Duplicate, queue.accept(envelope("dev:1", 1)))
        runBlocking { queue.resume() }

        assertEquals("redelivery after execution must not run the turn twice", 1, sink.attempts)
        assertEquals(listOf("dev:1"), sink.requestIds())
    }

    @Test
    fun aDuplicateAfterARestartIsDeduplicatedByTheLog() {
        val log = InMemoryIngressLog()
        val sink = RecordingSink()
        val before = queueWith(sink, log)
        before.adopt(origin, 1)
        before.accept(envelope("dev:1", 1))
        runBlocking { before.resume() }
        assertEquals(listOf("dev:1"), sink.requestIds())

        // A new process: same durable log, fresh queue. The connector retries.
        val after = queueWith(sink, log)
        assertEquals(IngressAdmission.Duplicate, after.accept(envelope("dev:1", 1)))
        runBlocking { after.resume() }

        assertEquals("the retry across the restart must not execute", 1, sink.attempts)
        assertEquals(listOf("dev:1"), sink.requestIds())
    }

    // ----------------------------------------------------------------- order

    @Test
    fun outOfOrderArrivalExecutesInSeqOrder() {
        val sink = RecordingSink()
        val queue = queueWith(sink)
        queue.adopt(origin, 1)

        // The network delivers 2 and 3 first; 1 is retried last.
        assertEquals(IngressAdmission.Accepted, queue.accept(envelope("dev:2", 2)))
        assertEquals(IngressAdmission.Accepted, queue.accept(envelope("dev:3", 3)))
        assertEquals(IngressAdmission.Accepted, queue.accept(envelope("dev:1", 1)))

        runBlocking { queue.resume() }

        assertEquals(listOf("dev:1", "dev:2", "dev:3"), sink.requestIds())
    }

    @Test
    fun aGapWaitsForTheMissingOrdinalInsteadOfSkippingIt() {
        val sink = RecordingSink()
        val queue = queueWith(sink)
        queue.adopt(origin, 1)

        queue.accept(envelope("dev:1", 1))
        runBlocking { queue.resume() }
        assertEquals(listOf("dev:1"), sink.requestIds())

        queue.accept(envelope("dev:3", 3))
        runBlocking { queue.resume() }
        assertEquals("seq 3 must not jump the hole at seq 2", listOf("dev:1"), sink.requestIds())
        assertEquals(1, queue.pendingCount)

        queue.accept(envelope("dev:2", 2))
        runBlocking { queue.resume() }
        assertEquals(listOf("dev:1", "dev:2", "dev:3"), sink.requestIds())
    }

    @Test
    fun aMessageThatArrivesAfterItsSuccessorExecutedIsRefusedNotReordered() {
        val sink = RecordingSink()
        val queue = queueWith(sink)
        queue.adopt(origin, 1)
        queue.accept(envelope("dev:1", 1))
        queue.accept(envelope("dev:2", 2))
        runBlocking { queue.resume() }
        assertEquals(listOf("dev:1", "dev:2"), sink.requestIds())

        val late = queue.accept(envelope("dev:late", 1))

        val rejected = late as IngressAdmission.Rejected
        assertEquals(IngressRejectionReason.STALE_SEQUENCE, rejected.reason)
        assertTrue("the refusal must name the expected ordinal", rejected.detail.contains("seq >= 3"))
        runBlocking { queue.resume() }
        assertEquals("a stale envelope is never executed", listOf("dev:1", "dev:2"), sink.requestIds())
    }

    @Test
    fun twoRequestIdsClaimingOneOrdinalConflictInsteadOfRacing() {
        val sink = RecordingSink()
        val queue = queueWith(sink)
        queue.adopt(origin, 1)
        assertEquals(IngressAdmission.Accepted, queue.accept(envelope("dev:a", 1)))

        val second = queue.accept(envelope("dev:b", 1))

        val rejected = second as IngressAdmission.Rejected
        assertEquals(IngressRejectionReason.SEQUENCE_CONFLICT, rejected.reason)
        assertTrue(rejected.detail.contains("dev:a"))
        runBlocking { queue.resume() }
        assertEquals("only the first holder of the ordinal runs", listOf("dev:a"), sink.requestIds())
    }

    @Test
    fun originsOrderIndependentlyAndAGapDoesNotBlockTheOther() {
        val sink = RecordingSink()
        val queue = queueWith(sink)
        queue.adopt("device:a", 1)
        queue.adopt("device:b", 1)

        queue.accept(envelope("a:2", 2, origin = "device:a")) // hole at a:1
        queue.accept(envelope("b:1", 1, origin = "device:b"))
        runBlocking { queue.resume() }
        assertEquals("device:b must not wait for device:a's hole", listOf("b:1"), sink.requestIds())

        queue.accept(envelope("a:1", 1, origin = "device:a"))
        runBlocking { queue.resume() }
        assertEquals(listOf("b:1", "a:1", "a:2"), sink.requestIds())
    }

    // -------------------------------------------------- parked / adoption

    @Test
    fun theQueueStartsParkedAndAnUnadoptedOriginIsNotGuessed() {
        val sink = RecordingSink()
        val queue = queueWith(sink)
        assertTrue(queue.parked)
        assertFalse(queue.isAdopted(origin))

        assertEquals(IngressAdmission.Accepted, queue.accept(envelope("dev:1", 1)))
        runBlocking { queue.resume() }
        assertEquals("no baseline, no execution", 0, sink.attempts)
        assertEquals(1, queue.pendingCount)

        queue.adopt(origin, 1)
        runBlocking { queue.resume() }
        assertEquals(listOf("dev:1"), sink.requestIds())
    }

    @Test
    fun parkStopsTheDrainBetweenTwoEnvelopes() {
        val delivered = ArrayList<String>()
        lateinit var queue: IngressQueue
        val sink = object : IngressSink {
            override suspend fun deliver(envelope: IngressEnvelope) {
                delivered += envelope.requestId
                // The host notices the session stopped mid-drain.
                if (envelope.requestId == "dev:1") queue.park()
            }
        }
        queue = IngressQueue(InMemoryIngressLog(), sink)
        queue.adopt(origin, 1)
        queue.accept(envelope("dev:1", 1))
        queue.accept(envelope("dev:2", 2))

        runBlocking { queue.resume() }

        assertEquals("park() must stop before the next envelope", listOf("dev:1"), delivered)
        assertEquals(1, queue.pendingCount)

        runBlocking { queue.resume() }
        assertEquals(listOf("dev:1", "dev:2"), delivered)
    }

    // ------------------------------------------------ at-least-once retry

    @Test
    fun aFailedDeliveryStaysPendingAndRetriesWithoutSkippingAhead() {
        val sink = RecordingSink()
        sink.failOn = "dev:2"
        val queue = queueWith(sink)
        queue.adopt(origin, 1)
        queue.accept(envelope("dev:1", 1))
        queue.accept(envelope("dev:2", 2))
        queue.accept(envelope("dev:3", 3))

        val failure = assertThrows(IllegalStateException::class.java) {
            runBlocking { queue.resume() }
        }
        assertEquals("transport down", failure.message)
        assertEquals("dev:3 must not run past the failure", listOf("dev:1"), sink.requestIds())
        assertEquals("the failed envelope and its successor are still pending", 2, queue.pendingCount)
        val recorded = requireNotNull(queue.lastFailure())
        assertEquals("dev:2", recorded.requestId)
        assertEquals(origin, recorded.origin)

        sink.failOn = null
        runBlocking { queue.resume() }

        assertEquals(listOf("dev:1", "dev:2", "dev:3"), sink.requestIds())
        assertNull("a clean drain clears the failure record", queue.lastFailure())
    }

    // ------------------------------------------------- harness integration

    @Test
    fun theHarnessSinkSendsExactlyOneCommandPerAcceptedRequestIdInOrder() {
        val harness = FakeHarness()
        val queue = IngressQueue(
            InMemoryIngressLog(),
            HarnessIngressSink(harness, sessionId = "sess-ingress"),
        )
        queue.adopt(origin, 1)

        queue.accept(envelope("dev:1", 1))
        queue.accept(envelope("dev:1", 1)) // connector retry
        queue.accept(envelope("dev:2", 2))
        runBlocking { queue.resume() }

        val sent = harness.deliveredCommands().mapNotNull { it.requestId }
        assertEquals(listOf("dev:1", "dev:2"), sent)
        assertEquals(1, harness.executionsOf("dev:1"))
        assertEquals(1, harness.executionsOf("dev:2"))
    }

    @Test
    fun anEnvelopeWithoutAUsableKeyIsRejectedAtConstruction() {
        assertThrows(IllegalArgumentException::class.java) {
            IngressEnvelope(origin = "", requestId = "dev:1", seq = 1, command = HarnessCommand.Cancel)
        }
        assertThrows(IllegalArgumentException::class.java) {
            IngressEnvelope(origin = origin, requestId = "", seq = 1, command = HarnessCommand.Cancel)
        }
        assertThrows(IllegalArgumentException::class.java) {
            IngressEnvelope(origin = origin, requestId = "dev:1", seq = -1, command = HarnessCommand.Cancel)
        }
    }
}

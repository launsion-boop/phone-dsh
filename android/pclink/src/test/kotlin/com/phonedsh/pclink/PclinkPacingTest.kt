// SPDX-License-Identifier: MIT
// §3.8 sender pacing: the reference constants (also the golden `chunking`
// limits) and the pure token bucket — wait, never drop; full-bucket overdraft
// for one frame larger than the burst; monotonic refill.
package com.phonedsh.pclink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkPacingTest {
    @Test
    fun referenceValuesSitUnderTheRelayBucketAndMatchTheGoldenLimits() {
        val chunking = TestSupport.at(TestSupport.vectors(), "chunking")
            ?: throw AssertionError("missing chunking")
        assertEquals("threshold", TestSupport.requireInt(chunking, "threshold_bytes"),
            PclinkLimits.CHUNK_THRESHOLD_BYTES.toLong())
        assertEquals("max value", TestSupport.requireInt(chunking, "max_value_bytes"),
            PclinkLimits.MAX_VALUE_BYTES.toLong())
        assertEquals("max frame", TestSupport.requireInt(chunking, "max_frame_bytes"),
            PclinkLimits.MAX_RELAY_FRAME_BYTES.toLong())
        assertEquals("seq rekey", TestSupport.requireInt(chunking, "seq_rekey"),
            PclinkLimits.SOFT_FRAME_THRESHOLD)
        assertEquals("seq max", TestSupport.requireInt(chunking, "seq_max"),
            PclinkLimits.HARD_FRAME_THRESHOLD)
        assertEquals("byte rekey", TestSupport.requireInt(chunking, "byte_rekey"),
            PclinkLimits.SOFT_BYTE_THRESHOLD)
        assertEquals("byte hard", TestSupport.requireInt(chunking, "byte_hard"),
            PclinkLimits.HARD_BYTE_THRESHOLD)

        // §3.8: the local bucket must not exceed the relay's pair defaults
        // (1 MiB/s, 4 MiB burst); this revision's reference leaves margin.
        val relayRate = 1.0 * 1_048_576
        val relayBurst = 4.0 * 1_048_576
        assertTrue("rate margin", PclinkLimits.SEND_RATE_BYTES_PER_SECOND < relayRate)
        assertTrue("burst margin", PclinkLimits.SEND_BURST_BYTES < relayBurst)
        assertEquals(PclinkLimits.SEND_RATE_BYTES_PER_SECOND,
            PclinkPacer.REFERENCE_RATE_BYTES_PER_SECOND, 0.0)
        assertEquals(PclinkLimits.SEND_BURST_BYTES,
            PclinkPacer.REFERENCE_BURST_BYTES, 0.0)
        assertEquals("0.9 MiB/s", 0.9 * 1_048_576,
            PclinkPacer.REFERENCE_RATE_BYTES_PER_SECOND, 1e-9)
        assertEquals("3.5 MiB burst", 3.5 * 1_048_576,
            PclinkPacer.REFERENCE_BURST_BYTES, 1e-9)
    }

    @Test
    fun pacerWaitsForTokensInsteadOfDropping() {
        val pacer = PclinkPacer(rateBytesPerSecond = 1_000.0, burstBytes = 2_000.0)
        val start = 1_000_000_000L
        for (index in 0 until 2) {
            assertEquals("frame $index immediate", 0L, pacer.delayBeforeSending(1_000, start))
            pacer.consume(1_000, start)
            assertEquals("bucket after frame $index", 2_000.0 - (index + 1) * 1_000.0,
                pacer.availableTokens, 1e-9)
        }
        // Empty bucket: the next 1,000-byte frame waits one second; it is not lost.
        assertEquals(1_000_000_000L, pacer.delayBeforeSending(1_000, start))
        assertEquals(0L, pacer.delayBeforeSending(1_000, start + 1_000_000_000L))
        assertEquals("one second of refill", 1_000.0, pacer.availableTokens, 1e-9)
        pacer.consume(1_000, start + 1_000_000_000L)
        assertEquals(0.0, pacer.availableTokens, 1e-9)
    }

    @Test
    fun pacerOverdrawsOneOversizedFrameFromAFullBucket() {
        val pacer = PclinkPacer(rateBytesPerSecond = 1_000.0, burstBytes = 2_000.0)
        val start = 0L
        assertEquals(0L, pacer.delayBeforeSending(3_000, start))
        pacer.consume(3_000, start)
        assertEquals(-1_000.0, pacer.availableTokens, 1e-9)
        // Two seconds of refill pays the debt; the balance then recovers to burst.
        assertEquals(0L, pacer.delayBeforeSending(1_000, start + 2_000_000_000L))
        pacer.consume(1_000, start + 2_000_000_000L)
        assertEquals(0.0, pacer.availableTokens, 1e-9)
        pacer.refill(start + 10_000_000_000L)
        assertEquals(2_000.0, pacer.availableTokens, 1e-9)

        // A partly drained bucket must wait for a full bucket before overdraft.
        val partial = PclinkPacer(rateBytesPerSecond = 1_000.0, burstBytes = 2_000.0)
        assertEquals(0L, partial.delayBeforeSending(1_000, start))
        partial.consume(1_000, start)
        assertEquals(1_000_000_000L, partial.delayBeforeSending(3_000, start))
    }

    @Test
    fun refillIsMonotonicAndClamped() {
        var now = 5_000_000_000L
        val pacer = PclinkPacer(
            rateBytesPerSecond = 1_000.0,
            burstBytes = 2_000.0,
            clockNanos = { now },
        )
        assertEquals(0L, pacer.delayBeforeSending(1_500))
        // First observation starts the clock and keeps the full bucket.
        assertEquals(2_000.0, pacer.availableTokens, 1e-9)
        pacer.consume(1_500)
        assertEquals(500.0, pacer.availableTokens, 1e-9)
        now += 1_000_000_000L
        pacer.refill()
        assertEquals(1_500.0, pacer.availableTokens, 1e-9)
        now += 10_000_000_000L
        pacer.refill()
        assertEquals("never above burst", 2_000.0, pacer.availableTokens, 1e-9)
        // A clock that goes backwards must not create tokens.
        now -= 5_000_000_000L
        pacer.refill()
        assertEquals(2_000.0, pacer.availableTokens, 1e-9)
    }

    @Test
    fun nonPositivePacingValuesAreRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            PclinkPacer(rateBytesPerSecond = 0.0, burstBytes = 1.0)
        }
        assertThrows(IllegalArgumentException::class.java) {
            PclinkPacer(rateBytesPerSecond = 1.0, burstBytes = -1.0)
        }
    }

    private fun assertThrows(type: Class<out Throwable>, block: () -> Unit) {
        try {
            block()
            throw AssertionError("expected ${type.simpleName}")
        } catch (thrown: Throwable) {
            if (!type.isInstance(thrown)) throw thrown
        }
    }
}

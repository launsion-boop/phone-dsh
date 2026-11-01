// phone-dsh — :engine / com.phonedsh.engine: channel counters + HELLO summary, JVM.
// SPDX-License-Identifier: MIT
//
// The codec is the Rust one on device; here a fake decoder returns the canonical
// JSON shape WireCodec.decode() produces, so this test proves the engine's own
// behaviour (counting, labelling, merging both HELLOs, safe failure) without
// re-implementing or faking the codec itself. The real codec path is exercised on
// the emulator by WebViewEngineInstrumentedTest.

package com.phonedsh.engine

import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.wire.WireUnavailable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChannelTelemetryTest {
    private val logger = RecordingEngineLogger()

    /** `channel.md` §4.1 worker HELLO, canonical JSON as the Rust codec returns it. */
    private val workerHello = """
        {"boot_id":"00112233445566778899aabbccddeeff",
         "caps":["channel/1","vfs-sink/1","journal/1","api/1"],
         "fence":{"generation":0,"owner":"phone","wal_seq":0},
         "last_mseq":41,"proto":1,"role":"worker","session_epoch":1}
    """.trimIndent().replace("\n", "").replace(" ", "")

    /** `channel.md` §4.1 host HELLO, canonical JSON. */
    private val hostHello = """
        {"acked_mseq":41,"boot_id":"00112233445566778899aabbccddeeff",
         "caps":["channel/1","wal/1","exec/1","accelerator:rg"],
         "durable_mseq":41,
         "fence":{"generation":0,"owner":"phone","wal_seq":0},
         "next_mseq":42,"proto":1,"role":"host","session_epoch":1}
    """.trimIndent().replace("\n", "").replace(" ", "")

    @Test
    fun countsFramesInBothDirectionsAndLabelsTheirTypes() {
        val telemetry = ChannelTelemetry(decoder = { error("not used") }, logger = logger, clock = { 7L })

        telemetry.onChannelOpen()
        telemetry.onInbound(frame(0x10))
        telemetry.onInbound(frame(0x12))
        telemetry.onOutbound(frame(0x11))

        val status = telemetry.status.value
        assertTrue(status.connected)
        assertEquals(2L, status.framesFromWorker)
        assertEquals(1L, status.framesToWorker)
        assertEquals("VFS_ACK", status.lastFrameType)
        assertNull(status.lastError)
    }

    @Test
    fun decodesTheWorkerHelloAndPublishesTheSummary() {
        val telemetry = ChannelTelemetry(
            decoder = { payload -> assertEquals(17, payload.size); workerHello },
            logger = logger,
            clock = { 1234L },
        )
        val payload = frame(0x01, byteArrayOf(1))

        telemetry.onInbound(payload)

        val summary = telemetry.handshake.value
        assertNotNull(summary)
        assertEquals(1, summary!!.proto)
        assertEquals(listOf("channel/1", "vfs-sink/1", "journal/1", "api/1"), summary.workerCapabilities)
        assertEquals(emptyList<String>(), summary.hostCapabilities)
        assertEquals(0L, summary.nextMseq)
        assertEquals(0L, summary.ackedMseq)
        assertEquals(1234L, summary.receivedAtMillis)
        assertEquals("HELLO", telemetry.status.value.lastFrameType)
    }

    @Test
    fun mergesTheHostHelloIntoTheSameSummary() {
        var json = workerHello
        val telemetry = ChannelTelemetry(decoder = { json }, logger = logger, clock = { 1234L })
        telemetry.onInbound(frame(0x01, byteArrayOf(1)))

        json = hostHello
        telemetry.onOutbound(frame(0x01, byteArrayOf(2)))

        val summary = telemetry.handshake.value!!
        assertEquals(1, summary.proto)
        assertEquals(
            listOf("channel/1", "wal/1", "exec/1", "accelerator:rg"),
            summary.hostCapabilities,
        )
        assertEquals(listOf("channel/1", "vfs-sink/1", "journal/1", "api/1"), summary.workerCapabilities)
        assertEquals(42L, summary.nextMseq)
        assertEquals(41L, summary.ackedMseq)
        assertEquals(1234L, summary.receivedAtMillis) // first HELLO time, not the host one
        assertEquals(1L, telemetry.status.value.framesToWorker)
        assertTrue(logger.contains("handshake: proto=1"))
    }

    @Test
    fun unknownAndShortFramesAreLabelsNotExceptions() {
        val telemetry = ChannelTelemetry(decoder = { error("not used") }, logger = logger)

        telemetry.onInbound(frame(0x7E))
        assertEquals("UNKNOWN(0x7E)", telemetry.status.value.lastFrameType)

        telemetry.onInbound(byteArrayOf(0x5A, 0x4C))
        assertEquals(FrameType.MALFORMED, telemetry.status.value.lastFrameType)
        assertNull(telemetry.handshake.value)
    }

    @Test
    fun aMissingNativeLibraryKeepsTheEngineRunning() {
        val telemetry = ChannelTelemetry(
            decoder = { throw WireUnavailable(UnsatisfiedLinkError("no libpdsh_jni for this ABI")) },
            logger = logger,
        )

        telemetry.onInbound(frame(0x01, byteArrayOf(1))) // must not throw

        assertNull(telemetry.handshake.value)
        val lastError = telemetry.status.value.lastError
        assertNotNull(lastError)
        assertTrue(lastError!!, lastError.contains("libpdsh_jni not packaged"))
        assertEquals(1L, telemetry.status.value.framesFromWorker)
    }

    @Test
    fun aWireExceptionIsReportedByCodeOnly() {
        val telemetry = ChannelTelemetry(
            decoder = { throw com.phonedsh.wire.WireException("BAD_MAGIC", "magic mismatch") },
            logger = logger,
        )

        telemetry.onInbound(frame(0x01, byteArrayOf(1)))

        assertEquals("hello decode failed (BAD_MAGIC)", telemetry.status.value.lastError)
        assertNull(telemetry.handshake.value)
    }

    @Test
    fun closeReportsATransportLossAndStopClearsTheHandshake() {
        val json = workerHello
        val telemetry = ChannelTelemetry(decoder = { json }, logger = logger)
        telemetry.onChannelOpen()
        telemetry.onInbound(frame(0x01, byteArrayOf(1)))

        telemetry.onChannelClosed(ChannelCloseCause.TRANSPORT_LOST)
        assertEquals(false, telemetry.status.value.connected)
        assertEquals("channel lost (transport)", telemetry.status.value.lastError)

        telemetry.onEngineStopped()
        assertNull(telemetry.handshake.value)
        // Counters survive the stop so the last screen keeps showing them.
        assertEquals(1L, telemetry.status.value.framesFromWorker)
    }

    /**
     * P22: a page-initiated close is *the* close that kills the channel, and it used
     * to be the only one that left no reason on the screen (`CLIENT_CLOSED` was
     * mapped to `null`). The status now names it.
     */
    @Test
    fun aPageInitiatedCloseNamesItselfInsteadOfStayingSilent() {
        val telemetry = ChannelTelemetry(decoder = { error("not used") }, logger = logger)
        telemetry.onChannelOpen()
        telemetry.noteError("renderer gone")

        telemetry.onChannelClosed(ChannelCloseCause.CLIENT_CLOSED)

        assertEquals(false, telemetry.status.value.connected)
        assertEquals(
            "channel closed by the page (client_closed)",
            telemetry.status.value.lastError,
        )
    }

    @Test
    fun aServerStopKeepsTheLastErrorInsteadOfInventingOne() {
        val telemetry = ChannelTelemetry(decoder = { error("not used") }, logger = logger)
        telemetry.onChannelOpen()
        telemetry.noteError("renderer gone")

        telemetry.onChannelClosed(ChannelCloseCause.SERVER_STOPPED)

        assertEquals(false, telemetry.status.value.connected)
        assertEquals("renderer gone", telemetry.status.value.lastError)
    }

    @Test
    fun resetForStartClearsEverything() {
        val json = workerHello
        val telemetry = ChannelTelemetry(decoder = { json }, logger = logger)
        telemetry.onChannelOpen()
        telemetry.onInbound(frame(0x01, byteArrayOf(1)))

        telemetry.resetForStart()

        assertNull(telemetry.handshake.value)
        assertEquals(
            ChannelStatus(false, 0, 0, null, null),
            telemetry.status.value,
        )
    }

    /** A `channel.md` §1 frame with a type byte and a one-byte payload. */
    private fun frame(type: Int, payload: ByteArray = byteArrayOf(0)): ByteArray {
        val header = ByteArray(16)
        header[0] = 0x5A
        header[1] = 0x4C
        header[2] = type.toByte()
        header[15] = payload.size.toByte()
        return header + payload
    }
}

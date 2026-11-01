// phone-dsh — :dsh unit test: inbound seq enforcement (channel.md §7.2, §7.4).
// SPDX-License-Identifier: MIT
//
// Before this lane, `HostChannel` routed every frame without looking at its
// `seq`: a worker could repeat, skip or regress a number and the host would
// answer as if the connection were in order. These tests drive real frames
// through the real router and assert the §10 answer — one closing `BAD_SEQ`
// naming the offending frame — plus the two special cases the rule must not
// break: a continuous sequence is never reported, and a frame that arrives
// before the host HELLO does not open the inbound space (so the worker's HELLO
// still starts it at seq 1).
//
// JNI prerequisite, as for every `:dsh` wire test:
//   cd shell && cargo build -p pdsh-jni

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HostChannelSeqTest {
    // ---- 1. a gap answers BAD_SEQ and closes --------------------------------

    @Test
    fun aGapInInboundSeqAnswersOneBadSeqErrorAndCloses() {
        FakePlatform().use { platform ->
            val host = newHost(platform)
            start(host)
            try {
                val connection = connect(host)

                // HELLO was 1, so the next inbound frame must be 2; 3 is a gap.
                runBlocking { host.channel.onBinary(connection, consoleFrame("skipped", seq = 3L)) }

                val error = errorFields(connection).single()
                assertEquals("BAD_SEQ", error.getString("code"))
                assertEquals(3L, error.getLong("ref_seq"))
                assertEquals("expected seq 2, got 3", error.getString("message"))
                assertEquals(1, connection.closes.size)
                assertEquals(1002.toShort(), connection.closes.single().first)
                assertEquals("BAD_SEQ", connection.closes.single().second)
                assertEquals("host HELLO + the one ERROR", 2, connection.sent.size)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 2. a continuous sequence is not reported ---------------------------

    @Test
    fun aContinuousInboundSeqIsNotReported() {
        FakePlatform().use { platform ->
            val host = newHost(platform)
            start(host)
            try {
                val connection = connect(host)
                runBlocking {
                    host.channel.onBinary(connection, consoleFrame("two", seq = 2L))
                    host.channel.onBinary(connection, consoleFrame("three", seq = 3L))
                    host.channel.onBinary(connection, barrierFrame(seq = 4L))
                }

                assertTrue("no protocol ERROR for a legal sequence", errorFields(connection).isEmpty())
                assertTrue("the connection stays open", connection.closes.isEmpty())
                assertEquals("only the host HELLO was sent", 1, connection.sent.size)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 3. a duplicate / regression answers BAD_SEQ -----------------------

    @Test
    fun aDuplicateSeqAnswersBadSeqAndCloses() {
        FakePlatform().use { platform ->
            val host = newHost(platform)
            start(host)
            try {
                val connection = connect(host)
                runBlocking {
                    host.channel.onBinary(connection, consoleFrame("first", seq = 2L))
                    host.channel.onBinary(connection, consoleFrame("again", seq = 2L))
                }

                val error = errorFields(connection).single()
                assertEquals("BAD_SEQ", error.getString("code"))
                assertEquals(2L, error.getLong("ref_seq"))
                assertEquals(1, connection.closes.size)
                assertEquals("BAD_SEQ", connection.closes.single().second)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 4. a first-frame HELLO at another seq is BAD_SEQ -------------------

    @Test
    fun aFirstHelloAtAnotherSeqAnswersBadSeqWithoutSendingTheHostHello() {
        FakePlatform().use { platform ->
            val host = newHost(platform)
            start(host)
            try {
                val connection = RecordingLoopbackConnection("seq-hello")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame(seq = 2L))
                }

                val error = errorFields(connection).single()
                assertEquals("BAD_SEQ", error.getString("code"))
                assertEquals(2L, error.getLong("ref_seq"))
                assertEquals(0L, host.channel.framesToWorker)
                assertEquals(1, connection.closes.size)
                assertEquals("BAD_SEQ", connection.closes.single().second)
            } finally {
                host.stop()
            }
        }
    }

    // ---- 5. a pre-HELLO frame does not open the inbound space --------------

    @Test
    fun aFrameBeforeTheHostHelloDoesNotAdvanceTheInboundSpace() {
        FakePlatform().use { platform ->
            val host = newHost(platform)
            start(host)
            try {
                val connection = RecordingLoopbackConnection("seq-pre-hello")
                runBlocking {
                    host.channel.onOpen(connection)
                    // Ignored by the per-lane gate, and it must not consume seq 7.
                    host.channel.onBinary(connection, barrierFrame(seq = 7L))
                    host.channel.onBinary(connection, workerHelloFrame())
                    host.channel.onBinary(connection, consoleFrame("after", seq = 2L))
                }

                assertTrue("the pre-HELLO frame is not an ERROR", errorFields(connection).isEmpty())
                assertTrue("the connection stays open", connection.closes.isEmpty())
                assertEquals("one host HELLO, no ERROR", 1, connection.sent.size)
                assertEquals(1L, host.channel.framesToWorker)
            } finally {
                host.stop()
            }
        }
    }

    // ---- helpers ------------------------------------------------------------

    private fun newHost(platform: FakePlatform): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = ControllerStateMachine.boot(persistedState = null),
        clock = platform,
        signals = platform,
        notifier = platform,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = HostLog.None,
    )

    private fun start(host: DefaultPhoneDshHost) {
        host.start()
        runBlocking { withTimeout(5_000) { host.ready.first { it } } }
    }

    private fun connect(host: DefaultPhoneDshHost): RecordingLoopbackConnection {
        val connection = RecordingLoopbackConnection("seq-test")
        runBlocking {
            host.channel.onOpen(connection)
            host.channel.onBinary(connection, workerHelloFrame())
        }
        return connection
    }

    private fun consoleFrame(text: String, seq: Long): ByteArray = WireCodec.encode(
        """{"type":"CONSOLE","fields":{"level":"info","text":"$text"}}""",
        seq,
    )

    private fun barrierFrame(seq: Long): ByteArray = WireCodec.encode(
        """{"type":"VFS_BARRIER","fields":{"upto_mseq":0,"want_level":1}}""",
        seq,
    )

    private fun errorFields(connection: RecordingLoopbackConnection): List<JSONObject> =
        connection.sent
            .filter { HostFrame.typeOf(it) == ERROR }
            .map { JSONObject(WireCodec.decode(it)) }

    private companion object {
        /** `channel.md` §2: ERROR (`0x7F`). */
        const val ERROR = 0x7F
    }
}

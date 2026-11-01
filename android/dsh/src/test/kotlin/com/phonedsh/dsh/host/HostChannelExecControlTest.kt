// phone-dsh — :dsh unit test: HostChannel dispatches EXEC_CTL (`0x22`).
// SPDX-License-Identifier: MIT
//
// `ExecControlTest` proves what the bridge does with one decoded control. This
// test proves the router half that was missing: a real `0x22` frame through the
// real `HostChannel`, with the frames the host puts back on the wire asserted.
// There are exactly four observable outcomes (channel.md §4.4 has no reply
// frame), and each one is pinned here:
//
//   * applied cancel — the terminal `exit` arrives from the live `EXEC_EVT`
//     stream the `EXEC_REQ` collector is already sending; the host adds no
//     frame of its own (a second terminal event would be a protocol error);
//   * refused stdin on a live execution — same rule, one terminal `error` from
//     the stream and no extra frame;
//   * `Emit` (stdin for an execution that is not live) — the host frames the
//     standalone terminal `EXEC_EVT` itself, because no stream exists;
//   * `Ignored` (cancel that names nothing) — nothing at all is sent.
//
// A control that cannot be decoded, or whose `op`/`exec_id`/`data` is invalid,
// is one closing `BAD_PAYLOAD` ERROR naming the frame's `seq` (`channel.md`
// §10), and one that arrives before the host HELLO is ignored.
//
// JNI prerequisite, as for every `:dsh` wire test:
//   cd shell && cargo build -p pdsh-jni

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.exec.ExecBridge
import com.phonedsh.dsh.exec.ExecFixtures
import com.phonedsh.dsh.exec.GatedTool
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HostChannelExecControlTest {
    @Test
    fun anAppliedCancelRidesTheLiveStreamAndAddsNoFrame() {
        FakePlatform().use { platform ->
            val tool = GatedTool()
            val bridge = ExecFixtures.bridge(tool = tool, name = PHONE)
            val host = newHost(platform, bridge)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("exec-ctl-cancel")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                    // The EXEC_REQ collector runs until the execution's stream
                    // ends, so the control must be sent from another coroutine.
                    val request = async {
                        host.channel.onBinary(
                            connection,
                            execRequestFrame(ExecFixtures.EXEC_ID, ExecFixtures.IDEM_A),
                        )
                    }
                    withTimeout(5_000) { tool.started.await() }
                    host.channel.onBinary(
                        connection,
                        cancelFrame(ExecFixtures.EXEC_ID, seq = 3L),
                    )
                    withTimeout(5_000) { request.await() }
                }

                assertTrue("no protocol ERROR", connection.closes.isEmpty())
                val events = execEvents(connection)
                assertEquals(
                    "cancel is applied by the live stream, not re-sent by the host",
                    listOf("start", "exit"),
                    events.map { it.getString("type") },
                )
                assertEquals("cancelled", events.last().getString("status"))
                assertEquals(2L, host.channel.execFramesToWorker)

                tool.release()
                runBlocking { withTimeout(5_000) { tool.finished.await() } }
                assertEquals(
                    "the tool's late result must not produce another frame",
                    2,
                    execEvents(connection).size,
                )
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun aRefusedStdinControlOnALiveStreamAddsNoFrame() {
        FakePlatform().use { platform ->
            val tool = GatedTool()
            val bridge = ExecFixtures.bridge(tool = tool, name = PHONE)
            val host = newHost(platform, bridge)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("exec-ctl-stdin-live")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                    val request = async {
                        host.channel.onBinary(
                            connection,
                            execRequestFrame(ExecFixtures.EXEC_ID, ExecFixtures.IDEM_A),
                        )
                    }
                    withTimeout(5_000) { tool.started.await() }
                    host.channel.onBinary(
                        connection,
                        controlFrame(
                            """{"exec_id":"${ExecFixtures.EXEC_ID}","op":"stdin","data":"aGVsbG8K"}""",
                            seq = 3L,
                        ),
                    )
                    withTimeout(5_000) { request.await() }
                }

                assertTrue("no protocol ERROR", connection.closes.isEmpty())
                val events = execEvents(connection)
                assertEquals(
                    "the refusal is the stream's terminal error, not a second frame",
                    listOf("start", "error"),
                    events.map { it.getString("type") },
                )
                assertEquals(ExecBridge.CODE_UNSUPPORTED, events.last().getString("code"))

                tool.release()
                runBlocking { withTimeout(5_000) { tool.finished.await() } }
                assertEquals(2, execEvents(connection).size)
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun aStdinControlWithoutALiveStreamEmitsOneStandaloneTerminalEvent() {
        FakePlatform().use { platform ->
            val bridge = ExecFixtures.bridge(tool = GatedTool(), name = PHONE)
            val host = newHost(platform, bridge)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("exec-ctl-stdin-orphan")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                    host.channel.onBinary(
                        connection,
                        controlFrame(
                            """{"exec_id":"${ExecFixtures.EXEC_ID}","op":"stdin","data":"aGVsbG8K"}""",
                        ),
                    )
                }

                assertTrue("no protocol ERROR", connection.closes.isEmpty())
                val events = execEvents(connection)
                val error = events.single()
                assertEquals("error", error.getString("type"))
                assertEquals(ExecFixtures.EXEC_ID, error.getString("exec_id"))
                assertEquals(0L, error.getLong("seq"))
                assertEquals(ExecBridge.CODE_UNSUPPORTED, error.getString("code"))
                assertEquals("one standalone EXEC_EVT, framed by the host", 1L, host.channel.execFramesToWorker)
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun aCancelThatNamesNothingIsIgnoredSilently() {
        FakePlatform().use { platform ->
            val bridge = ExecFixtures.bridge(tool = GatedTool(), name = PHONE)
            val host = newHost(platform, bridge)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("exec-ctl-ignored")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                    host.channel.onBinary(connection, cancelFrame(ExecFixtures.EXEC_ID))
                }

                assertTrue("no protocol ERROR", connection.closes.isEmpty())
                assertEquals("only the host HELLO was sent", 1, connection.sent.size)
                assertEquals(0L, host.channel.execFramesToWorker)
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun aMalformedControlIsOneClosingBadPayloadError() {
        FakePlatform().use { platform ->
            val bridge = ExecFixtures.bridge(tool = GatedTool(), name = PHONE)
            val host = newHost(platform, bridge)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("exec-ctl-bad")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                    // `op` is not in the §4.4 domain; the frame itself is legal.
                    host.channel.onBinary(
                        connection,
                        controlFrame("""{"exec_id":"${ExecFixtures.EXEC_ID}","op":"pause"}"""),
                    )
                }

                assertEquals("exactly one ERROR", 2, connection.sent.size)
                val error = JSONObject(WireCodec.decode(connection.sent.last()))
                assertEquals("BAD_PAYLOAD", error.getString("code"))
                assertEquals(2L, error.getLong("ref_seq"))
                assertEquals(1, connection.closes.size)
                assertEquals(1002.toShort(), connection.closes.single().first)
                assertEquals("BAD_PAYLOAD", connection.closes.single().second)
                assertEquals(0L, host.channel.execFramesToWorker)
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun aControlBeforeTheHostHelloIsIgnored() {
        FakePlatform().use { platform ->
            val bridge = ExecFixtures.bridge(tool = GatedTool(), name = PHONE)
            val host = newHost(platform, bridge)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("exec-ctl-before-hello")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, cancelFrame(ExecFixtures.EXEC_ID))
                }

                assertTrue("no frame may precede the host HELLO", connection.sent.isEmpty())
                assertTrue("and no ERROR either", connection.closes.isEmpty())
            } finally {
                host.stop()
            }
        }
    }

    // ---- helpers ------------------------------------------------------------

    private fun newHost(platform: FakePlatform, bridge: ExecBridge): DefaultPhoneDshHost =
        DefaultPhoneDshHost(
            engine = platform.engine,
            controller = ControllerStateMachine.boot(persistedState = null),
            clock = platform,
            signals = platform,
            notifier = platform,
            exec = bridge,
            scope = CoroutineScope(Dispatchers.Unconfined),
            logger = HostLog.None,
        )

    private fun execEvents(connection: RecordingLoopbackConnection): List<JSONObject> =
        connection.sent
            .filter { HostFrame.typeOf(it) == HostFrame.EXEC_EVT }
            .map { JSONObject(WireCodec.decode(it)) }

    private fun execRequestFrame(execId: String, idemKey: String): ByteArray = WireCodec.encode(
        """
        {"type":"EXEC_REQ","fields":{
          "argv":["$PHONE","info"],
          "cwd":"/dsh/workspace",
          "exec_id":"$execId",
          "idem_key":"$idemKey",
          "requires_mseq":0
        }}
        """.trimIndent(),
        seq = 2L,
    )

    private fun cancelFrame(execId: String, seq: Long = 2L): ByteArray =
        controlFrame("""{"exec_id":"$execId","op":"cancel"}""", seq = seq)

    private fun controlFrame(fieldsJson: String, seq: Long = 2L): ByteArray = WireCodec.encode(
        """{"type":"EXEC_CTL","fields":$fieldsJson}""",
        seq = seq,
    )

    private companion object {
        /** The one advertised accelerator; `argv[0]` must name it. */
        const val PHONE: String = "phone"
    }
}

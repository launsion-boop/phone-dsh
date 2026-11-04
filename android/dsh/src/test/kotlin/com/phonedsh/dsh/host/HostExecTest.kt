// phone-dsh — :dsh unit test: exec/1 → phone info, end to end.
// SPDX-License-Identifier: MIT
//
// One real `0x20 EXEC_REQ` goes through the real `HostChannel`, the J2
// `ExecBridge` and the `phone` accelerator, and the resulting `0x21 EXEC_EVT`
// frames are decoded with the Rust codec. No process, no WebView, no Android:
// `PhoneInfoTool` gets a fixed `PhoneInfoSource`, so the test proves the argv →
// tool → result-contract → events path rather than the device model string.
//
// JNI prerequisite, as for every `:dsh` HELLO test:
//   cd shell && cargo build -p pdsh-jni

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.exec.AdmissionGate
import com.phonedsh.dsh.exec.ExecBridge
import com.phonedsh.dsh.exec.ExecCapability
import com.phonedsh.dsh.exec.ExecFixtures
import com.phonedsh.dsh.exec.ExecWorkspace
import com.phonedsh.dsh.tools.PhoneTool
import com.phonedsh.dsh.tools.RegisteredTool
import com.phonedsh.dsh.tools.ToolOutcome
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import java.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HostExecTest {
    @Test
    fun phoneInfoRunsWithARealExecRequestAndReturnsStartAndExit() {
        FakePlatform().use { platform ->
            val source = PhoneInfoSource { """{"model":"fake-device","sdk":35}""" }
            val capability = ExecCapability.of(
                RegisteredTool(PhoneInfoTool.NAME, PhoneInfoTool(source)),
            )
            val bridge = ExecBridge(
                capability = capability,
                admission = AdmissionGate.Open,
                workspace = ExecWorkspace.None,
                clock = platform,
                logger = HostLog.None,
            )
            val host = DefaultPhoneDshHost(
                engine = platform.engine,
                controller = ControllerStateMachine.boot(persistedState = null),
                clock = platform,
                signals = platform,
                notifier = platform,
                exec = bridge,
                scope = CoroutineScope(Dispatchers.Unconfined),
                logger = HostLog.None,
            )
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("exec-test")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                }

                val hello = JSONObject(WireCodec.decode(connection.sent.first()))
                val caps = (0 until hello.getJSONArray("caps").length())
                    .map { hello.getJSONArray("caps").getString(it) }
                assertTrue("exec/1 must be advertised: $caps", caps.contains(HostCapabilities.EXEC))
                assertTrue("phone must be advertised: $caps", caps.contains("accelerator:phone"))

                runBlocking {
                    host.channel.onBinary(connection, execRequestFrame())
                }

                val events = connection.sent
                    .filter { HostFrame.typeOf(it) == HostFrame.EXEC_EVT }
                    .map { JSONObject(WireCodec.decode(it)) }
                assertTrue("at least start + exit", events.size >= 2)
                assertEquals("start", events.first().getString("type"))
                assertEquals("exec-1", events.first().getString("exec_id"))

                val exit = events.last()
                assertEquals("exit", exit.getString("type"))
                assertEquals(0, exit.getInt("code"))
                assertEquals("exited", exit.getString("status"))

                val stdout = events
                    .filter { it.getString("type") == "output" && it.getString("stream") == "stdout" }
                    .joinToString(separator = "") {
                        String(Base64.getDecoder().decode(it.getString("data")), Charsets.UTF_8)
                    }
                assertTrue("stdout must be the phone-info JSON: $stdout", stdout.contains("\"fake-device\""))
                assertEquals(events.size.toLong(), host.channel.execFramesToWorker)
            } finally {
                host.stop()
            }
        }
    }

    /** `exec.md` §2.2: `phone info` needs no VFS view, so `requires_mseq = 0`. */
    private fun execRequestFrame(): ByteArray = WireCodec.encode(
        """
        {"type":"EXEC_REQ","fields":{
          "argv":["phone","info"],
          "cwd":"/dsh/workspace",
          "exec_id":"exec-1",
          "idem_key":"${"a".repeat(64)}",
          "requires_mseq":0
        }}
        """.trimIndent(),
        seq = 2,
    )

    /**
     * An EXEC_REQ carrying an empty argv element is dispatched, not refused.
     *
     * The device defect: the model sent `rg -N ''` (an empty pattern — an
     * ordinary argument), `ExecRequest` answered `BAD_PAYLOAD`, and
     * `channel.md` §10 says every ERROR except `VFS_REFUSED` closes the
     * connection — so one legal argument killed the whole ordered channel and
     * every later tool call in the turn.
     *
     * `channel.md` §4.2 types `argv` as "array of strings"; §10's `BAD_PAYLOAD`
     * causes do not include an element's content; `exec.md` §1 derives
     * `idem_key` from the canonical JSON of argv, where `""` is a value like any
     * other. The element is legal and the host must run the tool.
     *
     * Reverse validation: restore the `argv.any { it.isEmpty() }` rejection in
     * [com.phonedsh.dsh.exec.ExecRequest] and this test fails at its first
     * assertion — the ERROR arrives, the channel closes, and no `start`/`exit`
     * reaches the wire.
     */
    @Test
    fun anExecRequestWithAnEmptyArgvElementRunsAndKeepsTheChannelOpen() {
        FakePlatform().use { platform ->
            val seen = java.util.concurrent.atomic.AtomicReference<String>()
            val capability = ExecCapability.of(
                RegisteredTool(
                    "phone",
                    PhoneTool { invocation ->
                        seen.set(invocation.argumentsJson)
                        ToolOutcome.Success(ExecFixtures.resultJson("ran\n".toByteArray(Charsets.UTF_8)))
                    },
                ),
            )
            val bridge = ExecBridge(
                capability = capability,
                admission = AdmissionGate.Open,
                workspace = ExecWorkspace.None,
                clock = platform,
                logger = HostLog.None,
            )
            val host = DefaultPhoneDshHost(
                engine = platform.engine,
                controller = ControllerStateMachine.boot(persistedState = null),
                clock = platform,
                signals = platform,
                notifier = platform,
                exec = bridge,
                scope = CoroutineScope(Dispatchers.Unconfined),
                logger = HostLog.None,
            )
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = RecordingLoopbackConnection("exec-empty-argv")
                runBlocking {
                    host.channel.onOpen(connection)
                    host.channel.onBinary(connection, workerHelloFrame())
                    host.channel.onBinary(
                        connection,
                        WireCodec.encode(
                            """
                            {"type":"EXEC_REQ","fields":{
                              "argv":["phone","-N","","--color=never"],
                              "cwd":"/dsh/workspace",
                              "exec_id":"exec-empty",
                              "idem_key":"${"a".repeat(64)}",
                              "requires_mseq":0
                            }}
                            """.trimIndent(),
                            seq = 2,
                        ),
                    )
                }

                // §10: an ERROR (0x7F) closes the connection. Neither may happen.
                val errors = connection.sent
                    .filter { HostFrame.typeOf(it) == 0x7F }
                    .map { JSONObject(WireCodec.decode(it)) }
                assertTrue("no ERROR for a legal argv: $errors", errors.isEmpty())
                assertTrue("the channel must stay open: ${connection.closes}", connection.closes.isEmpty())

                val events = connection.sent
                    .filter { HostFrame.typeOf(it) == HostFrame.EXEC_EVT }
                    .map { JSONObject(WireCodec.decode(it)) }
                assertEquals("start", events.first().getString("type"))
                assertEquals("exit", events.last().getString("type"))
                assertEquals(0, events.last().getInt("code"))

                // The tool saw the empty element intact — the request was not
                // silently rewritten to satisfy a validator.
                val arguments = JSONObject(seen.get())
                val argv = arguments.getJSONArray("argv")
                assertEquals(4, argv.length())
                assertEquals("", argv.getString(2))
                assertEquals("--color=never", argv.getString(3))
            } finally {
                host.stop()
            }
        }
    }
}

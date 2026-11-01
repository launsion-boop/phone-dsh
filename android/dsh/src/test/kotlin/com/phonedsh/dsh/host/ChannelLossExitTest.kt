// phone-dsh — :dsh unit test: what a lost ordered channel costs the App (P22).
// SPDX-License-Identifier: MIT
//
// The defect: when the page's one WebSocket ended, every in-flight `/api` request
// failed as `api_aborted` — the same code a *Worker-sent* `API_ABORT` produces —
// so the App could not tell "the turn was aborted" from "the transport is gone",
// and the next turn answered `no_channel` for the life of the process (measured
// 12:47:39, emulator API 35).
//
// What is asserted here:
//   * a connection that ends under a request fails it with `channel_lost`, and the
//     host logs how many requests the close took with it;
//   * a Worker-sent `API_ABORT` keeps `api_aborted` — the two are not merged;
//   * `session/create`'s retry schedule is bounded over the first 30 s (the old
//     flat 1 s produced 180 attempts for a transport that could not answer one).
//
// JNI prerequisite, as for every `:dsh` wire test:
//   cd shell && cargo build -p pdsh-jni

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.turn.CREATE_RETRY_FIRST_DELAY_MILLIS
import com.phonedsh.dsh.turn.CREATE_RETRY_MAX_DELAY_MILLIS
import com.phonedsh.dsh.turn.createAttemptsWithin
import com.phonedsh.dsh.turn.nextCreateRetryDelay
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.wire.WireCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChannelLossExitTest {
    private val logger = RecordingHostLog()

    @Test
    fun aConnectionThatEndsUnderARequestFailsItWithChannelLost() {
        FakePlatform().use { platform ->
            val host = newHost(platform)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = connect(host)
                runBlocking {
                    val inFlight = async(start = CoroutineStart.UNDISPATCHED) {
                        runCatching { host.channel.apiRequest(method = "POST", path = "/api/x") }
                    }
                    // The request is registered and on the wire; now the channel dies.
                    host.channel.onClosed(connection, com.phonedsh.loopback.ChannelCloseCause.CLIENT_CLOSED)
                    val outcome = inFlight.await()

                    val failure = outcome.exceptionOrNull()
                    assertTrue("the request must fail, not hang: $outcome", failure is HostApiException)
                    assertEquals(ChannelLoss.CODE, (failure as HostApiException).code)
                    assertTrue(
                        "the message names the transport, not a Worker abort",
                        failure.message.orEmpty().contains("the ordered channel closed"),
                    )
                }
                assertTrue(
                    "the host says how much work the close took with it",
                    logger.messages.any {
                        it.contains("1 in-flight request(s) aborted because the channel ended")
                    },
                )
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun aWorkerApiAbortKeepsItsOwnCode() {
        FakePlatform().use { platform ->
            val host = newHost(platform)
            host.start()
            runBlocking { withTimeout(5_000) { host.ready.first { it } } }
            try {
                val connection = connect(host)
                runBlocking {
                    val inFlight = async(start = CoroutineStart.UNDISPATCHED) {
                        runCatching { host.channel.apiRequest(method = "POST", path = "/api/x") }
                    }
                    val request = HostApiFrames.fields(connection.sent.last())
                        ?: error("the API_REQ was not encoded")
                    val reqId = HostApiFrames.reqId(request) ?: error("the API_REQ carried no req_id")

                    host.channel.onBinary(
                        connection,
                        WireCodec.encode(
                            """{"type":"API_ABORT","fields":{"req_id":$reqId,"reason":"turn_cancelled"}}""",
                            seq = 2L,
                        ),
                    )

                    val failure = inFlight.await().exceptionOrNull()
                    assertTrue("the abort must fail the request: $failure", failure is HostApiException)
                    assertEquals(
                        "a Worker abort is not a lost channel",
                        "api_aborted",
                        (failure as HostApiException).code,
                    )
                }
            } finally {
                host.stop()
            }
        }
    }

    @Test
    fun theSessionCreateRetryScheduleIsBoundedOverTheFirstThirtySeconds() {
        assertEquals(250L, CREATE_RETRY_FIRST_DELAY_MILLIS)
        assertEquals(500L, nextCreateRetryDelay(CREATE_RETRY_FIRST_DELAY_MILLIS))
        assertEquals(2_000L, nextCreateRetryDelay(1_000L))
        assertEquals(
            "the delay is capped",
            CREATE_RETRY_MAX_DELAY_MILLIS,
            nextCreateRetryDelay(CREATE_RETRY_MAX_DELAY_MILLIS),
        )

        val attempts = createAttemptsWithin(30_000L)
        assertTrue(
            "the first 30 s hold $attempts session/create attempts; the old flat 1 s held 30",
            attempts in 15..20,
        )
    }

    // ---- helpers ------------------------------------------------------------

    private fun newHost(platform: FakePlatform): DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = platform.engine,
        controller = ControllerStateMachine.boot(persistedState = null),
        clock = platform,
        signals = platform,
        notifier = platform,
        scope = CoroutineScope(Dispatchers.Unconfined),
        logger = logger,
    )

    private fun connect(host: DefaultPhoneDshHost): RecordingLoopbackConnection {
        val connection = RecordingLoopbackConnection("channel-loss")
        runBlocking {
            host.channel.onOpen(connection)
            host.channel.onBinary(connection, workerHelloFrame())
        }
        return connection
    }
}

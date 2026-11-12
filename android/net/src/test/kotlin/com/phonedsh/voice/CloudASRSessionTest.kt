// SPDX-License-Identifier: MIT
// phone-dsh — :net voice tests: CloudASRSession's gate, ordering, queue cap and
// deadlines (spec/v1/cloud-voice.md §2). The socket is a fake; no host is
// contacted.

package com.phonedsh.voice

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudASRSessionTest {
    private fun timing(
        connectMs: Long = 2_000,
        startedMs: Long = 2_000,
        finishDefaultMs: Long = 1_000,
        finishGraceMs: Long = 100,
    ) = CloudVoiceTiming(
        connectTimeoutMs = connectMs,
        startedTimeoutMs = startedMs,
        finishTimeoutDefaultMs = finishDefaultMs,
        finishGraceMs = finishGraceMs,
    )

    @Test
    fun startedGatesOrderedForwardingAndFinishIsSent() = runBlocking {
        val socket = FakeCloudVoiceSocket()
        val factory = RecordingSocketFactory(socket)
        val session = CloudASRSession(
            turnId = 7u,
            credentials = { "tok-a" },
            socketFactory = factory,
            url = "ws://127.0.0.1/asr",
            timing = timing(),
            scope = this,
        )
        session.open()

        assertEquals("ws://127.0.0.1/asr", factory.url)
        assertEquals(CloudVoice.ASR_SUBPROTOCOL, factory.subprotocol)
        assertEquals("tok-a", factory.credential)
        assertEquals(1, socket.textSent.size)
        val start = GatewayJson.parse(socket.textSent.single()) as JsonValue.Obj
        assertEquals("start", start.string("type"))
        assertEquals("tonolink-7", start.string("client_ref"))

        // The board records immediately; the phone queues until `started`.
        session.send(byteArrayOf(1))
        session.send(byteArrayOf(2))
        session.send(byteArrayOf(3))
        assertEquals(0, socket.binarySent.size)

        socket.deliver(startedMessage())
        assertTrue(withTimeout(2_000) { session.ready() })
        awaitUntil { socket.binarySent.size == 3 }
        assertArrayEquals(byteArrayOf(1), socket.binarySent[0])
        assertArrayEquals(byteArrayOf(2), socket.binarySent[1])
        assertArrayEquals(byteArrayOf(3), socket.binarySent[2])
        assertEquals(3, session.sentPackets)

        session.finish()
        assertTrue(socket.textSent.contains(String(CloudVoice.finishMessage)))

        // Finals are used in segment order, and only after completed.
        socket.deliver(finalMessage(2, "电量"))
        socket.deliver(finalMessage(1, "看看"))
        assertNull(session.outcomeIfComplete)
        socket.deliver("""{"type":"completed","session_id":"s1","final":true,"end_reason":"single_utterance"}""")
        assertEquals(CloudASRTranscript.Outcome.Text("看看电量"), withTimeout(2_000) { session.outcome() })
        assertNotNull(session.connectMs)
        assertNotNull(session.startedMs)
        assertTrue(socket.closed)
    }

    @Test
    fun preStartQueueCapIsOneHundredAndTheNextFailsWithCancel() = runBlocking {
        val socket = FakeCloudVoiceSocket()
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { "tok" },
            socketFactory = RecordingSocketFactory(socket),
            timing = timing(),
            scope = this,
        )
        session.open()
        repeat(CloudVoice.PRE_START_QUEUE_MAX) { index -> session.send(byteArrayOf(index.toByte())) }
        assertEquals(0, socket.binarySent.size)
        assertFalse(socket.textSent.contains(String(CloudVoice.cancelMessage)))

        session.send(byteArrayOf(0x7F))
        assertEquals(CloudASRTranscript.Outcome.Failed("cancelled"), withTimeout(2_000) { session.outcome() })
        assertTrue(socket.textSent.contains(String(CloudVoice.cancelMessage)))
        assertTrue(socket.closed)
        assertEquals(0, session.sentPackets)
    }

    @Test
    fun startedDeadlineCancelsAndFailsTheTurn() = runBlocking {
        val socket = FakeCloudVoiceSocket()
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { "tok" },
            socketFactory = RecordingSocketFactory(socket),
            timing = timing(startedMs = 50),
            scope = this,
        )
        session.open()
        assertEquals(
            CloudASRTranscript.Outcome.Failed("no started within 5 s of start"),
            withTimeout(2_000) { session.outcome() },
        )
        assertTrue(socket.textSent.contains(String(CloudVoice.cancelMessage)))
        assertTrue(socket.closed)
    }

    @Test
    fun finishDeadlineUsesTheStartedLimitPlusTheGrace() = runBlocking {
        val socket = FakeCloudVoiceSocket()
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { "tok" },
            socketFactory = RecordingSocketFactory(socket),
            timing = timing(finishDefaultMs = 1_000, finishGraceMs = 50),
            scope = this,
        )
        session.open()
        socket.deliver(startedMessage(finishTimeoutMs = 50))
        assertTrue(withTimeout(2_000) { session.ready() })
        session.finish()
        assertEquals(
            CloudASRTranscript.Outcome.Failed("no result in time"),
            withTimeout(2_000) { session.outcome() },
        )
        assertTrue(socket.closed)
    }

    @Test
    fun connectDeadlineFailsWithoutASocket() = runBlocking {
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { "tok" },
            socketFactory = HangingSocketFactory(),
            timing = timing(connectMs = 50),
            scope = this,
        )
        session.open()
        assertEquals(
            CloudASRTranscript.Outcome.Failed("no connection within 10 s"),
            withTimeout(2_000) { session.outcome() },
        )
        assertNull(session.connectMs)
    }

    @Test
    fun handshakeStatusIsRecordedAndTheTurnFailsClosed() = runBlocking {
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { "tok" },
            socketFactory = { _, _, _ -> throw CloudVoiceHandshakeException(401) },
            timing = timing(),
            scope = this,
        )
        session.open()
        assertEquals(
            CloudASRTranscript.Outcome.Failed("closed without a result"),
            withTimeout(2_000) { session.outcome() },
        )
        assertEquals(401, session.handshakeStatus)
    }

    @Test
    fun credentialUnavailableFailsBeforeConnecting() = runBlocking {
        val factory = RecordingSocketFactory()
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { null },
            socketFactory = factory,
            timing = timing(),
            scope = this,
        )
        session.open()
        assertEquals(
            CloudASRTranscript.Outcome.Failed("credential unavailable"),
            withTimeout(2_000) { session.outcome() },
        )
        assertNull(factory.url)
    }

    @Test
    fun aPeerCloseWithoutATerminalFailsTheTurn() = runBlocking {
        val socket = FakeCloudVoiceSocket()
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { "tok" },
            socketFactory = RecordingSocketFactory(socket),
            timing = timing(),
            scope = this,
        )
        session.open()
        socket.deliver(startedMessage())
        assertTrue(withTimeout(2_000) { session.ready() })
        socket.closeFromPeer()
        assertEquals(
            CloudASRTranscript.Outcome.Failed("closed without a result"),
            withTimeout(2_000) { session.outcome() },
        )
    }

    @Test
    fun errorAndInvalidMessagesAreTerminalFailures() = runBlocking {
        val socket = FakeCloudVoiceSocket()
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { "tok" },
            socketFactory = RecordingSocketFactory(socket),
            timing = timing(),
            scope = this,
        )
        session.open()
        socket.deliver(startedMessage())
        assertTrue(withTimeout(2_000) { session.ready() })
        socket.deliver("""{"type":"error","code":"quota_exceeded","message":"busy"}""")
        assertEquals(CloudASRTranscript.Outcome.Failed("quota_exceeded"), withTimeout(2_000) { session.outcome() })
    }

    @Test
    fun invalidServerMessageFailsWithoutText() = runBlocking {
        val socket = FakeCloudVoiceSocket()
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { "tok" },
            socketFactory = RecordingSocketFactory(socket),
            timing = timing(),
            scope = this,
        )
        session.open()
        socket.deliver("not json")
        assertEquals(
            CloudASRTranscript.Outcome.Failed("invalid server message"),
            withTimeout(2_000) { session.outcome() },
        )
    }

    @Test
    fun cancelSendsTheCancelMessageAndEndsTheSession() = runBlocking {
        val socket = FakeCloudVoiceSocket()
        val session = CloudASRSession(
            turnId = 1u,
            credentials = { "tok" },
            socketFactory = RecordingSocketFactory(socket),
            timing = timing(),
            scope = this,
        )
        session.open()
        session.cancel()
        assertEquals(CloudASRTranscript.Outcome.Failed("cancelled"), withTimeout(2_000) { session.outcome() })
        assertTrue(socket.textSent.contains(String(CloudVoice.cancelMessage)))
        assertTrue(socket.closed)
    }
}

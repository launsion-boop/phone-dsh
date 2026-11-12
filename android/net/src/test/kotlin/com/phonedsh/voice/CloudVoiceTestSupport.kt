// SPDX-License-Identifier: MIT
// phone-dsh — :net voice tests: a fake pdsh-asr.v1 socket.
//
// The session tests need three things a real socket cannot give deterministically:
// delivery of `started` on command, a peer close without a terminal message, and
// a connect that never finishes. This fake provides all three and records what
// the session actually wrote.

package com.phonedsh.voice

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout

internal class FakeCloudVoiceSocket : CloudVoiceSocket {
    private val frames = Channel<CloudVoiceSocketFrame>(Channel.UNLIMITED)

    val textSent = CopyOnWriteArrayList<String>()
    val binarySent = CopyOnWriteArrayList<ByteArray>()
    val closeCodes = CopyOnWriteArrayList<Int>()

    @Volatile
    var closed: Boolean = false
        private set

    override suspend fun sendText(text: String) {
        textSent.add(text)
    }

    override suspend fun sendBinary(bytes: ByteArray) {
        binarySent.add(bytes.copyOf())
    }

    override suspend fun receive(): CloudVoiceSocketFrame? =
        frames.receiveCatching().getOrNull()

    override suspend fun close(code: Int, reason: String?) {
        closed = true
        closeCodes.add(code)
        frames.close()
    }

    /** Delivers one server text message. */
    fun deliver(message: String) {
        check(frames.trySend(CloudVoiceSocketFrame.Text(message)).isSuccess) { "fake socket is closed" }
    }

    /** The peer dropped the connection without a terminal message. */
    fun closeFromPeer() {
        frames.close()
    }
}

internal class RecordingSocketFactory(
    private val socket: CloudVoiceSocket = FakeCloudVoiceSocket(),
) : CloudVoiceSocketFactory {
    var url: String? = null
        private set
    var subprotocol: String? = null
        private set
    var credential: String? = null
        private set

    override suspend fun open(url: String, subprotocol: String, credential: String): CloudVoiceSocket {
        this.url = url
        this.subprotocol = subprotocol
        this.credential = credential
        return socket
    }
}

/** A factory whose connect never completes, for the connect-deadline case. */
internal class HangingSocketFactory : CloudVoiceSocketFactory {
    override suspend fun open(url: String, subprotocol: String, credential: String): CloudVoiceSocket {
        delay(60_000)
        error("the connect deadline must cancel this")
    }
}

internal fun startedMessage(finishTimeoutMs: Int? = 15_000): String =
    if (finishTimeoutMs == null) {
        """{"type":"started","session_id":"s1","mode":"interactive","price_version":"p1","limits":{}}"""
    } else {
        """{"type":"started","session_id":"s1","mode":"interactive","price_version":"p1","limits":{"finish_timeout_ms":$finishTimeoutMs}}"""
    }

internal fun finalMessage(segment: Int, text: String): String =
    """{"type":"final","segment_id":$segment,"text":"$text","start_ms":0,"end_ms":1}"""

internal suspend fun awaitUntil(timeoutMs: Long = 2_000, condition: () -> Boolean) {
    withTimeout(timeoutMs) {
        while (!condition()) delay(10)
    }
}

// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.voice: the transport seams of the cloud voice
// clients. The session and TTS state machines depend only on these interfaces,
// so the shared cases and the failure paths run on a fake socket with no
// network, and the Ktor client is one interchangeable implementation.
//
// Nothing here reads account storage: the host injects a
// [CloudVoiceCredentialProvider] whose value follows cloud-voice.md §1.

package com.phonedsh.voice

import kotlinx.coroutines.flow.Flow

/** The injected credential for one voice turn (§1); null means voice is unavailable. */
fun interface CloudVoiceCredentialProvider {
    suspend fun credential(): String?
}

/** One frame the ASR socket delivered. */
sealed interface CloudVoiceSocketFrame {
    data class Text(val text: String) : CloudVoiceSocketFrame

    class Binary(val bytes: ByteArray) : CloudVoiceSocketFrame {
        override fun equals(other: Any?): Boolean =
            this === other || (other is Binary && bytes.contentEquals(other.bytes))

        override fun hashCode(): Int = bytes.contentHashCode()

        override fun toString(): String = "Binary(${bytes.size} bytes)"
    }
}

/** One open pdsh-asr.v1 WebSocket. */
interface CloudVoiceSocket {
    suspend fun sendText(text: String)

    suspend fun sendBinary(bytes: ByteArray)

    /** The next frame, or null once the peer/transport closed. A transport failure throws. */
    suspend fun receive(): CloudVoiceSocketFrame?

    suspend fun close(code: Int, reason: String?)

    companion object {
        const val CLOSE_NORMAL = 1000
    }
}

/** Opens one WebSocket; the credential is already resolved by the caller. */
fun interface CloudVoiceSocketFactory {
    suspend fun open(url: String, subprotocol: String, credential: String): CloudVoiceSocket
}

/** The handshake answered a non-101 status; `status` is what the ASR session records. */
class CloudVoiceHandshakeException(
    val status: Int,
    cause: Throwable? = null,
) : Exception("websocket handshake answered $status", cause)

/** One TTS request: the body is `CloudVoice.speechRequest`, the URL the contract's. */
class CloudTtsRequest(
    val url: String,
    val body: ByteArray,
    val credential: String,
)

/**
 * `/v1/tts/speech` with `response_format: pcm` (§3). The flow yields the raw
 * response bytes as they arrive; [CloudTTSClient] owns the sample/chunk
 * boundary. A non-200 answer throws [CloudVoiceException] before any byte.
 */
fun interface CloudTtsTransport {
    fun stream(request: CloudTtsRequest): Flow<ByteArray>
}

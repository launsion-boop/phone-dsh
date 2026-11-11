// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.voice: the real Ktor client transport for the
// cloud voice clients (P05 dependency decision, PC-20261112-android-voice-consumer).
//
// The session and TTS state machines never see Ktor; they depend on
// CloudVoiceSocketFactory / CloudTtsTransport. This file is the one adapter that
// speaks RFC 6455 (Ktor client 3.2.3, already pinned) and streams the HTTP PCM
// body. It never contacts a host by itself: the URL comes from the contract or
// from a test's local server.

package com.phonedsh.voice

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.ResponseException
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.WebSocketException
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.client.request.header
import io.ktor.client.request.preparePost
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.utils.io.readAvailable
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readBytes
import io.ktor.websocket.readText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/** The Ktor `/v1/asr/stream` WebSocket factory. */
class KtorCloudVoiceSocketFactory(
    private val client: HttpClient = defaultVoiceClient(),
) : CloudVoiceSocketFactory, AutoCloseable {
    override suspend fun open(url: String, subprotocol: String, credential: String): CloudVoiceSocket {
        val session = try {
            client.webSocketSession {
                url(urlString = url)
                header(HttpHeaders.Authorization, "Bearer $credential")
                header(HttpHeaders.SecWebSocketProtocol, subprotocol)
            }
        } catch (failure: ResponseException) {
            throw CloudVoiceHandshakeException(failure.response.status.value, failure)
        } catch (failure: WebSocketException) {
            // Ktor 3.2.3 reports a failed upgrade as `expected status code 101
            // but was <status>`; the status is what the 401 invalidation path
            // needs, so surface it instead of losing it in the message.
            val status = HANDSHAKE_STATUS.find(failure.message.orEmpty())?.groupValues?.get(1)?.toIntOrNull()
            if (status != null) throw CloudVoiceHandshakeException(status, failure)
            throw failure
        }
        return KtorCloudVoiceSocket(session)
    }

    override fun close() {
        client.close()
    }

    companion object {
        /** 16 KiB, matching the iOS session's `maximumMessageSize`. */
        const val MAX_FRAME_SIZE = 16L * 1024

        private val HANDSHAKE_STATUS = Regex("expected status code 101 but was ([0-9]{3})")

        fun defaultVoiceClient(): HttpClient = HttpClient(CIO) {
            install(WebSockets) {
                maxFrameSize = MAX_FRAME_SIZE
            }
        }
    }
}

private class KtorCloudVoiceSocket(
    private val session: DefaultClientWebSocketSession,
) : CloudVoiceSocket {
    override suspend fun sendText(text: String) {
        session.send(Frame.Text(text))
    }

    override suspend fun sendBinary(bytes: ByteArray) {
        session.send(Frame.Binary(true, bytes))
    }

    override suspend fun receive(): CloudVoiceSocketFrame? {
        while (true) {
            val frame = try {
                session.incoming.receive()
            } catch (_: ClosedReceiveChannelException) {
                return null
            } catch (cancelled: CancellationException) {
                throw cancelled
            }
            when (frame) {
                is Frame.Text -> return CloudVoiceSocketFrame.Text(frame.readText())
                is Frame.Binary -> return CloudVoiceSocketFrame.Binary(frame.readBytes())
                is Frame.Close -> return null
                else -> continue
            }
        }
    }

    override suspend fun close(code: Int, reason: String?) {
        session.close(CloseReason(code.toShort(), reason.orEmpty()))
    }
}

/** `/v1/tts/speech` over Ktor's streaming response body. */
class KtorCloudTtsTransport(
    private val client: HttpClient = HttpClient(CIO),
) : CloudTtsTransport, AutoCloseable {
    override fun close() {
        client.close()
    }

    override fun stream(request: CloudTtsRequest): Flow<ByteArray> = flow {
        client.preparePost(request.url) {
            header(HttpHeaders.Authorization, "Bearer ${request.credential}")
            header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            setBody(request.body)
        }.execute { response ->
            val status = response.status.value
            if (status != 200) {
                throw cloudVoiceException(status, readErrorBody(response))
            }
            val channel = response.bodyAsChannel()
            val buffer = ByteArray(8 * 1024)
            while (true) {
                val count = channel.readAvailable(buffer, 0, buffer.size)
                if (count == -1) break
                if (count > 0) emit(buffer.copyOf(count))
            }
        }
    }
}

/** At most 16 KiB of the error body, enough for `error.code`/`error.type` (§1). */
private suspend fun readErrorBody(response: io.ktor.client.statement.HttpResponse): ByteArray {
    val channel = response.bodyAsChannel()
    val buffer = ByteArray(16 * 1024)
    var used = 0
    while (used < buffer.size) {
        val count = channel.readAvailable(buffer, used, buffer.size - used)
        if (count == -1) break
        if (count > 0) used += count
    }
    return buffer.copyOf(used)
}

private fun cloudVoiceException(status: Int, body: ByteArray): CloudVoiceException {
    val objectValue = GatewayJson.parseOrNull(body) as? JsonValue.Obj
    val error = objectValue?.obj("error")
    val code = error?.string("code") ?: error?.string("type")
    val message = "语音合成失败（HTTP $status${code?.let { " $it" } ?: ""}）"
    return CloudVoiceException(status, code, message)
}

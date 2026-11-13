// SPDX-License-Identifier: MIT
// The injectable relay WebSocket seam and its one production adapter.
//
// `PclinkRelayClient` never sees Ktor: tests drive it through [FakeWebSocket]
// (test source set) and production uses [KtorPclinkWebSocketFactory]. The
// adapter is a thin RFC 6455 reader; every PCLink rule (frame size, closed JSON,
// relay types) stays in `PclinkRelayClient`, so the fake and the real client
// exercise the same state machine.
package com.phonedsh.pclink

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.client.request.url
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.FrameTooBigException
import io.ktor.websocket.close
import io.ktor.websocket.readBytes
import io.ktor.websocket.readReason
import io.ktor.websocket.readText
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withTimeoutOrNull

/** One WebSocket message. [Closed] is the last emitted item of [PclinkWebSocket.incoming]. */
sealed interface PclinkWebSocketMessage {
    data class Text(val text: String) : PclinkWebSocketMessage

    class Binary(val bytes: ByteArray) : PclinkWebSocketMessage {
        override fun equals(other: Any?): Boolean =
            this === other || (other is Binary && bytes.contentEquals(other.bytes))

        override fun hashCode(): Int = bytes.contentHashCode()

        override fun toString(): String = "Binary(${bytes.size} bytes)"
    }

    /** The peer closed; [code]/[reason] are the RFC 6455 close frame values. */
    data class Closed(val code: Int?, val reason: String?) : PclinkWebSocketMessage
}

/**
 * One relay WebSocket. The contract is text-only: a binary message is surfaced
 * so the client can answer `bad_frame`/close 1003 rather than silently ignore
 * it. [incoming] is a single-consumer flow that completes after [Closed].
 */
interface PclinkWebSocket {
    suspend fun sendText(text: String)

    val incoming: Flow<PclinkWebSocketMessage>

    suspend fun close(code: Int, reason: String)
}

/** Dials one relay URL; the URL is the `ws`/`wss` form of a validated origin. */
fun interface PclinkWebSocketFactory {
    suspend fun connect(url: String): PclinkWebSocket
}

class KtorPclinkWebSocketFactory private constructor(
    private val client: HttpClient,
    private val boundOrigin: String?,
) : PclinkWebSocketFactory, AutoCloseable {
    constructor(client: HttpClient = defaultClient()) : this(client, null)

    override suspend fun connect(url: String): PclinkWebSocket {
        if (boundOrigin != null && PclinkRelayClientFactory.originForWebSocketUrl(url) != boundOrigin) {
            throw PclinkError.BadFrame("relay socket belongs to another origin")
        }
        val session = try {
            client.webSocketSession { url(urlString = url) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            throw PclinkError.Unavailable("relay WebSocket connect failed: ${failure.message}")
        }
        return KtorPclinkWebSocket(session)
    }

    override fun close() {
        client.close()
    }

    companion object {
        fun defaultClient(): HttpClient = createClient()

        fun forOrigin(origin: String, trustManagerForHost: (String) -> X509TrustManager): KtorPclinkWebSocketFactory {
            PclinkValidation.origin(origin)
            val host = origin.substringAfter("://").substringBefore(':')
            val tls = if (origin.startsWith("https://")) trustManagerForHost(host) else null
            return KtorPclinkWebSocketFactory(createClient(tls), origin)
        }

        private fun createClient(trust: X509TrustManager? = null): HttpClient = HttpClient(CIO) {
            followRedirects = false
            if (trust != null) {
                engine {
                    https { trustManager = trust }
                }
            }
            install(WebSockets) {
                maxFrameSize = PclinkLimits.MAX_RELAY_FRAME_BYTES.toLong()
            }
        }
    }
}

private class KtorPclinkWebSocket(
    private val session: DefaultClientWebSocketSession,
) : PclinkWebSocket {
    override suspend fun sendText(text: String) {
        try {
            session.send(Frame.Text(text))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            throw PclinkError.Unavailable("relay WebSocket send failed: ${failure.message}")
        }
    }

    override val incoming: Flow<PclinkWebSocketMessage> = flow {
        try {
            for (frame in session.incoming) {
                when (frame) {
                    is Frame.Text -> emit(PclinkWebSocketMessage.Text(frame.readText()))
                    is Frame.Binary -> emit(PclinkWebSocketMessage.Binary(frame.readBytes()))
                    is Frame.Close -> {
                        val reason = runCatching { frame.readReason() }.getOrNull()
                        emit(PclinkWebSocketMessage.Closed(reason?.code?.toInt(), reason?.message))
                        return@flow
                    }
                    else -> Unit // ping/pong are handled by Ktor's session.
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (tooBig: FrameTooBigException) {
            throw PclinkError.FrameTooLarge("relay frame exceeds 16 MiB")
        } catch (_: ClosedReceiveChannelException) {
            // Normal end of the incoming channel; the close reason follows.
        } catch (failure: Throwable) {
            throw PclinkError.Unavailable("relay WebSocket receive failed: ${failure.message}")
        }

        // Ktor may consume the close frame before exposing it; the session's
        // closeReason is the authoritative RFC 6455 code either way.
        val reason = try {
            withTimeoutOrNull(CLOSE_REASON_TIMEOUT_MILLIS) { session.closeReason.await() }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            null
        }
        emit(PclinkWebSocketMessage.Closed(reason?.code?.toInt(), reason?.message))
    }

    override suspend fun close(code: Int, reason: String) {
        try {
            session.close(CloseReason(code.toShort(), reason))
        } catch (_: CancellationException) {
            // The caller is shutting down; the socket is already unusable.
        } catch (_: Throwable) {
            // Best effort: the connection is going away either way.
        }
    }

    companion object {
        private const val CLOSE_REASON_TIMEOUT_MILLIS = 1_000L
    }
}

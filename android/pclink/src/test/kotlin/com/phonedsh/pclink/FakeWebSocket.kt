// SPDX-License-Identifier: MIT
// In-memory WebSocket for the C3 relay tests. It implements the same
// `PclinkWebSocket` seam as the Ktor adapter, so `PclinkRelayClientTest` drives
// the production state machine without a network. No vector value is copied
// into Kotlin: the scripted relay sends the shared golden documents read from
// disk by `TestSupport`.
package com.phonedsh.pclink

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/** One text frame the client wrote, with its monotonic write time. */
data class FakeWebSocketSent(val text: String, val nanos: Long) {
    val frame: PclinkJson get() = PclinkJsonParser.parseObject(text)
}

/**
 * A scriptable relay endpoint. The test writes frames with [deliver] and reads
 * the client's frames from [sent]; [incoming] is the same single-consumer flow
 * shape as the Ktor adapter.
 */
class FakeWebSocket : PclinkWebSocket {
    private val inbox = Channel<PclinkWebSocketMessage>(Channel.UNLIMITED)
    private val outbound = CopyOnWriteArrayList<FakeWebSocketSent>()

    val sent: List<FakeWebSocketSent> get() = outbound.toList()

    @Volatile
    var closedCode: Int? = null
        private set

    @Volatile
    var closedReason: String? = null
        private set

    val closeCalled = AtomicBoolean(false)

    override suspend fun sendText(text: String) {
        outbound += FakeWebSocketSent(text, System.nanoTime())
    }

    override val incoming: Flow<PclinkWebSocketMessage> = inbox.receiveAsFlow()

    override suspend fun close(code: Int, reason: String) {
        closeCalled.set(true)
        closedCode = code
        closedReason = reason
        inbox.close()
    }

    fun deliver(frame: PclinkJson) {
        deliverText(PclinkJsonEncoder.encodeString(frame))
    }

    fun deliverText(text: String) {
        inbox.trySend(PclinkWebSocketMessage.Text(text))
    }

    fun deliverBinary(bytes: ByteArray) {
        inbox.trySend(PclinkWebSocketMessage.Binary(bytes))
    }

    fun deliverClose(code: Int?, reason: String?) {
        inbox.trySend(PclinkWebSocketMessage.Closed(code, reason))
    }

    fun endOfStream() {
        inbox.close()
    }

    fun frames(type: String? = null): List<PclinkJson> = sent
        .map { it.frame }
        .filter { type == null || it["type"]?.stringValue == type }

    /** Waits for a frame of [type] and returns it (last one if several arrived). */
    suspend fun awaitSent(type: String, timeoutMillis: Long = 3_000): PclinkJson =
        withTimeout(timeoutMillis) {
            while (true) {
                frames(type).lastOrNull()?.let { return@withTimeout it }
                delay(2)
            }
            @Suppress("UNREACHABLE_CODE")
            throw IllegalStateException("unreachable")
        }
}

/** Assigns one [FakeWebSocket] per `connect` and runs the test's relay script. */
class FakeWebSocketFactory(
    private val scope: CoroutineScope,
    private val handler: suspend (FakeWebSocket, Int) -> Unit = { _, _ -> },
) : PclinkWebSocketFactory {
    private val created = CopyOnWriteArrayList<FakeWebSocket>()

    val urls = CopyOnWriteArrayList<String>()

    val sockets: List<FakeWebSocket> get() = created.toList()

    val last: FakeWebSocket get() = created.last()

    override suspend fun connect(url: String): PclinkWebSocket {
        val socket = FakeWebSocket()
        val index = created.size
        created += socket
        urls += url
        scope.launch { handler(socket, index) }
        return socket
    }
}

/** Frames a scripted relay sends, built from the shared golden values. */
object FakeRelay {
    fun challenge(origin: String, nonce: ByteArray): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("relay.challenge"),
        "nonce" to PclinkJson.Text(PclinkBase64Url.encode(nonce)),
        "relay" to PclinkJson.Text(origin),
    )

    fun ready(machineId: String, role: String): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("relay.ready"),
        "machineId" to PclinkJson.Text(machineId),
        "role" to PclinkJson.Text(role),
    )

    fun ping(nonce: ByteArray): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("relay.ping"),
        "nonce" to PclinkJson.Text(PclinkBase64Url.encode(nonce)),
    )

    fun pong(nonce: ByteArray): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("relay.pong"),
        "nonce" to PclinkJson.Text(PclinkBase64Url.encode(nonce)),
    )

    fun error(
        code: String,
        message: String? = null,
        retryAfterMs: Int? = null,
        id: String? = null,
        streamId: String? = null,
        sid: String? = null,
    ): PclinkJson {
        val members = linkedMapOf<String, PclinkJson>(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("relay.error"),
            "code" to PclinkJson.Text(code),
        )
        if (message != null) members["message"] = PclinkJson.Text(message)
        if (retryAfterMs != null) members["retryAfterMs"] = PclinkJson.Integer(retryAfterMs.toLong())
        if (id != null) members["id"] = PclinkJson.Text(id)
        if (streamId != null) members["streamId"] = PclinkJson.Text(streamId)
        if (sid != null) members["sid"] = PclinkJson.Text(sid)
        return PclinkJson.Object(members)
    }

    fun offline(
        to: String,
        id: String? = null,
        streamId: String? = null,
        sid: String? = null,
    ): PclinkJson {
        val members = linkedMapOf<String, PclinkJson>(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("relay.offline"),
            "to" to PclinkJson.Text(to),
        )
        if (id != null) members["id"] = PclinkJson.Text(id)
        if (streamId != null) members["streamId"] = PclinkJson.Text(streamId)
        if (sid != null) members["sid"] = PclinkJson.Text(sid)
        return PclinkJson.Object(members)
    }

    fun allow(peers: List<String>): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("relay.allow"),
        "peers" to PclinkJson.Array(peers.map { PclinkJson.Text(it) }),
    )

    fun e2e(
        sid: String,
        seq: Long,
        from: String,
        to: String,
        body: ByteArray = ByteArray(16) { it.toByte() },
    ): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("e2e"),
        "sid" to PclinkJson.Text(sid),
        "seq" to PclinkJson.Integer(seq),
        "from" to PclinkJson.Text(from),
        "to" to PclinkJson.Text(to),
        "body" to PclinkJson.Text(PclinkBase64Url.encode(body)),
    )

    /** Sends `relay.challenge`, waits for `peer.auth`, then sends `relay.ready`. */
    suspend fun handshake(
        socket: FakeWebSocket,
        origin: String,
        nonce: ByteArray,
        machineId: String,
        role: String = "phone",
    ) {
        socket.deliver(challenge(origin, nonce))
        socket.awaitSent("peer.auth")
        socket.deliver(ready(machineId, role))
    }
}

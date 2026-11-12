// SPDX-License-Identifier: MIT
// Relay WebSocket client: challenge signature auth, frame grammar, heartbeats,
// relay errors/offline access and the C3 reconnect/pacing policy (§3, §10). It
// is a second `role:"phone"` implementation of the frozen `pclink-v1.6` bytes.
//
// Layering: `PclinkRelayLink` (C1 seam) is the transport C2 consumes. This class
// implements it and adds a structured event view. `e2e`/`e2e.handshake` bodies
// stay opaque here: no C2/C4 class is referenced (design C3 definition of done).
// Sender pacing lives on the single application writer below, so a queued frame
// keeps its `seq` order and is never dropped, coalesced or split (§3.8).
package com.phonedsh.pclink

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/**
 * The one relay connection of a phone. [connect] performs
 * `relay.challenge` -> `peer.auth` -> `relay.ready`; after `relay.ready` a
 * heartbeat loop runs and relay frames are forwarded as [PclinkRelayEvent]s.
 *
 * Exactly one of [events] and [incoming] may be collected: both read the same
 * single-consumer event channel. [incoming] is the three-method C1 link view and
 * yields the exact `relay.offline`/`relay.error` frames as well as `e2e`,
 * `e2e.handshake` and pairing frames; the channel then completes (or completes
 * exceptionally with the terminal [PclinkError]).
 */
class PclinkRelayClient(
    private val configuration: Configuration,
    private val socketFactory: PclinkWebSocketFactory,
    private val pacer: PclinkPacer = PclinkPacer(),
    private val random: Random = Random.Default,
) : PclinkRelayLink {
    data class Configuration(
        val origin: String,
        val identity: PclinkIdentity,
        val role: String = "phone",
        val challengeTimeoutMillis: Long = 10_000,
        val readyTimeoutMillis: Long = 10_000,
        val heartbeatRangeMillis: LongRange =
            (PclinkLimits.HEARTBEAT_RANGE.first * 1_000L)..(PclinkLimits.HEARTBEAT_RANGE.last * 1_000L),
        val heartbeatEnabled: Boolean = true,
        val frameLimitBytes: Int = PclinkLimits.MAX_RELAY_FRAME_BYTES,
    )

    enum class State { IDLE, CONNECTING, READY, CLOSED }

    private data class PendingSend(
        val text: String,
        val bytes: Int,
        val paced: Boolean,
        val done: CompletableDeferred<Unit>,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val eventChannel = Channel<PclinkRelayEvent>(Channel.UNLIMITED)

    /** The rich event view; collect either this or [incoming], not both. */
    val events: Flow<PclinkRelayEvent> = eventChannel.receiveAsFlow()

    /** C1 link view: every frame the upper layer must interpret (see the class KDoc). */
    override val incoming: Flow<PclinkJson> = eventChannel.receiveAsFlow().mapNotNull { event ->
        when (event) {
            is PclinkRelayEvent.Frame -> event.frame
            is PclinkRelayEvent.Offline -> event.offline.frame
            is PclinkRelayEvent.Error -> event.frame
            is PclinkRelayEvent.Ready, is PclinkRelayEvent.Closed -> null
        }
    }

    @Volatile
    var state: State = State.IDLE
        private set

    /** The close code actually sent or observed; null while connected. */
    @Volatile
    var closeCode: Int? = null
        private set

    @Volatile
    var closeReason: String? = null
        private set

    private val challenge = CompletableDeferred<ByteArray>()
    private val ready = CompletableDeferred<Unit>()
    private val finished = AtomicBoolean(false)
    private val outstandingPing = AtomicReference<ByteArray?>(null)
    private val sendQueue = Channel<PendingSend>(Channel.UNLIMITED)
    private val writeMutex = Mutex()
    private val stateMutex = Mutex()

    @Volatile
    private var terminalError: PclinkError? = null

    private var socket: PclinkWebSocket? = null
    private var challengeSeen = false
    private var readySeen = false
    private var heartbeatJob: Job? = null
    private var sendWriter: Job? = null

    /**
     * Authenticates one connection. Throws the mapped [PclinkError] on
     * challenge/ready timeout, origin mismatch, ready mismatch or close.
     */
    suspend fun connect() {
        if (state != State.IDLE) throw PclinkError.BadFrame("relay client already started")
        if (configuration.role != "phone" && configuration.role != "pc") {
            throw PclinkError.BadFrame("relay role must be phone or pc")
        }
        PclinkValidation.origin(configuration.origin)
        if (configuration.frameLimitBytes <= 0) {
            throw PclinkError.BadFrame("frame limit must be positive")
        }
        if (configuration.challengeTimeoutMillis <= 0 || configuration.readyTimeoutMillis <= 0) {
            throw PclinkError.BadFrame("auth timeouts must be positive")
        }
        if (configuration.heartbeatEnabled &&
            (configuration.heartbeatRangeMillis.first < 1 ||
                configuration.heartbeatRangeMillis.last < configuration.heartbeatRangeMillis.first)
        ) {
            throw PclinkError.BadFrame("heartbeat range is invalid")
        }
        val url = PclinkValidation.websocketUrl(configuration.origin)
        state = State.CONNECTING
        try {
            socket = socketFactory.connect(url)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            val mapped = failure as? PclinkError
                ?: PclinkError.Unavailable("relay connect failed: ${failure.message}")
            shutdown(null, null, mapped, sendClose = false)
            throw mapped
        }
        scope.launch { receiveLoop() }
        startSendWriter()

        try {
            val nonce = try {
                withTimeout(configuration.challengeTimeoutMillis) { challenge.await() }
            } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
                // A relay that never sends the challenge has not authenticated
                // us; the 10 s unauthenticated window closes 4002 (§3.2/§3.5),
                // but the local outcome is retryable transport unavailability.
                val timeout = PclinkError.Unavailable("relay.challenge timeout")
                shutdown(4002, "auth_failed", timeout)
                throw timeout
            }
            val transcript = PclinkCrypto.relayAuthTranscript(configuration.origin, nonce)
            val signature = configuration.identity.sign(transcript)
            val auth = pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("peer.auth"),
                "machineId" to PclinkJson.Text(configuration.identity.machineId),
                "publicKey" to PclinkJson.Text(
                    PclinkBase64Url.encode(configuration.identity.publicKey),
                ),
                "role" to PclinkJson.Text(configuration.role),
                "sig" to PclinkJson.Text(PclinkBase64Url.encode(signature)),
            )
            sendControl(auth)
            try {
                withTimeout(configuration.readyTimeoutMillis) { ready.await() }
            } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
                throw PclinkError.AuthFailed("relay.ready timeout")
            }
            stateMutex.withLock {
                if (finished.get()) {
                    throw terminalError ?: PclinkError.Unavailable("relay closed during authentication")
                }
                state = State.READY
            }
            startHeartbeat()
        } catch (cancelled: CancellationException) {
            shutdown(null, null, PclinkError.Cancelled(), sendClose = true)
            throw cancelled
        } catch (failure: Throwable) {
            val mapped = failure as? PclinkError
                ?: PclinkError.Unavailable("relay authentication failed: ${failure.message}")
            shutdown(closeCodeFor(mapped), mapped.code, mapped)
            throw mapped
        }
    }

    /**
     * Writes one frame. Only `e2e` application frames are paced and queued on
     * the single writer (§3.8); `e2e.handshake` and relay-plane frames are
     * written immediately so a handshake step cannot sit behind an application
     * backlog. A phone never sends `relay.allow` (§3.3).
     */
    override suspend fun send(frame: PclinkJson) {
        if (state != State.READY) throw PclinkError.PeerOffline()
        val type = frame["type"]?.stringValue ?: throw PclinkError.BadFrame("relay frame has no type")
        validateOutbound(type, frame)
        val text = encodeFrame(frame)
        if (type == "e2e") {
            val pending = PendingSend(
                text = text,
                bytes = text.toByteArray(Charsets.UTF_8).size,
                paced = true,
                done = CompletableDeferred(),
            )
            if (!sendQueue.trySend(pending).isSuccess) throw PclinkError.PeerOffline()
            pending.done.await()
        } else {
            sendControl(frame)
        }
    }

    /**
     * Closes the connection and finishes [events]/[incoming]. Idempotent.
     */
    override suspend fun close(code: Int, reason: String) {
        shutdown(code, reason, null)
    }

    // ---- Receive path ----------------------------------------------------

    private suspend fun receiveLoop() {
        try {
            socket?.incoming?.collect { message ->
                when (message) {
                    is PclinkWebSocketMessage.Binary ->
                        throw BinaryFrameViolation()
                    is PclinkWebSocketMessage.Closed -> {
                        closeCode = message.code
                        closeReason = message.reason
                        val error = errorForCloseCode(message.code, message.reason)
                        shutdown(null, message.reason, error, sendClose = false)
                        throw StopReceive()
                    }
                    is PclinkWebSocketMessage.Text -> {
                        val bytes = message.text.toByteArray(Charsets.UTF_8).size
                        if (bytes > configuration.frameLimitBytes) {
                            throw PclinkError.FrameTooLarge("relay frame exceeds 16 MiB")
                        }
                        val frame = PclinkJsonParser.parseObject(message.text)
                        if (handleFrame(frame)) throw StopReceive()
                    }
                }
            }
            // The transport ended without an explicit close frame.
            shutdown(null, null, errorForCloseCode(null, null), sendClose = false)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: StopReceive) {
            // A terminal frame already shut the connection down.
        } catch (binary: BinaryFrameViolation) {
            shutdown(1003, "bad_frame", PclinkError.BadFrame("binary relay frame"))
        } catch (failure: PclinkError) {
            shutdown(closeCodeFor(failure), failure.code, failure)
        } catch (failure: Throwable) {
            shutdown(
                null,
                null,
                PclinkError.Unavailable("relay receive failed: ${failure.message}"),
                sendClose = false,
            )
        }
    }

    /** Returns true when handling ended the connection. */
    private suspend fun handleFrame(frame: PclinkJson): Boolean {
        when (val type = frame["type"]?.stringValue) {
            "relay.challenge" -> handleChallenge(frame)
            "relay.ready" -> handleReady(frame)
            "relay.error" -> return handleRelayError(frame)
            "relay.ping" -> {
                requireReadyForReceive()
                PclinkWire.validateRelayHeartbeat(frame)
                val nonce = frame.requiredString("nonce")
                sendControl(
                    pclinkObject(
                        "v" to PclinkJson.Integer(1),
                        "type" to PclinkJson.Text("relay.pong"),
                        "nonce" to PclinkJson.Text(nonce),
                    ),
                )
            }
            "relay.pong" -> {
                requireReadyForReceive()
                PclinkWire.validateRelayHeartbeat(frame)
                acceptPong(PclinkBase64Url.decode(frame.requiredString("nonce"), expectedLength = 16))
            }
            "relay.offline" -> {
                requireReadyForReceive()
                PclinkWire.validateRelayOffline(frame)
                emit(
                    PclinkRelayEvent.Offline(
                        PclinkRelayOffline(
                            to = frame.requiredString("to"),
                            id = frame["id"]?.stringValue,
                            streamId = frame["streamId"]?.stringValue,
                            sid = frame["sid"]?.stringValue,
                            frame = frame,
                        ),
                    ),
                )
            }
            "relay.redirect" -> {
                // Reserved (§3.6): a v1 client logs and ignores it, never acts.
                requireReadyForReceive()
                PclinkWire.validateRelayRedirect(frame)
            }
            "relay.pair.joined", "relay.pair.message", "relay.pair.close" -> {
                requireReadyForReceive()
                PclinkWire.validateRelayPair(frame)
                emit(PclinkRelayEvent.Frame(frame))
            }
            "e2e" -> {
                requireReadyForReceive()
                PclinkWire.validateE2EFrame(frame)
                emit(PclinkRelayEvent.Frame(frame))
            }
            "e2e.handshake" -> {
                requireReadyForReceive()
                PclinkWire.validateE2EHandshake(frame)
                emit(PclinkRelayEvent.Frame(frame))
            }
            "relay.allow", "peer.auth", "relay.pair.open", "relay.pair.join" ->
                throw PclinkError.BadFrame("unexpected relay frame $type")
            null -> throw PclinkError.BadFrame("relay frame has no type")
            else -> throw PclinkError.BadFrame("unknown relay frame type $type")
        }
        return false
    }

    private fun handleChallenge(frame: PclinkJson) {
        if (challengeSeen || state != State.CONNECTING) {
            throw PclinkError.BadFrame("unexpected relay.challenge")
        }
        val objectValue = frame.closedObject(setOf("v", "type", "nonce", "relay"))
        if (objectValue["v"]?.longValue != 1L ||
            objectValue["type"]?.stringValue != "relay.challenge"
        ) {
            throw PclinkError.BadFrame("relay.challenge header")
        }
        val nonce = PclinkBase64Url.decode(
            frame.requiredString("nonce"),
            expectedLength = 32,
        )
        val relay = frame.requiredString("relay")
        // §3.2: a challenge whose origin differs from the dialed origin is an
        // authentication failure, and an uppercase/non-canonical origin can
        // never equal the validated dialed origin. Compare before validating so
        // the negative origin rows map to auth_failed, not bad_frame.
        if (relay != configuration.origin) {
            throw PclinkError.AuthFailed("relay origin does not match the dialed origin")
        }
        challengeSeen = true
        challenge.complete(nonce)
    }

    private suspend fun handleReady(frame: PclinkJson) {
        if (readySeen || !challengeSeen) {
            throw PclinkError.BadFrame("unexpected relay.ready")
        }
        PclinkWire.validateRelayReady(frame)
        val machineId = frame.requiredString("machineId")
        val role = frame.requiredString("role")
        if (machineId != configuration.identity.machineId || role != configuration.role) {
            throw PclinkError.AuthFailed("relay.ready machineId/role mismatch")
        }
        // Accept the authenticated state here, not only after `connect` resumes:
        // the relay may legally send the next business frame (e.g. a
        // `relay.offline` for a queued prompt) immediately after `relay.ready`.
        stateMutex.withLock {
            if (finished.get()) {
                throw terminalError ?: PclinkError.Unavailable("relay closed during authentication")
            }
            state = State.READY
        }
        // Emit here, in the receive loop, so a business frame the relay sends
        // immediately after `relay.ready` can never be observed before Ready.
        emit(PclinkRelayEvent.Ready(configuration.identity.machineId, configuration.role))
        readySeen = true
        ready.complete(Unit)
    }

    private suspend fun handleRelayError(frame: PclinkJson): Boolean {
        PclinkWire.validateRelayError(frame)
        val code = frame.requiredString("code")
        val message = frame["message"]?.stringValue ?: ""
        val retryAfterMs = frame["retryAfterMs"]?.longValue?.toInt()
        val context = PclinkRelayErrorContext(
            id = frame["id"]?.stringValue,
            streamId = frame["streamId"]?.stringValue,
            sid = frame["sid"]?.stringValue,
            retryAfterMs = retryAfterMs,
        )
        val mapped = if (code == "rate_limited") {
            PclinkError.RateLimited(retryAfterMs)
        } else {
            PclinkError.fromCode(code, message)
        }
        emit(PclinkRelayEvent.Error(mapped, context, frame))
        // `rate_limited` is not terminal for the socket: the relay keeps the
        // connection, and the upper layer must invalidate its sessions, wait
        // retryAfterMs and re-handshake (§3.8). The other four are followed by
        // the relay's close; finish now so the caller sees them deterministically.
        if (code in TERMINAL_RELAY_ERROR_CODES) {
            shutdown(closeCodeFor(mapped), code, mapped)
            return true
        }
        return false
    }

    private fun requireReadyForReceive() {
        if (state != State.READY) throw PclinkError.BadFrame("frame before relay.ready")
    }

    private fun acceptPong(nonce: ByteArray) {
        while (true) {
            val current = outstandingPing.get() ?: return
            if (!current.contentEquals(nonce)) return
            if (outstandingPing.compareAndSet(current, null)) return
        }
    }

    // ---- Heartbeat -------------------------------------------------------

    private fun startHeartbeat() {
        if (!configuration.heartbeatEnabled) return
        heartbeatJob = scope.launch {
            while (state == State.READY) {
                delay(nextHeartbeatMillis())
                if (state != State.READY) return@launch
                if (outstandingPing.get() != null) {
                    // Two consecutive ping periods without a matching pong:
                    // close 1001 (§3.4). A pong for an old nonce never clears
                    // the outstanding ping.
                    shutdown(
                        HEARTBEAT_CLOSE_CODE,
                        "heartbeat timeout",
                        PclinkError.Unavailable("heartbeat timeout"),
                    )
                    return@launch
                }
                val nonce = PclinkRandom.bytes(16)
                outstandingPing.set(nonce)
                try {
                    sendControl(
                        pclinkObject(
                            "v" to PclinkJson.Integer(1),
                            "type" to PclinkJson.Text("relay.ping"),
                            "nonce" to PclinkJson.Text(PclinkBase64Url.encode(nonce)),
                        ),
                    )
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    val mapped = failure as? PclinkError
                        ?: PclinkError.Unavailable("relay heartbeat send failed: ${failure.message}")
                    shutdown(null, null, mapped, sendClose = false)
                    return@launch
                }
            }
        }
    }

    private fun nextHeartbeatMillis(): Long {
        val from = configuration.heartbeatRangeMillis.first
        val until = configuration.heartbeatRangeMillis.last
        if (from > until) throw PclinkError.BadFrame("heartbeat range is empty")
        if (from == until) return from
        return random.nextLong(from, until + 1)
    }

    // ---- Send path -------------------------------------------------------

    private fun startSendWriter() {
        if (sendWriter != null) return
        sendWriter = scope.launch { drainSendQueue() }
    }

    private suspend fun drainSendQueue() {
        for (item in sendQueue) {
            try {
                if (item.paced) {
                    while (true) {
                        val waitNanos = pacer.delayBeforeSending(item.bytes)
                        if (waitNanos <= 0) break
                        delay(nanosToCeilingMillis(waitNanos))
                    }
                    pacer.consume(item.bytes)
                }
                writeMutex.withLock {
                    val current = socket ?: throw PclinkError.PeerOffline()
                    current.sendText(item.text)
                }
                item.done.complete(Unit)
            } catch (cancelled: CancellationException) {
                item.done.completeExceptionally(PclinkError.Cancelled())
                throw cancelled
            } catch (failure: Throwable) {
                val mapped = failure as? PclinkError
                    ?: PclinkError.Unavailable("relay send failed: ${failure.message}")
                item.done.completeExceptionally(mapped)
                shutdown(closeCodeFor(mapped), mapped.code, mapped)
                return
            }
        }
    }

    private suspend fun sendControl(frame: PclinkJson) {
        val text = encodeFrame(frame)
        writeMutex.withLock {
            val current = socket ?: throw PclinkError.PeerOffline()
            current.sendText(text)
        }
    }

    private fun encodeFrame(frame: PclinkJson): String {
        val bytes = PclinkJsonEncoder.encode(frame)
        if (bytes.size > configuration.frameLimitBytes) {
            throw PclinkError.FrameTooLarge("relay frame exceeds 16 MiB")
        }
        return String(bytes, Charsets.UTF_8)
    }

    private fun validateOutbound(type: String, frame: PclinkJson) {
        when (type) {
            "e2e" -> PclinkWire.validateE2EFrame(frame)
            "e2e.handshake" -> PclinkWire.validateE2EHandshake(frame)
            "relay.pair.join" -> {
                if (configuration.role != "phone") throw PclinkError.BadFrame("only a phone joins a pairing slot")
                PclinkWire.validateRelayPair(frame)
            }
            "relay.pair.open" -> {
                if (configuration.role != "pc") throw PclinkError.BadFrame("only a PC opens a pairing slot")
                PclinkWire.validateRelayPair(frame)
            }
            "relay.pair.message", "relay.pair.close" -> PclinkWire.validateRelayPair(frame)
            "relay.allow" -> {
                // §3.3: only role:"pc" may send it; the Android client is a
                // phone and never sends `relay.allow`.
                if (configuration.role != "pc") throw PclinkError.BadFrame("only a PC sends relay.allow")
                PclinkWire.validateRelayFrame(frame)
            }
            "relay.ping", "relay.pong" ->
                throw PclinkError.BadFrame("heartbeats are owned by the relay client")
            "relay.challenge", "relay.ready", "relay.offline", "relay.error",
            "relay.redirect", "peer.auth",
            -> throw PclinkError.BadFrame("unexpected outbound relay frame $type")
            else -> throw PclinkError.BadFrame("unknown relay frame type $type")
        }
    }

    // ---- Teardown --------------------------------------------------------

    private suspend fun shutdown(
        code: Int?,
        reason: String?,
        error: PclinkError?,
        sendClose: Boolean = code != null,
    ) {
        stateMutex.withLock {
            if (finished.get()) return
            finished.set(true)
            terminalError = error
            state = State.CLOSED
        }
        heartbeatJob?.cancel()
        heartbeatJob = null
        sendWriter?.cancel()
        sendWriter = null
        sendQueue.close()
        val terminal = error ?: PclinkError.PeerOffline()
        while (true) {
            val pending = sendQueue.tryReceive().getOrNull() ?: break
            pending.done.completeExceptionally(terminal)
        }
        // Publish the close code before waking `connect()`: a caller that sees
        // the terminal error must also see the code it closed with.
        if (code != null) closeCode = code
        if (reason != null) closeReason = reason
        challenge.completeExceptionally(error ?: PclinkError.Unavailable("relay connection closed"))
        ready.completeExceptionally(error ?: PclinkError.Unavailable("relay connection closed"))
        emit(PclinkRelayEvent.Closed(closeCode, closeReason, error))
        eventChannel.close(error)
        val current = socket
        socket = null
        if (sendClose && current != null) {
            withContext(NonCancellable) {
                try {
                    current.close(code ?: 1000, reason ?: "")
                } catch (_: Throwable) {
                    // Best effort: the connection is already going away.
                }
            }
        }
    }

    private fun emit(event: PclinkRelayEvent) {
        eventChannel.trySend(event)
    }

    private fun closeCodeFor(error: PclinkError): Int = when (error) {
        is PclinkError.AuthFailed -> 4002
        is PclinkError.Replaced -> 4001
        is PclinkError.FrameTooLarge -> 1009
        else -> 1008
    }

    private fun errorForCloseCode(code: Int?, reason: String?): PclinkError? = when (code) {
        null -> PclinkError.Unavailable("relay connection closed")
        1000 -> null
        1001 -> PclinkError.Unavailable(reason?.takeIf { it.isNotEmpty() } ?: "relay going away")
        1003 -> PclinkError.BadFrame("binary relay frame")
        1008 -> PclinkError.BadFrame(reason?.takeIf { it.isNotEmpty() } ?: "relay policy close")
        1009 -> PclinkError.FrameTooLarge(reason?.takeIf { it.isNotEmpty() } ?: "relay frame too large")
        4001 -> PclinkError.Replaced()
        4002 -> PclinkError.AuthFailed(reason?.takeIf { it.isNotEmpty() } ?: "relay authentication failed")
        4003 -> PclinkError.RateLimited(null)
        4004 -> PclinkError.SessionExpired(reason?.takeIf { it.isNotEmpty() } ?: "relay session expired")
        else -> PclinkError.Unavailable("relay closed ($code)")
    }

    private class BinaryFrameViolation : Exception()

    private class StopReceive : Exception()

    private fun nanosToCeilingMillis(nanos: Long): Long = max(1L, (nanos + 999_999L) / 1_000_000L)

    companion object {
        const val HEARTBEAT_CLOSE_CODE: Int = 1001
        private val TERMINAL_RELAY_ERROR_CODES =
            setOf("auth_failed", "replaced", "bad_frame", "frame_too_large")
    }
}

/**
 * The C3 `PclinkRelayLinkFactory`: derives the paired origin from the canonical
 * `ws`/`wss` URL (the form `PclinkValidation.websocketUrl` produces), dials it
 * with [PclinkRelayClient], and returns it only after `relay.ready`.
 */
class PclinkRelayClientFactory(
    private val identity: PclinkIdentity,
    private val role: String = "phone",
    private val challengeTimeoutMillis: Long = 10_000,
    private val readyTimeoutMillis: Long = 10_000,
    private val heartbeatRangeMillis: LongRange =
        (PclinkLimits.HEARTBEAT_RANGE.first * 1_000L)..(PclinkLimits.HEARTBEAT_RANGE.last * 1_000L),
    private val heartbeatEnabled: Boolean = true,
    private val socketFactory: PclinkWebSocketFactory = KtorPclinkWebSocketFactory(),
) : PclinkRelayLinkFactory, AutoCloseable {
    override suspend fun connect(url: String): PclinkRelayLink {
        val origin = originForWebSocketUrl(url)
        val client = PclinkRelayClient(
            configuration = PclinkRelayClient.Configuration(
                origin = origin,
                identity = identity,
                role = role,
                challengeTimeoutMillis = challengeTimeoutMillis,
                readyTimeoutMillis = readyTimeoutMillis,
                heartbeatRangeMillis = heartbeatRangeMillis,
                heartbeatEnabled = heartbeatEnabled,
            ),
            socketFactory = socketFactory,
        )
        client.connect()
        return client
    }

    override fun close() {
        (socketFactory as? AutoCloseable)?.close()
    }

    companion object {
        /**
         * `wss://relay.example/` -> `https://relay.example` (and `ws` -> `http`);
         * the path is exactly `/` and the result must be a canonical origin
         * (§3.1). The relay challenge must equal this dialed origin.
         */
        fun originForWebSocketUrl(url: String): String {
            val scheme = when {
                url.startsWith("wss://") -> "https"
                url.startsWith("ws://") -> "http"
                else -> throw PclinkError.BadFrame("relay URL is not ws(s)")
            }
            val prefix = if (scheme == "https") "wss://" else "ws://"
            val rest = url.removePrefix(prefix)
            if (!rest.endsWith("/")) throw PclinkError.BadFrame("relay URL must end with /")
            val authority = rest.dropLast(1)
            if (authority.isEmpty() || authority.contains('/')) {
                throw PclinkError.BadFrame("relay URL has a path")
            }
            val origin = "$scheme://$authority"
            PclinkValidation.origin(origin)
            return origin
        }
    }
}

/**
 * §10 reconnect policy: 0.5 s, 1 s, 2 s, 4 s, 8 s, 16 s, 30 s, then 30 s, each
 * with ±20 % jitter; reset after 60 s of a successful connection. A replaced
 * client waits at least 30 s (§3.2); a phone-initiated resume caps the next
 * delay at the second step (1 s ±20 %) and never shortens the replaced wait.
 */
class PclinkReconnectPolicy(
    val delaysSeconds: List<Double> = listOf(0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0),
    val jitterFraction: Double = 0.2,
    val resetAfterSeconds: Double = PclinkLimits.RECONNECT_RESET_AFTER.seconds.toDouble(),
    val replacedMinimumDelaySeconds: Double = 30.0,
) {
    init {
        require(delaysSeconds.isNotEmpty() && delaysSeconds.all { it > 0 }) {
            "reconnect delays must be non-empty and positive"
        }
        require(jitterFraction in 0.0..1.0) { "jitter fraction must be in [0, 1]" }
        require(resetAfterSeconds > 0) { "reset delay must be positive" }
        require(replacedMinimumDelaySeconds > 0) { "replaced delay must be positive" }
    }

    /** `attempt` is 1-based; values past the list repeat the last delay. */
    fun baseDelaySeconds(attempt: Int): Double {
        val index = min(max(attempt, 1) - 1, delaysSeconds.size - 1)
        return delaysSeconds[index]
    }

    fun delaySeconds(attempt: Int, jitter: Double): Double {
        val clamped = min(max(jitter, 0.0), 1.0)
        val factor = 1 + jitterFraction * (clamped * 2 - 1)
        return baseDelaySeconds(attempt) * factor
    }

    fun delaySeconds(attempt: Int): Double =
        delaySeconds(attempt, Random.Default.nextDouble())

    /** A phone-initiated resume: at most the second step, 1 s ±20 % (§10). */
    fun resumeDelaySeconds(attempt: Int, jitter: Double): Double {
        val clamped = min(max(jitter, 0.0), 1.0)
        val factor = 1 + jitterFraction * (clamped * 2 - 1)
        return min(baseDelaySeconds(attempt), RESUME_CAP_SECONDS) * factor
    }

    /** `replaced`: never below 30 s (§3.2/§9.1). */
    fun replacedDelaySeconds(attempt: Int, jitter: Double): Double =
        max(replacedMinimumDelaySeconds, delaySeconds(attempt, jitter))

    /**
     * §3.8: after `relay.error{code:"rate_limited"}` the caller waits at least
     * `retryAfterMs` (a missing value means at least 1 000 ms) before the next
     * handshake.
     */
    fun rateLimitedDelaySeconds(retryAfterMs: Int?): Double =
        max(MIN_RATE_LIMIT_WAIT_SECONDS, (retryAfterMs ?: 0).coerceAtLeast(0) / 1_000.0)

    companion object {
        const val RESUME_CAP_SECONDS: Double = 1.0
        const val MIN_RATE_LIMIT_WAIT_SECONDS: Double = 1.0
        val V1: PclinkReconnectPolicy = PclinkReconnectPolicy()
    }
}

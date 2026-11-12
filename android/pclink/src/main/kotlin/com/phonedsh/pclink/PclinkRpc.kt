// SPDX-License-Identifier: MIT
// `workspace/1` request/response over one established PCLink E2E session
// (§6.1, §6.2, §7). This file owns the phone side of `rpc.call`/`rpc.result`,
// chunk reassembly, stream framing, cancellation, request-id allocation and the
// retry classification. It never derives keys, builds an E2E frame or interprets
// `seq`/`sid`: those checks live in `PclinkE2eSession` (C2), and C4 consumes its
// decoded inner messages only. `PclinkDshTransport` is the DSH-facing adapter.
package com.phonedsh.pclink

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.SecureRandom
import java.time.Duration
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

/** Tunables for [PclinkRpc]; defaults are the frozen §6.2 values. */
data class PclinkRpcConfiguration(
    /** §6.2: 30 s inactivity per value, measured from the last accepted chunk. */
    val chunkReassemblyTimeout: Duration = PclinkLimits.CHUNK_REASSEMBLY_TIMEOUT,
    /**
     * How long a `read`/`idempotent` call may keep retrying across lost
     * sessions before it reports the last transport error. §7 does not fix a
     * number; this mirrors the iOS client's 120 s budget and is injectable for
     * tests. An `unsafe` call never retries.
     */
    val retryDeadline: Duration = DEFAULT_RETRY_DEADLINE,
    /** Delay between reconnect-driven retry attempts. */
    val retryDelay: Duration = Duration.ofMillis(20),
    /** How often the session watcher checks whether the bound session vanished. */
    val sessionPollInterval: Duration = Duration.ofMillis(100),
) {
    init {
        require(!chunkReassemblyTimeout.isNegative && !chunkReassemblyTimeout.isZero) {
            "chunkReassemblyTimeout must be positive"
        }
        require(!retryDeadline.isNegative && !retryDeadline.isZero) { "retryDeadline must be positive" }
        require(!retryDelay.isNegative) { "retryDelay must not be negative" }
        require(!sessionPollInterval.isNegative && !sessionPollInterval.isZero) {
            "sessionPollInterval must be positive"
        }
    }

    companion object {
        val DEFAULT_RETRY_DEADLINE: Duration = Duration.ofSeconds(120)
    }
}

/**
 * One chunk of a split JSON value (§6.2). [data] is the unpadded base64url of a
 * contiguous byte range of the JSON encoding; [part] starts at 0 and [last] is
 * true exactly on the final chunk.
 */
data class PclinkRpcChunk(val part: Long, val last: Boolean, val data: String)

/** Splits a value the way the PC sender must split `rpc.*.chunk` frames. */
object PclinkRpcChunking {
    /**
     * Encodes [value] once and cuts the bytes into chunks of at most
     * [chunkBytes] raw bytes. The final chunk carries `last=true`; a value
     * whose encoding fits in one chunk is returned as that single chunk (a
     * caller sending a stream item uses `rpc.stream.item` instead, §6.2).
     */
    fun split(value: PclinkJson, chunkBytes: Int = PclinkLimits.CHUNK_THRESHOLD_BYTES): List<PclinkRpcChunk> {
        require(chunkBytes in 1..PclinkLimits.MAX_VALUE_BYTES) { "invalid chunk size" }
        val bytes = PclinkJsonEncoder.encode(value)
        if (bytes.size > PclinkLimits.MAX_VALUE_BYTES) {
            throw PclinkError.FrameTooLarge("value exceeds 8 MiB")
        }
        if (bytes.isEmpty()) return listOf(PclinkRpcChunk(0, true, ""))
        val chunks = ArrayList<PclinkRpcChunk>()
        var offset = 0
        var part = 0L
        while (offset < bytes.size) {
            val end = minOf(offset + chunkBytes, bytes.size)
            val data = PclinkBase64Url.encode(bytes.copyOfRange(offset, end))
            chunks.add(PclinkRpcChunk(part, end == bytes.size, data))
            offset = end
            part += 1
        }
        return chunks
    }
}

/**
 * Shared §6.2 receiver-buffer budget. Every active reassembler reserves the
 * bytes it holds, so the 16 MiB total is enforced across streams/ids rather
 * than per value only. Thread-safe: the client reader and a timer may race.
 */
internal class PclinkChunkReassemblyBudget(private val maxTotalBytes: Int) {
    private val used = java.util.concurrent.atomic.AtomicInteger(0)

    val totalBytes: Int get() = used.get()

    fun tryReserve(bytes: Int): Boolean {
        if (bytes <= 0) return true
        while (true) {
            val current = used.get()
            val next = current + bytes
            if (next > maxTotalBytes) return false
            if (used.compareAndSet(current, next)) return true
        }
    }

    fun release(bytes: Int) {
        if (bytes <= 0) return
        used.addAndGet(-bytes)
    }
}

/**
 * §6.2 chunk reassembly. One instance holds every partial value for one
 * namespace (result ids or stream ids); values for different keys may
 * interleave and are never mixed. A malformed sequence, a value above 8 MiB,
 * more than 16 MiB of partial state or a 30 s inactivity gap discards the
 * partial value and throws the exact §9.1 code.
 */
internal class PclinkChunkReassembler(
    private val maxValueBytes: Int = PclinkLimits.MAX_VALUE_BYTES,
    maxTotalBytes: Int = MAX_TOTAL_BUFFER_BYTES,
    private val budget: PclinkChunkReassemblyBudget = PclinkChunkReassemblyBudget(maxTotalBytes),
) {
    private class Buffer(
        var expectedPart: Long,
        var bytes: ByteArray,
        var lastAcceptedAtMillis: Long,
    )

    private val buffers = LinkedHashMap<String, Buffer>()

    val pendingKeys: Set<String>
        get() = buffers.keys.toSet()

    val bufferedBytes: Int
        get() = buffers.values.sumOf { it.bytes.size }

    fun discard(key: String) {
        buffers.remove(key)?.let { budget.release(it.bytes.size) }
    }

    fun discardAll() {
        for (buffer in buffers.values) budget.release(buffer.bytes.size)
        buffers.clear()
    }

    /** Asserts that no partial value is left unfinished (the interleave model row). */
    fun finish() {
        if (buffers.isNotEmpty()) {
            discardAll()
            throw PclinkError.BadFrame("chunk sequence is missing its last part")
        }
    }

    /**
     * Accepts one chunk. Returns the reassembled bytes when [last] completes the
     * sequence, `null` while more chunks are needed.
     */
    fun accept(
        key: String,
        part: Long,
        last: Boolean,
        data: String,
        nowMillis: Long,
        timeoutMillis: Long,
    ): ByteArray? {
        try {
            if (part < 0) throw PclinkError.BadFrame("chunk part out of range")
            if (data.length > PclinkLimits.MAX_CHUNK_CHARACTERS) {
                throw PclinkError.FrameTooLarge("chunk data exceeds 1,500,000 characters")
            }
            val decoded = try {
                PclinkBase64Url.decode(data)
            } catch (error: PclinkError) {
                throw PclinkError.BadFrame("chunk data is not canonical b64url: ${error.message}")
            }
            val existing = buffers[key]
            val buffer: Buffer
            if (existing != null) {
                if (nowMillis - existing.lastAcceptedAtMillis > timeoutMillis) {
                    throw PclinkError.BadFrame("chunk sequence timed out")
                }
                if (part != existing.expectedPart) {
                    throw PclinkError.BadFrame("chunk part order violation")
                }
                buffer = existing
            } else {
                if (part != 0L) throw PclinkError.BadFrame("chunk sequence did not start at part 0")
                buffer = Buffer(expectedPart = 0L, bytes = ByteArray(0), lastAcceptedAtMillis = nowMillis)
            }
            if (buffer.bytes.size.toLong() + decoded.size > maxValueBytes) {
                throw PclinkError.FrameTooLarge("reassembled value exceeds 8 MiB")
            }
            if (!budget.tryReserve(decoded.size)) {
                throw PclinkError.FrameTooLarge("chunk reassembly buffers exceed 16 MiB")
            }
            buffer.bytes = buffer.bytes + decoded
            buffer.expectedPart += 1
            buffer.lastAcceptedAtMillis = nowMillis
            if (last) {
                buffers.remove(key)
                budget.release(buffer.bytes.size)
                return requireOneJsonValue(buffer.bytes)
            }
            buffers[key] = buffer
            return null
        } catch (error: Exception) {
            buffers.remove(key)?.let { budget.release(it.bytes.size) }
            throw error
        }
    }

    /** Strict UTF-8 once, then exactly one JSON value (§6.2). */
    private fun requireOneJsonValue(bytes: ByteArray): ByteArray {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        try {
            decoder.decode(ByteBuffer.wrap(bytes))
        } catch (_: CharacterCodingException) {
            throw PclinkError.BadFrame("reassembled value is not UTF-8")
        }
        PclinkJsonParser.parse(bytes)
        return bytes
    }

    companion object {
        const val MAX_TOTAL_BUFFER_BYTES: Int = 16 shl 20 // 16 MiB
    }
}

/**
 * The phone-side `workspace/1` RPC state machine. It implements C2's
 * [PclinkRpcHost] so `PclinkClient` can hand every authenticated post-handshake
 * inner message to it; outbound messages go through the same client's
 * `sendInner` (the only sealer/writer), so this class never builds a wire frame.
 *
 * Construction is two-step because `PclinkClient` needs the host in its
 * constructor:
 *
 * ```kotlin
 * val rpc = PclinkRpc()
 * val client = PclinkClient(..., rpcHost = rpc)
 * rpc.attach(client)
 * ```
 *
 * [close] is idempotent; a new instance is required after it.
 */
class PclinkRpc(
    private val configuration: PclinkRpcConfiguration = PclinkRpcConfiguration(),
    private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000L },
) : PclinkRpcHost {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val lock = Any()
    private val random = SecureRandom()

    @Volatile
    private var channel: PclinkRpcChannel? = null

    @Volatile
    private var closed = false

    private var callCounter = 0L
    private var streamCounter = 0L
    private val chunkBudget = PclinkChunkReassemblyBudget(PclinkChunkReassembler.MAX_TOTAL_BUFFER_BYTES)
    private val pendingCalls = LinkedHashMap<String, PendingCall>()
    private val streams = LinkedHashMap<String, PclinkRpcStream>()
    private val usedStreamIds = HashSet<String>()
    private var usedStreamSid: String? = null
    private var watcherRunning = false

    /** Binds the real client; call once, after the client is constructed. */
    fun attach(client: PclinkClient) {
        attach(ClientRpcChannel(client))
    }

    internal fun attach(channel: PclinkRpcChannel) {
        check(!closed) { "PclinkRpc is closed" }
        this.channel = channel
    }

    override fun activeSession(): PclinkE2eSession? = channel?.activeSession()

    /**
     * C2's inbound delivery point. The name is the frozen C2 seam; the
     * direction here is client → RPC. Outbound RPC messages use the attached
     * client's `sendInner`.
     */
    override suspend fun sendInner(inner: PclinkJson) {
        receive(inner)
    }

    // ---- Unary calls ---------------------------------------------------

    /**
     * Sends one `rpc.call` and returns the DSH `result` value (§6.1). A DSH
     * endpoint error is thrown as [PclinkRpcError]; a transport failure is a
     * [PclinkError]. `read`/`idempotent` calls retry across lost sessions with a
     * fresh correlation id until [PclinkRpcConfiguration.retryDeadline]; an
     * `unsafe` call that was sent becomes [PclinkError.UnknownOutcome].
     */
    suspend fun call(endpoint: String, args: PclinkJson): PclinkJson {
        validateRequest(endpoint, args)
        if (isClosed()) throw PclinkError.Cancelled()
        val retry = PclinkEndpoints.retryClass(endpoint)
        val deadline = nowMillis() + configuration.retryDeadline.toMillis()
        var lastError: PclinkError = PclinkError.PeerOffline()
        while (true) {
            ensureOpen()
            currentCoroutineContext().ensureActive()
            awaitSession(deadline)
            val id = allocateCallId()
            val sid = channel?.activeSession()?.sid
                ?: throw PclinkError.PeerOffline()
            val pending = PendingCall(id, endpoint, args, retry, sid, chunkBudget)
            synchronized(lock) {
                if (closed) throw PclinkError.Cancelled()
                pendingCalls[id] = pending
                ensureWatcherLocked()
            }
            var sent = false
            try {
                try {
                    outboundSend(
                        pclinkObject(
                            "type" to PclinkJson.Text("rpc.call"),
                            "id" to PclinkJson.Text(id),
                            "endpoint" to PclinkJson.Text(endpoint),
                            "args" to args,
                        ),
                    )
                    sent = true
                } catch (error: PclinkError) {
                    if (isDefinitiveSendError(error)) throw error
                    lastError = error
                    if (retry == PclinkRetryClass.UNSAFE) throw PclinkError.UnknownOutcome(endpoint)
                }
                if (sent) {
                    val result = try {
                        pending.result.await()
                    } catch (lost: RpcSessionLost) {
                        lastError = lost.reason
                        if (retry == PclinkRetryClass.UNSAFE) throw PclinkError.UnknownOutcome(endpoint)
                        null
                    }
                    if (result != null) return result
                }
            } finally {
                unregisterCall(pending)
            }
            if (nowMillis() >= deadline) throw lastError
            delay(configuration.retryDelay.toMillis())
        }
    }

    // ---- Streams -------------------------------------------------------

    /**
     * Opens one `rpc.stream.open` (§6.2). The returned handle receives values
     * from [PclinkRpcStream.next] and is terminal on `rpc.stream.end`/`error`,
     * cancellation or session loss. [wireId] is only for tests/mux adapters; it
     * is unique per session and never reused.
     */
    suspend fun openStream(
        endpoint: String,
        args: PclinkJson,
        wireId: String? = null,
    ): PclinkRpcStream {
        validateRequest(endpoint, args)
        if (isClosed()) throw PclinkError.Cancelled()
        val retry = PclinkEndpoints.retryClass(endpoint)
        val deadline = nowMillis() + configuration.retryDeadline.toMillis()
        var lastError: PclinkError = PclinkError.PeerOffline()
        var requested = wireId
        while (true) {
            ensureOpen()
            currentCoroutineContext().ensureActive()
            val session = awaitSession(deadline)
            val id = allocateStreamId(requested, session.sid)
            requested = null
            val stream = PclinkRpcStream(id, endpoint, retry, session.sid, chunkBudget, this)
            synchronized(lock) {
                if (closed) throw PclinkError.Cancelled()
                streams[id] = stream
                ensureWatcherLocked()
            }
            try {
                outboundSend(
                    pclinkObject(
                        "type" to PclinkJson.Text("rpc.stream.open"),
                        "streamId" to PclinkJson.Text(id),
                        "endpoint" to PclinkJson.Text(endpoint),
                        "payload" to pclinkObject("args" to args),
                    ),
                )
                return stream
            } catch (error: PclinkError) {
                removeStream(stream)
                if (isDefinitiveSendError(error)) throw error
                lastError = error
                if (retry == PclinkRetryClass.UNSAFE) throw PclinkError.UnknownOutcome(endpoint)
            }
            if (nowMillis() >= deadline) throw lastError
            delay(configuration.retryDelay.toMillis())
        }
    }

    internal suspend fun cancelStream(stream: PclinkRpcStream) {
        synchronized(lock) {
            if (streams[stream.wireId] !== stream || stream.cancelled) return
            stream.cancelled = true
        }
        // Unblock a waiting next() immediately; the stream stays in the routing
        // table so late items/chunks are discarded until end/error/session loss.
        stream.finish(null)
        try {
            outboundSend(
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.cancel"),
                    "streamId" to PclinkJson.Text(stream.wireId),
                ),
            )
        } catch (_: Exception) {
            // The session may already be gone; the cancel is best-effort.
        }
    }

    internal fun closeStream(stream: PclinkRpcStream) {
        val wasOpen = removeStream(stream)
        stream.finish(null)
        if (wasOpen) scope.launch { sendCancel(stream.wireId) }
    }

    private suspend fun sendCancel(wireId: String) {
        try {
            outboundSend(
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.cancel"),
                    "streamId" to PclinkJson.Text(wireId),
                ),
            )
        } catch (_: Exception) {
            // The session may already be gone; the cancel is best-effort.
        }
    }

    /** Cancels every pending call/stream and releases the watcher. */
    fun close() {
        val lostCalls: List<PendingCall>
        val lostStreams: List<PclinkRpcStream>
        synchronized(lock) {
            if (closed) return
            closed = true
            lostCalls = pendingCalls.values.toList()
            lostStreams = streams.values.toList()
            pendingCalls.clear()
            streams.clear()
            watcherRunning = false
        }
        for (call in lostCalls) {
            call.chunkTimer?.cancel()
            call.result.completeExceptionally(PclinkError.Cancelled())
        }
        for (stream in lostStreams) {
            stream.finish(PclinkError.Cancelled())
        }
        scope.cancel()
    }

    // ---- Inbound inner messages ---------------------------------------

    private fun receive(inner: PclinkJson) {
        if (isClosed()) return
        when (val type = inner["type"]?.stringValue) {
            "rpc.result" -> handleResult(inner)
            "rpc.result.chunk" -> handleResultChunk(inner)
            "rpc.stream.item" -> handleStreamItem(inner)
            "rpc.stream.chunk" -> handleStreamChunk(inner)
            "rpc.stream.end" -> handleStreamEnd(inner)
            "rpc.stream.error" -> handleStreamError(inner)
            "rpc.call", "rpc.stream.open", "rpc.stream.cancel" ->
                throw PclinkError.BadFrame("unexpected $type from the PC")
            else -> {
                if (type == null) throw PclinkError.BadFrame("inner message has no type")
                // peer.hello/notice/session.close are consumed by C2 before the host.
            }
        }
    }

    private fun handleResult(inner: PclinkJson) {
        val id = inner["id"]?.stringValue ?: throw PclinkError.BadFrame("rpc.result without id")
        val pending = synchronized(lock) { pendingCalls[id] } ?: return
        if (pending.chunking) {
            failCall(pending, PclinkError.BadFrame("rpc.result arrived during chunked result"))
            return
        }
        dispatchResult(pending, inner)
    }

    private fun handleResultChunk(inner: PclinkJson) {
        val id = inner["id"]?.stringValue ?: throw PclinkError.BadFrame("rpc.result.chunk without id")
        val pending = synchronized(lock) { pendingCalls[id] } ?: return // late chunk: discard
        val part = inner["part"]?.longValue
            ?: throw PclinkError.BadFrame("rpc.result.chunk part")
        val last = inner["last"]?.boolValue
            ?: throw PclinkError.BadFrame("rpc.result.chunk last")
        val data = inner["data"]?.stringValue
            ?: throw PclinkError.BadFrame("rpc.result.chunk data")
        pending.chunking = true
        pending.lastChunkAtMillis = nowMillis()
        val completed = try {
            pending.chunks.accept(
                key = "result:$id",
                part = part,
                last = last,
                data = data,
                nowMillis = nowMillis(),
                timeoutMillis = configuration.chunkReassemblyTimeout.toMillis(),
            )
        } catch (error: PclinkError) {
            failCall(pending, error)
            return
        }
        if (completed == null) {
            restartChunkTimer(pending)
            return
        }
        pending.chunkTimer?.cancel()
        val result = try {
            PclinkJsonParser.parseObject(completed)
        } catch (error: PclinkError) {
            failCall(pending, PclinkError.BadFrame("chunked rpc.result is not one JSON object"))
            return
        }
        if (result["type"]?.stringValue != "rpc.result" || result["id"]?.stringValue != id) {
            failCall(pending, PclinkError.BadFrame("chunked rpc.result mismatch"))
            return
        }
        dispatchResult(pending, result)
    }

    private fun dispatchResult(pending: PendingCall, result: PclinkJson) {
        val members = try {
            result.closedObject(
                required = setOf("type", "id", "ok"),
                optional = setOf("result", "error"),
            )
        } catch (error: PclinkError) {
            failCall(pending, PclinkError.BadFrame("rpc.result header"))
            return
        }
        if (members["type"]?.stringValue != "rpc.result" ||
            members["id"]?.stringValue != pending.id ||
            !PclinkValidation.isCorrelationId(pending.id)
        ) {
            failCall(pending, PclinkError.BadFrame("rpc.result header"))
            return
        }
        val ok = members["ok"]?.boolValue
        if (ok == null) {
            failCall(pending, PclinkError.BadFrame("rpc.result ok"))
            return
        }
        if (ok) {
            val value = members["result"]
            if (value == null || members["error"] != null) {
                failCall(pending, PclinkError.BadFrame("rpc.result ok/result mismatch"))
                return
            }
            unregisterCall(pending)
            pending.result.complete(value)
            return
        }
        val errorValue = members["error"]
        if (members["result"] != null || errorValue == null) {
            failCall(pending, PclinkError.BadFrame("rpc.result ok/error mismatch"))
            return
        }
        val errorMembers = try {
            errorValue.closedObject(required = setOf("code", "message"), optional = setOf("details"))
        } catch (_: PclinkError) {
            failCall(pending, PclinkError.BadFrame("rpc.result error shape"))
            return
        }
        val code = errorMembers["code"]?.stringValue
        val message = errorMembers["message"]?.stringValue
        if (code == null || code.indexOf('\u0000') >= 0 || message == null) {
            failCall(pending, PclinkError.BadFrame("rpc.result error shape"))
            return
        }
        try {
            PclinkValidation.displayText(message, "rpc.result.error.message", maximumBytes = 2048, minimumBytes = 1)
        } catch (_: PclinkError) {
            failCall(pending, PclinkError.BadFrame("rpc.result error message invalid"))
            return
        }
        unregisterCall(pending)
        pending.result.completeExceptionally(
            PclinkRpcError(code = code, message = message, details = errorMembers["details"]),
        )
    }

    private fun failCall(pending: PendingCall, error: PclinkError) {
        unregisterCall(pending)
        pending.result.completeExceptionally(error)
    }

    private fun failCallLost(pending: PendingCall, reason: PclinkError) {
        unregisterCall(pending)
        pending.result.completeExceptionally(RpcSessionLost(reason))
    }

    private fun unregisterCall(pending: PendingCall) {
        synchronized(lock) {
            if (pendingCalls[pending.id] === pending) pendingCalls.remove(pending.id)
        }
        pending.chunkTimer?.cancel()
        pending.chunkTimer = null
        pending.chunks.discardAll()
    }

    private fun restartChunkTimer(pending: PendingCall) {
        pending.chunkTimer?.cancel()
        pending.chunkTimer = scope.launch {
            delay(configuration.chunkReassemblyTimeout.toMillis())
            expireResultChunk(pending)
        }
    }

    private fun expireResultChunk(pending: PendingCall) {
        synchronized(lock) {
            if (pendingCalls[pending.id] !== pending || !pending.chunking) return
        }
        // A chunk may have arrived after this timer was scheduled but before it
        // ran; the acceptance timestamp is authoritative (30 s from the last
        // accepted chunk, §6.2).
        if (nowMillis() - pending.lastChunkAtMillis < configuration.chunkReassemblyTimeout.toMillis()) {
            restartChunkTimer(pending)
            return
        }
        pending.chunks.discard("result:${pending.id}")
        when (pending.retry) {
            PclinkRetryClass.UNSAFE ->
                failCall(pending, PclinkError.UnknownOutcome(pending.endpoint))
            PclinkRetryClass.READ, PclinkRetryClass.IDEMPOTENT ->
                failCallLost(pending, PclinkError.SessionExpired("result chunk sequence timed out"))
        }
    }

    private fun handleStreamItem(inner: PclinkJson) {
        val stream = streamFor(inner) ?: return
        if (stream.cancelled) return
        val members = try {
            inner.closedObject(setOf("type", "streamId", "value"))
        } catch (_: PclinkError) {
            failStream(stream, PclinkError.BadFrame("rpc.stream.item shape"), cancel = false)
            return
        }
        if (stream.chunks.pendingKeys.isNotEmpty()) {
            failStream(stream, PclinkError.BadFrame("rpc.stream.item interleaved with a chunk sequence"), cancel = true)
            return
        }
        val value = members["value"] ?: return
        if (PclinkJsonEncoder.encode(value).size > PclinkLimits.MAX_VALUE_BYTES) {
            failStream(stream, PclinkError.FrameTooLarge("value exceeds 8 MiB"), cancel = true)
            return
        }
        stream.events.trySend(PclinkRpcStreamEvent.Item(value))
    }

    private fun handleStreamChunk(inner: PclinkJson) {
        val stream = streamFor(inner) ?: return
        if (stream.cancelled) return
        val members = try {
            inner.closedObject(setOf("type", "streamId", "part", "last", "data"))
        } catch (_: PclinkError) {
            failStream(stream, PclinkError.BadFrame("rpc.stream.chunk shape"), cancel = false)
            return
        }
        val part = members["part"]?.longValue
        val last = members["last"]?.boolValue
        val data = members["data"]?.stringValue
        if (part == null || last == null || data == null) {
            failStream(stream, PclinkError.BadFrame("rpc.stream.chunk shape"), cancel = false)
            return
        }
        stream.lastChunkAtMillis = nowMillis()
        val completed = try {
            stream.chunks.accept(
                key = stream.wireId,
                part = part,
                last = last,
                data = data,
                nowMillis = nowMillis(),
                timeoutMillis = configuration.chunkReassemblyTimeout.toMillis(),
            )
        } catch (error: PclinkError) {
            failStream(stream, error, cancel = error is PclinkError.FrameTooLarge)
            return
        }
        if (completed == null) {
            restartStreamTimeout(stream)
            return
        }
        stream.chunkTimer?.cancel()
        stream.chunkTimer = null
        val value = try {
            PclinkJsonParser.parse(completed)
        } catch (_: PclinkError) {
            failStream(stream, PclinkError.BadFrame("stream chunk is not one JSON value"), cancel = true)
            return
        }
        stream.events.trySend(PclinkRpcStreamEvent.Item(value))
    }

    private fun handleStreamEnd(inner: PclinkJson) {
        val stream = streamFor(inner) ?: return
        try {
            inner.closedObject(setOf("type", "streamId"))
        } catch (_: PclinkError) {
            failStream(stream, PclinkError.BadFrame("rpc.stream.end shape"), cancel = false)
            return
        }
        if (stream.chunks.pendingKeys.isNotEmpty()) {
            failStream(stream, PclinkError.BadFrame("stream chunk sequence is missing its last part"), cancel = false)
            return
        }
        removeStream(stream)
        stream.finish(null)
    }

    private fun handleStreamError(inner: PclinkJson) {
        val stream = streamFor(inner) ?: return
        val members = try {
            inner.closedObject(setOf("type", "streamId", "error"))
        } catch (_: PclinkError) {
            failStream(stream, PclinkError.BadFrame("rpc.stream.error shape"), cancel = false)
            return
        }
        val errorValue = members["error"]
        val errorMembers = try {
            errorValue?.closedObject(required = setOf("code", "message"), optional = setOf("details"))
        } catch (_: PclinkError) {
            null
        }
        val code = errorMembers?.get("code")?.stringValue
        val message = errorMembers?.get("message")?.stringValue
        if (code == null || message == null || code.indexOf('\u0000') >= 0) {
            failStream(stream, PclinkError.BadFrame("rpc.stream.error shape"), cancel = false)
            return
        }
        try {
            PclinkValidation.displayText(message, "rpc.stream.error.message", maximumBytes = 2048, minimumBytes = 1)
        } catch (_: PclinkError) {
            failStream(stream, PclinkError.BadFrame("rpc.stream.error message invalid"), cancel = false)
            return
        }
        removeStream(stream)
        stream.finish(PclinkRpcError(code, message, errorMembers["details"]))
    }

    private fun streamFor(inner: PclinkJson): PclinkRpcStream? {
        val id = inner["streamId"]?.stringValue ?: throw PclinkError.BadFrame("stream frame without streamId")
        return synchronized(lock) { streams[id] }
    }

    private fun restartStreamTimeout(stream: PclinkRpcStream) {
        stream.chunkTimer?.cancel()
        stream.chunkTimer = scope.launch {
            delay(configuration.chunkReassemblyTimeout.toMillis())
            expireStreamChunk(stream)
        }
    }

    private fun expireStreamChunk(stream: PclinkRpcStream) {
        synchronized(lock) {
            if (streams[stream.wireId] !== stream || stream.chunks.pendingKeys.isEmpty()) return
        }
        if (nowMillis() - stream.lastChunkAtMillis < configuration.chunkReassemblyTimeout.toMillis()) {
            restartStreamTimeout(stream)
            return
        }
        stream.chunks.discard(stream.wireId)
        val error: Exception = when (stream.retry) {
            PclinkRetryClass.UNSAFE -> PclinkError.UnknownOutcome(stream.endpoint)
            PclinkRetryClass.READ, PclinkRetryClass.IDEMPOTENT ->
                PclinkError.SessionExpired("stream chunk sequence timed out")
        }
        failStream(stream, error, cancel = true)
    }

    private fun failStream(stream: PclinkRpcStream, error: Exception, cancel: Boolean) {
        if (removeStream(stream)) {
            stream.finish(error)
        }
        if (cancel) {
            // The stream is already out of the table, so a raw cancel is needed;
            // `cancelStream` intentionally ignores terminal streams.
            scope.launch { sendCancel(stream.wireId) }
        }
    }

    private fun removeStream(stream: PclinkRpcStream): Boolean {
        val removed = synchronized(lock) {
            if (streams[stream.wireId] === stream) {
                streams.remove(stream.wireId)
                true
            } else {
                false
            }
        }
        stream.chunkTimer?.cancel()
        stream.chunkTimer = null
        stream.chunks.discardAll()
        return removed
    }

    // ---- Session / ids / send -----------------------------------------

    private suspend fun awaitSession(deadline: Long): PclinkE2eSession {
        val waitUntil = minOf(deadline, nowMillis() + SESSION_WAIT_TIMEOUT_MILLIS)
        while (true) {
            ensureOpen()
            currentCoroutineContext().ensureActive()
            val active = channel?.activeSession()
            if (active != null && active.phase == PclinkSessionPhase.ESTABLISHED) return active
            if (nowMillis() >= waitUntil) throw PclinkError.PeerOffline()
            delay(configuration.sessionPollInterval.toMillis())
        }
    }

    private suspend fun outboundSend(inner: PclinkJson) {
        val active = channel ?: throw PclinkError.NotPaired()
        active.sendInner(inner)
    }

    private fun ensureOpen() {
        if (isClosed()) throw PclinkError.Cancelled()
    }

    private fun isClosed(): Boolean = closed

    private fun validateRequest(endpoint: String, args: PclinkJson) {
        if (!PclinkValidation.isEndpoint(endpoint)) {
            throw PclinkError.BadFrame("invalid endpoint")
        }
        if (PclinkEndpoints.isForbiddenRemoteAdmin(endpoint)) {
            throw PclinkError.Forbidden("remote pclink.admin calls are forbidden")
        }
        if (args.objectValue == null) throw PclinkError.BadFrame("args must be an object")
        if (PclinkJsonEncoder.encode(args).size > PclinkLimits.MAX_VALUE_BYTES) {
            throw PclinkError.FrameTooLarge("args exceed 8 MiB")
        }
    }

    private fun isDefinitiveSendError(error: PclinkError): Boolean =
        error is PclinkError.BadFrame || error is PclinkError.FrameTooLarge ||
            error is PclinkError.AuthFailed || error is PclinkError.Forbidden ||
            error is PclinkError.VersionUnsupported || error is PclinkError.NotPaired

    private fun allocateCallId(): String {
        synchronized(lock) {
            while (true) {
                callCounter += 1
                val id = "call-$callCounter-${randomSuffix()}"
                if (id !in pendingCalls) return id
            }
        }
    }

    private fun allocateStreamId(requested: String?, sid: String): String {
        synchronized(lock) {
            if (usedStreamSid != sid) {
                usedStreamSid = sid
                usedStreamIds.clear()
            }
            if (requested != null) {
                if (!PclinkValidation.isCorrelationId(requested)) {
                    throw PclinkError.BadFrame("invalid streamId")
                }
                if (requested in usedStreamIds || requested in streams) {
                    throw PclinkError.BadFrame("duplicate or reused streamId")
                }
                usedStreamIds.add(requested)
                return requested
            }
            while (true) {
                streamCounter += 1
                val id = "stream-$streamCounter-${randomSuffix()}"
                if (id !in usedStreamIds && id !in streams) {
                    usedStreamIds.add(id)
                    return id
                }
            }
        }
    }

    private fun randomSuffix(): String {
        val bytes = ByteArray(4)
        random.nextBytes(bytes)
        return bytes.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
    }

    private fun ensureWatcherLocked() {
        if (closed || watcherRunning) return
        if (pendingCalls.isEmpty() && streams.isEmpty()) return
        watcherRunning = true
        scope.launch {
            while (true) {
                delay(configuration.sessionPollInterval.toMillis())
                checkSessions()
                synchronized(lock) {
                    if (closed || (pendingCalls.isEmpty() && streams.isEmpty())) {
                        watcherRunning = false
                        return@launch
                    }
                }
            }
        }
    }

    private fun checkSessions() {
        val activeSid = channel?.activeSession()?.sid
        val lostCalls = ArrayList<PendingCall>()
        val lostStreams = ArrayList<PclinkRpcStream>()
        synchronized(lock) {
            if (closed) return
            for (call in pendingCalls.values) {
                if (activeSid == null || call.sid != activeSid) lostCalls.add(call)
            }
            for (stream in streams.values) {
                if (activeSid == null || stream.sid != activeSid) lostStreams.add(stream)
            }
        }
        for (call in lostCalls) {
            failCallLost(call, PclinkError.SessionExpired("the E2E session was lost"))
        }
        for (stream in lostStreams) {
            val error: Exception = if (stream.retry == PclinkRetryClass.UNSAFE) {
                PclinkError.UnknownOutcome(stream.endpoint)
            } else {
                PclinkError.SessionExpired("the E2E session was lost")
            }
            if (removeStream(stream)) stream.finish(error)
        }
    }

    private class PendingCall(
        val id: String,
        val endpoint: String,
        val args: PclinkJson,
        val retry: PclinkRetryClass,
        val sid: String,
        budget: PclinkChunkReassemblyBudget,
    ) {
        val result = CompletableDeferred<PclinkJson>()
        val chunks = PclinkChunkReassembler(budget = budget)
        @Volatile
        var chunking: Boolean = false
        @Volatile
        var chunkTimer: Job? = null
        @Volatile
        var lastChunkAtMillis: Long = 0
    }

    private class RpcSessionLost(val reason: PclinkError) : Exception(reason.message)

    private class ClientRpcChannel(private val client: PclinkClient) : PclinkRpcChannel {
        override suspend fun sendInner(inner: PclinkJson) = client.sendInner(inner)
        override fun activeSession(): PclinkE2eSession? = client.activeSession()
    }

    private companion object {
        /** Local wait before a call reports `peer_offline`; not a wire value. */
        const val SESSION_WAIT_TIMEOUT_MILLIS: Long = 15_000
    }
}

/** The C2-frozen host seam plus the outbound side, kept internal for tests. */
internal interface PclinkRpcChannel {
    suspend fun sendInner(inner: PclinkJson)
    fun activeSession(): PclinkE2eSession?
}

internal sealed interface PclinkRpcStreamEvent {
    data class Item(val value: PclinkJson) : PclinkRpcStreamEvent
    data object End : PclinkRpcStreamEvent
    data class Error(val error: Exception) : PclinkRpcStreamEvent
}

/**
 * One open `rpc.stream.open` handle. [next] returns values in order and `null`
 * after `rpc.stream.end`; a DSH endpoint error is thrown as [PclinkRpcError]
 * and a transport failure as [PclinkError]. Late items/chunks after
 * end/error/cancel are discarded. Only one [next] should be active at a time.
 */
class PclinkRpcStream internal constructor(
    val wireId: String,
    internal val endpoint: String,
    internal val retry: PclinkRetryClass,
    internal val sid: String,
    budget: PclinkChunkReassemblyBudget,
    private val owner: PclinkRpc,
) {
    internal val events = Channel<PclinkRpcStreamEvent>(Channel.UNLIMITED)
    internal val chunks = PclinkChunkReassembler(budget = budget)

    @Volatile
    internal var chunkTimer: Job? = null

    @Volatile
    internal var lastChunkAtMillis: Long = 0

    @Volatile
    internal var cancelled: Boolean = false

    @Volatile
    private var finished: Boolean = false

    /** The server-assigned stream id for this session. */
    val id: String get() = wireId

    /** Returns the next value, or `null` when the stream ended normally. */
    suspend fun next(): PclinkJson? {
        while (true) {
            if (cancelled) return null
            val event = events.receiveCatching().getOrNull() ?: return null
            when (event) {
                is PclinkRpcStreamEvent.Item -> return event.value
                is PclinkRpcStreamEvent.End -> return null
                is PclinkRpcStreamEvent.Error -> throw event.error
            }
        }
    }

    /** Sends `rpc.stream.cancel`; late values are discarded (§6.2). */
    suspend fun cancel() = owner.cancelStream(this)

    /** Best-effort cancel + release; safe to call more than once. */
    fun close() = owner.closeStream(this)

    internal fun finish(error: Exception?) {
        if (finished) return
        finished = true
        chunkTimer?.cancel()
        chunkTimer = null
        chunks.discardAll()
        if (error != null) events.trySend(PclinkRpcStreamEvent.Error(error))
        events.close()
    }

    override fun toString(): String = "PclinkRpcStream(id=$id, endpoint=$endpoint)"
}


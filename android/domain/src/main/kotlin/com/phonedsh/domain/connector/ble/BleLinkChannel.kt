// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.ble

/**
 * Target-only, platform-independent ordinary Link channel. The owner must supply
 * unique connection generations, a monotonic three-second exchange timeout and
 * successful notification subscriptions. No GATT, authorization, persistence,
 * task-profile negotiation or automatic replay is implemented here.
 *
 * Calls must be serialized by the owner. Each returned Write is one write with
 * response; no subsequent write is emitted until that exact write succeeds.
 */
internal class BleLinkChannel(private val generation: Long, private val writeLimit: Int) {
    internal sealed interface Effect {
        class Write(val generation: Long, val requestId: Int, val token: Long, val bytes: ByteArray) : Effect
        class Ready(val peer: BleLinkCodec.Peer) : Effect
        class Complete(val requestId: Int, val body: ByteArray) : Effect
        class Nak(val requestId: Int, val body: ByteArray) : Effect
        class Event(val body: ByteArray) : Effect
        class Reject(val reason: Rejection) : Effect
        class Unknown(val requestId: Int) : Effect
        data object Disconnect : Effect
    }

    internal enum class Rejection { NOT_READY, BUSY, EXHAUSTED, TOOLS_UNSUPPORTED, INVALID_REQUEST }

    private enum class State { NEW, NEGOTIATING, READY, CLOSED }
    private class Pending(
        val id: Int,
        val opcode: Int,
        val segments: List<ByteArray>,
        var index: Int = 0,
        var token: Long = 0,
        var writing: Boolean = true,
        var response: BleLinkCodec.Frame? = null,
    )

    private var state = State.NEW
    private var nextId = 1
    private var nextToken = 1L
    private var pending: Pending? = null
    private var peer: BleLinkCodec.Peer? = null
    private val reassembler = BleLinkCodec.Reassembler()

    init { require(writeLimit >= 20) { "Link ATT write budget too small" } }

    /** Opens only after the adapter has confirmed both notifications. */
    fun open(txSubscribed: Boolean, audioSubscribed: Boolean): List<Effect> {
        if (state != State.NEW || !txSubscribed || !audioSubscribed) return reject(Rejection.NOT_READY)
        state = State.NEGOTIATING
        return start(0x01, BleLinkCodec.hello())
    }

    /** The target channel is not itself permission to invoke or replay a tool. */
    fun request(opcode: Int, body: ByteArray): List<Effect> {
        if (state != State.READY) return reject(Rejection.NOT_READY)
        if (pending != null) return reject(Rejection.BUSY)
        if (nextId > 65535) return reject(Rejection.EXHAUSTED)
        if (opcode !in 2..0x7f || body.size > BleLinkCodec.MAX_BODY) return reject(Rejection.INVALID_REQUEST)
        if (opcode in 0x54..0x56 && peer?.supportsTools != true) return reject(Rejection.TOOLS_UNSUPPORTED)
        return start(opcode, body)
    }

    private fun start(opcode: Int, body: ByteArray): List<Effect> {
        val id = nextId++
        val operation = Pending(id, opcode, BleLinkCodec.Frame(opcode, id, body).segments(writeLimit))
        pending = operation
        return listOf(write(operation))
    }

    private fun write(operation: Pending): Effect.Write {
        check(nextToken > 0) { "Link write identity exhausted" }
        operation.token = nextToken++
        return Effect.Write(generation, operation.id, operation.token, operation.segments[operation.index].copyOf())
    }

    fun writeComplete(callbackGeneration: Long, token: Long, success: Boolean): List<Effect> {
        val operation = pending ?: return emptyList()
        if (callbackGeneration != generation || !operation.writing || token != operation.token) return emptyList()
        if (!success) return terminate()
        operation.index++
        if (operation.index < operation.segments.size) return listOf(write(operation))
        operation.writing = false
        val response = operation.response ?: return emptyList()
        return finish(operation, response)
    }

    /** The adapter supplies only ctl_tx characteristic notifications. */
    fun receive(callbackGeneration: Long, segment: ByteArray): List<Effect> {
        if (callbackGeneration != generation || state == State.CLOSED || state == State.NEW) return emptyList()
        val frame = try { reassembler.push(segment) } catch (_: IllegalArgumentException) { return terminate() }
            ?: return emptyList()
        if (frame.opcode == 0x6c && frame.requestId == 0) {
            return if (state == State.READY && peer?.supportsTools == true) listOf(Effect.Event(frame.body)) else emptyList()
        }
        val operation = pending ?: return emptyList()
        if (frame.requestId != operation.id || (frame.opcode != 0xff && frame.opcode != (operation.opcode or 0x80))) return emptyList()
        if (operation.response != null) return emptyList()
        if (operation.writing) {
            // A response cannot be legitimate until the complete request has
            // actually been handed to the transport for its final write.
            if (operation.index != operation.segments.lastIndex) return terminate()
            operation.response = frame
            return emptyList()
        }
        return finish(operation, frame)
    }

    private fun finish(operation: Pending, frame: BleLinkCodec.Frame): List<Effect> {
        if (frame.opcode == 0xff) {
            pending = null
            val nak = Effect.Nak(operation.id, frame.body)
            return if (state == State.NEGOTIATING) {
                peer = null
                reassembler.reset()
                state = State.CLOSED
                listOf(nak, Effect.Disconnect)
            } else listOf(nak)
        }
        if (state == State.NEGOTIATING) {
            val remote = try { BleLinkCodec.decodeHelloAck(frame.body) } catch (_: IllegalArgumentException) { return terminate() }
            pending = null
            peer = remote
            state = State.READY
            return listOf(Effect.Ready(remote))
        }
        pending = null
        return listOf(Effect.Complete(operation.id, frame.body))
    }

    /** An owner ties timeout/cancellation to the exact exchange; stale events are ignored. */
    fun timeout(callbackGeneration: Long, requestId: Int): List<Effect> = endExchange(callbackGeneration, requestId)
    fun cancel(callbackGeneration: Long, requestId: Int): List<Effect> = endExchange(callbackGeneration, requestId)

    private fun endExchange(callbackGeneration: Long, requestId: Int): List<Effect> {
        if (callbackGeneration != generation || pending?.id != requestId) return emptyList()
        return terminate()
    }

    fun disconnected(callbackGeneration: Long): List<Effect> {
        if (callbackGeneration != generation || state == State.CLOSED || state == State.NEW) return emptyList()
        return terminate()
    }

    private fun terminate(): List<Effect> {
        val operation = pending
        pending = null
        peer = null
        reassembler.reset()
        state = State.CLOSED
        return buildList {
            if (operation != null) add(Effect.Unknown(operation.id))
            add(Effect.Disconnect)
        }
    }

    private fun reject(reason: Rejection): List<Effect> = listOf(Effect.Reject(reason))
}

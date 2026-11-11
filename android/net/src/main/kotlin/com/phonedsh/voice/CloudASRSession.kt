// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.voice: one pdsh-asr.v1 recognition session
// (spec/v1/cloud-voice.md §2). One connection per turn; never reused or
// replayed.
//
// The session owns the `started` gate: the board records immediately, so Opus
// bodies may arrive before the cloud has answered. They wait on the phone in
// arrival order and are sent only after `started`; the pre-start queue is
// capped at 100 bodies and one more fails the turn with `cancel`. The four
// deadlines are armed from the contract constants through [CloudVoiceTiming].
// The socket is an interface; production uses KtorCloudVoiceSocketFactory and
// every test here uses a fake.

package com.phonedsh.voice

import java.nio.charset.StandardCharsets
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

class CloudASRSession(
    private val turnId: UInt,
    private val credentials: CloudVoiceCredentialProvider,
    private val socketFactory: CloudVoiceSocketFactory = KtorCloudVoiceSocketFactory(),
    private val url: String = CloudVoice.ASR_URL,
    private val timing: CloudVoiceTiming = CloudVoiceTiming(),
    /**
     * Owns the receive loop and the deadline jobs. Production passes a
     * process-scoped scope; a test passes its own so a forgotten child is
     * visible instead of leaking.
     */
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val mutex = Mutex()
    private val transcript = CloudASRTranscript()
    private val outcomeSignal = CompletableDeferred<CloudASRTranscript.Outcome>()
    private val readySignal = CompletableDeferred<Boolean>()
    private val queued = ArrayDeque<ByteArray>()
    private var socket: CloudVoiceSocket? = null
    private var started = false
    private var finishSent = false
    private var finishTimeoutMs = timing.finishTimeoutDefaultMs
    private var deadline: Job? = null
    private var concluded = false
    private var openCalled = false
    private val openedAt = System.nanoTime()

    /** What the handshake answered when the upgrade did not succeed (401 → tono-account §5). */
    @Volatile
    var handshakeStatus: Int? = null
        private set

    /** Bodies actually handed to the socket after `started`; the queue is not counted. */
    @Volatile
    var sentPackets: Int = 0
        private set

    /** Milliseconds from `open()` until `start` was written on the open connection. */
    @Volatile
    var connectMs: Long? = null
        private set

    /** Milliseconds from `open()` until `started` arrived. */
    @Volatile
    var startedMs: Long? = null
        private set

    /**
     * Resolves the credential, connects (at most the connect deadline), sends
     * `start` and starts reading. `started` must then arrive within its own
     * deadline or the turn fails with `cancel` (§2).
     */
    suspend fun open() {
        val credential = try {
            credentials.credential()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            null
        }
        if (credential.isNullOrEmpty()) {
            end("credential unavailable")
            return
        }
        val opened = try {
            withTimeout(timing.connectTimeoutMs) {
                socketFactory.open(url, CloudVoice.ASR_SUBPROTOCOL, credential)
            }
        } catch (timeout: TimeoutCancellationException) {
            end("no connection within 10 s")
            return
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            handshakeStatus = (failure as? CloudVoiceHandshakeException)?.status
            end("closed without a result")
            return
        }

        var closeNow = false
        locked {
            if (openCalled || concluded) {
                closeNow = true
            } else {
                openCalled = true
                socket = opened
            }
        }
        if (closeNow) {
            closeQuietly(opened)
            return
        }

        try {
            opened.sendText(String(CloudVoice.startMessage(turnId), StandardCharsets.UTF_8))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            end("closed without a result")
            return
        }
        connectMs = elapsedMs()
        locked {
            if (concluded) closeNow = true else arm(timing.startedTimeoutMs, "no started within 5 s of start")
        }
        if (closeNow) {
            closeQuietly(opened)
            return
        }
        scope.launch { receiveLoop() }
    }

    /** Queues one Opus body; sent at once after `started`, in arrival order. */
    suspend fun send(opus: ByteArray) {
        if (opus.isEmpty()) return
        var capHit = false
        locked {
            if (concluded || finishSent) return@locked
            val current = socket
            if (!started) {
                if (queued.size >= CloudVoice.PRE_START_QUEUE_MAX) {
                    capHit = true
                } else {
                    queued.addLast(opus.copyOf())
                }
            } else if (current != null) {
                current.sendBinary(opus.copyOf())
                sentPackets += 1
            }
        }
        if (capHit) cancel()
    }

    /** The board's audio ended (§4.1): send `finish` unless a terminal already arrived. */
    suspend fun finish() {
        var toClose: CloudVoiceSocket? = null
        locked {
            if (concluded || finishSent) return@locked
            finishSent = true
            if (started) {
                try {
                    sendFinishLocked()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    toClose = concludeLocked("closed without a result")
                }
            }
        }
        toClose?.let { closeQuietly(it) }
    }

    /** A user cancel or a new wake: send `cancel`, then fail this session's outcome. */
    suspend fun cancel() {
        var toClose: CloudVoiceSocket? = null
        locked {
            if (concluded) return@locked
            socket?.let { trySend(it, String(CloudVoice.cancelMessage, StandardCharsets.UTF_8)) }
            toClose = concludeLocked("cancelled")
        }
        toClose?.let { closeQuietly(it) }
    }

    /** True once `started` arrived; false when the session ended first (handshake, deadline). */
    suspend fun ready(): Boolean = readySignal.await()

    /** The turn's terminal outcome; suspends until the session ends. */
    suspend fun outcome(): CloudASRTranscript.Outcome = outcomeSignal.await()

    /** The outcome if the session already ended, else null. Diagnostics only. */
    @OptIn(ExperimentalCoroutinesApi::class)
    val outcomeIfComplete: CloudASRTranscript.Outcome?
        get() = if (outcomeSignal.isCompleted) outcomeSignal.getCompleted() else null

    // MARK: - state machine

    private suspend fun receiveLoop() {
        var toClose: CloudVoiceSocket? = null
        try {
            while (true) {
                val current = locked { socket }
                if (current == null) break
                val frame = current.receive() ?: break
                if (frame !is CloudVoiceSocketFrame.Text) continue
                val message = CloudASRMessage.decode(frame.text)
                var terminal = false
                locked {
                    if (concluded) return@locked
                    if (message is CloudASRMessage.Started && !started) {
                        started = true
                        startedMs = elapsedMs()
                        finishTimeoutMs = message.finishTimeoutMs
                        deadline?.cancel()
                        val open = socket
                        if (open != null) {
                            for (body in queued) {
                                open.sendBinary(body)
                                sentPackets += 1
                            }
                        }
                        queued.clear()
                        if (finishSent) sendFinishLocked()
                        readySignal.complete(true)
                    }
                    transcript.apply(message)
                    if (transcript.outcome != CloudASRTranscript.Outcome.Pending) {
                        terminal = true
                        toClose = concludeLocked(null)
                    }
                }
                if (terminal) break
            }
            if (toClose == null) {
                locked {
                    if (!concluded) {
                        transcript.closed()
                        toClose = concludeLocked(null)
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            handshakeStatus = (failure as? CloudVoiceHandshakeException)?.status
            locked {
                if (!concluded) {
                    transcript.closed()
                    toClose = concludeLocked(null)
                }
            }
        } finally {
            toClose?.let { closeQuietly(it) }
        }
    }

    private suspend fun sendFinishLocked() {
        socket?.sendText(String(CloudVoice.finishMessage, StandardCharsets.UTF_8))
        arm(finishTimeoutMs + timing.finishGraceMs, "no result in time")
    }

    private fun arm(afterMs: Long, reason: String) {
        deadline?.cancel()
        deadline = scope.launch {
            delay(afterMs)
            expire(reason)
        }
    }

    private suspend fun expire(reason: String) {
        var toClose: CloudVoiceSocket? = null
        locked {
            if (concluded) return@locked
            socket?.let { trySend(it, String(CloudVoice.cancelMessage, StandardCharsets.UTF_8)) }
            toClose = concludeLocked(reason)
        }
        toClose?.let { closeQuietly(it) }
    }

    private suspend fun end(reason: String) {
        var toClose: CloudVoiceSocket? = null
        locked { toClose = concludeLocked(reason) }
        toClose?.let { closeQuietly(it) }
    }

    /** Must be called with [mutex] held. */
    private fun concludeLocked(localFailure: String?): CloudVoiceSocket? {
        if (localFailure != null) transcript.fail(localFailure)
        if (transcript.outcome == CloudASRTranscript.Outcome.Pending) return null
        if (concluded) return null
        concluded = true
        deadline?.cancel()
        readySignal.complete(started)
        outcomeSignal.complete(transcript.outcome)
        val current = socket
        socket = null
        return current
    }

    private suspend fun <T> locked(block: suspend () -> T): T {
        mutex.lock()
        try {
            return block()
        } finally {
            mutex.unlock()
        }
    }

    private suspend fun trySend(current: CloudVoiceSocket, text: String) {
        try {
            current.sendText(text)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            // A failed cancel/finish still ends the turn; nothing is replayed.
        }
    }

    private suspend fun closeQuietly(current: CloudVoiceSocket) {
        withContext(NonCancellable) {
            try {
                current.close(CloudVoiceSocket.CLOSE_NORMAL, null)
            } catch (_: Throwable) {
                // The peer may already be gone.
            }
        }
    }

    private fun elapsedMs(): Long = (System.nanoTime() - openedAt) / 1_000_000L
}

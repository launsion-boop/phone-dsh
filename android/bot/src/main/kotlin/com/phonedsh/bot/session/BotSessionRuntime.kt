// SPDX-License-Identifier: MIT
package com.phonedsh.bot.session

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.attachments.BotAttachmentPolicy
import com.phonedsh.bot.attachments.BotAttachmentPrompt
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * A durable `runtime.started` / `runtime.exited` event the lifecycle appended
 * (`session-lifecycle.md` §4). `eventId` and `time` are host-assigned and are
 * not part of the rule.
 */
public data class BotSessionLifecycleEvent(
    public val type: String,
    public val principal: BotSessionPrincipal,
    public val data: Map<String, JsonValue>,
    public val eventId: String,
    public val time: Long,
)

/** A stored durable Bot event. Recovery scans these in `commitSeq` order. */
public data class BotSessionStoredEvent(
    public val type: String,
    public val principal: BotSessionPrincipal,
    public val data: Map<String, JsonValue>,
    public val eventId: String,
    public val time: Long,
    public val commitSeq: Long,
)

/** An ephemeral `runtime.stderr` diagnostic (§5); never durable, never a row. */
public data class BotSessionEphemeralEvent(
    public val type: String,
    public val sessionId: String,
    public val data: Map<String, JsonValue>,
)

/** One `session/follow` live frame (§6.2). */
public sealed interface BotSessionLiveFrame {
    public data object StreamStart : BotSessionLiveFrame

    public data class TextDelta(public val text: String) : BotSessionLiveFrame

    public data class Event(
        public val type: String,
        public val event: JsonValue,
    ) : BotSessionLiveFrame
}

/** One turn's terminal result (`session-lifecycle.md` §6). */
public data class BotSessionTurnResult(
    public val sessionId: String,
    public val turnId: String?,
    public val status: String,
    public val text: String,
    public val error: String?,
    /** The last non-empty visible assistant message (§6.2). */
    public val finalText: String? = null,
)

/** Old/new ids of an erasure epoch switch (§5.2). */
public data class BotSessionErasureSwitch(
    public val old: String,
    public val new: String,
)

/**
 * The DSH Remote surface as a port. Implementations are host adapters; this
 * contract exercises only the request values and response values. No network
 * client lives in `:bot`.
 */
public interface BotSessionTransport {
    /**
     * One unary DSH Remote call. [args] is the full argument object
     * (`{"request": …}` where the method uses a request envelope). Throw
     * [BotSessionRemoteException] for a Remote error.
     */
    public fun call(endpoint: String, args: JsonObject): JsonObject

    /** Open the one mux a coordinated turn uses for its `session/follow`. */
    public fun openFollow(): BotFollowConnection
}

/** A `session/follow` mux port: `send` the open frame and `receive` frames. */
public interface BotFollowConnection {
    public fun send(frame: JsonObject)

    /** Returns null when the socket ended. */
    public fun receive(): JsonObject?

    public fun close()
}

/**
 * The P27 main-chat session lifecycle state machine
 * (`spec/bot/v1/session-lifecycle.md`).
 *
 * The class holds in-memory host state only. Every operation reports the DSH
 * calls it makes through [BotSessionTransport]; durable lifecycle events are
 * accumulated in [appendedEvents] and are never written to a store here. The
 * integrator wires this runtime to the P25 store and the P14 transport.
 */
public class BotSessionRuntime(
    private val transport: BotSessionTransport,
    private val botId: String = "main",
    private val botDataDirectory: String = BotSessionWorkspace.DEFAULT_BOT_DATA_DIRECTORY,
    private val tokens: BotSessionTokenRegistry = BotSessionTokenRegistry(),
    private val now: () -> Long = { System.currentTimeMillis() },
    private val onSessionRegistered: (String) -> Unit = {},
    /** Cold-start retry delay for `session/not-found`; the contract says 50 ms. */
    private val retryDelayMillis: Long = 50,
    seedEvents: List<BotSessionStoredEvent> = emptyList(),
) {
    private data class SessionCredential(
        val token: String,
        val principal: BotSessionPrincipal,
        val claimGeneration: Long,
        val claimAcknowledged: Boolean,
    )

    private class ActiveTurn(
        val sessionId: String,
        val attemptId: String,
        val kind: BotSessionKind,
        val hidden: Boolean,
    ) {
        @Volatile
        var cancelRequested: Boolean = false

        @Volatile
        var promptAccepted: Boolean = false

        @Volatile
        var currentTurnId: String? = null

        @Volatile
        var connection: BotFollowConnection? = null

        val finished: CountDownLatch = CountDownLatch(1)
        val result: CompletableFuture<BotSessionTurnResult> = CompletableFuture()
    }

    private class QueuedTurn {
        @Volatile
        var cancelled: Boolean = false
        val predecessorDone: CountDownLatch = CountDownLatch(1)
    }

    private data class RecoveredMainSession(val sessionId: String, val cwd: String?)

    private val stateLock = Any()
    private val sessions = HashMap<String, SessionCredential>()
    private val activeTurns = ConcurrentHashMap<String, ActiveTurn>()
    private val queuedTurns = ConcurrentHashMap<String, QueuedTurn>()
    private val liveObservers = LinkedHashMap<Long, (BotSessionLiveFrame) -> Unit>()
    private var liveObserverCounter = 0L
    @Volatile
    private var claimGeneration = 0L
    private val storedEvents = ArrayList(seedEvents)
    private var nextCommitSeq = (seedEvents.maxOfOrNull { it.commitSeq } ?: 0L) + 1
    private val appended = ArrayList<BotSessionLifecycleEvent>()
    private val ephemeral = ArrayList<BotSessionEphemeralEvent>()
    private var pendingContinuation: String? = null

    @Volatile
    public var mainSessionId: String? = null
        private set

    /** Single-flight first-message/recovery task (`session-lifecycle.md` §5). */
    private var mainSessionFuture: CompletableFuture<String>? = null

    // MARK: - Public lifecycle surface

    /** `startMainSession` / `ensureMainSession` (§5). */
    public fun startMainSession(): String = ensureMainSession()

    public fun mainSessionIdentifier(): String? = mainSessionId

    /** The durable lifecycle events this runtime appended, in order. */
    @Synchronized
    public fun appendedEvents(): List<BotSessionLifecycleEvent> = appended.toList()

    /** Ephemeral diagnostics (`runtime.stderr`) this runtime emitted. */
    @Synchronized
    public fun ephemeralEvents(): List<BotSessionEphemeralEvent> = ephemeral.toList()

    /** Stage the one-shot epoch-continuation seam for the next user message. */
    @Synchronized
    public fun setPendingContinuation(seam: String?) {
        pendingContinuation = seam
    }

    @Synchronized
    public fun subscribeLiveFrames(observer: (BotSessionLiveFrame) -> Unit): Long {
        val token = liveObserverCounter++
        liveObservers[token] = observer
        return token
    }

    @Synchronized
    public fun unsubscribeLiveFrames(token: Long) {
        liveObservers.remove(token)
    }

    public fun isMainTurnBusy(): Boolean {
        val sessionId = mainSessionId ?: return false
        return activeTurns[sessionId] != null || queuedTurns[sessionId] != null
    }

    public fun isAvailable(): Boolean {
        val sessionId = mainSessionId ?: return false
        return validateRemoteSession(sessionId)
    }

    /**
     * Worker replacement (`session-lifecycle.md` §5.3): invalidate the Worker's
     * in-memory credentials without rotating the host tokens, cancel every
     * active and queued turn best-effort, and clear the adopted main session so
     * the next `startMainSession` runs the full recovery table again.
     */
    public fun workerReplaced() {
        claimGeneration += 1
        for (active in activeTurns.values) {
            active.cancelRequested = true
            try {
                transport.call(
                    "session/cancel",
                    JsonObject(linkedMapOf("request" to JsonObject(linkedMapOf(
                        "sessionId" to JsonString(active.sessionId),
                        "cause" to JsonObject(linkedMapOf("kind" to JsonString("user"))),
                    )))),
                )
            } catch (_: Exception) {
                // Best effort.
            }
        }
        for (queued in queuedTurns.values) queued.cancelled = true
        // Keep the host credentials: the bumped generation makes ensureSession
        // re-claim each still-current token; only the adopted id is cleared.
        mainSessionId = null
    }

    /** One visible main-chat turn (§6.1). */
    public fun sendUserMessage(
        text: String,
        requestId: String? = null,
        attachments: List<BotAttachment> = emptyList(),
    ): BotSessionTurnResult {
        if (attachments.size > BotAttachmentPolicy.MAX_COUNT) {
            throw BotSessionException("invalidRequest", "too_many_attachments")
        }
        val sessionId = ensureMainSession()
        var body = text
        val block = BotAttachmentPrompt.block(attachments)
        if (block.isNotEmpty()) {
            body = if (text.isEmpty()) block.dropWhile { it == '\n' } else text + block
        }
        var prompt = body
        val seam = synchronized(this) {
            val staged = pendingContinuation
            if (!staged.isNullOrEmpty()) pendingContinuation = null
            staged
        }
        if (!seam.isNullOrEmpty()) prompt = "$seam\n\n$prompt"
        val promptRequestId = requestId ?: BotTurnOrigin.visibleRequestId()
        return runTurn(sessionId, BotSessionKind.CHAT, prompt, promptRequestId, allowSteer = true)
    }

    /** One hidden main-chat turn; the request id carries a hidden prefix. */
    public fun sendHiddenInteraction(text: String, requestId: String? = null): BotSessionTurnResult {
        val id = requestId
        if (id == null || !BotTurnOrigin.parse(id).hidden) {
            throw BotSessionException(
                "invalidRequest", "hidden interaction requires a hidden request id prefix")
        }
        val sessionId = ensureMainSession()
        return runTurn(sessionId, BotSessionKind.CHAT, text, id)
    }

    /** `cancelMainTurn` (§6.3): no stale-turn id check. */
    public fun cancelMainTurn() {
        val sessionId = ensureMainSession()
        cancelTurn(sessionId, includeQueued = false)
    }

    /** `stopMainTurn(turnID:)` (§6.3): reject a mismatched live turn id. */
    public fun stopMainTurn(turnID: String?) {
        val sessionId = ensureMainSession()
        val active = activeTurns[sessionId]
        if (turnID != null && active != null && active.currentTurnId != turnID) {
            throw BotSessionException("invalidRequest", "stale_turn")
        }
        cancelTurn(sessionId, includeQueued = false)
    }

    /** Erasure epoch switch (§5.2). */
    public fun switchMainSessionForErasure(
        erasureID: String,
        erasedRecords: List<String> = emptyList(),
    ): BotSessionErasureSwitch {
        val old = ensureMainSession()
        try {
            cancelTurn(old, includeQueued = true)
        } catch (_: Exception) {
            // A cancel error is ignored; the epoch switch continues.
        }
        val newID = rebuiltMainSessionID()
        val created = createSession(BotSessionKind.CHAT, sessionID = newID)
        archiveRemoteSession(old)
        try {
            val principal = issueAndClaimSession(created, BotSessionKind.CHAT)
            val oldPrincipal = sessions[old]?.principal ?: BotSessionPrincipal(
                botId = botId,
                sessionId = old,
                kind = BotSessionKind.CHAT,
                expiresAt = Long.MAX_VALUE,
                incarnation = "",
            )
            appendLifecycle(
                type = "runtime.exited",
                principal = oldPrincipal,
                data = linkedMapOf(
                    "sessionId" to JsonString(old),
                    "reason" to JsonString("session-erased"),
                    "replacedBy" to JsonString(created),
                    "erasureId" to JsonString(erasureID),
                    "erasedRecords" to JsonArray(erasedRecords.map { JsonString(it) }),
                ),
            )
            recordRuntimeStarted(created, principal, botRoot())
            mainSessionId = created
            sessions.remove(old)
            return BotSessionErasureSwitch(old = old, new = created)
        } catch (error: Exception) {
            archiveRemoteSession(created)
            unarchiveRemoteSession(old)
            throw error
        }
    }

    // MARK: - Session recovery

    private fun ensureMainSession(): String {
        mainSessionId?.let { return it }
        val (future, owner) = synchronized(stateLock) {
            val existing = mainSessionFuture
            if (existing != null) {
                existing to false
            } else {
                CompletableFuture<String>().also { mainSessionFuture = it } to true
            }
        }
        if (!owner) {
            return try {
                future.get()
            } catch (error: java.util.concurrent.ExecutionException) {
                throw (error.cause as? Exception) ?: error
            }
        }
        try {
            val sessionId = recoverOrCreateMainSession()
            mainSessionId = sessionId
            future.complete(sessionId)
            return sessionId
        } catch (error: Exception) {
            future.completeExceptionally(error)
            throw error
        } finally {
            synchronized(stateLock) { mainSessionFuture = null }
        }
    }

    private fun recoverOrCreateMainSession(): String {
        val root = botRoot()
        val recovered = latestMainSessionEvent()
        if (recovered != null) {
            val recoveredCwd = recovered.cwd ?: remoteSessionCwd(recovered.sessionId)
            if (recoveredCwd == root && validateRemoteSession(recovered.sessionId, attempts = 100)) {
                val principal = issueAndClaimSession(recovered.sessionId, BotSessionKind.CHAT)
                recordRuntimeStarted(recovered.sessionId, principal, root)
                return recovered.sessionId
            }
            return rebuildMainSession(recovered.sessionId, root)
        }
        try {
            val sessionId = createSession(BotSessionKind.CHAT)
            val principal = issueAndClaimSession(sessionId, BotSessionKind.CHAT)
            recordRuntimeStarted(sessionId, principal, root)
            return sessionId
        } catch (error: Exception) {
            val legacyID = mintedSessionID(BotSessionKind.CHAT)
            if (isSessionCwdConflict(error) && remoteSessionCwd(legacyID) != null) {
                return rebuildMainSession(legacyID, root)
            }
            throw error
        }
    }

    private fun latestMainSessionEvent(): RecoveredMainSession? {
        var latest: RecoveredMainSession? = null
        for (event in storedEvents.sortedBy { it.commitSeq }) {
            if (event.type != "runtime.started") continue
            if (event.principal.botId != botId) continue
            if (event.principal.kind != BotSessionKind.CHAT) continue
            val dataSessionId = (event.data["sessionId"] as? JsonString)?.value
            val sessionId = when {
                !dataSessionId.isNullOrEmpty() -> dataSessionId
                event.principal.sessionId.isNotEmpty() -> event.principal.sessionId
                else -> continue
            }
            latest = RecoveredMainSession(
                sessionId = sessionId,
                cwd = (event.data["cwd"] as? JsonString)?.value,
            )
        }
        return latest
    }

    private fun recordRuntimeStarted(
        sessionId: String,
        principal: BotSessionPrincipal,
        cwd: String,
    ) {
        appendLifecycle(
            type = "runtime.started",
            principal = principal,
            data = linkedMapOf(
                "sessionId" to JsonString(sessionId),
                "botId" to JsonString(botId),
                "cwd" to JsonString(cwd),
            ),
        )
    }

    private fun appendLifecycle(
        type: String,
        principal: BotSessionPrincipal,
        data: Map<String, JsonValue>,
    ): BotSessionLifecycleEvent {
        val event = BotSessionLifecycleEvent(
            type = type,
            principal = principal,
            data = data,
            eventId = "evt-$type-${UUID.randomUUID().toString().lowercase()}",
            time = now(),
        )
        storedEvents.add(
            BotSessionStoredEvent(
                type = event.type,
                principal = event.principal,
                data = event.data,
                eventId = event.eventId,
                time = event.time,
                commitSeq = nextCommitSeq++,
            ),
        )
        appended.add(event)
        return event
    }

    /** Replaces an old main session; `runtime.started` is the commit point (§5.1). */
    private fun rebuildMainSession(from: String, cwd: String): String {
        onSessionRegistered(from)
        val newSessionId = rebuiltMainSessionID()
        val created = createSession(BotSessionKind.CHAT, sessionID = newSessionId)
        archiveRemoteSession(from)
        try {
            val principal = issueAndClaimSession(created, BotSessionKind.CHAT)
            recordRuntimeStarted(created, principal, cwd)
            return created
        } catch (error: Exception) {
            archiveRemoteSession(created)
            unarchiveRemoteSession(from)
            throw error
        }
    }

    // MARK: - session/create and claims

    private fun createSession(kind: BotSessionKind, sessionID: String? = null): String {
        val expectedPreset = requestedPreset(kind)
        val request = linkedMapOf<String, JsonValue>(
            "cwd" to JsonString(botRoot()),
            "sessionId" to JsonString(sessionID ?: mintedSessionID(kind)),
            "agentPreset" to JsonString(expectedPreset),
        )
        val created = transport.call(
            "session/create",
            JsonObject(linkedMapOf("request" to JsonObject(request))),
        )
        val sessionId = (created["sessionId"] as? JsonString)?.value
        if (sessionId.isNullOrEmpty()) {
            throw BotSessionException("unavailable", "session/create returned no sessionId")
        }
        val composed = (created["agentPreset"] as? JsonString)?.value
            ?: throw BotSessionException(
                "unavailable",
                "session/create did not report its composed agent preset " +
                    "(expected $expectedPreset for ${kind.wire}); refusing to run the Bot turn",
            )
        if (composed != expectedPreset) {
            throw BotSessionException(
                "unavailable",
                "Bot ${kind.wire} session composed preset $composed instead of " +
                    "$expectedPreset; refusing to run the Bot turn",
            )
        }
        return sessionId
    }

    private fun issueAndClaimSession(
        sessionId: String,
        kind: BotSessionKind,
        capabilities: List<String> = emptyList(),
    ): BotSessionPrincipal {
        val issued = tokens.issueSession(
            botId = botId,
            sessionId = sessionId,
            kind = kind,
            capabilities = capabilities,
            ttlMilliseconds = if (kind == BotSessionKind.CHAT) {
                BotSessionTokenRegistry.CHAT_TTL_MILLISECONDS
            } else {
                BotSessionTokenRegistry.EPHEMERAL_TTL_MILLISECONDS
            },
        )
        val acknowledged = claimOwnedSession(sessionId, issued.token)
        synchronized(stateLock) {
            sessions[sessionId] = SessionCredential(
                token = issued.token,
                principal = issued.principal,
                claimGeneration = claimGeneration,
                claimAcknowledged = acknowledged,
            )
        }
        return issued.principal
    }

    private fun claimOwnedSession(sessionId: String, sessionToken: String): Boolean {
        onSessionRegistered(sessionId)
        val fields = linkedMapOf<String, JsonValue>("sessionId" to JsonString(sessionId))
        if (sessionToken.isNotEmpty()) fields["sessionToken"] = JsonString(sessionToken)
        val response: JsonObject = try {
            transport.call(
                "phone/botClaimSession",
                JsonObject(linkedMapOf("request" to JsonObject(fields))),
            )
        } catch (error: Exception) {
            if (sessionId.startsWith("gb-")) return false
            throw error
        }
        if ((response["ok"] as? JsonBool)?.value != true) {
            if (sessionId.startsWith("gb-")) return false
            throw BotSessionException(
                "unavailable", "Bot session ownership was not acknowledged for $sessionId")
        }
        return true
    }

    private fun ensureSession(sessionId: String, kind: BotSessionKind): BotSessionPrincipal {
        val existing = synchronized(stateLock) { sessions[sessionId] }
        if (existing != null) {
            if (existing.claimGeneration == claimGeneration && existing.claimAcknowledged) {
                return existing.principal
            }
            val current = tokens.lookup(existing.token)
            val live = tokens.lookupSession(sessionId)
            if (current != null && current.sessionId == sessionId &&
                live?.incarnation == current.incarnation
            ) {
                val acknowledged = claimOwnedSession(sessionId, existing.token)
                synchronized(stateLock) {
                    sessions[sessionId] = SessionCredential(
                        token = existing.token,
                        principal = current,
                        claimGeneration = claimGeneration,
                        claimAcknowledged = acknowledged,
                    )
                }
                return current
            }
        } else if (!validateRemoteSession(sessionId)) {
            throw BotSessionException("unavailable", "session/page could not resume $sessionId")
        }
        val restoredCapabilities = synchronized(stateLock) {
            sessions[sessionId]?.principal?.capabilities
        }
        return issueAndClaimSession(
            sessionId, kind, capabilities = restoredCapabilities ?: emptyList())
    }

    // MARK: - Turn execution

    private fun runTurn(
        sessionId: String,
        kind: BotSessionKind,
        prompt: String,
        requestId: String,
        allowSteer: Boolean = true,
    ): BotSessionTurnResult {
        ensureSession(sessionId, kind)
        val origin = BotTurnOrigin.parse(requestId)
        val hidden = origin.hidden
        val active = activeTurns[sessionId]
        if (allowSteer && canSteer(sessionId) && kind == BotSessionKind.CHAT && !hidden && active != null) {
            sendPrompt(sessionId, prompt, mode = "steer", requestId = requestId)
            return awaitTurn(active)
        }
        val predecessor = queuedTurns[sessionId] ?: active
        if (predecessor != null) {
            val queued = QueuedTurn()
            queuedTurns[sessionId] = queued
            try {
                when (predecessor) {
                    is ActiveTurn -> awaitTurn(predecessor)
                    is QueuedTurn -> queued.predecessorDone.await()
                    else -> Unit
                }
                synchronized(stateLock) {
                    if (queuedTurns[sessionId] === queued) queuedTurns.remove(sessionId)
                }
                if (queued.cancelled) {
                    return BotSessionTurnResult(
                        sessionId = sessionId, turnId = null, status = "cancelled",
                        text = "", error = "cancelled")
                }
                return startCoordinatedTurn(
                    sessionId, kind, prompt, hidden, requestId)
            } finally {
                synchronized(stateLock) {
                    if (queuedTurns[sessionId] === queued) queuedTurns.remove(sessionId)
                }
                queued.predecessorDone.countDown()
            }
        }
        return startCoordinatedTurn(sessionId, kind, prompt, hidden, requestId)
    }

    private fun startCoordinatedTurn(
        sessionId: String,
        kind: BotSessionKind,
        prompt: String,
        hidden: Boolean,
        requestId: String,
    ): BotSessionTurnResult {
        val attempt = ActiveTurn(
            sessionId = sessionId,
            attemptId = UUID.randomUUID().toString().lowercase(),
            kind = kind,
            hidden = hidden,
        )
        activeTurns[sessionId] = attempt
        return try {
            val result = performCoordinatedTurn(attempt, prompt, requestId)
            attempt.result.complete(result)
            result
        } catch (error: Exception) {
            attempt.result.completeExceptionally(error)
            throw error
        } finally {
            finishCoordinatedTurn(attempt)
        }
    }

    private fun performCoordinatedTurn(
        attempt: ActiveTurn,
        prompt: String,
        requestId: String,
    ): BotSessionTurnResult {
        val mux = transport.openFollow()
        attempt.connection = mux
        try {
            mux.send(followOpenFrame(attempt.sessionId))
            waitForSnapshot(mux)
            if (activeTurns[attempt.sessionId]?.attemptId != attempt.attemptId) {
                return BotSessionTurnResult(
                    sessionId = attempt.sessionId, turnId = null, status = "cancelled",
                    text = "", error = "stale turn attempt")
            }
            if (attempt.cancelRequested) {
                return BotSessionTurnResult(
                    sessionId = attempt.sessionId, turnId = null, status = "cancelled",
                    text = "", error = "cancelled")
            }
            sendPrompt(attempt.sessionId, prompt, mode = "queue", requestId = requestId)
            attempt.promptAccepted = true
            return collectTurn(mux, attempt)
        } finally {
            attempt.connection = null
            mux.close()
        }
    }

    private fun finishCoordinatedTurn(attempt: ActiveTurn) {
        synchronized(stateLock) {
            if (activeTurns[attempt.sessionId]?.attemptId == attempt.attemptId) {
                activeTurns.remove(attempt.sessionId)
            }
        }
        attempt.finished.countDown()
    }

    private fun awaitTurn(active: ActiveTurn): BotSessionTurnResult = try {
        active.result.get()
    } catch (error: java.util.concurrent.ExecutionException) {
        throw (error.cause as? Exception) ?: error
    }

    private fun canSteer(sessionId: String): Boolean {
        if (queuedTurns[sessionId] != null) return false
        val active = activeTurns[sessionId] ?: return false
        return active.promptAccepted && !active.cancelRequested &&
            active.kind == BotSessionKind.CHAT && !active.hidden
    }

    private fun cancelTurn(sessionId: String, includeQueued: Boolean = false) {
        if (includeQueued) queuedTurns[sessionId]?.cancelled = true
        val active = activeTurns[sessionId]
        if (active == null) {
            if (includeQueued) {
                synchronized(stateLock) {
                    queuedTurns.remove(sessionId)?.cancelled = true
                }
            }
            return
        }
        active.cancelRequested = true
        transport.call(
            "session/cancel",
            JsonObject(linkedMapOf("request" to JsonObject(linkedMapOf(
                "sessionId" to JsonString(sessionId),
                "cause" to JsonObject(linkedMapOf("kind" to JsonString("user"))),
            )))),
        )
        if (!active.finished.await(5, TimeUnit.SECONDS)) {
            // The turn did not consume the terminal frame in the budget: close
            // its mux so a real receive unblocks, then drop the coordinator.
            active.connection?.close()
            synchronized(stateLock) {
                if (activeTurns[sessionId]?.attemptId == active.attemptId) {
                    activeTurns.remove(sessionId)
                }
            }
        }
    }

    private fun sendPrompt(sessionId: String, prompt: String, mode: String, requestId: String) {
        transport.call(
            "session/prompt",
            JsonObject(linkedMapOf("request" to JsonObject(linkedMapOf(
                "requestId" to JsonString(requestId),
                "sessionId" to JsonString(sessionId),
                "mode" to JsonString(mode),
                "content" to JsonArray(listOf(JsonObject(linkedMapOf(
                    "type" to JsonString("text"),
                    "text" to JsonString(prompt),
                )))),
            )))),
        )
    }

    private fun followOpenFrame(sessionId: String): JsonObject = JsonObject(linkedMapOf(
        "type" to JsonString("open"),
        "streamId" to JsonString("follow"),
        "endpoint" to JsonString("session/follow"),
        "payload" to JsonObject(linkedMapOf(
            "args" to JsonObject(linkedMapOf(
                "request" to JsonObject(linkedMapOf(
                    "address" to JsonObject(linkedMapOf(
                        "kind" to JsonString("session"),
                        "sessionId" to JsonString(sessionId),
                    )),
                    "maxMessages" to JsonNumber("64"),
                    "assistantStream" to JsonBool(true),
                )),
            )),
        )),
    ))

    private fun waitForSnapshot(mux: BotFollowConnection) {
        while (true) {
            val frame = mux.receive()
                ?: throw BotSessionException(
                    "unavailable", "session/follow ended before its snapshot")
            if ((frame["type"] as? JsonString)?.value == "error") {
                val message = ((frame["error"] as? JsonObject)?.members?.get("message") as? JsonString)?.value
                throw BotSessionException(
                    "unavailable", message ?: "session/follow failed")
            }
            if ((frame["type"] as? JsonString)?.value != "item") continue
            if ((frame["streamId"] as? JsonString)?.value != "follow") continue
            val value = frame["value"] as? JsonObject
            when ((value?.get("type") as? JsonString)?.value) {
                "snapshot" -> return
                "end" -> throw BotSessionException(
                    "unavailable", "session/follow ended before its snapshot")
                // §6.2: the first follow item MUST be the snapshot. The
                // reference implementation skips a non-snapshot item; the
                // frozen text fails closed before session/prompt.
                else -> throw BotSessionException(
                    "unavailable", "session/follow did not start with its snapshot")
            }
        }
    }

    private fun collectTurn(mux: BotFollowConnection, attempt: ActiveTurn): BotSessionTurnResult {
        val sessionId = attempt.sessionId
        val live = attempt.kind == BotSessionKind.CHAT && !attempt.hidden
        var currentTurn: String? = null
        val texts = ArrayList<String>()
        val resultTexts = ArrayList<String>()
        val toolNames = HashMap<String, String>()
        var suppressWrapUp = false

        fun publish(frame: BotSessionLiveFrame) {
            if (!live) return
            publishLiveFrame(frame)
        }

        while (true) {
            if (activeTurns[sessionId]?.attemptId != attempt.attemptId) {
                return BotSessionTurnResult(
                    sessionId = sessionId, turnId = currentTurn, status = "cancelled",
                    text = "", error = "stale turn attempt")
            }
            val frame = mux.receive()
            if (frame == null) {
                return BotSessionTurnResult(
                    sessionId = sessionId, turnId = currentTurn, status = "failed",
                    text = texts.joinToString(""), error = "session/follow ended before turn/end")
            }
            if ((frame["type"] as? JsonString)?.value == "error") {
                val message = ((frame["error"] as? JsonObject)?.members?.get("message") as? JsonString)?.value
                return BotSessionTurnResult(
                    sessionId = sessionId, turnId = currentTurn, status = "failed",
                    text = texts.joinToString(""), error = message ?: "session/follow failed")
            }
            if ((frame["type"] as? JsonString)?.value != "item") continue
            if ((frame["streamId"] as? JsonString)?.value != "follow") continue
            val value = frame["value"] as? JsonObject ?: continue
            val valueType = (value["type"] as? JsonString)?.value
            if (valueType == "assistant-stream") {
                if (attempt.cancelRequested) continue
                val streamFrame = value["frame"] as? JsonObject
                val frameType = (streamFrame?.members?.get("type") as? JsonString)?.value
                val chunk = streamFrame?.members?.get("chunk") as? JsonObject
                if (frameType == "start") publish(BotSessionLiveFrame.StreamStart)
                if (frameType == "chunk" &&
                    (chunk?.members?.get("type") as? JsonString)?.value == "text-delta"
                ) {
                    val text = (chunk.members["text"] as? JsonString)?.value
                    if (!text.isNullOrEmpty() && !suppressWrapUp) {
                        publish(BotSessionLiveFrame.TextDelta(text))
                    }
                }
                continue
            }
            if (valueType != "event") continue
            val event = value["event"] as? JsonObject ?: continue
            val type = (event["type"] as? JsonString)?.value ?: continue
            if (event["seq"]?.let { jsonLong(it) } == null) continue
            val data = (event["data"] as? JsonObject)?.members ?: emptyMap()
            val eventTurn = jsonLong(data["turn"])?.toString()
            if (currentTurn != null && eventTurn != null && currentTurn != eventTurn) continue
            if (attempt.cancelRequested && type != "turn/end") continue
            if (type == "turn/start") currentTurn = eventTurn ?: currentTurn
            val published = type == "turn/start" || type == "step/start" ||
                type == "tool/call" || type == "tool/result" || type == "turn/end" ||
                (type == "assistant/message" && !suppressWrapUp)
            if (published) publish(BotSessionLiveFrame.Event(type, event))
            when (type) {
                "turn/start" -> {
                    currentTurn = eventTurn ?: currentTurn
                    attempt.currentTurnId = currentTurn
                }
                "step/start" -> Unit
                "user/message" -> Unit
                "assistant/message" -> {
                    val message = data["message"] as? JsonObject
                    val text = textBlocks(message?.members?.get("content"))
                    if (text.isNotEmpty() && !suppressWrapUp) {
                        resultTexts.add(text)
                        if (!attempt.hidden) texts.add(text)
                    }
                }
                "tool/call" -> {
                    val callID = (data["callId"] as? JsonString)?.value ?: ""
                    val name = (data["name"] as? JsonString)?.value ?: ""
                    toolNames[callID] = name
                }
                "tool/result" -> {
                    val message = data["message"] as? JsonObject
                    val callID = (message?.members?.get("toolCallId") as? JsonString)?.value ?: ""
                    val name = toolNames[callID] ?: ""
                    val failed = (message?.members?.get("isError") as? JsonBool)?.value == true ||
                        data["error"] != null
                    if (!failed && isQuestionTool(name)) suppressWrapUp = true
                }
                "turn/end" -> {
                    val reason = data["reason"] as? JsonObject
                    val reasonKind = (reason?.members?.get("kind") as? JsonString)?.value ?: "completed"
                    val cancelled = attempt.cancelRequested ||
                        reasonKind == "aborted" || reasonKind == "interrupted"
                    val status = when {
                        cancelled -> "cancelled"
                        reasonKind == "completed" -> "completed"
                        else -> "failed"
                    }
                    val error = if (status == "completed") {
                        null
                    } else {
                        val message = (reason?.members?.get("error") as? JsonObject)
                            ?.members?.get("message") as? JsonString
                        message?.value ?: reasonKind
                    }
                    return BotSessionTurnResult(
                        sessionId = sessionId,
                        turnId = currentTurn ?: eventTurn,
                        status = status,
                        text = if (attempt.kind == BotSessionKind.CHAT && attempt.hidden) {
                            ""
                        } else {
                            resultTexts.joinToString("")
                        },
                        error = error,
                        finalText = resultTexts.lastOrNull { it.isNotEmpty() },
                    )
                }
                else -> Unit
            }
        }
    }

    private fun publishLiveFrame(frame: BotSessionLiveFrame) {
        val observers = synchronized(this) { liveObservers.values.toList() }
        for (observer in observers) observer(frame)
    }

    // MARK: - Remote calls

    private fun validateRemoteSession(sessionId: String, attempts: Int = 1): Boolean {
        for (attempt in 0 until maxOf(1, attempts)) {
            try {
                val page = transport.call(
                    "session/page",
                    JsonObject(linkedMapOf("request" to JsonObject(linkedMapOf(
                        "address" to JsonObject(linkedMapOf(
                            "kind" to JsonString("session"),
                            "sessionId" to JsonString(sessionId),
                        )),
                        "throughSeq" to JsonNumber("-1"),
                        "maxMessages" to JsonNumber("1"),
                    )))),
                )
                val returned = (page["sessionId"] as? JsonString)?.value
                    ?: ((page["session"] as? JsonObject)?.members?.get("sessionId") as? JsonString)?.value
                return if (returned != null) returned == sessionId else true
            } catch (error: BotSessionRemoteException) {
                if (error.code == "session/not-found" && attempt + 1 < attempts) {
                    try {
                        if (retryDelayMillis > 0) Thread.sleep(retryDelayMillis)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return false
                    }
                    continue
                }
                return false
            } catch (_: Exception) {
                return false
            }
        }
        return false
    }

    private fun remoteSessionCwd(sessionId: String): String? {
        try {
            val list = transport.call(
                "session/list",
                JsonObject(linkedMapOf("_request" to JsonObject(emptyMap()))),
            )
            val items = (list["items"] as? JsonArray)?.values ?: emptyList()
            for (item in items) {
                val members = (item as? JsonObject)?.members ?: continue
                if ((members["sessionId"] as? JsonString)?.value != sessionId) continue
                return (members["cwd"] as? JsonString)?.value
            }
        } catch (error: Exception) {
            ephemeral.add(
                BotSessionEphemeralEvent(
                    type = "runtime.stderr",
                    sessionId = sessionId,
                    data = linkedMapOf(
                        "source" to JsonString("BotDSHRemoteRuntime.remoteSessionCwd"),
                        "message" to JsonString(
                            "session/list cwd lookup failed for $sessionId: ${error.message ?: error}"),
                    ),
                ),
            )
        }
        return null
    }

    private fun archiveRemoteSession(sessionId: String): Boolean = try {
        transport.call(
            "workspace/archiveSession",
            JsonObject(linkedMapOf("request" to JsonObject(linkedMapOf(
                "sessionId" to JsonString(sessionId),
                "stopActivity" to JsonBool(false),
            )))),
        )
        true
    } catch (_: Exception) {
        false
    }

    private fun unarchiveRemoteSession(sessionId: String): Boolean = try {
        transport.call(
            "workspace/unarchiveSession",
            JsonObject(linkedMapOf("request" to JsonObject(linkedMapOf(
                "sessionId" to JsonString(sessionId),
            )))),
        )
        true
    } catch (_: Exception) {
        false
    }

    // MARK: - Naming

    private fun botRoot(): String =
        BotSessionWorkspace.botRoot(botId, botDataDirectory)

    private fun mintedSessionID(kind: BotSessionKind): String =
        if (kind == BotSessionKind.CHAT) {
            "gb-${BotSessionWorkspace.safePathComponent(botId)}"
        } else {
            "gb-${kind.wire}-${UUID.randomUUID().toString().lowercase()}"
        }

    private fun rebuiltMainSessionID(): String =
        "gb-${BotSessionWorkspace.safePathComponent(botId)}-${UUID.randomUUID().toString().lowercase()}"

    private fun requestedPreset(kind: BotSessionKind): String = when (kind) {
        BotSessionKind.VERIFIER -> "pdsh-verifier"
        BotSessionKind.MAINTAINER -> "phone-bot-maintainer"
        else -> "phone-bot"
    }

    private fun isSessionCwdConflict(error: Throwable): Boolean =
        (error as? BotSessionRemoteException)?.code == "session/conflict"

    // MARK: - JSON helpers

    private fun textBlocks(value: JsonValue?): String {
        val blocks = (value as? JsonArray)?.values ?: return ""
        val out = StringBuilder()
        for (block in blocks) {
            val members = (block as? JsonObject)?.members ?: continue
            if ((members["type"] as? JsonString)?.value != "text") continue
            out.append((members["text"] as? JsonString)?.value ?: "")
        }
        return out.toString()
    }

    private fun isQuestionTool(name: String): Boolean =
        name == "ask_user" || name.endsWith("__ask_user") ||
            name == "show_next_steps" || name.endsWith("__show_next_steps")

    private fun jsonLong(value: JsonValue?): Long? {
        val number = value as? JsonNumber ?: return null
        var text = number.raw
        if (text.contains('.') || text.contains('e', ignoreCase = true)) {
            val decimal = try {
                java.math.BigDecimal(text)
            } catch (_: NumberFormatException) {
                return null
            }
            if (decimal.stripTrailingZeros().scale() > 0) return null
            return try {
                decimal.longValueExact()
            } catch (_: ArithmeticException) {
                null
            }
        }
        return text.toLongOrNull()
    }
}

// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.authz.BotTaskAuthorization
import com.phonedsh.bot.session.BotSessionKind
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import com.phonedsh.bot.wake.BotTurnOrigin
import com.phonedsh.bot.wake.HeldMessages
import com.phonedsh.bot.wake.HiddenWakes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * One child turn result. The App's DSH transport supplies this shape; a test
 * fake scripts the same fields. `approvalId` is present when the worker parked
 * the turn on a durable approval.
 */
public data class BotTaskTurnResult(
    public val sessionId: String,
    public val status: String,
    public val text: String = "",
    public val turnId: String? = null,
    public val error: String? = null,
    public val recordRefs: List<String> = emptyList(),
    public val finalText: String? = null,
    public val approvalId: String? = null,
)

/** The caller-side principal facts `Task`/`AwaitTask`/`StopSubagent` need. */
public data class BotTaskCaller(
    public val botId: String,
    public val sessionId: String,
    public val kind: BotSessionKind,
    public val incarnation: String,
    public val capabilities: List<String> = emptyList(),
)

/** One durable approval decision the runtime may reconcile against a parked task. */
public enum class BotTaskApprovalDecision(public val wire: String) {
    ALLOWED("allowed"),
    DENIED("denied"),
    EXPIRED("expired"),
    CANCELLED("cancelled"),
    ;

    public companion object {
        public fun from(value: String?): BotTaskApprovalDecision? =
            entries.firstOrNull { it.wire == value }
    }
}

/**
 * The DSH seam the task runtime needs. The App implementation opens real DSH
 * task sessions and turns; the tests script the same calls. It is deliberately
 * smaller than the whole remote runtime (the MCP remote transport is B5a1's).
 */
public interface BotTaskTransport {
    public suspend fun createSession(kind: BotSessionKind, capabilities: List<String>): String

    public suspend fun runTurn(
        sessionId: String,
        kind: BotSessionKind,
        prompt: String,
        requestId: String,
    ): BotTaskTurnResult

    /** Cancel the session's current turn and (optionally) every queued turn. */
    public suspend fun cancelTurn(sessionId: String, includeQueued: Boolean): Boolean

    /** Ensure the session still exists/attaches for the next turn. */
    public suspend fun ensureSession(sessionId: String, kind: BotSessionKind): Boolean

    /** The Bot's current main chat session, when it is known in this process. */
    public suspend fun currentMainSession(): String?

    /** Cancel a durable approval; false when it was already consumed. */
    public suspend fun cancelApproval(approvalId: String, reason: String): Boolean

    /** A decision already durable for this approval; null while still pending. */
    public suspend fun durableApprovalDecision(approvalId: String): BotTaskApprovalDecision?
}

/** The Task call a host hands to [BotDSHRemoteRuntime.start]. */
public data class BotTaskRequest(
    public val parent: BotTaskCaller,
    public val title: String,
    public val prompt: String,
    public val asynchronous: Boolean,
    public val timeoutMs: Int,
    public val completion: String = "",
    public val purpose: String? = null,
    public val constraints: List<String> = emptyList(),
    public val budget: BotTaskBudget? = null,
    public val authorization: BotTaskAuthorization? = null,
)

/**
 * The task record of `tasks.md` §1 (`BotTaskRecord.jsonValue`). Optional
 * members are omitted from [toJson], never encoded as explicit null.
 */
public data class BotTaskRecord(
    public val taskId: String,
    public val sessionId: String,
    public val status: String,
    public val title: String,
    public val result: String? = null,
    public val partial: String? = null,
    public val error: String? = null,
    public val completion: String? = null,
    public val purpose: String? = null,
    public val constraints: List<String> = emptyList(),
    public val budget: BotTaskBudget? = null,
    public val verification: JsonValue? = null,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["task_id"] = JsonString(taskId)
        members["sessionId"] = JsonString(sessionId)
        members["status"] = JsonString(status)
        members["title"] = JsonString(title)
        result?.let { members["result"] = JsonString(it) }
        partial?.let { members["partial"] = JsonString(it) }
        error?.let { members["error"] = JsonString(it) }
        completion?.takeIf { it.isNotEmpty() }?.let { members["completion"] = JsonString(it) }
        purpose?.takeIf { it.isNotEmpty() }?.let { members["purpose"] = JsonString(it) }
        if (constraints.isNotEmpty()) {
            members["constraints"] = JsonArray(constraints.map(::JsonString))
        }
        budget?.let { members["budget"] = budgetJson(it) }
        verification?.let { members["verification"] = it }
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue?): BotTaskRecord? {
            val members = (value as? JsonObject)?.members ?: return null
            val taskId = string(members["task_id"]) ?: return null
            val sessionId = string(members["sessionId"]) ?: ""
            val status = string(members["status"]) ?: return null
            val title = string(members["title"]) ?: ""
            val constraints = (members["constraints"] as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value }
                ?: emptyList()
            return BotTaskRecord(
                taskId = taskId,
                sessionId = sessionId,
                status = status,
                title = title,
                result = string(members["result"]),
                partial = string(members["partial"]),
                error = string(members["error"]),
                completion = string(members["completion"]),
                purpose = string(members["purpose"]),
                constraints = constraints,
                budget = decodeBudget(members["budget"]),
                verification = members["verification"]?.takeIf { it !is JsonNull },
            )
        }
    }
}

/**
 * The task branch of the Swift `BotDSHRemoteRuntime`.
 *
 * `task.created`/`task.updated` carry the record plus the additive
 * `data.persistedTask` snapshot; `task.settled`/`task.started`/
 * `task.stop_requested` carry only the record. No new table, event type or
 * wire field is introduced. Restore scans the durable log from commit 0,
 * applies a terminal `task.settled` over its snapshot, maps a restored
 * `running`/`stopping` record to `interrupted` (`worker_restarted`), preserves
 * `waiting_approval`, and queues one interrupted wake per asynchronous chat
 * task without `wakeDelivered`.
 */
public class BotDSHRemoteRuntime(
    private val store: BotDomainStore,
    private val transport: BotTaskTransport,
    private val botId: String = "main",
    private val botRoot: String,
    private val now: () -> Long = { System.currentTimeMillis() },
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val incarnationOf: (BotMCPPrincipal) -> String = { it.sessionId },
) : BotTaskPort, BotMCPEventSink {
    public companion object {
        public const val DEFAULT_TASK_TIMEOUT_MS: Int = 180_000
        public const val DEFAULT_AWAIT_TIMEOUT_MS: Int = 180_000
        public const val MINIMUM_TASK_TIMEOUT_MS: Int = 1_000
        public const val MAXIMUM_TASK_TIMEOUT_MS: Int = 300_000
        public const val MINIMUM_AWAIT_TIMEOUT_MS: Int = 1_000
        public const val MAXIMUM_AWAIT_TIMEOUT_MS: Int = 600_000

        private val AWAIT_TERMINAL_STATUSES: Set<String> = setOf(
            "completed", "failed", "stopped", "interrupted", "denied", "waiting_approval",
        )
        private val LIFECYCLE_TERMINAL_STATUSES: Set<String> = setOf(
            "completed", "failed", "stopped", "interrupted", "denied",
        )
        private val RECORD_ONLY_TASK_EVENTS: Set<String> = setOf(
            "task.started", "task.stop_requested", "task.settled",
        )
    }

    private data class TaskState(
        val ownerBotId: String,
        val ownerSessionId: String,
        val ownerIncarnation: String,
        val parentKind: BotSessionKind,
        val title: String,
        val prompt: String,
        val asynchronous: Boolean,
        val timeoutMs: Int,
        val completion: String,
        val purpose: String?,
        val constraints: List<String>,
        val budget: BotTaskBudget?,
        val authorization: BotTaskAuthorization,
        var record: BotTaskRecord,
        var generation: Int,
        var work: Job? = null,
        var stopWork: Deferred<BotTaskRecord>? = null,
        var live: Boolean = true,
        var wakeDelivered: Boolean = false,
        var waitingApprovalID: String? = null,
    )

    private val lock = Any()
    private val taskStates: MutableMap<String, TaskState> = LinkedHashMap()
    private val interruptedTaskWakes: MutableSet<String> = LinkedHashSet()
    private val earlyApprovalDecisions: MutableMap<String, BotTaskApprovalDecision> = LinkedHashMap()
    private val mainSessionEpochs: MutableSet<String> = LinkedHashSet()
    @Volatile
    private var hostParkExpected: Boolean = false
    private var restored: Boolean = false
    private val restoreMutex: Mutex = Mutex()
    /** The SQLite connection is not thread-safe; every durable access is serialized. */
    private val storeMutex: Mutex = Mutex()

    // ------------------------------------------------------------------
    // BotTaskPort (the MCP tool layer's seam)
    // ------------------------------------------------------------------

    override suspend fun start(request: BotTaskStartRequest): JsonValue {
        val caller = caller(request.context)
        val requested = requestedDirectories(request.arguments)
        val authorization = resolveAuthorization(requested, caller)
        val typed = BotTaskRequest(
            parent = caller,
            title = request.title,
            prompt = request.prompt,
            asynchronous = request.asynchronous,
            timeoutMs = request.timeoutMs,
            completion = request.completion,
            purpose = request.purpose,
            constraints = request.constraints,
            budget = request.budget,
            authorization = authorization,
        )
        val record = start(typed)
        return recordWithAuthorization(record, authorization)
    }

    override suspend fun await(
        taskId: String,
        timeoutMs: Int,
        context: BotToolCallContext,
    ): JsonValue {
        val caller = caller(context)
        val record = await(taskId = taskId, timeoutMs = timeoutMs, parent = caller)
        val authorization = synchronized(lock) { taskStates[taskId]?.authorization }
        return recordWithAuthorization(record, authorization)
    }

    override suspend fun stop(taskId: String, context: BotToolCallContext): JsonValue {
        val record = stop(taskId = taskId, parent = caller(context))
        return record.toJson()
    }

    // ------------------------------------------------------------------
    // Typed API
    // ------------------------------------------------------------------

    public suspend fun start(request: BotTaskRequest): BotTaskRecord {
        ensureRestored()
        val authorization = request.authorization
            ?: resolveAuthorization(emptyList(), request.parent)
        val taskId = "task-" + UUID.randomUUID().toString().replace("-", "").take(12)
        val sessionId = transport.createSession(
            BotSessionKind.TASK,
            authorizationCapabilities(authorization),
        )
        val record = BotTaskRecord(
            taskId = taskId,
            sessionId = sessionId,
            status = "running",
            title = request.title,
            partial = "",
            completion = request.completion.takeIf { it.isNotEmpty() },
            purpose = request.purpose?.takeIf { it.isNotEmpty() },
            constraints = request.constraints,
            budget = request.budget,
        )
        val state = TaskState(
            ownerBotId = request.parent.botId,
            ownerSessionId = request.parent.sessionId,
            ownerIncarnation = request.parent.incarnation,
            parentKind = request.parent.kind,
            title = request.title,
            prompt = request.prompt,
            asynchronous = request.asynchronous,
            timeoutMs = request.timeoutMs,
            completion = request.completion,
            purpose = request.purpose,
            constraints = request.constraints,
            budget = request.budget,
            authorization = authorization,
            record = record,
            generation = 1,
            live = true,
        )
        synchronized(lock) { taskStates[taskId] = state }
        try {
            // Durability precedes work: a crash after this event leaves an
            // interrupted task the next process can report, never an orphan.
            persistTask(taskId, "task.created", "created:$taskId")
        } catch (error: Throwable) {
            synchronized(lock) { taskStates.remove(taskId) }
            throw error
        }
        if (request.asynchronous) {
            val work = scope.async(start = CoroutineStart.LAZY) {
                executeTask(taskId, generation = 1)
            }
            synchronized(lock) { taskStates[taskId]?.work = work }
            work.start()
            return record
        }
        return executeTask(taskId, generation = 1)
    }

    /** The resolved write subset stored with one task, for `AwaitTask`. */
    public suspend fun authorization(
        taskId: String,
        parent: BotTaskCaller,
    ): BotTaskAuthorization? {
        ensureRestored()
        val state = ownedTask(taskId, parent)
            ?: throw BotMCPToolException("invalid_arguments", "unknown task: $taskId")
        return state.authorization
    }

    /**
     * Wait on the *record*, not on the background work item that also delivers
     * the parent wake. A terminal record returns immediately; a still-running
     * task returns its current record at the caller's deadline.
     */
    public suspend fun await(
        taskId: String,
        timeoutMs: Int,
        parent: BotTaskCaller,
    ): BotTaskRecord {
        ensureRestored()
        val initial = ownedTask(taskId, parent)
            ?: throw BotMCPToolException("invalid_arguments", "unknown task: $taskId")
        if (isTerminalTaskStatus(initial.record.status)) return initial.record
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(maxOf(0, timeoutMs).toLong())
        while (System.nanoTime() < deadline) {
            delay(20)
            val current = synchronized(lock) { taskStates[taskId]?.record } ?: return initial.record
            if (isTerminalTaskStatus(current.status)) return current
        }
        return synchronized(lock) { taskStates[taskId]?.record } ?: initial.record
    }

    public suspend fun stop(taskId: String, parent: BotTaskCaller): BotTaskRecord {
        ensureRestored()
        val state = ownedTask(taskId, parent)
            ?: throw BotMCPToolException("invalid_arguments", "unknown task: $taskId")
        state.stopWork?.let { return it.await() }
        val waitingApproval = state.record.status == "waiting_approval"
        if (state.record.status in LIFECYCLE_TERMINAL_STATUSES ||
            (!state.live && !waitingApproval)
        ) {
            return state.record
        }
        val generation = state.generation + 1
        val stopping = state.record.copy(
            status = "stopping",
            result = null,
            error = null,
        )
        synchronized(lock) {
            taskStates[taskId]?.generation = generation
            taskStates[taskId]?.record = stopping
        }
        val work = scope.async(start = CoroutineStart.LAZY) {
            performStop(taskId, generation)
        }
        synchronized(lock) { taskStates[taskId]?.stopWork = work }
        work.start()
        return work.await()
    }

    /** Marks the start of a deliberate host park (the S6 epoch eraser). */
    public fun beginHostPark() {
        hostParkExpected = true
    }

    public fun endHostPark() {
        hostParkExpected = false
    }

    /** A Worker replacement: live tasks become interrupted and reconcile approvals. */
    public suspend fun workerRestarted() {
        ensureRestored()
        val live = synchronized(lock) { taskStates.filterValues { it.live }.toMap() }
        for ((taskId, state) in live) {
            state.work?.cancelAndJoin()
            val current = synchronized(lock) { taskStates[taskId] } ?: continue
            if (!current.live) continue
            val record = current.record.copy(
                status = "interrupted",
                result = null,
                partial = current.record.partial,
                error = "worker_restarted",
            )
            synchronized(lock) {
                current.record = record
                current.generation += 1
                current.work = null
                current.stopWork = null
                current.live = false
            }
            runCatching {
                persistTask(taskId, "task.updated", "persisted:interrupted:$taskId")
            }
            if (current.asynchronous && current.parentKind == BotSessionKind.CHAT &&
                !current.wakeDelivered
            ) {
                synchronized(lock) { interruptedTaskWakes += taskId }
            }
        }
        reconcileWaitingApprovals()
    }

    /** Delivers at most one interrupted hidden wake per queued task. */
    public suspend fun deliverInterruptedTaskWakes(): Int {
        ensureRestored()
        val queued = synchronized(lock) { interruptedTaskWakes.sorted() }
        if (queued.isEmpty()) return 0
        var delivered = 0
        for (taskId in queued) {
            val state = synchronized(lock) { taskStates[taskId] }
            if (state == null) {
                synchronized(lock) { interruptedTaskWakes.remove(taskId) }
                continue
            }
            if (state.record.status != "interrupted" || state.wakeDelivered) {
                synchronized(lock) { interruptedTaskWakes.remove(taskId) }
                continue
            }
            val prompt = HiddenWakes.taskInterrupted(taskId = taskId, title = state.title)
            try {
                val result = transport.runTurn(
                    sessionId = parentWakeSessionId(state),
                    kind = BotSessionKind.CHAT,
                    prompt = prompt,
                    requestId = BotTurnOrigin.taskInterruptedRequestId(taskId),
                )
                if (result.status != "completed") continue
                synchronized(lock) { taskStates[taskId]?.wakeDelivered = true }
                runCatching {
                    persistTask(taskId, "task.updated", "persisted:wake:$taskId")
                }
                synchronized(lock) { interruptedTaskWakes.remove(taskId) }
                delivered += 1
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                continue
            }
        }
        return delivered
    }

    /** Convenience for a host recovery path; does not auto-resume a parked turn. */
    public suspend fun reconcileWaitingApprovals() {
        ensureRestored()
        val parked = synchronized(lock) {
            taskStates.filterValues { it.record.status == "waiting_approval" }.toMap()
        }
        for ((taskId, state) in parked) {
            val approvalID = state.waitingApprovalID ?: continue
            val decision = synchronized(lock) { earlyApprovalDecisions.remove(approvalID) }
                ?: transport.durableApprovalDecision(approvalID)
                ?: continue
            applyApprovalToTask(taskId, approvalID, decision)
        }
    }

    /** Applies a decision to a parked task, or remembers an early one. */
    public suspend fun approvalResolved(
        approvalId: String,
        decision: BotTaskApprovalDecision,
    ) {
        ensureRestored()
        val parked = synchronized(lock) {
            taskStates.entries.firstOrNull { it.value.waitingApprovalID == approvalId }
        }
        if (parked == null) {
            synchronized(lock) { earlyApprovalDecisions[approvalId] = decision }
            return
        }
        applyApprovalToTask(parked.key, approvalId, decision)
    }

    public fun queuedInterruptedTaskIDs(): List<String> =
        synchronized(lock) { interruptedTaskWakes.sorted() }

    /** Host hook for an erasure epoch switch; mirrors Swift's `mainSessionEpochs`. */
    public fun noteMainSessionEpoch(sessionId: String) {
        if (sessionId.isNotEmpty()) {
            synchronized(lock) { mainSessionEpochs += sessionId }
        }
    }

    public fun recordFor(taskId: String): BotTaskRecord? =
        synchronized(lock) { taskStates[taskId]?.record }

    // ------------------------------------------------------------------
    // Event sink (tool wrapper's task.started / task.stop_requested / settled)
    // ------------------------------------------------------------------

    override suspend fun append(event: BotMCPEvent) {
        // `task.started`/`task.stop_requested`/`task.settled` carry only the
        // record fields; `authorization` is part of the Task tool result, not
        // the durable event body (`tasks.md` §5).
        val data = if (event.type in RECORD_ONLY_TASK_EVENTS) {
            val members = (event.data as? JsonObject)?.members
            if (members != null) JsonObject(members.filterKeys { it != "authorization" })
            else event.data
        } else {
            event.data
        }
        val taskId = ((data as? JsonObject)?.members?.get("task_id") as? JsonString)?.value
        val traceId = if (taskId != null) "task:$taskId" else "evt:${event.type}"
        val source = when {
            event.type.startsWith("task.") -> "task-manager"
            event.type == "agent.comm" -> "comm-service"
            event.type.startsWith("routine.") -> "scheduler"
            event.type.startsWith("memory.") -> "memory-service"
            event.type.startsWith("card.") -> "card-bridge"
            else -> "mcp"
        }
        val origin = BotEventOrigin.Local(source)
        val principal = BotPrincipal(
            botId = event.principal.botId,
            sessionId = event.principal.sessionId.takeIf { it.isNotEmpty() },
            kind = event.principal.kind.wire,
            capabilities = event.principal.capabilities.toList(),
        )
        // `tasks.md` §4/§12 ruling 5: `task.stop_requested` has a generated
        // event id, never `stop:<taskId>`. B5a1's tool wrapper still passes the
        // legacy shape, so the durable writer normalizes it here.
        val eventId = when {
            event.type == "task.stop_requested" ->
                "evt-task.stop_requested-${UUID.randomUUID().toString().lowercase()}"
            event.eventId != null -> event.eventId!!
            else -> "evt-${event.type}-${UUID.randomUUID().toString().lowercase()}"
        }
        storeMutex.withLock {
            store.append(
                BotEvent(
                    schemaVersion = com.phonedsh.bot.store.BotEventCodec.CURRENT_SCHEMA_VERSION,
                    type = event.type,
                    eventId = eventId,
                    commitSeq = null,
                    time = now(),
                    origin = origin,
                    traceId = traceId,
                    principal = principal,
                    causationId = null,
                    correlationId = taskId,
                    data = data,
                ),
            )
        }
    }

    // ------------------------------------------------------------------
    // Execution
    // ------------------------------------------------------------------

    private suspend fun executeTask(
        taskId: String,
        generation: Int,
        resumeApprovalID: String? = null,
    ): BotTaskRecord {
        val state = synchronized(lock) { taskStates[taskId] } ?: return BotTaskRecord(
            taskId = taskId,
            sessionId = "",
            status = "stopped",
            title = "",
        )
        if (state.generation != generation || state.record.status != "running") {
            return state.record
        }
        try {
            val resume = if (resumeApprovalID != null) {
                "\n\n[approval_resume] The user approved the pending $resumeApprovalID approval. " +
                    "Continue this task from where it stopped. Do not repeat side effects that already happened."
            } else {
                ""
            }
            val prompt = authorizationPrompt(state.authorization) +
                "\n\n" + taskContractPrompt(
                    completion = state.completion,
                    purpose = state.purpose,
                    constraints = state.constraints,
                    budgetMs = state.budget?.maxDurationMs ?: state.timeoutMs,
                ) +
                resume +
                "\n\n" + state.prompt
            val requestID = if (resumeApprovalID != null) {
                "${BotTurnOrigin.taskTurnRequestId(taskId)}:approval:$resumeApprovalID"
            } else {
                BotTurnOrigin.taskTurnRequestId(taskId)
            }
            val turn = transport.runTurn(
                sessionId = state.record.sessionId,
                kind = BotSessionKind.TASK,
                prompt = prompt,
                requestId = requestID,
            )
            val current = synchronized(lock) { taskStates[taskId] } ?: return state.record
            if (current.generation != generation || current.record.status != "running") {
                return current.record
            }
            // A turn that ends with a durable approval pending parks here;
            // its partial text is the latest assistant text.
            if (turn.approvalId != null) {
                return parkForApproval(taskId, generation, turn.approvalId, turn.text)
            }
            if (turn.status == "interrupted") {
                return markTaskInterrupted(
                    taskId = taskId,
                    generation = generation,
                    partial = turn.text,
                )
            }
            val completed = turn.status == "completed"
            val record = current.record.copy(
                status = if (completed) "completed" else "failed",
                result = if (completed) turn.text else null,
                partial = turn.text,
                error = if (completed) null else (turn.error ?: "task turn failed"),
            )
            synchronized(lock) {
                taskStates[taskId]?.record = record
                taskStates[taskId]?.work = null
                taskStates[taskId]?.live = false
            }
            runCatching {
                persistTask(taskId, "task.updated", "persisted:settled:$taskId")
            }
            runCatching { appendSettled(taskId, record, current) }
            if (current.asynchronous && current.parentKind == BotSessionKind.CHAT &&
                synchronized(lock) { taskStates[taskId]?.generation } == generation
            ) {
                val prompt = HiddenWakes.taskSettled(
                    taskId = taskId,
                    title = current.title,
                    status = record.status,
                    excerpt = turn.text,
                )
                runCatching {
                    transport.runTurn(
                        sessionId = parentWakeSessionId(current),
                        kind = BotSessionKind.CHAT,
                        prompt = prompt,
                        requestId = BotTurnOrigin.taskSettledRequestId(taskId),
                    )
                }
            }
            return record
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            val current = synchronized(lock) { taskStates[taskId] } ?: return state.record
            if (current.generation != generation || current.record.status != "running") {
                return current.record
            }
            if (hostParkExpected) {
                return markTaskInterrupted(
                    taskId = taskId,
                    generation = generation,
                    partial = current.record.partial,
                )
            }
            // A parked approval is not a task failure. The worker may close the
            // transport while parking; the durable decision later resumes it.
            if (current.waitingApprovalID != null) {
                return current.record
            }
            val record = current.record.copy(
                status = "failed",
                result = null,
                partial = null,
                error = error.message ?: error.toString(),
            )
            synchronized(lock) {
                taskStates[taskId]?.record = record
                taskStates[taskId]?.work = null
                taskStates[taskId]?.live = false
            }
            runCatching {
                persistTask(taskId, "task.updated", "persisted:failed:$taskId")
            }
            return record
        }
    }

    private suspend fun parkForApproval(
        taskId: String,
        generation: Int,
        approvalId: String,
        partial: String?,
    ): BotTaskRecord {
        val current = synchronized(lock) { taskStates[taskId] } ?: return BotTaskRecord(
            taskId = taskId,
            sessionId = "",
            status = "stopped",
            title = "",
        )
        if (current.generation != generation) return current.record
        val parked = current.record.copy(
            status = "waiting_approval",
            partial = partial ?: current.record.partial,
            error = "approval_pending",
        )
        synchronized(lock) {
            current.record = parked
            current.generation = generation + 1
            current.waitingApprovalID = approvalId
            current.work = null
            current.live = false
        }
        runCatching {
            persistTask(taskId, "task.updated", "persisted:waiting-approval:$taskId")
        }
        val early = synchronized(lock) { earlyApprovalDecisions.remove(approvalId) }
        if (early != null) applyApprovalToTask(taskId, approvalId, early)
        return synchronized(lock) { taskStates[taskId]?.record } ?: parked
    }

    private suspend fun applyApprovalToTask(
        taskId: String,
        approvalId: String,
        decision: BotTaskApprovalDecision,
    ) {
        val state = synchronized(lock) { taskStates[taskId] } ?: return
        if (state.record.status != "waiting_approval" &&
            state.record.status != "running"
        ) {
            return
        }
        when (decision) {
            BotTaskApprovalDecision.ALLOWED -> {
                val resumed = state.record.copy(status = "running", error = null)
                val generation = state.generation + 1
                synchronized(lock) {
                    taskStates[taskId]?.record = resumed
                    taskStates[taskId]?.generation = generation
                    taskStates[taskId]?.waitingApprovalID = null
                    taskStates[taskId]?.live = true
                }
                runCatching { transport.ensureSession(state.record.sessionId, BotSessionKind.TASK) }
                runCatching {
                    persistTask(taskId, "task.updated", "persisted:resumed:$taskId")
                }
                appendResumed(taskId, state.record.sessionId, approvalId)
                val work = scope.async(start = CoroutineStart.LAZY) {
                    executeTask(taskId, generation, resumeApprovalID = approvalId)
                }
                synchronized(lock) { taskStates[taskId]?.work = work }
                work.start()
            }

            BotTaskApprovalDecision.DENIED,
            BotTaskApprovalDecision.EXPIRED,
            -> {
                val error = if (decision == BotTaskApprovalDecision.DENIED) {
                    "approval_denied"
                } else {
                    "approval_expired"
                }
                val denied = state.record.copy(
                    status = "denied",
                    result = null,
                    error = error,
                )
                synchronized(lock) {
                    taskStates[taskId]?.record = denied
                    taskStates[taskId]?.generation = state.generation + 1
                    taskStates[taskId]?.waitingApprovalID = null
                    taskStates[taskId]?.live = false
                    taskStates[taskId]?.work = null
                }
                runCatching {
                    persistTask(taskId, "task.updated", "persisted:denied:$taskId")
                }
                runCatching { appendSettled(taskId, denied, state) }
                if (state.asynchronous && state.parentKind == BotSessionKind.CHAT &&
                    !state.wakeDelivered
                ) {
                    deliverDeniedWake(taskId, state, approvalId, error)
                }
            }

            BotTaskApprovalDecision.CANCELLED -> {
                val stopped = state.record.copy(
                    status = "stopped",
                    result = null,
                    error = "approval_cancelled",
                )
                synchronized(lock) {
                    taskStates[taskId]?.record = stopped
                    taskStates[taskId]?.generation = state.generation + 1
                    taskStates[taskId]?.waitingApprovalID = null
                    taskStates[taskId]?.live = false
                    taskStates[taskId]?.work = null
                }
                runCatching {
                    persistTask(taskId, "task.updated", "persisted:stopped:$taskId")
                }
                runCatching { appendSettled(taskId, stopped, state) }
            }
        }
    }

    private suspend fun deliverDeniedWake(
        taskId: String,
        state: TaskState,
        approvalId: String,
        error: String,
    ) {
        val prompt = HiddenWakes.taskDenied(
            taskId = taskId,
            title = state.title,
            error = error,
            approvalId = approvalId,
        )
        val result = runCatching {
            transport.runTurn(
                sessionId = parentWakeSessionId(state),
                kind = BotSessionKind.CHAT,
                prompt = prompt.text,
                requestId = prompt.requestId,
            )
        }.getOrNull() ?: return
        if (result.status != "completed") return
        synchronized(lock) { taskStates[taskId]?.wakeDelivered = true }
        runCatching {
            persistTask(taskId, "task.updated", "persisted:denied-wake:$taskId")
        }
    }

    private suspend fun performStop(taskId: String, generation: Int): BotTaskRecord {
        val state = synchronized(lock) { taskStates[taskId] } ?: throw BotMCPToolException(
            "invalid_arguments",
            "unknown task",
        )
        if (state.generation != generation) {
            throw BotMCPToolException("invalid_arguments", "unknown task")
        }
        transport.cancelTurn(state.record.sessionId, includeQueued = true)
        val work = state.work
        if (work != null) {
            work.cancelAndJoin()
        }
        state.waitingApprovalID?.let { approvalID ->
            runCatching { transport.cancelApproval(approvalID, "task_stopped") }
        }
        val stopped = state.record.copy(
            status = "stopped",
            result = null,
            error = null,
            partial = state.record.partial,
        )
        val current = synchronized(lock) { taskStates[taskId] }
        if (current == null || current.generation != generation) {
            throw BotMCPToolException("invalid_arguments", "unknown task")
        }
        synchronized(lock) {
            current.record = stopped
            current.work = null
            current.stopWork = null
            current.live = false
        }
        runCatching {
            persistTask(taskId, "task.updated", "persisted:stopped:$taskId")
        }
        runCatching { appendSettled(taskId, stopped, current) }
        return stopped
    }

    private suspend fun markTaskInterrupted(
        taskId: String,
        generation: Int,
        partial: String?,
    ): BotTaskRecord {
        val state = synchronized(lock) { taskStates[taskId] } ?: return BotTaskRecord(
            taskId = taskId,
            sessionId = "",
            status = "stopped",
            title = "",
        )
        if (state.generation != generation || state.record.status != "running") {
            return state.record
        }
        val record = state.record.copy(
            status = "interrupted",
            result = null,
            partial = partial ?: state.record.partial,
            error = "worker_restarted",
        )
        synchronized(lock) {
            taskStates[taskId]?.record = record
            taskStates[taskId]?.generation = generation + 1
            taskStates[taskId]?.work = null
            taskStates[taskId]?.stopWork = null
            taskStates[taskId]?.live = false
        }
        runCatching {
            persistTask(taskId, "task.updated", "persisted:interrupted:$taskId")
        }
        if (state.asynchronous && state.parentKind == BotSessionKind.CHAT &&
            !state.wakeDelivered
        ) {
            synchronized(lock) { interruptedTaskWakes += taskId }
        }
        return record
    }

    // ------------------------------------------------------------------
    // Durable records
    // ------------------------------------------------------------------

    private suspend fun persistTask(taskId: String, type: String, eventId: String) {
        val state = synchronized(lock) { taskStates[taskId] } ?: return
        val snapshot = persistedTaskJson(state)
        val data = LinkedHashMap((state.record.toJson()).members)
        data["persistedTask"] = snapshot
        storeMutex.withLock {
            store.append(
                BotEvent(
                    schemaVersion = 1,
                    type = type,
                    eventId = eventId,
                    commitSeq = null,
                    time = now(),
                    origin = BotEventOrigin.Local("task-manager"),
                    traceId = "task:$taskId",
                    principal = BotPrincipal(
                        botId = state.ownerBotId,
                        sessionId = state.ownerSessionId,
                        kind = state.parentKind.wire,
                        capabilities = emptyList(),
                    ),
                    causationId = null,
                    correlationId = taskId,
                    data = JsonObject(data),
                ),
            )
        }
    }

    private suspend fun appendSettled(
        taskId: String,
        record: BotTaskRecord,
        state: TaskState,
    ) {
        storeMutex.withLock {
            store.append(
                BotEvent(
                    schemaVersion = 1,
                    type = "task.settled",
                    eventId = "settled:$taskId",
                    commitSeq = null,
                    time = now(),
                    origin = BotEventOrigin.Local("task-manager"),
                    traceId = "task:$taskId",
                    principal = BotPrincipal(
                        botId = state.ownerBotId,
                        sessionId = record.sessionId,
                        kind = BotSessionKind.TASK.wire,
                        capabilities = emptyList(),
                    ),
                    causationId = null,
                    correlationId = taskId,
                    data = record.toJson(),
                ),
            )
        }
    }

    private suspend fun appendResumed(
        taskId: String,
        sessionId: String,
        approvalId: String,
    ) {
        storeMutex.withLock {
            store.append(
                BotEvent(
                    schemaVersion = 1,
                    type = "task.resumed",
                    eventId = "resumed:$taskId",
                    commitSeq = null,
                    time = now(),
                    origin = BotEventOrigin.Local("task-manager"),
                    traceId = "task:$taskId",
                    principal = BotPrincipal(
                        botId = botId,
                        sessionId = sessionId,
                        kind = BotSessionKind.TASK.wire,
                        capabilities = emptyList(),
                    ),
                    causationId = null,
                    correlationId = taskId,
                    data = BotJson.objectOf(
                        "task_id" to JsonString(taskId),
                        "sessionId" to JsonString(sessionId),
                        "status" to JsonString("running"),
                        "approvalID" to JsonString(approvalId),
                        "resumedAt" to JsonNumber(now().toString()),
                    ),
                ),
            )
        }
    }

    private fun persistedTaskJson(state: TaskState): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["taskId"] = JsonString(state.record.taskId)
        members["sessionId"] = JsonString(state.record.sessionId)
        members["parentSessionId"] = JsonString(state.ownerSessionId)
        members["parentBotId"] = JsonString(state.ownerBotId)
        members["parentIncarnation"] = JsonString(state.ownerIncarnation)
        members["parentKind"] = JsonString(state.parentKind.wire)
        members["title"] = JsonString(state.title)
        members["prompt"] = JsonString(state.prompt)
        members["asynchronous"] = JsonBool(state.asynchronous)
        members["timeoutMs"] = JsonNumber(state.timeoutMs.toString())
        members["status"] = JsonString(state.record.status)
        members["createdAt"] = JsonNumber(now().toString())
        members["wakeDelivered"] = JsonBool(state.wakeDelivered)
        state.record.result?.let { members["result"] = JsonString(it) }
        state.record.partial?.let { members["partial"] = JsonString(it) }
        state.record.error?.let { members["error"] = JsonString(it) }
        members["authorization"] = authorizationJson(state.authorization)
        state.completion.takeIf { it.isNotEmpty() }?.let {
            members["completion"] = JsonString(it)
        }
        state.purpose?.takeIf { it.isNotEmpty() }?.let {
            members["purpose"] = JsonString(it)
        }
        members["constraints"] = JsonArray(state.constraints.map(::JsonString))
        state.budget?.let { members["budget"] = budgetJson(it) }
        state.record.verification?.let { members["verification"] = it }
        state.waitingApprovalID?.let { members["waitingApprovalID"] = JsonString(it) }
        return JsonObject(members)
    }

    // ------------------------------------------------------------------
    // Restore
    // ------------------------------------------------------------------

    public suspend fun restore() {
        ensureRestored()
    }

    private suspend fun ensureRestored() {
        if (restored) return
        restoreMutex.withLock {
            if (restored) return
            restoreMainSessionEpochs()
            restorePersistedTasks()
            restored = true
        }
    }

    private suspend fun restoreMainSessionEpochs() {
        var cursor = 0
        while (true) {
            val events = try {
                storeMutex.withLock { store.events(cursor, 1_000) }
            } catch (_: Throwable) {
                break
            }
            for (event in events) {
                if (event.type != "runtime.started") continue
                if (event.principal.botId != botId) continue
                if (event.principal.kind != BotSessionKind.CHAT.wire) continue
                val sessionId = ((event.data as? JsonObject)?.members?.get("sessionId")
                    as? JsonString)?.value
                    ?: event.principal.sessionId
                if (!sessionId.isNullOrEmpty()) mainSessionEpochs += sessionId
            }
            if (events.size != 1_000) break
            cursor = events.last().commitSeq?.toInt() ?: break
        }
    }

    private suspend fun restorePersistedTasks() {
        val latest = LinkedHashMap<String, JsonObject>()
        val settled = LinkedHashMap<String, BotTaskRecord>()
        var cursor = 0
        while (true) {
            val events = try {
                storeMutex.withLock { store.events(cursor, 1_000) }
            } catch (_: Throwable) {
                break
            }
            for (event in events) {
                val persisted = (event.data as? JsonObject)?.members?.get("persistedTask")
                    as? JsonObject
                if (persisted != null &&
                    (persisted.members["parentBotId"] as? JsonString)?.value == botId
                ) {
                    val taskId = (persisted.members["taskId"] as? JsonString)?.value
                    if (!taskId.isNullOrEmpty()) latest[taskId] = persisted
                }
                if (event.type == "task.settled") {
                    val record = BotTaskRecord.fromJson(event.data)
                    if (record != null) settled[record.taskId] = record
                }
            }
            if (events.size != 1_000) break
            cursor = events.last().commitSeq?.toInt() ?: break
        }
        for (taskId in latest.keys.sorted()) {
            val snapshot = latest.getValue(taskId)
            var record = BotTaskRecord(
                taskId = taskId,
                sessionId = string(snapshot.members["sessionId"]) ?: "",
                status = string(snapshot.members["status"]) ?: "failed",
                title = string(snapshot.members["title"]) ?: "",
                result = string(snapshot.members["result"]),
                partial = string(snapshot.members["partial"]),
                error = string(snapshot.members["error"]),
                completion = string(snapshot.members["completion"]),
                purpose = string(snapshot.members["purpose"]),
                constraints = (snapshot.members["constraints"] as? JsonArray)?.values
                    ?.mapNotNull { (it as? JsonString)?.value }
                    ?: emptyList(),
                budget = decodeBudget(snapshot.members["budget"]),
                verification = snapshot.members["verification"]?.takeIf { it !is JsonNull },
            )
            settled[taskId]?.let { terminal ->
                // The terminal event is authoritative for status/title/
                // result/partial/error; the snapshot keeps the S3 fields an
                // older binary may not have written.
                record = BotTaskRecord(
                    taskId = terminal.taskId,
                    sessionId = terminal.sessionId,
                    status = terminal.status,
                    title = terminal.title,
                    result = terminal.result,
                    partial = terminal.partial,
                    error = terminal.error,
                    completion = terminal.completion ?: record.completion,
                    purpose = terminal.purpose ?: record.purpose,
                    constraints = if (terminal.constraints.isEmpty()) {
                        record.constraints
                    } else {
                        terminal.constraints
                    },
                    budget = terminal.budget ?: record.budget,
                    verification = terminal.verification ?: record.verification,
                )
            }
            val interrupted = record.status == "running" || record.status == "stopping"
            if (interrupted) {
                record = record.copy(
                    status = "interrupted",
                    result = null,
                    partial = record.partial,
                    error = "worker_restarted",
                )
            }
            val parentKind = runCatching {
                BotSessionKind.fromWire(string(snapshot.members["parentKind"]) ?: "chat")
            }.getOrDefault(BotSessionKind.CHAT)
            val authorization = decodeAuthorization(snapshot.members["authorization"])
                ?: defaultAuthorization()
            val state = TaskState(
                ownerBotId = string(snapshot.members["parentBotId"]) ?: botId,
                ownerSessionId = string(snapshot.members["parentSessionId"]) ?: "",
                ownerIncarnation = string(snapshot.members["parentIncarnation"]) ?: "",
                parentKind = parentKind,
                title = string(snapshot.members["title"]) ?: "",
                prompt = string(snapshot.members["prompt"]) ?: "",
                asynchronous = (snapshot.members["asynchronous"] as? JsonBool)?.value ?: false,
                timeoutMs = (snapshot.members["timeoutMs"] as? JsonNumber)
                    ?.asLongOrNull()?.toInt() ?: DEFAULT_TASK_TIMEOUT_MS,
                completion = string(snapshot.members["completion"]) ?: "",
                purpose = string(snapshot.members["purpose"]),
                constraints = (snapshot.members["constraints"] as? JsonArray)?.values
                    ?.mapNotNull { (it as? JsonString)?.value }
                    ?: emptyList(),
                budget = decodeBudget(snapshot.members["budget"]),
                authorization = authorization,
                record = record,
                generation = 1,
                live = false,
                wakeDelivered = (snapshot.members["wakeDelivered"] as? JsonBool)?.value ?: false,
                waitingApprovalID = string(snapshot.members["waitingApprovalID"]),
            )
            synchronized(lock) { taskStates[taskId] = state }
            if (interrupted) {
                runCatching {
                    persistTask(taskId, "task.updated", "persisted:interrupted:$taskId")
                }
            }
            if (interrupted && state.asynchronous &&
                parentKind == BotSessionKind.CHAT && !state.wakeDelivered
            ) {
                synchronized(lock) { interruptedTaskWakes += taskId }
            }
        }
        synchronized(lock) {
            val sorted = interruptedTaskWakes.sorted()
            interruptedTaskWakes.clear()
            interruptedTaskWakes.addAll(sorted)
        }
    }

    // ------------------------------------------------------------------
    // Ownership / routing
    // ------------------------------------------------------------------

    private suspend fun ownedTask(taskId: String, parent: BotTaskCaller): TaskState? {
        val state = synchronized(lock) { taskStates[taskId] } ?: return null
        if (state.ownerBotId != parent.botId) {
            throw BotMCPToolException("unauthorized", "Unauthorized")
        }
        if (state.ownerSessionId != parent.sessionId) {
            if (state.parentKind != BotSessionKind.CHAT ||
                parent.kind != BotSessionKind.CHAT
            ) {
                throw BotMCPToolException("unauthorized", "Unauthorized")
            }
            if (currentMainSessionRouting(state.ownerSessionId) != parent.sessionId) {
                throw BotMCPToolException("unauthorized", "Unauthorized")
            }
            return state
        }
        // A live call is bound to the exact session incarnation. A persisted
        // record may outlive its incarnation; the same bot+session may still
        // read or stop it (the interrupted status is explicit).
        if (state.live && state.ownerIncarnation != parent.incarnation) {
            throw BotMCPToolException("unauthorized", "Unauthorized")
        }
        return state
    }

    private suspend fun currentMainSessionRouting(ownerSessionId: String): String? {
        if (ownerSessionId !in mainSessionEpochs) return null
        val current = transport.currentMainSession() ?: latestMainSessionEvent() ?: return null
        if (current == ownerSessionId) return null
        return current
    }

    private suspend fun latestMainSessionEvent(): String? {
        var cursor = 0
        var latest: String? = null
        while (true) {
            val events = try {
                storeMutex.withLock { store.events(cursor, 1_000) }
            } catch (_: Throwable) {
                break
            }
            for (event in events) {
                if (event.type != "runtime.started") continue
                if (event.principal.botId != botId) continue
                if (event.principal.kind != BotSessionKind.CHAT.wire) continue
                latest = ((event.data as? JsonObject)?.members?.get("sessionId")
                    as? JsonString)?.value ?: event.principal.sessionId ?: latest
            }
            if (events.size != 1_000) break
            cursor = events.last().commitSeq?.toInt() ?: break
        }
        return latest
    }

    private suspend fun parentWakeSessionId(state: TaskState): String {
        if (state.parentKind != BotSessionKind.CHAT || state.ownerBotId != botId) {
            return state.ownerSessionId
        }
        return currentMainSessionRouting(state.ownerSessionId) ?: state.ownerSessionId
    }

    // ------------------------------------------------------------------
    // Authorization
    // ------------------------------------------------------------------

    private fun resolveAuthorization(
        requestedDirectories: List<String>,
        parent: BotTaskCaller,
    ): BotTaskAuthorization {
        if (requestedDirectories.size > 32) {
            throw BotMCPToolException(
                "invalid_arguments",
                "allowed_write_directories accepts at most 32 entries",
            )
        }
        val rawRoot = botRoot.trim()
        if (rawRoot.isEmpty()) {
            throw BotMCPToolException(
                "execution_failed",
                "invalid task write authorization: 工作区根目录为空",
            )
        }
        val root = java.nio.file.Path.of(rawRoot).toAbsolutePath().normalize().toString()
        if (root.length + BotTaskAuthorization.WORKSPACE_CAPABILITY_PREFIX.length > 128) {
            throw BotMCPToolException(
                "execution_failed",
                "invalid task write authorization: 工作区根目录超出会话权限的长度上限",
            )
        }
        val directories = ArrayList<String>()
        for (raw in requestedDirectories) {
            val value = raw.trim()
            if (value.isEmpty()) {
                throw BotMCPToolException(
                    "execution_failed",
                    "invalid task write authorization: 目录条目为空",
                )
            }
            val normalized = java.nio.file.Path.of(value).let {
                if (it.isAbsolute) it else java.nio.file.Path.of(root).resolve(it)
            }.normalize().toString()
            if (normalized.isEmpty()) {
                throw BotMCPToolException(
                    "execution_failed",
                    "invalid task write authorization: 目录条目规范化后为空",
                )
            }
            if (normalized.length + BotTaskAuthorization.WRITE_DIRECTORY_PREFIX.length > 128) {
                throw BotMCPToolException(
                    "execution_failed",
                    "invalid task write authorization: 目录条目超出会话权限的长度上限",
                )
            }
            if (normalized !in directories) directories += normalized
        }
        val allowed = if (directories.isEmpty()) listOf(root) else directories
        val outside = allowed.any { it != root && !it.startsWith("$root/") }
        var authorized = BotTaskAuthorization(
            workspaceRoot = root,
            allowedWriteDirectories = allowed,
            canWriteOutsideWorkspace = outside,
            canNetworkWrite = false,
            canDelegateTasks = false,
        )
        if (parent.kind == BotSessionKind.TASK) {
            val parentAuthorization = BotTaskAuthorization.fromCapabilities(parent.capabilities)
            if (parentAuthorization != null) {
                val narrowed = authorized.allowedWriteDirectories.filter { directory ->
                    parentAuthorization.allowedWriteDirectories.any { allowedDirectory ->
                        directory == allowedDirectory || directory.startsWith("$allowedDirectory/")
                    }
                }
                authorized = authorized.copy(
                    allowedWriteDirectories = if (narrowed.isEmpty()) {
                        parentAuthorization.allowedWriteDirectories
                    } else {
                        narrowed
                    },
                )
            }
        }
        return authorized
    }

    private fun defaultAuthorization(): BotTaskAuthorization {
        val root = java.nio.file.Path.of(botRoot).toAbsolutePath().normalize().toString()
        return BotTaskAuthorization(
            workspaceRoot = root,
            allowedWriteDirectories = listOf(root),
            canWriteOutsideWorkspace = false,
            canNetworkWrite = false,
            canDelegateTasks = false,
        )
    }

    private fun authorizationCapabilities(
        authorization: BotTaskAuthorization,
    ): List<String> {
        val values = ArrayList<String>()
        values += "${BotTaskAuthorization.WORKSPACE_CAPABILITY_PREFIX}${authorization.workspaceRoot}"
        values += authorization.allowedWriteDirectories.map {
            "${BotTaskAuthorization.WRITE_DIRECTORY_PREFIX}$it"
        }
        if (authorization.canWriteOutsideWorkspace) {
            values += BotTaskAuthorization.OUTSIDE_WORKSPACE_CAPABILITY
        }
        if (authorization.canNetworkWrite) {
            values += BotTaskAuthorization.NETWORK_WRITE_CAPABILITY
        }
        if (authorization.canDelegateTasks) {
            values += BotTaskAuthorization.DELEGATE_CAPABILITY
        }
        return values
    }

    private fun authorizationJson(value: BotTaskAuthorization): JsonObject =
        JsonObject(
            linkedMapOf(
                "workspaceRoot" to JsonString(value.workspaceRoot),
                "allowedWriteDirectories" to JsonArray(
                    value.allowedWriteDirectories.map(::JsonString),
                ),
                "canWriteOutsideWorkspace" to JsonBool(value.canWriteOutsideWorkspace),
                "canNetworkWrite" to JsonBool(value.canNetworkWrite),
                "canDelegateTasks" to JsonBool(value.canDelegateTasks),
            ),
        )

    private fun recordWithAuthorization(
        record: BotTaskRecord,
        authorization: BotTaskAuthorization?,
    ): JsonValue {
        if (authorization == null) return record.toJson()
        val members = LinkedHashMap(record.toJson().members)
        members["authorization"] = authorizationJson(authorization)
        return JsonObject(members)
    }

    // ------------------------------------------------------------------
    // Caller / helpers
    // ------------------------------------------------------------------

    private fun caller(context: BotToolCallContext): BotTaskCaller {
        val kind = runCatching {
            BotSessionKind.fromWire(context.principal.kind.wire)
        }.getOrDefault(BotSessionKind.CHAT)
        return BotTaskCaller(
            botId = context.principal.botId,
            sessionId = context.principal.sessionId,
            kind = kind,
            incarnation = incarnationOf(context.principal),
            capabilities = context.principal.capabilities.toList(),
        )
    }

    private fun requestedDirectories(arguments: JsonValue): List<String> {
        val members = (arguments as? JsonObject)?.members ?: return emptyList()
        return (members["allowed_write_directories"] as? JsonArray)?.values
            ?.mapNotNull { (it as? JsonString)?.value }
            ?: emptyList()
    }

    private fun isTerminalTaskStatus(status: String): Boolean =
        status in AWAIT_TERMINAL_STATUSES

    // ------------------------------------------------------------------
    // Prompt builders (byte-for-byte with the Swift reference)
    // ------------------------------------------------------------------

    internal fun taskContractPrompt(
        completion: String,
        purpose: String?,
        constraints: List<String>,
        budgetMs: Int,
    ): String {
        val lines = ArrayList<String>()
        lines += "<task_contract>"
        lines += "budget_ms: $budgetMs"
        if (completion.isNotEmpty()) {
            lines += "completion:"
            lines += HeldMessages.escapedHeldField(completion)
        }
        if (!purpose.isNullOrEmpty()) {
            lines += "purpose:"
            lines += HeldMessages.escapedHeldField(purpose)
        }
        if (constraints.isNotEmpty()) {
            lines += "constraints:"
            lines += constraints.map { "- ${HeldMessages.escapedHeldField(it)}" }
        }
        if (completion.isNotEmpty()) {
            lines += "Finish only when the completion condition is true. " +
                "A separate read-only verifier will re-check the artifacts and raw records; " +
                "your own summary is not evidence."
        }
        lines += "</task_contract>"
        return lines.joinToString("\n")
    }

    internal fun authorizationPrompt(authorization: BotTaskAuthorization): String {
        val escapedRoot = HeldMessages.escapedHeldField(authorization.workspaceRoot)
        val directories = authorization.allowedWriteDirectories
            .joinToString(", ") { HeldMessages.escapedHeldField(it) }
        return buildString {
            appendLine("<task_authorization>")
            appendLine("workspace_root: $escapedRoot")
            appendLine("allowed_write_directories: $directories")
            appendLine("write_outside_workspace: ${authorization.canWriteOutsideWorkspace}")
            appendLine("network_write: ${authorization.canNetworkWrite}")
            appendLine("delegate_tasks: ${authorization.canDelegateTasks}")
            append("</task_authorization>")
        }
    }

}

// ---------------------------------------------------------------------------
// Small codecs shared by the runtime and its tests.
// ---------------------------------------------------------------------------

internal fun budgetJson(value: BotTaskBudget): JsonObject {
    val members = LinkedHashMap<String, JsonValue>()
    value.maxDurationMs?.let { members["max_duration_ms"] = JsonNumber(it.toString()) }
    return JsonObject(members)
}

internal fun decodeBudget(value: JsonValue?): BotTaskBudget? {
    val members = (value as? JsonObject)?.members ?: return null
    return BotTaskBudget((members["max_duration_ms"] as? JsonNumber)?.asLongOrNull()?.toInt())
}

internal fun decodeAuthorization(value: JsonValue?): BotTaskAuthorization? {
    val members = (value as? JsonObject)?.members ?: return null
    val root = string(members["workspaceRoot"]) ?: return null
    val directories = (members["allowedWriteDirectories"] as? JsonArray)?.values
        ?.mapNotNull { (it as? JsonString)?.value }
        ?: listOf(root)
    return BotTaskAuthorization(
        workspaceRoot = root,
        allowedWriteDirectories = directories,
        canWriteOutsideWorkspace = (members["canWriteOutsideWorkspace"] as? JsonBool)?.value
            ?: false,
        canNetworkWrite = (members["canNetworkWrite"] as? JsonBool)?.value ?: false,
        canDelegateTasks = (members["canDelegateTasks"] as? JsonBool)?.value ?: false,
    )
}

private fun string(value: JsonValue?): String? = (value as? JsonString)?.value

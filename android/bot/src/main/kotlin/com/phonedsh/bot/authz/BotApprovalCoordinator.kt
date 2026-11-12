// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.attachments.BotWorkspaceLayout
import com.phonedsh.bot.gateway.BotAttribution
import com.phonedsh.bot.gateway.BotGatewayPrincipal
import com.phonedsh.bot.session.BotSessionKind
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Optional Task-session authority hook. The runtime owns the capability
 * parser; the coordinator only gives it the frozen validation slot before a
 * card exists (`task_scope:*`).
 */
public fun interface BotTaskAuthorizationPort {
    public fun denial(
        call: BotResolvedToolCall,
        bareName: String,
        arguments: JsonValue,
        command: String,
    ): String?
}

/**
 * The pending/decision state machine for `/approval`
 * (`BotApprovalCoordinator.swift`, D13 §8.3-§8.4).
 *
 * Interactive cards wait up to 300,000 ms; task/routine cards are durable
 * todos with a 24 h expiry. A `once` grant is consumed at decision time unless
 * every effect declares an execution seam, and a durable approval always
 * leaves its once grant for the resumed retry. All `stale:*` refusals are
 * ordinary 200 outcomes (`ok:false, allowed:false, pending:false`).
 */
public class BotApprovalCoordinator(
    private val grants: BotGrantStore,
    private val eventLog: BotAuthzEventLog? = null,
    private val now: () -> Long = { System.currentTimeMillis() },
    public val approvalTimeoutMs: Long = DEFAULT_TIMEOUT_MILLISECONDS,
    public val durableExpiryMs: Long = DEFAULT_DURABLE_EXPIRY_MILLISECONDS,
    private val scheduler: BotApprovalScheduler = BotRealApprovalScheduler,
    private val taskAuthorization: BotTaskAuthorizationPort? = BotTaskAuthorizationGate,
) : BotApprovalPort, BotInteractiveApprovalCanceller {
    private data class Pending(
        val principal: BotGatewayPrincipal,
        val callId: String,
        val effects: List<BotToolEffect>,
        val digest: String,
        val action: String,
        val detail: String,
        val command: String,
        val alwaysScope: String,
        val deferConsumption: Boolean,
        val persistent: Boolean,
        val origin: String,
        val requestedAt: Long,
        val expiresAt: Long,
        var continuation: CompletableFuture<BotApprovalOutcome>?,
        var timeout: BotApprovalCancellation?,
        var waitTimeout: BotApprovalCancellation?,
    )

    private val authorizer = BotExecutionAuthorizer(grants)
    private val lock = Any()
    private val pending = LinkedHashMap<String, Pending>()
    private val decisions = LinkedHashMap<String, BotApprovalResolutionNotice>()
    private val lastDecisionBySession = HashMap<String, BotApprovalResolutionNotice>()
    private val pendingNotices = ArrayList<BotApprovalResolutionNotice>()
    private var resolutionHandler: ((BotApprovalResolutionNotice) -> Unit)? = null
    private var restored = eventLog == null
    private var restoring = false

    init {
        require(approvalTimeoutMs > 0) { "approvalTimeoutMs must be positive" }
        require(durableExpiryMs > 0) { "durableExpiryMs must be positive" }
    }

    public fun setResolutionHandler(handler: ((BotApprovalResolutionNotice) -> Unit)?) {
        synchronized(lock) {
            resolutionHandler = handler
            if (handler != null) {
                val queued = pendingNotices.toList()
                pendingNotices.clear()
                for (notice in queued) handler(notice)
            }
        }
    }

    override fun approve(
        body: com.phonedsh.agentcore.JsonObject,
        runtimeId: String,
        resolver: BotApprovalRegistrationResolver,
    ): BotApprovalOutcome {
        val request = BotApprovalRequest.parse(body) ?: return BotApprovalOutcome.invalidRequest()
        return approve(request, runtimeId, resolver)
    }

    public fun approve(
        request: BotApprovalRequest,
        runtimeId: String,
        resolver: BotApprovalRegistrationResolver,
    ): BotApprovalOutcome {
        val call = resolver.resolve(runtimeId, request.sessionId, request.callId)
            ?: return BotApprovalOutcome.stale("unattributed")
        val bareName = bareToolName(request.tool)
        if (bareToolName(call.attribution.name) != bareName) {
            return BotApprovalOutcome.stale("unattributed")
        }
        val suppliedDigest = BotArgumentsDigest.validatedOrNull(request.argsDigest)
            ?: return BotApprovalOutcome.stale("stale:digest_mismatch")
        val storedDigest = BotArgumentsDigest.string(call.arguments)
        if (suppliedDigest != call.attribution.argsDigest || storedDigest != suppliedDigest) {
            return BotApprovalOutcome.stale("stale:digest_mismatch")
        }
        if (bareName == "bash") {
            val storedCommand = (call.arguments as? com.phonedsh.agentcore.JsonObject)
                ?.members?.get("command")?.let(BotJson::string)
            if (storedCommand != request.command) {
                return BotApprovalOutcome.stale("stale:command_mismatch")
            }
        }
        taskAuthorization?.denial(call, bareName, call.arguments, request.command)?.let {
            return BotApprovalOutcome.stale(it)
        }
        val effects: List<BotToolEffect>
        if (request.askAction == "sandbox-escalation") {
            val supplied = request.effects
            val effect = supplied?.singleOrNull()
            if (bareName != "bash" || request.alwaysScope != "none" || effect == null ||
                effect.operation != "sandbox-escalation" ||
                BotResourceNormalizer.normalize(effect.resource).isEmpty()
            ) {
                return BotApprovalOutcome.stale("stale:sandbox_effect")
            }
            effects = listOf(
                BotToolEffect(
                    tool = "bash",
                    operation = "sandbox-escalation",
                    resource = effect.resource,
                    target = effect.target,
                    mutability = BotToolMutability.WRITE,
                    policy = BotToolPolicy.ASK,
                    label = request.action,
                    detail = request.detail,
                ),
            )
        } else {
            effects = effectsForApproval(bareName, call.botId, call.arguments)
        }
        if (request.alwaysScope !in setOf("until", "session", "none")) {
            return BotApprovalOutcome.stale("stale:always_scope")
        }
        val expectedScope = if (effects.isNotEmpty() && effects.all { !it.known }) "session" else "until"
        if (request.alwaysScope != expectedScope && request.alwaysScope != "none") {
            return BotApprovalOutcome.stale("stale:always_scope")
        }
        if (effects.isEmpty()) {
            return BotApprovalOutcome(ok = true, allowed = true, pending = false, message = "auto-policy")
        }
        val persistence = when (call.principal.kind) {
            BotSessionKind.TASK, BotSessionKind.ROUTINE -> BotApprovalPersistence.DURABLE
            else -> BotApprovalPersistence.INTERACTIVE
        }
        return request(
            call = call,
            effects = effects,
            action = request.action,
            detail = request.detail,
            command = request.command,
            alwaysScope = request.alwaysScope,
            persistence = persistence,
            origin = "structural",
        )
    }

    override fun request(
        call: BotResolvedToolCall,
        effects: List<BotToolEffect>,
        action: String,
        detail: String,
        command: String,
        alwaysScope: String,
        persistence: BotApprovalPersistence,
        origin: String,
        onPending: ((String) -> Unit)?,
        interactiveWaitMilliseconds: Long,
    ): BotApprovalOutcome {
        ensureRestored()
        val deferConsumption = effects.all { it.execution != null }
        standingDecision(call, effects, deferConsumption)?.let { return it }
        if (origin == "egress") {
            matchingPendingEgress(call.principal, effects)?.let { existing ->
                return pendingOutcome(existing.first, existing.second)
            }
        }
        val approvalId = "approval-" + UUID.randomUUID().toString().lowercase()
        val principal = call.principal
        val digest = call.attribution.argsDigest
        val requestedAt = now()
        val persistent = persistence == BotApprovalPersistence.DURABLE
        val expiresAt = if (persistent) requestedAt + durableExpiryMs else 0L
        val data = linkedMapOf<String, JsonValue>(
            "approvalID" to JsonString(approvalId),
            "status" to JsonString("pending"),
            "action" to JsonString(action),
            "detail" to JsonString(detail),
            "digest" to JsonString(digest),
            "command" to JsonString(command),
            "alwaysScope" to JsonString(alwaysScope),
            "deferConsumption" to JsonBool(deferConsumption),
            "effects" to JsonArray(effects.map { it.toJson() }),
            "persistent" to JsonBool(persistent),
            "kind" to JsonString(principal.kind.wire),
            "origin" to JsonString(origin),
            "requestedAt" to BotJson.number(requestedAt),
        )
        if (persistent) data["expiresAt"] = BotJson.number(expiresAt)
        if (!writeEvent("approval.requested", principal, com.phonedsh.agentcore.JsonObject(data))) {
            return BotApprovalOutcome(ok = false, allowed = false, message = "approval audit failed")
        }
        val future = CompletableFuture<BotApprovalOutcome>()
        val expiryTimeout = if (persistent) {
            scheduler.schedule(maxOf(1L, expiresAt - requestedAt)) { expireDurable(approvalId) }
        } else {
            null
        }
        val waitTimeout = if (persistent && interactiveWaitMilliseconds > 0) {
            scheduler.schedule(interactiveWaitMilliseconds) { expireDurableWait(approvalId) }
        } else {
            null
        }
        val interactiveTimeout = if (!persistent) {
            scheduler.schedule(approvalTimeoutMs) { expireInteractive(approvalId) }
        } else {
            null
        }
        val request = Pending(
            principal = principal,
            callId = call.callId,
            effects = effects,
            digest = digest,
            action = action,
            detail = detail,
            command = command,
            alwaysScope = alwaysScope,
            deferConsumption = deferConsumption,
            persistent = persistent,
            origin = origin,
            requestedAt = requestedAt,
            expiresAt = expiresAt,
            continuation = future,
            timeout = expiryTimeout ?: interactiveTimeout,
            waitTimeout = waitTimeout,
        )
        synchronized(lock) {
            pending[approvalId] = request
        }
        onPending?.invoke(approvalId)
        if (persistent && interactiveWaitMilliseconds <= 0) {
            return pendingOutcome(approvalId, expiresAt)
        }
        return await(future, approvalId)
    }

    public fun standingDecision(
        call: BotResolvedToolCall,
        effects: List<BotToolEffect>,
        deferConsumption: Boolean,
    ): BotApprovalOutcome? {
        val decision = authorizer.authorizeExecution(
            principal = BotExecutionPrincipal.fromGateway(call.principal),
            effects = effects,
            source = "approval-standing",
            argsDigest = call.attribution.argsDigest,
            consumeOnce = !deferConsumption,
        )
        if (decision.allowed) {
            return BotApprovalOutcome(
                ok = true, allowed = true, pending = false, message = decision.reason,
            )
        }
        if (decision.denied || decision.reason == "standing-deny") {
            return BotApprovalOutcome(
                ok = true, allowed = false, pending = false, message = decision.reason,
            )
        }
        return null
    }

    override fun resolve(
        approvalId: String,
        decision: BotApprovalDecision,
        digest: String,
    ): BotApprovalResolution {
        ensureRestored()
        synchronized(lock) {
            val request = pending[approvalId]
            if (request == null) {
                val notice = decisions[approvalId]
                return BotApprovalResolution.Stale(
                    when {
                        notice == null -> "unknown_approval"
                        notice.expired -> "expired"
                        notice.cancelled -> "cancelled"
                        else -> "already_decided"
                    },
                )
            }
            val supplied = BotArgumentsDigest.validatedOrNull(digest)
            if (supplied == null || supplied != request.digest) {
                return BotApprovalResolution.Stale("digest_mismatch")
            }
            if (request.persistent && request.expiresAt > 0 && now() >= request.expiresAt) {
                pending.remove(approvalId)
                request.timeout?.cancel()
                request.waitTimeout?.cancel()
                finishDurableExpiry(approvalId, request)
                return BotApprovalResolution.Stale("expired")
            }
            pending.remove(approvalId)
            request.timeout?.cancel()
            request.waitTimeout?.cancel()
            var allowed = decision != BotApprovalDecision.DENY
            val createdGrantIds = ArrayList<String>()
            var effectiveScope = BotGrantScope.ONCE
            if (allowed) {
                effectiveScope = when (decision) {
                    BotApprovalDecision.ALLOW_ONCE -> BotGrantScope.ONCE
                    BotApprovalDecision.ALWAYS -> when (request.alwaysScope) {
                        "until" -> BotGrantScope.UNTIL
                        "session" -> BotGrantScope.SESSION
                        else -> BotGrantScope.ONCE
                    }
                    BotApprovalDecision.DENY -> BotGrantScope.ONCE
                }
                try {
                    for (effect in request.effects) {
                        val grant = grants.add(
                            BotGrant(
                                botId = request.principal.botId,
                                tool = effect.tool,
                                operation = effect.operation,
                                resource = effect.resource,
                                scope = effectiveScope,
                                sessionId = request.principal.sessionId,
                                createdAt = now(),
                                source = "approval-card",
                                decision = BotGrantDecision.ALLOW,
                            ),
                        )
                        createdGrantIds += grant.id
                    }
                    if (effectiveScope == BotGrantScope.ONCE &&
                        !request.deferConsumption && !request.persistent
                    ) {
                        if (!grants.consumeOnceAtomically(createdGrantIds)) {
                            throw BotGrantException("invalidGrant", "once grant was already consumed")
                        }
                    }
                } catch (_: Exception) {
                    allowed = false
                    for (id in createdGrantIds) grants.revoke(id)
                }
            }
            val decisionData = linkedMapOf<String, JsonValue>(
                "approvalID" to JsonString(approvalId),
                "decision" to JsonString(decision.wire),
                "status" to JsonString(if (allowed) "allowed" else "denied"),
                "alwaysScope" to JsonString(
                    if (decision == BotApprovalDecision.ALWAYS) request.alwaysScope else effectiveScope.wire,
                ),
            )
            if (request.persistent) {
                decisionData["persistent"] = JsonBool(true)
                decisionData["kind"] = JsonString(request.principal.kind.wire)
            }
            val written = writeEvent(
                "approval.decided",
                request.principal,
                com.phonedsh.agentcore.JsonObject(decisionData),
                eventId = "decided:$approvalId",
            )
            if (!written) {
                allowed = false
                for (id in createdGrantIds) grants.revoke(id)
                if (request.persistent) {
                    pending[approvalId] = request
                    scheduleExpiry(approvalId, request.expiresAt)
                    return BotApprovalResolution.Stale("audit_failed")
                }
            }
            val outcome = BotApprovalOutcome(
                ok = allowed,
                allowed = allowed,
                approvalId = approvalId,
                message = if (allowed) "allowed" else "approval denied",
                pending = false,
                decision = decision,
                scope = if (allowed) effectiveScope.wire else null,
                onceGrantIDs = if (allowed && effectiveScope == BotGrantScope.ONCE &&
                    request.persistent && request.origin == "egress"
                ) {
                    createdGrantIds
                } else {
                    emptyList()
                },
            )
            request.continuation?.complete(outcome)
            if (request.persistent) {
                val notice = BotApprovalResolutionNotice(
                    approvalID = approvalId,
                    principal = request.principal,
                    allowed = allowed,
                    decision = decision,
                    decidedAt = now(),
                )
                record(notice)
                deliver(notice)
            }
            return BotApprovalResolution.Resolved
        }
    }

    override fun cancel(approvalId: String): Boolean {
        ensureRestored()
        synchronized(lock) {
            val request = pending[approvalId] ?: return false
            if (request.persistent) return false
            pending.remove(approvalId)
            request.timeout?.cancel()
            request.waitTimeout?.cancel()
            writeEvent(
                "approval.decided",
                request.principal,
                com.phonedsh.agentcore.JsonObject(
                    linkedMapOf(
                        "approvalID" to JsonString(approvalId),
                        "decision" to JsonString("deny"),
                        "status" to JsonString("cancelled"),
                        "reason" to JsonString("consumer_cancelled"),
                    ),
                ),
                eventId = "cancelled:$approvalId",
            )
            request.continuation?.complete(
                BotApprovalOutcome(
                    ok = false,
                    allowed = false,
                    approvalId = approvalId,
                    message = "approval cancelled",
                    pending = false,
                ),
            )
            return true
        }
    }

    public fun cancelPersistent(approvalId: String, reason: String): Boolean {
        ensureRestored()
        synchronized(lock) {
            val request = pending[approvalId] ?: return false
            if (!request.persistent) return false
            pending.remove(approvalId)
            request.timeout?.cancel()
            request.waitTimeout?.cancel()
            writeEvent(
                "approval.decided",
                request.principal,
                com.phonedsh.agentcore.JsonObject(
                    linkedMapOf(
                        "approvalID" to JsonString(approvalId),
                        "decision" to JsonString("deny"),
                        "status" to JsonString("cancelled"),
                        "reason" to JsonString(reason),
                        "persistent" to JsonBool(true),
                    ),
                ),
                eventId = "cancelled:$approvalId",
            )
            val notice = BotApprovalResolutionNotice(
                approvalID = approvalId,
                principal = request.principal,
                allowed = false,
                cancelled = true,
                decision = BotApprovalDecision.DENY,
                decidedAt = now(),
            )
            request.continuation?.complete(
                BotApprovalOutcome(
                    ok = false,
                    allowed = false,
                    approvalId = approvalId,
                    message = "approval cancelled",
                    pending = false,
                ),
            )
            record(notice)
            deliver(notice)
            return true
        }
    }

    override fun cancelInteractive(sessionId: String, callId: String): Int {
        ensureRestored()
        val ids = synchronized(lock) {
            pending.filter {
                !it.value.persistent && it.value.principal.sessionId == sessionId &&
                    it.value.callId == callId
            }.keys.toList()
        }
        var cancelled = 0
        for (id in ids) if (cancel(id)) cancelled++
        return cancelled
    }

    override fun cancelInteractive(reason: String): Int {
        ensureRestored()
        val ids = synchronized(lock) {
            pending.filter { !it.value.persistent }.keys.toList()
        }
        var cancelled = 0
        for (id in ids) {
            synchronized(lock) {
                val request = pending[id] ?: return@synchronized
                pending.remove(id)
                request.timeout?.cancel()
                request.waitTimeout?.cancel()
                writeEvent(
                    "approval.decided",
                    request.principal,
                    com.phonedsh.agentcore.JsonObject(
                        linkedMapOf(
                            "approvalID" to JsonString(id),
                            "decision" to JsonString("deny"),
                            "status" to JsonString("cancelled"),
                            "reason" to JsonString(reason),
                        ),
                    ),
                    eventId = "cancelled:$id",
                )
                request.continuation?.complete(
                    BotApprovalOutcome(
                        ok = false,
                        allowed = false,
                        approvalId = id,
                        message = "approval unavailable",
                        pending = false,
                    ),
                )
                cancelled++
            }
        }
        return cancelled
    }

    public fun cancelAll(botId: String, reason: String = "bot_deleted"): Int {
        ensureRestored()
        val ids = synchronized(lock) {
            pending.filter { it.value.principal.botId == botId }.keys.toList()
        }
        var cancelled = 0
        for (id in ids) {
            val persistent = synchronized(lock) { pending[id]?.persistent == true }
            if (persistent) {
                if (cancelPersistent(id, reason)) cancelled++
            } else if (cancel(id)) {
                cancelled++
            }
        }
        return cancelled
    }

    override fun pendingIDs(): List<String> = synchronized(lock) { pending.keys.sorted() }

    override fun pendingDigest(approvalId: String): String? =
        synchronized(lock) { pending[approvalId]?.digest }

    public fun pendingApproval(sessionId: String): BotDurableApprovalState? {
        ensureRestored()
        synchronized(lock) {
            val match = pending.entries
                .filter { it.value.persistent && it.value.principal.sessionId == sessionId }
                .sortedWith(compareBy({ it.value.requestedAt }, { it.key }))
                .firstOrNull() ?: return null
            return state(match.key, match.value)
        }
    }

    override fun durableStatus(approvalId: String): BotApprovalDurableStatus {
        ensureRestored()
        synchronized(lock) {
            if (pending[approvalId]?.persistent == true) return BotApprovalDurableStatus.PENDING
            val notice = decisions[approvalId] ?: return BotApprovalDurableStatus.UNKNOWN
            return when {
                notice.cancelled -> BotApprovalDurableStatus.CANCELLED
                notice.expired -> BotApprovalDurableStatus.EXPIRED
                notice.allowed -> BotApprovalDurableStatus.ALLOWED
                else -> BotApprovalDurableStatus.DENIED
            }
        }
    }

    public fun consumeOnceGrants(ids: List<String>): Boolean {
        if (ids.isEmpty()) return true
        return try {
            grants.consumeOnceAtomically(ids)
        } catch (_: Exception) {
            false
        }
    }

    public fun restoreDurable() {
        ensureRestored()
    }

    private fun ensureRestored() {
        if (restored || restoring) return
        val log = eventLog ?: run {
            restored = true
            return
        }
        restoring = true
        try {
            val requested = LinkedHashMap<String, Pair<BotAuthzPrincipal?, com.phonedsh.agentcore.JsonObject>>()
            val decided = HashSet<String>()
            var cursor = 0L
            while (true) {
                val events = try {
                    log.events(cursor, 1_000)
                } catch (_: Exception) {
                    break
                }
                if (events.isEmpty()) break
                for (event in events) {
                    val data = event.data
                    val id = BotJson.string(data.members["approvalID"]) ?: continue
                    when (event.type) {
                        "approval.requested" -> requested[id] = event.principal to data
                        "approval.decided" -> decided += id
                    }
                }
                val last = events.last().sequence
                if (events.size < 1_000 || last <= cursor) break
                cursor = last
            }
            synchronized(lock) {
                for ((id, pair) in requested) {
                    if (id in decided || pending.containsKey(id)) continue
                    val (eventPrincipal, data) = pair
                    val persistent = BotJson.bool(data.members["persistent"]) == true
                    if (!persistent) {
                        writeEvent(
                            "approval.decided",
                            principalFrom(eventPrincipal),
                            com.phonedsh.agentcore.JsonObject(
                                linkedMapOf(
                                    "approvalID" to JsonString(id),
                                    "decision" to JsonString("deny"),
                                    "status" to JsonString("cancelled"),
                                    "reason" to JsonString("worker_restarted"),
                                ),
                            ),
                            eventId = "cancelled:$id",
                        )
                        continue
                    }
                    val requestedAt = BotJson.long(data.members["requestedAt"]) ?: now()
                    val expiresAt = BotJson.long(data.members["expiresAt"]) ?: (requestedAt + durableExpiryMs)
                    val principal = principalFrom(eventPrincipal)
                    if (expiresAt > 0 && now() >= expiresAt) {
                        writeEvent(
                            "approval.decided",
                            principal,
                            com.phonedsh.agentcore.JsonObject(
                                linkedMapOf(
                                    "approvalID" to JsonString(id),
                                    "decision" to JsonString("deny"),
                                    "status" to JsonString("expired"),
                                    "reason" to JsonString("approval_expired"),
                                    "expired" to JsonBool(true),
                                    "timedOut" to JsonBool(false),
                                    "persistent" to JsonBool(true),
                                ),
                            ),
                            eventId = "expired:$id",
                        )
                        record(
                            BotApprovalResolutionNotice(
                                approvalID = id,
                                principal = principal,
                                allowed = false,
                                expired = true,
                                decision = BotApprovalDecision.DENY,
                                decidedAt = now(),
                            ),
                        )
                        continue
                    }
                    val effects = (data.members["effects"] as? JsonArray)?.values
                        ?.mapNotNull(BotToolEffect::fromJson) ?: emptyList()
                    val request = Pending(
                        principal = principal,
                        callId = "",
                        effects = effects,
                        digest = BotJson.string(data.members["digest"]) ?: "",
                        action = BotJson.string(data.members["action"]) ?: "",
                        detail = BotJson.string(data.members["detail"]) ?: "",
                        command = BotJson.string(data.members["command"]) ?: "",
                        alwaysScope = BotJson.string(data.members["alwaysScope"]) ?: "until",
                        deferConsumption = BotJson.bool(data.members["deferConsumption"]) ?: true,
                        persistent = true,
                        origin = BotJson.string(data.members["origin"]) ?: "structural",
                        requestedAt = requestedAt,
                        expiresAt = expiresAt,
                        continuation = null,
                        timeout = null,
                        waitTimeout = null,
                    )
                    pending[id] = request
                    scheduleExpiry(id, expiresAt)
                }
            }
            restored = true
        } finally {
            restoring = false
        }
    }

    private fun finishDurableExpiry(approvalId: String, request: Pending) {
        writeEvent(
            "approval.decided",
            request.principal,
            com.phonedsh.agentcore.JsonObject(
                linkedMapOf(
                    "approvalID" to JsonString(approvalId),
                    "decision" to JsonString("deny"),
                    "status" to JsonString("expired"),
                    "reason" to JsonString("approval_expired"),
                    "expired" to JsonBool(true),
                    "timedOut" to JsonBool(false),
                    "persistent" to JsonBool(true),
                ),
            ),
            eventId = "expired:$approvalId",
        )
        request.continuation?.complete(
            BotApprovalOutcome(
                ok = false,
                allowed = false,
                approvalId = approvalId,
                message = "approval expired",
                pending = false,
            ),
        )
        val notice = BotApprovalResolutionNotice(
            approvalID = approvalId,
            principal = request.principal,
            allowed = false,
            expired = true,
            decision = BotApprovalDecision.DENY,
            decidedAt = now(),
        )
        record(notice)
        deliver(notice)
    }

    private fun expireInteractive(approvalId: String) {
        synchronized(lock) {
            val request = pending.remove(approvalId) ?: return
            if (request.persistent) return
            request.timeout?.cancel()
            writeEvent(
                "approval.decided",
                request.principal,
                com.phonedsh.agentcore.JsonObject(
                    linkedMapOf(
                        "approvalID" to JsonString(approvalId),
                        "decision" to JsonString("deny"),
                        "status" to JsonString("denied"),
                        "timedOut" to JsonBool(true),
                    ),
                ),
            )
            request.continuation?.complete(
                BotApprovalOutcome(
                    ok = false,
                    allowed = false,
                    approvalId = approvalId,
                    message = "approval timed out",
                    pending = false,
                ),
            )
        }
    }

    private fun expireDurable(approvalId: String) {
        synchronized(lock) {
            val request = pending.remove(approvalId) ?: return
            if (!request.persistent) return
            request.timeout?.cancel()
            request.waitTimeout?.cancel()
            finishDurableExpiry(approvalId, request)
        }
    }

    private fun expireDurableWait(approvalId: String) {
        synchronized(lock) {
            val request = pending[approvalId] ?: return
            if (!request.persistent) return
            val continuation = request.continuation ?: return
            pending[approvalId] = request.copy(continuation = null, waitTimeout = null)
            continuation.complete(pendingOutcome(approvalId, request.expiresAt))
        }
    }

    private fun scheduleExpiry(approvalId: String, expiresAt: Long) {
        val delay = maxOf(1L, expiresAt - now())
        val timeout = scheduler.schedule(delay) { expireDurable(approvalId) }
        synchronized(lock) {
            pending[approvalId]?.let { pending[approvalId] = it.copy(timeout = timeout) }
        }
    }

    private fun matchingPendingEgress(
        principal: BotGatewayPrincipal,
        effects: List<BotToolEffect>,
    ): Pair<String, Long>? {
        val effect = effects.firstOrNull() ?: return null
        synchronized(lock) {
            return pending.entries
                .filter { (_, request) ->
                    request.persistent && request.origin == "egress" &&
                        request.principal.botId == principal.botId &&
                        request.principal.sessionId == principal.sessionId &&
                        request.effects.any {
                            it.operation == effect.operation && it.resource == effect.resource
                        }
                }
                .sortedWith(compareBy({ it.value.requestedAt }, { it.key }))
                .firstOrNull()
                ?.let { it.key to it.value.expiresAt }
        }
    }

    private fun effectsForApproval(
        name: String,
        botId: String,
        arguments: JsonValue,
    ): List<BotToolEffect> {
        if (name == "BotVolatileContext") return emptyList()
        val workspace = BotWorkspaceLayout.botRoot(botId)
        if (name == "bash") {
            return BotApprovalPatternAnalyzer.effects(name, arguments, workspace)
        }
        if (name == "write" || name == "edit") {
            return BotEgressEffects.fileEffects(name, arguments, workspace)
        }
        val effect = BotToolEffectClassifier.effect(name, arguments)
        return if (effect.mutability == BotToolMutability.READ || effect.ui ||
            effect.policy == BotToolPolicy.AUTO
        ) {
            emptyList()
        } else {
            listOf(effect)
        }
    }

    private fun await(future: CompletableFuture<BotApprovalOutcome>, approvalId: String): BotApprovalOutcome =
        try {
            future.get()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            cancel(approvalId)
            BotApprovalOutcome(
                ok = false, allowed = false, approvalId = approvalId,
                message = "approval unavailable", pending = false,
            )
        } catch (_: ExecutionException) {
            BotApprovalOutcome(
                ok = false, allowed = false, approvalId = approvalId,
                message = "approval unavailable", pending = false,
            )
        }

    private fun pendingOutcome(approvalId: String, expiresAt: Long): BotApprovalOutcome =
        BotApprovalOutcome(
            ok = true,
            allowed = false,
            approvalId = approvalId,
            message = "approval pending",
            pending = true,
            expiresAt = expiresAt,
        )

    private fun writeEvent(
        type: String,
        principal: BotGatewayPrincipal,
        data: com.phonedsh.agentcore.JsonObject,
        eventId: String = "$type-" + UUID.randomUUID().toString().lowercase(),
    ): Boolean {
        val log = eventLog ?: return true
        return try {
            log.append(
                BotAuthzEvent(
                    sequence = 0,
                    type = type,
                    eventId = eventId,
                    time = now(),
                    principal = BotAuthzPrincipal(
                        botId = principal.botId,
                        sessionId = principal.sessionId,
                        kind = principal.kind.wire,
                        capabilities = principal.capabilities,
                    ),
                    data = data,
                ),
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun principalFrom(principal: BotAuthzPrincipal?): BotGatewayPrincipal {
        if (principal == null) {
            return BotGatewayPrincipal(
                botId = "main",
                sessionId = "gb-main",
                kind = BotSessionKind.CHAT,
                capabilities = emptyList(),
                expiresAt = Long.MAX_VALUE,
                incarnation = "restored",
            )
        }
        val kind = principal.kind.let { wire ->
            BotSessionKind.entries.firstOrNull { it.wire == wire }
        } ?: BotSessionKind.CHAT
        return BotGatewayPrincipal(
            botId = principal.botId ?: "main",
            sessionId = principal.sessionId ?: "gb-main",
            kind = kind,
            capabilities = principal.capabilities,
            expiresAt = Long.MAX_VALUE,
            incarnation = "restored",
        )
    }

    private fun state(id: String, request: Pending): BotDurableApprovalState =
        BotDurableApprovalState(
            approvalID = id,
            principal = request.principal,
            status = BotApprovalDurableStatus.PENDING,
            requestedAt = request.requestedAt,
            expiresAt = request.expiresAt,
            action = request.action,
            detail = request.detail,
            command = request.command,
        )

    private fun record(notice: BotApprovalResolutionNotice) {
        decisions[notice.approvalID] = notice
        lastDecisionBySession[notice.principal.sessionId] = notice
        while (decisions.size > 512) {
            decisions.remove(decisions.keys.first())
        }
        while (lastDecisionBySession.size > 512) {
            lastDecisionBySession.remove(lastDecisionBySession.keys.first())
        }
    }

    private fun deliver(notice: BotApprovalResolutionNotice) {
        val handler = synchronized(lock) {
            val current = resolutionHandler
            if (current == null) pendingNotices += notice
            current
        }
        handler?.invoke(notice)
    }

    private fun bareToolName(name: String): String =
        if (name.startsWith("mcp__")) name.substringAfterLast("__") else name

    public companion object {
        public const val DEFAULT_TIMEOUT_MILLISECONDS: Long = 300_000
        public const val DEFAULT_DURABLE_EXPIRY_MILLISECONDS: Long = 24 * 60 * 60 * 1_000
    }
}

/** The production scheduler uses one daemon timer thread. */
public object BotRealApprovalScheduler : BotApprovalScheduler {
    private val executor: ScheduledThreadPoolExecutor = ScheduledThreadPoolExecutor(1) { runnable ->
        Thread(runnable, "bot-approval-timeout").apply { isDaemon = true }
    }.apply {
        removeOnCancelPolicy = true
    }

    override fun schedule(delayMilliseconds: Long, action: () -> Unit): BotApprovalCancellation {
        val future = executor.schedule(
            { action() },
            maxOf(0L, delayMilliseconds),
            TimeUnit.MILLISECONDS,
        )
        return BotApprovalCancellation { future.cancel(false) }
    }
}

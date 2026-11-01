// D1-c tests — a fake backend that honours the contract's idempotency and resume rules.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import kotlinx.coroutines.flow.flow

/** One scripted line of a fake event stream. */
internal sealed interface WireLine {
    /** A JSON event line, exactly what a transport would deliver. */
    data class Json(val text: String) : WireLine

    /** A transport loss at this point of the stream. */
    data class Loss(val reason: String) : WireLine
}

/**
 * A fake [AgentHarness].
 *
 * It models the backend-side obligations the interface names but cannot
 * enforce:
 *
 * - `send` executes a command with a `request_id` at most once, no matter how
 *   often the host sends it;
 * - `events` serves durable events strictly after `afterSeq`, drops unknown
 *   kinds through [HarnessJson], and can lose the transport after a given
 *   durable `seq` was delivered.
 *
 * [reportedLastSeq] is deliberately independent of the stream cursor, so a
 * test can prove that `HarnessSession.lastSeq` is not used for resumption.
 */
internal class FakeHarness(
    override val capabilities: HarnessCapabilities = HarnessCapabilities(),
    private val wire: List<WireLine> = emptyList(),
    private val failAfterDeliveredSeq: Long? = null,
    private val reportedLastSeq: Long? = null,
) : AgentHarness {
    private val deliveries = ArrayList<HarnessCommand>()
    private val executedRequestIds = HashSet<String>()
    private val closed = ArrayList<String>()
    private val cursors = ArrayList<Long?>()

    /** Number of times [events] was called (one call == one subscription attempt). */
    var eventsSubscriptions: Int = 0
        private set

    /** The `afterSeq` passed to each [events] call, in call order. */
    fun subscriptionCursors(): List<Long?> = cursors.toList()

    /** The goal [goal] returns; `null` means the backend has no goal. */
    var currentGoal: HarnessGoal? = null

    /** Every command the transport was asked to send, including duplicates. */
    fun deliveredCommands(): List<HarnessCommand> = deliveries.toList()

    /** Whether a command with [requestId] actually executed (0 or 1). */
    fun executionsOf(requestId: String): Int = if (requestId in executedRequestIds) 1 else 0

    fun closedSessions(): List<String> = closed.toList()

    override suspend fun openSession(request: HarnessSessionRequest): HarnessSession =
        HarnessSession(
            id = request.sessionId ?: "sess-new",
            capabilities = capabilities,
            lastSeq = reportedLastSeq,
        )

    override suspend fun send(command: HarnessCommand, sessionId: String) {
        deliveries += command
        val requestId = command.requestId ?: return
        // Backend-side idempotency: the first delivery executes, later ones are
        // acknowledged without running again.
        executedRequestIds += requestId
    }

    override fun events(sessionId: String, afterSeq: Long?): Flow<HarnessEvent> {
        eventsSubscriptions += 1
        cursors += afterSeq
        return flow {
            var failed = false
            for (line in wire) {
                when (line) {
                    is WireLine.Loss -> throw HarnessUnavailable(line.reason)
                    is WireLine.Json -> {
                        val event = HarnessJson.decodeEvent(line.text) ?: continue
                        if (afterSeq != null) {
                            val seq = event.seq
                            if (seq != null && seq <= afterSeq) {
                                continue
                            }
                        }
                        emit(event)
                        val seq = event.seq
                        if (!failed && failAfterDeliveredSeq != null && seq == failAfterDeliveredSeq) {
                            failed = true
                            throw HarnessUnavailable("transport lost after durable seq $seq")
                        }
                    }
                }
            }
        }
    }

    override suspend fun goal(sessionId: String): HarnessGoal? = currentGoal

    override suspend fun closeSession(sessionId: String) {
        closed += sessionId
    }
}

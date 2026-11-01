// Host contract 1 — the harness backend interface.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

/**
 * A harness backend: an embedded runtime, a self-hosted harness server, or a
 * commercial cloud.
 *
 * Commands go in, an ordered event stream comes out, and declared capabilities
 * let the host UI adapt to what the backend can do. Implementations translate
 * transport errors into [HarnessException] / [HarnessUnavailable]; the caller
 * never sees a provider-specific error type.
 *
 * The session id is always carried out of band, never inside a command or an
 * event payload helper.
 */
public interface AgentHarness {
    /**
     * Static capabilities of this backend.
     *
     * A session may narrow this set, never widen it (host README §4).
     */
    public val capabilities: HarnessCapabilities

    /**
     * Opens a new session, or resumes [HarnessSessionRequest.sessionId] when it
     * is present.
     *
     * The returned [HarnessSession.lastSeq] is only what the backend reported;
     * it is **not** a resume cursor. See [HarnessSession].
     *
     * @throws HarnessException with [HarnessErrorCode.CONFLICT] when the session
     *   id is already open with different parameters, or another class when the
     *   backend rejects the request.
     */
    public suspend fun openSession(
        request: HarnessSessionRequest = HarnessSessionRequest(),
    ): HarnessSession

    /**
     * Sends exactly one command to one session.
     *
     * [HarnessCommand.Prompt] and [HarnessCommand.Steer] are idempotent by
     * [HarnessCommand.requestId]; the backend must not run the same request
     * twice. Idempotency is the backend's obligation — this interface does not
     * buffer or rewrite commands.
     *
     * @throws HarnessException with [HarnessErrorCode.UNSUPPORTED] when the
     *   backend does not implement the command, [HarnessErrorCode.INVALID_REQUEST]
     *   when the command is illegal in the current state (for example steering
     *   while no turn runs), or another class for transport failures.
     */
    public suspend fun send(command: HarnessCommand, sessionId: String)

    /**
     * Opens the ordered event stream for [sessionId], starting **strictly
     * after** [afterSeq].
     *
     * `afterSeq == null` means "from the beginning of what the backend
     * retains". [afterSeq] is the highest durable `seq` the caller has actually
     * consumed — never [HarnessSession.lastSeq]. Durable events carry `seq`;
     * best-effort events carry none, are never replayed, and may be lost.
     *
     * **Transport loss.** If the transport drops mid-stream, this flow fails
     * with [HarnessUnavailable] (the `unavailable` class, `retryable = true`).
     * The caller must then re-subscribe with the last durable `seq` it
     * processed:
     *
     * ```
     * var cursor: Long? = null
     * try {
     *     harness.events(sessionId, cursor).collect { event ->
     *         event.seq?.let { cursor = it }
     *         render(event)
     *     }
     * } catch (loss: HarnessUnavailable) {
     *     // re-subscribe with the cursor; redelivery is harmless
     * }
     * ```
     *
     * A backend must drop any event whose `seq` is not above the cursor, so
     * redelivery after a re-subscribe is harmless. `seq` is an ordinal, not a
     * count: gaps are legal, the first durable `seq` may be `0`, and a gap is
     * never evidence of missed events (host README §2.5). The stream completes
     * normally when it delivers [HarnessKindName.EXITED]; it does not complete
     * on transport loss.
     *
     * An event whose `kind` is not one of the fifteen contract kinds is
     * dropped: it is never emitted, the stream keeps running, and its `seq`
     * counts as consumed. Dropping does **not** advance the caller's cursor:
     * the caller still re-subscribes with its own last processed durable `seq`.
     * Only a transport that keeps an internal retained cursor can advance past
     * the dropped line (see [HarnessEventDecode.UnknownKindDropped]).
     *
     * The returned [Flow] is cold and single-subscription in practice: each
     * call opens one stream.
     */
    public fun events(sessionId: String, afterSeq: Long? = null): Flow<HarnessEvent>

    /**
     * The session's current goal projection, or `null` when the backend has no
     * goals for this session (the default).
     */
    public suspend fun goal(sessionId: String): HarnessGoal? = null

    /**
     * Releases client-side resources for [sessionId]; it never deletes the
     * remote session and carries no wire form.
     *
     * The default is a no-op, as in the reference implementation.
     */
    public suspend fun closeSession(sessionId: String) {}
}

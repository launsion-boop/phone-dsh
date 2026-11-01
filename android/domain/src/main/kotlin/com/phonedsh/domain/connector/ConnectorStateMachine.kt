// The one transition table every connector shares.
// SPDX-License-Identifier: MIT
//
// A seam with a state stream and no table lets every implementation invent its own
// idea of which movements exist, and the differences surface as a page that shows
// "reconnecting" forever or a retry policy that never reaches Failed. The table is
// small enough to state once and is therefore stated once: implementations hold a
// ConnectorStateMachine and call advance, tests drive it directly, and neither has
// to re-derive the graph.
//
// This is a helper, not a base class: a `DeviceConnector` implementation may own the
// machine, wrap it or forward to it. Nothing above the SPI needs to call advance,
// and doing so from a UI would be reaching past the connector that owns the link.

package com.phonedsh.domain.connector

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The state of one link, with the legal movements checked.
 *
 * [advance] refuses an illegal movement with [IllegalStateException] and leaves the
 * state as it was: a connector that emits a movement outside the table has a bug,
 * and silently accepting it would hide the bug in the one place a UI trusts.
 *
 * @param initial the state the machine starts in. A production connector starts at
 *   [ConnectorState.Idle]; a test may start elsewhere to exercise one row of the
 *   table without walking to it. Starting elsewhere does not relax the table.
 */
class ConnectorStateMachine(
    initial: ConnectorState = ConnectorState.Idle,
) {
    private val lock = Any()
    private val mutableState = MutableStateFlow(initial)

    /** The current state. Hot, thread-safe, and always has a value. */
    val state: StateFlow<ConnectorState> = mutableState.asStateFlow()

    /**
     * Moves to [next] if the table allows it.
     *
     * @return [next], for a caller that wants to publish the state it just set.
     * @throws IllegalStateException when [next] cannot follow the current state.
     */
    fun advance(next: ConnectorState): ConnectorState = synchronized(lock) {
        val current = mutableState.value
        check(isLegal(current, next)) {
            "illegal connector transition: $current -> $next"
        }
        mutableState.value = next
        next
    }

    companion object {
        /**
         * Whether [to] may follow [from].
         *
         * The rows, and why each exists:
         *
         *  * Idle -> Idle: `disconnect` on a connector that never connected.
         *  * Idle -> Connecting: the first attempt.
         *  * Connecting -> Connected: the attempt succeeded.
         *  * Connecting -> Failed: the attempt failed for good.
         *  * Connecting -> Reconnecting: an adapter that retries its first attempt
         *    has no other state to use, and inventing a second "trying" state for
         *    it would split every page's rendering in two.
         *  * Connecting -> Idle: the caller cancelled while the attempt was in
         *    flight and disconnected; the attempt's own completion then fails loudly
         *    instead of resurrecting a link nobody wants.
         *  * Connected -> Connected: the same live link re-read its manifest, for
         *    example after the device announced new capabilities.
         *  * Connected -> Reconnecting: the live link died and a retry is running.
         *  * Connected -> Failed: the live link died and the adapter will not retry,
         *    or the peer refused the session on the open link.
         *  * Connected -> Idle: `disconnect`.
         *  * Reconnecting -> Reconnecting: the next retry, [ConnectorState.Reconnecting.attempt]
         *    goes up by one.
         *  * Reconnecting -> Connected: the retry recovered the link.
         *  * Reconnecting -> Failed: the retries ran out, or the peer refused.
         *  * Reconnecting -> Idle: the caller gave up and disconnected.
         *  * Reconnecting -> Connecting: the caller re-dials through `connect` rather
         *    than waiting for the retry loop.
         *  * Failed -> Connecting: an explicit retry.
         *  * Failed -> Idle: the caller reset the connector.
         *
         * Everything else is refused. The refusals that matter: a connected link may
         * not go straight back to Connecting (disconnect first, so there is never a
         * moment with two open links), an attempt may not start from Failed without a
         * new connect, and Connecting may not follow Connecting (one attempt at a
         * time).
         */
        fun isLegal(from: ConnectorState, to: ConnectorState): Boolean = when (from) {
            is ConnectorState.Idle ->
                to is ConnectorState.Idle || to is ConnectorState.Connecting

            is ConnectorState.Connecting ->
                to is ConnectorState.Connected || to is ConnectorState.Failed ||
                    to is ConnectorState.Reconnecting || to is ConnectorState.Idle

            is ConnectorState.Connected ->
                to is ConnectorState.Connected || to is ConnectorState.Reconnecting ||
                    to is ConnectorState.Failed || to is ConnectorState.Idle

            is ConnectorState.Reconnecting ->
                to is ConnectorState.Reconnecting || to is ConnectorState.Connected ||
                    to is ConnectorState.Failed || to is ConnectorState.Idle ||
                    to is ConnectorState.Connecting

            is ConnectorState.Failed ->
                to is ConnectorState.Connecting || to is ConnectorState.Idle
        }
    }
}

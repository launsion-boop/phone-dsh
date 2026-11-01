// The connector seam: one link to one remote device host.
// SPDX-License-Identifier: MIT
//
// This interface exists because the link does not: the normative tree fixes what a
// device sends (envelope, manifest, receipt) and deliberately leaves the transport,
// discovery and pairing life cycle to a protocol that is not frozen yet. A port
// that waited for that protocol would have nothing to test, and a port that
// invented one would have to be undone. So this seam fixes only the shape the host
// above it needs — connect, hold a state, disconnect — and the first real adapter
// fills it in without changing a single caller.
//
// Two rules make the seam usable before any adapter exists:
//
//  * The state stream is the truth, not a return value. Every call changes it, and
//    a consumer that missed a return value still sees where the link is.
//  * A failed attempt is a state, never an absence. `connect` throws, and the state
//    it leaves behind is Failed; it never returns to Idle, because "never tried" and
//    "tried and failed" are different answers for a page and for a retry policy.

package com.phonedsh.domain.connector

import kotlinx.coroutines.flow.StateFlow

/**
 * One link to one remote device host.
 *
 * Implementations serialise their own operations: one `connect`, `disconnect` or
 * reconnect step at a time, from any thread. [state] is the only truth and always
 * has a value (initially [ConnectorState.Idle]).
 *
 * The contract:
 *
 *  1. `connect` is legal from [ConnectorState.Idle], [ConnectorState.Failed] and
 *     [ConnectorState.Reconnecting]. From [ConnectorState.Connected] or
 *     [ConnectorState.Connecting] it throws [IllegalStateException] without
 *     touching the link, so a caller never silently drops a working connection.
 *  2. On success `connect` returns the device that [ConnectorState.Connected]
 *     carries, with its manifest already decoded.
 *  3. On failure `connect` throws [ConnectorException] and the state is
 *     [ConnectorState.Failed] — never [ConnectorState.Idle].
 *  4. `disconnect` is idempotent and ends in [ConnectorState.Idle]. It is a
 *     suspending call because the state may only become Idle once the transport is
 *     closed: a fire-and-forget close would let the next `connect` race the old
 *     socket, which is the classic way a reconnect ends up with two links.
 */
interface DeviceConnector {
    /** The link's life cycle. Hot, and always has a value. */
    val state: StateFlow<ConnectorState>

    /**
     * Establishes the link and reads the device's capability manifest.
     *
     * @param endpoint where to dial; its syntax belongs to the endpoint's protocol.
     * @return the live device, carrying the decoded manifest.
     * @throws ConnectorException when the attempt failed; the state is then
     *   [ConnectorState.Failed] (or [ConnectorState.Reconnecting], for an adapter
     *   that retries by itself).
     * @throws IllegalStateException when the connector is already connected or
     *   already connecting.
     */
    suspend fun connect(endpoint: Endpoint): ConnectedDevice

    /**
     * Closes the link, if any, and leaves the connector in [ConnectorState.Idle].
     *
     * Repeating it is harmless. A connector that has never connected may be
     * disconnected too: the call is "make sure there is no link", not "close the
     * link you have".
     */
    suspend fun disconnect()
}

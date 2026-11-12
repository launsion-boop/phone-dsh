// SPDX-License-Identifier: MIT
// Transport seams shared by the C2/C3/C4 checkpoints (design §6, "C2 defines
// one seam and consumes another"). No implementation lives here: C3 provides the
// Ktor WebSocket `PclinkRelayLinkFactory`, C2's tests use an in-memory fake, and
// C4 consumes the decrypted inner frames.
package com.phonedsh.pclink

import kotlinx.coroutines.flow.Flow

/**
 * One authenticated relay connection. Sealing assigns `seq` and one writer
 * enqueues in that order (§3.8/§5.4), so [send] must be called by that writer
 * only; [incoming] completes when the socket closes.
 */
interface PclinkRelayLink {
    suspend fun send(frame: PclinkJson)
    val incoming: Flow<PclinkJson>
    suspend fun close(code: Int, reason: String)
}

/** Dials `wss`/`ws` and returns an authenticated [PclinkRelayLink]. */
interface PclinkRelayLinkFactory {
    suspend fun connect(url: String): PclinkRelayLink
}

// ---- Relay events (C3 additions; the C1 link seam above is unchanged) -------
//
// [PclinkRelayLink.incoming] carries `relay.offline` and `relay.error` frames
// unchanged as well, so a consumer that only knows the three-method link still
// sees every relay-plane frame it must interpret. It completes normally on a
// clean close (1000) and completes exceptionally with the terminal
// [PclinkError] otherwise (e.g. `replaced`/4001, `auth_failed`/4002,
// `bad_frame`/1008, `frame_too_large`/1009). The structured events below are
// the richer view used by the Android client and its tests; collect exactly one
// of `events` and `incoming`.

/** A `relay.offline` frame with its optional correlation fields (§3.3, §10). */
data class PclinkRelayOffline(
    val to: String,
    val id: String?,
    val streamId: String?,
    val sid: String?,
    val frame: PclinkJson,
)

/**
 * The correlation members a `relay.error` may echo (§3.7). A `rate_limited`
 * error carries no peer correlation in v1; the upper layer must then invalidate
 * every established session on the connection (§3.8).
 */
data class PclinkRelayErrorContext(
    val id: String? = null,
    val streamId: String? = null,
    val sid: String? = null,
    val retryAfterMs: Int? = null,
)

/** One event from an authenticated relay connection. */
sealed interface PclinkRelayEvent {
    /** `relay.ready` accepted; [PclinkRelayClient.connect] returns after this. */
    data class Ready(val machineId: String, val role: String) : PclinkRelayEvent

    /** An `e2e`, `e2e.handshake` or pairing frame to hand to the upper layer. */
    data class Frame(val frame: PclinkJson) : PclinkRelayEvent

    /** The relay says the target is not connected; never queued (§3.3). */
    data class Offline(val offline: PclinkRelayOffline) : PclinkRelayEvent

    /** A mapped `relay.error`; [frame] is the exact received frame. */
    data class Error(
        val error: PclinkError,
        val context: PclinkRelayErrorContext,
        val frame: PclinkJson,
    ) : PclinkRelayEvent

    /** The connection ended. [error] is null for a clean close. */
    data class Closed(val code: Int?, val reason: String?, val error: PclinkError?) : PclinkRelayEvent
}

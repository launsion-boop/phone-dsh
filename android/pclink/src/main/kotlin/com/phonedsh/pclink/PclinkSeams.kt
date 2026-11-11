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

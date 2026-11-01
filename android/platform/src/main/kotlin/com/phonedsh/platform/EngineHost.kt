// The engine seam, so :dsh never links :engine.
// SPDX-License-Identifier: MIT
//
// plan §5.1 / §6: the WebView host is platform-specific, but the facade only
// needs its lifecycle state, channel counters and HELLO summary. Lifting those
// five members here lets :dsh depend on :platform while :engine implements the
// interface. The value types below mirror PhoneDSHEngine's DemoEngine exactly,
// so :engine can adopt them with typealiases instead of a translation layer.

package com.phonedsh.platform

import kotlinx.coroutines.flow.StateFlow

/**
 * The one WebView host as the rest of the host sees it.
 *
 * [start] and [stop] may be called from any thread, are safe to repeat and are
 * asynchronous: [state] is the only lifecycle truth. The interface never
 * exposes a WebView, a page URL or a token.
 */
interface EngineHost {
    /** Hot lifecycle state; always has a value (initially [EngineHostState.Stopped]). */
    val state: StateFlow<EngineHostState>

    /** The one channel as the engine sees it; counters reset on every `start()`. */
    val channel: StateFlow<EngineChannelStatus>

    /** The merged HELLO summary; `null` before the first HELLO and after `stop()`. */
    val handshake: StateFlow<EngineHandshake?>

    /** Starts the origin, the page and the channel; ignored while already running. */
    fun start()

    /** Closes the channel and the origin and destroys the page; idempotent. */
    fun stop()
}

/**
 * Lifecycle of the one WebView host (plan §6.2-1, §6.3).
 *
 * `Stopped -> Starting -> Running` is the happy path. `Running -> Recovering ->
 * Running` is the renderer-death path, which D14 maps to its existing
 * `Recovering` state; `Failed` is terminal until [EngineHost.start] is called
 * again.
 */
sealed interface EngineHostState {
    /** No page, no origin, no channel. Also the state after `stop()`. */
    data object Stopped : EngineHostState

    /** The worker bundle is being materialized and the loopback origin is coming up. */
    data object Starting : EngineHostState

    /** The origin serves the page and the one channel; [origin] never carries the token. */
    data class Running(val origin: String, val port: Int) : EngineHostState

    /** The renderer died; the page is rebuilt and reloaded while origin and port survive. */
    data object Recovering : EngineHostState

    /** The engine gave up. [reason] is safe to show and to log, never a token. */
    data class Failed(val reason: String) : EngineHostState
}

/** What the page and the host have actually exchanged, for the demo UI and telemetry. */
data class EngineChannelStatus(
    val connected: Boolean = false,
    val framesFromWorker: Long = 0,
    val framesToWorker: Long = 0,
    /** `"HELLO"` / `"VFS_ACK"` / ...; `null` before the first frame. */
    val lastFrameType: String? = null,
    /** Safe to show: a short reason, never a token and never a full URL. */
    val lastError: String? = null,
)

/** One merged HELLO handshake, decoded by the single Wire codec. */
data class EngineHandshake(
    val proto: Int,
    val workerCapabilities: List<String>,
    val hostCapabilities: List<String>,
    val nextMseq: Long,
    val ackedMseq: Long,
    val receivedAtMillis: Long,
)

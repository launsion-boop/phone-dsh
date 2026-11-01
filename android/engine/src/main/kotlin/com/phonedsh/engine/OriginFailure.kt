// phone-dsh — :engine / com.phonedsh.engine: the loopback origin's failure text.
// SPDX-License-Identifier: MIT
//
// :net never throws an engine death into an unobserved scope: it records the
// cause in LoopbackServer.lastFailure() and counts it in
// LoopbackMetrics.engineFailures. :engine is the layer that turns that into a
// lifecycle fact, and this object is the only place that formats it, so a token
// or a full URL cannot reach EngineHostState.Failed / channel.lastError.

package com.phonedsh.engine

import com.phonedsh.loopback.LoopbackStartException

/** Formats loopback failures as short, token-free reasons that are safe to show. */
object OriginFailure {
    /** Prefix shared by every reason this object derives from the origin. */
    const val PREFIX: String = "loopback origin failed: "

    /**
     * Why `LoopbackServer.start()` failed.
     *
     * A [LoopbackStartException] itself only names host and port; its cause is
     * the real failure (bind refused, missing `INTERNET` permission, a probe
     * timeout), and [recorded] is the origin's own `lastFailure()` for the case
     * where the wrap lost it. A start failure that is not the origin's (bundle
     * materialization, WebView construction) keeps its own type and message, with
     * URLs scrubbed but without the origin prefix.
     */
    fun startReason(failure: Throwable, recorded: Throwable? = null): String {
        if (failure !is LoopbackStartException) return safeReasonOf(failure)
        return PREFIX + safeReasonOf(failure.cause ?: recorded ?: failure)
    }

    /**
     * Why a running origin died, as :net recorded it.
     *
     * [engineFailures] is `LoopbackMetrics.engineFailures`; it is appended only
     * when :net counted one, so a healthy origin never reads as a failure.
     */
    fun runtimeReason(failure: Throwable, engineFailures: Long): String {
        val counted = if (engineFailures > 0L) " (engineFailures=$engineFailures)" else ""
        return PREFIX + safeReasonOf(failure) + counted
    }

    /**
     * [EngineLogText.reasonOf] with every `http(s)://…` run reduced to `<url>`.
     *
     * `reasonOf` already drops the query string (where the launch token lives)
     * and truncates; the extra scrub keeps even the base URL out of a reason that
     * a screen may show verbatim.
     */
    fun safeReasonOf(failure: Throwable): String =
        EngineLogText.reasonOf(failure).replace(URL_PATTERN, URL_PLACEHOLDER)

    private val URL_PATTERN = Regex("""https?://\S+""")
    private const val URL_PLACEHOLDER = "<url>"
}

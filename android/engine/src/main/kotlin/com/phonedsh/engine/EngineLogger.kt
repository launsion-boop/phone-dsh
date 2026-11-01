// phone-dsh — :engine / com.phonedsh.engine: one log seam, token-safe by construction.
// SPDX-License-Identifier: MIT
//
// :engine deliberately does not depend on :core/log: it moves bytes and emits
// lines the host routes wherever it likes (logcat, UI, a test buffer). Every line
// built in this module is built through [EngineLogText], which drops the query
// string of a URL and never formats a [com.phonedsh.loopback.LoopbackEndpoint]
// (whose toString() already redacts the token).

package com.phonedsh.engine

import com.phonedsh.loopback.LoopbackEndpoint
import com.phonedsh.platform.EngineHostState

/** The only logging seam of :engine. No timestamps, no thread names, no tokens. */
fun interface EngineLogger {
    fun log(level: EngineLogLevel, message: String)
}

enum class EngineLogLevel { DEBUG, INFO, WARN, ERROR }

fun EngineLogger.debug(message: String) = log(EngineLogLevel.DEBUG, message)

fun EngineLogger.info(message: String) = log(EngineLogLevel.INFO, message)

fun EngineLogger.warn(message: String) = log(EngineLogLevel.WARN, message)

fun EngineLogger.error(message: String) = log(EngineLogLevel.ERROR, message)

/** String shapes the engine is allowed to log. Everything here is token-free. */
object EngineLogText {
    /** `scheme://host:port/path` of [url], with the query and the fragment removed. */
    fun baseUrl(url: String): String {
        val cut = url.indexOfFirst { it == '?' || it == '#' }
        return if (cut < 0) url else url.substring(0, cut)
    }

    /**
     * [text] with the query and the fragment of every URL in it removed.
     *
     * A page can log its own `location.href`, and the console callback would then
     * write the launch URL — whose `env` query carries the whole worker
     * environment (the model key placeholder and the per-start launch token) — to
     * logcat. Every URL span keeps only its [baseUrl] form, and [baseUrl] stays
     * the one implementation of the cut, so this path and the engine's own URL
     * lines cannot drift apart. Text that is not a URL, including an honest `?`
     * in prose, passes through unchanged.
     */
    fun console(text: String): String = URL_IN_TEXT.replace(text) { baseUrl(it.value) }

    /** The [endpoint] origin, which by construction carries no token. */
    fun origin(endpoint: LoopbackEndpoint): String = endpoint.origin

    /** `Stopped`, `Starting`, `Running(origin=..., port=...)`, `Recovering`, `Failed(...)`. */
    fun describe(state: EngineState): String = when (state) {
        EngineHostState.Stopped -> "Stopped"
        EngineHostState.Starting -> "Starting"
        EngineHostState.Recovering -> "Recovering"
        is EngineHostState.Running -> "Running(origin=${state.origin}, port=${state.port})"
        is EngineHostState.Failed -> "Failed(${state.reason})"
    }

    /**
     * A short, URL-safe reason for [failure].
     *
     * `Throwable.message` can embed a URL; only its base form survives and the
     * whole reason is truncated so one bad line cannot fill logcat.
     */
    fun reasonOf(failure: Throwable): String {
        val type = failure::class.java.simpleName.ifEmpty { "Throwable" }
        val message = failure.message?.takeIf { it.isNotBlank() }?.let { baseUrl(it) } ?: "no message"
        return "$type: ${message.take(MAX_REASON_CHARS)}"
    }

    /**
     * A URL span inside page text: a scheme, `://`, then everything up to
     * whitespace, a quote or an angle bracket. A page's own text is untrusted; the
     * pattern is deliberately narrow so ordinary prose is never rewritten.
     */
    private val URL_IN_TEXT = Regex("""[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+""")

    private const val MAX_REASON_CHARS = 180
}

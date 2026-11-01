// Host contract 1 — the eight error classes and their retry split.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

/**
 * The eight error classes a harness operation or event stream reports.
 *
 * `retryable` is derived from the code, never carried on the wire:
 * [UNAVAILABLE] and [RATE_LIMITED] are retryable; every other class is not
 * (`spec/host/v1/schema/harness-error.schema.json`).
 */
public enum class HarnessErrorCode(
    public val wire: String,
    public val retryable: Boolean,
) {
    /** The backend does not implement this operation. */
    UNSUPPORTED("unsupported", false),

    /** Credentials are missing, expired or rejected. */
    UNAUTHORIZED("unauthorized", false),

    /** The service is temporarily unreachable; retry after the hint if given. */
    UNAVAILABLE("unavailable", true),

    /** The service throttled the caller. */
    RATE_LIMITED("rate_limited", true),

    /** The request is invalid and must not be retried unchanged. */
    INVALID_REQUEST("invalid_request", false),

    /** The backend answered with something the host could not interpret. */
    INVALID_RESPONSE("invalid_response", false),

    /** The operation was cancelled by the caller or the user. */
    CANCELLED("cancelled", false),

    /** A conflict with existing state, for example a reused idempotency key with a different payload. */
    CONFLICT("conflict", false),
    ;

    public companion object {
        public fun fromWire(wire: String): HarnessErrorCode? = entries.firstOrNull { it.wire == wire }
    }
}

/** The wire value of a harness error. */
public data class HarnessError(
    public val code: HarnessErrorCode,
    public val message: String? = null,
    /** Hint in milliseconds (`retry_after_ms`); only meaningful for retryable codes. */
    public val retryAfterMs: Long? = null,
) {
    /** Whether the same request may be retried later. Derived, never a wire member. */
    public val retryable: Boolean get() = code.retryable
}

/**
 * A harness operation failure carrying a [HarnessError].
 *
 * Backends translate their transport errors into these classes so the caller
 * can apply one retry policy.
 */
public open class HarnessException(
    public val error: HarnessError,
    cause: Throwable? = null,
) : Exception(error.message ?: error.code.wire, cause) {
    public val code: HarnessErrorCode get() = error.code
    public val retryable: Boolean get() = error.retryable
    public val retryAfterMs: Long? get() = error.retryAfterMs
}

/**
 * A transport loss ended an event stream.
 *
 * This is the Kotlin equivalent of `ProviderError.unavailable`: code
 * [HarnessErrorCode.UNAVAILABLE], retryable. The caller re-subscribes with
 * [AgentHarness.events] `(sessionId, afterSeq = last durable seq actually
 * processed)`; see [AgentHarness.events].
 */
public class HarnessUnavailable(
    message: String? = null,
    retryAfterMs: Long? = null,
    cause: Throwable? = null,
) : HarnessException(
    HarnessError(code = HarnessErrorCode.UNAVAILABLE, message = message, retryAfterMs = retryAfterMs),
    cause,
)

/** A wire value could not be decoded; reported as [HarnessErrorCode.INVALID_RESPONSE]. */
public class HarnessDecodingException(
    /** JSON-path-like location of the offending member, for example `event.request.request_id`. */
    public val path: String,
    detail: String,
    cause: Throwable? = null,
) : HarnessException(
    HarnessError(code = HarnessErrorCode.INVALID_RESPONSE, message = "$path: $detail"),
    cause,
)

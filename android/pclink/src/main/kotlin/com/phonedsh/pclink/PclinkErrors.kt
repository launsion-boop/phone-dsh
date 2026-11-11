// SPDX-License-Identifier: MIT
// PCLink v1 error vocabulary (§9.1) and the DSH-facing projection seam (§9.2).
//
// This is deliberately not a DSH/ProviderError type: the direct-loopback
// 401/cookie/`Host`/`Origin` semantics do not exist on the relay path, and
// mapping a pairing state to a credential refresh would make a caller re-exchange
// a token that does not exist. C4's transport adapter implements the seam.
package com.phonedsh.pclink

/**
 * A PCLink-namespace error. [code] is the on-wire / §9.1 vocabulary value;
 * some subtypes are local outcomes (`unknownOutcome`) or client names for an
 * observed relay frame (`peerOffline`) rather than values a peer sends.
 */
sealed class PclinkError(message: String) : Exception(message) {
    abstract val code: String

    /** Whether §7 lets the caller retry the same logical operation. */
    open val isRetryable: Boolean get() = false

    class Unavailable(message: String) : PclinkError(message) {
        override val code: String get() = "unavailable"
        override val isRetryable: Boolean get() = true
    }

    /** Local phone-transport outcome: an unsafe call may have executed. Never retried. */
    class UnknownOutcome(endpoint: String) : PclinkError(
        "may have executed but no definitive reply arrived for $endpoint",
    ) {
        override val code: String get() = "unknown_outcome"
    }

    class PeerOffline : PclinkError("the paired PC is offline") {
        override val code: String get() = "peer_offline"
        override val isRetryable: Boolean get() = true
    }

    class Unpaired(message: String) : PclinkError(message) {
        override val code: String get() = "unpaired"
    }

    class AuthFailed(message: String) : PclinkError(message) {
        override val code: String get() = "auth_failed"
    }

    class BadFrame(message: String) : PclinkError(message) {
        override val code: String get() = "bad_frame"
    }

    class FrameTooLarge(message: String) : PclinkError(message) {
        override val code: String get() = "frame_too_large"
    }

    class RateLimited(val retryAfterMs: Int? = null) : PclinkError(
        if (retryAfterMs != null) "rate limited; retry after $retryAfterMs ms" else "rate limited",
    ) {
        override val code: String get() = "rate_limited"
        override val isRetryable: Boolean get() = true
    }

    class VersionUnsupported(message: String) : PclinkError(message) {
        override val code: String get() = "version_unsupported"
    }

    class SessionExpired(message: String) : PclinkError(message) {
        override val code: String get() = "session_expired"
        override val isRetryable: Boolean get() = true
    }

    class Replay(message: String) : PclinkError(message) {
        override val code: String get() = "replay"
    }

    class Forbidden(message: String) : PclinkError(message) {
        override val code: String get() = "forbidden"
    }

    class RendezvousExpired : PclinkError("the pairing code expired") {
        override val code: String get() = "rendezvous_expired"
    }

    class RendezvousExhausted : PclinkError("the pairing code was already used or exhausted") {
        override val code: String get() = "rendezvous_exhausted"
    }

    class Replaced : PclinkError("a newer connection replaced this one") {
        override val code: String get() = "replaced"
        override val isRetryable: Boolean get() = true
    }

    class Storage(message: String) : PclinkError(message) {
        override val code: String get() = "storage"
    }

    class NoIdentity : PclinkError("the phone identity key is missing") {
        override val code: String get() = "no_identity"
    }

    class NotPaired : PclinkError("no paired computer") {
        override val code: String get() = "not_paired"
    }

    class AlreadyPaired : PclinkError("a computer is already paired; unpair it first") {
        override val code: String get() = "already_paired"
    }

    class Cancelled : PclinkError("the operation was cancelled") {
        override val code: String get() = "cancelled"
    }

    class PairingCancelled : PclinkError("the pairing was cancelled") {
        override val code: String get() = "cancelled"
    }

    class PairingRejected : PclinkError("the computer rejected the pairing") {
        override val code: String get() = "rejected"
    }

    class PairingTimedOut : PclinkError("the pairing timed out") {
        override val code: String get() = "timeout"
    }

    class Unsupported(message: String) : PclinkError(message) {
        override val code: String get() = "unavailable"
    }

    companion object {
        /** Every §9.1 code, including the client-only outcomes and `rekey`. */
        val knownCodes: Set<String> = setOf(
            "unavailable", "unknown_outcome", "peer_offline", "unpaired",
            "auth_failed", "replaced", "session_expired", "replay", "bad_frame",
            "frame_too_large", "rate_limited", "version_unsupported",
            "rendezvous_expired", "rendezvous_exhausted", "rekey", "forbidden",
        )

        /**
         * An on-wire code from `relay.error`/`session.close`/`session.reject`.
         * An unknown code is [BadFrame] (§9.1: one mapping for an unknown PCLink
         * code, never a new meaning).
         */
        fun fromCode(code: String, message: String = ""): PclinkError = when (code) {
            "unavailable" -> Unavailable(message)
            "unpaired" -> Unpaired(message)
            "auth_failed" -> AuthFailed(message)
            "replaced" -> Replaced()
            "session_expired" -> SessionExpired(message)
            "replay" -> Replay(message)
            "bad_frame" -> BadFrame(message)
            "frame_too_large" -> FrameTooLarge(message)
            "rate_limited" -> RateLimited()
            "version_unsupported" -> VersionUnsupported(message)
            "rendezvous_expired" -> RendezvousExpired()
            "rendezvous_exhausted" -> RendezvousExhausted()
            "forbidden" -> Forbidden(message)
            "peer_offline" -> PeerOffline()
            "unknown_outcome" -> Unavailable(message)
            else -> BadFrame("unknown PCLink code $code")
        }
    }
}

/**
 * A DSH endpoint error carried inside `rpc.result.error` / `rpc.stream.error.error`.
 * It is a different namespace from [PclinkError] and is passed through unchanged;
 * the only PCLink code allowed in it is `forbidden` (§9.1).
 */
class PclinkRpcError(
    val code: String,
    override val message: String,
    val details: PclinkJson? = null,
) : Exception("[$code] $message")

/**
 * The DSH-facing projection of a PCLink outcome (§9.2). `:pclink` owns the
 * vocabulary and C4's `PclinkDshTransport` supplies the implementation; it must
 * never turn `unpaired`/`auth_failed` into a credential refresh and must keep an
 * unknown DSH code displayable as `unavailable` with its original message.
 */
fun interface PclinkErrorProjection {
    fun project(error: PclinkError): PclinkRpcError
}

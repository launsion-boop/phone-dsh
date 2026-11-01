// Why a connection did not happen, in the three classes a host can act on.
// SPDX-License-Identifier: MIT
//
// The three classes are not invented protocol codes: each one is a refusal class
// that the in-tree documents already separate, and the host's reaction differs
// for each.
//
//  * [ConnectorFailure.Unreachable] — nothing answered. Retry is cheap and
//    meaningless to show a user: the address was wrong, the peer is off, or
//    discovery handed back a stale candidate.
//  * [ConnectorFailure.Rejected] — the peer answered and refused. Retrying the
//    same way cannot help; the reason decides what the user must do (pair it,
//    upgrade it, or look at its capability document).
//  * [ConnectorFailure.TransportLost] — a live link died. This is the only class
//    that a reconnect loop exists for.
//
// A single "connection failed" string would erase that split, and the UI would
// have to match on text to decide whether to offer "retry" or "pair". The stable
// codes below are what a log, a retry policy or a quarantine rule matches on; an
// existing code is never renamed or reused, and new members are appended.

package com.phonedsh.domain.connector

/**
 * Why a connector is not (or is no longer) connected.
 *
 * Every member is safe to show and to log: a detail is bounded to
 * [MAX_DETAIL_LENGTH] characters and carries no credential, because an
 * [Endpoint] is not allowed to carry one in the first place.
 */
sealed interface ConnectorFailure {
    /** The stable identifier a caller matches on; never reused for another meaning. */
    val code: String

    /** One bounded, single-line explanation. */
    val detail: String

    /**
     * Nothing answered at [endpoint]: the link was never established.
     *
     * @property endpoint the address that did not answer.
     */
    data class Unreachable(val endpoint: Endpoint) : ConnectorFailure {
        override val code: String
            get() = CODE

        /**
         * Names the protocol but not the address, so a diagnostic line stays one
         * line even when an adapter's address text is long. The address itself is
         * still reachable through [endpoint] for a caller that wants to show it.
         */
        override val detail: String
            get() = "no answer from the ${endpoint.protocolId} endpoint"

        companion object {
            /** The stable code of every [Unreachable]. */
            const val CODE: String = "CONNECTOR_UNREACHABLE"
        }
    }

    /**
     * The peer answered and refused the connection.
     *
     * @property reason which refusal, from the closed set below.
     * @property detail the bounded, single-line explanation the adapter reports.
     */
    data class Rejected(
        val reason: RejectionReason,
        override val detail: String,
    ) : ConnectorFailure {
        init {
            requireDetail(detail)
        }

        override val code: String
            get() = "CONNECTOR_REJECTED_${reason.name}"
    }

    /**
     * A live link died after it had been established.
     *
     * @property detail the bounded, single-line cause the adapter reports.
     */
    data class TransportLost(override val detail: String) : ConnectorFailure {
        init {
            requireDetail(detail)
        }

        override val code: String
            get() = CODE

        companion object {
            /** The stable code of every [TransportLost]. */
            const val CODE: String = "CONNECTOR_TRANSPORT_LOST"
        }
    }

    companion object {
        /** The longest detail this seam carries; a longer explanation is truncated by its author. */
        const val MAX_DETAIL_LENGTH: Int = 256

        /** Refuses a detail that is empty, too long, or spans lines. */
        internal fun requireDetail(detail: String) {
            require(detail.isNotEmpty() && detail.length <= MAX_DETAIL_LENGTH) {
                "a connector failure detail must be 1..$MAX_DETAIL_LENGTH characters, " +
                    "was ${detail.length}"
            }
            require(detail.none { it.isISOControl() }) {
                "a connector failure detail must be a single line without control characters"
            }
        }
    }
}

/**
 * The refusal classes of [ConnectorFailure.Rejected].
 *
 * Each one is a refusal the in-tree contract already names, so this enum maps
 * documented refusals into the seam's vocabulary instead of inventing a taxonomy:
 * an unpaired device is refused (device-adapter-contract §2, §6), a major version
 * mismatch is refused with a reason (device-adapter-contract §7), and a capability
 * document this host cannot decode is refused by [com.phonedsh.domain.device.DeviceManifest.parse].
 */
enum class RejectionReason {
    /** The device is not paired, or its pairing was revoked (device-adapter-contract §6). */
    NOT_PAIRED,

    /** The peer's major protocol version differs (device-adapter-contract §7). */
    PROTOCOL_MISMATCH,

    /** The peer's capability document is not one this host accepts. */
    INVALID_MANIFEST,
}

/**
 * The one exception a [DeviceConnector] throws.
 *
 * It is thrown by `connect` and by a reconnect attempt, and the connector's
 * state is [ConnectorState.Failed] (or still [ConnectorState.Reconnecting]) when
 * it is. A connector never reports a failure by returning `null` and never
 * leaves the state at [ConnectorState.Idle]: "no link yet" and "the link was
 * tried and failed" are different answers, and only the second one is a reason a
 * page may show.
 *
 * @property failure why the connection is not there.
 */
class ConnectorException(
    val failure: ConnectorFailure,
    cause: Throwable? = null,
) : Exception("${failure.code}: ${failure.detail}", cause)

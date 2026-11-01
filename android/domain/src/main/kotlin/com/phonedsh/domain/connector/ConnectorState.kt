// The connector's five states, and their total projection onto the UI's four.
// SPDX-License-Identifier: MIT
//
// The spec does not define a connection life cycle for a remote device host.
// spec/host/v1 fixes what a device *is* on the wire — envelope, capability
// manifest, receipt — and its README §1 keeps a device protocol's own wire format
// (discovery, pairing, framing) outside the normative tree until that protocol
// freezes. So the states below are not transcribed from a rule; they are the
// smallest set a host needs to tell the truth about one link, and they are fixed
// here because whoever writes the first adapter must not invent a different set.
//
// Why five states and not three. "Not connected" hides two different facts: a
// link that was never attempted, and a link that was attempted and failed. A page
// that renders both as "disconnected" cannot tell a user whether to wait or to
// act, and a retry policy cannot tell whether it has anything to retry.
//
// Why every state carries a four-state projection. The page layer's catalogs
// (runtime details, export, egress, background) each have exactly four states —
// ready, empty, failed, unknown — and no page may invent a fifth. [ConnectorStatus]
// is the same four words, so a page maps one enum constant to one enum constant
// and never parses a message to decide what to show.

package com.phonedsh.domain.connector

import com.phonedsh.domain.device.DeviceManifest

/**
 * The state of the one link a [DeviceConnector] owns.
 *
 * The legal transitions are the [ConnectorStateMachine]'s table; the short version
 * is `Idle -> Connecting -> Connected`, `Connected -> Reconnecting -> Connected`
 * for a loss that a retry recovers, and any state `-> Failed` for one it does not.
 */
sealed interface ConnectorState {
    /**
     * How a page shows this state, from the four-state catalog.
     *
     * Total by design: there is no state without an answer, so no page needs a
     * fallback branch of its own.
     */
    val status: ConnectorStatus

    /**
     * No link and no attempt: the connector was created, or the last link was
     * closed on purpose.
     *
     * Status is [ConnectorStatus.UNKNOWN], not [ConnectorStatus.EMPTY]: nothing
     * was reported about the device, so a page says 未知 rather than "no
     * capabilities".
     */
    data object Idle : ConnectorState {
        override val status: ConnectorStatus
            get() = ConnectorStatus.UNKNOWN
    }

    /**
     * A link is being established: discovery answered, the pair is being
     * authenticated, the capability document is still in flight.
     *
     * Status is [ConnectorStatus.UNKNOWN] for the same reason as [Idle] — there is
     * no answer yet. It is a separate state because a page may show progress and
     * because a second `connect` must be refused while it is true.
     */
    data object Connecting : ConnectorState {
        override val status: ConnectorStatus
            get() = ConnectorStatus.UNKNOWN
    }

    /**
     * The link is up and [device] carries the decoded manifest.
     *
     * Status is [ConnectorStatus.READY] when the device declared at least one
     * capability, and [ConnectorStatus.EMPTY] when it declared none: a connected
     * device that declares nothing is a report with no fact in it, which is what
     * `empty` means in every other page catalog. It is not `unknown` — the host
     * asked and got an answer.
     *
     * @property device the endpoint and its decoded manifest.
     */
    data class Connected(val device: ConnectedDevice) : ConnectorState {
        /** The decoded manifest, reachable without going through [device]. */
        val manifest: DeviceManifest
            get() = device.manifest

        override val status: ConnectorStatus
            get() = if (device.manifest.capabilities.isEmpty()) {
                ConnectorStatus.EMPTY
            } else {
                ConnectorStatus.READY
            }
    }

    /**
     * A link that had been established was lost, and a retry is in progress.
     *
     * Status is [ConnectorStatus.FAILED] rather than [ConnectorStatus.UNKNOWN]: a
     * specific failure is known, and showing it as unknown would hide the one fact
     * the page has. [attempt] is what separates this from [Failed] on screen.
     *
     * @property attempt the ordinal of the retry that is running, starting at 1.
     * @property lastFailure why the previous attempt ended.
     */
    data class Reconnecting(
        val attempt: Int,
        val lastFailure: ConnectorFailure,
    ) : ConnectorState {
        init {
            require(attempt >= 1) { "a reconnect attempt starts at 1, was $attempt" }
        }

        override val status: ConnectorStatus
            get() = ConnectorStatus.FAILED
    }

    /**
     * The connector gave up. Terminal until the next explicit `connect`.
     *
     * Status is [ConnectorStatus.FAILED]. This state is never [Idle]: a failed
     * attempt is remembered so a page can say why, and so a retry policy can tell
     * that there is something to retry.
     *
     * @property failure why the last attempt ended.
     */
    data class Failed(val failure: ConnectorFailure) : ConnectorState {
        override val status: ConnectorStatus
            get() = ConnectorStatus.FAILED
    }
}

/**
 * The four-state catalog a page renders, in the same words the page layer already
 * uses for its own reads.
 *
 * The mapping from [ConnectorState] is a total function, so adding a connector
 * state is a compile error at this projection rather than an unstyled branch in a
 * page. `:domain` cannot name the page layer's per-screen enums — that would point
 * the dependency the wrong way — so this enum is the shared vocabulary a page
 * joins on, one constant for one constant.
 */
enum class ConnectorStatus {
    /** Connected, and the device declared at least one capability. */
    READY,

    /** Connected, and the device declared no capability at all. */
    EMPTY,

    /** A failure is known: the connector is [ConnectorState.Failed] or retrying. */
    FAILED,

    /** No answer has been produced yet: never attempted, or still in flight. */
    UNKNOWN,
}

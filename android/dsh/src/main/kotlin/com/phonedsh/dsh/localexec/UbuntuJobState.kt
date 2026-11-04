// phone-dsh — :dsh / com.phonedsh.dsh.localexec: the `ubuntu.exec` job state machine.
// SPDX-License-Identifier: MIT
//
// ---- the contract this file encodes -----------------------------------------
// spec/v1/bridge.md §12.3 fixes nine job states, four of them terminal, fourteen
// state-to-state edges plus the entry row, and the boot mapping; it also says
// "no other edge exists". [EDGES] and [BOOT] below are that section transcribed.
// `UbuntuJobRulesTest` walks both, so a state added here without a row in the
// document — or a document row with no code — fails a test instead of shipping.
//
// ---- why three of the names are the host's ----------------------------------
// `handingOff`, `remote` and `reclaiming` are budgets.md §1's `HandingOff`,
// `Remote` and `Reclaiming` seen from one job's point of view: the same three
// legs (authority leaves / authority is elsewhere / authority returns), the same
// guard (admission stays closed to the affected work), the same two failure
// rules (a half-finished handoff cannot be replayed at boot; a lost remote is
// `outcome: unknown` and is never retried automatically). What is *not* shared
// is the record: the host state stays the only authority state and a job state
// never opens admission. That is why this is a second enum and not a second
// authority machine — the difference the review asked for in as many words.
//
// ---- terminal is a property, not a promise ----------------------------------
// `succeeded -> ingestRefused` is the one legal edge out of a terminal state
// (§12.3 row 15). It exists because a job's artifacts are fetched *after* the
// job ends: a later fetch refused for a resource reason makes the old record
// false, and an audit that may not be rewritten must be allowed to become
// correct. Every other terminal has no outgoing edge.

package com.phonedsh.dsh.localexec

/** One `ubuntu.exec` job state (bridge.md §12.3). */
enum class UbuntuJobState(val wire: String, val terminal: Boolean) {
    /** The record and its audit line are durable; nothing has left the host. */
    ADMITTED("admitted", false),

    /** The three internal roots are being sealed; no adapter may be reached first. */
    SEALING("sealing", false),

    /** The snapshot and the command are crossing to the environment. */
    HANDING_OFF("handingOff", false),

    /** The environment owns the execution; DSH polls. */
    REMOTE("remote", false),

    /** Exit, log tail and the artifact manifest are coming back; the seal is restored. */
    RECLAIMING("reclaiming", false),

    /** An exit code was recorded, the manifest is known, the seal is restored. */
    SUCCEEDED("succeeded", true),

    /** No exit code will ever be recorded; a `failure` is present. */
    FAILED("failed", true),

    /** A page cancel or a host drain stopped the job; a `failure` is present. */
    CANCELLED("cancelled", true),

    /** The command ran and its exit code is recorded, but an artifact cannot be ingested. */
    INGEST_REFUSED("ingestRefused", true);

    companion object {
        /** The five non-terminal states, in the order a job visits them. */
        val IN_FLIGHT: List<UbuntuJobState> =
            listOf(ADMITTED, SEALING, HANDING_OFF, REMOTE, RECLAIMING)

        /** The four terminal states of §12.3's first column. */
        val TERMINAL: List<UbuntuJobState> = listOf(SUCCEEDED, FAILED, CANCELLED, INGEST_REFUSED)

        /** Every state; the two lists above partition it. */
        val ALL: List<UbuntuJobState> = IN_FLIGHT + TERMINAL

        /**
         * §12.3's fourteen state-to-state edges.
         *
         * A terminal state is present with an empty set (or with the one revision
         * edge) so that "the table is exhaustive" is checkable by lookup rather
         * than by its absence from a map.
         */
        val EDGES: Map<UbuntuJobState, Set<UbuntuJobState>> = mapOf(
            ADMITTED to setOf(SEALING, FAILED),
            SEALING to setOf(HANDING_OFF, FAILED),
            HANDING_OFF to setOf(REMOTE, FAILED, CANCELLED),
            REMOTE to setOf(RECLAIMING, FAILED),
            RECLAIMING to setOf(SUCCEEDED, INGEST_REFUSED, CANCELLED, FAILED),
            // §12.3 row 15: the only edge out of a terminal state.
            SUCCEEDED to setOf(INGEST_REFUSED),
            FAILED to emptySet(),
            CANCELLED to emptySet(),
            INGEST_REFUSED to emptySet(),
        )

        /** The state named by [raw], or `null` — a name this build cannot claim. */
        fun ofWire(raw: String): UbuntuJobState? = ALL.firstOrNull { it.wire == raw.trim() }

        /** `true` when §12.3 has the edge, and never for a state this build lacks. */
        fun canMove(from: UbuntuJobState, to: UbuntuJobState): Boolean =
            EDGES[from]?.contains(to) == true

        /**
         * What a boot must do with a job found in [persisted] (bridge.md §12.3).
         *
         * The four rows are budgets.md §3's pinned boot mapping applied to a job:
         * `Remote` survives and polling resumes, `HandingOff` is unrecoverable,
         * and the two states that never reached an adapter are `not_started`
         * rather than `unknown` because nothing was contacted.
         */
        fun bootDisposition(persisted: UbuntuJobState): UbuntuBootDisposition = when (persisted) {
            ADMITTED, SEALING ->
                UbuntuBootDisposition.Fail(cause = UbuntuCause.HOST_LOST, outcome = UbuntuOutcome.NOT_STARTED)

            HANDING_OFF ->
                UbuntuBootDisposition.Fail(cause = UbuntuCause.HANDOFF_LOST, outcome = UbuntuOutcome.UNKNOWN)

            REMOTE -> UbuntuBootDisposition.Keep
            RECLAIMING -> UbuntuBootDisposition.Keep
            SUCCEEDED, FAILED, CANCELLED, INGEST_REFUSED -> UbuntuBootDisposition.Keep
        }
    }
}

/** The boot decision for one persisted job (bridge.md §12.3's boot table). */
sealed interface UbuntuBootDisposition {
    /** Keep the persisted state; a `remote` job resumes polling and a `reclaiming` one resumes. */
    data object Keep : UbuntuBootDisposition

    /** Overwrite the job with a terminal `failed`; the seal is repaired first. */
    data class Fail(val cause: String, val outcome: String) : UbuntuBootDisposition
}

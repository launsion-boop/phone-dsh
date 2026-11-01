// phone-dsh — :dsh / com.phonedsh.dsh.exec: the two external facts exec needs.
// SPDX-License-Identifier: MIT
//
// The exec bridge does not own admission (channel.md §4.5 LIFECYCLE / §4.7 FENCE)
// and does not own the VFS watermark (wal.md / exec.md §2.1). It reads them
// through these two one-method interfaces, so the protocol layer is testable on
// a JVM and the host lane keeps both authorities:
//
//   * [AdmissionGate] is the conjunction the host already computes — a new side
//     effect needs the last LIFECYCLE admission and the last FENCE admission to
//     be open. This lane never opens or closes it.
//   * [ExecWorkspace] is the *applied* watermark. `WorkspaceLog.materializedUptoMseq`
//     is the strictly contiguous mseq materialized into the copy an accelerator
//     reads, so it is the one value that answers exec.md §2.1. `lastMseq` (the
//     highest allocated mseq) would be a weaker claim: a mutation can be framed
//     and still not be applied, and this lane must not dispatch on that.

package com.phonedsh.dsh.exec

import com.phonedsh.log.WorkspaceLog

/**
 * Whether a new side effect is admitted right now.
 *
 * channel.md §4.5: `pause` dispatches no new tool work; §4.7: FENCE may close
 * admission on a live connection. A closed gate answers every EXEC_REQ with one
 * terminal error event and starts nothing (exec.md §2 "Admission").
 */
fun interface AdmissionGate {
    /** The host's current admission state. */
    fun isOpen(): Boolean

    companion object {
        /** Admission is open; used by a host that has not wired a gate yet. */
        val Open: AdmissionGate = AdmissionGate { true }

        /** Admission is closed; the safe value for tests and for a stopped turn. */
        val Closed: AdmissionGate = AdmissionGate { false }
    }
}

/**
 * The VFS readiness fence of exec.md §2.1 (`requires_mseq`).
 *
 * The bridge polls this value while a request waits; it never dispatches before
 * `appliedMseq() >= requires_mseq`. The read-only contract is deliberate: the
 * WAL's append, ack and repair order is the host lane's, not this lane's.
 */
fun interface ExecWorkspace {
    /**
     * The highest contiguous mseq applied to the materialized view an
     * accelerator reads; 0 when no log is wired.
     */
    fun appliedMseq(): Long

    companion object {
        /**
         * No WAL is attached: nothing has been applied.
         *
         * Honest for a request with `requires_mseq = 0`; a request that requires
         * a mutation will wait and then fail its deadline/bound instead of
         * reading a view that is not there.
         */
        val None: ExecWorkspace = ExecWorkspace { 0L }

        /**
         * Adapts the real log. The materialized watermark is read without taking
         * the log's mutex on purpose: a scalar read is the seam the WAL lane can
         * replace with a signal later without changing this API.
         */
        fun of(log: WorkspaceLog): ExecWorkspace = ExecWorkspace { log.materializedUptoMseq }
    }
}

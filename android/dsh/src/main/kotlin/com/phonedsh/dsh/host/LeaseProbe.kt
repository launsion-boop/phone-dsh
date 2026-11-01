// phone-dsh — :dsh / com.phonedsh.dsh.host: the lease precondition of D14, as a seam.
// SPDX-License-Identifier: MIT
//
// budgets.md §2: `Recovering -> Running` is guarded by "lease verified"; the
// controller therefore needs a `LeaseCheckResult` before it opens admission.
// The lease itself (fence generation + WAL tail + a remote generation that can
// outrank them) belongs to the WAL/handoff lanes. Until those exist the facade
// must still be able to boot, so the check is an injected port with one
// documented implementation.
//
// This is not a silent `true`: [LocalOnly] states the topological reason it
// holds, the facade logs the probe result, and a false answer keeps the host in
// `Recovering` instead of opening admission on an unverified lease.

package com.phonedsh.dsh.host

/**
 * The `Recovering -> Running` guard of the D14 table.
 *
 * Implementations are synchronous and cheap: the state machine is fed serially
 * and a probe that blocked would stall every lifecycle signal behind it.
 */
fun interface LeaseProbe {
    /** `true` when this host may open admission on the local lease. */
    fun verify(): Boolean

    companion object {
        /**
         * The demo topology: one App process, no remote authority, no handoff.
         *
         * Nothing outside this process can hold execution authority yet —
         * `ControllerStateMachine` has never entered `HandingOff` on this boot,
         * and no fence generation above 0 exists — so the local lease is the only
         * one there is and it holds. The moment a remote handoff or a WAL-backed
         * lease exists, pass a probe that reads the fence generation and the
         * `durable_mseq` instead; the type of this function does not change.
         */
        val LocalOnly: LeaseProbe = LeaseProbe { true }
    }
}

// phone-dsh — :dsh / com.phonedsh.dsh.host: "one probe succeeded", as a seam.
// SPDX-License-Identifier: MIT
//
// budgets.md §2 gates `Backoff -> Running` on three facts: "Retry-After
// elapsed, network path satisfied, one probe succeeded". §3 never names a
// source for the probe (unlike scenePhase/NWPathMonitor/thermalState/
// battery), so the port has to decide what a probe *is* and write the decision
// down instead of hiding it in a `true`:
//
//   * the "network path satisfied" conjunct is §3's NWPathMonitor row and is
//     already a real D14 signal, so the probe must not repeat it;
//   * the same §2 row's Actions column says "Reopen admission after a lease
//     check", and `ControllerSignal.RetryProbeSucceeded` carries
//     `leaseVerified` for exactly that reason. The probe is therefore the
//     lease check, performed once per window — the only check §2 names.
//
// [LeaseProbe.LocalOnly] is the current single-process topology, so on today's
// composition the probe answers "the local lease still holds" — a real call
// through a real seam whose result the lane feeds unchanged, not a hard-coded
// `true`. When a remote authority or a WAL-backed fence exists, the composition
// root passes a probe that reads them; the type does not change.

package com.phonedsh.dsh.host

/**
 * One probe of the `Backoff -> Running` guard.
 *
 * Synchronous like [LeaseProbe]: the lane feeds the result to the controller on
 * the same thread, and a probe that blocked would stall the signal that opens
 * admission behind it. A probe that throws is a failed probe, never a pass.
 */
fun interface RetryProbe {
    /** `true` when this attempt may reopen admission. */
    fun probe(): Boolean

    companion object {
        /** The probe of the `Backoff -> Running` Actions column: one lease check. */
        fun leaseCheck(lease: LeaseProbe): RetryProbe = RetryProbe { lease.verify() }
    }
}

// The composition root's seal wiring: the real BuildSeal behind the lane's seam.
// SPDX-License-Identifier: MIT
//
// ---- why this file exists here, and not in :dsh ---------------------------
// `:dsh` owns the `UbuntuSeal` seam and deliberately does not depend on
// `:platform-android` (that module is the device half of the `:platform` SPI; the
// host facade must not link it). `:platform-android` in turn does not depend on
// `:dsh`, so its adapter (`BuildSealUbuntu`) cannot implement the seam itself.
// `:app` is the one module that sees both, which is what makes it the
// composition root: this file is the ~30-line type adapter, and every line of
// behaviour stays in `BuildSealUbuntu`.
//
// ---- what the audit found, and what this closes ---------------------------
// Before this wiring, `MockUbuntuSession` built `MockUbuntuSeal`, whose own
// comment says it "opens and closes nothing", so the Agent's `ubuntu run` never
// executed a `chmod`. The 768-line `BuildSeal`, its tripwire and its 25 device
// tests were reachable only from tests. Now the production path is:
//
//   HostExec.defaultTools(seal = UbuntuWorkspaceSeal(...))
//     -> UbuntuHostTool -> MockUbuntuSession -> UbuntuJobLane.seal(jobId)
//       -> BuildSealUbuntu.seal(jobId) -> BuildSeal.seal(job)
//         -> chmod 000 on materialized/home/{sessions,storages,tool-journal}
//
// and `repair()` runs in `ProbeEngineViewModel` **before** `host.start()` opens
// the workspace, because a root left at 000 by a killed process makes the WAL's
// first reconcile of `materialized/home` fail.

package com.phonedsh.probe

import com.phonedsh.dsh.localexec.UbuntuSeal
import com.phonedsh.dsh.localexec.UbuntuSealResult
import com.phonedsh.platform.android.BuildSealUbuntu
import com.phonedsh.platform.android.SealOutcome
import java.nio.file.Path

/**
 * [UbuntuSeal] over the real seal.
 *
 * The type adapter only: it renames `SealOutcome` to `UbuntuSealResult` so
 * `:dsh` keeps its own vocabulary and `:platform-android` keeps the
 * `SealFailure`-based one. The reason tokens are produced by
 * `SealFailure.reasonToken()` on the platform side; nothing here rewrites them,
 * so the four tokens L47's contract names (`chmod_failed`, `verify_failed`,
 * `restore_failed`, `marker_unreadable`) reach `seal.reason` unchanged.
 *
 * @param seal the platform adapter over `BuildSeal` + `BuildSealTripwire`.
 */
class UbuntuWorkspaceSeal(private val seal: BuildSealUbuntu) : UbuntuSeal {

    override suspend fun seal(jobId: String): UbuntuSealResult = seal.seal(jobId).toSeam()

    override suspend fun restore(jobId: String): UbuntuSealResult = seal.restore(jobId).toSeam()

    override fun observed(jobId: String): Boolean = seal.observed(jobId)

    override suspend fun repair(): Boolean = seal.repair()

    /**
     * The platform adapter, for the composition root's own boot repair.
     *
     * The seam's `repair()` is the only thing the lane calls, and the lane calls
     * it too late for a boot (it runs on the first `ubuntu` op, after
     * `host.start()`). The app therefore needs this handle to repair before the
     * workspace opens.
     */
    fun platform(): BuildSealUbuntu = seal

    companion object {
        /**
         * The one production construction.
         *
         * @param xlRoot `filesDir/xl`, the workspace root the WAL, the journal and
         *   the exec ledger are all built over — so the sealed roots are the same
         *   `materialized/home` tree those stores materialize, not a second copy.
         * @param log token-free host log the seal's own lines go to.
         */
        fun forWorkspace(xlRoot: Path, log: (String) -> Unit): UbuntuWorkspaceSeal =
            UbuntuWorkspaceSeal(BuildSealUbuntu.forWorkspace(xlRoot = xlRoot, log = log))
    }
}

/** One platform answer as the lane's result. */
private fun SealOutcome.toSeam(): UbuntuSealResult = when (this) {
    SealOutcome.Sealed -> UbuntuSealResult.Sealed
    is SealOutcome.Failed -> UbuntuSealResult.Failed(reason)
}

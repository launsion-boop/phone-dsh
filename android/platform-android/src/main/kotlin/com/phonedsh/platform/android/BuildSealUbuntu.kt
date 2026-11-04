// The `ubuntu` job lane's seal: BuildSeal + its tripwire, behind one job-keyed object.
// SPDX-License-Identifier: MIT
//
// ---- why this file exists ------------------------------------------------
// Plan §3 layer 3 (`chmod 000` the three internal roots for one job's window)
// and layer 4 (the FileObserver tripwire that notices a deliberate `chmod`
// back) are implemented by `BuildSeal.kt`, `BuildSealTripwire.kt` and
// `FileObserverTripwireSource.kt`. Those three shipped with 25/25 device tests
// and **zero production consumers**: `:dsh`'s `ubuntu` lane was wired to
// `MockUbuntuSeal`, whose own comment says it "opens and closes nothing", so
// the Agent's `ubuntu run` never changed a permission bit. This class is the
// missing adapter between the lane's job-keyed seam (`UbuntuSeal` in `:dsh`,
// four methods) and the handle-keyed machinery here.
//
// ---- the two shapes that have to be reconciled ---------------------------
//   * the lane speaks **job ids**: `seal(jobId)` … `restore(jobId)` … and it
//     may read `observed(jobId)` once, *after* the restore (so the audit
//     describes a closed window);
//   * `BuildSeal` speaks **handles**: `seal(job)` returns the only value
//     `restore` accepts, so a caller can only undo a seal it was given.
//
// This object holds the `job -> handle` table. It is the single owner of it:
// nothing else in the process may restore a handle, which is what keeps
// `§12.3`'s "every path out of the window restores" true without the lane
// having to store a filesystem type.
//
// ---- the tripwire window is opened and closed here -----------------------
// `begin()` before the first chmod, `end()` after the last one plus a settle
// delay (`BuildRuntime.DEFAULT_AUDIT_SETTLE_MS`, the same number the runtime
// uses): inotify delivery is asynchronous, so ending the window the instant the
// restore returns would drop a guest `chmod` that was still in the kernel
// queue. The `BuildSeal` is given this tripwire as its `SealSelfEvents`, so the
// seal's *own* chmods are excused and only a foreign `chmod` counts as an
// access. Without that wiring every single job would report `observed = true`.
//
// ---- the reason token ----------------------------------------------------
// `SealFailure` is an 8-value enum for the log; the lane's `seal.reason` is a
// short stable token a user-facing status can carry (L47's contract names
// `chmod_failed`, `verify_failed`, `restore_failed`, `marker_unreadable`).
// [reasonToken] is the one mapping, so a new enum value cannot reach the wire
// under an accidental `toString()`.

package com.phonedsh.platform.android

import com.phonedsh.platform.Durability
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.delay

/** What a seal request answered; [Failed.reason] is the token the job record carries. */
sealed interface SealOutcome {
    /** The window is open (seal), or closed again (restore). */
    data object Sealed : SealOutcome

    /** The seal could not be established or restored. */
    data class Failed(val reason: String) : SealOutcome
}

/**
 * The stable `seal.reason` token for one [SealFailure].
 *
 * The four tokens L47's contract lists are exactly [REASON_CHMOD_FAILED],
 * [REASON_VERIFY_FAILED], [REASON_RESTORE_FAILED] and [REASON_MARKER_UNREADABLE];
 * the other four are named here rather than stringified so a status reader sees
 * one vocabulary.
 */
fun SealFailure.reasonToken(): String = when (this) {
    SealFailure.ROOT_MISSING -> BuildSealUbuntu.REASON_ROOT_MISSING
    SealFailure.MARKER_FAILED -> BuildSealUbuntu.REASON_MARKER_FAILED
    SealFailure.CHMOD_FAILED -> BuildSealUbuntu.REASON_CHMOD_FAILED
    SealFailure.VERIFY_FAILED -> BuildSealUbuntu.REASON_VERIFY_FAILED
    SealFailure.RESTORE_FAILED -> BuildSealUbuntu.REASON_RESTORE_FAILED
    SealFailure.MARKER_UNREADABLE -> BuildSealUbuntu.REASON_MARKER_UNREADABLE
    SealFailure.ALREADY_SEALED -> BuildSealUbuntu.REASON_ALREADY_SEALED
    SealFailure.HANDLE_UNKNOWN -> BuildSealUbuntu.REASON_HANDLE_UNKNOWN
}

/**
 * The `ubuntu` lane's seal over one workspace, keyed by job id.
 *
 * @param seal the real seal. Its `selfEvents` **must** be [tripwire] or every
 *   job reports `internalAccessObserved = true`; [forWorkspace] wires that, and
 *   a constructor caller is responsible for it (the tests in this module do it
 *   deliberately, including one that asserts the difference).
 * @param tripwire the audit of one job's window.
 * @param watch opens the live watch for a window; `null` when the device cannot
 *   observe (a JVM suite, or a workspace whose `materialized/home` does not
 *   exist yet). Created lazily per job because the watched directory is created
 *   by the WAL *after* this object is constructed.
 * @param settleMs how long the audit stays open after the restore, for inotify
 *   delivery. Defaults to the runtime's own settle.
 * @param log token-free log seam.
 */
class BuildSealUbuntu(
    private val seal: BuildSeal,
    private val tripwire: BuildSealTripwire,
    private val watch: (() -> SealWatch?)? = null,
    private val settleMs: Long = BuildRuntime.DEFAULT_AUDIT_SETTLE_MS,
    private val log: (String) -> Unit = {},
) {
    private val lock = Any()

    /** The open handles, by job id: the only values a restore accepts. */
    private val handles = HashMap<String, SealHandle>()

    /**
     * The closed windows' verdicts, by job id.
     *
     * The lane reads `observed(jobId)` *after* the restore, so the verdict has
     * to survive the window's close. Bounded, because a host that runs many jobs
     * must not grow one Boolean per job forever; the oldest is evicted first and
     * an evicted id answers `false` — never `true`, which would invent an
     * access.
     */
    private val audits = BoundedAudits(MAX_AUDITED_JOBS)

    /** The watch of the window currently open, or `null`. */
    private var live: SealWatch? = null

    /**
     * Opens the window for [jobId] and seals the roots.
     *
     * Idempotent for the same job: a second call for a job that already holds a
     * handle answers [SealOutcome.Sealed] without a second chmod (the lane's boot
     * recovery can re-seal a job it resumed).
     *
     * @param jobId the job the window is booked under.
     */
    suspend fun seal(jobId: String): SealOutcome {
        synchronized(lock) {
            if (handles.containsKey(jobId)) {
                log("ubuntu-seal: job \"$jobId\" is already sealed; reusing its handle")
                return SealOutcome.Sealed
            }
        }
        if (tripwire.isArmed()) {
            // The lane serialises jobs, so an armed window here means a previous
            // window leaked (a restore that never ran). begin() resets it; say so
            // rather than hiding it.
            log("ubuntu-seal: a previous audit window was still open; resetting it for job \"$jobId\"")
        }
        tripwire.begin()
        val opened = try {
            watch?.invoke()
        } catch (failure: Throwable) {
            // A watch that cannot start is not a seal failure: layer 3 still
            // protects bytes, and layer 4's absence is reported by the empty
            // audit (`observed = false` means "nothing was seen", never "nothing
            // happened" — the tripwire's own contract).
            log("ubuntu-seal: the tripwire watch could not start (${failure.javaClass.simpleName})")
            null
        }
        synchronized(lock) { live = opened }
        opened?.start()

        val handle = try {
            seal.seal(jobId)
        } catch (failure: SealException) {
            closeWindow(auditFor = null, settle = false)
            log("ubuntu-seal: job \"$jobId\" was not sealed (${failure.failure.reasonToken()}): ${failure.detail}")
            return SealOutcome.Failed(failure.failure.reasonToken())
        } catch (failure: Throwable) {
            closeWindow(auditFor = null, settle = false)
            log("ubuntu-seal: job \"$jobId\" was not sealed (chmod_failed): ${failure.javaClass.simpleName}")
            return SealOutcome.Failed(REASON_CHMOD_FAILED)
        }

        synchronized(lock) { handles[jobId] = handle }
        log(
            "ubuntu-seal: job \"$jobId\" sealed ${handle.protectedLabels} " +
                if (handle.isVacuous) {
                    "(no root exists yet, so the seal protects nothing)"
                } else {
                    "(${handle.protectedLabels.size} root(s) at 000)"
                },
        )
        return SealOutcome.Sealed
    }

    /**
     * Closes [jobId]'s window: restore the modes, then close the audit.
     *
     * Idempotent by the handle table: a second restore for the same job finds no
     * handle and answers [SealOutcome.Sealed] without touching a mode, which is
     * what makes an agent close racing the system close harmless.
     *
     * A restore that fails keeps the handle (so a later retry re-attempts it) and
     * the marker (so the next boot repairs it), and answers the token.
     *
     * @param jobId the job whose window closes.
     */
    suspend fun restore(jobId: String): SealOutcome {
        val handle = synchronized(lock) { handles[jobId] }
        if (handle == null) {
            // No handle: either the job never sealed, or this is the second
            // restore. A window still armed under this job is closed anyway, so
            // a leaked audit cannot be attributed to the next job.
            if (tripwire.isArmed()) closeWindow(auditFor = jobId, settle = true)
            log("ubuntu-seal: job \"$jobId\" has no open seal; nothing to restore")
            return SealOutcome.Sealed
        }
        var outcome: SealOutcome = SealOutcome.Sealed
        try {
            seal.restore(handle)
            synchronized(lock) { handles.remove(jobId) }
        } catch (failure: SealException) {
            outcome = SealOutcome.Failed(failure.failure.reasonToken())
            log("ubuntu-seal: job \"$jobId\" was not restored (${failure.failure.reasonToken()}): ${failure.detail}")
        } catch (failure: Throwable) {
            outcome = SealOutcome.Failed(REASON_RESTORE_FAILED)
            log("ubuntu-seal: job \"$jobId\" was not restored (restore_failed): ${failure.javaClass.simpleName}")
        }
        // The restore chmods announced themselves through the tripwire's
        // SealSelfEvents; the settle keeps the window open long enough for those
        // events (and any foreign one behind them) to arrive before it closes.
        closeWindow(auditFor = jobId, settle = true)
        return outcome
    }

    /**
     * `true` when the tripwire saw an access to the internal roots in [jobId]'s window.
     *
     * Read *after* the restore (the lane's ordering), so it answers from the
     * closed window; while the window is open it answers what has been seen so
     * far. `false` means "nothing was seen", never "nothing happened".
     */
    fun observed(jobId: String): Boolean {
        synchronized(lock) { audits[jobId] }?.let { return it }
        return tripwire.internalAccessObserved
    }

    /**
     * Repairs a seal a killed process left behind.
     *
     * **Must run before the workspace is opened on boot**: a root still at 000
     * makes the WAL's first reconcile of `materialized/home` fail. Idempotent,
     * and a no-op when no marker exists (the ordinary boot).
     *
     * @returns `true` when there is nothing left to repair. A `false` means the
     *   marker is still there and the next boot retries; the caller must surface
     *   it rather than treating the workspace as healthy.
     */
    suspend fun repair(): Boolean {
        val recovery = try {
            seal.recoverIfNeeded()
        } catch (failure: Throwable) {
            log("ubuntu-seal: the boot repair threw (${failure.javaClass.simpleName})")
            return false
        }
        return when (recovery) {
            SealRecovery.NothingToDo -> true
            is SealRecovery.Repaired -> {
                val changed = recovery.roots.count { it.modeBefore != it.modeAfter }
                log(
                    "ubuntu-seal: repaired job \"${recovery.job}\" after a crash; " +
                        "$changed of ${recovery.roots.size} root(s) put back",
                )
                true
            }

            is SealRecovery.Failed -> {
                log("ubuntu-seal: repair failed (${recovery.failure.reasonToken()}): ${recovery.reason}")
                false
            }
        }
    }

    /** Stops the watch, closes the audit and files its verdict under [auditFor]. */
    private suspend fun closeWindow(auditFor: String?, settle: Boolean) {
        if (settle && settleMs > 0L) delay(settleMs)
        val opened = synchronized(lock) { live.also { live = null } }
        try {
            opened?.stop()
        } catch (failure: Throwable) {
            log("ubuntu-seal: the tripwire watch could not stop (${failure.javaClass.simpleName})")
        }
        val report = tripwire.end()
        if (auditFor != null) {
            synchronized(lock) { audits[auditFor] = report.observed }
            if (report.observed) {
                log(
                    "ubuntu-seal: job \"$auditFor\" saw ${report.events.size} access(es) to the internal " +
                        "roots (dropped=${report.dropped}, excused=${report.excused})",
                )
            }
        }
    }

    /** A job-id-keyed verdict table with a hard bound and insertion-order eviction. */
    private class BoundedAudits(private val max: Int) {
        private val entries = LinkedHashMap<String, Boolean>()

        operator fun get(jobId: String): Boolean? = synchronized(entries) { entries[jobId] }

        operator fun set(jobId: String, observed: Boolean) {
            synchronized(entries) {
                entries.remove(jobId)
                entries[jobId] = observed
                while (entries.size > max) {
                    val eldest = entries.keys.firstOrNull() ?: break
                    entries.remove(eldest)
                }
            }
        }
    }

    companion object {
        /** L47's four contract tokens, and the four extra names. */
        const val REASON_CHMOD_FAILED: String = "chmod_failed"
        const val REASON_VERIFY_FAILED: String = "verify_failed"
        const val REASON_RESTORE_FAILED: String = "restore_failed"
        const val REASON_MARKER_UNREADABLE: String = "marker_unreadable"
        const val REASON_MARKER_FAILED: String = "marker_failed"
        const val REASON_ROOT_MISSING: String = "root_missing"
        const val REASON_ALREADY_SEALED: String = "already_sealed"
        const val REASON_HANDLE_UNKNOWN: String = "handle_unknown"

        /** How many closed windows keep their verdict, for a late `observed` read. */
        const val MAX_AUDITED_JOBS: Int = 32

        /**
         * The production construction for one workspace.
         *
         * Wires the three pieces the design calls layers 3 and 4 together:
         * `BuildSeal` gets this tripwire as its `SealSelfEvents` (so its own
         * chmods do not read as accesses), the marker lives beside the roots at
         * `<workspace>/.build-seal.lock`, and the watch is created per job over
         * `<workspace>/materialized/home` — which the WAL creates after this
         * object exists, hence the lazy lambda.
         *
         * @param xlRoot the workspace root, `filesDir/xl` on Android.
         */
        fun forWorkspace(
            xlRoot: Path,
            durability: Durability = AndroidDurability(),
            modes: ModeControl = PosixModeControl,
            nowMs: () -> Long = System::currentTimeMillis,
            log: (String) -> Unit = {},
            targets: SealTargets = SealTargets.standard(xlRoot),
        ): BuildSealUbuntu {
            val tripwire = BuildSealTripwire(nowMs)
            val seal = BuildSeal(
                targets = targets,
                markerPath = xlRoot.resolve(BuildSeal.MARKER_NAME),
                durability = durability,
                modes = modes,
                nowMs = nowMs,
                log = log,
                // Layer 3's own chmods must not read as layer 4's accesses.
                selfEvents = tripwire,
            )
            return BuildSealUbuntu(
                seal = seal,
                tripwire = tripwire,
                watch = {
                    if (Files.isDirectory(targets.home)) {
                        FileObserverTripwireSource(targets.home, tripwire)
                    } else {
                        null
                    }
                },
                log = log,
            )
        }
    }
}

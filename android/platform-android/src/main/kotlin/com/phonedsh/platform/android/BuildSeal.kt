// The build seal: chmod 000 on the internal roots, with a crash-recoverable marker.
// SPDX-License-Identifier: MIT
//
// ---- what this closes ------------------------------------------------------
// `spec/v1/channel.md` §6 says the execution surfaces get EACCES on
// `/dsh/home/{sessions,storages,tool-journal}` and never see the bytes. That
// EACCES is the *worker's* VFS (JavaScript) enforcing it, so any execution
// surface that is not the worker -- a proot'd Ubuntu guest sharing this app's
// UID -- is outside the checkpoint. Plan §3 layer 3 adds a kernel-level
// checkpoint for the duration of one job: the three roots are `chmod 000`, so
// an accidental `find` or `cat` stops at EACCES and a deliberate read has to
// start with an explicit `chmod`, which is an observable act rather than an
// `open()`.
//
// This class is only the seal half. §3 layer 4 (the FileObserver tripwire that
// notices the deliberate `chmod`) is `BuildSealTripwire.kt`, the process-tree
// half of "use it and throw it away" is `BuildSealReaper.kt`, and the "warm but
// sealed" lifecycle is `BuildRuntime.kt`.
//
// ---- the honest boundary ---------------------------------------------------
// Same UID means the guest can `chmod` the roots back. Nothing here prevents
// that; the repair is that doing so trips the wire and shows up in
// `internalAccessObserved`. Plan §2 states this and the consent text must say
// it out loud.
//
// ---- the crash risk, and the marker ---------------------------------------
// If the process dies between `chmod 000` and the restore, the roots stay 000
// and the user's sessions become unreadable *until some later boot repairs
// them*. That is worse than the exposure this layer removes, so the repair has
// to be unconditional:
//
//   1. write `.build-seal.lock` (atomic replace + file fsync + parent dir
//      fsync) *before* the first chmod, naming every root and its original
//      mode;
//   2. chmod;
//   3. on restore, chmod back and only then delete the marker;
//   4. on the next boot, `recoverIfNeeded()` reads the marker, restores every
//      root whose mode is still 000, and deletes it.
//
// The marker lives *next to* the sealed roots (`<workspace>/.build-seal.lock`),
// never inside one, or the seal would hide the evidence that it has to be
// undone.
//
// ---- ordering is the whole safety argument --------------------------------
// Marker first, chmod second. A crash between (1) and (2) leaves a marker whose
// roots are still at their original mode; recovery sees mode != 000 and does
// nothing, which is idempotent. A crash between (2) and (3) is the case the
// marker exists for. A crash after the restore chmods but before the marker
// delete is again idempotent: recovery restores modes that are already right.
//
// ---- fail-closed -----------------------------------------------------------
// `seal()` returning *is* the permission to start a job. A missing required
// root, a failing chmod, or a root that does not read back as 000 throws
// [SealException]; a partial seal is rolled back so the app is not left in a
// half-sealed, half-readable state, and the marker is kept only when the
// rollback itself failed (so the next boot repairs it).
//
// ---- roots that must stay out ---------------------------------------------
// The three roots are the *materialized mirror* of the worker VFS paths:
// `<workspace>/materialized/home/{sessions,storages,tool-journal}`. The host's
// own durable journal at `<workspace>/journal` is **not** sealed: it is appended
// and fsynced per record during a turn (`JournalStore.appendLocked` opens
// `journal/<hex>` and fsyncs before the ACK), so a chmod 000 there would stop
// the durability acknowledgement for the very job that is running -- the N1
// failure mode, not a security win. [SealTargets.standard] therefore lists it as
// an explicit exclusion, and the exclusion is reported instead of being silently
// skipped.

package com.phonedsh.platform.android

import com.phonedsh.platform.Durability
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermission
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One root the seal is expected to cover.
 *
 * @property label the short name used in logs and in the audit status
 *   (`sessions`, `storages`, `tool-journal`).
 * @property path the physical directory. For the standard set this is the
 *   materialized mirror of the worker VFS path.
 * @property required when `true`, an absent path fails [BuildSeal.seal]
 *   (fail-closed). When `false`, an absent path is recorded as
 *   [SealEntry.originalMode] `null` and nothing is chmod'd: the worker creates
 *   these directories lazily, so "not there yet" means "no bytes to protect
 *   yet", not "the seal is broken".
 */
data class SealRoot(
    val label: String,
    val path: Path,
    val required: Boolean = false,
) {
    init {
        require(label.isNotEmpty()) { "a seal root needs a label" }
        require(path.isAbsolute) { "a seal root needs an absolute path: $path" }
    }
}

/**
 * A root the seal deliberately does not touch, with the reason.
 *
 * Reported in [SealHandle.exclusions] and in the job status, because narrowing
 * the seal is a decision the user has to be able to see. A silently skipped
 * root would make `internalAccessObserved` look like it covered more than it
 * does.
 */
data class SealExclusion(val label: String, val path: Path, val reason: String)

/**
 * The root set of one seal.
 *
 * @property home the physical `/dsh/home` mirror; the tripwire watches this
 *   directory, and it is the parent of the three roots.
 * @property roots the roots [BuildSeal] chmods; order is the chmod order.
 * @property exclusions roots that are deliberately left alone.
 */
class SealTargets(
    val home: Path,
    val roots: List<SealRoot>,
    val exclusions: List<SealExclusion> = emptyList(),
) {
    init {
        require(roots.isNotEmpty()) { "a seal needs at least one root" }
        require(home.isAbsolute) { "the home directory needs an absolute path: $home" }
        val labels = roots.map { it.label }
        require(labels.toSet().size == labels.size) { "duplicate root labels: $labels" }
    }

    companion object {
        /** The worker VFS path `sessions` (internal to DSH). */
        const val SESSIONS: String = "sessions"

        /** The worker VFS path `storages` (internal to DSH). */
        const val STORAGES: String = "storages"

        /** The worker VFS path `tool-journal` (internal to DSH). */
        const val TOOL_JOURNAL: String = "tool-journal"

        /** Why the host's own journal directory is not chmod'd. */
        const val HOST_JOURNAL_NOT_SEALED: String =
            "the host appends and fsyncs the journal for every step during the job " +
                "(JournalStore.appendLocked); sealing it would stop the durability ACK"

        /**
         * The standard set for one workspace.
         *
         * @param xlRoot the workspace root, `filesDir/xl` on Android.
         */
        fun standard(xlRoot: Path): SealTargets {
            val home = xlRoot.resolve("materialized").resolve("home")
            return SealTargets(
                home = home,
                roots = listOf(
                    SealRoot(SESSIONS, home.resolve(SESSIONS)),
                    SealRoot(STORAGES, home.resolve(STORAGES)),
                    SealRoot(TOOL_JOURNAL, home.resolve(TOOL_JOURNAL)),
                ),
                exclusions = listOf(
                    SealExclusion(
                        label = "host-journal",
                        path = xlRoot.resolve("journal"),
                        reason = HOST_JOURNAL_NOT_SEALED,
                    ),
                ),
            )
        }
    }
}

/**
 * The mode bits primitive, as a seam.
 *
 * Production is [PosixModeControl]. The host JVM has no `android.system.Os`, so
 * the JVM suite supplies a recorder or the real POSIX path; the device suite
 * (`BuildSealDeviceTest`) proves the real one against the app's own UID.
 */
interface ModeControl {
    /** The permission bits of [path], as an integer such as `0b111_000_000`. */
    fun read(path: Path): Int

    /** Sets the permission bits of [path] to [mode]. */
    fun write(path: Path, mode: Int)
}

/**
 * [ModeControl] through `java.nio.file`'s POSIX attribute view.
 *
 * One code path on the device and on the host JVM, so the JVM suite exercises
 * the same implementation that ships. `chmod(2)` is what it lands on:
 * `Files.setPosixFilePermissions` is a `fchmodat`/`chmod` on the backing
 * filesystem (ext4/f2fs on Android, APFS on the host JVM).
 */
object PosixModeControl : ModeControl {

    override fun read(path: Path): Int = bitsOf(Files.getPosixFilePermissions(path))

    override fun write(path: Path, mode: Int) {
        Files.setPosixFilePermissions(path, permissionsOf(mode))
    }

    /** The integer form of [permissions]; `0b111_101_101` is `0755`. */
    fun bitsOf(permissions: Set<PosixFilePermission>): Int {
        var bits = 0
        for (permission in permissions) {
            bits = bits or when (permission) {
                PosixFilePermission.OWNER_READ -> 0b100_000_000
                PosixFilePermission.OWNER_WRITE -> 0b010_000_000
                PosixFilePermission.OWNER_EXECUTE -> 0b001_000_000
                PosixFilePermission.GROUP_READ -> 0b000_100_000
                PosixFilePermission.GROUP_WRITE -> 0b000_010_000
                PosixFilePermission.GROUP_EXECUTE -> 0b000_001_000
                PosixFilePermission.OTHERS_READ -> 0b000_000_100
                PosixFilePermission.OTHERS_WRITE -> 0b000_000_010
                PosixFilePermission.OTHERS_EXECUTE -> 0b000_000_001
            }
        }
        return bits
    }

    /** The set form of [mode]; inverse of [bitsOf]. */
    fun permissionsOf(mode: Int): Set<PosixFilePermission> {
        val permissions = LinkedHashSet<PosixFilePermission>(9)
        if (mode and 0b100_000_000 != 0) permissions.add(PosixFilePermission.OWNER_READ)
        if (mode and 0b010_000_000 != 0) permissions.add(PosixFilePermission.OWNER_WRITE)
        if (mode and 0b001_000_000 != 0) permissions.add(PosixFilePermission.OWNER_EXECUTE)
        if (mode and 0b000_100_000 != 0) permissions.add(PosixFilePermission.GROUP_READ)
        if (mode and 0b000_010_000 != 0) permissions.add(PosixFilePermission.GROUP_WRITE)
        if (mode and 0b000_001_000 != 0) permissions.add(PosixFilePermission.GROUP_EXECUTE)
        if (mode and 0b000_000_100 != 0) permissions.add(PosixFilePermission.OTHERS_READ)
        if (mode and 0b000_000_010 != 0) permissions.add(PosixFilePermission.OTHERS_WRITE)
        if (mode and 0b000_000_001 != 0) permissions.add(PosixFilePermission.OTHERS_EXECUTE)
        return permissions
    }
}

/**
 * Notified about the seal's *own* mode changes.
 *
 * The tripwire watches `/dsh/home` for `IN_ATTRIB`, and a `chmod` by this class
 * is indistinguishable from a `chmod` by the guest unless the seal says so. The
 * tripwire therefore excuses exactly the changes announced here, which keeps
 * "sealed" from reading as "accessed" on every single job.
 *
 * @see BuildSealTripwire
 */
fun interface SealSelfEvents {
    /** The seal is about to change [path]'s mode itself. */
    fun selfModeChange(path: Path)
}

/**
 * Why a seal could not be established, which is also why the job must not run.
 *
 * The code is the stable part; the detail is for the log and the status line.
 */
enum class SealFailure {
    /** A root declared [SealRoot.required] does not exist. */
    ROOT_MISSING,

    /** The marker could not be written durably, so chmod was never attempted. */
    MARKER_FAILED,

    /** `chmod 000` itself failed on one of the roots. */
    CHMOD_FAILED,

    /** The root did not read back as 000, so the seal cannot be claimed. */
    VERIFY_FAILED,

    /** The restore could not put the original mode back; the marker is kept. */
    RESTORE_FAILED,

    /** The marker exists but cannot be parsed or is from a newer version. */
    MARKER_UNREADABLE,

    /** A seal was already active; two seals over one workspace is a bug. */
    ALREADY_SEALED,

    /** [BuildSeal.seal] ran twice for one handle, or the handle is foreign. */
    HANDLE_UNKNOWN,
}

/**
 * A failed seal, restore or recovery.
 *
 * The message never contains file *contents*: only labels, modes and the last
 * path component, because the status line is user-visible and this app does not
 * put internal path bytes into logs (`wal.md` §7).
 *
 * @property failure the stable reason.
 * @property detail a short description for the log.
 * @property cause the underlying I/O failure, when there is one.
 */
class SealException(
    val failure: SealFailure,
    val detail: String,
    cause: Throwable? = null,
) : IOException("$failure: $detail", cause)

/**
 * What one root looked like at seal time and after it.
 *
 * @property label the root's short name.
 * @property path the physical directory.
 * @property originalMode the mode found before the seal, or `null` when the
 *   root did not exist (an optional root that was never created).
 * @property sealedMode the mode read back after the chmod, or `null` when the
 *   root was absent. `0` is the sealed value.
 */
data class SealEntry(
    val label: String,
    val path: Path,
    val originalMode: Int?,
    val sealedMode: Int?,
) {
    /** `true` when this entry actually protects bytes. */
    val isProtected: Boolean get() = originalMode != null

    /** `true` when the mode read back after the seal was indeed 000. */
    val isSealed: Boolean get() = sealedMode == 0
}

/**
 * The handle one seal returns, and the only thing a restore accepts.
 *
 * Idempotent by [restored]: the second [BuildSeal.restore] for the same handle
 * is a no-op rather than a second chmod, so a close path that runs twice (an
 * agent close racing the system close) cannot widen the window.
 *
 * @property job the job id this seal belongs to.
 * @property sealedAtMs the wall clock of the seal, recorded in the marker.
 * @property entries per root evidence.
 * @property exclusions the roots this seal deliberately did not touch.
 */
class SealHandle internal constructor(
    val job: String,
    val sealedAtMs: Long,
    val entries: List<SealEntry>,
    val exclusions: List<SealExclusion>,
) {
    internal val restored = AtomicBoolean(false)

    /** The labels of the roots whose mode is 000 under this handle. */
    val protectedLabels: List<String> get() = entries.filter { it.isSealed }.map { it.label }

    /** `true` when there was nothing on disk to protect (all roots absent). */
    val isVacuous: Boolean get() = entries.none { it.isProtected }

    /** `true` once [BuildSeal.restore] returned the original modes. */
    val isRestored: Boolean get() = restored.get()
}

/** One root as a recovery put it back. */
data class RecoveredRoot(val label: String, val path: Path, val modeBefore: Int, val modeAfter: Int)

/** What [BuildSeal.recoverIfNeeded] found. */
sealed interface SealRecovery {
    /** No marker: the previous process did not die inside a seal. */
    data object NothingToDo : SealRecovery

    /**
     * A marker existed and the roots are back.
     *
     * @property job the job whose seal was interrupted.
     * @property sealedAtMs when it was sealed, for the recovery notice.
     * @property roots what the repair changed (empty when the modes were
     *   already right, which is the idempotent case).
     */
    data class Repaired(
        val job: String,
        val sealedAtMs: Long,
        val roots: List<RecoveredRoot>,
    ) : SealRecovery

    /**
     * A marker existed and could not be repaired.
     *
     * Boot continues (the seal is a degradation, not a start-up gate) but the
     * marker is kept so the next boot retries, and the caller must surface it.
     */
    data class Failed(val reason: String, val failure: SealFailure) : SealRecovery
}

/**
 * The seal over one workspace's internal roots.
 *
 * One instance per process is enough: [seal] refuses a second active seal, so
 * two callers cannot interleave two jobs' seals over the same roots.
 *
 * @param targets the roots to protect and the roots to leave alone.
 * @param markerPath the crash-recovery marker. It must live outside every
 *   sealed root, or the seal would hide its own undo record.
 * @param durability the durable-write primitive for the marker; injected
 *   because the host JVM cannot call `android.system.Os`.
 * @param modes the mode-bits primitive.
 * @param nowMs the clock seam, for the marker timestamp and the audit.
 * @param log the token-free log seam.
 */
class BuildSeal(
    private val targets: SealTargets,
    private val markerPath: Path,
    private val durability: Durability = AndroidDurability(),
    private val modes: ModeControl = PosixModeControl,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
    private val selfEvents: SealSelfEvents? = null,
) {
    private val lock = Any()

    private var active: SealHandle? = null

    /** Guards the gap between the [active] check and the handle being published. */
    private var inflight: Boolean = false

    /** The seal currently protecting the roots, or `null`. */
    fun active(): SealHandle? = synchronized(lock) { active }

    /**
     * Seals every root and returns the handle that restores them.
     *
     * The marker is durable before the first chmod, so a crash anywhere below
     * leaves a record the next boot can repair.
     *
     * @param job the job id; it goes into the marker so a recovery notice can
     *   name the job whose seal was interrupted.
     * @throws SealException when a required root is missing, the marker cannot
     *   be written, a chmod fails, or a root does not read back as 000. In all
     *   of those cases no job may start.
     */
    suspend fun seal(job: String): SealHandle {
        synchronized(lock) {
            if (active != null || inflight) {
                throw SealException(
                    SealFailure.ALREADY_SEALED,
                    "a seal is already active for job \"${active?.job}\"",
                )
            }
            inflight = true
        }
        try {
            return sealLocked(job)
        } catch (failure: Throwable) {
            synchronized(lock) { inflight = false }
            throw failure
        }
    }

    private suspend fun sealLocked(job: String): SealHandle {
        val sealedAtMs = nowMs()
        val entries = mutableListOf<SealEntry>()
        for (root in targets.roots) {
            val exists = Files.isDirectory(root.path)
            if (!exists) {
                if (root.required) {
                    throw SealException(
                        SealFailure.ROOT_MISSING,
                        "required root \"${root.label}\" is not a directory",
                    )
                }
                entries.add(SealEntry(root.label, root.path, originalMode = null, sealedMode = null))
                log("build-seal: \"${root.label}\" is absent; nothing to protect")
                continue
            }
            val mode = try {
                modes.read(root.path)
            } catch (failure: IOException) {
                throw SealException(
                    SealFailure.VERIFY_FAILED,
                    "cannot read the mode of \"${root.label}\": ${failure.message}",
                    failure,
                )
            }
            if (mode == SEALED_MODE) {
                // A root already at 000 is a state a previous seal left behind,
                // not an original mode. Recording it would make the boot repair
                // write 000 again and lose the real mode permanently.
                throw SealException(
                    SealFailure.VERIFY_FAILED,
                    "root \"${root.label}\" is already ${octal(mode)}; " +
                        "run the boot repair (recoverIfNeeded) before sealing",
                )
            }
            entries.add(SealEntry(root.label, root.path, originalMode = mode, sealedMode = null))
        }

        // The marker names every root and its original mode, so recovery never
        // has to guess what the mode used to be.
        writeMarker(job, sealedAtMs, entries)

        val sealed = mutableListOf<SealEntry>()
        try {
            for (entry in entries) {
                if (entry.originalMode == null) {
                    sealed.add(entry)
                    continue
                }
                // Recorded *before* the syscall so a failure below still rolls
                // this root back: the chmod may have landed even when the read
                // back did not agree, and a rollback that skips it would leave a
                // root sealed by a seal that was refused.
                sealed.add(entry)
                // Announced before the syscall so the tripwire can excuse the
                // seal's own IN_ATTRIB; see [SealSelfEvents].
                selfEvents?.selfModeChange(entry.path)
                modes.write(entry.path, SEALED_MODE)
                val readBack = modes.read(entry.path)
                if (readBack != SEALED_MODE) {
                    throw SealException(
                        SealFailure.VERIFY_FAILED,
                        "\"${entry.label}\" read back as ${octal(readBack)} after chmod 000",
                    )
                }
                sealed[sealed.lastIndex] = entry.copy(sealedMode = readBack)
            }
        } catch (failure: Throwable) {
            rollback(job, sealed)
            throw when (failure) {
                is SealException -> failure
                else -> SealException(
                    SealFailure.CHMOD_FAILED,
                    "chmod 000 failed: ${failure.message}",
                    failure,
                )
            }
        }

        val handle = SealHandle(job, sealedAtMs, sealed.toList(), targets.exclusions)
        synchronized(lock) {
            active = handle
            inflight = false
        }
        log(
            "build-seal: job \"$job\" sealed ${handle.protectedLabels} " +
                "(${sealed.filter { it.isSealed }.size} root(s) at 000)" +
                if (handle.isVacuous) "; no root existed, the seal protects nothing" else "",
        )
        return handle
    }

    /**
     * Restores every root to the mode the seal found, and deletes the marker.
     *
     * Idempotent: a handle that is already restored returns without touching a
     * mode. Every root is attempted even when an earlier one failed, because a
     * single failure must not leave the other roots sealed. A failed restore
     * keeps the handle active, so [seal] refuses a second job until an explicit
     * retry or [recoverIfNeeded] has restored every root.
     *
     * @throws SealException when any root could not be restored. The marker is
     *   kept in that case, so the next boot retries.
     */
    suspend fun restore(handle: SealHandle) {
        if (!handle.restored.compareAndSet(false, true)) {
            log("build-seal: job \"${handle.job}\" was already restored; nothing to do")
            return
        }
        val failures = mutableListOf<String>()
        val restoredModes = mutableListOf<String>()
        for (entry in handle.entries) {
            val original = entry.originalMode ?: continue
            try {
                val current = modes.read(entry.path)
                if (current == original) {
                    restoredModes.add("${entry.label}=${octal(original)} (unchanged)")
                    continue
                }
                selfEvents?.selfModeChange(entry.path)
                modes.write(entry.path, original)
                val readBack = modes.read(entry.path)
                if (readBack != original) {
                    failures.add("\"${entry.label}\" read back as ${octal(readBack)}, wanted ${octal(original)}")
                } else {
                    restoredModes.add("${entry.label}=${octal(original)}")
                }
            } catch (failure: IOException) {
                failures.add("\"${entry.label}\": ${failure.message}")
            }
        }

        if (failures.isNotEmpty()) {
            handle.restored.set(false)
            log("build-seal: restore FAILED for job \"${handle.job}\": ${failures.joinToString("; ")}")
            throw SealException(
                SealFailure.RESTORE_FAILED,
                "cannot restore ${failures.joinToString("; ")}; the marker is kept for the next boot",
            )
        }

        // Only a complete restore may release the active handle. A failed one
        // keeps it, so the same instance refuses to seal again (ALREADY_SEALED)
        // until the retry or the boot repair has actually put every root back.
        synchronized(lock) {
            if (active === handle) active = null
        }

        try {
            Files.deleteIfExists(markerPath)
            markerPath.parent?.let { parent ->
                if (Files.isDirectory(parent)) durability.fsyncPath(parent)
            }
        } catch (failure: IOException) {
            // The modes are right and the marker is idempotent, so a marker that
            // outlives this call only costs one extra no-op repair on the next
            // boot. Report it, do not fail the restore.
            log("build-seal: could not remove the marker: ${failure.message}")
        }
        log("build-seal: job \"${handle.job}\" restored ${restoredModes.joinToString(", ")}")
    }

    /**
     * Repairs a seal a dead process left behind, and deletes the marker.
     *
     * Must run before the workspace is opened on boot: a root at 000 would make
     * the first reconcile of `<workspace>/materialized/home` fail.
     *
     * Safe to call on every boot; it does nothing when there is no marker.
     */
    suspend fun recoverIfNeeded(): SealRecovery {
        if (!Files.exists(markerPath, LinkOption.NOFOLLOW_LINKS)) return SealRecovery.NothingToDo
        val marker = try {
            parseMarker(Files.readAllBytes(markerPath))
        } catch (failure: SealException) {
            // SealException extends IOException, so it has to be caught first or
            // the structured reason would be reported as a generic read failure.
            return SealRecovery.Failed(failure.detail, failure.failure)
        } catch (failure: IOException) {
            return SealRecovery.Failed("cannot read the seal marker: ${failure.message}", SealFailure.MARKER_UNREADABLE)
        }

        val repaired = mutableListOf<RecoveredRoot>()
        for (root in marker.roots) {
            if (!Files.isDirectory(root.path)) continue
            try {
                val before = modes.read(root.path)
                if (before != SEALED_MODE) {
                    repaired.add(RecoveredRoot(root.label, root.path, before, before))
                    continue
                }
                selfEvents?.selfModeChange(root.path)
                modes.write(root.path, root.originalMode)
                val after = modes.read(root.path)
                if (after != root.originalMode) {
                    return SealRecovery.Failed(
                        "root \"${root.label}\" read back as ${octal(after)} after recovery",
                        SealFailure.RESTORE_FAILED,
                    )
                }
                repaired.add(RecoveredRoot(root.label, root.path, before, after))
            } catch (failure: IOException) {
                return SealRecovery.Failed(
                    "cannot restore \"${root.label}\": ${failure.message}",
                    SealFailure.RESTORE_FAILED,
                )
            }
        }

        try {
            Files.deleteIfExists(markerPath)
            markerPath.parent?.let { parent ->
                if (Files.isDirectory(parent)) durability.fsyncPath(parent)
            }
        } catch (failure: IOException) {
            return SealRecovery.Failed("cannot remove the seal marker: ${failure.message}", SealFailure.RESTORE_FAILED)
        }
        // The repair has undone the failed seal's chmods, so the handle that
        // failed to restore must no longer block the next seal. Only a fully
        // successful repair reaches this point; a Failed recovery keeps it.
        synchronized(lock) { active = null }
        log(
            "build-seal: recovered job \"${marker.job}\" after a crash; " +
                "${repaired.filter { it.modeBefore != it.modeAfter }.size} root(s) put back",
        )
        return SealRecovery.Repaired(marker.job, marker.sealedAtMs, repaired.toList())
    }

    /** Best-effort rollback of a partial seal; keeps the marker when it fails. */
    private fun rollback(job: String, sealed: List<SealEntry>) {
        var clean = true
        for (entry in sealed) {
            val original = entry.originalMode ?: continue
            try {
                modes.write(entry.path, original)
            } catch (failure: IOException) {
                clean = false
                log("build-seal: rollback of \"${entry.label}\" failed: ${failure.message}")
            }
        }
        if (clean) {
            try {
                Files.deleteIfExists(markerPath)
            } catch (failure: IOException) {
                log("build-seal: could not remove the marker after a rollback: ${failure.message}")
            }
        } else {
            log("build-seal: rollback incomplete; the marker for job \"$job\" is kept")
        }
    }

    private suspend fun writeMarker(job: String, sealedAtMs: Long, entries: List<SealEntry>) {
        // A zero is the sealed state, never an original mode. Reaching this check
        // means a caller assembled an entry without going through sealLocked's
        // read-back guard; refuse it rather than write a line that would make
        // the next boot restore 000.
        val zeroMode = entries.firstOrNull { it.originalMode == SEALED_MODE }
        if (zeroMode != null) {
            throw SealException(
                SealFailure.VERIFY_FAILED,
                "refusing to record root \"${zeroMode.label}\" at ${octal(SEALED_MODE)} " +
                    "as its original mode; run the boot repair first",
            )
        }
        val text = buildString {
            append(MARKER_MAGIC).append(' ').append(MARKER_VERSION).append('\n')
            append("sealed_at_ms ").append(sealedAtMs).append('\n')
            append("job ").append(job).append('\n')
            for (entry in entries) {
                val original = entry.originalMode ?: continue
                append("root ").append(original).append(' ').append(entry.label)
                    .append(' ').append(entry.path.toAbsolutePath()).append('\n')
            }
        }
        val bytes = text.toByteArray(Charsets.UTF_8)
        try {
            durability.atomicReplace(markerPath) { temp -> Files.write(temp, bytes) }
        } catch (failure: IOException) {
            throw SealException(
                SealFailure.MARKER_FAILED,
                "cannot write the seal marker, so no chmod was attempted: ${failure.message}",
                failure,
            )
        }
        log("build-seal: marker written for job \"$job\" before any chmod")
    }

    private fun parseMarker(bytes: ByteArray): SealMarker {
        val lines = String(bytes, Charsets.UTF_8).lineSequence().filter { it.isNotEmpty() }.toList()
        val header = lines.firstOrNull()?.split(' ')
        if (header == null || header.size != 2 || header[0] != MARKER_MAGIC) {
            throw SealException(SealFailure.MARKER_UNREADABLE, "the seal marker has no magic line")
        }
        val version = header[1].toIntOrNull()
        if (version == null || version != MARKER_VERSION) {
            throw SealException(
                SealFailure.MARKER_UNREADABLE,
                "seal marker version $version is not $MARKER_VERSION",
            )
        }
        var sealedAtMs = 0L
        var job = ""
        val roots = mutableListOf<SealMarkerRoot>()
        for (line in lines.drop(1)) {
            val parts = line.split(' ', limit = 4)
            when (parts.firstOrNull()) {
                "sealed_at_ms" -> sealedAtMs = parts.getOrNull(1)?.toLongOrNull()
                    ?: throw SealException(SealFailure.MARKER_UNREADABLE, "bad sealed_at_ms")
                "job" -> job = line.removePrefix("job ")
                "root" -> {
                    val mode = parts.getOrNull(1)?.toIntOrNull()
                        ?: throw SealException(SealFailure.MARKER_UNREADABLE, "bad root mode")
                    val label = parts.getOrNull(2)
                        ?: throw SealException(SealFailure.MARKER_UNREADABLE, "bad root label")
                    val path = parts.getOrNull(3)
                        ?: throw SealException(SealFailure.MARKER_UNREADABLE, "bad root path")
                    roots.add(SealMarkerRoot(label, Path.of(path), mode))
                }
                else -> throw SealException(
                    SealFailure.MARKER_UNREADABLE,
                    "unknown seal marker line \"${parts.firstOrNull()}\"",
                )
            }
        }
        return SealMarker(job, sealedAtMs, roots)
    }

    private class SealMarker(
        val job: String,
        val sealedAtMs: Long,
        val roots: List<SealMarkerRoot>,
    )

    private class SealMarkerRoot(val label: String, val path: Path, val originalMode: Int)

    companion object {
        /** The `chmod 000` value: no owner, group or other bit. */
        const val SEALED_MODE: Int = 0

        /** The marker file name, kept beside the roots instead of inside one. */
        const val MARKER_NAME: String = ".build-seal.lock"

        private const val MARKER_MAGIC = "pdsh-build-seal"
        private const val MARKER_VERSION = 1

        /** Formats [mode] the way `chmod` and `ls` do, for logs and failures. */
        fun octal(mode: Int): String = "0" + Integer.toOctalString(mode and 0xFFF)
    }
}

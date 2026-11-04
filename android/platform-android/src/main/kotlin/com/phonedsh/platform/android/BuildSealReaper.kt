// The process-tree reaper: "use it and throw it away" means a process group, not a pid.
// SPDX-License-Identifier: MIT
//
// ---- why killing the direct child is not closing --------------------------
// Plan §5.1.1: proot has no PID namespace, so a background process a makefile
// forked survives the job's direct child exiting. Killing the pid we spawned
// therefore proves nothing about the window: the guest is still running, still
// holding the seal open, and still able to read. The enforcement point is the
// **process tree**, so closing is:
//
//   1. kill the whole process group of every root pid (the echo adapter starts
//      its job through `setsid`, so the root pid *is* the group leader);
//   2. kill every descendant found by walking `/proc` parent links, which also
//      covers a root that ended up in this app's own group;
//   3. take a fresh `/proc` snapshot and report every same-UID process that is
//      not us and not one of the pids above -- then `kill -9` each of them,
//      because a residual process is exactly the thing that must not survive;
//   4. snapshot once more: anything still alive is reported as unkillable.
//
// Step 4 is the honest half. A report that says "0 residual" without looking
// again would be the same kind of lie the N1 evidence caught.
//
// ---- the group kill is why `setsid` is in the launch path -----------------
// Android's `ProcessBuilder` does not put the child in a new process group, so
// `kill(-pgid)` on an arbitrary child could kill *this app*. The reaper
// therefore refuses to signal a group that is this process's own group, and the
// job launcher (`ShellJobLauncher`) uses `setsid` so the job gets a group of
// its own. The refusal is a safety property, not a fallback: the tree walk in
// step 2 still reaches the children.
//
// ---- /proc is the seam ----------------------------------------------------
// [ProcTable] is an interface so the host JVM suite can hand the reaper a fake
// `/proc` and assert the kill order; [ProcfsTable] is the real one and the
// device suite (`BuildSealReaperDeviceTest`) proves it against live processes.

package com.phonedsh.platform.android

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path

/**
 * One process, as `/proc` describes it.
 *
 * @property pid the process id.
 * @property ppid the parent process id.
 * @property pgrp the process group id (from `/proc/<pid>/stat` field 5).
 * @property uid the real uid (from `/proc/<pid>/status`'s `Uid:` line).
 * @property name the `comm` name, for the report only.
 * @property state the single-letter state from `/proc/<pid>/stat`; `Z` is a
 *   zombie. A zombie has already exited and can read nothing, so it is never a
 *   residual process -- counting one would make a clean close look dirty for as
 *   long as init takes to reap it.
 */
data class ProcEntry(
    val pid: Int,
    val ppid: Int,
    val pgrp: Int,
    val uid: Int,
    val name: String,
    val state: Char = 'S',
) {
    /** `true` when the process has exited and only its exit status remains. */
    val isZombie: Boolean get() = state == 'Z'
}

/** A snapshot of `/proc`, as a seam. */
fun interface ProcTable {
    /** Every process the caller could read, in any order. */
    fun entries(): List<ProcEntry>
}

/**
 * The real `/proc` reader.
 *
 * A process that disappears between the listing and the read is normal (it is
 * exactly what a reap looks like), so every read failure skips that pid
 * instead of failing the snapshot.
 *
 * @param procRoot the mount point, injectable so a test can point elsewhere
 *   even though the production value is the only one that matters.
 */
class ProcfsTable(private val procRoot: Path = Path.of("/proc")) : ProcTable {

    override fun entries(): List<ProcEntry> {
        val directory = procRoot.toFile()
        val names = directory.list() ?: return emptyList()
        val entries = ArrayList<ProcEntry>(names.size)
        for (name in names) {
            val pid = name.toIntOrNull() ?: continue
            if (pid <= 0) continue
            val entry = entryOf(pid) ?: continue
            entries.add(entry)
        }
        return entries
    }

    /** The uid of one pid, or `-1` when it cannot be read. */
    fun uidOf(pid: Int): Int {
        val status = readOrNull(procRoot.resolve(pid.toString()).resolve("status")) ?: return -1
        for (line in status.lineSequence()) {
            if (!line.startsWith("Uid:")) continue
            // `/proc/<pid>/status` separates its fields with TABS, not spaces;
            // splitting on a space returns the whole "10208<TAB>10208<TAB>..."
            // string and the uid quietly becomes -1 (a real device bug: it made
            // every same-UID process look like a stranger, and the residual scan
            // found nothing).
            return line.removePrefix("Uid:").trim().split(' ', '\t').firstOrNull()?.toIntOrNull()
                ?: -1
        }
        return -1
    }

    /** The process group of one pid, or `-1` when it cannot be read. */
    fun pgrpOf(pid: Int): Int {
        val stat = readOrNull(procRoot.resolve(pid.toString()).resolve("stat")) ?: return -1
        return parseStat(pid, stat, uid = -1)?.pgrp ?: -1
    }

    private fun entryOf(pid: Int): ProcEntry? {
        val stat = readOrNull(procRoot.resolve(pid.toString()).resolve("stat")) ?: return null
        val parsed = parseStat(pid, stat, uid = uidOf(pid)) ?: return null
        return parsed
    }

    /**
     * Parses `/proc/<pid>/stat`.
     *
     * The `comm` field is parenthesised and may itself contain spaces or `)`,
     * so the split happens at the **last** `)`; from there the fields are
     * positional: state, ppid, pgrp, session, and so on.
     */
    private fun parseStat(pid: Int, text: String, uid: Int): ProcEntry? {
        val close = text.lastIndexOf(')')
        if (close <= 0 || close + 2 >= text.length) return null
        val name = text.substring(0, close).substringAfter('(', "")
        val fields = text.substring(close + 2).split(' ')
        val state = fields.getOrNull(0)?.firstOrNull() ?: 'S'
        val ppid = fields.getOrNull(1)?.toIntOrNull() ?: return null
        val pgrp = fields.getOrNull(2)?.toIntOrNull() ?: return null
        return ProcEntry(pid, ppid, pgrp, uid, name, state)
    }

    private fun readOrNull(path: Path): String? = try {
        if (Files.isRegularFile(path)) String(Files.readAllBytes(path), Charsets.UTF_8) else null
    } catch (ignored: IOException) {
        null
    }
}

/** Sends one signal; a seam, because `android.system.Os` is a stub on the host JVM. */
fun interface SignalSender {
    /** @throws IOException when the signal could not be delivered. */
    fun send(pid: Int, signal: Int)
}

/** [SignalSender] over `android.system.Os.kill`, which is `kill(2)` with a JNI wrapper. */
object OsSignalSender : SignalSender {
    override fun send(pid: Int, signal: Int) {
        android.system.Os.kill(pid, signal)
    }
}

/**
 * What one close found.
 *
 * @property tree every descendant pid the walk found, killed in pid order.
 * @property groups the process groups the reaper signalled with one `kill(-pgid)`.
 * @property skippedGroups group ids it refused to signal, because they are this
 *   process's own group (signalling one would kill the app).
 * @property survivors same-UID processes that were still alive after the group
 *   and tree kills -- the residual processes the contract has to report.
 * @property killedSurvivors which of [survivors] the `kill -9` reached.
 * @property unkillable survivors still alive on the final snapshot.
 * @property errors human-readable delivery failures, never fatal on their own.
 */
data class HarvestReport(
    val tree: List<Int>,
    val groups: List<Int>,
    val skippedGroups: List<Int>,
    val survivors: List<Int>,
    val killedSurvivors: List<Int>,
    val unkillable: List<Int>,
    val errors: List<String>,
) {
    /**
     * `true` when nothing outside this process survived the close.
     *
     * A survivor that the `kill -9` reached is not a survivor any more, so the
     * test is [unkillable] -- the second snapshot -- rather than "was a residual
     * found", which would report a clean close as dirty forever.
     */
    val clean: Boolean get() = unkillable.isEmpty() && survivors.all { it in killedSurvivors }
}

/**
 * Reaps one app UID's guest process tree.
 *
 * @param uid the app's uid; only processes with this uid are candidate
 *   survivors. Injected so the JVM suite can use an arbitrary number.
 * @param selfPid this process; never a survivor and never signalled.
 * @param selfPgrp this process's group; never signalled as a group.
 * @param table the `/proc` seam.
 * @param signal the signal seam.
 * @param protected pids that are allowed to share the uid (none on this app:
 *   the device evidence is one process per uid, but a future WebView child would
 *   have to be added here rather than discovered by the reaper).
 */
class ProcessTreeReaper(
    private val uid: Int,
    private val selfPid: Int,
    private val selfPgrp: Int,
    private val table: ProcTable,
    private val signal: SignalSender,
    private val protected: Set<Int> = emptySet(),
    private val settleMs: Long = DEFAULT_SETTLE_MS,
) {
    /**
     * Kills [rootPids]' groups and descendants, reports and kills the residual
     * same-UID processes, and reports what it could not kill.
     *
     * [knownGroups] exists because the job's root pid is usually **gone** by the
     * time the close runs: after `sh -c 'make &'` exits, `/proc/<pid>` no longer
     * exists, so the process group cannot be looked up from the tree walk. The
     * launcher knows the group it created (see `ShellJobLauncher`, which uses
     * `setsid`), so it hands it over instead of the reaper guessing from a pid
     * that may already have been reused.
     *
     * Never throws: a close that cannot reap is a report, and the caller still
     * has to restore the seal. Failures land in [HarvestReport.errors].
     *
     * @param rootPids the pids the job was started as.
     * @param knownGroups process groups to kill even when the pid is gone.
     */
    fun harvest(rootPids: List<Int>, knownGroups: List<Int> = emptyList()): HarvestReport {
        val errors = mutableListOf<String>()
        val before = try {
            table.entries()
        } catch (failure: Throwable) {
            errors.add("cannot read /proc: ${failure.message}")
            emptyList()
        }
        val byPid = before.associateBy { it.pid }
        val children = before.groupBy { it.ppid }

        val tree = LinkedHashSet<Int>()
        val queue = ArrayDeque(rootPids)
        while (queue.isNotEmpty()) {
            val pid = queue.removeFirst()
            if (!tree.add(pid)) continue
            for (child in children[pid].orEmpty()) {
                if (!tree.contains(child.pid)) queue.addLast(child.pid)
            }
        }

        val groups = mutableListOf<Int>()
        val skippedGroups = mutableListOf<Int>()
        val candidates = LinkedHashSet<Int>()
        for (group in knownGroups) candidates.add(group)
        for (root in rootPids) {
            val group = byPid[root]?.pgrp ?: -1
            if (group > 1) candidates.add(group)
        }
        for (group in candidates) {
            if (group <= 1) continue
            if (group == selfPgrp) {
                if (!skippedGroups.contains(group)) skippedGroups.add(group)
                continue
            }
            groups.add(group)
            // The group first: it reaches a background fork whose parent has
            // already exited and been reparented away from the tree walk.
            send(-group, "group $group", errors)
        }
        for (pid in tree) {
            if (pid == selfPid) continue
            send(pid, "pid $pid", errors)
        }

        val afterKill = snapshot(errors)
        val survivors = afterKill
            .filter { it.uid == uid && !it.isZombie }
            .filter { it.pid != selfPid && it.pid !in protected && it.pid != 1 }
            .filter { !tree.contains(it.pid) }
            .map { it.pid }
        val killedSurvivors = mutableListOf<Int>()
        for (pid in survivors) {
            if (send(pid, "residual $pid", errors)) killedSurvivors.add(pid)
        }

        // Only a survivor that is *still there* after the kill -9 counts as
        // unkillable; asking the same question again is what makes the "0
        // residual" line a fact instead of an assumption. The wait is not
        // politeness: SIGKILL delivery and process teardown are asynchronous, so
        // an immediate re-read calls a just-killed process unkillable.
        if (survivors.isNotEmpty()) settle(survivors)
        val finalSnapshot = if (survivors.isEmpty()) afterKill else snapshot(errors)
        val unkillable = finalSnapshot
            .filter { it.uid == uid && !it.isZombie }
            .filter { it.pid != selfPid && it.pid !in protected && it.pid != 1 }
            .filter { survivors.contains(it.pid) }
            .map { it.pid }

        return HarvestReport(
            tree = tree.toList(),
            groups = groups,
            skippedGroups = skippedGroups,
            survivors = survivors,
            killedSurvivors = killedSurvivors,
            unkillable = unkillable,
            errors = errors,
        )
    }

    /** Waits up to [settleMs] for the signalled survivors to leave `/proc`. */
    private fun settle(survivors: List<Int>) {
        if (settleMs <= 0L) return
        val deadline = System.currentTimeMillis() + settleMs
        while (System.currentTimeMillis() < deadline) {
            val alive = try {
                table.entries().map { it.pid }.toSet()
            } catch (ignored: Throwable) {
                return
            }
            if (survivors.none { it in alive }) return
            Thread.sleep(SETTLE_STEP_MS)
        }
    }

    private fun snapshot(errors: MutableList<String>): List<ProcEntry> = try {
        table.entries()
    } catch (failure: Throwable) {
        errors.add("cannot re-read /proc: ${failure.message}")
        emptyList()
    }

    /**
     * Sends one `SIGKILL`.
     *
     * @return `true` when the target is gone afterwards, which includes the
     *   `ESRCH` race: a process that exited between the snapshot and the signal
     *   is gone, and counting it as a failed kill would report a clean close as
     *   dirty. A real delivery failure is reported and returns `false`.
     */
    private fun send(pid: Int, what: String, errors: MutableList<String>): Boolean {
        return try {
            signal.send(pid, SIGKILL)
            true
        } catch (failure: Throwable) {
            // ESRCH is the expected race; anything else is worth reporting but
            // never fatal, because the seal still has to be restored.
            val message = failure.message.orEmpty()
            if (message.contains("No such process")) {
                true
            } else {
                errors.add("$what: $message")
                false
            }
        }
    }

    companion object {
        /** `SIGKILL`, from `signal(7)`. The close path does not ask politely. */
        const val SIGKILL: Int = 9

        /** How long a killed survivor gets to leave `/proc` before it is "unkillable". */
        const val DEFAULT_SETTLE_MS: Long = 300L

        private const val SETTLE_STEP_MS: Long = 20L
    }
}

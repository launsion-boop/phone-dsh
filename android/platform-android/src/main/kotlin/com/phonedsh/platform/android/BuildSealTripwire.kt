// The build-seal tripwire: a FileObserver audit of the sealed roots.
// SPDX-License-Identifier: MIT
//
// ---- what this is for ------------------------------------------------------
// The seal (`BuildSeal.kt`) is a speed bump, not a wall: the guest shares this
// app's UID, so it can chmod a root back and read it. Plan §3 layer 4 accepts
// that and buys the only thing left to buy -- **the bypass leaves a trace**. A
// job's `ubuntu.status` carries `internalAccessObserved`, and the consent
// surface tells the user "during this job, the internal state was accessed".
//
// The watch is on `/dsh/home` (the parent of the three roots), because the act
// that has to be caught is a `chmod` **on a root**: inotify reports a child's
// `IN_ATTRIB` to a watch on its parent, so `chmod 755 sessions` arrives as
// `IN_ATTRIB` with `path = "sessions"`.
//
// ---- the two limits, stated rather than hidden ----------------------------
//   * inotify is not a security mechanism: it can drop events when the queue
//     overflows, it does not report a failed `open()` (EACCES on a 000 mode is
//     silent, because the call never opened anything), and a recursive read is
//     only visible at the level the watch sits on. So `observed == false` means
//     "nothing was seen", never "nothing happened". This is the §2 claim
//     ("we make it leave a trace"), not a stronger one.
//   * the seal's own chmods are excused. `SealSelfEvents` announces them and
//     [BuildSealTripwire] drops exactly one matching `IN_ATTRIB` per
//     announcement. A guest `chmod` that lands inside that window would be
//     excused too — and the window is [EXCUSE_WINDOW_MS] (2 s), **not** the
//     "one syscall" this comment used to claim: a guest that chmods the same
//     root within two seconds of the seal's own chmod is silently excused.
//     An independent audit measured the 2000 ms constant against this comment
//     and called the three-orders-of-magnitude gap out; the alternative (never
//     arming around a seal) leaves a bigger hole, so the window stays and the
//     cost is now stated instead of denied.
//
// `IN_ATTRIB` is the load-bearing event: it is what `chmod` produces, so it is
// the "deliberate act" half of the design. `IN_OPEN` is the read half; it is
// only reported for an open that succeeded, which after a bypass is exactly the
// case worth reporting.

package com.phonedsh.platform.android

import java.nio.file.Path

/** What one observed event names. */
enum class AccessKind {
    /** `IN_OPEN`: something opened an entry in the watched directory. */
    OPEN,

    /** `IN_ATTRIB`: something changed the mode of an entry -- `chmod` lands here. */
    ATTRIB,

    /** Any other bit the watch delivered; kept so an unexpected mask is not lost. */
    OTHER,
}

/**
 * One event the watch delivered.
 *
 * @property name the entry name relative to the watched directory, or `null`
 *   when inotify reported the directory itself.
 * @property kind the decoded meaning.
 * @property mask the raw inotify mask, for the log and for the audit record.
 * @property atMs when the app observed it.
 */
data class ObservedAccess(
    val name: String?,
    val kind: AccessKind,
    val mask: Int,
    val atMs: Long,
)

/**
 * The audit of one job.
 *
 * @property armed whether a watch was live for the whole job.
 * @property observed the value that goes into `ubuntu.status`: `true` when any
 *   access was seen. `false` means "nothing was seen", never "nothing happened".
 * @property events the events, oldest first, capped at
 *   [BuildSealTripwire.MAX_EVENTS].
 * @property dropped how many events were discarded by the cap.
 * @property excused how many of the seal's own chmods were filtered out.
 */
data class TripwireReport(
    val armed: Boolean,
    val observed: Boolean,
    val events: List<ObservedAccess>,
    val dropped: Int,
    val excused: Int,
)

/**
 * The tripwire's bookkeeping. Not tied to Android, so the host JVM suite can
 * drive it with [record] directly and the device suite drives it through the
 * real `FileObserver` in [`FileObserverTripwireSource`].
 *
 * @param nowMs the clock seam.
 * @param maxEvents the event cap; a job that opens every session file must not
 *   grow an unbounded list in the host's memory.
 */
class BuildSealTripwire(
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val maxEvents: Int = MAX_EVENTS,
) : SealSelfEvents {
    private val lock = Any()

    private val events = ArrayDeque<ObservedAccess>()

    /** File names the seal is about to chmod itself, with the excuse deadline. */
    private val expected = ArrayDeque<ExpectedAttrib>()

    private var armed: Boolean = false
    private var dropped: Int = 0
    private var excused: Int = 0
    private var seen: Boolean = false

    /** `true` while a job's audit window is open. */
    fun isArmed(): Boolean = synchronized(lock) { armed }

    /** Opens the audit window; any event recorded after this belongs to the job. */
    fun begin() {
        synchronized(lock) {
            events.clear()
            expected.clear()
            dropped = 0
            excused = 0
            seen = false
            armed = true
        }
    }

    /**
     * Records one inotify event.
     *
     * Called by the `FileObserver` callback, on the observer's thread. Ignored
     * while no job is running, because an event outside a job has no job to
     * attribute it to and [begin] resets the window anyway.
     *
     * @param name the entry name relative to the watched directory, or `null`.
     * @param mask the raw inotify mask.
     */
    fun record(name: String?, mask: Int) {
        val kind = kindOf(mask)
        synchronized(lock) {
            if (!armed) return
            if (kind == AccessKind.ATTRIB && excuseLocked(name)) return
            seen = true
            if (events.size >= maxEvents) {
                events.removeFirst()
                dropped += 1
            }
            events.addLast(ObservedAccess(name, kind, mask, nowMs()))
        }
    }

    /**
     * The events recorded so far in the open window.
     *
     * A snapshot, for a caller that has to poll: inotify delivery is
     * asynchronous, so a device test has to wait for the event to arrive before
     * it closes the window.
     */
    fun pendingEvents(): List<ObservedAccess> = synchronized(lock) { events.toList() }

    /** `true` when at least one access has been recorded in the open window. */
    fun observedSoFar(): Boolean = synchronized(lock) { seen }

    /**
     * The same verdict under the name the job record and `ubuntu.status` use
     * (`bridge.md` §12.8's `internalAccessObserved`).
     *
     * An alias rather than a second field: two names for one fact cannot drift,
     * and the caller that writes the audit status does not have to know which
     * class owns the window.
     */
    val internalAccessObserved: Boolean get() = observedSoFar()

    /**
     * Closes the audit window and returns what the job saw.
     *
     * The window is consumed: a second [end] reports an unarmed, empty audit
     * rather than handing back the first job's events under the second job's
     * name.
     */
    fun end(): TripwireReport = synchronized(lock) {
        val report = TripwireReport(
            armed = armed,
            observed = seen,
            events = events.toList(),
            dropped = dropped,
            excused = excused,
        )
        armed = false
        events.clear()
        expected.clear()
        seen = false
        dropped = 0
        excused = 0
        report
    }

    /**
     * Announces one of the seal's own `chmod`s so its `IN_ATTRIB` is not counted
     * as an access.
     *
     * Keyed by file name, because that is all inotify hands the observer. The
     * excuse expires after [EXCUSE_WINDOW_MS], so an announcement whose event
     * never arrives cannot swallow a later, real one.
     */
    override fun selfModeChange(path: Path) {
        val name = path.fileName?.toString() ?: return
        synchronized(lock) {
            val now = nowMs()
            pruneExpectedLocked(now)
            expected.addLast(ExpectedAttrib(name, now + EXCUSE_WINDOW_MS))
        }
    }

    private fun excuseLocked(name: String?): Boolean {
        if (name == null) return false
        val now = nowMs()
        pruneExpectedLocked(now)
        val head = expected.firstOrNull() ?: return false
        // inotify delivers in cause order, so the oldest announcement is the one
        // this event belongs to. Anything else is a real access.
        if (head.name != name) return false
        expected.removeFirst()
        excused += 1
        return true
    }

    private fun pruneExpectedLocked(now: Long) {
        while (true) {
            val head = expected.firstOrNull() ?: return
            if (head.deadlineMs >= now) return
            expected.removeFirst()
        }
    }

    private class ExpectedAttrib(val name: String, val deadlineMs: Long)

    companion object {
        /** inotify masks, from `inotify(7)`. Spelled out so minSdk 26 compiles. */
        const val IN_ATTRIB: Int = 0x00000004
        const val IN_OPEN: Int = 0x00000020

        /** The event cap: enough to show a pattern, bounded so memory is not. */
        const val MAX_EVENTS: Int = 32

        /** How long a self-chmod announcement waits for its event. */
        const val EXCUSE_WINDOW_MS: Long = 2_000L

        /** The mask one watch subscribes to: the deliberate act plus the read. */
        const val WATCH_MASK: Int = IN_ATTRIB or IN_OPEN

        /** Decodes the raw mask the way [ObservedAccess.kind] documents. */
        fun kindOf(mask: Int): AccessKind = when {
            mask and IN_ATTRIB != 0 -> AccessKind.ATTRIB
            mask and IN_OPEN != 0 -> AccessKind.OPEN
            else -> AccessKind.OTHER
        }
    }
}

// phone-dsh — :dsh / com.phonedsh.dsh.host: a failed durable write -> D14 Failed.
// SPDX-License-Identifier: MIT
//
// ---- the gap this file closes ---------------------------------------------
// [VfsSink.append] and the journal lane both used to log an append failure,
// close the transport and rethrow. Nothing told the controller, so the host
// stayed `Running` with admission open while its durable store refused every
// write: a worker could keep sending side effects and the user saw no failure.
// budgets.md §2 makes this a fail-loud condition ("quota still exceeded after
// compaction", "materialization I/O failure", "unrecoverable host defect"), and
// §5 says the same for the WAL and journal quota rows ("still over → Failed").
// This file is the one mapping from the stores' stable codes onto the closed
// `ControllerFailure` vocabulary, plus the callback the two writers use to reach
// the facade. The state machine itself is `:controller`'s; this file never
// invents a reason and never writes a state.
//
// The journal store and its sink live in `:dsh/journal`, so they are not edited
// here: [HostChannel] owns the JOURNAL dispatch and reports the sink's
// host-side `JournalException` through the same callback. One callback, two
// writers, one mapping.
//
// ---- what stays transport-level -------------------------------------------
// A *protocol* violation (a malformed frame, a forward jseq gap, a bad seq) is
// answered with one closing `ERROR` and is not a host failure: it never reaches
// this mapping. Only an append or epoch close that the store itself refused or
// could not perform is reported here, and the caller still rethrows so the
// transport closes: fail loud, never a silent retry.
//
// ---- the closed vocabulary ------------------------------------------------
// `ControllerFailure` has six members and lives in `:controller`, a lane this
// one may not edit. The mapping below therefore chooses the nearest member for
// the journal codes instead of adding a `JOURNAL_*` member. `JOURNAL_IO`,
// `JOURNAL_CORRUPT` and a closed store are host-side durable-store defects and
// map to [ControllerFailure.HOST_DEFECT]; the journal quota row maps to
// [ControllerFailure.QUOTA_EXCEEDED], the same member the WAL quota uses. That
// choice is reported as a gap rather than hidden: a future `:controller`
// revision may want `JOURNAL_IO` spelled out.

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerFailure
import com.phonedsh.dsh.journal.JournalException
import com.phonedsh.dsh.journal.JournalFailure
import com.phonedsh.log.LogException
import com.phonedsh.log.LogFailure
import com.phonedsh.wire.WalException
import kotlinx.coroutines.CancellationException

/**
 * The facade's write-failure surface.
 *
 * A sink reports one durable write that did not happen; the facade turns the
 * report into `ControllerSignal.FailureRaised`, which closes admission and moves
 * the D14 state to `Failed`. The report is not an exception channel: the store's
 * exception still propagates to the transport owner, so "record the failure" and
 * "stop the connection" both happen and neither hides the other.
 *
 * Two implementations exist: the facade's lambda (wired to the controller) and
 * [None] for a sink constructed without one (unit tests of the sink itself).
 */
fun interface WriteFailureSink {
    /** Records one failed durable write; [detail] is token-free by construction. */
    fun report(reason: ControllerFailure, detail: String)

    companion object {
        /** A sink that drops the report; used when no controller is attached. */
        val None: WriteFailureSink = WriteFailureSink { _, _ -> }
    }
}

/**
 * Reports a failure without letting the report itself break the store's
 * fail-loud path.
 *
 * The caller is about to rethrow the store's exception. If the notification
 * surface threw first, that original failure would be replaced by an unrelated
 * one, so the report is best-effort: a throwing report is logged and the store
 * exception remains the one the transport sees.
 *
 * @param logger the token-free log seam of the caller.
 */
internal fun WriteFailureSink.reportQuietly(
    reason: ControllerFailure,
    detail: String,
    logger: HostLog,
) {
    try {
        report(reason, detail)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (reportFailure: Exception) {
        logger.error(
            "recording ${reason.code} threw ${reportFailure.javaClass.simpleName}; " +
                "the store failure is still rethrown",
        )
    }
}

/**
 * One attributable store failure: the D14 reason plus the store's stable code.
 *
 * [code] is used only in the log line and the `FailureRaised` detail, both of
 * which are token-free: the codes are compile-time constants, never an exception
 * message, a path or a record byte.
 */
internal data class HostWriteFailure(
    val reason: ControllerFailure,
    val code: String,
)

/**
 * The one mapping from store codes to `ControllerFailure`.
 *
 * A `null` result means "not attributable to a durable-store condition": the
 * caller keeps its pre-existing behavior (log and rethrow) and the host does
 * **not** enter `Failed`. That is the deliberate answer for a plain
 * `IOException` escaping the seam, which is not one of the documented failure
 * types, and for `WAL_NOT_READY`, whose only real cause is a caller bug that
 * the sink's open gate already prevents.
 */
internal object HostFailureRules {
    /**
     * The WAL append/epoch-close codes of `wal.md` §5, §5.1 and §9.
     *
     * `LogException` is the log package's host-side failure type (segment and
     * materialization I/O, quota, a closed log); `WalException` carries the
     * Rust kernel's own codes. Structural `WalException`s (`BAD_PATH`,
     * `BAD_PAYLOAD`) can only come from a body the VFS decoder already
     * validated, so none of them is mapped here.
     */
    fun wal(error: Throwable): HostWriteFailure? = when (error) {
        is WalException -> when (error.code) {
            WAL_CORRUPT -> HostWriteFailure(ControllerFailure.WAL_CORRUPT, error.code)
            else -> null
        }

        is LogException -> when (error.failure) {
            // budgets.md §5 WAL row: compaction already ran and the quota is
            // still exceeded, so the append is the fail-loud point.
            LogFailure.QUOTA_EXCEEDED ->
                HostWriteFailure(ControllerFailure.QUOTA_EXCEEDED, error.failure.code)

            // budgets.md §2: "materialization I/O failure" is an any-state
            // Failed condition with its own member.
            LogFailure.MATERIALIZATION_FAILED ->
                HostWriteFailure(ControllerFailure.MATERIALIZATION_IO, error.failure.code)

            // budgets.md §2: "unrepaired base mismatch at an epoch close".
            LogFailure.RESYNC_UNREPAIRED ->
                HostWriteFailure(ControllerFailure.UNREPAIRED_BASE_MISMATCH, error.failure.code)

            // The log package documents segment/directory/reconcile I/O and a
            // closed log as host defects that close admission; there is no more
            // specific member in the closed vocabulary.
            LogFailure.SEGMENT_IO,
            LogFailure.WAL_DIRECTORY_IO,
            LogFailure.RECONCILE_FAILED,
            LogFailure.CLOSED,
            -> HostWriteFailure(ControllerFailure.HOST_DEFECT, error.failure.code)

            // A call before recovery completed is a caller bug the sink's open
            // gate already prevents; do not turn a spurious one into Failed.
            LogFailure.NOT_READY -> null
        }

        else -> null
    }

    /**
     * The journal codes of budgets.md §5 and `journal/JournalFailure`.
     *
     * The channel calls this only for a `JournalException` whose `wireCode` is
     * `null`; a non-null wire code is a §10 protocol error and keeps the
     * existing one-closing-ERROR path, never `Failed`.
     */
    fun journal(error: JournalException): HostWriteFailure? = when (error.failure) {
        // budgets.md §5 journal row: the 64 MiB quota is over and nothing
        // journaled and durable could be pruned.
        JournalFailure.QUOTA_EXCEEDED ->
            HostWriteFailure(ControllerFailure.QUOTA_EXCEEDED, error.failure.code)

        // Host-side durable-store defects: an unreadable/unwritable file, a
        // file that is not this host's journal, or a store a prior defect
        // already closed. The closed vocabulary has no journal-specific member.
        JournalFailure.IO,
        JournalFailure.CORRUPT,
        JournalFailure.CLOSED,
        -> HostWriteFailure(ControllerFailure.HOST_DEFECT, error.failure.code)

        // A malformed frame is a protocol error and carries a wire code; the
        // channel's ERROR path stays the only answer. NOT_READY is a gate race
        // the dispatch already excludes (isOpen was checked), not a durable
        // failure.
        JournalFailure.PROTOCOL,
        JournalFailure.NOT_READY,
        -> null
    }

    /** `wal.md` §10 / `pdsh_wal`: the one code that means impossible bytes. */
    private const val WAL_CORRUPT: String = "WAL_CORRUPT"
}

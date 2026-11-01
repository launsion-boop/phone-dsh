// phone-dsh — :dsh / com.phonedsh.dsh.journal: the journal store's failures.
// SPDX-License-Identifier: MIT
//
// ---- the shape, borrowed from :core's log package -------------------------
// `:core/log/LogException` separates "the bytes are impossible" from "the host
// could not write them" and carries one stable code per kind. The journal is an
// independent store, so it must not borrow the WAL's codes: a caller that sees
// JOURNAL_QUOTA_EXCEEDED knows the journal row of budgets.md §5 was hit, not a
// WAL segment. The detail is workspace-relative and token-free, exactly like
// LogException.detail.
//
// ---- the one wire code -----------------------------------------------------
// A malformed JOURNAL frame is a `channel.md` §10 protocol error, and the host
// answers it with the one `ERROR` (`0x7F`) frame. [wireCode] carries that code
// for the channel to send; every host-side failure leaves it `null`, because
// §10 defines no code for "the host could not persist your record" and
// inventing one would blame the worker for a host defect.

package com.phonedsh.dsh.journal

/**
 * One journal failure, typed by [failure].
 *
 * @property failure the kind of failure and its stable code.
 * @property detail a workspace-relative explanation; never an absolute path,
 *   never a record byte and never a token.
 * @property wireCode the `channel.md` §10 code to put in an `ERROR` frame, or
 *   `null` when the failure is host-side and the transport must close without
 *   a protocol ERROR (the `VfsSink` append failure takes the same route).
 * @param cause the I/O or codec failure underneath, when there is one.
 */
class JournalException(
    val failure: JournalFailure,
    val detail: String,
    val wireCode: String? = null,
    cause: Throwable? = null,
) : RuntimeException("${failure.code}: $detail", cause)

/**
 * The journal failures this host can report.
 *
 * The codes are the store's vocabulary, not the WAL's: they appear in log lines
 * and in tests, and the controller maps [QUOTA_EXCEEDED] and [CORRUPT] onto the
 * D14 `Failed` state (closing admission, keeping every durable byte). That
 * mapping is deliberately outside this package: the store reports, it does not
 * drive the host state machine.
 */
enum class JournalFailure(val code: String) {
    /**
     * The inbound frame is not a legal `JOURNAL` (§3.5, §6): the codec refused
     * the bytes, the session id is not D6, or `jseq` is a forward gap. Always
     * paired with a non-null [JournalException.wireCode].
     */
    PROTOCOL("JOURNAL_PROTOCOL"),

    /** The journal directory or one of its files cannot be read or written. */
    IO("JOURNAL_IO"),

    /**
     * A retained file is not a journal this host wrote: bad magic, a session id
     * that disagrees with the file name, or a corrupt record in the middle of a
     * file. A torn *tail* is not this failure; recovery truncates it.
     */
    CORRUPT("JOURNAL_CORRUPT"),

    /**
     * budgets.md §5: the 64 MiB journal quota is exceeded and nothing is
     * journaled and durable enough to prune. The record is not written.
     */
    QUOTA_EXCEEDED("JOURNAL_QUOTA_EXCEEDED"),

    /** [JournalStore.recover] has not completed; no append is accepted. */
    NOT_READY("JOURNAL_NOT_READY"),

    /** A prior host defect closed the store; no further write is accepted. */
    CLOSED("JOURNAL_CLOSED"),
}

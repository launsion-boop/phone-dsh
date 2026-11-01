// The host-defect error of the log package, plus the WAL code it carries.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

/**
 * The host-side failures that are not a `pdsh_wal` diagnostic.
 *
 * The Rust kernel reports format and plan failures as `WAL_CORRUPT`,
 * `WAL_MANIFEST_INVALID` and friends, and [com.phonedsh.wire.NativeWal] turns
 * those into [com.phonedsh.wire.WalException]. This type is for the other half
 * of the package — the I/O that the kernel deliberately does not perform:
 * materialization, a segment write, a truncation, a staging exchange. Keeping it
 * separate means a caller can tell "the WAL bytes are impossible"
 * ([com.phonedsh.wire.WalException]) from "the host could not write them"
 * ([LogException]), which is exactly the D8 distinction between a protocol
 * failure and a host defect.
 *
 * @property failure the kind of host failure.
 * @property detail a workspace-relative explanation; never an absolute path.
 */
class LogException(
    val failure: LogFailure,
    val detail: String,
    cause: Throwable? = null,
) : RuntimeException("${failure.code}: $detail", cause)

/**
 * The host-defect classes of the log package.
 *
 * Materialization and segment I/O failures are `wal.md` §5/§5.1 host defects:
 * admission closes and the host state becomes `Failed`. They are not protocol
 * errors, and no code here is a `pdsh_wal` code.
 */
enum class LogFailure(val code: String) {
    /** `wal.md` §5/§5.1: applying a record to the materialized copy failed. */
    MATERIALIZATION_FAILED("WAL_MATERIALIZATION_FAILED"),

    /** Creating, appending to or truncating a segment file failed. */
    SEGMENT_IO("WAL_SEGMENT_IO"),

    /** Reading the `wal/` directory or the manifest failed. */
    WAL_DIRECTORY_IO("WAL_DIRECTORY_IO"),

    /** The staged reconcile's copy or exchange failed (`wal.md` §7.2). */
    RECONCILE_FAILED("WAL_RECONCILE_FAILED"),

    /** `wal.md` §5.2: an epoch close with an unrepaired base mismatch fails. */
    RESYNC_UNREPAIRED("WAL_RESYNC_UNREPAIRED"),

    /**
     * `wal.md` §9: the WAL is above its quota and compaction cannot free
     * enough. This is the fail-loud state — admission closes, never a silent
     * truncation and never a segment dropped without proof.
     */
    QUOTA_EXCEEDED("WAL_QUOTA_EXCEEDED"),

    /** A call arrived before [WorkspaceLog.recover] completed. */
    NOT_READY("WAL_NOT_READY"),

    /** A prior host defect closed the log; no further write is accepted. */
    CLOSED("WAL_CLOSED"),
}

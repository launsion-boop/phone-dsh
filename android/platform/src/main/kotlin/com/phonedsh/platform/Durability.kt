// Durability as semantics, never as a file descriptor.
// SPDX-License-Identifier: MIT
//
// spec/v1/wal.md §5.2 closes an epoch by ordering fsyncs and replacing the
// manifest atomically. iOS gets F_FULLFSYNC; Android only has fsync/fdatasync,
// and whether "at most the last epoch is lost" holds depends on the filesystem
// and the device write cache (plan §3.2, §11-R1). The SPI therefore exposes
// three semantic operations and an honest level report, and never a raw fd that
// a caller could fsync in the wrong order.

package com.phonedsh.platform

import java.nio.file.Path

/**
 * The durable-write primitives the log layer is allowed to use.
 *
 * Implementations own the ordering: callers never receive an fd, so they cannot
 * interleave an fsync between two writes that the platform must publish
 * together.
 */
interface Durability {
    /**
     * Forces [path] to stable storage. [path] may be a regular file or a
     * directory.
     *
     * A directory fsync publishes the entries created or renamed inside it; the
     * epoch-close order is file fsync first, then the containing directory.
     *
     * @throws java.io.IOException when the path cannot be opened or synced.
     */
    suspend fun fsyncPath(path: Path)

    /**
     * Replaces [target] with the content [write] produces, atomically.
     *
     * The implementation passes a temporary sibling path to [write], fsyncs it,
     * renames it over [target] and fsyncs the containing directory. A partial
     * file is never observable: after this call returns, [target] holds exactly
     * the new bytes; after it throws, [target] either still holds the previous
     * bytes (a failure before the rename, including a throw from [write]) or
     * already holds the complete new bytes whose power-loss durability was not
     * confirmed (a failure in the parent-directory fsync after the rename). The
     * temporary file is removed on failure.
     *
     * @throws java.io.IOException when [write] or any sync/rename step fails.
     */
    suspend fun atomicReplace(target: Path, write: (Path) -> Unit)

    /**
     * The durability this implementation can actually honour.
     *
     * Must report the measured level, never a default. Returning
     * [DurabilityLevel.LEVEL_2_POWER_LOSS_MEASURED] without a device-class
     * measurement is a product-claim bug (plan §11-R1, D2a).
     */
    fun level(): DurabilityLevel
}

/**
 * What the implementation reports it can lose.
 *
 * The three values are not a quality ladder: `LEVEL_2_POWER_LOSS_UNVERIFIED`
 * means the mechanism exists but the "at most the last epoch" claim has not
 * been measured on this device class, which is exactly the state before the
 * power-loss bench runs (D2a).
 */
enum class DurabilityLevel {
    /** A process kill loses nothing that the epoch close reported as durable. */
    LEVEL_1_PROCESS_KILL,

    /** Level-2 mechanism exists, but the power-loss claim is not measured. */
    LEVEL_2_POWER_LOSS_UNVERIFIED,

    /** Level-2 claim measured on this device class; the only level that may be promised. */
    LEVEL_2_POWER_LOSS_MEASURED,
}

/**
 * True only for the measured level-2 report.
 *
 * This is the single place allowed to turn [DurabilityLevel] into a product
 * claim. Everything else must treat `UNVERIFIED` exactly like level 1.
 */
fun DurabilityLevel.supportsLevel2Claim(): Boolean =
    this == DurabilityLevel.LEVEL_2_POWER_LOSS_MEASURED

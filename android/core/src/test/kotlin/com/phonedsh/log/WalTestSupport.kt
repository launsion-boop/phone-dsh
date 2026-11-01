// Test-only doubles and fixtures for the log package.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.platform.Clock
import com.phonedsh.platform.Durability
import com.phonedsh.platform.DurabilityLevel
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.runBlocking

/**
 * A [Durability] that performs the real file work and records every SPI call.
 *
 * The internal fsync of [atomicReplace] is deliberately **not** recorded as a
 * separate event: the SPI contract already fixes that sequence, and the D18
 * order test asserts the order the log layer itself issues. The fake therefore
 * has one observable event per SPI call.
 */
internal class RecordingDurability(
    private val root: Path,
    private val reportedLevel: DurabilityLevel = DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED,
) : Durability {
    /** One recorded SPI call. */
    sealed interface Call {
        data class Fsync(val path: Path) : Call

        data class AtomicReplace(val target: Path) : Call
    }

    private val history = ArrayList<Call>()

    /** Every SPI call, in call order. */
    val calls: List<Call>
        get() = history.toList()

    /** The calls as workspace-relative labels, for an exact order assertion. */
    val events: List<String>
        get() = calls.map { call ->
            when (call) {
                is Call.Fsync -> "fsync:" + label(call.path)
                is Call.AtomicReplace -> "atomicReplace:" + label(call.target)
            }
        }

    /** Forgets recorded calls, so a test can bracket one operation. */
    fun clear() {
        history.clear()
    }

    override fun level(): DurabilityLevel = reportedLevel

    override suspend fun fsyncPath(path: Path) {
        history += Call.Fsync(path.toAbsolutePath().normalize())
    }

    override suspend fun atomicReplace(target: Path, write: (Path) -> Unit) {
        val absolute = target.toAbsolutePath().normalize()
        val parent = absolute.parent
            ?: throw IllegalArgumentException("target has no parent directory: $target")
        Files.createDirectories(parent)
        val temporary = Files.createTempFile(parent, ".${absolute.fileName}.", ".tmp")
        var published = false
        try {
            write(temporary)
            Files.move(
                temporary,
                absolute,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            published = true
        } finally {
            if (!published) {
                try {
                    Files.deleteIfExists(temporary)
                } catch (_: IOException) {
                    // Cleanup only; the caller sees the publish failure.
                }
            }
        }
        history += Call.AtomicReplace(absolute)
    }

    private fun label(path: Path): String {
        val base = root.toAbsolutePath().normalize()
        val absolute = path.toAbsolutePath().normalize()
        if (absolute == base) return "."
        return try {
            base.relativize(absolute).toString()
        } catch (_: IllegalArgumentException) {
            path.fileName?.toString() ?: "?"
        }
    }
}

/** A wall clock pinned to the epoch-close millisecond of the §4 golden. */
internal class FixedClock(private var millis: Long = 1_792_800_000_123L) : Clock {
    /** Moves the wall clock; the close record must record the new value. */
    fun setNow(value: Long) {
        millis = value
    }

    override fun nowMillis(): Long = millis

    override fun monotonicMillis(): Long = 0L
}

/** The fixed boot id of the WAL goldens, reused by tests that need a stable one. */
internal val TEST_BOOT_ID: BootId = BootId("00112233445566778899aabbccddeeff")

/** Builds a log over [root]; callers run [WorkspaceLog.recover] themselves. */
internal fun newLog(
    root: Path,
    durability: Durability,
    bootId: BootId = TEST_BOOT_ID,
    rollBytes: Int = WorkspaceLog.DEFAULT_SEGMENT_ROLL_BYTES,
    sink: WalLogSink = WalLogSink.NONE,
    clock: Clock = FixedClock(),
    limitBytes: Long = WalQuota.DEFAULT_LIMIT_BYTES,
): WorkspaceLog = WorkspaceLog(
    paths = WalPaths(root),
    durability = durability,
    clock = clock,
    bootId = bootId,
    segmentRollBytes = rollBytes,
    sink = sink,
    walLimitBytes = limitBytes,
)

/** Runs [WorkspaceLog.recover] on a fresh log and returns it. */
internal fun recoveredLog(
    root: Path,
    durability: Durability,
    bootId: BootId = TEST_BOOT_ID,
    rollBytes: Int = WorkspaceLog.DEFAULT_SEGMENT_ROLL_BYTES,
    sink: WalLogSink = WalLogSink.NONE,
    limitBytes: Long = WalQuota.DEFAULT_LIMIT_BYTES,
): WorkspaceLog {
    val log = newLog(root, durability, bootId, rollBytes, sink, limitBytes = limitBytes)
    runBlocking { log.recover() }
    return log
}

/** A complete write body with `entryChanged` set, as the VFS emits. */
internal fun writeMutation(path: String, text: String, mode: Int = 420): MutationBody =
    MutationBody(
        op = VfsOp.WRITE,
        mode = mode,
        path = path,
        data = text.toByteArray(Charsets.UTF_8),
        entryChanged = true,
    )

/** An appended write body: [text] is the suffix from [appendFrom]. */
internal fun appendedMutation(path: String, appendFrom: Long, text: String): MutationBody =
    MutationBody(
        op = VfsOp.WRITE,
        mode = 420,
        path = path,
        data = text.toByteArray(Charsets.UTF_8),
        appended = true,
        appendFrom = appendFrom,
        entryChanged = false,
    )

/** A mkdir body with the usual 0755 mode. */
internal fun mkdirMutation(path: String, mode: Int = 493): MutationBody =
    MutationBody(op = VfsOp.MKDIR, mode = mode, path = path)

/** A remove body; mode 0 and no data, per `channel.md` §3.1. */
internal fun removeMutation(path: String): MutationBody =
    MutationBody(op = VfsOp.REMOVE, mode = 0, path = path)

/** A chmod body. */
internal fun chmodMutation(path: String, mode: Int): MutationBody =
    MutationBody(op = VfsOp.CHMOD, mode = mode, path = path)

/** Reads and parses the on-disk manifest. */
internal fun readManifest(paths: WalPaths): Manifest =
    Manifest.parse(Files.readAllBytes(paths.manifestFile))

/** The `wal/` files, in name order. */
internal fun segmentFiles(paths: WalPaths): List<Path> {
    if (!Files.isDirectory(paths.walDirectory)) return emptyList()
    return Files.list(paths.walDirectory).use { stream ->
        stream
            .filter { Files.isRegularFile(it) }
            .sorted()
            .toList()
    }
}

/** The bytes of one segment. */
internal fun segmentBytes(paths: WalPaths, name: WalSegmentName): ByteArray =
    Files.readAllBytes(paths.segment(name))

/** Truncates [bytes] bytes off the end of [path]; the torn-tail fixture. */
internal fun tearTail(path: Path, bytes: Int) {
    java.nio.channels.FileChannel.open(path, java.nio.file.StandardOpenOption.WRITE).use { channel ->
        channel.truncate(channel.size() - bytes)
    }
}

/** The materialized text of a `/dsh/...` path, or `null` when absent. */
internal fun materializedText(paths: WalPaths, vfsPath: String): String? {
    val path = paths.materialized(vfsPath)
    if (!Files.isRegularFile(path)) return null
    return String(Files.readAllBytes(path), Charsets.UTF_8)
}

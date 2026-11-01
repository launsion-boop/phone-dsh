// phone-dsh — :dsh unit test: the journal lane's fakes and frame builders.
// SPDX-License-Identifier: MIT
//
// The fakes are deliberately small: one [Durability] that records the order of
// fsyncs and can fail on demand, one [JournalSender] that records the
// acknowledgements, a temporary workspace root, and the two frame builders the
// tests need. `WireCodec.encode` produces every frame, so the tests use the same
// Rust codec the host does and never hand-roll a payload offset.

package com.phonedsh.dsh.journal

import com.phonedsh.platform.Durability
import com.phonedsh.platform.DurabilityLevel
import com.phonedsh.wire.WireCodec
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.Comparator

/**
 * A [Durability] that appends one event per call to [events].
 *
 * [failFsync] makes the next `fsyncPath` throw, which is how the tests prove
 * "no ACK without a completed fsync". [atomicReplace] is a real implementation
 * (temp file, fsync, atomic rename, directory fsync), so pruning exercises the
 * same path production uses.
 */
internal class RecordingDurability(
    val events: MutableList<String>,
    private val level: DurabilityLevel = DurabilityLevel.LEVEL_2_POWER_LOSS_UNVERIFIED,
) : Durability {
    /** When `true`, every [fsyncPath] throws [IOException]. */
    var failFsync: Boolean = false

    override suspend fun fsyncPath(path: Path) {
        events += "fsync:${path.fileName}"
        if (failFsync) throw IOException("fsync refused by the test")
    }

    override suspend fun atomicReplace(target: Path, write: (Path) -> Unit) {
        val absolute = target.toAbsolutePath()
        val parent = absolute.parent
            ?: throw IllegalArgumentException("target has no parent directory: $target")
        Files.createDirectories(parent)
        val temporary = Files.createTempFile(parent, ".${absolute.fileName}.", ".tmp")
        var published = false
        try {
            write(temporary)
            fsyncPath(temporary)
            Files.move(
                temporary,
                absolute,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            published = true
            fsyncPath(parent)
        } finally {
            if (!published) {
                Files.deleteIfExists(temporary)
            }
        }
    }

    override fun level(): DurabilityLevel = level
}

/** A [JournalSender] that keeps every acknowledgement in send order. */
internal class RecordingSender(
    private val events: MutableList<String>? = null,
) : JournalSender {
    val acks = mutableListOf<JournalAck>()

    override suspend fun send(ack: JournalAck) {
        events?.add("ack:${ack.uptoJseq}")
        acks += ack
    }
}

/** Runs [block] on a fresh temporary workspace root, deleted afterwards. */
internal fun <T> withJournalRoot(block: (Path) -> T): T {
    val root = Files.createTempDirectory("pdsh-journal-test")
    try {
        return block(root)
    } finally {
        if (Files.exists(root)) {
            Files.walk(root).use { stream ->
                stream.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
            }
        }
    }
}

/**
 * A store on [root] with an optional lowered [limit] (the default is the real
 * 64 MiB row; the quota tests lower it so they never write 64 MiB).
 */
internal fun newJournalStore(
    durability: Durability,
    root: Path,
    limit: Long = JournalStore.DEFAULT_LIMIT_BYTES,
): JournalStore = JournalStore(JournalPaths(root), durability, limitBytes = limit)

/**
 * One tool-journal record in the worker's wire projection (`exec.md` §4).
 *
 * `type` is `dispatched`, `completed`, `resolved`, `executed` or anything else;
 * [padding] grows the opaque payload without changing the locator.
 */
internal fun journalRecord(
    type: String = "dispatched",
    stepId: String? = "1",
    turnId: String? = "turn_1",
    key: String? = "xl1-0123456789abcdef0123456789abcdef",
    padding: Int = 0,
): ByteArray {
    val members = mutableListOf<String>()
    members += "\"v\":1"
    members += "\"type\":\"$type\""
    if (key != null) members += "\"key\":\"$key\""
    if (stepId != null) members += "\"step_id\":\"$stepId\""
    if (turnId != null) members += "\"turn_id\":\"$turnId\""
    if (padding > 0) members += "\"detail\":\"" + "x".repeat(padding) + "\""
    return ("{" + members.joinToString(",") + "}").toByteArray(Charsets.UTF_8)
}

/** One whole `JOURNAL` frame for the codec to encode (§3.5). */
internal fun journalFrame(
    sessionId: String,
    jseq: Long,
    record: ByteArray,
    seq: Long = 2L,
): ByteArray = WireCodec.encode(
    "{\"type\":\"JOURNAL\",\"fields\":{\"jseq\":$jseq," +
        "\"record_hex\":\"${hex(record)}\",\"session_id\":\"$sessionId\"}}",
    seq,
)

/** Lowercase hex; the codec's binary field form. */
internal fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
    for (byte in bytes) {
        val value = byte.toInt() and 0xFF
        append("0123456789abcdef"[value ushr 4]).append("0123456789abcdef"[value and 0x0F])
    }
}

/**
 * Hex to bytes for the golden vectors.
 *
 * The main source cannot use `java.util.HexFormat` (API 34+ on Android, minSdk
 * 26 here) and decodes strictly by hand; a JVM unit test has no such constraint,
 * so it uses the standard library rather than a second copy of the decoder.
 */
internal fun hexBytes(hex: String): ByteArray = java.util.HexFormat.of().parseHex(hex)

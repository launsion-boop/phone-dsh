// SPDX-License-Identifier: MIT
package com.phonedsh.log

import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardOpenOption.WRITE
import java.security.MessageDigest

/** Durable survivor bytes for a logical file replacement that requires multiple WAL records. */
internal class PendingSessionWrites(private val log: WorkspaceLog) {
    private val root = log.paths.root.resolve("pending-session-rewrite")
    private val sessions = log.paths.materializedHome.resolve("sessions")
    val exists: Boolean get() = Files.exists(root, NOFOLLOW_LINKS)

    data class Item(val stage: Path, val target: Path, val originalHash: String, val bytes: ByteArray)

    suspend fun prepare(change: ClosedSessionRewrite.FileChange) {
        val bytes = checkNotNull(change.replacement)
        val path = root.resolve(hex(change.originalDigest)).resolve(hex(sha(bytes))).resolve(sessions.relativize(change.file))
        Files.createDirectories(path.parent)
        requireSafePath(path.parent)
        val temp = Files.createTempFile(path.parent, "survivors-", ".part")
        try {
            Files.write(temp, bytes)
            FileChannel.open(temp, WRITE).use { it.force(true) }
            Files.move(temp, path, ATOMIC_MOVE)
            var parent = path.parent
            while (parent.startsWith(log.paths.root)) {
                log.durability.fsyncPath(parent)
                parent = parent.parent
            }
        } finally { Files.deleteIfExists(temp) }
    }

    fun read(): List<Item> {
        if (!exists) return emptyList()
        val items = mutableListOf<Item>()
        requireSafePath(root)
        Files.walk(root).use { files ->
            files.forEach { file ->
                check(!Files.isSymbolicLink(file))
                if (Files.isDirectory(file, NOFOLLOW_LINKS) || file.fileName.toString().endsWith(".part")) return@forEach
                val relative = root.relativize(file)
                require(relative.nameCount >= 4 && relative.fileName.toString().matches(Regex("""session\.v[0-9]+\.jsonl""")))
                val original = relative.getName(0).toString()
                require(original.matches(Regex("[a-f0-9]{64}")))
                val bytes = Files.readAllBytes(file)
                check(hex(sha(bytes)) == relative.getName(1).toString()) { "会话改写的恢复副本校验失败" }
                val target = sessions.resolve(relative.subpath(2, relative.nameCount))
                requireSafePath(target)
                items += Item(file, target, original, bytes)
            }
        }
        return items
    }

    suspend fun clear() {
        if (!exists) return
        requireSafePath(root)
        Files.walk(root).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach(Files::delete) }
        log.durability.fsyncPath(log.paths.root)
    }

    private fun requireSafePath(path: Path) {
        check(path.toRealPath() == log.paths.root.toRealPath().resolve(log.paths.root.relativize(path)))
    }

    companion object {
        fun sha(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
        fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
    }
}

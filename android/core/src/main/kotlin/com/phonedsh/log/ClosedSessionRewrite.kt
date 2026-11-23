// SPDX-License-Identifier: MIT
package com.phonedsh.log

import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.security.MessageDigest

/** wal.md §5.3. Called with the Worker parked, after computing tombstones under that same park. */
class ClosedSessionRewrite(private val log: WorkspaceLog) {
    data class FileChange(val file: Path, val originalDigest: ByteArray, val replacement: ByteArray?)

    private val pending = PendingSessionWrites(log)
    val hasPending: Boolean get() = pending.exists

    /** Startup and parked resume share the same idempotent reader. */
    suspend fun recoverPending(): Boolean {
        if (!pending.exists) return false
        val items = pending.read()
        val changes = mutableListOf<FileChange>()
        val sessions = mutableSetOf<String>()
        for (item in items) {
            val current = Files.readAllBytes(item.target)
            if (PendingSessionWrites.hex(PendingSessionWrites.sha(current)) == item.originalHash) continue
            check(current.size <= item.bytes.size && current.indices.all { current[it] == item.bytes[it] }) {
                "会话与改写恢复副本不一致，拒绝覆盖"
            }
            sessions += item.target.parent.fileName.toString()
            changes += FileChange(item.target, PendingSessionWrites.sha(current), item.bytes)
            val currentVersion = version(item.target) ?: error("会话改写文件名无效")
            Files.newDirectoryStream(item.target.parent).use { siblings ->
                for (sibling in siblings) {
                    val generation = version(sibling) ?: continue
                    if (sibling == item.target) continue
                    check(generation < currentVersion) { "会话已经产生新版本，拒绝覆盖" }
                    changes += FileChange(sibling, digest(sibling), null)
                }
            }
        }
        if (changes.isNotEmpty()) rewrite(changes, sessions, prepare = false)
        pending.clear()
        return true
    }

    private suspend fun writeFile(file: Path, bytes: ByteArray) {
        val path = "/dsh/home/sessions/" + log.paths.materializedHome.resolve("sessions").relativize(file).joinToString("/")
        var offset = 0
        do {
            val end = offset + minOf(bytes.size - offset, MutationBody.MAX_DATA_BYTES)
            log.appendMutation(MutationBody(VfsOp.WRITE, 420, path, bytes.copyOfRange(offset, end),
                appended = offset != 0, appendFrom = offset.toLong()))
            offset = end
        } while (offset < bytes.size)
    }

    suspend fun apply(changes: List<FileChange>, sessionIds: Set<String>) {
        check(!hasPending) { "上次会话改写尚待恢复" }
        rewrite(changes, sessionIds, prepare = true)
        pending.clear()
    }

    private suspend fun rewrite(changes: List<FileChange>, sessionIds: Set<String>, prepare: Boolean) {
        require(sessionIds.all { it.matches(Regex("[A-Za-z0-9._-]{1,64}")) && it !in setOf(".", "..") })
        val paths = log.paths
        val sessions = paths.materializedHome.resolve("sessions")
        check(!Files.exists(paths.reconcileMarker, NOFOLLOW_LINKS)) { "工作区正在恢复" }
        for (change in changes) {
            val file = change.file
            require(file.normalize() == file && file.startsWith(sessions) && file.parent.fileName.toString() in sessionIds)
            require(file.fileName.toString().matches(Regex("""session\.v[0-9]+\.jsonl(?:\.zstd)?""")))
            check(Files.isRegularFile(file, NOFOLLOW_LINKS) && file.toRealPath() == paths.root.toRealPath().resolve(paths.root.relativize(file)))
            check(MessageDigest.isEqual(digest(file), change.originalDigest)) { "会话记录已变化，请重试" }
        }
        log.closeEpoch()
        check(log.materializedUptoMseq == log.allocator().lastMseq)
        val start = log.allocator().nextMseq
        for (change in changes) {
            val path = "/dsh/home/sessions/" + sessions.relativize(change.file).joinToString("/")
            val bytes = change.replacement
            if (bytes == null) {
                log.appendMutation(MutationBody(VfsOp.REMOVE, 0, path))
                continue
            }
            if (prepare) pending.prepare(change)
            writeFile(change.file, bytes)
            check(MessageDigest.isEqual(digest(change.file), MessageDigest.getInstance("SHA-256").digest(bytes)))
        }
        log.closeEpoch()
        log.locked {
            log.quota.enforceWithReserve(log.quota.limitBytes)
            Files.newDirectoryStream(paths.walDirectory, "*.xlwal").use { segments ->
                for (segment in segments) {
                    val name = checkNotNull(WalSegmentName.parse(segment.fileName.toString()))
                    check(log.readSegmentRecordRefs(name).none { it.isMutation && it.mseq < start }) { "旧 WAL 记录仍存在" }
                }
            }
        }
        val derived = mutableListOf(paths.stagingDirectory, paths.previousMaterializedDirectory,
            paths.root.resolve("recovery-backup"), paths.root.resolve("boot-overlay"),
            paths.root.resolve("overlay-frags"), paths.root.resolve("overlay-cache.tar"), paths.root.resolve("overlay-cache.json"))
        Files.newDirectoryStream(paths.root, "overlay-*.tar").use { derived.addAll(it) }
        for (id in sessionIds) {
            derived.add(paths.materializedHome.resolve("storages/session_projcache/sessions/$id.json"))
        }
        for (entry in derived.distinct()) {
            if (!Files.exists(entry, NOFOLLOW_LINKS)) continue
            check(entry.parent.toRealPath() == paths.root.toRealPath().resolve(paths.root.relativize(entry.parent)))
            Files.walk(entry).use { tree -> tree.sorted(Comparator.reverseOrder()).forEach(Files::delete) }
            log.durability.fsyncPath(entry.parent)
        }
    }

    companion object {
        private val sessionFile = Regex("""session\.v([0-9]+)\.jsonl(?:\.zstd)?""")
        private fun version(path: Path) = sessionFile.matchEntire(path.fileName.toString())?.groupValues?.get(1)?.toLong()

        fun digest(file: Path): ByteArray {
            val digest = MessageDigest.getInstance("SHA-256")
            Files.newInputStream(file, NOFOLLOW_LINKS).use { source ->
                val buffer = ByteArray(65536)
                while (true) {
                    val size = source.read(buffer)
                    if (size == -1) break
                    digest.update(buffer, 0, size)
                }
            }
            return digest.digest()
        }
    }
}

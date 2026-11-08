// phone-dsh — :app / com.phonedsh.ssh: SCP as SFTP over SSH, bounded per transfer tree.
// SPDX-License-Identifier: MIT
//
// Port of `Sources/PhoneDSHSSH/SSHFileTransfer.swift`. Limits apply to the
// whole tree (bytes, 1,000 entries, depth 32), not to each file. Downloads emit
// the NDJSON records of docs/native-ssh.md (`directory`, `file`, `data`, `end`);
// every downloaded path is relative and validated again by the Worker's VFS
// writer, which is the only writer of the workspace. Uploads read only the
// acknowledged materialized mounts and refuse symbolic links and special files.

package com.phonedsh.ssh

import com.jcraft.jsch.ChannelSftp
import com.jcraft.jsch.SftpATTRS
import com.jcraft.jsch.SftpException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.attribute.BasicFileAttributes
import java.util.Base64
import org.json.JSONObject

/**
 * One transfer's budget and record sink.
 *
 * @param limit the device byte budget for the whole tree.
 * @param emit receives one complete NDJSON line (with its `\n`); it may throw
 *   [SshFailure] when the record no longer fits the result budget.
 * @param cancelled polled between chunks; a cancelled transfer stops promptly.
 */
internal class SshFileTransfer(
    private val limit: Long,
    private val emit: (ByteArray) -> Unit,
    private val cancelled: () -> Boolean,
) {
    private var bytes = 0L
    private var entries = 0

    private fun checkCancelled() {
        if (cancelled()) throw SshFailure("SSH cancelled")
    }

    private fun admit(size: Long = 0L, depth: Int) {
        checkCancelled()
        entries += 1
        if (entries > MAX_ENTRIES || depth > MAX_DEPTH || size < 0L || size > (limit - bytes).coerceAtLeast(0L)) {
            throw SshFailure(LIMIT_MESSAGE)
        }
        bytes += size
    }

    private fun record(vararg fields: Pair<String, Any>) {
        val json = JSONObject()
        for ((name, value) in fields) json.put(name, value)
        emit((json.toString() + "\n").toByteArray(Charsets.UTF_8))
    }

    fun upload(local: Path, remote: String, recursive: Boolean, sftp: ChannelSftp, depth: Int = 0) {
        val attributes = Files.readAttributes(local, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        if (attributes.isDirectory) {
            if (!recursive) throw SshFailure("Source is a directory; use scp -r")
            admit(depth = depth)
            val existing = statOrNull(sftp, remote)
            if (existing != null) {
                if (!existing.isDirectory()) throw SshFailure("Remote destination is not a directory")
            } else {
                sftp.mkdir(remote)
            }
            val children = Files.list(local).use { stream -> stream.iterator().asSequence().toList() }.sortedBy { it.fileName.toString() }
            for (child in children) {
                upload(child, remoteJoin(remote, child.fileName.toString()), true, sftp, depth + 1)
            }
            return
        }
        if (!attributes.isRegularFile) throw SshFailure("scp refuses symbolic links and special local files")
        val size = attributes.size()
        admit(size, depth)
        Files.newInputStream(local, LinkOption.NOFOLLOW_LINKS).use { input ->
            sftp.put(remote, ChannelSftp.OVERWRITE).use { output ->
                val buffer = ByteArray(CHUNK_BYTES)
                var offset = 0L
                while (offset < size) {
                    checkCancelled()
                    val want = minOf(CHUNK_BYTES.toLong(), size - offset).toInt()
                    val read = input.read(buffer, 0, want)
                    if (read <= 0) throw SshFailure("Local file changed while uploading")
                    output.write(buffer, 0, read)
                    offset += read
                }
            }
        }
        record("type" to "uploaded", "path" to remote, "size" to size)
    }

    fun download(
        remote: String,
        relative: String,
        recursive: Boolean,
        sftp: ChannelSftp,
        depth: Int = 0,
        knownAttributes: SftpATTRS? = null,
    ) {
        val attributes = knownAttributes ?: sftp.stat(remote)
        if (attributes.isDirectory()) {
            if (!recursive) throw SshFailure("Source is a directory; use scp -r")
            admit(depth = depth)
            record("type" to "directory", "path" to relative, "name" to basename(remote))
            for (entry in sftp.ls(remote)) {
                val name = entry.filename
                if (name == "." || name == "..") continue
                validateName(name)
                val childPath = if (relative.isEmpty()) name else "$relative/$name"
                download(remoteJoin(remote, name), childPath, true, sftp, depth + 1, entry.attrs)
            }
            return
        }
        val kind = attributes.kind()
        if (kind != null && kind != REGULAR) throw SshFailure("scp refuses symbolic links and special remote files")
        if (attributes.flags and SftpATTRS.SSH_FILEXFER_ATTR_SIZE == 0) {
            throw SshFailure("Server did not provide the file size")
        }
        val size = attributes.size
        admit(size, depth)
        record("type" to "file", "path" to relative, "name" to basename(remote), "size" to size)
        sftp.get(remote).use { input ->
            val buffer = ByteArray(CHUNK_BYTES)
            var offset = 0L
            while (offset < size) {
                checkCancelled()
                val want = minOf(CHUNK_BYTES.toLong(), size - offset).toInt()
                val read = input.read(buffer, 0, want)
                if (read <= 0) throw SshFailure("Remote file changed while downloading")
                record("type" to "data", "data" to Base64.getEncoder().encodeToString(buffer.copyOf(read)))
                offset += read
            }
        }
        record("type" to "end", "path" to relative)
    }

    companion object {
        const val MAX_ENTRIES: Int = 1000
        const val MAX_DEPTH: Int = 32
        const val CHUNK_BYTES: Int = 32 * 1024
        const val LIMIT_MESSAGE: String = "scp transfer exceeds the device byte, entry or directory-depth limit"
        private const val TYPE_MASK = 0xF000 // 0o170000
        private const val DIRECTORY = 0x4000 // 0o040000
        private const val REGULAR = 0x8000 // 0o100000

        fun validateName(name: String) {
            if (name.isEmpty() || name == "." || name == ".." || name.contains('/') || name.contains('\\') ||
                name.contains('\u0000')
            ) {
                throw SshFailure("Unsafe filename from SSH server")
            }
        }

        fun basename(path: String): String = path.split('/').lastOrNull { it.isNotEmpty() } ?: "download"

        fun remoteJoin(parent: String, name: String): String =
            if (parent.endsWith("/")) parent + name else "$parent/$name"

        /** `stat`, with "does not exist" as `null`; every other SFTP error propagates. */
        fun statOrNull(sftp: ChannelSftp, path: String): SftpATTRS? = try {
            sftp.stat(path)
        } catch (missing: SftpException) {
            if (missing.id == ChannelSftp.SSH_FX_NO_SUCH_FILE) null else throw missing
        }

        private fun SftpATTRS.kind(): Int? =
            if (flags and SftpATTRS.SSH_FILEXFER_ATTR_PERMISSIONS == 0) null else permissions and TYPE_MASK

        fun SftpATTRS.isDirectory(): Boolean = kind() == DIRECTORY
    }
}

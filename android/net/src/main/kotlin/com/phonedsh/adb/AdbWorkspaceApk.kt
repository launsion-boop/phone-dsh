// phone-dsh — :net / com.phonedsh.adb: read a workspace APK for android_install_apk.
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHADB/ADBWorkspaceAPK.swift`. The root is the
// host's materialized `/dsh/workspace` mirror. Every component is checked with
// NOFOLLOW_LINKS and the final file is opened NOFOLLOW_LINKS; the Worker-supplied
// SHA-256 must match the bytes read before any ADB connection is opened.
//
// Honest difference from iOS: Swift walks the path with `openat(O_NOFOLLOW)`
// descriptors; the JVM has no `openat`, so an intermediate directory swapped for a
// symlink between the check and the open is a narrower race here. The tree is in
// the app's private storage and the digest still fences the bytes that are sent.

package com.phonedsh.adb

import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest

internal object AdbWorkspaceApk {
    const val LIMIT: Int = 128 * 1024 * 1024
    private const val PREFIX = "/dsh/workspace/"

    fun read(path: String, root: Path?, sha256: String?, maximumBytes: Int = LIMIT): ByteArray {
        if (root == null) throw AdbFailure("The host has not configured an APK workspace directory")
        if (!path.startsWith(PREFIX)) throw AdbFailure("APK must be inside /dsh/workspace/")
        val components = path.substring(PREFIX.length).split("/")
        if (components.isEmpty() || components.any { it.isEmpty() || it == "." || it == ".." || it.contains('\u0000') }) {
            throw AdbFailure("Invalid workspace APK path")
        }
        val unavailable = "APK file is unavailable; workspace symlinks are not supported. " +
            "Check the path and workspace synchronization."
        var current: Path = root
        if (!Files.isDirectory(current, LinkOption.NOFOLLOW_LINKS)) throw AdbFailure("Cannot open APK workspace directory")
        components.forEachIndexed { index, component ->
            current = current.resolve(component)
            val attributes = try {
                Files.readAttributes(current, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
            } catch (failure: java.io.IOException) {
                throw AdbFailure(unavailable)
            }
            val last = index == components.lastIndex
            if (attributes.isSymbolicLink || (!last && !attributes.isDirectory)) throw AdbFailure(unavailable)
        }
        val bytes = try {
            FileChannel.open(current, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
                val attributes = Files.readAttributes(current, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
                val size = channel.size()
                if (!attributes.isRegularFile || size < 4 || size > maximumBytes) {
                    throw AdbFailure("APK must be a regular file of 4 bytes to 128 MiB")
                }
                val buffer = ByteBuffer.allocate(size.toInt())
                while (buffer.hasRemaining()) {
                    if (channel.read(buffer) < 0) break
                }
                if (buffer.hasRemaining() || channel.read(ByteBuffer.allocate(1)) > 0) {
                    throw AdbFailure("APK changed while being read; recompute its sha256")
                }
                buffer.array()
            }
        } catch (failure: AdbFailure) {
            throw failure
        } catch (failure: java.io.IOException) {
            throw AdbFailure(unavailable)
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        if (sha256 != null && digest != sha256) {
            throw AdbFailure(
                "APK sha256 mismatch: workspace may not be synchronized or file changed. No Android command was sent; " +
                    "verify sha256sum and retry after synchronization.",
            )
        }
        if (!(bytes[0] == 80.toByte() && bytes[1] == 75.toByte() && bytes[2] == 3.toByte() && bytes[3] == 4.toByte())) {
            throw AdbFailure("File is not an APK/ZIP archive")
        }
        return bytes
    }
}

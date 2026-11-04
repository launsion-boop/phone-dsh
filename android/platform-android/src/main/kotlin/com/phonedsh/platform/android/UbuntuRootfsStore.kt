// phone-dsh — :platform-android: the on-demand Ubuntu Base rootfs.
// SPDX-License-Identifier: MIT
//
// ---- what this file owns ----------------------------------------------------
// One pinned Ubuntu Base arm64 tarball: download it over HTTPS, verify its
// SHA-256, extract it safely, and install `<filesDir>/rootfs/<version>` only
// after the whole tree is on disk. The rootfs is never committed and never
// carried in the APK; the first `ubuntu run` asks the user, then downloads
// ~30 MB and writes ~150 MB of disk. A failed or altered download installs
// nothing and returns a reason the caller can put in the job refusal.
//
// ---- why the extractor is hand-written -------------------------------------
// The repository has no tar dependency on the Android side, and the security
// properties are the point: an entry path may not be absolute or escape the
// installation root, a symlink may not point outside it, a hardlink may not
// reach outside it, and device/pipe nodes are refused. Ubuntu Base itself uses
// absolute in-guest symlinks (its alternatives links name guest-absolute
// targets) and hardlinks (`perl5.38.2 -> perl`), so those two shapes are supported
// rather than rejected: an absolute symlink target is rewritten as the
// equivalent path relative to the installation root, which keeps the guest
// meaning identical while guaranteeing the host never follows it out of the
// root. Hardlink creation is attempted first and falls back to a byte copy,
// because Android's app sandbox refuses `link()` on some app-data filesystems
// (the same fallback the PR14 recon measured).
//
// ---- what is *not* here ----------------------------------------------------
// No apt, no gcc, no package metadata, no deletion UI: the only operations are
// ensure/installedVersion/delete. The caller decides when to download (at job
// start, after approval) and which spec is pinned.

package com.phonedsh.platform.android

import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermission
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.GZIPInputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** One pinned rootfs: where it comes from and what it must hash to. */
data class UbuntuRootfsSpec(
    /** The directory name and the version shown to the user, e.g. `24.04.5`. */
    val version: String,
    /** The official HTTPS tarball; only `https` is accepted at download time. */
    val url: String,
    /** Lowercase sha256 of the tarball, pinned in the build. */
    val sha256: String,
    /** The tarball's exact Content-Length, used as an early corruption bound. */
    val archiveBytes: Long,
    /** The tar's declared uncompressed size, used for the free-space precheck. */
    val extractedBytes: Long,
    /** A corruption bound for one extraction; not a product limit. */
    val maxExtractedBytes: Long = DEFAULT_MAX_EXTRACTED_BYTES,
) {
    init {
        require(version.isNotEmpty() && '/' !in version && ".." !in version) {
            "the rootfs version is a directory name"
        }
        require(url.startsWith("https://")) { "the rootfs URL must be HTTPS" }
        require(SHA256.matches(sha256)) { "the rootfs sha256 is lowercase hex" }
        require(archiveBytes > 0 && extractedBytes > 0) { "rootfs sizes are positive" }
        require(maxExtractedBytes >= extractedBytes) {
            "the extraction bound must cover the declared tree"
        }
    }

    companion object {
        val SHA256 = Regex("^[0-9a-f]{64}$")

        /**
         * One extraction may never write more than this. Ubuntu Base 24.04.5
         * declares 101.8 MiB; the bound leaves room for a later point release
         * while still refusing a decompression bomb. The installed tree on a
         * 4 KiB filesystem measures ~147 MB because of block overhead.
         */
        const val DEFAULT_MAX_EXTRACTED_BYTES: Long = 256L * 1024L * 1024L
    }
}

/** What `ensureInstalled` answers. */
sealed interface UbuntuRootfsResult {
    /** The tree is complete and verified; [rootfs] is the directory to serve. */
    data class Ready(val rootfs: Path, val version: String) : UbuntuRootfsResult

    /** Nothing was installed; [reason] is a stable token for the job refusal. */
    data class Failed(val reason: String, val detail: String? = null) : UbuntuRootfsResult
}

/** The seam an adapter uses; a JVM test supplies a fake. */
interface UbuntuRootfsProvider {
    /** Downloads, verifies and extracts on first use; idempotent afterwards. */
    suspend fun ensureInstalled(): UbuntuRootfsResult

    /** The installed version, or `null` when no verified tree is present. */
    fun installedVersion(): String?

    /** Removes the installed tree and the downloaded archive. */
    suspend fun delete()
}

/** A download source, as a seam so the JVM suite never opens a socket. */
fun interface RootfsDownload {
    /** Opens [url] for reading; only an HTTPS URL is ever passed in production. */
    suspend fun open(url: String): InputStream
}

/**
 * The production downloader: HTTPS only, bounded redirects, connect/read
 * timeouts, and a non-200 response is an error rather than a body to parse.
 */
object HttpsRootfsDownload : RootfsDownload {
    override suspend fun open(url: String): InputStream = withContext(Dispatchers.IO) {
        require(url.startsWith("https://")) { "only HTTPS rootfs downloads are allowed" }
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = true
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            requestMethod = "GET"
            setRequestProperty("Accept", "application/gzip, application/octet-stream")
        }
        try {
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_OK) {
                throw IOException("the rootfs host answered HTTP $code")
            }
            connection.inputStream
        } catch (failure: IOException) {
            connection.disconnect()
            throw failure
        }
    }

    private const val CONNECT_TIMEOUT_MS = 15_000
    private const val READ_TIMEOUT_MS = 120_000
}

/**
 * The on-demand Ubuntu rootfs store.
 *
 * @param filesDir the environment root (`<app files>/ubuntu`); the store creates
 *   `downloads/` and `rootfs/` under it.
 * @param spec the pinned tarball.
 * @param download the byte source; tests inject a fixture.
 * @param availableBytes free-space probe; defaults to the file store's usable
 *   space, which is what a low-storage device would answer.
 * @param logger token-free progress/failure lines; never a URL with a token
 *   (this URL has none) and never a credential.
 * @param link the hardlink primitive, a seam because Android app data refuses
 *   `link()` on some filesystems. Production is `Files.createLink`; the JVM
 *   suite injects a refusal to prove the copy fallback.
 */
class UbuntuRootfsStore(
    private val filesDir: Path,
    private val spec: UbuntuRootfsSpec = UBUNTU_BASE_24_04_5,
    private val download: RootfsDownload = HttpsRootfsDownload,
    private val availableBytes: () -> Long = {
        runCatching { Files.getFileStore(filesDir).usableSpace }.getOrDefault(Long.MAX_VALUE)
    },
    private val logger: (String) -> Unit = {},
    private val link: (target: Path, source: Path) -> Unit = { target, source ->
        Files.createLink(target, source)
    },
) : UbuntuRootfsProvider {

    private val mutex = Mutex()

    /** `<filesDir>/rootfs/<version>`. */
    val rootfsDir: Path = filesDir.resolve("rootfs").resolve(spec.version)

    /** `<filesDir>/downloads/<version>.tar.gz`. */
    val archiveFile: Path = filesDir.resolve("downloads").resolve("${spec.version}.tar.gz")

    private val markerFile: Path = rootfsDir.resolve(MARKER)

    override fun installedVersion(): String? {
        if (!Files.isDirectory(rootfsDir)) return null
        if (!Files.isRegularFile(rootfsDir.resolve("bin/uname"))) return null
        val marker = readMarker() ?: return null
        return marker.takeIf { it == spec.version }
    }

    override suspend fun ensureInstalled(): UbuntuRootfsResult = mutex.withLock {
        withContext(Dispatchers.IO) {
            Files.createDirectories(filesDir)
            installedVersion()?.let { return@withContext UbuntuRootfsResult.Ready(rootfsDir, it) }
            val free = availableBytes()
            val required = spec.archiveBytes + spec.extractedBytes + FREE_SPACE_MARGIN_BYTES
            if (free < required) {
                return@withContext UbuntuRootfsResult.Failed(
                    "insufficient_disk_space",
                    "need $required bytes, $free available",
                )
            }
            var installing = false
            try {
                ensureArchive()
                installing = true
                install()
                UbuntuRootfsResult.Ready(rootfsDir, spec.version)
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (failure: RootfsFailure) {
                logger("ubuntu rootfs: ${failure.reason}${failure.detail?.let { " ($it)" } ?: ""}")
                UbuntuRootfsResult.Failed(failure.reason, failure.detail)
            } catch (failure: IOException) {
                val reason = extractionReason(failure, installing)
                logger("ubuntu rootfs: $reason (${failure.javaClass.simpleName})")
                UbuntuRootfsResult.Failed(reason, failure.javaClass.simpleName)
            }
        }
    }

    /** Map one extraction exception to the token a job refusal can report. */
    private fun extractionReason(failure: IOException, installing: Boolean): String {
        val message = failure.message ?: ""
        return when {
            message.startsWith("unsafe_path") -> "unsafe_path"
            message.startsWith("unsafe_entry") -> "unsafe_entry"
            message.startsWith("unsupported_entry") -> "unsupported_entry"
            installing -> "extract_failed"
            else -> "download_failed"
        }
    }

    override suspend fun delete() {
        mutex.withLock {
            withContext(Dispatchers.IO) {
                deleteTree(rootfsDir)
                Files.deleteIfExists(archiveFile)
            }
        }
    }

    // ---- download and verify -------------------------------------------

    private suspend fun ensureArchive() {
        Files.createDirectories(archiveFile.parent)
        if (Files.isRegularFile(archiveFile)) {
            val digest = sha256Of(archiveFile)
            if (digest == spec.sha256) return
            Files.deleteIfExists(archiveFile)
        }
        val temporary = archiveFile.resolveSibling("${archiveFile.fileName}.part")
        Files.deleteIfExists(temporary)
        logger("ubuntu rootfs: downloading ${spec.version} (${spec.archiveBytes} bytes)")
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        try {
            download.open(spec.url).use { input ->
                Files.newOutputStream(
                    temporary,
                    StandardOpenOption.CREATE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE,
                ).use { output ->
                    val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > spec.archiveBytes) {
                            throw RootfsFailure("sha256_mismatch", "archive grew past its pinned size")
                        }
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                    }
                }
            }
            if (total != spec.archiveBytes) {
                throw RootfsFailure("sha256_mismatch", "read $total of ${spec.archiveBytes} bytes")
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (actual != spec.sha256) {
                throw RootfsFailure("sha256_mismatch", "archive sha256 does not match the pinned value")
            }
            Files.move(temporary, archiveFile, StandardCopyOption.REPLACE_EXISTING)
        } catch (failure: Throwable) {
            runCatching { Files.deleteIfExists(temporary) }
            throw failure
        }
        logger("ubuntu rootfs: download verified (${spec.archiveBytes} bytes)")
    }

    // ---- safe extraction and atomic install ----------------------------

    private fun install() {
        val partial = filesDir.resolve("rootfs").resolve(".${spec.version}.${UUID.randomUUID()}.partial")
        deleteTree(partial)
        Files.createDirectories(partial)
        try {
            Files.newInputStream(archiveFile).use { raw ->
                GZIPInputStream(raw, GZIP_BUFFER_BYTES).use { gzip ->
                    SafeTarExtractor(partial, spec.maxExtractedBytes, logger, link).extract(gzip)
                }
            }
            if (!Files.isRegularFile(partial.resolve("bin/uname"))) {
                throw RootfsFailure("extract_failed", "the archive carries no bin/uname")
            }
            writeMarker(partial)
            if (Files.exists(rootfsDir)) deleteTree(rootfsDir)
            Files.createDirectories(rootfsDir.parent)
            try {
                Files.move(partial, rootfsDir, StandardCopyOption.ATOMIC_MOVE)
            } catch (_: IOException) {
                // A filesystem without atomic directory moves still gets the
                // complete tree; the failure mode is a visible partial rename,
                // which `installedVersion` refuses because the marker and
                // bin/uname are the last things written above.
                Files.move(partial, rootfsDir)
            }
            logger("ubuntu rootfs: installed ${spec.version} at rootfs/${spec.version}")
        } catch (failure: Throwable) {
            runCatching { deleteTree(partial) }
            throw failure
        }
    }

    private fun writeMarker(root: Path) {
        // Written inside the partial tree before the rename, so a tree without
        // a matching marker is never reported as installed.
        Files.write(
            root.resolve(MARKER),
            "${spec.version}\n${spec.sha256}\n".toByteArray(StandardCharsets.UTF_8),
            StandardOpenOption.CREATE,
            StandardOpenOption.TRUNCATE_EXISTING,
            StandardOpenOption.WRITE,
        )
    }

    private fun readMarker(): String? = try {
        if (!Files.isRegularFile(markerFile)) {
            null
        } else {
            String(Files.readAllBytes(markerFile), StandardCharsets.UTF_8).lineSequence().firstOrNull()
        }
    } catch (_: IOException) {
        null
    }

    private fun sha256Of(path: Path): String {
        val digest = MessageDigest.getInstance("SHA-256")
        Files.newInputStream(path).use { input ->
            val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        /** The pinned Ubuntu Base release used by this slice. */
        val UBUNTU_BASE_24_04_5: UbuntuRootfsSpec = UbuntuRootfsSpec(
            version = "24.04.5",
            url = "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/" +
                "ubuntu-base-24.04.5-base-arm64.tar.gz",
            sha256 = "a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2",
            archiveBytes = 29_936_675L,
            extractedBytes = 106_741_760L,
        )

        /** The marker file inside an installed tree. */
        const val MARKER: String = ".pdsh-rootfs"

        /** Headroom over the archive + tree so a install does not fill the disk. */
        const val FREE_SPACE_MARGIN_BYTES: Long = 16L * 1024L * 1024L

        private const val DOWNLOAD_BUFFER_BYTES = 64 * 1024
        private const val GZIP_BUFFER_BYTES = 64 * 1024
    }

    /** One mapped failure, carrying the token the job refusal reports. */
    private class RootfsFailure(val reason: String, val detail: String? = null) : IOException(reason)
}

/**
 * A streaming ustar/PAX reader that refuses every path the installation root
 * would not contain.
 *
 * Only the entry types Ubuntu Base uses are accepted: regular files,
 * directories, symlinks and hardlinks. Device nodes, FIFOs and unknown types
 * are refused rather than skipped, because a skipped entry turns a complete
 * tree into a subtly broken one. GNU long names and PAX `path`/`linkpath`/`size`
 * records are supported; the pinned 24.04.5 tar is plain ustar and needs none of
 * them, but a point release that adds one must not be able to escape the gate.
 */
internal class SafeTarExtractor(
    private val root: Path,
    private val maxBytes: Long,
    private val logger: (String) -> Unit,
    private val link: (target: Path, source: Path) -> Unit,
) {
    private var written = 0L

    fun extract(input: InputStream) {
        val reader = TarReader(input)
        var pendingPath: String? = null
        var pendingLink: String? = null
        var pendingSize: Long? = null
        while (true) {
            val header = reader.nextHeader() ?: break
            val type = header.type
            if (type == TYPE_PAX || type == TYPE_GNU_LONG_NAME || type == TYPE_GNU_LONG_LINK) {
                val payload = reader.readAll(header.size)
                when (type) {
                    TYPE_PAX -> {
                        val records = PaxRecords.parse(payload)
                        records["path"]?.let { pendingPath = it }
                        records["linkpath"]?.let { pendingLink = it }
                        records["size"]?.toLongOrNull()?.let { pendingSize = it }
                    }

                    TYPE_GNU_LONG_NAME -> pendingPath = String(payload, StandardCharsets.UTF_8).trimEnd('\u0000')
                    else -> pendingLink = String(payload, StandardCharsets.UTF_8).trimEnd('\u0000')
                }
                continue
            }
            val name = pendingPath ?: header.name
            val link = pendingLink ?: header.linkName
            val size = pendingSize ?: header.size
            pendingPath = null
            pendingLink = null
            pendingSize = null
            extractEntry(name, type, size, link, header.mode, reader)
        }
    }

    private fun extractEntry(
        rawName: String,
        type: Byte,
        size: Long,
        linkName: String,
        mode: Int,
        reader: TarReader,
    ) {
        val relative = safeRelative(rawName, "entry")
        val target = root.resolve(relative).normalize()
        requireInside(target)
        when (type) {
            TYPE_FILE, TYPE_FILE_OLD -> {
                if (size < 0) throw fail("unsafe_entry", "negative file size")
                written += size
                if (written > maxBytes) throw fail("unsafe_entry", "the archive exceeds the extraction bound")
                prepareFile(target)
                Files.newOutputStream(
                    target,
                    StandardOpenOption.CREATE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE,
                ).use { output -> reader.copyData(size, output) }
                applyMode(target, mode)
            }

            TYPE_DIR -> {
                prepareDirectory(target)
                applyMode(target, mode or 0b111_000_000)
            }

            TYPE_SYMLINK -> {
                if (linkName.isEmpty()) throw fail("unsafe_entry", "a symlink with no target")
                prepareSymlink(target)
                val targetPath = resolveSymlinkTarget(relative, target, linkName)
                Files.createSymbolicLink(target, targetPath)
            }

            TYPE_HARDLINK -> {
                if (linkName.isEmpty()) throw fail("unsafe_entry", "a hardlink with no target")
                val linked = safeRelative(linkName, "hardlink")
                val source = root.resolve(linked).normalize()
                requireInside(source)
                if (!Files.isRegularFile(source, java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
                    throw fail("unsafe_entry", "a hardlink does not name a regular file in the tree")
                }
                val sourcePermissions = runCatching { Files.getPosixFilePermissions(source) }.getOrNull()
                prepareFile(target)
                try {
                    link(target, source)
                } catch (_: FileAlreadyExistsException) {
                    throw fail("unsafe_entry", "a hardlink target already exists")
                } catch (_: IOException) {
                    // Measured on Android app data: link() is refused. The
                    // complete tree still works with a byte copy; the copy takes
                    // the source's mode, never the hardlink header's (which is
                    // zero for a hardlink entry).
                    logger("ubuntu rootfs: hardlink fallback to copy for ${target.fileName}")
                    Files.copy(source, target, StandardCopyOption.REPLACE_EXISTING)
                    sourcePermissions?.let { runCatching { Files.setPosixFilePermissions(target, it) } }
                }
            }

            else -> throw fail(
                "unsupported_entry",
                "tar entry type ${type.toInt().toChar()} is not a file, directory or link",
            )
        }
    }

    /** A tar entry path: relative, no `..` segment, no drive/UNC spelling. */
    private fun safeRelative(raw: String, what: String): Path {
        if (raw.isEmpty() || '\u0000' in raw) throw fail("unsafe_path", "an empty $what path")
        if (raw.startsWith("/") || raw.startsWith("\\")) {
            throw fail("unsafe_path", "an absolute $what path was refused")
        }
        if (Regex("^[A-Za-z]:").containsMatchIn(raw)) {
            throw fail("unsafe_path", "a drive-letter $what path was refused")
        }
        val path = try {
            Paths.get(raw)
        } catch (failure: RuntimeException) {
            throw fail("unsafe_path", "an unparseable $what path")
        }.normalize()
        if (path.isAbsolute || path.toString().isEmpty() || path.startsWith("..")) {
            throw fail("unsafe_path", "a $what path escapes the installation root")
        }
        return path
    }

    /**
     * Resolve a symlink target against the tree.
     *
     * Absolute targets are the guest's absolute paths, not the host's: resolve
     * them against [root], then express the result relative to the link's
     * parent so the on-disk symlink cannot reach outside the installation root.
     * A relative target is kept only when it still resolves inside the root.
     */
    private fun resolveSymlinkTarget(entryRelative: Path, link: Path, rawTarget: String): Path {
        val resolved = if (rawTarget.startsWith("/")) {
            root.resolve(rawTarget.removePrefix("/")).normalize()
        } else {
            link.parent.resolve(rawTarget).normalize()
        }
        requireInside(resolved)
        if (resolved == link.parent) return Paths.get(".")
        return link.parent.relativize(resolved)
    }

    private fun requireInside(path: Path) {
        if (!path.startsWith(root)) throw fail("unsafe_path", "a path escapes the installation root")
    }

    private fun prepareDirectory(target: Path) {
        if (Files.isSymbolicLink(target)) {
            throw fail("unsafe_entry", "a directory would replace a symlink")
        }
        val parent = target.parent ?: root
        createParents(parent)
        if (Files.exists(target, java.nio.file.LinkOption.NOFOLLOW_LINKS) && !Files.isDirectory(target)) {
            throw fail("unsafe_entry", "a directory would replace a file")
        }
        Files.createDirectories(target)
    }

    private fun prepareFile(target: Path) {
        createParents(target.parent ?: root)
        if (Files.isDirectory(target, java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
            throw fail("unsafe_entry", "a file would replace a directory")
        }
        Files.deleteIfExists(target)
    }

    private fun prepareSymlink(target: Path) {
        createParents(target.parent ?: root)
        if (Files.isDirectory(target, java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
            throw fail("unsafe_entry", "a symlink would replace a directory")
        }
        Files.deleteIfExists(target)
    }

    /**
     * Create [directory] and every missing parent, then prove the real path is
     * still inside the root. That second check is the one a symlink-escape tar
     * trips: a parent the archive created as a link to the outside would
     * resolve out of the tree before the first byte is written.
     */
    private fun createParents(directory: Path) {
        Files.createDirectories(directory)
        val real = directory.toRealPath()
        if (!real.startsWith(root.toRealPath())) {
            throw fail("unsafe_path", "a parent directory resolves outside the installation root")
        }
    }

    private fun applyMode(path: Path, mode: Int) {
        val permissions = permissionsOf(mode)
        try {
            Files.setPosixFilePermissions(path, permissions)
        } catch (_: UnsupportedOperationException) {
            // A filesystem without POSIX modes keeps the platform default.
        }
    }

    private fun permissionsOf(mode: Int): Set<PosixFilePermission> {
        val permissions = mutableSetOf<PosixFilePermission>()
        if (mode and 0b100_000_000 != 0) permissions += PosixFilePermission.OWNER_READ
        if (mode and 0b010_000_000 != 0) permissions += PosixFilePermission.OWNER_WRITE
        if (mode and 0b001_000_000 != 0) permissions += PosixFilePermission.OWNER_EXECUTE
        if (mode and 0b000_100_000 != 0) permissions += PosixFilePermission.GROUP_READ
        if (mode and 0b000_010_000 != 0) permissions += PosixFilePermission.GROUP_WRITE
        if (mode and 0b000_001_000 != 0) permissions += PosixFilePermission.GROUP_EXECUTE
        if (mode and 0b000_000_100 != 0) permissions += PosixFilePermission.OTHERS_READ
        if (mode and 0b000_000_010 != 0) permissions += PosixFilePermission.OTHERS_WRITE
        if (mode and 0b000_000_001 != 0) permissions += PosixFilePermission.OTHERS_EXECUTE
        return permissions
    }

    private fun fail(reason: String, detail: String): Fail = Fail("$reason: $detail")

    private class Fail(message: String) : IOException(message)

    private class TarReader(private val input: InputStream) {
        private val header = ByteArray(BLOCK)

        /** The next real header, or `null` at the two zero blocks that end a tar. */
        fun nextHeader(): TarHeader? {
            val read = readFully(header, allowEof = true)
            if (read == 0) return null
            if (read != BLOCK) throw IOException("a truncated tar header")
            if (header.all { it == 0.toByte() }) {
                val second = ByteArray(BLOCK)
                val secondRead = readFully(second, allowEof = true)
                if (secondRead != 0 && secondRead != BLOCK) throw IOException("a truncated tar terminator")
                return null
            }
            val expected = octal(header, 148, 8)
            val actual = checksum()
            if (expected != actual) throw IOException("a tar header checksum mismatch")
            val magic = String(header, 257, 5, StandardCharsets.US_ASCII)
            if (magic != "ustar") throw IOException("an unrecognized tar header")
            val prefix = string(header, 345, 155)
            val name = string(header, 0, 100).let { if (prefix.isEmpty()) it else "$prefix/$it" }
            val type = header[156]
            return TarHeader(
                name = name,
                type = if (type == 0.toByte()) TYPE_FILE else type,
                size = octal(header, 124, 12),
                linkName = string(header, 157, 100),
                mode = octal(header, 100, 8).toInt(),
            )
        }

        fun readAll(size: Long): ByteArray {
            if (size < 0 || size > MAX_META_BYTES) throw IOException("an oversized tar metadata entry")
            val bytes = ByteArray(size.toInt())
            readFully(bytes, allowEof = false)
            skipPadding(size)
            return bytes
        }

        fun copyData(size: Long, output: java.io.OutputStream) {
            var remaining = size
            val buffer = ByteArray(COPY_BUFFER)
            while (remaining > 0) {
                val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (read < 0) throw IOException("a truncated tar entry")
                output.write(buffer, 0, read)
                remaining -= read
            }
            skipPadding(size)
        }

        private fun skipPadding(size: Long) {
            val padding = ((BLOCK - (size % BLOCK)) % BLOCK).toInt()
            if (padding == 0) return
            val skipped = input.skip(padding.toLong())
            if (skipped == padding.toLong()) return
            val buffer = ByteArray(padding)
            readFully(buffer, allowEof = false)
        }

        private fun readFully(target: ByteArray, allowEof: Boolean): Int {
            var offset = 0
            while (offset < target.size) {
                val read = input.read(target, offset, target.size - offset)
                if (read < 0) {
                    if (offset == 0 && allowEof) return 0
                    throw IOException("a truncated tar stream")
                }
                offset += read
            }
            return offset
        }

        private fun checksum(): Long {
            var sum = 0L
            for (index in header.indices) {
                val byte = if (index in 148..155) 0x20 else header[index].toInt() and 0xFF
                sum += byte
            }
            return sum
        }

        private fun string(bytes: ByteArray, offset: Int, length: Int): String =
            String(bytes, offset, length, StandardCharsets.UTF_8).substringBefore('\u0000')

        private fun octal(bytes: ByteArray, offset: Int, length: Int): Long {
            val text = String(bytes, offset, length, StandardCharsets.US_ASCII)
                .substringBefore('\u0000')
                .trim()
            if (text.isEmpty()) return 0L
            return text.toLongOrNull(8) ?: throw IOException("a non-octal tar number")
        }

        companion object {
            const val BLOCK = 512
            private const val COPY_BUFFER = 64 * 1024
            private const val MAX_META_BYTES = 1024 * 1024L
        }
    }

    private data class TarHeader(
        val name: String,
        val type: Byte,
        val size: Long,
        val linkName: String,
        val mode: Int,
    )

    private object PaxRecords {
        fun parse(payload: ByteArray): Map<String, String> {
            val records = mutableMapOf<String, String>()
            var index = 0
            while (index < payload.size) {
                var space = -1
                for (position in index until payload.size) {
                    if (payload[position] == ' '.code.toByte()) {
                        space = position
                        break
                    }
                }
                if (space < 0) break
                val length = String(payload, index, space - index, StandardCharsets.US_ASCII).toIntOrNull()
                    ?: break
                if (length <= 0 || index + length > payload.size) break
                val record = String(payload, space + 1, index + length - space - 2, StandardCharsets.UTF_8)
                val equals = record.indexOf('=')
                if (equals > 0) records[record.substring(0, equals)] = record.substring(equals + 1)
                index += length
            }
            return records
        }
    }

    companion object {
        private const val TYPE_FILE: Byte = '0'.code.toByte()
        private const val TYPE_FILE_OLD: Byte = 0
        private const val TYPE_HARDLINK: Byte = '1'.code.toByte()
        private const val TYPE_SYMLINK: Byte = '2'.code.toByte()
        private const val TYPE_DIR: Byte = '5'.code.toByte()
        private const val TYPE_GNU_LONG_NAME: Byte = 'L'.code.toByte()
        private const val TYPE_GNU_LONG_LINK: Byte = 'K'.code.toByte()
        private const val TYPE_PAX: Byte = 'x'.code.toByte()
    }
}

/** Deletes [path] and every child; missing paths are not an error. */
internal fun deleteTree(path: Path) {
    if (!Files.exists(path, java.nio.file.LinkOption.NOFOLLOW_LINKS)) return
    Files.walk(path).use { stream ->
        stream.sorted(Comparator.reverseOrder()).forEach { entry ->
            try {
                Files.deleteIfExists(entry)
            } catch (failure: IOException) {
                throw IOException("cannot delete $entry", failure)
            }
        }
    }
}

// phone-dsh — :engine tests: the wal.md §8 boot overlay bytes.
// SPDX-License-Identifier: MIT
//
// What these tests pin, and why each one is a failure this lane exists to close:
//   * entries are only `home/...` and `workspace/...` — the runtime's
//     `loadVfsOverlay` throws for any other first segment, so a `tmp/` or `wal/`
//     entry would fail the boot, and a missing tree would seed an empty view;
//   * the envelope is one gzip member around a ustar — the runtime's
//     `storage/image-gzip.ts` refuses a plain tar by name;
//   * a tree over the cap is refused, never truncated — a truncated overlay is an
//     incomplete view, which is the data-loss shape this lane fixes;
//   * pack is deterministic, so "same tree, same bytes" is a property a later
//     reviewer can rely on.

package com.phonedsh.engine

import java.io.ByteArrayInputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermission
import java.util.zip.GZIPInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class BootOverlayTest {
    // ------------------------------------------------------------ entry subset

    @Test
    fun theOverlayCarriesOnlyHomeAndWorkspace() {
        val root = Files.createTempDirectory("pdsh-overlay-subset")
        writeFile(root.resolve("materialized/home/AGENTS.md"), "# agent\n")
        writeFile(root.resolve("materialized/workspace/notes/a.txt"), "hello\n")
        // Present in a real workspace root, and must never appear in the overlay.
        writeFile(root.resolve("materialized/tmp/scratch"), "volatile")
        writeFile(root.resolve("materialized/wal/000001.wal"), "wal")
        writeFile(root.resolve("materialized/manifest.json"), "{}")
        writeFile(root.resolve("materialized/steps/step-1.json"), "{}")

        val pack = pack(root, target = root.resolve("overlay.tar"))
        val entries = parse(ustar(pack.file))

        assertEquals(
            listOf(
                "home/",
                "home/AGENTS.md",
                "workspace/",
                "workspace/notes/",
                "workspace/notes/a.txt",
            ),
            entries.map { it.name }.sorted(),
        )
        assertTrue("the overlay must never carry tmp/", entries.none { it.name.startsWith("tmp") })
        assertTrue("the overlay must never carry the WAL", entries.none { it.name.startsWith("wal") })
        assertTrue(
            "the overlay must never carry the manifest",
            entries.none { it.name.contains("manifest") },
        )
    }

    @Test
    fun aMissingTreeIsNotAnError() {
        val root = Files.createTempDirectory("pdsh-overlay-empty")
        Files.createDirectories(root.resolve("materialized/workspace"))
        val pack = pack(root, target = root.resolve("overlay.tar"))
        assertEquals(listOf("workspace/"), parse(ustar(pack.file)).map { it.name })
    }

    // ------------------------------------------------------------- envelope

    @Test
    fun theArchiveIsOneGzipMemberAroundAUstar() {
        val root = tree("home/AGENTS.md" to "agent\n", "workspace/x.txt" to "x")
        val pack = pack(root, target = root.resolve("overlay.tar"))
        val raw = Files.readAllBytes(pack.file)
        assertTrue("a gzip member must start 1f 8b", raw[0] == 0x1f.toByte() && raw[1] == 0x8b.toByte())
        val tar = ustar(pack.file)
        assertEquals("ustar", String(tar, 257, 5, Charsets.US_ASCII))
        assertEquals("00", String(tar, 263, 2, Charsets.US_ASCII))
        assertEquals(
            "the runtime's tar reader walks the archive",
            "home/AGENTS.md",
            parse(tar).first { it.name == "home/AGENTS.md" }.name,
        )
    }

    @Test
    fun modesAndContentsRoundTrip() {
        val root = Files.createTempDirectory("pdsh-overlay-modes")
        val script = root.resolve("materialized/workspace/run.sh")
        writeFile(script, "#!/bin/sh\n")
        Files.setPosixFilePermissions(
            script,
            setOf(
                PosixFilePermission.OWNER_READ,
                PosixFilePermission.OWNER_WRITE,
                PosixFilePermission.OWNER_EXECUTE,
            ),
        )
        val pack = pack(root, target = root.resolve("overlay.tar"))
        val entry = parse(ustar(pack.file)).first { it.name == "workspace/run.sh" }
        assertEquals(0b111_000_000, entry.mode)
        assertEquals("#!/bin/sh\n", String(entry.bytes, Charsets.UTF_8))
        assertEquals(10L, entry.declaredSize)
    }

    @Test
    fun theSameTreePacksToTheSameBytes() {
        val root = tree("home/a" to "one", "workspace/b" to "two")
        val first = pack(root, target = root.resolve("first.tar"))
        val second = pack(root, target = root.resolve("second.tar"))
        assertTrue(
            "a deterministic pack is what makes the watermark retry meaningful",
            Files.readAllBytes(first.file).contentEquals(Files.readAllBytes(second.file)),
        )
    }

    @Test
    fun aLongNameUsesThePrefixField() {
        val root = Files.createTempDirectory("pdsh-overlay-long")
        val longName = "segment-".repeat(8) + "file.txt" // 78 bytes, under the name field
        writeFile(root.resolve("materialized/workspace/$longName"), "long")
        val deep = "workspace/" + "d".repeat(90) + "/" + "n".repeat(90) + ".txt"
        writeFile(root.resolve("materialized").resolve(deep), "deep")
        val pack = pack(root, target = root.resolve("overlay.tar"))
        val tar = ustar(pack.file)
        val entries = parse(tar)
        assertTrue(entries.any { it.name == deep })
    }

    // ------------------------------------------------------------- refusals

    @Test
    fun anOversizedTreeIsRefusedNotTruncated() {
        val root = Files.createTempDirectory("pdsh-overlay-large")
        writeFile(root.resolve("materialized/workspace/big.bin"), "x".repeat(4096))
        val target = root.resolve("overlay.tar")
        try {
            BootOverlayPacker(root.resolve("materialized"), maxArchiveBytes = 1024).pack(target)
            fail("a tree over the cap must be refused")
        } catch (refused: BootOverlayException) {
            assertEquals(BootOverlayException.Refusal.TOO_LARGE, refused.refusal)
            assertEquals(1024L, refused.limit)
            assertTrue("the refusal must name the size it would have needed", refused.bytes > 1024L)
        }
        assertFalse("no partial overlay may survive a refusal", Files.exists(target))
    }

    @Test
    fun aSymlinkIsRefused() {
        val root = Files.createTempDirectory("pdsh-overlay-symlink")
        writeFile(root.resolve("materialized/workspace/real.txt"), "real")
        Files.createSymbolicLink(
            root.resolve("materialized/workspace/link.txt"),
            root.resolve("materialized/workspace/real.txt"),
        )
        try {
            pack(root, target = root.resolve("overlay.tar"))
            fail("the Worker VFS has no symlink model, so a symlink must be refused")
        } catch (refused: BootOverlayException) {
            assertEquals(BootOverlayException.Refusal.SYMLINK, refused.refusal)
            assertEquals("workspace/link.txt", refused.entry)
        }
    }

    @Test
    fun aNameThatCannotFitTheUstarSplitIsRefused() {
        val root = Files.createTempDirectory("pdsh-overlay-name")
        // 120 bytes with no '/', and no parent segment to move into the prefix.
        writeFile(root.resolve("materialized/workspace/" + "n".repeat(120)), "x")
        try {
            pack(root, target = root.resolve("overlay.tar"))
            fail("a name that cannot fit must be refused, never truncated")
        } catch (refused: BootOverlayException) {
            assertEquals(BootOverlayException.Refusal.PATH_TOO_LONG, refused.refusal)
        }
    }

    // ------------------------------------------------------------- the source

    @Test
    fun theSourceWritesAMemberAndReportsTheRouteShape() = run {
        val root = Files.createTempDirectory("pdsh-overlay-source")
        writeFile(root.resolve("materialized/workspace/one.txt"), "1")
        val source = MaterializedBootOverlaySource(
            materializedDirectory = root.resolve("materialized"),
            outputDirectory = root.resolve("boot-overlay"),
            maxArchiveBytes = 1 shl 20,
            logger = RecordingEngineLogger(),
            watermark = { 42L },
            idSource = { "0123456789abcdef0123456789abcdef" },
        )
        val snapshot = source.packBlocking()
        assertEquals("/image/overlay/0123456789abcdef0123456789abcdef.tar", snapshot.urlPath)
        assertEquals(42L, snapshot.watermark)
        assertEquals("application/gzip", snapshot.contentType)
        assertTrue(Files.isRegularFile(snapshot.file))
        assertEquals("0123456789abcdef0123456789abcdef.tar", snapshot.file.fileName.toString())
        assertEquals("workspace/", parse(ustar(snapshot.file)).first().name)
        assertNull("a successful pack clears the last refusal", source.lastRefusal())
    }

    @Test
    fun aSnapshotThatStraddlesAMaterializationIsDiscarded() = run {
        val root = Files.createTempDirectory("pdsh-overlay-watermark")
        writeFile(root.resolve("materialized/workspace/one.txt"), "1")
        val marks = ArrayDeque(listOf(1L, 2L, 2L, 2L))
        val ids = ArrayDeque(
            listOf(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            ),
        )
        val source = MaterializedBootOverlaySource(
            materializedDirectory = root.resolve("materialized"),
            outputDirectory = root.resolve("boot-overlay"),
            maxArchiveBytes = 1 shl 20,
            logger = RecordingEngineLogger(),
            watermark = { marks.removeFirst() },
            idSource = { ids.removeFirst() },
        )
        val snapshot = source.packBlocking()
        // The first attempt saw 1 -> 2 and was thrown away; the accepted one saw 2 -> 2.
        assertEquals(2L, snapshot.watermark)
        assertEquals("/image/overlay/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.tar", snapshot.urlPath)
        assertFalse(
            "the straddling snapshot must not survive on disk",
            Files.exists(root.resolve("boot-overlay/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tar")),
        )
    }

    @Test
    fun aRefusedTreeIsNeverServed() = run {
        val root = Files.createTempDirectory("pdsh-overlay-refused")
        writeFile(root.resolve("materialized/workspace/big.bin"), "x".repeat(4096))
        val source = MaterializedBootOverlaySource(
            materializedDirectory = root.resolve("materialized"),
            outputDirectory = root.resolve("boot-overlay"),
            maxArchiveBytes = 1024,
            logger = RecordingEngineLogger(),
            watermark = { 1L },
        )
        try {
            source.packBlocking()
            fail("a refused pack must throw, never return a smaller overlay")
        } catch (refused: BootOverlayException) {
            assertEquals(BootOverlayException.Refusal.TOO_LARGE, refused.refusal)
        }
        assertEquals(
            "no member may exist after a refusal",
            0,
            Files.list(root.resolve("boot-overlay")).use { stream -> stream.count() }.toInt(),
        )
        assertEquals(BootOverlayException.Refusal.TOO_LARGE, source.lastRefusal()?.refusal)
    }

    @Test
    fun onlyTheNewestMembersAreKept() = run {
        val root = Files.createTempDirectory("pdsh-overlay-prune")
        writeFile(root.resolve("materialized/workspace/one.txt"), "1")
        val ids = ArrayDeque(
            listOf(
                "11111111111111111111111111111111",
                "22222222222222222222222222222222",
                "33333333333333333333333333333333",
            ),
        )
        val source = MaterializedBootOverlaySource(
            materializedDirectory = root.resolve("materialized"),
            outputDirectory = root.resolve("boot-overlay"),
            maxArchiveBytes = 1 shl 20,
            logger = RecordingEngineLogger(),
            watermark = { 1L },
            idSource = { ids.removeFirst() },
            keepFiles = 2,
        )
        repeat(3) { source.packBlocking() }
        val members = Files.list(root.resolve("boot-overlay")).use { stream ->
            stream.map { it.fileName.toString() }.sorted().toList()
        }
        assertEquals(
            listOf("22222222222222222222222222222222.tar", "33333333333333333333333333333333.tar"),
            members,
        )
    }

    // ------------------------------------------------------------- the responder

    @Test
    fun theOverlayIsServedUnderItsExactPathOnly() {
        val root = Files.createTempDirectory("pdsh-overlay-route")
        val member = root.resolve("0123456789abcdef0123456789abcdef.tar")
        writeFile(member, "bytes")
        val served = ServedAsset(
            urlPath = "/image/overlay/0123456789abcdef0123456789abcdef.tar",
            file = member,
            contentType = "application/gzip",
        )
        val responder = LoopbackAssetResponder(
            store = WorkerFileStore(Files.createTempDirectory("pdsh-overlay-bundle")),
            port = 1234,
            logger = RecordingEngineLogger(),
            servedAssets = { listOf(served) },
        )
        val resolved = responder.resolveAsset(served.urlPath)
        assertNotNull(resolved)
        assertEquals("application/gzip", resolved!!.contentType)
        assertEquals(served.urlPath, responder.resolveAsset("${served.urlPath}?token=ignored")?.urlPath)
        assertNull(
            "the route is matched exactly, never resolved by walking the lookup",
            responder.resolveAsset("/image/overlay/../worker/image.tar.gz"),
        )
        assertNull(responder.resolveAsset("/image/overlay/unknown.tar"))
        assertNull(
            "a pruned member must fall through instead of crashing",
            responder.resolveAsset("/image/overlay/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tar"),
        )
    }

    // ------------------------------------------------------------- helpers

    private fun pack(root: Path, target: Path): BootOverlayPack =
        BootOverlayPacker(root.resolve("materialized"), maxArchiveBytes = 8L shl 20).pack(target)

    private fun tree(vararg files: Pair<String, String>): Path {
        val root = Files.createTempDirectory("pdsh-overlay-tree")
        for ((name, body) in files) writeFile(root.resolve("materialized").resolve(name), body)
        return root
    }

    private fun writeFile(path: Path, body: String) {
        Files.createDirectories(path.parent)
        Files.write(path, body.toByteArray(Charsets.UTF_8))
    }

    /** The ustar inside the one gzip member; fails the test when the body is not gzip. */
    private fun ustar(member: Path): ByteArray =
        Files.newInputStream(member).use { input ->
            GZIPInputStream(ByteArrayInputStream(input.readBytes())).use { gzip -> gzip.readBytes() }
        }

    private data class Entry(
        val name: String,
        val mode: Int,
        val declaredSize: Long,
        val bytes: ByteArray,
    )

    /** A test-only ustar reader: enough to assert the bytes the runtime will parse. */
    private fun parse(tar: ByteArray): List<Entry> {
        val entries = mutableListOf<Entry>()
        var offset = 0
        while (offset + 512 <= tar.size) {
            val header = tar.copyOfRange(offset, offset + 512)
            if (header.all { it == 0.toByte() }) break
            val name = field(header, 0, 100)
            val prefix = field(header, 345, 155)
            val fullName = if (prefix.isEmpty()) name else "$prefix/$name"
            val mode = field(header, 100, 8).trim().toInt(8)
            val declaredSize = field(header, 124, 12).trim().toInt(8).toLong()
            val start = offset + 512
            val end = start + declaredSize.toInt()
            assertTrue("an entry's bytes must be inside the archive", end <= tar.size)
            entries += Entry(
                name = fullName,
                mode = mode,
                declaredSize = declaredSize,
                bytes = tar.copyOfRange(start, end),
            )
            offset = start + ((declaredSize + 511) / 512 * 512).toInt()
        }
        assertTrue("a ustar must end with two zero blocks", offset + 1024 <= tar.size)
        return entries
    }

    private fun field(header: ByteArray, offset: Int, length: Int): String {
        var end = offset
        while (end < offset + length && header[end] != 0.toByte()) end++
        return String(header, offset, end - offset, Charsets.UTF_8)
    }
}

/** Runs the suspend pack from a plain JUnit test. */
private fun MaterializedBootOverlaySource.packBlocking(): BootOverlaySnapshot =
    kotlinx.coroutines.runBlocking { pack() }

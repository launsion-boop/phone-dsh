// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest

/**
 * Checks the real merged-asset directory that AGP packs into the AAR. The
 * directory is supplied by `android/lib/build.gradle.kts` through
 * `pdsh.merged.assets`, so this test cannot pass against a hand-made copy.
 *
 * The manifest is `spec/ui/v1/bot/fish/golden/assets.json`; `SOURCES.md` is
 * provenance and is checked for presence only (the grant text is owned by the
 * spec lane, not this test).
 */
class BotFishAssetManifestTest {
    private val mergedAssets: Path by lazy {
        val property = System.getProperty("pdsh.merged.assets")
            ?: error("pdsh.merged.assets is not set; run this test through Gradle")
        Path.of(property)
    }

    @Test
    fun `every frozen BotFish file is in the merged assets with its byte size and hash`() {
        val manifest = SpecFixtures.repoJson("spec/ui/v1/bot/fish/golden/assets.json")
        val entries = (manifest["files"] as JsonArray).values.map { it as JsonObject }
        assertEquals(35, entries.size)

        val root = mergedAssets.resolve("BotFish")
        assertTrue("merged BotFish assets missing at $root", Files.isDirectory(root))

        val expectedRelative = LinkedHashSet<String>()
        for (entry in entries) {
            val relative = entry.str("path")
            expectedRelative += relative
            val file = root.resolve(relative)
            assertTrue("merged asset missing: BotFish/$relative", Files.isRegularFile(file))
            assertEquals(
                "byte size drifted for BotFish/$relative",
                entry.long("bytes"),
                Files.size(file),
            )
            assertEquals(
                "SHA-256 drifted for BotFish/$relative",
                entry.str("sha256"),
                sha256(file),
            )
        }

        val provenance = root.resolve("SOURCES.md")
        assertTrue("merged BotFish provenance missing: $provenance", Files.isRegularFile(provenance))
        expectedRelative += "SOURCES.md"

        val actualRelative = Files.walk(root).use { stream ->
            stream.filter { Files.isRegularFile(it) }
                .map { root.relativize(it).toString().replace('\\', '/') }
                .toList()
                .toSet()
        }
        assertEquals(
            "merged BotFish file set differs from the manifest + provenance",
            expectedRelative,
            actualRelative,
        )
    }

    private fun JsonObject.str(key: String): String =
        (this[key] as? JsonString)?.value ?: error("missing string $key")

    private fun JsonObject.long(key: String): Long =
        (this[key] as com.phonedsh.agentcore.JsonNumber).asLongOrNull()
            ?: error("missing integer $key")

    private fun sha256(path: Path): String {
        val digest = MessageDigest.getInstance("SHA-256")
        Files.newInputStream(path).use { stream ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

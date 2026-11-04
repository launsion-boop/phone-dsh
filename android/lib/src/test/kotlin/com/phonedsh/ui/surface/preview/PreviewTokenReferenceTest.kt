// The preview face's token discipline, read against the real `tokens.json`.
// SPDX-License-Identifier: MIT
//
// `PageTokenReferenceTest` covers the files under `ui/page/`; the preview face lives
// under `ui/surface/preview/`, so it needs the same three rules or it would be the
// one screen in the app that may type its own lengths:
//
//   1. every token the preview reads exists in `spec/ui/v1/tokens.json`;
//   2. no preview file re-types a length (`12.dp`) or a colour (`Color(0x…)`);
//   3. every preview file carries the license header on line 2.
//
// The inventory is *derived*, not declared: the files are read from disk and every
// `tokens.<family>.<name>` / `type.<style>` reference is extracted, so a new
// reference is checked the moment it is written — there is no list to forget to
// update (that is what made the page layer's declared inventories worth reviewing).
package com.phonedsh.ui.surface.preview

import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.tokenNames
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewTokenReferenceTest {

    @Test
    fun `the preview face exists where the test expects it`() {
        assertTrue(
            "the preview sources moved: ${previewDirectory()}",
            Files.isDirectory(previewDirectory()),
        )
        assertTrue("no preview sources found", sources().isNotEmpty())
    }

    @Test
    fun `every token the preview reads exists in tokens json`() {
        val known = SpecFixtures.tokenNames()
        sources().forEach { (name, source) ->
            references(source).forEach { reference ->
                assertTrue(
                    "$name reads '$reference', which is not a token in spec/ui/v1/tokens.json",
                    reference in known,
                )
            }
        }
    }

    @Test
    fun `no preview file re-types a length or a colour`() {
        sources().forEach { (name, source) ->
            val lengths = LENGTH_LITERAL.findAll(source).map { it.value }.toList()
            assertTrue("$name re-types a length: $lengths", lengths.isEmpty())
            val colours = COLOUR_LITERAL.findAll(source).map { it.value }.toList()
            assertTrue("$name re-types a colour: $colours", colours.isEmpty())
        }
    }

    @Test
    fun `every preview file carries the license header on line 2`() {
        sources().keys.forEach { name ->
            val lines = Files.readAllLines(previewDirectory().resolve(name))
            assertEquals("$name: line 2 must be the SPDX header", SPDX, lines[1])
        }
    }

    @Test
    fun `the preview reads typography through the theme, never a pixel size`() {
        sources().forEach { (name, source) ->
            val hardSizes = FONT_SIZE_LITERAL.findAll(source).map { it.value }.toList()
            assertTrue("$name sets a font size directly: $hardSizes", hardSizes.isEmpty())
        }
    }

    // ------------------------------------------------------------------ helpers

    private fun sources(): Map<String, String> {
        val directory = previewDirectory()
        if (!Files.isDirectory(directory)) return emptyMap()
        val found = sortedMapOf<String, String>()
        Files.list(directory).use { stream ->
            stream.filter { it.fileName.toString().endsWith(".kt") }
                .forEach { path ->
                    val name = path.fileName.toString()
                    found[name] = readText(path)
                }
        }
        return found
    }

    /** `Files.readString` is Java 11 and absent from the Android SDK stubs. */
    private fun readText(path: Path): String = String(Files.readAllBytes(path), Charsets.UTF_8)

    private fun previewDirectory(): Path =
        SpecFixtures.repoRoot.resolve(
            "android/lib/src/main/kotlin/com/phonedsh/ui/surface/preview",
        )

    /** Every token spelling the file reads through the theme locals. */
    private fun references(source: String): List<String> {
        val direct = TOKEN_REF.findAll(source).map { "${it.groupValues[1]}.${it.groupValues[2]}" }
        val typography = TYPOGRAPHY_REF.findAll(source)
            .map { "typography.${it.groupValues[1]}" }
            .filter { it in KNOWN_TYPOGRAPHY }
        return (direct + typography).toSet().toList()
    }

    private companion object {
        const val SPDX: String = "// SPDX-License-Identifier: MIT"

        val KNOWN_TYPOGRAPHY: Set<String> = SpecFixtures.tokenNames()

        val TOKEN_REF: Regex = Regex("""tokens\.(colors|spacing|radius|stroke|motion|geometry)\.([A-Za-z0-9_]+)""")
        val TYPOGRAPHY_REF: Regex = Regex("""(?:type|LocalUiType\.current)\.([A-Za-z0-9_]+)""")

        /** A bare dp/sp value; `screenWidthDp.dp` is a platform read, not a literal. */
        val LENGTH_LITERAL: Regex = Regex("""\b\d+(?:\.\d+)?\.(?:dp|sp)\b""")

        /** A colour constructor or a named Compose colour; both are a second source. */
        val COLOUR_LITERAL: Regex =
            Regex("""Color\(\s*0x|androidx\.compose\.ui\.graphics\.Color\.(White|Black|Red|Gray|Blue)""")

        /** `fontSize = 13.sp` would be a typography value outside the token table. */
        val FONT_SIZE_LITERAL: Regex = Regex("""fontSize\s*=""")
    }
}

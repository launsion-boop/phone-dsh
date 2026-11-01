// Token discipline for the P5 K2 pages: they read the theme and never re-type a
// SPDX-License-Identifier: MIT
// token value (a literal colour, dp or sp), and every visible string comes from
// `UiStrings`.
//
// The six signature surfaces are pinned token-by-token by `TokenReferenceTest`.
// The settings/tools/files/memory/about pages are semantic-only (§4), so their
// guard is a source check: a literal would be a second source of values, which
// `spec/ui/v1/tokens.json` being the single source forbids.
package com.phonedsh.ui.page

import com.phonedsh.ui.SpecFixtures
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path

class PageSourceDisciplineTest {
    private val pageDir: Path =
        SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/page")

    /** Every page source this lane owns. */
    private val pages: List<String> = listOf(
        "PageScaffold.kt",
        "SettingsPage.kt",
        "ToolsPage.kt",
        "FilesPage.kt",
        "MemoryPage.kt",
        "AboutPage.kt",
    )

    @Test
    fun `page sources carry no literal colour, dp or sp`() {
        pages.forEach { name ->
            val text = read(name)
            assertFalse("$name: a literal Color(0x…) is a second colour source", COLOUR.containsMatchIn(text))
            assertFalse("$name: a literal dp is a second geometry source", DP.containsMatchIn(text))
            assertFalse("$name: a literal sp is a second typography source", SP.containsMatchIn(text))
        }
    }

    @Test
    fun `page sources read the theme (directly or through the shared frame) and the shared copy`() {
        pages.forEach { name ->
            val text = read(name)
            assertTrue(
                "$name: no token source (neither LocalUiTokens nor the shared page frame)",
                text.contains("com.phonedsh.ui.theme.LocalUiTokens") ||
                    text.contains("PageFrame(") ||
                    text.contains("pageListGap"),
            )
            assertTrue("$name: copy must come from UiStrings", text.contains("com.phonedsh.ui.UiStrings"))
        }
    }

    @Test
    fun `every page source has the SPDX line on line 2`() {
        pages.forEach { name ->
            val lines = Files.readAllLines(pageDir.resolve(name))
            assertTrue("$name: file is empty", lines.size >= 2)
            assertTrue(
                "$name: line 2 must be the SPDX identifier, was '${lines[1]}'",
                lines[1] == "// SPDX-License-Identifier: MIT",
            )
        }
    }

    private fun read(name: String): String = String(Files.readAllBytes(pageDir.resolve(name)), Charsets.UTF_8)

    private companion object {
        private val COLOUR = Regex("""\bColor\(\s*0x""")
        private val DP = Regex("""\b\d+(?:\.\d+)?\.dp\b""")
        private val SP = Regex("""\b\d+(?:\.\d+)?\.sp\b""")
    }
}

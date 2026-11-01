// Page token discipline: the session pages read `spec/ui/v1/tokens.json`, nothing else.
// SPDX-License-Identifier: MIT
//
// The six signature surfaces already have `TokenReferenceTest`; this test gives the
// page layer the same rule, without touching the surface inventory:
//  1. every token a page reads exists in `tokens.json` (read from the spec here);
//  2. each page's declared inventory equals the tokens its source actually reads, so
//     a new reference cannot slip past review and a stale entry fails too;
//  3. no page re-types a length (`12.dp`) or a colour (`Color(0x...)`): a value that
//     is not a token is an invented value;
//  4. every page consumes the system-bar insets (targetSdk 35 edge-to-edge);
//  5. every page that reads a page-layer geometry token marks the reuse with
//     `unverified geometry`, so `tokens.json`'s missing page geometry stays visible;
//  6. every page file carries the license header on line 2.
//
// The test reads the real spec file, never a copy, so a spec edit reaches it.
package com.phonedsh.ui.page

import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.surfaces
import com.phonedsh.ui.tokenNames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path

class PageTokenReferenceTest {
    /** The pages this lane owns, with the inventory object each file declares. */
    private val pages: Map<String, List<String>> = mapOf(
        "ChatPage.kt" to ChatPageTokens.refs,
        "ChatRows.kt" to ChatRowsTokens.refs,
        "SessionPageChrome.kt" to SessionPageChromeTokens.refs,
        "SessionsPage.kt" to SessionsPageTokens.refs,
        "SessionHistoryPage.kt" to SessionHistoryPageTokens.refs,
        "SessionActivityPage.kt" to SessionActivityPageTokens.refs,
        // The N5 mirror lane: the files page and the commands page declare the
        // same inventory as the session pages, so an extra or missing token use
        // fails here too.
        "FilesPage.kt" to FilesPageTokens.refs,
        "ToolsPage.kt" to ToolsPageTokens.refs,
        "GoalDetailPage.kt" to GoalDetailTokens.refs,
        // The two pages that landed after this test was written. Listing them here is
        // what makes the equality assertion below bite: an unlisted page silently
        // escaped the inventory check until its file was added to this map.
        "NativeWorkbenchPage.kt" to NativeWorkbenchPageTokens.refs,
        "WorkspaceFoldersPage.kt" to WorkspaceFoldersPageTokens.refs,
        "ModelProviderSettingsPage.kt" to ModelProviderSettingsPageTokens.refs,
        "WebSearchSettingsPage.kt" to WebSearchSettingsPageTokens.refs,
        "MCPSettingsPage.kt" to MCPSettingsPageTokens.refs,
        "MCPEditorPage.kt" to MCPEditorPageTokens.refs,
        "RuntimeDetailsPage.kt" to RuntimeDetailsTokens.refs,
        "EgressAllowListPage.kt" to EgressAllowListTokens.refs,
        "NativeAutomationPage.kt" to NativeAutomationPageTokens.refs,
        "NativeConfigurationPage.kt" to NativeConfigurationPageTokens.refs,
        "WebSurfacePage.kt" to WebSurfacePageTokens.refs,
        "ProbesPage.kt" to ProbesPageTokens.refs,
        "BackgroundPage.kt" to BackgroundPageTokens.refs,
        "ExportPage.kt" to ExportPageTokens.refs,
        "DailyBriefPage.kt" to DailyBriefPageTokens.refs,
        "TaskScreenPage.kt" to TaskScreenPageTokens.refs,
        // N4 lane: the mirrored settings index and the memory probe.
        "SettingsPage.kt" to SettingsPageTokens.refs,
        "MemoryPage.kt" to MemoryPageTokens.refs,
    )

    @Test
    fun `every token a page reads exists in tokens json`() {
        val known = SpecFixtures.tokenNames()
        pages.forEach { (file, declared) ->
            (references(file) + declared).forEach { reference ->
                assertTrue(
                    "$file reads '$reference', which is not a token in spec/ui/v1/tokens.json",
                    reference in known,
                )
            }
        }
    }

    @Test
    fun `each page declares exactly the tokens its source reads`() {
        pages.forEach { (file, declared) ->
            assertEquals(
                "$file: the declared inventory must equal the tokens the file reads",
                references(file).sorted(),
                declared.toSet().sorted(),
            )
        }
    }

    @Test
    fun `no page re-types a length or a colour`() {
        pages.keys.forEach { file ->
            val source = source(file)
            val lengths = LENGTH_LITERAL.findAll(source).map { it.value }.toList()
            assertTrue("$file re-types a length: $lengths", lengths.isEmpty())
            val colours = COLOUR_LITERAL.findAll(source).map { it.value }.toList()
            assertTrue("$file re-types a colour: $colours", colours.isEmpty())
        }
    }

    @Test
    fun `every page consumes the system bar insets`() {
        pages.keys.forEach { file ->
            val source = source(file)
            if (file == "ChatRows.kt" || file == "SessionPageChrome.kt") return@forEach
            val hasFrame = source.contains("PageFrame(")
            val hasRoot = source.contains("WindowInsets.safeDrawing")
            assertTrue(
                "$file must consume the insets itself (WindowInsets.safeDrawing) or delegate to PageFrame",
                hasFrame || hasRoot,
            )
        }
        // The chat page owns its insets: status bar above the header, IME + navigation
        // bar below the dock (spec §5 rows `insets` and `ime`).
        val chat = source("ChatPage.kt")
        assertTrue(chat.contains("statusBarsPadding()"))
        assertTrue(chat.contains("navigationBarsPadding()"))
        assertTrue(chat.contains("imePadding()"))
        assertTrue(chat.contains("WindowInsets.safeDrawing"))
    }

    @Test
    fun `a page that reuses geometry says so`() {
        // The marker is about **borrowed** geometry, not about geometry in general: a
        // page that reads a page-level token (one no signature surface declares) is
        // using the token for exactly its purpose and has nothing to disclose. The
        // earlier file-level rule fired on any geometry reference, which made a
        // correct page fail and would have taught the next person to sprinkle the
        // marker until the test went quiet.
        val surfaceOwned = SpecFixtures.surfaces().flatMap { it.tokens }
            .filter { it.startsWith("geometry.") }
            .map { it.removePrefix("geometry.") }
            .toSet()

        pages.keys.forEach { file ->
            val source = source(file)
            val borrowed = surfaceOwned.filter { source.contains("tokens.geometry.$it") }
            if (borrowed.isEmpty()) return@forEach
            assertTrue(
                "$file borrows signature-surface geometry $borrowed without an " +
                    "`unverified geometry` note",
                source.contains("unverified geometry"),
            )
        }
    }

    @Test
    fun `every page carries the license header on line 2`() {
        pages.keys.forEach { file ->
            val lines = Files.readAllLines(pageDir().resolve(file))
            assertEquals("$file: line 2 must be the SPDX header", SPDX, lines[1])
        }
    }

    /** Every token spelling the file's source reads through the theme locals. */
    private fun references(file: String): List<String> {
        val source = source(file)
        val direct = TOKEN_REF.findAll(source).map { "${it.groupValues[1]}.${it.groupValues[2]}" }
        val typography = TYPOGRAPHY_REF.findAll(source)
            .map { "typography.${it.groupValues[1]}" }
            .filter { it in SPEC_TOKENS }
        return (direct + typography).toSet().toList()
    }

    private fun source(file: String): String =
        String(Files.readAllBytes(pageDir().resolve(file)), Charsets.UTF_8)

    private fun pageDir(): Path =
        SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/page")

    private companion object {
        const val SPDX: String = "// SPDX-License-Identifier: MIT"
        val SPEC_TOKENS: Set<String> = SpecFixtures.tokenNames()

        val TOKEN_REF: Regex = Regex("""tokens\.(colors|spacing|radius|stroke|motion|geometry)\.([A-Za-z0-9_]+)""")
        val TYPOGRAPHY_REF: Regex = Regex("""(?:type|LocalUiType\.current)\.([A-Za-z0-9_]+)""")

        /** A bare dp/sp value; `screenHeightDp.dp` is a platform read, not a literal. */
        val LENGTH_LITERAL: Regex = Regex("""\b\d+(?:\.\d+)?\.(?:dp|sp)\b""")

        /** A colour constructor or a named Compose colour; both are a second source. */
        val COLOUR_LITERAL: Regex = Regex("""Color\(\s*0x|androidx\.compose\.ui\.graphics\.Color\.(White|Black|Red|Gray|Blue)""")
    }
}

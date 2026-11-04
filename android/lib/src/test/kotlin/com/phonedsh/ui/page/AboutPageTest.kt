// About page: real branding content, package facts and honest unknowns.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class AboutPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val facts = AboutFacts(version = "0.1.0", buildNumber = "42")

    private fun show(
        facts: AboutFacts,
        onBack: () -> Unit = {},
        onOpenLicenses: (() -> Unit)? = null,
        onOpenDeveloper: (() -> Unit)? = null,
    ) {
        val state = AboutScreenState.from(facts)
        compose.setContent {
            PdshTheme {
                AboutPage(
                    state = state,
                    onToggleSection = {},
                    onBack = onBack,
                    onOpenLicenses = onOpenLicenses,
                    onOpenDeveloper = onOpenDeveloper,
                )
            }
        }
    }

    /** `NativeShell.swift:842-864`: branding content plus one package facts card. */
    @Test
    fun `about with no package facts renders actual brand content and no invented values`() {
        val state = AboutScreenState.from(AboutFacts())
        assertEquals(listOf(AboutScreenState.VERSION_SECTION_ID), state.sections.map { it.id })
        val rows = state.sections.single().rows
        assertEquals(listOf(UiStrings.ABOUT_SECTION_VERSION, "构建"), rows.map { it.title })
        assertEquals(listOf(UiStrings.UNKNOWN, UiStrings.UNKNOWN), rows.map { it.value })
        show(AboutFacts())
        compose.onNodeWithTag(UiTags.ABOUT_LIST).assertIsDisplayed()
        compose.onNodeWithTag("pdsh.about.brand-logo").assertIsDisplayed()
        compose.onNodeWithText("Phone DSH").assertIsDisplayed()
        compose.onNodeWithText("运行在手机上的 DeepSeek Harness").assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.UNKNOWN).assertCountEquals(2)
        compose.onNodeWithText(UiStrings.ABOUT_LOCAL_NOTE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ABOUT_DEVELOPER).assertDoesNotExist()
    }

    @Test
    fun `measured package version and build render and the licenses row navigates when wired`() {
        var licenses = 0
        show(facts, onOpenLicenses = { licenses += 1 })
        compose.onNodeWithText(UiStrings.ABOUT_LICENSES).assertIsDisplayed()
        compose.onNodeWithText("0.1.0").assertIsDisplayed()
        compose.onNodeWithText("构建").assertIsDisplayed()
        compose.onNodeWithText("42").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ABOUT_LOCAL_NOTE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ABOUT_LICENSES).performClick()
        assertEquals(1, licenses)
        compose.onNodeWithText(UiStrings.ABOUT_DEVELOPER).assertDoesNotExist()
    }

    @Test
    fun `the debug developer entry appears only when the build has one`() {
        var developers = 0
        show(
            facts.copy(developerEntry = true),
            onOpenLicenses = {},
            onOpenDeveloper = { developers += 1 },
        )
        compose.onNodeWithText(UiStrings.ABOUT_DEVELOPER).performClick()
        assertEquals(1, developers)
    }

    /**
     * A host that cannot read the platform draws no 系统 card, and a sub-page with
     * no callback is **not drawn at all** rather than drawn as 不可用: the
     * baseline's about page has no licenses row to disable.
     */
    @Test
    fun `unread version and build are explicit and an unwired sub-page draws no row`() {
        show(facts.copy(version = null, buildNumber = null), onOpenLicenses = null)
        compose.onAllNodesWithText(UiStrings.UNKNOWN).assertCountEquals(2)
        compose.onNodeWithText(UiStrings.ABOUT_API_LEVEL).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.ABOUT_LICENSES).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.UNAVAILABLE).assertDoesNotExist()
    }

    /**
     * L74: there is no section header to fold.
     *
     * The baseline draws no header and no disclosure (`NativeShell.swift:842-864`),
     * so the section titles are no longer on screen and a tap on the card does not
     * hide the rows it holds.
     */
    @Test
    fun `branding and package rows are content rather than section headers`() {
        show(facts)
        compose.onNodeWithText("Phone DSH").assertIsDisplayed()
        compose.onNodeWithText("构建").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ABOUT_SECTION_SYSTEM).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.ABOUT_API_LEVEL).assertDoesNotExist()
    }

    @Test
    fun `about footnote is on the page background below the package card`() {
        show(facts)
        val card = compose.onNodeWithTag("pdsh.settings.about.version-card").getUnclippedBoundsInRoot()
        val footnote = compose.onNodeWithText(UiStrings.ABOUT_LOCAL_NOTE).getUnclippedBoundsInRoot()
        assertTrue("About footnote must begin below the white package card", footnote.top >= card.bottom)
        assertEquals(SettingsMetrics.ROW_CONTENT_INSET_PT.toFloat(), footnote.left.value, 1f)
    }

    @Test
    fun `pushed about returns through back chrome without sheet handle`() {
        var back = 0
        show(facts, onBack = { back += 1 })
        compose.onNodeWithText(PAGE_BACK_GLYPH).performClick()
        assertEquals(1, back)
        compose.onNodeWithTag("settings-sheet-drag-handle").assertDoesNotExist()
        compose.onNodeWithText(SETTINGS_CLOSE_GLYPH).assertDoesNotExist()
    }

    /** §3.1: same facts + same fold script → same state sequence, sections in order. */
    @Test
    fun `the about fold sequence is a pure function of the script`() {
        val script = listOf(
            AboutUiEvent.ToggleSection("about.version"),
            AboutUiEvent.ToggleSection("about.system"),
        )
        var local = AboutLocalState()
        val states = buildList {
            add(AboutScreenState.from(facts, local))
            script.forEach { event ->
                local = local.apply(event)
                add(AboutScreenState.from(facts, local))
            }
        }
        states.forEach { state ->
            // One card only: the 系统 appendix is not part of the page (L79), and
            // `facts` carries no developer entry so the 更多 card is absent too.
            assertEquals(listOf(AboutScreenState.VERSION_SECTION_ID), state.sections.map { it.id })
        }
        // The fold script still folds the model (it is the host's vocabulary); the
        // page simply has no header to drive it with any more.
        assertEquals(listOf(true, false, false), states.map { it.sections[0].expanded })
        var replay = AboutLocalState()
        val replayed = buildList {
            add(AboutScreenState.from(facts, replay))
            script.forEach { event ->
                replay = replay.apply(event)
                add(AboutScreenState.from(facts, replay))
            }
        }
        assertEquals(states, replayed)
    }
}

// About page: version/platform facts, the fold sequence and the honest unknowns.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class AboutPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val facts = AboutFacts(
        version = "0.1.0",
        build = "42",
        platform = PlatformInfo(
            sdkInt = 34,
            release = "14",
            abi = "arm64-v8a",
            deviceModel = "test-device",
            webViewVersion = "120.0",
        ),
    )

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

    /** No facts at all: every value is 未知, and no version is invented. */
    @Test
    fun `about with no facts renders unknown values instead of a fallback version`() {
        val state = AboutScreenState.from(AboutFacts())
        val version = state.sections.single { it.id == "about.version" }.rows
        assertEquals(listOf(UiStrings.UNKNOWN, UiStrings.UNKNOWN), version.map { it.value })
        val system = state.sections.single { it.id == "about.system" }.rows
        assertEquals(5, system.size)
        assertEquals(7, system.plus(version).count { it.value == UiStrings.UNKNOWN })
        // The DEBUG-only developer entry does not exist in this build, so its row is absent.
        assertEquals(
            listOf(AboutScreenState.LICENSES_ROW_ID),
            state.sections.single { it.id == "about.more" }.rows.map { it.id },
        )
        show(AboutFacts())
        compose.onNodeWithTag(UiTags.ABOUT_LIST).assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.UNKNOWN).assertCountEquals(7)
        compose.onNodeWithText(UiStrings.ABOUT_DEVELOPER).assertDoesNotExist()
    }

    @Test
    fun `measured facts render their values and the licenses action navigates`() {
        var licenses = 0
        show(facts, onOpenLicenses = { licenses += 1 })
        compose.onNodeWithText("0.1.0").assertIsDisplayed()
        compose.onNodeWithText("42").assertIsDisplayed()
        compose.onNodeWithText("14").assertIsDisplayed()
        compose.onNodeWithText("34").assertIsDisplayed()
        compose.onNodeWithText("arm64-v8a").assertIsDisplayed()
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
     * A host that cannot read the platform still gets five honest 未知 rows; a
     * sub-page without a callback reads 不可用 instead of pretending it opens.
     */
    @Test
    fun `an unread platform and an unwired sub-page are reported as unknown and unavailable`() {
        show(facts.copy(platform = null, version = null, build = null), onOpenLicenses = null)
        compose.onAllNodesWithText(UiStrings.UNKNOWN).assertCountEquals(7)
        compose.onNodeWithText(UiStrings.UNAVAILABLE).assertIsDisplayed()
    }

    @Test
    fun `a section folds and unfolds from its header`() {
        compose.setContent {
            var local by remember { mutableStateOf(AboutLocalState()) }
            PdshTheme {
                AboutPage(
                    state = AboutScreenState.from(facts, local),
                    onToggleSection = { id -> local = local.apply(AboutUiEvent.ToggleSection(id)) },
                    onBack = {},
                )
            }
        }
        compose.onNodeWithText(UiStrings.ABOUT_API_LEVEL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ABOUT_SECTION_SYSTEM).performClick()
        compose.onNodeWithText(UiStrings.ABOUT_API_LEVEL).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.ABOUT_SECTION_SYSTEM).performClick()
        compose.onNodeWithText(UiStrings.ABOUT_API_LEVEL).assertIsDisplayed()
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
            assertEquals(listOf("about.version", "about.system", "about.more"), state.sections.map { it.id })
        }
        assertEquals(listOf(true, false, false), states.map { it.sections[0].expanded })
        assertEquals(listOf(true, true, false), states.map { state -> state.sections[1].expanded })
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

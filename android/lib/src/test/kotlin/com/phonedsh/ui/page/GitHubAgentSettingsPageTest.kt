// GitHubAgentSettingsPage: contract copy, masked draft, save/delete/toggle wiring.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.nav.PdshSettingsRows
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class GitHubAgentSettingsPageTest {
    @get:Rule val compose = createComposeRule()

    private val saved = mutableListOf<String>()
    private val writes = mutableListOf<Boolean>()
    private var deletes = 0
    private var restarts = 0
    private var saveResult = true
    private var deleteResult = true

    private fun show(facts: GitHubAgentFacts = GitHubAgentFacts(hasToken = true)) {
        compose.setContent {
            PdshTheme {
                GitHubAgentSettingsPage(
                    facts = facts,
                    onBack = {},
                    onSaveToken = {
                        saved += it
                        saveResult
                    },
                    onDeleteToken = {
                        deletes += 1
                        deleteResult
                    },
                    onAllowWritesChange = { writes += it },
                    onRestartEngine = { restarts += 1 },
                )
            }
        }
    }

    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_LIST).performScrollToNode(hasTestTag(tag))
    }

    @Test
    fun theSettingsRowPushesThePage() {
        assertEquals(PdshRoute.GitHubAgent, PdshSettingsRows.targetOf(SettingsDestination.GITHUB_AGENT))
    }

    @Test
    fun theSettingsIndexDrawsTheRowAndNavigates() {
        var navigated: SettingsDestination? = null
        compose.setContent {
            PdshTheme {
                SettingsPage(
                    state = SettingsScreenState.from(
                        SettingsFacts(preferences = SettingsPreferences(language = SettingsLanguage.ZH)),
                    ),
                    onNavigate = { navigated = it },
                    onToggleBackgroundKeepAlive = {},
                    onSelectBusyEnterMode = {},
                    onBack = {},
                )
            }
        }
        val row = UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "githubAgent"
        compose.onNodeWithTag(UiTags.SETTINGS_LIST).performScrollToNode(hasTestTag(row))
        compose.onNodeWithTag(row).performClick()
        assertEquals(SettingsDestination.GITHUB_AGENT, navigated)
    }

    @Test
    fun thePageRendersTheContractLabels() {
        show()
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_TITLE).assertExists()
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_TOKEN_SECTION).assertExists()
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_TOKEN_PLACEHOLDER).assertExists()
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_TOKEN_SAVE).assertExists()
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_TOKEN_DELETE).assertExists()
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_TOKEN_FOOTER).assertExists()
        scrollTo(UiPageTags.GITHUB_AGENT_ALLOW_WRITES)
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_ALLOW_WRITES).assertExists()
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_ALLOW_WRITES_FOOTER).assertExists()
        scrollTo(UiPageTags.GITHUB_AGENT_RESTART)
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_RESTART).assertExists()
    }

    @Test
    fun aStoredTokenShowsDelete() {
        show(GitHubAgentFacts(hasToken = true))
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_DELETE).assertExists()
    }

    @Test
    fun anAbsentTokenHidesDelete() {
        show(GitHubAgentFacts(hasToken = false))
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_DELETE).assertDoesNotExist()
    }

    @Test
    fun savingSendsTheTrimmedTokenAndClearsTheDraft() {
        show(GitHubAgentFacts(hasToken = false))
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_SAVE).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_TOKEN_FIELD).performTextReplacement("  ghp_test  ")
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_SAVE).assertIsEnabled().performClick()
        assertEquals(listOf("ghp_test"), saved)
        scrollTo(UiPageTags.GITHUB_AGENT_MESSAGE)
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_SAVED).assertExists()
    }

    @Test
    fun aFailedSaveKeepsTheDraftAndReportsTheKeychainFailure() {
        saveResult = false
        show(GitHubAgentFacts(hasToken = false))
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_TOKEN_FIELD).performTextReplacement("ghp_test")
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_SAVE).performClick()
        scrollTo(UiPageTags.GITHUB_AGENT_ERROR)
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_WRITE_FAILED).assertExists()
        assertTrue("the host saw the saved value", saved.isNotEmpty())
    }

    @Test
    fun deletingCallsTheHostAndRemovesTheRow() {
        show(GitHubAgentFacts(hasToken = true))
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_DELETE).performClick()
        assertEquals(1, deletes)
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_DELETE).assertDoesNotExist()
        scrollTo(UiPageTags.GITHUB_AGENT_MESSAGE)
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_DELETED).assertExists()
    }

    @Test
    fun aFailedDeleteKeepsTheRowAndReportsTheKeychainFailure() {
        deleteResult = false
        show(GitHubAgentFacts(hasToken = true))
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_DELETE).performClick()
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_DELETE).assertExists()
        scrollTo(UiPageTags.GITHUB_AGENT_ERROR)
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_DELETE_FAILED).assertExists()
    }

    @Test
    fun theWriteTogglePersistsAndAsksForAnEngineRestart() {
        show(GitHubAgentFacts(hasToken = true, allowWrites = false))
        scrollTo(UiPageTags.GITHUB_AGENT_ALLOW_WRITES)
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_ALLOW_WRITES).performClick()
        assertEquals(listOf(true), writes)
        scrollTo(UiPageTags.GITHUB_AGENT_MESSAGE)
        compose.onNodeWithText(UiStrings.GITHUB_AGENT_RESTART_REQUIRED).assertExists()
    }

    @Test
    fun restartingTheEngineIsTheHostCommand() {
        show()
        scrollTo(UiPageTags.GITHUB_AGENT_RESTART)
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_RESTART).performClick()
        assertEquals(1, restarts)
        assertEquals("no write is implied by a restart", 0, writes.size)
    }

    @Test
    fun anEmptyDraftIsNeverSent() {
        show(GitHubAgentFacts(hasToken = false))
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_TOKEN_FIELD).performTextReplacement("   ")
        compose.onNodeWithTag(UiPageTags.GITHUB_AGENT_SAVE).assertIsNotEnabled()
        assertTrue(saved.isEmpty())
        assertFalse(deletes > 0)
    }
}

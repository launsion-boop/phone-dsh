// Scheduled automation's nested route and editor sheet use the real platform UI.
// SPDX-License-Identifier: MIT

package com.phonedsh.ui.nav

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.page.AutomationFacts
import com.phonedsh.ui.page.AutomationScheduleDraft
import com.phonedsh.ui.page.AutomationSnapshot
import com.phonedsh.ui.page.AutomationUiEvent
import com.phonedsh.ui.page.NativeAutomationPage
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import androidx.compose.ui.test.junit4.createAndroidComposeRule

@RunWith(AndroidJUnit4::class)
class PdshAutomationRouteDeviceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun catalogSheetLaunchesEditorSavesTypedDraftToHostAndCancelsBackIntoParent() {
        val actions = mutableListOf<PdshHostAction>()
        compose.setContent {
            PdshTheme {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Automation)),
                    facts = PdshNavFacts(
                        automation = AutomationFacts(
                            snapshot = AutomationSnapshot(schedules = emptyList()),
                            currentSessionID = "worker-session-1",
                        ),
                    ),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = { actions += it },
                    home = { androidx.compose.foundation.text.BasicText("home") },
                    webSurface = {},
                )
            }
        }
        compose.waitForIdle()

        compose.onNodeWithTag(UiPageTags.AUTOMATION_NEW).assertIsDisplayed().performClick()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_NAME).performTextInput("周报")
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_PROMPT).performTextInput("总结这一周")
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_SAVE).performClick()
        compose.waitForIdle()

        val save = actions.filterIsInstance<PdshHostAction.SaveAutomationSchedule>().single()
        assertEquals("周报", save.draft.title)
        assertEquals("总结这一周", save.draft.prompt)
        assertTrue(save.submissionID.isNotBlank())
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_CANCEL).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_EDITOR_ROOT).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.AUTOMATION_ROOT).assertIsDisplayed()
    }
}

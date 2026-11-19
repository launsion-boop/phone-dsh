// SPDX-License-Identifier: MIT
//
// PhonePermissionsPage.swift `dshApprovalSection` / `nextStepsUsageSection` parity:
// both sections render between the capability groups and the audit, show their
// empty line, and offer the clear action only when there is something to clear.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasTestTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.bot.state.BotNextStepsMetrics
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PhonePermissionsLocalSectionsTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(
        facts: PhonePermissionsFacts,
        onClearApprovals: () -> Unit = {},
        onClearUsage: () -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme {
                PhonePermissionsPage(
                    state = PhonePermissionsScreenState.from(facts),
                    onClearDshApprovals = onClearApprovals,
                    onClearNextStepsUsage = onClearUsage,
                )
            }
        }
    }

    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.PHONE_PERMISSIONS_LIST).performScrollToNode(hasTestTag(tag))
    }

    @Test
    fun `empty stores show the baseline's empty lines and no clear actions`() {
        show(PhonePermissionsFacts(dshApprovals = emptyList(), nextStepsUsage = BotNextStepsMetrics.Snapshot(0, 0)))
        scrollTo(UiPageTags.PHONE_PERMISSIONS_DSH_APPROVALS)
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_DSH_APPROVALS_SECTION).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_DSH_APPROVALS_EMPTY).assertIsDisplayed()
        scrollTo(UiPageTags.PHONE_PERMISSIONS_NEXT_STEPS)
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_NEXT_STEPS_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_DSH_APPROVALS_CLEAR).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_NEXT_STEPS_CLEAR).assertDoesNotExist()
    }

    @Test
    fun `grants and usage are listed and each clear action reaches the host`() {
        var clearedApprovals = 0
        var clearedUsage = 0
        show(
            PhonePermissionsFacts(
                dshApprovals = listOf(DshApprovalGrantRow("session-1", "bash:read-only", System.currentTimeMillis())),
                nextStepsUsage = BotNextStepsMetrics.Snapshot(turnsWithOptions = 4, turnsWithStepsCard = 3),
            ),
            onClearApprovals = { clearedApprovals += 1 },
            onClearUsage = { clearedUsage += 1 },
        )
        scrollTo(UiPageTags.PHONE_PERMISSIONS_DSH_APPROVALS)
        compose.onNodeWithText("bash:read-only").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_DSH_APPROVALS_SESSION.format("session-1")).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_DSH_APPROVALS_CLEAR).performClick()
        assertEquals(1, clearedApprovals)

        scrollTo(UiPageTags.PHONE_PERMISSIONS_NEXT_STEPS)
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_NEXT_STEPS_OPTIONS.format(4)).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_NEXT_STEPS_CARDS.format(3)).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_NEXT_STEPS_RATE.format(75)).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_NEXT_STEPS_CLEAR).performClick()
        assertEquals(1, clearedUsage)
    }

    @Test
    fun `an unreported store says so instead of claiming none`() {
        show(PhonePermissionsFacts())
        scrollTo(UiPageTags.PHONE_PERMISSIONS_DSH_APPROVALS)
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_DSH_APPROVALS_UNKNOWN).assertIsDisplayed()
        scrollTo(UiPageTags.PHONE_PERMISSIONS_NEXT_STEPS)
        compose.onNodeWithText(UiStrings.PHONE_PERMISSIONS_NEXT_STEPS_UNKNOWN).assertIsDisplayed()
    }
}

// Signature surface 4/6: the approval card (JVM + Robolectric).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
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
@Config(sdk = [34])
class ApprovalCardSurfaceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `the card shows title, subtitle and both actions`() {
        compose.setContent {
            PdshTheme {
                ApprovalCard(
                    title = UiStrings.APPROVAL_TITLE,
                    subtitle = "exec 请求执行 id",
                    primaryLabel = UiStrings.ALLOW_ONCE,
                    onPrimary = {},
                    secondaryLabel = UiStrings.DENY,
                    onSecondary = {},
                )
            }
        }
        compose.onNodeWithTag(UiTags.APPROVAL_CARD).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.APPROVAL_TITLE).assertIsDisplayed()
        compose.onNodeWithText("exec 请求执行 id").assertIsDisplayed()
        compose.onNodeWithTag(UiTags.APPROVAL_PRIMARY).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.APPROVAL_SECONDARY).assertIsDisplayed()
    }

    @Test
    fun `the two actions are separately clickable`() {
        var accepted = 0
        var denied = 0
        compose.setContent {
            PdshTheme {
                ApprovalCard(
                    title = "需要授权",
                    subtitle = "allow exec?",
                    primaryLabel = UiStrings.ALLOW_ONCE,
                    onPrimary = { accepted += 1 },
                    secondaryLabel = UiStrings.DENY,
                    onSecondary = { denied += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiTags.APPROVAL_PRIMARY).performClick()
        compose.onNodeWithTag(UiTags.APPROVAL_SECONDARY).performClick()
        assertEquals(1, accepted)
        assertEquals(1, denied)
    }

    @Test
    fun `a card without a decline action hides the second button`() {
        compose.setContent {
            PdshTheme {
                ApprovalCard(
                    title = "需要回答",
                    subtitle = "pick one",
                    primaryLabel = UiStrings.SUBMIT_ANSWER,
                    onPrimary = {},
                )
            }
        }
        compose.onNodeWithTag(UiTags.APPROVAL_SECONDARY).assertDoesNotExist()
    }

    @Test
    fun `the folded second ask is one tappable line`() {
        var expanded = 0
        compose.setContent {
            PdshTheme {
                FoldedPendingRow(label = UiStrings.MORE_PENDING, onExpand = { expanded += 1 })
            }
        }
        compose.onNodeWithText(UiStrings.MORE_PENDING).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MORE_PENDING).performClick()
        assertEquals(1, expanded)
    }
}

// Code block: the three header/footer controls the iOS DSSCodeBlock carries.
// SPDX-License-Identifier: MIT
//
// `Components.swift:151-225` is the mirror: a 28 x 28 wrap toggle, a copy action
// that turns into 已复制 for one second, and — only for a long block — the
// 展开全部 N 行 / 收起 tail. These tests pin the controls, not their pixels; the
// capture sheet is what checks the geometry.
package com.phonedsh.ui.surface

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class CodeBlockSurfaceTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(body: String) {
        compose.setContent {
            PdshTheme {
                CodeBlock(language = "swift", body = body)
            }
        }
    }

    @Test
    fun `a short block has the wrap toggle and the copy action but no tail`() {
        show("let scheme = \"PhoneDSHProbe\"")
        compose.onNodeWithTag(CODE_WRAP_TAG).assertIsDisplayed()
        compose.onNodeWithTag(CODE_COPY_TAG).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MESSAGE_COPY).assertIsDisplayed()
        compose.onNodeWithTag(CODE_EXPAND_TAG).assertDoesNotExist()
    }

    @Test
    fun `copy reports 已复制 before it reverts`() {
        show("let scheme = \"PhoneDSHProbe\"")
        compose.mainClock.autoAdvance = false
        compose.onNodeWithTag(CODE_COPY_TAG).performClick()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText(UiStrings.MESSAGE_COPIED).assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.MESSAGE_COPIED).assertExists()
        compose.mainClock.advanceTimeBy(1_000L)
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText(UiStrings.MESSAGE_COPY).assertIsDisplayed()
        compose.onNodeWithContentDescription(UiStrings.CODE_COPY_ACTION).assertExists()
    }

    @Test
    fun `the wrap toggle flips its accessibility state`() {
        show("let scheme = \"PhoneDSHProbe\"")
        // Wrapped initially: the control offers 关闭自动换行.
        compose.onNodeWithContentDescription(UiStrings.CODE_WRAP_OFF).assertExists()
        compose.onNodeWithTag(CODE_WRAP_TAG).performClick()
        compose.onNodeWithContentDescription(UiStrings.CODE_WRAP_ON).assertExists()
    }

    @Test
    fun `a long block shows the expand tail and collapses again`() {
        val body = (1..30).joinToString("\n") { "line $it" }
        show(body)
        val expand = UiStrings.CODE_EXPAND_ALL.format(30)
        compose.onNodeWithText(expand).assertIsDisplayed()
        compose.onNodeWithText(expand).performClick()
        compose.onNodeWithText(UiStrings.CODE_COLLAPSE).assertIsDisplayed()
    }
}

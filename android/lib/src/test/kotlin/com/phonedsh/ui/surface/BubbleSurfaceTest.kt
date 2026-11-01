// Signature surface 1/6, rendered on the JVM through Robolectric.
// SPDX-License-Identifier: MIT
//
// Compose UI tests run as JVM unit tests (`:lib:testDebugUnitTest`) with
// Robolectric's Android runtime, not on an emulator: `createComposeRule()` plus
// `@Config(sdk = [34])`. Every assertion is a semantics/text assertion on a test
// tag — the six signature surfaces are the only place a screenshot could ever be
// compared, and that artifact is not part of this suite.
package com.phonedsh.ui.surface

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.page.ChatRowList
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class BubbleSurfaceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `both roles render their text on the bubble tag`() {
        compose.setContent {
            PdshTheme {
                androidx.compose.foundation.layout.Column {
                    ChatBubble(BubbleRole.USER, "我发送的消息")
                    ChatBubble(BubbleRole.ASSISTANT, "助手的回答")
                }
            }
        }
        compose.onNodeWithText("我发送的消息").assertIsDisplayed()
        compose.onNodeWithText("助手的回答").assertIsDisplayed()
        compose.onAllNodesWithTag(UiTags.BUBBLE).assertCountEquals(2)
    }

    @Test
    fun `the body token is emitted in sp so the platform scale is the only multiplier`() {
        // `typography.scale`: rendered size = baseSize x platform scale. On Android
        // that is only true when the theme emits `sp`; the base size and the
        // doubling below are the token rule, not a layout coincidence.
        val body = com.phonedsh.ui.theme.UiType.fromSpec().body
        assertTrue("the theme must emit sp, not px/dp", body.fontSize.isSp)
        val atOne = with(Density(1f, fontScale = 1f)) { body.fontSize.toPx() }
        val atTwo = with(Density(1f, fontScale = 2f)) { body.fontSize.toPx() }
        assertEquals("typography.body base size", 14f, atOne, 0.01f)
        // Android 14+ maps the scale through a non-linear font-scale converter, so
        // the growth is monotonic rather than exactly 2x; it must still be large.
        assertTrue("fontScale must grow the rendered size: $atOne -> $atTwo", atTwo > atOne * 1.5f)
        println("font-scale probe: atOne=$atOne atTwo=$atTwo")
    }

    @Test
    fun `the queue label renders its text`() {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                androidx.compose.foundation.layout.Column {
                    BubbleBadge(UiStrings.QUEUED_TAG)
                }
            }
        }
        compose.onNodeWithText(UiStrings.QUEUED_TAG).assertIsDisplayed()
    }

    @Test
    fun `the badge style is typography secondary in colors secondary`() {
        var style: TextStyle? = null
        compose.setContent {
            PdshTheme(darkTheme = false) {
                style = bubbleBadgeStyle()
            }
        }
        compose.waitForIdle()
        val resolved = requireNotNull(style) { "the badge style must resolve under PdshTheme" }
        assertTrue("the badge must emit sp, not px/dp", resolved.fontSize.isSp)
        assertEquals("typography.secondary base size", 13f, resolved.fontSize.value, 0f)
        assertEquals("colors.secondary light", Color(0xFF66666B), resolved.color)
    }

    @Test
    fun `a user row badge reaches the row renderer end to end`() {
        // The bug this pins is one layer above Bubble.kt: `ChatRow.User.badge`
        // existed in the state, but the row renderer dropped it before the
        // surface ever saw it. Rendering ChatBubble alone cannot catch that.
        compose.setContent {
            PdshTheme(darkTheme = false) {
                ChatRowList(
                    rows = listOf(
                        ChatRow.User("row-queued", "把这周的日志按天归档", UiStrings.QUEUED_TAG),
                        ChatRow.User("row-plain", "普通消息"),
                    ),
                    expandedRowIds = emptySet(),
                    onToggleRow = {},
                )
            }
        }
        compose.onAllNodesWithText(UiStrings.QUEUED_TAG).assertCountEquals(1)
        compose.onNodeWithText(UiStrings.QUEUED_TAG).assertIsDisplayed()
        // The label the row actually laid out: the style comes from the spec
        // tokens, not from a literal in the renderer (13 pt + #66666B).
        val label = compose
            .onNodeWithText(UiStrings.QUEUED_TAG, useUnmergedTree = true)
            .fetchSemanticsNode()
        val layouts = mutableListOf<TextLayoutResult>()
        label.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(layouts)
        val style = layouts.single().layoutInput.style
        assertTrue("the queue label must emit sp, not px/dp", style.fontSize.isSp)
        assertEquals("typography.secondary base size", 13f, style.fontSize.value, 0f)
        assertEquals("colors.secondary light", Color(0xFF66666B), style.color)
        // Row-level placement, not bubble-internal: iOS `queueLine` sits in a
        // leading VStack while `userBubble` is trailing, so the label starts at
        // the row's leading edge and the bubble hugs the trailing edge.
        val rootWidth = compose.onRoot().fetchSemanticsNode().boundsInRoot.width
        val labelBounds = label.boundsInRoot
        val bubbleBounds = compose
            .onAllNodesWithTag(UiTags.BUBBLE, useUnmergedTree = true)[0]
            .fetchSemanticsNode()
            .boundsInRoot
        assertTrue(
            "the queue label must sit below its bubble (label.top=${labelBounds.top}, bubble.bottom=${bubbleBounds.bottom})",
            labelBounds.top >= bubbleBounds.bottom,
        )
        assertTrue(
            "the queue label must start at the row's leading edge (label.left=${labelBounds.left}, root=$rootWidth)",
            labelBounds.left < rootWidth / 2f,
        )
        assertTrue(
            "the bubble must hug the row's trailing edge (bubble.right=${bubbleBounds.right}, root=$rootWidth)",
            bubbleBounds.right > rootWidth / 2f,
        )
        assertTrue(
            "the label must start left of the bubble (${labelBounds.left} vs ${bubbleBounds.left})",
            labelBounds.left < bubbleBounds.left,
        )
    }

    // Layout-level font scaling is NOT asserted here on purpose: Robolectric
    // returns fake font metrics, so a text box measures the same height at every
    // scale (verified: 35px at fontScale 1 and 2). The contract above is what the
    // JVM can prove; the rendered behaviour needs an instrumented test on a device
    // and is listed as an open item in the lane report.

}

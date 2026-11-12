// The "已编辑 N 个文件" card, rendered on the JVM through Robolectric.
// SPDX-License-Identifier: MIT
//
// The card is content, so the assertions are the strings and the row count the
// baseline shows, plus the behaviours iOS gives it: the fold at four files, the
// rows 5..N body *above* the toggle, the 0°→180° chevron, and the tap that routes
// a path to the host.
package com.phonedsh.ui.surface

import android.provider.Settings
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.disclosure.DisclosureKind
import com.phonedsh.ui.disclosure.DisclosureMotion
import com.phonedsh.ui.theme.PdshTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import kotlin.math.roundToLong

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class ChangedFilesCardSurfaceTest {
    @get:Rule
    val compose = createComposeRule()

    private fun files(count: Int): List<ChatFileChange> = (1..count).map { index ->
        ChatFileChange(
            path = "docs/design/phone-dsh-app/file$index.md",
            display = "docs/design/phone-dsh-app/file$index.md",
            added = 1,
            deleted = 1,
        )
    }

    @Test
    fun `six files show the count, the totals and the first four rows`() {
        compose.setContent {
            PdshTheme { ChangedFilesCard(files(6)) }
        }
        compose.onNodeWithText(UiStrings.CHANGED_FILES_TITLE.format(6)).assertIsDisplayed()
        // The header totals are the sum of the rows the card lists (iOS
        // `NativeChangedFiles.added` / `.deleted`).
        compose.onNodeWithText("+6").assertIsDisplayed()
        compose.onNodeWithText("-6").assertIsDisplayed()
        compose.onAllNodesWithTag(CHANGED_FILES_ROW_TAG).assertCountEquals(4)
        compose.onNodeWithText(UiStrings.CHANGED_FILES_ALL.format(6)).assertIsDisplayed()
        compose.onNodeWithTag(CHANGED_FILES_CHEVRON_TAG, useUnmergedTree = true).assertIsDisplayed()
    }

    @Test
    fun `the toggle opens the last two rows and becomes 收起`() {
        compose.setContent {
            PdshTheme { ChangedFilesCard(files(6)) }
        }
        val toggle = compose.onNodeWithTag(CHANGED_FILES_TOGGLE_TAG)
        toggle.assertContentDescriptionEquals(UiStrings.CHANGED_FILES_ALL.format(6))
        toggle.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.COLLAPSED))
        toggle.assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
        toggle.performClick()
        compose.onAllNodesWithTag(CHANGED_FILES_ROW_TAG).assertCountEquals(6)
        // The card is now taller than the test window; the label existing is what
        // the fold changes, not the scroll position.
        toggle.assertContentDescriptionEquals(UiStrings.CHANGED_FILES_COLLAPSE)
        toggle.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.EXPANDED))
        compose.onNodeWithText(UiStrings.CHANGED_FILES_COLLAPSE).assertExists()
        compose.onNodeWithText(UiStrings.CHANGED_FILES_ALL.format(6)).assertDoesNotExist()
    }

    @Test
    fun `expanding grows one body above the toggle, runs 160 ms, and rotates the chevron 180`() {
        Settings.Global.putFloat(
            ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
        var rotation = 0f
        compose.setContent {
            PdshTheme {
                ChangedFilesCardWithChevronObserver(
                    changes = files(6),
                    onChevronRotationChanged = { rotation = it },
                )
            }
        }
        val durationMs = DisclosureMotion.specFor(DisclosureKind.BODY, reducedMotion = false).durationMs
        compose.mainClock.autoAdvance = false
        val row4TopBefore = rowBounds(3).top
        val toggleTopBefore = nodeBounds(CHANGED_FILES_TOGGLE_TAG).top
        compose.onNodeWithTag(CHANGED_FILES_BODY_TAG).assertDoesNotExist()
        assertEquals("the chevron starts at zero", 0f, rotation, 0f)

        compose.onNodeWithTag(CHANGED_FILES_TOGGLE_TAG).performClick()
        compose.mainClock.advanceTimeByFrame()
        var attempts = 0
        while (attempts < 12 && runCatching { bodyHeightPx() }.getOrDefault(0f) <= 0.2f) {
            compose.mainClock.advanceTimeByFrame()
            attempts++
        }
        val early = bodyHeightPx()
        assertTrue("the extra file rows started animating (height=$early)", early > 0.2f)

        compose.mainClock.advanceTimeBy((durationMs / 2.0).roundToLong())
        val mid = bodyHeightPx()
        val midRotation = rotation
        assertTrue("the body is mid-motion at the half sample (height=$mid)", mid > 0.2f)
        assertTrue(
            "the chevron is between 0 and 180 degrees at the half sample (rotation=$midRotation)",
            midRotation > 0f && midRotation < 180f,
        )

        compose.mainClock.advanceTimeBy(durationMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        val end = bodyHeightPx()
        assertTrue("the body settles taller than the half sample ($mid -> $end)", end > mid)
        assertEquals("the chevron settles at 180 degrees", 180f, rotation, 0.01f)
        compose.onAllNodesWithTag(CHANGED_FILES_ROW_TAG).assertCountEquals(6)
        compose.onNodeWithTag(CHANGED_FILES_CHEVRON_TAG, useUnmergedTree = true).assertIsDisplayed()

        // iOS order (`NativeChangedFilesCard.swift:54-90`): rows 5..N are above
        // the toggle, not below it.
        val row5Top = rowBounds(4).top
        val toggleTopAfter = nodeBounds(CHANGED_FILES_TOGGLE_TAG).top
        assertTrue(
            "row 5 is above the toggle when expanded (row5=$row5Top, toggle=$toggleTopAfter)",
            row5Top < toggleTopAfter,
        )

        // `interaction.md` §7 rule 6: the growth happens below row 4, so nothing
        // above the toggle moves except by the body's own height.
        assertEquals(
            "rule 6: row 4's top is unchanged by expanding",
            row4TopBefore,
            rowBounds(3).top,
            0.5f,
        )
        assertEquals(
            "rule 6: the toggle moves down by exactly the body height",
            end,
            toggleTopAfter - toggleTopBefore,
            1f,
        )
    }

    @Test
    fun `animator duration scale zero snaps the body and the 180 degree chevron`() {
        Settings.Global.putFloat(
            ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            0f,
        )
        var rotation = 0f
        compose.setContent {
            PdshTheme {
                ChangedFilesCardWithChevronObserver(
                    changes = files(6),
                    onChevronRotationChanged = { rotation = it },
                )
            }
        }
        compose.mainClock.autoAdvance = false
        val row4TopBefore = rowBounds(3).top
        val toggleTopBefore = nodeBounds(CHANGED_FILES_TOGGLE_TAG).top
        compose.onNodeWithTag(CHANGED_FILES_BODY_TAG).assertDoesNotExist()
        assertEquals("the chevron starts at zero", 0f, rotation, 0f)

        compose.onNodeWithTag(CHANGED_FILES_TOGGLE_TAG).performClick()
        compose.mainClock.advanceTimeByFrame()

        assertEquals("reduced motion snaps the chevron", 180f, rotation, 0.01f)
        val bodyHeight = bodyHeightPx()
        assertEquals(
            "reduced motion skips every body frame",
            rowBounds(4).height + rowBounds(5).height,
            bodyHeight,
            0.5f,
        )
        assertEquals(
            "rule 6: row 4's top is unchanged by the snap",
            row4TopBefore,
            rowBounds(3).top,
            0.5f,
        )
        assertEquals(
            "rule 6: the toggle moves down by the snapped body height",
            bodyHeight,
            nodeBounds(CHANGED_FILES_TOGGLE_TAG).top - toggleTopBefore,
            1f,
        )
        compose.onAllNodesWithTag(CHANGED_FILES_ROW_TAG).assertCountEquals(6)
    }

    @Test
    fun `one file prints its name and has no list or toggle`() {
        val single = files(1)
        compose.setContent {
            PdshTheme { ChangedFilesCard(single) }
        }
        compose.onNodeWithText(UiStrings.CHANGED_FILES_SINGLE.format("file1.md")).assertIsDisplayed()
        compose.onAllNodesWithTag(CHANGED_FILES_ROW_TAG).assertCountEquals(0)
        compose.onAllNodesWithTag(CHANGED_FILES_TOGGLE_TAG).assertCountEquals(0)
    }

    @Test
    fun `a file row routes its path to the host`() {
        var opened: String? = null
        compose.setContent {
            PdshTheme { ChangedFilesCard(files(2), onOpenFile = { opened = it }) }
        }
        compose.onAllNodesWithTag(CHANGED_FILES_ROW_TAG)[0].performClick()
        assertEquals("docs/design/phone-dsh-app/file1.md", opened)
    }

    @Test
    fun `a later successful change for one path replaces the earlier row`() {
        val merged = mergeChangedFiles(
            listOf(
                ChatFileChange("a.md", "first display", 1, 2),
                ChatFileChange("b.md", "second", 2, 3),
                ChatFileChange("a.md", "latest display", 7, 8),
            ),
        )
        assertEquals(listOf("a.md", "b.md"), merged.map { it.path })
        assertEquals("latest display", merged.first().display)
        assertEquals(7, merged.first().added)
        assertEquals(8, merged.first().deleted)
    }

    @Test
    fun `an empty change list draws nothing`() {
        compose.setContent {
            PdshTheme { ChangedFilesCard(emptyList()) }
        }
        compose.onAllNodesWithTag(CHANGED_FILES_TAG).assertCountEquals(0)
    }

    private fun nodeBounds(tag: String) = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot

    private fun rowBounds(index: Int) =
        compose.onAllNodesWithTag(CHANGED_FILES_ROW_TAG)[index].fetchSemanticsNode().boundsInRoot

    private fun bodyHeightPx(): Float =
        compose.onNodeWithTag(CHANGED_FILES_BODY_TAG).fetchSemanticsNode().boundsInRoot.height

    @After
    fun restoreAnimatorScale() {
        Settings.Global.putFloat(
            ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
    }
}

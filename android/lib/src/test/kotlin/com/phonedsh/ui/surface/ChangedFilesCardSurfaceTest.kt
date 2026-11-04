// The "已编辑 N 个文件" card, rendered on the JVM through Robolectric.
// SPDX-License-Identifier: MIT
//
// The card is content, so the assertions are the strings and the row count the
// baseline shows, plus the two behaviours iOS gives it: the fold at four files and
// the tap that routes a path to the host.
package com.phonedsh.ui.surface

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
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
    }

    @Test
    fun `the toggle opens the last two rows and becomes 收起`() {
        compose.setContent {
            PdshTheme { ChangedFilesCard(files(6)) }
        }
        compose.onNodeWithTag(CHANGED_FILES_TOGGLE_TAG).performClick()
        compose.onAllNodesWithTag(CHANGED_FILES_ROW_TAG).assertCountEquals(6)
        // The card is now taller than the test window; the label existing is what
        // the fold changes, not the scroll position.
        compose.onNodeWithText(UiStrings.CHANGED_FILES_COLLAPSE).assertExists()
        compose.onNodeWithText(UiStrings.CHANGED_FILES_ALL.format(6)).assertDoesNotExist()
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
}

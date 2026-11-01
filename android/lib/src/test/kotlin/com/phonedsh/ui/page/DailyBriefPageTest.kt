// DailyBriefPage: the baseline header, items, source controls and swipe action.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §3.1 rule 3: the daily brief has no harness event anchor,
// so the host snapshot is the UiState-side input and the same snapshot sequence
// must replay to the same ScreenState sequence. The editor's fields and the
// swipe gesture are local UI events (§3.1 rule 2).
//
// These tests cover the lane's restored baseline controls: the source Toggle is a
// real Switch, delete is a trailing swipe (`SwipeToDismissBox`), and the add
// action opens the baseline's two-field form. A port that replaced the swipe with
// a visible button fails the swipe test on purpose.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class DailyBriefPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val itemTitle: String = "今天的头条"
    private val sourceUrl: String = "https://feeds.example.org/rss.xml"

    private fun measuredSnapshot(): DailyBriefSnapshot = DailyBriefSnapshot(
        lastSuccessText = "3 分钟前",
        lastAttemptText = "刚刚",
        refreshing = FactState.NO,
        report = DailyBriefReport(
            itemCount = 12,
            newItemCount = 3,
            networkBytes = 1536,
            modelCalls = 0,
            billingLabel = "实际",
        ),
        items = listOf(
            DailyBriefItem(
                id = "item-1",
                title = itemTitle,
                summary = "摘要",
                sourceName = "示例源",
                publishedText = "1 小时前",
                hasLink = true,
            ),
        ),
        sources = listOf(
            DailyBriefSource(
                id = "src-1",
                name = "示例源",
                url = sourceUrl,
                enabled = FactState.YES,
            ),
        ),
        issues = listOf(
            DailyBriefIssue(id = "issue-1", sourceName = "示例源", message = "解析失败"),
        ),
        shareText = "每日简报 12 条",
    )

    private fun show(
        state: DailyBriefScreenState,
        onRefresh: () -> Unit = {},
        onBack: (() -> Unit)? = null,
        onAddSource: ((String, String) -> Unit)? = null,
        onToggleSource: ((String, Boolean) -> Unit)? = null,
        onRemoveSource: ((String) -> Unit)? = null,
        onOpenItem: ((String) -> Unit)? = null,
        onShare: (() -> Unit)? = null,
        onRefreshIfNeeded: (() -> Unit)? = null,
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                DailyBriefPage(
                    state = state,
                    onRefresh = onRefresh,
                    onBack = onBack,
                    onAddSource = onAddSource,
                    onToggleSource = onToggleSource,
                    onRemoveSource = onRemoveSource,
                    onOpenItem = onOpenItem,
                    onShare = onShare,
                    onRefreshIfNeeded = onRefreshIfNeeded,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    /** Scroll one tagged row into the viewport before asserting it is displayed. */
    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.BRIEF_LIST).performScrollToNode(hasTestTag(tag))
        compose.onNodeWithTag(tag).assertIsDisplayed()
    }

    private fun textShown(text: String): Boolean =
        compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()

    // ---------------------------------------------------------------- baseline

    @Test
    fun `header keeps the success attempt report share and refresh-if-needed`() {
        val state = DailyBriefScreenState.from(DailyBriefFacts(snapshot = measuredSnapshot()))
        var shared = 0
        var refreshed = 0
        show(
            state,
            onShare = { shared += 1 },
            onRefreshIfNeeded = { refreshed += 1 },
        )
        compose.waitForIdle()
        assertEquals(1, refreshed)

        scrollTo(UiPageTags.BRIEF_HEADER)
        assertTrue(textShown(UiStrings.DAILY_BRIEF_TITLE))
        assertTrue(textShown(UiStrings.DAILY_BRIEF_LAST_SUCCESS.format("3 分钟前")))
        assertTrue(textShown(UiStrings.DAILY_BRIEF_LAST_ATTEMPT.format("刚刚")))
        scrollTo(UiPageTags.BRIEF_REPORT)
        assertTrue(textShown(UiStrings.DAILY_BRIEF_REPORT_ITEMS.format(12)))
        assertTrue(textShown(UiStrings.DAILY_BRIEF_REPORT_NEW.format(3)))
        assertTrue(textShown("网络 1.5 KiB · 模型 0 · 实际"))
        scrollTo(UiPageTags.BRIEF_SHARE)
        compose.onNodeWithTag(UiPageTags.BRIEF_SHARE).performClick()
        assertEquals(1, shared)
        compose.onNodeWithTag(UiPageTags.BRIEF_REFRESH).assertExists()
    }

    @Test
    fun `items sources and issues are the baseline blocks`() {
        val state = DailyBriefScreenState.from(DailyBriefFacts(snapshot = measuredSnapshot()))
        var opened: String? = null
        show(state, onOpenItem = { opened = it })

        scrollTo(UiPageTags.BRIEF_ITEMS)
        assertTrue(textShown(UiStrings.DAILY_BRIEF_SECTION_LATEST))
        scrollTo(UiPageTags.BRIEF_ITEM_PREFIX + "item-1")
        assertTrue(textShown(itemTitle))
        assertTrue(textShown("摘要"))
        assertTrue(textShown("1 小时前"))
        compose.onNodeWithTag(UiPageTags.BRIEF_ITEM_PREFIX + "item-1").performClick()
        assertEquals("item-1", opened)

        scrollTo(UiPageTags.BRIEF_SOURCES)
        assertTrue(textShown(sourceUrl))
        scrollTo(UiPageTags.BRIEF_ISSUE_PREFIX + "issue-1")
        assertTrue(textShown("解析失败"))
        assertTrue(textShown(UiStrings.DAILY_BRIEF_SECTION_ISSUES))
    }

    @Test
    fun `the source toggle is a switch and the delete is a trailing swipe`() {
        val state = DailyBriefScreenState.from(DailyBriefFacts(snapshot = measuredSnapshot()))
        var toggled: Pair<String, Boolean>? = null
        var removed: String? = null
        show(
            state,
            onToggleSource = { id, enabled -> toggled = id to enabled },
            onRemoveSource = { removed = it },
        )

        scrollTo(UiPageTags.BRIEF_SOURCE_PREFIX + "src-1")
        compose.onNodeWithTag(UiPageTags.BRIEF_SOURCE_SWITCH_PREFIX + "src-1").performClick()
        assertEquals("src-1" to false, toggled)

        compose.onNodeWithTag(UiPageTags.BRIEF_SOURCE_SWIPE_PREFIX + "src-1")
            .performTouchInput { swipeLeft() }
        assertEquals("src-1", removed)
        // The page never removes the row itself: the host re-projection does.
        compose.onNodeWithTag(UiPageTags.BRIEF_SOURCE_PREFIX + "src-1").assertExists()
    }

    @Test
    fun `add source opens the baseline two-field form and reports both values`() {
        val state = DailyBriefScreenState.from(DailyBriefFacts(snapshot = measuredSnapshot()))
        var added: Pair<String, String>? = null
        show(state, onAddSource = { name, url -> added = name to url })

        scrollTo(UiPageTags.BRIEF_ADD_SOURCE)
        compose.onNodeWithTag(UiPageTags.BRIEF_ADD_SOURCE).performClick()
        compose.onNodeWithTag(UiPageTags.BRIEF_SOURCE_EDITOR).assertExists()
        assertTrue(textShown(UiStrings.DAILY_BRIEF_ADD_SOURCE_TITLE))
        assertTrue(textShown(UiStrings.DAILY_BRIEF_SOURCE_FOOTER))
        compose.onNodeWithTag(UiPageTags.BRIEF_SOURCE_NAME_FIELD)
            .performTextReplacement("示例 2")
        compose.onNodeWithTag(UiPageTags.BRIEF_SOURCE_URL_FIELD)
            .performTextReplacement("https://example.org/atom.xml")
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.BRIEF_SOURCE_URL_FIELD)
            .assertTextEquals("https://example.org/atom.xml")
        compose.onNodeWithTag(UiPageTags.BRIEF_SOURCE_ADD_CONFIRM)
            .performSemanticsAction(SemanticsActions.OnClick)
        assertEquals("示例 2" to "https://example.org/atom.xml", added)
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.BRIEF_SOURCE_EDITOR).assertDoesNotExist()
    }

    @Test
    fun `an empty item list keeps the baseline hint variant chosen by the state`() {
        val withSource = DailyBriefScreenState.from(
            DailyBriefFacts(snapshot = measuredSnapshot().copy(items = emptyList())),
        )
        assertEquals(UiStrings.DAILY_BRIEF_ITEMS_EMPTY_SOURCES, withSource.emptyHint)
        show(withSource)
        scrollTo(UiPageTags.BRIEF_ITEMS_EMPTY)
        assertTrue(textShown(UiStrings.DAILY_BRIEF_ITEMS_EMPTY))
        compose.onNodeWithTag(UiPageTags.BRIEF_EMPTY_ICON).assertExists()
        assertTrue(textShown(UiStrings.DAILY_BRIEF_ITEMS_EMPTY_SOURCES))
        assertFalse(textShown(itemTitle))
    }

    @Test
    fun `the no-source hint and the disabled refresh are state facts`() {
        val state = DailyBriefScreenState.from(
            DailyBriefFacts(snapshot = measuredSnapshot().copy(items = emptyList(), sources = emptyList())),
        )
        assertEquals(UiStrings.DAILY_BRIEF_ITEMS_EMPTY_NO_SOURCE, state.emptyHint)
        assertFalse(state.canRefresh)
        show(state)
        scrollTo(UiPageTags.BRIEF_ITEMS_EMPTY)
        assertTrue(textShown(UiStrings.DAILY_BRIEF_ITEMS_EMPTY_NO_SOURCE))
    }

    @Test
    fun `a failed read adds the fail-loud line and offers a retry`() {
        val state = DailyBriefScreenState.from(
            DailyBriefFacts(snapshot = measuredSnapshot(), failure = "读取失败：简报库不可读"),
        )
        var retried = 0
        var dismissed = 0
        show(state, onRetry = { retried += 1 }, onDismissFailure = { dismissed += 1 })

        compose.onNodeWithTag(UiPageTags.BRIEF_FAILURE).assertIsDisplayed()
        assertTrue(textShown("读取失败：简报库不可读"))
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        compose.onNodeWithContentDescription(UiStrings.DISMISS).performClick()
        assertEquals(1, retried)
        assertEquals(1, dismissed)
    }

    @Test
    fun `the screen state sequence is a pure function of the facts script`() {
        val script = listOf(
            DailyBriefFacts(),
            DailyBriefFacts(snapshot = DailyBriefSnapshot()),
            DailyBriefFacts(snapshot = measuredSnapshot()),
            DailyBriefFacts(snapshot = measuredSnapshot().copy(items = emptyList())),
            DailyBriefFacts(
                snapshot = measuredSnapshot().copy(
                    refreshing = FactState.YES,
                    errorMessage = "上次失败了",
                ),
            ),
            DailyBriefFacts(snapshot = measuredSnapshot(), failure = "读取失败"),
            DailyBriefFacts(),
        )

        fun run(): List<DailyBriefScreenState> = script.map { DailyBriefScreenState.from(it) }

        val states = run()
        assertEquals(
            listOf(
                DailyBriefStatus.UNKNOWN,
                DailyBriefStatus.EMPTY,
                DailyBriefStatus.READY,
                DailyBriefStatus.READY,
                DailyBriefStatus.READY,
                DailyBriefStatus.FAILED,
                DailyBriefStatus.UNKNOWN,
            ),
            states.map { it.status },
        )
        assertEquals(UiStrings.DAILY_BRIEF_ITEMS_EMPTY_SOURCES, states[3].emptyHint)
        assertEquals(FactState.YES, states[4].refreshing)
        assertFalse(states[4].canRefresh)
        assertTrue(states[4].hasBrief)
        assertEquals("读取失败", states[5].failure)
        assertEquals(states.map { it.signature() }, run().map { it.signature() })
        assertEquals(states.map { it.hasUnmeasuredValues }, run().map { it.hasUnmeasuredValues })
    }
}

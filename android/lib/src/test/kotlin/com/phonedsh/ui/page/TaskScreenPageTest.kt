// TaskScreenPage: the restored Slider, the local drafts and the ScreenState sequence.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §3.1 rule 2: the status line and the brightness reflect
// local input, so they belong to ScreenState, not to UiState; `TaskScreenLocalState.apply`
// is a pure reducer and the draft sequence is replayed in the JVM test below.
//
// The first test is the one this lane restored: the baseline draws a
// `Slider(value: $minimumBrightness, in: 0...0.5)` under the
// "Minimum brightness: …" label. A port that omitted the control (and exposed
// only the host's reported value) fails to find the Slider here.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
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
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class TaskScreenPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun measuredSnapshot(): TaskScreenSnapshot = TaskScreenSnapshot(
        statusLine = "准备中",
        presented = FactState.YES,
        minimumBrightness = 0.2,
    )

    private fun show(
        state: TaskScreenScreenState,
        onShowTaskScreen: (String, Double) -> Unit = { _, _ -> },
        onStatusLineChange: (String) -> Unit = {},
        onBrightnessChange: (Double) -> Unit = {},
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                TaskScreenPage(
                    state = state,
                    onBack = {},
                    onShowTaskScreen = onShowTaskScreen,
                    onStatusLineChange = onStatusLineChange,
                    onBrightnessChange = onBrightnessChange,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    /** Scroll one tagged row into the viewport before asserting it is displayed. */
    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.TASK_SCREEN_LIST).performScrollToNode(hasTestTag(tag))
        compose.onNodeWithTag(tag).assertIsDisplayed()
    }

    private fun textShown(text: String): Boolean =
        compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty()

    // --------------------------------------------------------------- baseline

    @Test
    fun `the brightness Slider exists with the baseline label and range`() {
        val state = TaskScreenScreenState.from(TaskScreenFacts(snapshot = measuredSnapshot()))
        var changed: Double? = null
        show(state, onBrightnessChange = { changed = it })

        scrollTo(UiPageTags.TASK_SCREEN_SLIDER)
        assertTrue(textShown(UiStrings.TASK_SCREEN_BRIGHTNESS_LABEL.format("0.00")))
        compose.onNodeWithTag(UiPageTags.TASK_SCREEN_SLIDER)
            .performSemanticsAction(SemanticsActions.SetProgress) { setProgress ->
                setProgress(0.25f)
            }
        assertEquals(0.25, changed!!, 0.011)
    }

    @Test
    fun `a measured report shows the status line presented and brightness`() {
        val state = TaskScreenScreenState.from(TaskScreenFacts(snapshot = measuredSnapshot()))
        assertEquals("准备中", state.statusLine)
        assertEquals(FactState.YES, state.presented)
        assertEquals(0.2, state.reportedBrightness!!, 0.0)
        assertEquals(0.0, state.brightness, 0.0)
        var shownLine: String? = null
        var shownBrightness = -1.0
        var editedLine: String? = null
        show(
            state,
            onShowTaskScreen = { line, brightness ->
                shownLine = line
                shownBrightness = brightness
            },
            onStatusLineChange = { editedLine = it },
        )

        scrollTo(UiPageTags.TASK_SCREEN_DESCRIPTION)
        assertTrue(textShown(UiStrings.TASK_SCREEN_DESCRIPTION))
        scrollTo(UiPageTags.TASK_SCREEN_STATUS_FIELD)
        compose.onNodeWithTag(UiPageTags.TASK_SCREEN_STATUS_FIELD)
            .performTextReplacement("夜间任务")
        assertEquals("夜间任务", editedLine)
        scrollTo(UiPageTags.TASK_SCREEN_PRESENTED)
        assertTrue(textShown(UiStrings.TASK_SCREEN_PRESENTED))
        scrollTo(UiPageTags.TASK_SCREEN_BRIGHTNESS)
        assertTrue(textShown("0.20"))
        assertTrue(textShown(UiStrings.TASK_SCREEN_BRIGHTNESS_HINT))
        scrollTo(UiPageTags.TASK_SCREEN_SHOW)
        compose.onNodeWithTag(UiPageTags.TASK_SCREEN_SHOW).performClick()
        // The field is a controlled draft: without the host applying the edit the
        // state (and therefore the presented line) stays the host's line.
        assertEquals("准备中", shownLine)
        assertEquals(0.0, shownBrightness, 0.0)
    }

    @Test
    fun `the status line and the brightness are local drafts in one reducer`() {
        val facts = TaskScreenFacts(snapshot = measuredSnapshot())
        compose.setContent {
            var local by remember { mutableStateOf(TaskScreenLocalState()) }
            PdshTheme {
                TaskScreenPage(
                    state = TaskScreenScreenState.from(facts, local),
                    onBack = {},
                    onShowTaskScreen = { _, _ -> },
                    onStatusLineChange = { text ->
                        local = local.apply(TaskScreenUiEvent.EditStatusLine(text))
                    },
                    onBrightnessChange = { value ->
                        local = local.apply(TaskScreenUiEvent.EditMinimumBrightness(value))
                    },
                )
            }
        }

        compose.onNodeWithTag(UiPageTags.TASK_SCREEN_STATUS_FIELD)
            .performTextReplacement("夜间任务")
        compose.onNodeWithTag(UiPageTags.TASK_SCREEN_STATUS_FIELD)
            .assertTextEquals("夜间任务")
        compose.onNodeWithTag(UiPageTags.TASK_SCREEN_SLIDER)
            .performSemanticsAction(SemanticsActions.SetProgress) { setProgress ->
                setProgress(0.3f)
            }
        compose.waitForIdle()
        assertTrue(textShown(UiStrings.TASK_SCREEN_BRIGHTNESS_LABEL.format("0.30")))

        val script = listOf(
            TaskScreenUiEvent.EditStatusLine("a"),
            TaskScreenUiEvent.EditMinimumBrightness(0.1),
            TaskScreenUiEvent.EditStatusLine("ab"),
            TaskScreenUiEvent.EditMinimumBrightness(0.5),
        )

        fun run(): List<TaskScreenScreenState> {
            var local = TaskScreenLocalState()
            return buildList {
                add(TaskScreenScreenState.from(facts, local))
                script.forEach { event ->
                    local = local.apply(event)
                    add(TaskScreenScreenState.from(facts, local))
                }
            }
        }

        val states = run()
        assertEquals(listOf("准备中", "a", "a", "ab", "ab"), states.map { it.statusLine })
        assertEquals(listOf(0.0, 0.0, 0.1, 0.1, 0.5), states.map { it.brightness })
        assertNotEquals(states[0].signature(), states[1].signature())
        assertNotEquals(states[1].signature(), states[2].signature())
        // Replaying the same script yields exactly the same sequence (purity).
        assertEquals(states.map { it.signature() }, run().map { it.signature() })
    }

    @Test
    fun `an unreported task screen keeps the form and never invents a brightness`() {
        val state = TaskScreenScreenState.from(TaskScreenFacts())
        assertEquals(TaskScreenStatus.UNKNOWN, state.status)
        assertEquals(FactState.UNKNOWN, state.presented)
        assertEquals(0.0, state.brightness, 0.0)
        show(state)

        scrollTo(UiPageTags.TASK_SCREEN_SLIDER)
        scrollTo(UiPageTags.TASK_SCREEN_STATUS_FIELD)
        scrollTo(UiPageTags.TASK_SCREEN_PRESENTED)
        assertTrue(textShown(UiStrings.UNKNOWN))
        assertFalse(textShown("0.20"))
    }

    @Test
    fun `a failed read adds the fail-loud line and offers a retry`() {
        val state = TaskScreenScreenState.from(
            TaskScreenFacts(snapshot = measuredSnapshot(), failure = "读取失败：亮度不可读"),
        )
        var retried = 0
        var dismissed = 0
        show(state, onRetry = { retried += 1 }, onDismissFailure = { dismissed += 1 })

        compose.onNodeWithTag(UiPageTags.TASK_SCREEN_FAILURE).assertIsDisplayed()
        assertTrue(textShown("读取失败：亮度不可读"))
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        compose.onNodeWithContentDescription(UiStrings.DISMISS).performClick()
        assertEquals(1, retried)
        assertEquals(1, dismissed)
    }

    @Test
    fun `the screen state sequence is a pure function of the facts script`() {
        val script = listOf(
            TaskScreenFacts(),
            TaskScreenFacts(snapshot = TaskScreenSnapshot()),
            TaskScreenFacts(snapshot = measuredSnapshot()),
            TaskScreenFacts(snapshot = measuredSnapshot().copy(presented = FactState.NO)),
            TaskScreenFacts(snapshot = measuredSnapshot(), failure = "读取失败"),
            TaskScreenFacts(),
        )

        fun run(): List<TaskScreenScreenState> = script.map { TaskScreenScreenState.from(it) }

        val states = run()
        assertEquals(
            listOf(
                TaskScreenStatus.UNKNOWN,
                TaskScreenStatus.EMPTY,
                TaskScreenStatus.READY,
                TaskScreenStatus.READY,
                TaskScreenStatus.FAILED,
                TaskScreenStatus.UNKNOWN,
            ),
            states.map { it.status },
        )
        assertEquals(FactState.YES, states[2].presented)
        assertEquals(FactState.NO, states[3].presented)
        assertEquals("准备中", states[3].statusLine)
        assertEquals(FactState.UNKNOWN, states[4].presented)
        assertTrue(states[4].reportedBrightness == null)
        assertEquals(states.map { it.signature() }, run().map { it.signature() })
        assertEquals(states.map { it.hasUnmeasuredValues }, run().map { it.hasUnmeasuredValues })
    }
}

// BackgroundPage: the baseline matrix-cell controls, observation and cell log.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §3.1 rule 3: this page has no harness event anchor, so the
// host snapshot is the UiState-side input and the same snapshot sequence must
// replay to the same ScreenState sequence. The tests drive the restored baseline
// controls: the Scenario segmented picker, the continued-processing Switch and the
// Required window picker. A port that replaced them with read-only host facts
// fails these tests.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performScrollToNode
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
class BackgroundPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun measuredSnapshot(): BackgroundSnapshot = BackgroundSnapshot(
        running = FactState.NO,
        scenario = BackgroundScenario.LOCK,
        continuedProcessing = FactState.YES,
        requiredSeconds = BackgroundScreenState.PLAN_SECONDS,
        bundleInstalled = FactState.YES,
        phase = "观测中",
        statusText = "已开始 1 格",
        observation = BackgroundObservation(
            openedArm = "continuedProcessing",
            lockObserved = FactState.YES,
            backgroundSeconds = 1.4,
            recovered = FactState.YES,
            recoverySeconds = 0.42,
            hostState = "parked",
        ),
        cells = listOf(
            BackgroundCell(
                id = "lock-10",
                scenario = BackgroundScenario.LOCK,
                continuedProcessing = FactState.YES,
                status = "MEASURED",
                arm = "continuedProcessing",
                observedSeconds = 1.4,
                heldFullWindow = FactState.YES,
                recovered = FactState.YES,
                detail = "lock signal observed",
            ),
        ),
        transitions = listOf(
            BackgroundTransition(
                id = "t1",
                kind = "didEnterBackground",
                from = "active",
                to = "background",
                detail = "parked host",
                at = "2026-10-31T12:00:00Z",
            ),
        ),
        lockdown = FactState.YES,
    )

    private fun show(
        state: BackgroundScreenState,
        onStart: () -> Unit = {},
        onCancel: (() -> Unit)? = null,
        onScenarioChange: ((BackgroundScenario) -> Unit)? = null,
        onContinuedProcessingChange: ((Boolean) -> Unit)? = null,
        onRequiredWindowChange: ((Double) -> Unit)? = null,
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                BackgroundPage(
                    state = state,
                    onBack = {},
                    onStart = onStart,
                    onCancel = onCancel,
                    onScenarioChange = onScenarioChange,
                    onContinuedProcessingChange = onContinuedProcessingChange,
                    onRequiredWindowChange = onRequiredWindowChange,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    /** Scroll one tagged row into the viewport before asserting it is displayed. */
    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.BACKGROUND_LIST).performScrollToNode(hasTestTag(tag))
        compose.onNodeWithTag(tag).assertIsDisplayed()
    }

    private fun textShown(text: String): Boolean =
        compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()

    // ---------------------------------------------------------------- controls

    @Test
    fun `matrix cell keeps the two pickers and the continued-processing switch`() {
        val state = BackgroundScreenState.from(BackgroundFacts(snapshot = measuredSnapshot()))
        var scenario: BackgroundScenario? = null
        var continued: Boolean? = null
        var window: Double? = null
        show(
            state,
            onScenarioChange = { scenario = it },
            onContinuedProcessingChange = { continued = it },
            onRequiredWindowChange = { window = it },
        )

        scrollTo(UiPageTags.BACKGROUND_SCENARIO)
        assertTrue(textShown(UiStrings.BACKGROUND_SCENARIO_BACKGROUND))
        assertTrue(textShown(UiStrings.BACKGROUND_SCENARIO_LOCK))
        compose.onNodeWithTag(UiPageTags.BACKGROUND_SCENARIO + ".BACKGROUND")
            .assertIsEnabled()
            .assertHasClickAction()
            .performSemanticsAction(SemanticsActions.OnClick)
        assertEquals(BackgroundScenario.BACKGROUND, scenario)

        scrollTo(UiPageTags.BACKGROUND_CONTINUED_SWITCH)
        compose.onNodeWithTag(UiPageTags.BACKGROUND_CONTINUED_SWITCH)
            .performScrollTo()
            .performClick()
        assertEquals(false, continued)

        scrollTo(UiPageTags.BACKGROUND_REQUIRED_PICKER)
        assertTrue(textShown(UiStrings.BACKGROUND_WINDOW_10MIN))
        assertTrue(textShown(UiStrings.BACKGROUND_WINDOW_60S))
        compose.onNodeWithTag(
            UiPageTags.BACKGROUND_REQUIRED_PICKER + "." +
                BackgroundScreenState.UI_CHECK_SECONDS.toInt(),
        ).performSemanticsAction(SemanticsActions.OnClick)
        assertEquals(BackgroundScreenState.UI_CHECK_SECONDS, window!!, 0.0)
    }

    @Test
    fun `run block keeps start and cancel`() {
        var started = 0
        var cancelled = 0
        show(
            BackgroundScreenState.from(
                BackgroundFacts(snapshot = measuredSnapshot().copy(running = FactState.UNKNOWN)),
            ),
            onStart = { started += 1 },
            onCancel = { cancelled += 1 },
        )
        scrollTo(UiPageTags.BACKGROUND_START)
        compose.onNodeWithTag(UiPageTags.BACKGROUND_START).performScrollTo().performClick()
        compose.onNodeWithTag(UiPageTags.BACKGROUND_CANCEL).performScrollTo().performClick()
        assertEquals(1, started)
        assertEquals(1, cancelled)
    }

    @Test
    fun `a missing bundle is a red note and disables start`() {
        show(
            BackgroundScreenState.from(
                BackgroundFacts(
                    snapshot = measuredSnapshot().copy(
                        bundleInstalled = FactState.NO,
                        bundleDetail = "Worker bundle missing",
                    ),
                ),
            ),
        )
        scrollTo(UiPageTags.BACKGROUND_BUNDLE_HINT)
        assertTrue(textShown("Worker bundle missing"))
        compose.onNodeWithTag(UiPageTags.BACKGROUND_START).assertIsNotEnabled()
    }

    // ------------------------------------------------------------- observation

    @Test
    fun `observation shows the arm lock interval recovery host and badge`() {
        show(BackgroundScreenState.from(BackgroundFacts(snapshot = measuredSnapshot())))
        scrollTo(UiPageTags.BACKGROUND_WINDOW)
        assertTrue(textShown("continuedProcessing"))
        scrollTo(UiPageTags.BACKGROUND_LOCK)
        assertTrue(textShown(UiStrings.YES))
        scrollTo(UiPageTags.BACKGROUND_INTERVAL)
        assertTrue(textShown("1.4 秒"))
        scrollTo(UiPageTags.BACKGROUND_RECOVERY)
        assertTrue(textShown("0.42 秒"))
        scrollTo(UiPageTags.BACKGROUND_HOST)
        assertTrue(textShown("parked"))
        scrollTo(UiPageTags.BACKGROUND_LOCKDOWN)
        assertTrue(textShown(UiStrings.LOCKDOWN_ON))
    }

    @Test
    fun `matrix cells show the continued flag status and footnote`() {
        show(BackgroundScreenState.from(BackgroundFacts(snapshot = measuredSnapshot())))
        scrollTo(UiPageTags.BACKGROUND_CELL_PREFIX + "lock-10")
        assertTrue(textShown(UiStrings.BACKGROUND_SCENARIO_LOCK))
        assertTrue(textShown(UiStrings.BACKGROUND_CONTINUED_ON))
        assertTrue(textShown("MEASURED"))
        assertTrue(textShown("continuedProcessing"))
        assertTrue(textShown("lock signal observed"))
        scrollTo(UiPageTags.BACKGROUND_NOTE)
        assertTrue(textShown(UiStrings.BACKGROUND_SIMULATOR_NOTE))
    }

    @Test
    fun `transitions keep only the newest fourteen as the baseline does`() {
        val transitions = (1..20).map { index ->
            BackgroundTransition(
                id = "t$index",
                kind = "kind-$index",
                from = "a",
                to = "b",
                at = "12:00:0$index",
            )
        }
        show(
            BackgroundScreenState.from(
                BackgroundFacts(snapshot = measuredSnapshot().copy(transitions = transitions)),
            ),
        )
        scrollTo(UiPageTags.BACKGROUND_TRANSITION_PREFIX + "t20")
        assertTrue(textShown("kind-20"))
        scrollTo(UiPageTags.BACKGROUND_TRANSITION_PREFIX + "t7")
        assertTrue(textShown("kind-7"))
        compose.onNodeWithTag(UiPageTags.BACKGROUND_TRANSITION_PREFIX + "t6").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.BACKGROUND_TRANSITION_PREFIX + "t1").assertDoesNotExist()
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `an unreported snapshot keeps the controls but not invented values`() {
        val state = BackgroundScreenState.from(BackgroundFacts())
        assertEquals(BackgroundStatus.UNKNOWN, state.status)
        assertFalse(state.canStart)
        show(state)
        scrollTo(UiPageTags.BACKGROUND_SCENARIO)
        scrollTo(UiPageTags.BACKGROUND_CONTINUED_SWITCH)
        scrollTo(UiPageTags.BACKGROUND_REQUIRED_PICKER)
        compose.onNodeWithTag(UiPageTags.BACKGROUND_START).assertIsNotEnabled()
        scrollTo(UiPageTags.BACKGROUND_INTERVAL)
        assertTrue(textShown(UiStrings.UNKNOWN))
        assertTrue(compose.onAllNodesWithText("0.0 秒").fetchSemanticsNodes().isEmpty())
    }

    @Test
    fun `a failed read adds the fail-loud line and offers a retry`() {
        val state = BackgroundScreenState.from(
            BackgroundFacts(snapshot = measuredSnapshot(), failure = "读取失败：宿主未响应"),
        )
        assertEquals(BackgroundStatus.FAILED, state.status)
        var retried = 0
        var dismissed = 0
        show(state, onRetry = { retried += 1 }, onDismissFailure = { dismissed += 1 })
        compose.onNodeWithTag(UiPageTags.BACKGROUND_FAILURE).assertIsDisplayed()
        assertTrue(textShown("读取失败：宿主未响应"))
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        compose.onNodeWithContentDescription(UiStrings.DISMISS).performClick()
        assertEquals(1, retried)
        assertEquals(1, dismissed)
    }

    @Test
    fun `the screen state sequence is a pure function of the facts script`() {
        val script = listOf(
            BackgroundFacts(),
            BackgroundFacts(snapshot = BackgroundSnapshot()),
            BackgroundFacts(snapshot = measuredSnapshot()),
            BackgroundFacts(snapshot = measuredSnapshot(), failure = "读取失败"),
            BackgroundFacts(),
        )

        fun run(): List<BackgroundScreenState> = script.map { BackgroundScreenState.from(it) }

        val states = run()
        assertEquals(
            listOf(
                BackgroundStatus.UNKNOWN,
                BackgroundStatus.EMPTY,
                BackgroundStatus.READY,
                BackgroundStatus.FAILED,
                BackgroundStatus.UNKNOWN,
            ),
            states.map { it.status },
        )
        assertEquals(BackgroundScenario.LOCK, states[2].scenario)
        assertEquals(FactState.YES, states[2].continuedProcessing)
        assertEquals(BackgroundScreenState.PLAN_SECONDS, states[2].requiredSeconds!!, 0.0)
        assertEquals(FactState.YES, states[2].lockdown)
        assertEquals(states.map { it.signature() }, run().map { it.signature() })
        assertEquals(states.map { it.hasUnmeasuredValues }, run().map { it.hasUnmeasuredValues })
    }
}

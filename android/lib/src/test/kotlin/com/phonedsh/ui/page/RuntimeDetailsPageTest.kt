// RuntimeDetailsPage: its four states, the unmeasured-value rule and its sequence.
// SPDX-License-Identifier: MIT
//
// The unknown-value test locates the memory and power regions with
// `performScrollToNode` before asserting that a fabricated `0 B` or `0%` is
// absent: the groups are lazy items, so a bare `assertDoesNotExist` on a row that
// was never composed would pass for the wrong reason.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
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
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class RuntimeDetailsPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun fullFacts(): RuntimeFacts = RuntimeFacts(
        snapshot = RuntimeSnapshot(
            engine = FactState.YES,
            uptimeMs = 125_000,
            webView = WebViewRuntime(
                provider = "com.google.android.webview",
                version = "124.0.6367.82",
                featureGate = FactState.YES,
            ),
            memory = RuntimeMemory(
                tier = "standard",
                budgetBytes = 1024L * 1024 * 1024,
                usedBytes = 512L * 1024 * 1024,
            ),
            power = RuntimePower(
                thermal = ThermalLevel.LIGHT,
                batteryPercent = 42,
                charging = FactState.NO,
                batterySaver = FactState.NO,
            ),
            foregroundService = FactState.YES,
        ),
    )

    private fun partialFacts(): RuntimeFacts = RuntimeFacts(
        snapshot = RuntimeSnapshot(
            engine = FactState.YES,
            uptimeMs = 5_000,
            webView = WebViewRuntime(provider = "com.google.android.webview"),
            memory = RuntimeMemory(tier = "standard"),
            power = RuntimePower(),
            foregroundService = FactState.UNKNOWN,
        ),
    )

    private fun show(
        state: RuntimeDetailsScreenState,
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                RuntimeDetailsPage(
                    state = state,
                    onBack = {},
                    onToggleSection = {},
                    onRequestStop = {},
                    onCancelStop = {},
                    onConfirmStop = {},
                    onRestart = {},
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    /** A host that applies the local events, so a fold and a confirmation move the UI. */
    private fun showLive(
        facts: RuntimeFacts,
        initial: RuntimeLocalState = RuntimeLocalState(),
        onStop: () -> Unit = {},
        onRestart: () -> Unit = {},
    ) {
        compose.setContent {
            var local by remember { mutableStateOf(initial) }
            PdshTheme {
                RuntimeDetailsPage(
                    state = RuntimeDetailsScreenState.from(facts, local),
                    onBack = {},
                    onToggleSection = { id -> local = local.apply(RuntimeUiEvent.ToggleSection(id)) },
                    onRequestStop = { local = local.apply(RuntimeUiEvent.RequestStop) },
                    onCancelStop = { local = local.apply(RuntimeUiEvent.CancelStop) },
                    onConfirmStop = {
                        local = local.apply(RuntimeUiEvent.ConfirmStop)
                        onStop()
                    },
                    onRestart = onRestart,
                )
            }
        }
    }

    @Test
    fun `an empty snapshot shows the empty state and never a zero`() {
        val state = RuntimeDetailsScreenState.from(RuntimeFacts(snapshot = RuntimeSnapshot()))
        assertEquals(RuntimeStatus.EMPTY, state.status)
        assertTrue(state.isEmpty)
        assertEquals(RuntimeAction.NONE, state.action)
        show(state)
        compose.onNodeWithTag(UiPageTags.RUNTIME_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_EMPTY_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.RUNTIME_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST).assertDoesNotExist()
        compose.onNodeWithText("0 B").assertDoesNotExist()
        compose.onNodeWithText("0%").assertDoesNotExist()
    }

    @Test
    fun `a measured snapshot renders every runtime fact`() {
        val facts = fullFacts()
        val state = RuntimeDetailsScreenState.from(facts)
        assertEquals(RuntimeStatus.READY, state.status)
        assertEquals(UiStrings.RUNNING, state.engineValue)
        assertEquals("2 分钟", state.uptimeValue)
        assertEquals(RuntimeAction.STOP, state.action)
        assertFalse(state.hasUnmeasuredValues)
        assertTrue(state.notes.isEmpty())
        show(state)

        compose.onNodeWithText(UiStrings.RUNNING).assertIsDisplayed()
        compose.onNodeWithText("2 分钟").assertIsDisplayed()
        compose.onNodeWithText("com.google.android.webview").assertIsDisplayed()
        compose.onNodeWithText("124.0.6367.82").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_FEATURE_SUPPORTED).assertIsDisplayed()

        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.RUNTIME_SECTION_PREFIX + "runtime.memory"))
        compose.onNodeWithText("standard").assertIsDisplayed()
        compose.onNodeWithText("1.0 GiB").assertIsDisplayed()
        compose.onNodeWithText("512.0 MiB").assertIsDisplayed()

        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasText("42%"))
        compose.onNodeWithText("42%").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_THERMAL_LIGHT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_CHARGING_OFF).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_BATTERY_SAVER_OFF).assertIsDisplayed()

        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasText(UiStrings.RUNTIME_FGS_AVAILABLE))
        compose.onNodeWithText(UiStrings.RUNTIME_FGS_AVAILABLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.RUNTIME_STOP))
        compose.onNodeWithText(UiStrings.RUNTIME_STOP).assertIsDisplayed()
    }

    @Test
    fun `an unmeasured value is 未知 with an explanation, never zero`() {
        val state = RuntimeDetailsScreenState.from(partialFacts())
        assertEquals(RuntimeStatus.READY, state.status)
        assertTrue(state.hasUnmeasuredValues)
        show(state)
        compose.onNodeWithTag(UiPageTags.RUNTIME_UNMEASURED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_UNMEASURED_HINT).assertIsDisplayed()

        // Step 1: scroll to the memory group; only then is its row composed, so the
        // absent-number assertion below is about that region and not about the window.
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.RUNTIME_SECTION_PREFIX + "runtime.memory"))
        compose.onNodeWithText(UiStrings.RUNTIME_MEMORY_BUDGET).assertIsDisplayed()
        compose.onNodeWithText("0 B").assertDoesNotExist()
        assertTrue(
            "a row in the located memory group must say 未知",
            compose.onAllNodesWithText(UiStrings.UNKNOWN).fetchSemanticsNodes().size >= 2,
        )

        // Step 2: the same for the power group, whose battery value is unmeasured.
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.RUNTIME_SECTION_PREFIX + "runtime.power"))
        compose.onNodeWithText(UiStrings.RUNTIME_BATTERY).assertIsDisplayed()
        compose.onNodeWithText("0%").assertDoesNotExist()
        assertTrue(
            "a row in the located power group must say 未知",
            compose.onAllNodesWithText(UiStrings.UNKNOWN).fetchSemanticsNodes().isNotEmpty(),
        )
    }

    @Test
    fun `a failed read wins over stale facts and offers retry and dismiss`() {
        val state = RuntimeDetailsScreenState.from(fullFacts().copy(failure = "读取超时"))
        assertEquals(RuntimeStatus.FAILED, state.status)
        assertTrue(state.sections.isEmpty())
        assertTrue(state.isFailed)
        var retried = 0
        var dismissed = 0
        show(
            state,
            onRetry = { retried += 1 },
            onDismissFailure = { dismissed += 1 },
        )
        compose.onNodeWithTag(UiPageTags.RUNTIME_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_FAILED).assertIsDisplayed()
        compose.onNodeWithText("读取超时").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.RUNTIME_EMPTY).assertDoesNotExist()
        compose.onNodeWithText("1.0 GiB").assertDoesNotExist()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
        compose.onNodeWithText(UiStrings.DISMISS).performClick()
        assertEquals(1, dismissed)
    }

    @Test
    fun `an unreported snapshot is unknown, not an empty runtime`() {
        val state = RuntimeDetailsScreenState.from(RuntimeFacts())
        assertEquals(RuntimeStatus.UNKNOWN, state.status)
        assertTrue(state.isUnknown)
        assertFalse(state.isEmpty)
        show(state)
        compose.onNodeWithTag(UiPageTags.RUNTIME_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_UNKNOWN_STATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.RUNTIME_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST).assertDoesNotExist()
        compose.onNodeWithText("0 B").assertDoesNotExist()
        compose.onNodeWithText("0%").assertDoesNotExist()
    }

    @Test
    fun `the stop, cancel, confirm and fold sequence is a pure function of the script`() {
        val facts = fullFacts()
        val script = listOf(
            RuntimeUiEvent.ToggleSection(RuntimeDetailsScreenState.ENGINE_SECTION_ID),
            RuntimeUiEvent.RequestStop,
            RuntimeUiEvent.CancelStop,
            RuntimeUiEvent.RequestStop,
            RuntimeUiEvent.ConfirmStop,
        )

        fun run(): List<RuntimeDetailsScreenState> {
            var local = RuntimeLocalState()
            return buildList {
                add(RuntimeDetailsScreenState.from(facts, local))
                script.forEach { event ->
                    local = local.apply(event)
                    add(RuntimeDetailsScreenState.from(facts, local))
                }
            }
        }

        val states = run()
        assertEquals(
            listOf(true, false, false, false, false, false),
            states.map { state ->
                state.sections.first { it.id == RuntimeDetailsScreenState.ENGINE_SECTION_ID }.expanded
            },
        )
        assertEquals(
            listOf(false, false, true, false, true, false),
            states.map { it.stopConfirmationOpen },
        )
        assertEquals(
            List(6) { RuntimeAction.STOP },
            states.map { it.action },
        )
        // Replaying the same script yields exactly the same sequence (purity).
        assertEquals(states.map { it.signature() }, run().map { it.signature() })

        // A stopped snapshot closes a stale confirmation: the state, not the local
        // script, decides whether a stop can still be confirmed.
        val stopped = facts.copy(
            snapshot = facts.snapshot!!.copy(engine = FactState.NO),
        )
        val stale = RuntimeLocalState(stopConfirmationOpen = true)
        val stoppedState = RuntimeDetailsScreenState.from(stopped, stale)
        assertEquals(RuntimeAction.START, stoppedState.action)
        assertFalse(stoppedState.stopConfirmationOpen)
    }

    @Test
    fun `the stop action opens the inline confirmation and closes it on cancel`() {
        var stopped = 0
        showLive(fullFacts(), onStop = { stopped += 1 })
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.RUNTIME_STOP))
        compose.onNodeWithTag(UiPageTags.RUNTIME_STOP).performClick()
        compose.onNodeWithTag(UiPageTags.RUNTIME_STOP_CONFIRM).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RUNTIME_STOP_CONFIRM).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.RUNTIME_STOP_CANCEL))
        compose.onNodeWithTag(UiPageTags.RUNTIME_STOP_CANCEL).performClick()
        compose.onNodeWithTag(UiPageTags.RUNTIME_STOP_CONFIRM).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.RUNTIME_STOP))
        compose.onNodeWithTag(UiPageTags.RUNTIME_STOP).performClick()
        compose.onNodeWithTag(UiPageTags.RUNTIME_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.RUNTIME_STOP_CONFIRM_ACTION))
        compose.onNodeWithTag(UiPageTags.RUNTIME_STOP_CONFIRM_ACTION).performClick()
        compose.onNodeWithTag(UiPageTags.RUNTIME_STOP_CONFIRM).assertDoesNotExist()
        assertEquals(1, stopped)
    }

    @Test
    fun `uptime uses the baseline words and a host-supplied duration`() {
        assertEquals(UiStrings.RUNTIME_UPTIME_UNDER_MINUTE, formatUptime(0))
        assertEquals(UiStrings.RUNTIME_UPTIME_UNDER_MINUTE, formatUptime(59_999))
        assertEquals(UiStrings.RUNTIME_UPTIME_MINUTES.format(1), formatUptime(60_000))
        assertEquals(UiStrings.RUNTIME_UPTIME_MINUTES.format(59), formatUptime(3_599_000))
        assertEquals(UiStrings.RUNTIME_UPTIME_HOURS.format(1), formatUptime(3_600_000))
        assertEquals(UiStrings.RUNTIME_UPTIME_HOURS_MINUTES.format(1, 5), formatUptime(3_900_000))
    }
}

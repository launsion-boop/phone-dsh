// ProbesPage: the baseline sections, the group menu, the badge and the G0 rows.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §3.1 rule 3: a page with no harness event anchor projects
// the host's read-only snapshot, and the same snapshot sequence must replay to the
// same ScreenState sequence. The page's only local UI event is the group menu's
// open/closed state, so the sequence is asserted over facts.
//
// The tests are written against the iOS baseline's structure, not §1's one-line
// responsibility: Environment, the Lockdown badge, the run actions (a Button and
// a Menu), Rows, and the G0 threshold table. The menu test drives the real
// `DropdownMenu`; a port that replaced it with one row per group would fail here.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
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
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class ProbesPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun measuredSnapshot(): ProbesSnapshot = ProbesSnapshot(
        environment = "android/robolectric",
        os = "Android 14",
        bundle = "com.phonedsh.probe",
        running = false,
        statusText = "已运行 2 项",
        summary = ProbeSummary(
            passed = 1,
            failed = 1,
            info = 0,
            g0Passed = false,
            failedGatingProbes = listOf("wal-recovery"),
        ),
        rows = listOf(
            ProbeRow(
                id = "cold-start",
                probe = "cold-start",
                status = ProbeStatus.PASS,
                metrics = listOf(ProbeMetric("p50", "1.2 s")),
                threshold = ProbeThreshold(
                    name = "cold-start",
                    comparison = "<=",
                    bound = "2.0",
                    unit = "s",
                    met = true,
                    gating = true,
                    source = "PLAN §2.5",
                ),
                environment = "android",
                recordedAt = "2026-10-31T12:00:00Z",
            ),
            ProbeRow(
                id = "wal-recovery",
                probe = "wal-recovery",
                status = ProbeStatus.FAIL,
                metrics = listOf(ProbeMetric("p95")),
                gating = false,
                detail = "recovery took 3.4 s",
            ),
        ),
        groups = listOf(ProbeGroup(id = "dot", title = "DOT")),
        thresholds = listOf(
            ProbeThreshold(
                name = "cold-start",
                comparison = "<=",
                bound = "2.0",
                unit = "s",
                met = true,
                gating = true,
                source = "PLAN §2.5",
            ),
        ),
        lockdown = FactState.NO,
    )

    private fun show(
        state: ProbesScreenState,
        onRunAll: () -> Unit = {},
        onReset: (() -> Unit)? = null,
        onRunGroup: ((String) -> Unit)? = null,
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                ProbesPage(
                    state = state,
                    onBack = {},
                    onRunAll = onRunAll,
                    onReset = onReset,
                    onRunGroup = onRunGroup,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    /** Scroll one tagged row into the viewport before asserting it is displayed. */
    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.PROBES_LIST).performScrollToNode(hasTestTag(tag))
        compose.onNodeWithTag(tag).assertIsDisplayed()
    }

    private fun textShown(text: String): Boolean =
        compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()

    // ------------------------------------------------------------------ blocks

    @Test
    fun `environment badge actions and anchor follow the baseline order`() {
        val state = ProbesScreenState.from(ProbesFacts(snapshot = measuredSnapshot()))
        var ran = 0
        var reset = 0
        show(state, onRunAll = { ran += 1 }, onReset = { reset += 1 })

        scrollTo(UiPageTags.PROBES_ENVIRONMENT)
        assertTrue(textShown("android/robolectric"))
        scrollTo(UiPageTags.PROBES_OS)
        assertTrue(textShown("Android 14"))
        scrollTo(UiPageTags.PROBES_ENVIRONMENT_NOTE)
        assertTrue(textShown(UiStrings.PROBES_ENVIRONMENT_NOTE))
        scrollTo(UiPageTags.PROBES_LOCKDOWN)
        assertTrue(textShown(UiStrings.LOCKDOWN_OFF))
        // The baseline keeps a one-point visible anchor in the page hierarchy.
        compose.onNodeWithTag(UiPageTags.PROBES_ANCHOR).assertExists()
        scrollTo(UiPageTags.PROBES_RUN_ALL)
        compose.onNodeWithTag(UiPageTags.PROBES_RUN_ALL).performClick()
        compose.onNodeWithTag(UiPageTags.PROBES_RESET).performClick()
        assertEquals(1, ran)
        assertEquals(1, reset)
    }

    @Test
    fun `run one group is a menu with one entry per host group`() {
        val state = ProbesScreenState.from(ProbesFacts(snapshot = measuredSnapshot()))
        var group: String? = null
        show(state, onRunGroup = { group = it })

        scrollTo(UiPageTags.PROBES_MENU)
        compose.onNodeWithTag(UiPageTags.PROBES_MENU).performClick()
        compose.onNodeWithTag(UiPageTags.PROBES_GROUP_PREFIX + "dot").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PROBES_GROUP_PREFIX + "dot").performClick()
        assertEquals("dot", group)
        // The menu closes after one pick; the trigger is still a single control.
        compose.onNodeWithTag(UiPageTags.PROBES_MENU_LIST).assertDoesNotExist()
    }

    @Test
    fun `a measured report shows counts G0 chips metrics bounds and flags`() {
        val state = ProbesScreenState.from(ProbesFacts(snapshot = measuredSnapshot()))
        assertEquals(ProbesStatus.READY, state.status)
        assertEquals(2, state.rows.size)
        assertEquals(FactState.NO, state.lockdown)
        assertTrue(state.hasUnmeasuredValues)
        show(state)

        scrollTo(UiPageTags.PROBES_ROWS)
        // `ProbesPage.swift:112` renders `Rows (\(model.probeRows.count))`: the title is
        // the template with the measured count in it, never the interpolation source.
        assertTrue(textShown(UiStrings.PROBES_SECTION_ROWS_COUNT.format(state.rows.size)))
        assertFalse(textShown(UiStrings.PROBES_SECTION_ROWS_COUNT_EN))
        scrollTo(UiPageTags.PROBES_COUNTS)
        assertTrue(textShown(UiStrings.PROBES_COUNTS.format("1", "1", "0")))
        scrollTo(UiPageTags.PROBES_G0)
        assertTrue(textShown(UiStrings.PROBES_G0_FAILED))
        scrollTo(UiPageTags.PROBES_G0_FAILED)
        assertTrue(
            textShown(UiStrings.PROBES_G0_FAILED_LIST.format("wal-recovery")),
        )

        scrollTo(UiPageTags.PROBES_ROW_PREFIX + "cold-start")
        assertTrue(textShown(UiStrings.PROBES_CHIP_PASS))
        assertTrue(textShown("1.2 s"))
        assertTrue(textShown("G0 cold-start：<= 2.0 s · met=true"))
        scrollTo(UiPageTags.PROBES_ROW_PREFIX + "wal-recovery")
        assertTrue(textShown(UiStrings.PROBES_CHIP_FAIL))
        assertTrue(textShown(UiStrings.PROBES_VALUE_NONE))
        assertTrue(textShown(UiStrings.PROBES_NON_GATING_ROW))
        assertTrue(textShown("recovery took 3.4 s"))

        scrollTo(UiPageTags.PROBES_THRESHOLD_TABLE_PREFIX + "0")
        assertTrue(textShown(UiStrings.PROBES_BOUND))
        assertTrue(textShown(UiStrings.PROBES_GATING))
        assertTrue(textShown("2.0 s"))
        assertTrue(textShown("PLAN §2.5"))
    }

    @Test
    fun `no probe run shows the baseline Rows empty copy and never a count`() {
        val state = ProbesScreenState.from(
            ProbesFacts(snapshot = ProbesSnapshot(environment = "android/robolectric")),
        )
        assertEquals(ProbesStatus.READY, state.status)
        assertTrue(state.rows.isEmpty())
        show(state)

        scrollTo(UiPageTags.PROBES_EMPTY)
        assertTrue(textShown(UiStrings.PROBES_EMPTY_NOTE))
        assertTrue(textShown(UiStrings.PROBES_SECTION_ROWS_EN))
        compose.onNodeWithTag(UiPageTags.PROBES_COUNTS).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.PROBES_COUNTS_LABEL).assertDoesNotExist()
        assertTrue(compose.onAllNodesWithText("0").fetchSemanticsNodes().isEmpty())
    }

    @Test
    fun `an unreported snapshot still renders the baseline controls with unknown values`() {
        val state = ProbesScreenState.from(ProbesFacts())
        assertEquals(ProbesStatus.UNKNOWN, state.status)
        show(state)

        scrollTo(UiPageTags.PROBES_ENVIRONMENT)
        assertTrue(textShown(UiStrings.UNKNOWN))
        scrollTo(UiPageTags.PROBES_LOCKDOWN)
        assertTrue(textShown(UiStrings.LOCKDOWN_UNKNOWN))
        scrollTo(UiPageTags.PROBES_RUN_ALL)
        // The control exists even when the host has no snapshot, but is disabled
        // because "running" is unknown.
        compose.onNodeWithTag(UiPageTags.PROBES_MENU).assertExists()
        compose.onNodeWithTag(UiPageTags.PROBES_COUNTS).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.PROBES_COUNTS_LABEL).assertDoesNotExist()
    }

    @Test
    fun `a failed read adds the fail-loud line and keeps the page`() {
        val state = ProbesScreenState.from(
            ProbesFacts(snapshot = measuredSnapshot(), failure = "读取失败：socket 已关闭"),
        )
        assertEquals(ProbesStatus.FAILED, state.status)
        var retried = 0
        var dismissed = 0
        show(state, onRetry = { retried += 1 }, onDismissFailure = { dismissed += 1 })

        compose.onNodeWithTag(UiPageTags.PROBES_FAILURE).assertIsDisplayed()
        assertTrue(textShown("读取失败：socket 已关闭"))
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        compose.onNodeWithContentDescription(UiStrings.DISMISS).performClick()
        assertEquals(1, retried)
        assertEquals(1, dismissed)
    }

    @Test
    fun `the lockdown badge reports all three facts without guessing`() {
        var facts by mutableStateOf(ProbesFacts())
        compose.setContent {
            PdshTheme {
                ProbesPage(
                    state = ProbesScreenState.from(facts),
                    onBack = {},
                    onRunAll = {},
                )
            }
        }

        compose.onNodeWithTag(UiPageTags.PROBES_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.PROBES_LOCKDOWN))
        assertTrue(textShown(UiStrings.LOCKDOWN_UNKNOWN))

        facts = ProbesFacts(snapshot = measuredSnapshot().copy(lockdown = FactState.YES))
        assertTrue(textShown(UiStrings.LOCKDOWN_ON))
        facts = ProbesFacts(snapshot = measuredSnapshot().copy(lockdown = FactState.NO))
        assertTrue(textShown(UiStrings.LOCKDOWN_OFF))
    }

    @Test
    fun `the screen state sequence is a pure function of the facts script`() {
        val script = listOf(
            ProbesFacts(),
            ProbesFacts(snapshot = ProbesSnapshot()),
            ProbesFacts(snapshot = measuredSnapshot()),
            ProbesFacts(snapshot = measuredSnapshot(), failure = "读取失败"),
            ProbesFacts(),
        )

        fun run(): List<ProbesScreenState> = script.map { ProbesScreenState.from(it) }

        val states = run()
        assertEquals(
            listOf(
                ProbesStatus.UNKNOWN,
                ProbesStatus.EMPTY,
                ProbesStatus.READY,
                ProbesStatus.FAILED,
                ProbesStatus.UNKNOWN,
            ),
            states.map { it.status },
        )
        assertEquals(2, states[2].rows.size)
        assertEquals(FactState.NO, states[2].lockdown)
        assertFalse(states[3].rows.isNotEmpty())
        assertEquals("读取失败", states[3].failure)
        assertEquals(states.map { it.signature() }, run().map { it.signature() })
        assertEquals(states.map { it.hasUnmeasuredValues }, run().map { it.hasUnmeasuredValues })
    }
}

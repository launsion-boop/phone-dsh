// Memory probe page: the six baseline cards, card for card.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/MemoryPage.swift`. These tests pin
// the six cards, the bundle's two branches, the overlay buttons and their disabled
// rule, the running marker, the last-eight sample window, the measured-level
// metrics, the session's empty branch, the toolbar Cancel, and the baseline's
// 一 glyph for an unmeasured number.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTouchInput
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
class MemoryPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(
        facts: MemoryFacts = MemoryFacts(),
        onRunOverlay: (Int) -> Unit = {},
        onRunLong: () -> Unit = {},
        onCancel: () -> Unit = {},
        onBack: () -> Unit = {},
    ) {
        val state = MemoryScreenState.from(facts)
        compose.setContent {
            PdshTheme {
                MemoryPage(
                    state = state,
                    onRunOverlay = onRunOverlay,
                    onRunLongSession = onRunLong,
                    onCancel = onCancel,
                    onBack = onBack,
                )
            }
        }
    }

    /** The page scrolls: a card below the fold is only composed once it is near. */
    private fun scrollTo(text: String) {
        compose.onNodeWithTag(UiPageTags.MEMORY_LIST).performScrollToNode(hasText(text))
    }

    /** The body is six PageSections, in this order, on every render. */
    @Test
    fun `the page keeps the baseline's six cards`() {
        show()
        listOf(
            UiStrings.MEMORY_SECTION_BUNDLE,
            UiStrings.MEMORY_SECTION_OVERLAY,
            UiStrings.MEMORY_SECTION_PROGRESS,
            UiStrings.MEMORY_SECTION_LIVE,
            UiStrings.MEMORY_SECTION_MEASURED,
            UiStrings.MEMORY_SECTION_SESSION,
        ).forEach { title ->
            // LazyColumn only composes nearby sections; scroll to each card before
            // asserting its visible state instead of treating offscreen as absent.
            scrollTo(title)
            compose.onNodeWithText(title).assertIsDisplayed()
        }
        // The cards' contents say 未知 when nothing was read; no card disappears.
        val state = MemoryScreenState.from(MemoryFacts())
        assertEquals(UiStrings.UNKNOWN, state.session.statusLine?.value)
        assertTrue(state.measured.unknown)
        assertTrue(state.live.unknown)
        assertTrue(state.overlay.unknown)
        assertFalse(state.overlay.enabled)
    }

    /** An unread bundle says 未知 and quotes neither of the two notes. */
    @Test
    fun `an unread bundle says 未知 and quotes neither note`() {
        val state = MemoryScreenState.from(MemoryFacts(bundleInstalled = FactState.UNKNOWN))
        assertEquals(UiStrings.UNKNOWN, state.bundle.stateLine?.value)
        assertEquals(null, state.bundle.detail)
        assertEquals(null, state.bundle.note)
        show(MemoryFacts(bundleInstalled = FactState.UNKNOWN))
        compose.onNodeWithTag(UiPageTags.MEMORY_BUNDLE_STATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_BUNDLE_REFRESH_NOTE).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.MEMORY_BUNDLE_MISSING_NOTE).assertDoesNotExist()
    }

    /** Installed: the key line plus the refresh note; the badge is always there. */
    @Test
    fun `an installed bundle shows its key line and the refresh note`() {
        val state = MemoryScreenState.from(
            MemoryFacts(bundleInstalled = FactState.YES, lockdown = FactState.NO),
        )
        assertEquals(UiStrings.MEMORY_BUNDLE_INSTALLED, state.bundle.stateLine?.value)
        assertEquals(UiStrings.MEMORY_BUNDLE_REFRESH_NOTE, state.bundle.note)
        assertEquals(UiStrings.MEMORY_LOCKDOWN_OFF, state.bundle.lockdown)
        show(MemoryFacts(bundleInstalled = FactState.YES, lockdown = FactState.NO))
        compose.onNodeWithText(UiStrings.MEMORY_BUNDLE_INSTALLED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_BUNDLE_REFRESH_NOTE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_LOCKDOWN_OFF).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_LOCKDOWN_ON).assertDoesNotExist()
    }

    /** Missing: the runner's own detail plus the packed-image note, never "installed". */
    @Test
    fun `a missing bundle shows the runner detail and the packed-image note`() {
        show(
            MemoryFacts(
                bundleInstalled = FactState.NO,
                bundleDetail = "no bundle in the app",
                lockdown = FactState.YES,
            ),
        )
        compose.onNodeWithText("no bundle in the app").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_BUNDLE_MISSING_NOTE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_LOCKDOWN_ON).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_BUNDLE_INSTALLED).assertDoesNotExist()
        // No detail from the runner: 未知, never an empty line.
        assertEquals(
            UiStrings.UNKNOWN,
            MemoryScreenState.from(MemoryFacts(bundleInstalled = FactState.NO)).bundle.detail,
        )
    }

    /** The levels are the host's; the port never invents 20/50/100 MB. */
    @Test
    fun `overlay levels come from the host`() {
        val runs = mutableListOf<Int>()
        var longs = 0
        show(
            facts = MemoryFacts(
                bundleInstalled = FactState.YES,
                overlayLevelsMB = listOf(20, 50, 100),
            ),
            onRunOverlay = { runs += it },
            onRunLong = { longs += 1 },
        )
        compose.onNodeWithText("Run 20 MB overlay").assertIsDisplayed()
        compose.onNodeWithText("Run 100 MB overlay").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MEMORY_RUN_PREFIX + 50).performClick()
        assertEquals(listOf(50), runs)
        // The long session button is its own gesture.
        compose.onNodeWithTag(UiPageTags.MEMORY_RUN_LONG).performClick()
        assertEquals(1, longs)
    }

    /** A run is gated on a measured installed bundle and on nothing running. */
    @Test
    fun `overlay buttons need an installed bundle and an idle runner`() {
        val idle = MemoryFacts(bundleInstalled = FactState.YES, overlayLevelsMB = listOf(20))
        assertTrue(MemoryScreenState.from(idle).overlay.enabled)
        assertFalse(MemoryScreenState.from(idle.copy(isRunning = true)).overlay.enabled)
        assertFalse(MemoryScreenState.from(idle.copy(bundleInstalled = FactState.UNKNOWN)).overlay.enabled)
        assertFalse(MemoryScreenState.from(idle.copy(bundleInstalled = FactState.NO)).overlay.enabled)
        show(idle.copy(isRunning = true))
        compose.onNodeWithTag(UiPageTags.MEMORY_RUN_PREFIX + 20).assertHasNoClickAction()
        compose.onNodeWithTag(UiPageTags.MEMORY_RUN_LONG).assertHasNoClickAction()
    }

    /** The level being run carries the baseline's progress marker. */
    @Test
    fun `the running level carries the running marker`() {
        val facts = MemoryFacts(
            bundleInstalled = FactState.YES,
            overlayLevelsMB = listOf(20, 50),
            runningLevelMB = 50,
            isRunning = true,
        )
        assertTrue(MemoryScreenState.from(facts).overlay.runs.single { it.levelMB == 50 }.running)
        // A long session has no level: the baseline shows no spinner on the level rows.
        assertEquals(
            0,
            MemoryScreenState.from(
                MemoryFacts(bundleInstalled = FactState.YES, overlayLevelsMB = listOf(20), isRunning = true),
            ).overlay.runs.count { it.running },
        )
        show(facts)
        compose.onNodeWithTag(UiPageTags.MEMORY_RUNNING).assertIsDisplayed()
    }

    /** Progress: the phase, the runner's own status line, and the last run when known. */
    @Test
    fun `progress shows the phase, the status and the last run`() {
        show(MemoryFacts(phase = "seeding", statusText = "booted twice", lastRunAt = "10:41"))
        compose.onNodeWithText("seeding").assertIsDisplayed()
        compose.onNodeWithText("booted twice").assertIsDisplayed()
        compose.onNodeWithText("10:41").assertIsDisplayed()
        // An unread phase is 未知, not an empty line.
        val state = MemoryScreenState.from(MemoryFacts())
        assertEquals(UiStrings.UNKNOWN, state.progress.lines.first { it.key == UiStrings.MEMORY_KEY_PHASE }.value)
        assertEquals(UiStrings.UNKNOWN, state.progress.statusText)
        assertEquals(1, state.progress.lines.size)
    }

    /** Live samples: the last eight, in the baseline's t+N · footprint · avail form. */
    @Test
    fun `live samples show the last eight and the proxy note`() {
        val samples = (0 until 10).map { index ->
            MemorySample(
                offsetSeconds = index.toDouble(),
                footprintBytes = 1_048_576L * (index + 1),
                availableBytes = 2_097_152L,
                hostState = "running",
            )
        }
        val state = MemoryScreenState.from(MemoryFacts(liveSamples = samples))
        assertEquals(8, state.live.lines.size)
        assertEquals("t+2s", state.live.lines.first().key)
        assertEquals("t+9s", state.live.lines.last().key)
        assertEquals("3.0 MiB · avail 2.0 MiB · running", state.live.lines.first().value)
        assertEquals(UiStrings.MEMORY_LIVE_NOTE, state.live.note)
        show(MemoryFacts(liveSamples = samples))
        scrollTo(UiStrings.MEMORY_SECTION_LIVE)
        compose.onNodeWithText("t+9s").assertIsDisplayed()
        compose.onNodeWithText("t+0s").assertDoesNotExist()
        compose.onNodeWithText(UiStrings.MEMORY_LIVE_NOTE).assertIsDisplayed()
    }

    /** No sample yet is the baseline's own empty copy, not a zero count. */
    @Test
    fun `an empty sample list says no sample yet`() {
        val state = MemoryScreenState.from(MemoryFacts(liveSamples = emptyList()))
        assertTrue(state.live.empty)
        assertEquals(UiStrings.MEMORY_LIVE_EMPTY, state.live.note)
        show(MemoryFacts(liveSamples = emptyList()))
        scrollTo(UiStrings.MEMORY_SECTION_LIVE)
        compose.onNodeWithTag(UiPageTags.MEMORY_LIVE_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_LIVE_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_LIVE_NOTE).assertDoesNotExist()
    }

    /** Measured levels: the metrics appear only for MEASURED and FAILED. */
    @Test
    fun `measured levels show their metrics only when measured or failed`() {
        val measured = MemoryLevel(
            overlayMB = 20,
            status = MemoryScreenState.STATUS_MEASURED,
            bootSeconds = 1.5,
            durationSeconds = 12.25,
            webContentTerminations = 0,
            peakFootprintBytes = 1_048_576L,
            minAvailableBytes = 512L,
            sampleCount = 6,
        )
        val pending = MemoryLevel(overlayMB = 50, status = "PENDING")
        val state = MemoryScreenState.from(MemoryFacts(measuredLevels = listOf(measured, pending)))
        assertEquals(6, state.measured.levels[0].lines.size)
        assertTrue(state.measured.levels[0].lines.any { it.value == "1.50 s" })
        assertTrue(state.measured.levels[0].lines.any { it.value == "12.25 s" })
        assertTrue(state.measured.levels[0].divider)
        assertTrue(state.measured.levels[1].lines.isEmpty())
        assertFalse(state.measured.levels[1].divider)
        assertEquals(PageTone.ON, state.measured.levels[0].statusTone)
        assertEquals(PageTone.NORMAL, state.measured.levels[1].statusTone)
        show(MemoryFacts(measuredLevels = listOf(measured, pending)))
        scrollTo(UiStrings.MEMORY_SECTION_MEASURED)
        compose.onNodeWithText("20 MB").assertIsDisplayed()
        compose.onNodeWithText(MemoryScreenState.STATUS_MEASURED).assertIsDisplayed()
        compose.onNodeWithText("PENDING").assertIsDisplayed()
        // One "boot" line only: the pending level contributes no metrics.
        compose.onAllNodesWithText(UiStrings.MEMORY_KEY_BOOT).assertCountEquals(1)
    }

    /** The session's empty branch is the baseline's own sentence. */
    @Test
    fun `the session card quotes the empty note until a run records it`() {
        val empty = MemoryScreenState.from(
            MemoryFacts(session = MemorySession(status = MemoryScreenState.STATUS_NOT_VERIFIED)),
        )
        assertTrue(empty.session.empty)
        assertEquals(UiStrings.MEMORY_SESSION_EMPTY, empty.session.note)
        assertTrue(empty.session.lines.isEmpty())

        val recorded = MemoryScreenState.from(
            MemoryFacts(
                session = MemorySession(
                    status = "DONE",
                    plannedRestarts = 2,
                    webContentTerminations = 1,
                    peakFootprintBytes = 1_048_576L,
                    sampleCount = 9,
                ),
            ),
        )
        assertFalse(recorded.session.empty)
        assertEquals(4, recorded.session.lines.size)
        assertEquals("2", recorded.session.lines[0].value)
        show(
            MemoryFacts(
                session = MemorySession(
                    status = "DONE",
                    plannedRestarts = 2,
                    webContentTerminations = 1,
                    peakFootprintBytes = 1_048_576L,
                    sampleCount = 9,
                ),
            ),
        )
        scrollTo(UiStrings.MEMORY_SECTION_SESSION)
        compose.onNodeWithText("DONE").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_KEY_PLANNED_RESTARTS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MEMORY_SESSION_EMPTY).assertDoesNotExist()
    }

    /** The baseline's 一 glyph stands in for every number it could not produce. */
    @Test
    fun `an unmeasured number renders the baseline's dash`() {
        val state = MemoryScreenState.from(
            MemoryFacts(
                session = MemorySession(status = "DONE"),
                measuredLevels = listOf(MemoryLevel(overlayMB = 20, status = MemoryScreenState.STATUS_FAILED)),
            ),
        )
        assertEquals(UiStrings.MEMORY_UNSET_DASH, state.session.lines[0].value)
        assertTrue(state.measured.levels[0].lines.all { it.value == UiStrings.MEMORY_UNSET_DASH })
        assertEquals(6, state.measured.levels[0].lines.size)
    }

    /** Cancel is the baseline's destructive toolbar action, disabled unless running. */
    @Test
    fun `cancel is disabled unless a run is in flight`() {
        var cancels = 0
        show(MemoryFacts(isRunning = false), onCancel = { cancels += 1 })
        // A disabled clickable keeps its semantics node; a touch is the honest probe.
        compose.onNodeWithTag(UiPageTags.MEMORY_CANCEL_TAG).performTouchInput { click() }
        assertEquals(0, cancels)
    }

    @Test
    fun `cancel reports its gesture while a run is in flight`() {
        var cancels = 0
        show(MemoryFacts(isRunning = true), onCancel = { cancels += 1 })
        compose.onNodeWithTag(UiPageTags.MEMORY_CANCEL_TAG).performClick()
        assertEquals(1, cancels)
    }
}

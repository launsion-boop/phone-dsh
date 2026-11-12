// Shared page chrome adopts the §7 disclosure components: the fold chevron is
// SPDX-License-Identifier: MIT
// `motion.chevron` (120 ms), not the page's previous 160 ms tween.
//
// The page header itself has no body: `SessionsPage` and `BluetoothDevicesPage`
// mount the rows below the header as their own `LazyColumn` items, so the 160 ms
// `motion.disclosure` body edge is covered on the pages that own a body
// (`SessionActivityPage`, `NativeDeviceSessionPage`).
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.disclosure.DisclosureKind
import com.phonedsh.ui.disclosure.DisclosureMotion
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PageDisclosureChromeTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `section header chevron runs motion chevron at 120 ms and keeps the row height`() {
        val durationMs = DisclosureMotion
            .specFor(DisclosureKind.CHEVRON, reducedMotion = false)
            .durationMs
        var expanded by mutableStateOf(false)
        var toggles by mutableIntStateOf(0)
        var rotation = 0f
        compose.setContent {
            PdshTheme {
                SectionHeader(
                    title = "已归档",
                    expanded = expanded,
                    onToggle = {
                        toggles += 1
                        expanded = !expanded
                    },
                    trailing = "3",
                    tag = "section-header",
                    onChevronRotationChanged = { rotation = it },
                )
            }
        }
        compose.mainClock.autoAdvance = false
        compose.waitForIdle()
        assertEquals("the chevron starts at zero", 0f, rotation, 0f)
        val restHeight = compose.onNodeWithTag("section-header").fetchSemanticsNode().boundsInRoot.height

        compose.onNodeWithTag("section-header").performClick()
        compose.mainClock.advanceTimeByFrame()
        assertEquals("one tap toggles exactly once", 1, toggles)

        compose.mainClock.advanceTimeBy(60)
        assertTrue("the chevron is mid-rotation at 60 ms (rotation=$rotation)", rotation > 0f && rotation < 90f)
        compose.mainClock.advanceTimeBy(80)
        assertEquals(
            "motion.chevron completes at ${durationMs}ms, not the previous 160 ms",
            90f,
            rotation,
            0.5f,
        )
        assertEquals(
            "§7 rule 3: the chevron does not change the row height",
            restHeight,
            compose.onNodeWithTag("section-header").fetchSemanticsNode().boundsInRoot.height,
        )
    }
}

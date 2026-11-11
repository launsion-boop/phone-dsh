// Compose behaviour tests for spec/ui/v1/interaction.md §7.
// SPDX-License-Identifier: MIT
//
// Observable on the JVM here: body height, chevron degrees, row height, header
// bounds and the one-toggle-per-tap callback count. Not JVM-observable: the
// fade alpha (Compose semantics has no alpha channel, and Robolectric is not a
// pixel baseline) and the absence of per-row stagger (a structural property of
// the single AnimatedVisibility body). Those two are asserted by construction.
package com.phonedsh.ui.disclosure

import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import kotlin.math.abs
import kotlin.math.roundToLong

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PdshDisclosureMotionTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val density: Float get() = compose.activity.resources.displayMetrics.density

    // Read the contract durations through the production resolver, never a copy.
    private val bodyDurationMs: Int
        get() = DisclosureMotion.specFor(DisclosureKind.BODY, reducedMotion = false).durationMs
    private val folderDurationMs: Int
        get() = DisclosureMotion.specFor(DisclosureKind.FOLDER, reducedMotion = false).durationMs
    private val chevronDurationMs: Int
        get() = DisclosureMotion.specFor(DisclosureKind.CHEVRON, reducedMotion = false).durationMs

    @After
    fun restoreAnimatorScale() {
        Settings.Global.putFloat(
            compose.activity.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
    }

    @Test
    fun `body animates height mid-flight and keeps the tapped header fixed`() {
        var toggles = 0
        var lastAnchor: DisclosureAnchor? = null
        mountBody(
            onToggle = { anchor ->
                toggles++
                lastAnchor = anchor
            },
        )
        compose.mainClock.autoAdvance = false

        val headerTag = PdshDisclosureTags.header(TAG)
        val bodyTag = PdshDisclosureTags.body(TAG)
        val before = compose.onNodeWithTag(headerTag).fetchSemanticsNode().boundsInRoot
        compose.onNodeWithTag(bodyTag).assertDoesNotExist()

        compose.onNodeWithTag(headerTag).performClick()
        compose.mainClock.advanceTimeByFrame()

        assertEquals("one tap toggles exactly once", 1, toggles)
        assertNotNull("the caller receives a scroll anchor", lastAnchor)
        assertEquals("the anchor carries the row key", ROW_KEY, lastAnchor?.key)
        val anchor = requireNotNull(lastAnchor)
        assertEquals("the anchor is captured at tap time", before.top, anchor.headerTopPx, 1f)

        val start = firstBodyFrame(bodyTag, BODY_HEIGHT_DP, bodyDurationMs)
        val half = start + bodyDurationMs / 2.0
        compose.mainClock.advanceTimeBy((half - compose.mainClock.currentTime).roundToLong())
        val elapsed = compose.mainClock.currentTime - start
        assertTrue("the middle sample is within one frame of half the body motion", abs(elapsed - bodyDurationMs / 2.0) <= 16.0)
        val midHeight = bodyHeightDp(bodyTag)
        val expectedMid = BODY_HEIGHT_DP * easeOut(elapsed / bodyDurationMs)
        assertEquals("the body height follows motion.disclosure at the middle sample", expectedMid, midHeight.toDouble(), 2.0)
        assertTrue("the middle sample is neither collapsed nor complete", midHeight > 1f && midHeight < BODY_HEIGHT_DP - 1f)
        assertEquals("rule 6: the tapped header does not move mid-animation", before.top, headerTop(headerTag), 0.5f)

        compose.mainClock.advanceTimeBy(bodyDurationMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        assertEquals("the body settles at its full height", BODY_HEIGHT_DP, bodyHeightDp(bodyTag), 1f)
        assertEquals("rule 6: the tapped header does not move at the end state", before.top, headerTop(headerTag), 0.5f)
    }

    @Test
    fun `one tap toggles once and a second tap collapses once`() {
        var toggles = 0
        mountBody(onToggle = { toggles++ })
        compose.mainClock.autoAdvance = false
        val header = compose.onNodeWithTag(PdshDisclosureTags.header(TAG))
        val bodyTag = PdshDisclosureTags.body(TAG)

        header.performClick()
        compose.mainClock.advanceTimeBy(bodyDurationMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        assertEquals(1, toggles)
        compose.onNodeWithTag(bodyTag).assertExists()

        header.performClick()
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeBy(bodyDurationMs / 2L)
        val midCollapse = bodyHeightDp(bodyTag)
        assertTrue(
            "the collapsing body is sampled between full and collapsed (height=$midCollapse)",
            midCollapse > 0f && midCollapse < BODY_HEIGHT_DP,
        )
        compose.mainClock.advanceTimeBy(bodyDurationMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        assertEquals(2, toggles)
        compose.onNodeWithTag(bodyTag).assertDoesNotExist()
    }

    @Test
    fun `chevron rotates mid-animation without changing the row height`() {
        var expanded by mutableStateOf(false)
        var rotation = 0f
        compose.setContent {
            PdshTheme {
                Column(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(ROW_TAG)
                            .clickable { expanded = !expanded },
                    ) {
                        PdshChevron(
                            expanded = expanded,
                            size = CHEVRON_SIZE_DP.dp,
                            tag = CHEVRON_TAG,
                            onRotationChanged = { rotation = it },
                        )
                        Text("row")
                    }
                }
            }
        }
        compose.mainClock.autoAdvance = false
        assertEquals(0f, rotation, 0f)
        assertEquals("the row height comes from the chevron box", CHEVRON_SIZE_DP.toFloat(), rowHeightDp(ROW_TAG), 1f)

        compose.onNodeWithTag(ROW_TAG).performClick()
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeBy(chevronDurationMs / 2L)
        assertTrue("the chevron is between 0 and 90 degrees mid-animation", rotation > 0f && rotation < 90f)
        assertEquals("rule 3: the row height is unchanged mid-rotation", CHEVRON_SIZE_DP.toFloat(), rowHeightDp(ROW_TAG), 1f)

        compose.mainClock.advanceTimeBy(chevronDurationMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        assertEquals("the chevron settles at 90 degrees", 90f, rotation, 0.01f)
        assertEquals("rule 3: the row height is unchanged at the end state", CHEVRON_SIZE_DP.toFloat(), rowHeightDp(ROW_TAG), 1f)
    }

    @Test
    fun `folder group uses the folder motion and keeps its header fixed`() {
        var toggles = 0
        mountFolder(onToggle = { toggles++ })
        compose.mainClock.autoAdvance = false
        val headerTag = PdshDisclosureTags.header(TAG)
        val bodyTag = PdshDisclosureTags.body(TAG)
        val before = compose.onNodeWithTag(headerTag).fetchSemanticsNode().boundsInRoot

        compose.onNodeWithTag(headerTag).performClick()
        compose.mainClock.advanceTimeByFrame()
        assertEquals(1, toggles)

        val start = firstBodyFrame(bodyTag, FOLDER_BODY_HEIGHT_DP, folderDurationMs)
        val half = start + folderDurationMs / 2.0
        compose.mainClock.advanceTimeBy((half - compose.mainClock.currentTime).roundToLong())
        val elapsed = compose.mainClock.currentTime - start
        assertTrue("the middle sample is within one frame of half the folder motion", abs(elapsed - folderDurationMs / 2.0) <= 16.0)
        val midHeight = bodyHeightDp(bodyTag)
        val expectedMid = FOLDER_BODY_HEIGHT_DP * easeOut(elapsed / folderDurationMs)
        assertEquals("the folder body follows motion.folderCollapse", expectedMid, midHeight.toDouble(), 2.0)
        assertEquals("rule 6: the folder header does not move mid-animation", before.top, headerTop(headerTag), 0.5f)

        compose.mainClock.advanceTimeBy(folderDurationMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        assertEquals(FOLDER_BODY_HEIGHT_DP, bodyHeightDp(bodyTag), 1f)
        assertEquals("rule 6: the folder header does not move at the end state", before.top, headerTop(headerTag), 0.5f)
    }

    @Test
    fun `animator duration scale zero snaps the body and chevron with no intermediate state`() {
        Settings.Global.putFloat(
            compose.activity.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            0f,
        )
        var toggles = 0
        var rotation = 0f
        var expanded by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                PdshDisclosure(
                    expanded = expanded,
                    onToggle = {
                        toggles++
                        expanded = !expanded
                    },
                    tag = TAG,
                    header = {
                        Row(modifier = Modifier.height(ROW_HEIGHT_DP.dp)) {
                            PdshChevron(
                                expanded = expanded,
                                tag = CHEVRON_TAG,
                                onRotationChanged = { rotation = it },
                            )
                            Text("header")
                        }
                    },
                    body = { Box(Modifier.fillMaxWidth().height(BODY_HEIGHT_DP.dp)) },
                )
            }
        }
        compose.mainClock.autoAdvance = false
        assertEquals("the chevron starts at zero", 0f, rotation, 0f)
        compose.onNodeWithTag(PdshDisclosureTags.body(TAG)).assertDoesNotExist()

        compose.onNodeWithTag(PdshDisclosureTags.header(TAG)).performClick()
        compose.mainClock.advanceTimeByFrame()

        assertEquals(1, toggles)
        assertEquals("reduced motion skips every body frame", BODY_HEIGHT_DP, bodyHeightDp(PdshDisclosureTags.body(TAG)), 0.5f)
        assertEquals("reduced motion snaps the chevron", 90f, rotation, 0.01f)
    }

    private fun mountBody(onToggle: (DisclosureAnchor) -> Unit) {
        compose.setContent {
            PdshTheme {
                var expanded by remember { mutableStateOf(false) }
                PdshDisclosure(
                    expanded = expanded,
                    onToggle = { anchor ->
                        onToggle(anchor)
                        expanded = !expanded
                    },
                    tag = TAG,
                    anchorKey = ROW_KEY,
                    header = {
                        Box(modifier = Modifier.fillMaxWidth().height(ROW_HEIGHT_DP.dp)) {
                            Text("header")
                        }
                    },
                    body = {
                        Box(modifier = Modifier.fillMaxWidth().height(BODY_HEIGHT_DP.dp))
                    },
                )
            }
        }
    }

    private fun mountFolder(onToggle: (DisclosureAnchor) -> Unit) {
        compose.setContent {
            PdshTheme {
                var expanded by remember { mutableStateOf(false) }
                PdshFolderGroup(
                    expanded = expanded,
                    onToggle = { anchor ->
                        onToggle(anchor)
                        expanded = !expanded
                    },
                    tag = TAG,
                    anchorKey = ROW_KEY,
                    header = {
                        Box(modifier = Modifier.fillMaxWidth().height(ROW_HEIGHT_DP.dp)) {
                            PdshChevron(expanded = expanded)
                            Text("folder")
                        }
                    },
                    body = {
                        Box(modifier = Modifier.fillMaxWidth().height(FOLDER_BODY_HEIGHT_DP.dp))
                    },
                )
            }
        }
    }

    /** Advances until the body is visibly growing, then returns the recovered start instant. */
    private fun firstBodyFrame(bodyTag: String, fullHeightDp: Float, durationMs: Int): Double {
        var attempts = 0
        var height = 0f
        var observedAt = compose.mainClock.currentTime.toDouble()
        while (attempts < 20 && height <= 0.2f) {
            compose.mainClock.advanceTimeByFrame()
            observedAt = compose.mainClock.currentTime.toDouble()
            height = bodyHeightDp(bodyTag)
            attempts++
        }
        assertTrue("the body started animating (height=$height)", height > 0.2f)
        val progress = (height / fullHeightDp).coerceIn(0f, 1f)
        return observedAt - elapsedForEaseOut(progress, durationMs)
    }

    private fun bodyHeightDp(tag: String): Float =
        compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.height / density

    private fun rowHeightDp(tag: String): Float =
        compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.height / density

    private fun headerTop(tag: String): Float =
        compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.top

    /** The contract's cubic-bezier(0, 0, 0.58, 1) y for a time fraction x. */
    private fun easeOut(x: Double): Double {
        var lo = 0.0
        var hi = 1.0
        repeat(40) {
            val mid = (lo + hi) / 2.0
            if (bezier(mid, 0.0, 0.58) < x) lo = mid else hi = mid
        }
        return bezier((lo + hi) / 2.0, 0.0, 1.0)
    }

    /** Inverts [easeOut] to the elapsed milliseconds that reach [progress]. */
    private fun elapsedForEaseOut(progress: Float, durationMs: Int): Double {
        var lo = 0.0
        var hi = 1.0
        repeat(40) {
            val mid = (lo + hi) / 2.0
            if (easeOut(mid) < progress) lo = mid else hi = mid
        }
        return ((lo + hi) / 2.0) * durationMs
    }

    private fun bezier(t: Double, p1: Double, p2: Double): Double {
        val u = 1.0 - t
        return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t
    }

    private companion object {
        const val TAG = "disclosure.test"
        const val ROW_KEY = "row-1"
        const val CHEVRON_TAG = "disclosure.test.chevron"
        const val ROW_TAG = "disclosure.test.row"
        const val ROW_HEIGHT_DP = 44
        const val CHEVRON_SIZE_DP = 40
        const val BODY_HEIGHT_DP = 100f
        const val FOLDER_BODY_HEIGHT_DP = 80f
    }
}

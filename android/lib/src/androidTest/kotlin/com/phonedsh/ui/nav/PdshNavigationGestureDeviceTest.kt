// Device-level pointer and inner-back checks for the real route host.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import android.graphics.Bitmap
import android.util.Log
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.nav.PdshHostAction.RefreshAutomation
import com.phonedsh.ui.page.AutomationFacts
import com.phonedsh.ui.page.AutomationSnapshot
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.theme.PdshTheme
import java.io.File
import java.io.FileOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdshNavigationGestureDeviceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun automationRefreshReceivesARealPointerTapOnTheDevice() {
        val actions = mutableListOf<PdshHostAction>()
        compose.setContent {
            PdshTheme {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Automation)),
                    facts = PdshNavFacts(automation = AutomationFacts(snapshot = AutomationSnapshot(schedules = emptyList()))),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = { actions += it },
                    home = { BasicText("home") },
                    webSurface = {},
                )
            }
        }
        compose.waitForIdle()

        val refresh = compose.onNodeWithTag(UiPageTags.AUTOMATION_REFRESH)
        refresh.assertIsDisplayed()
        val refreshBounds = refresh.fetchSemanticsNode().boundsInRoot
        val closeBounds = compose.onNodeWithTag(UiPageTags.AUTOMATION_BACK).fetchSemanticsNode().boundsInRoot
        val density = compose.activity.resources.displayMetrics.density
        saveEvidence("automation-refresh.png", """screen=${compose.activity.resources.displayMetrics.widthPixels}x${compose.activity.resources.displayMetrics.heightPixels}
density=$density
refreshBoundsPx=$refreshBounds
closeBoundsPx=$closeBounds
""")

        // Inject a pointer gesture at the tagged control's actual on-device bounds;
        // this exercises hit testing and the real callback, not a semantics click.
        refresh.performTouchInput { click(center) }
        compose.waitForIdle()
        assertEquals(listOf(RefreshAutomation), actions)
    }

    @Test
    fun fontWorkAndPermissionChildrenConsumeBackToSettingsIndex() {
        val backLevel = PdshBackLevel()
        val outerBacks = mutableListOf<String>()
        compose.setContent {
            PdshTheme {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Settings)),
                    facts = PdshNavFacts(settings = SettingsFacts()),
                    onNavigate = {},
                    onBack = { outerBacks += "route" },
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText("home") },
                    webSurface = {},
                    backLevel = backLevel,
                )
            }
        }
        compose.waitForIdle()
        val index = compose.onNodeWithTag(UiTags.SETTINGS_LIST)
        index.assertIsDisplayed()

        // Exercise the three actual local children through their stable index tags.
        compose.onNodeWithTag(UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "fontSize").performScrollTo().performClick()
        compose.onNodeWithTag("pdsh.settings.font-size.list").assertIsDisplayed()
        consumeToSettingsIndex(backLevel)

        compose.onNodeWithTag(UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "workDetails").performScrollTo().performClick()
        compose.onNodeWithTag("pdsh.settings.conversation.list").assertIsDisplayed()
        consumeToSettingsIndex(backLevel)

        compose.onNodeWithTag(UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "permissionDefaults").performScrollTo().performClick()
        compose.onNodeWithTag("pdsh.settings.permission-defaults").assertIsDisplayed()
        consumeToSettingsIndex(backLevel)
        assertTrue("local child back should not pop the settings route", outerBacks.isEmpty())
    }

    @Test
    fun aboutBackRetainsTheSettingsIndexScrollPosition() {
        compose.setContent {
            PdshTheme {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Settings)),
                    facts = PdshNavFacts(settings = SettingsFacts()),
                    onNavigate = {}, onBack = {}, onHome = {}, onHostAction = {},
                    home = { BasicText("home") }, webSurface = {},
                )
            }
        }
        val aboutTag = UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "about"
        compose.onNodeWithTag(UiTags.SETTINGS_LIST).performScrollToNode(hasTestTag(aboutTag))
        val row = compose.onNodeWithTag(aboutTag)
        row.performScrollTo().assertIsDisplayed()
        val before = row.fetchSemanticsNode().boundsInRoot
        row.performTouchInput { click(center) }
        compose.onNodeWithTag(UiTags.ABOUT_LIST).assertIsDisplayed()
        compose.onNodeWithContentDescription("返回").performTouchInput { click(center) }
        row.assertIsDisplayed()
        val after = row.fetchSemanticsNode().boundsInRoot
        assertEquals("returning from About keeps the visible index row", before.top, after.top, 1f)
    }

    @Test
    fun routeReplacementDisposesSettingsChildBackRegistration() {
        val backLevel = PdshBackLevel()
        val outerBacks = mutableListOf<String>()
        val nav = mutableStateOf(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Settings)))
        compose.setContent {
            PdshTheme {
                PdshNavHost(
                    nav = nav.value,
                    facts = PdshNavFacts(settings = SettingsFacts()),
                    onNavigate = {},
                    onBack = { outerBacks += "route" },
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText("home") },
                    webSurface = {},
                    backLevel = backLevel,
                )
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "fontSize").performScrollTo().performClick()
        compose.onNodeWithTag("pdsh.settings.font-size.list").assertIsDisplayed()
        // Replacing the route disposes the child registration; it must not leak
        // into the next route or consume its outer back.
        assertTrue(backLevel.available)
        nav.value = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Automation))
        compose.waitForIdle()
        assertFalse("settings child registration should be disposed with its route", backLevel.available)
        assertFalse("a replaced route has no inner level to consume", backLevel.consume())
        assertTrue("consuming stale settings state must not invoke route back", outerBacks.isEmpty())
        compose.onNodeWithTag(UiPageTags.AUTOMATION_ROOT).assertIsDisplayed()
    }

    private fun consumeToSettingsIndex(backLevel: PdshBackLevel) {
        assertTrue("subpage should register an inner back level", backLevel.available)
        assertTrue("inner back level should consume before route back", backLevel.consume())
        compose.waitForIdle()
        compose.onNodeWithTag(UiTags.SETTINGS_LIST).assertIsDisplayed()
        compose.onNodeWithTag("pdsh.settings.font-size.list").assertDoesNotExist()
        compose.onNodeWithTag("pdsh.settings.conversation.list").assertDoesNotExist()
        compose.onNodeWithTag("pdsh.settings.permission-defaults").assertDoesNotExist()
    }

    private fun saveEvidence(name: String, measurements: String) {
        val context = InstrumentationRegistry.getInstrumentation().context
        val directory = File(requireNotNull(context.getExternalFilesDir(null)), "navigation-gesture-evidence")
        check(directory.mkdirs() || directory.isDirectory)
        File(directory, "$name.txt").writeText(measurements)
        val bitmap: Bitmap = requireNotNull(
            InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot(),
        )
        FileOutputStream(File(directory, name)).use { output ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
        }
        bitmap.recycle()
        Log.i("PdshNavigationGesture", "Saved device evidence to ${directory.absolutePath}/$name")
    }
}

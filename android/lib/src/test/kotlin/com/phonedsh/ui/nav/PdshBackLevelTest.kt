// The one level of back that lives inside a route.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §5 `back-gesture`: one gesture pops one level, the root page
// exits the app. The router's stack is one kind of level; a sheet's child page (the
// settings sheet's 新会话默认权限) is another, and before [PdshBackLevel] the gesture
// skipped it — the whole sheet closed under the person. These tests mount the real
// [PdshNavHost] and drive the same registrar the app's back handler consumes, so the
// route wiring is asserted, not just the class.
//
// The taps go through the row's semantics action rather than injected touch input:
// what is under test is the route's registration, and a touch click would also assert
// the sheet frame's hit geometry (which the device tests own).
package com.phonedsh.ui.nav

import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PdshBackLevelTest {

    @get:Rule
    val compose = createComposeRule()

    /** Mounts the real router on one route, with the chain the app passes in. */
    private fun mount(route: PdshRoute, level: PdshBackLevel) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, route)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText(text = "home") },
                    webSurface = {},
                    backLevel = level,
                )
            }
        }
        compose.waitForIdle()
    }

    /** Opens the settings sheet's 新会话默认权限 child page. */
    private fun openPermissionDefaults() {
        compose.onNodeWithTag(UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "permissionDefaults")
            .performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
    }

    @Test
    fun `a route with no inner level leaves nothing to consume`() {
        val level = PdshBackLevel()
        mount(PdshRoute.Tools, level)
        compose.runOnIdle {
            assertFalse("命令 has no inner level", level.available)
            assertFalse("nothing to consume", level.consume())
        }
    }

    @Test
    fun `the settings child page is left before the sheet is closed`() {
        val level = PdshBackLevel()
        mount(PdshRoute.Settings, level)
        compose.runOnIdle { assertFalse("the index has no inner level", level.available) }

        openPermissionDefaults()
        compose.onNodeWithTag(com.phonedsh.ui.page.PERMISSION_DEFAULTS_NOTE_TAG).assertIsDisplayed()
        compose.runOnIdle {
            assertTrue("the child page registered one level", level.available)
            assertTrue("the gesture leaves the child page", level.consume())
        }
        compose.waitForIdle()

        // Back stayed inside the sheet: the index is showing again, and the child
        // page is gone (a popped route would have rendered `home` instead).
        compose.onNodeWithTag(com.phonedsh.ui.page.PERMISSION_DEFAULTS_NOTE_TAG).assertDoesNotExist()
        compose.onNodeWithTag(UiTags.SETTINGS_LIST).assertIsDisplayed()
        compose.runOnIdle {
            assertFalse("the level is closed once the child page is", level.available)
        }
    }

    @Test
    fun `the registration is withdrawn when another route replaces it`() {
        val level = PdshBackLevel()
        var route by mutableStateOf<PdshRoute>(PdshRoute.Settings)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, route)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText(text = "home") },
                    webSurface = {},
                    backLevel = level,
                )
            }
        }
        compose.waitForIdle()
        openPermissionDefaults()
        compose.runOnIdle { assertTrue(level.available) }

        // A route push is what the stack does; the replaced route must not keep the
        // gesture to itself.
        compose.runOnIdle { route = PdshRoute.Tools }
        compose.waitForIdle()
        compose.runOnIdle { assertFalse("the replaced route withdrew its level", level.available) }
    }

    @Test
    fun `a route mounted without a host chain still renders its child page`() {
        // The default `backLevel = null` keeps `PdshNavHost` usable by a host that
        // renders these pages without a back gesture; nothing may crash or leak.
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Settings)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText(text = "home") },
                    webSurface = {},
                )
            }
        }
        compose.waitForIdle()
        openPermissionDefaults()
        compose.onNodeWithTag(com.phonedsh.ui.page.PERMISSION_DEFAULTS_NOTE_TAG).assertIsDisplayed()
    }
}

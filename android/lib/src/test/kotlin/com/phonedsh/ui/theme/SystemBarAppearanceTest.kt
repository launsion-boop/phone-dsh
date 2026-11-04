// System-bar appearance follows the app's own light/dark choice (device issue 9).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.theme

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.view.WindowCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class SystemBarAppearanceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun `the icon policy inverts the app dark choice`() {
        assertFalse(useLightSystemBars(darkTheme = true))
        assertTrue(useLightSystemBars(darkTheme = false))
    }

    @Test
    fun `an explicit dark theme sets light bars in the activity window`() {
        show(darkTheme = true)
        val controller = controller()
        assertFalse("dark chrome needs light status-bar glyphs", controller.isAppearanceLightStatusBars)
        assertFalse("dark chrome needs light navigation-bar glyphs", controller.isAppearanceLightNavigationBars)
    }

    @Test
    fun `an explicit light theme clears light bars in the activity window`() {
        show(darkTheme = false)
        val controller = controller()
        assertTrue("light chrome needs dark status-bar glyphs", controller.isAppearanceLightStatusBars)
        assertTrue("light chrome needs dark navigation-bar glyphs", controller.isAppearanceLightNavigationBars)
    }

    private fun show(darkTheme: Boolean) {
        compose.setContent {
            PdshTheme(darkTheme = darkTheme) {
                Box(Modifier.fillMaxSize())
            }
        }
        compose.waitForIdle()
    }

    private fun controller() = WindowCompat.getInsetsController(
        compose.activity.window,
        compose.activity.window.decorView,
    )
}

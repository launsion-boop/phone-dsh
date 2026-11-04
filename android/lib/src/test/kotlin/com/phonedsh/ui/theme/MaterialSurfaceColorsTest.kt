// Material overlays follow the app's dark tokens (device dark-theme issue).
// SPDX-License-Identifier: MIT
//
// `PdshTheme` deliberately installs no MaterialTheme colour scheme, so an
// `AlertDialog`/`ModalBottomSheet` that omits a colour falls back to Material's
// built-in light surface. These tests compose the real theme and assert that the
// shared overlay palette resolves to the dark token table, and that a light
// theme still resolves to the light one.
package com.phonedsh.ui.theme

import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class MaterialSurfaceColorsTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `dark theme resolves dialog and sheet surfaces to dark tokens`() {
        var darkTokens: UiTokens? = null
        var dialog: MaterialSurfaceColors? = null
        var sheet: MaterialSurfaceColors? = null
        compose.setContent {
            PdshTheme(darkTheme = true) {
                val tokens = LocalUiTokens.current
                darkTokens = tokens
                dialog = materialDialogColors(tokens)
                sheet = materialSheetColors(tokens)
            }
        }
        compose.waitForIdle()

        val tokens = requireNotNull(darkTokens)
        assertTrue(tokens.dark)
        assertEquals(tokens.colors.input, requireNotNull(dialog).container)
        assertEquals(tokens.colors.textPrimary, requireNotNull(dialog).content)
        assertEquals(tokens.colors.page, requireNotNull(sheet).container)
        assertEquals(tokens.colors.textPrimary, requireNotNull(sheet).content)
        assertTrue(
            "the dialog surface must be a dark colour",
            requireNotNull(dialog).container.luminance() < 0.5f,
        )
        assertNotEquals(
            "the dialog must not reuse Material's light fallback",
            UiTokens.resolve(false, 411.dp).colors.input,
            requireNotNull(dialog).container,
        )
    }

    @Test
    fun `light theme keeps the light tokens and no overlay forces dark`() {
        var lightTokens: UiTokens? = null
        var dialog: MaterialSurfaceColors? = null
        compose.setContent {
            PdshTheme(darkTheme = false) {
                val tokens = LocalUiTokens.current
                lightTokens = tokens
                dialog = materialDialogColors(tokens)
            }
        }
        compose.waitForIdle()

        val tokens = requireNotNull(lightTokens)
        assertTrue(!tokens.dark)
        assertEquals(tokens.colors.input, requireNotNull(dialog).container)
        assertNotEquals(
            UiTokens.resolve(true, 411.dp).colors.input,
            requireNotNull(dialog).container,
        )
    }
}

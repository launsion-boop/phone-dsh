// Token colours for the Material overlays the app uses (dialogs and sheets).
// SPDX-License-Identifier: MIT
//
// PdshTheme deliberately installs no MaterialTheme colour scheme: the product
// chrome is the token table. Material's AlertDialog/ModalBottomSheet defaults
// therefore resolve against Material's built-in *light* scheme when a call site
// omits a colour, which painted light surfaces under the app's dark setting.
// Every overlay passes the page/text tokens through these two functions so the
// overlay follows the app theme instead of Material's fallback.
package com.phonedsh.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color

/** The two colours one Material overlay needs. */
@Immutable
internal data class MaterialSurfaceColors(
    val container: Color,
    val content: Color,
)

/**
 * Dialog surface: the input/sheet-card token, with primary text ink. The
 * dialogs that already passed token colours (egress delete, workspace create,
 * automation rule) use this same role, so new call sites do not introduce a
 * second dialog fill.
 */
internal fun materialDialogColors(tokens: UiTokens): MaterialSurfaceColors =
    MaterialSurfaceColors(container = tokens.colors.input, content = tokens.colors.textPrimary)

/**
 * Sheet surface: the page token, with primary text ink.
 *
 * Kept separate from [materialDialogColors] because the two Material components
 * expose different parameters (`textContentColor` vs `contentColor`) and a
 * future visual change to one must not silently move the other.
 */
internal fun materialSheetColors(tokens: UiTokens): MaterialSurfaceColors =
    MaterialSurfaceColors(container = tokens.colors.page, content = tokens.colors.textPrimary)

// Per-site modal sheet chrome, spec/ui/v1/interaction.md §2 rules 4-6.
// SPDX-License-Identifier: MIT
//
// The three chrome roles are independent: ConnectorsPage shows a grabber and a
// page background with a 32 pt radius, the subagent catalog hides the grabber,
// clears the background and uses 16 pt, and every other sheet follows the system
// default. Values come from the generated sheet tokens; no radius is typed here.
package com.phonedsh.ui.sheet

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import com.phonedsh.ui.theme.UiTokens

/** Rule 4: whether the platform sheet draws its drag indicator. */
public enum class SheetGrabber {
    /** The system default, which the contract records as hidden. */
    SYSTEM_DEFAULT,

    /** `presentationDragIndicator(.visible)`. */
    VISIBLE,

    /** `presentationDragIndicator(.hidden)`. */
    HIDDEN,
}

/** Rule 5: the sheet panel fill. */
public enum class SheetBackground {
    /** Material's own sheet container, the platform default for unlisted sheets. */
    SYSTEM_DEFAULT,

    /** `colors.page`. */
    PAGE,

    /** `Color.clear`; the panel content draws its own surface. */
    CLEAR,
}

/** Rule 6: the top corner radius. */
public enum class SheetCornerRadius {
    /** The platform radius, which the contract leaves unmeasured. */
    SYSTEM_DEFAULT,

    /** ConnectorsPage's 32 pt radius token. */
    CONNECTOR,

    /** The subagent catalog's 16 pt `radiusLG` token. */
    CATALOG,
}

/**
 * Per-site sheet chrome from `interaction.md` §2 rules 4-6.
 *
 * The named presets are the contract's three explicit chrome sites. The default
 * instance is the system chrome for every unlisted sheet.
 */
@Immutable
public data class SheetChrome(
    public val grabber: SheetGrabber = SheetGrabber.SYSTEM_DEFAULT,
    public val background: SheetBackground = SheetBackground.SYSTEM_DEFAULT,
    public val cornerRadius: SheetCornerRadius = SheetCornerRadius.SYSTEM_DEFAULT,
) {
    public companion object {
        /** `homeSheetChrome()`: visible grabber and `colors.page`, system radius. */
        public val HomeSheet: SheetChrome = SheetChrome(
            grabber = SheetGrabber.VISIBLE,
            background = SheetBackground.PAGE,
        )

        /** ConnectorsPage: visible grabber, `colors.page`, connector radius. */
        public val Connectors: SheetChrome = SheetChrome(
            grabber = SheetGrabber.VISIBLE,
            background = SheetBackground.PAGE,
            cornerRadius = SheetCornerRadius.CONNECTOR,
        )

        /** Subagent catalog: hidden grabber, clear background, catalog radius. */
        public val SubagentCatalog: SheetChrome = SheetChrome(
            grabber = SheetGrabber.HIDDEN,
            background = SheetBackground.CLEAR,
            cornerRadius = SheetCornerRadius.CATALOG,
        )
    }
}

/** Rule 4: the contract's system default is hidden; only [SheetGrabber.VISIBLE] draws. */
internal fun SheetChrome.grabberVisible(): Boolean = grabber == SheetGrabber.VISIBLE

/** Rule 5: the explicit fills, or `null` for Material's platform container. */
internal fun SheetChrome.containerColor(tokens: UiTokens): Color? = when (background) {
    SheetBackground.SYSTEM_DEFAULT -> null
    SheetBackground.PAGE -> tokens.colors.page
    SheetBackground.CLEAR -> Color.Transparent
}

/** Rule 6: the explicit radius tokens, or `null` for the platform sheet shape. */
internal fun SheetChrome.cornerRadiusDp(tokens: UiTokens): Dp? = when (cornerRadius) {
    SheetCornerRadius.SYSTEM_DEFAULT -> null
    SheetCornerRadius.CONNECTOR -> tokens.sheet.cornerRadiusConnector
    SheetCornerRadius.CATALOG -> tokens.sheet.cornerRadiusCatalog
}

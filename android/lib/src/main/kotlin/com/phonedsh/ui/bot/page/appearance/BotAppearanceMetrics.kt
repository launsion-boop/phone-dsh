// Geometry and copy for the shared Bot appearance picker.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotAppearancePicker.swift`
// and `spec/ui/v1/pages/bot-info.md` §外观. The values below are the Swift
// view's measured points, collected here so the picker body holds no literal
// length; theme colours still come from `LocalUiTokens`.
package com.phonedsh.ui.bot.page.appearance

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Geometry of [BotAppearancePicker] (`BotAppearancePicker.swift:32-87`). */
public object BotAppearanceMetrics {
    /** One hairstyle's 44 pt hit area (`BotAppearancePicker.swift:108`). */
    public val HAIRSTYLE_SLOT: Dp = 44.dp

    /** The 40 pt still fish inside that hit area (`BotAppearancePicker.swift:106`). */
    public val HAIRSTYLE_FISH: Dp = 40.dp

    /** The selected hairstyle's 2 pt outer ring (`BotAppearancePicker.swift:112`). */
    public val HAIRSTYLE_SELECTED_RING: Dp = 2.dp

    /** Gap between the four hairstyle stills (`BotAppearancePicker.swift:36`). */
    public val HAIRSTYLE_GAP: Dp = 6.dp

    /** One colour's 44 pt touch area (`BotAppearancePicker.swift:138`). */
    public val COLOR_SLOT: Dp = 44.dp

    /** The 24 pt swatch itself (`BotAppearancePicker.swift:129`). */
    public val COLOR_SWATCH: Dp = 24.dp

    /** The selected colour's 2 pt ring, 32 pt across (`BotAppearancePicker.swift:141-142`). */
    public val COLOR_RING: Dp = 32.dp

    /** Gap between swatches (`BotAppearancePicker.swift:50`). */
    public val COLOR_GAP: Dp = 2.dp

    /** The unselected swatch's 1 pt adaptive hairline (`BotAppearancePicker.swift:136`). */
    public val COLOR_HAIRLINE: Dp = 1.dp

    /** The selected swatch's 0.5 pt inner border (`BotAppearancePicker.swift:136`). */
    public val COLOR_SELECTED_HAIRLINE: Dp = 0.5.dp

    /** Row inset the colour strip bleeds through (`BotAppearancePicker.swift:58,79`). */
    public val COLOR_ROW_INSET: Dp = 16.dp

    /** Vertical room for a ring that is drawn outside the 24 pt swatch (`:61`). */
    public val COLOR_ROW_VERTICAL_PADDING: Dp = 2.dp

    /** Leading edge fade width (`BotAppearancePicker.swift:68`). */
    public val FADE_LEADING: Dp = 12.dp

    /** Trailing edge fade width, the "scroll for more" hint (`:72`). */
    public val FADE_TRAILING: Dp = 24.dp

    /** Space between the label and its control row (`BotAppearancePicker.swift:32,44`). */
    public val LABEL_GAP: Dp = 6.dp

    /** Space between the hairstyle group and the colour group (`:24`). */
    public val GROUP_GAP: Dp = 16.dp

    /** Picker vertical padding (`:88`). */
    public val PICKER_VERTICAL_PADDING: Dp = 4.dp

    /** Default in-picker preview size (`BotAppearancePicker.swift:18`). */
    public val PREVIEW_SIZE: Dp = 112.dp

    /** Section label size (`BotAppearancePicker.swift:34,46`). */
    public val LABEL_SIZE: TextUnit = 13.sp
}

/**
 * Copy the picker owns. `spec/ui/v1/bot/strings.json` does not freeze these
 * appearance labels (`BotAppearancePicker.swift:33,45`); they are page copy, not
 * the normative Bot status/error vocabulary in `BotUiStrings`.
 */
public object BotAppearanceCopy {
    public const val HAIRSTYLE: String = "发型"
    public const val COLOR: String = "颜色"

    /** `外观预览，<colour>，<hairstyle>` (`BotAppearancePicker.swift:29`). */
    public fun previewLabel(color: String, hairstyle: String): String =
        "外观预览，$color，$hairstyle"
}

/** Stable test tags, matching the Swift accessibility identifiers. */
public object BotAppearanceTags {
    /** The info page's prefix (`spec/ui/v1/pages/bot-info.md` §外观). */
    public const val INFO_PREFIX: String = "bot.info.appearance"

    /** The add-Bot dialog's prefix (`spec/ui/v1/pages/bot-drawer.md` §3). */
    public const val ADD_PREFIX: String = "bot.add.appearance"

    public fun hair(prefix: String, hairstyleWire: String): String =
        "$prefix.hair.$hairstyleWire"

    public fun color(prefix: String, colorWire: String): String =
        "$prefix.color.$colorWire"
}

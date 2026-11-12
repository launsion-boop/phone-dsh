// Geometry, copy and stable accessibility ids for the Bot drawer.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotDrawer.swift` and
// `spec/ui/v1/pages/bot-drawer.md` §2-§4. The drawer panel's width, trailing
// radius, overhang and motion come from `tokens.drawer`; the row/add/dialog
// numbers below are the Swift view's measured points, collected here so no
// composable retypes one. Copy that `strings.json` freezes comes from
// `BotUiStrings`; the rest is [BotDrawerCopy].
package com.phonedsh.ui.bot.page.drawer

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Measured geometry of the Bot drawer (`BotDrawer.swift:202-498`). */
public object BotDrawerMetrics {
    /** A narrow window keeps this much visible page beside the panel (`PdshDrawer.kt:326`). */
    public val MIN_PAGE_STRIP: Dp = 40.dp

    /** The 40 pt panel header row (`BotDrawer.swift:270`). */
    public val HEADER_HEIGHT: Dp = 40.dp

    /** The header's 44 pt "…" hit area (`BotDrawer.swift:261`) and its 18 pt glyph. */
    public val HEADER_ACTION: Dp = 44.dp
    public val MANAGE_ICON: Dp = 18.dp

    /** Panel content inset (`HomeSpec.chromeInset`, 16, `BotDrawer.swift:268`). */
    public val CHROME_INSET: Dp = 16.dp

    /** The trailing 8 pt inset after the "…" control (`BotDrawer.swift:269`). */
    public val HEADER_TRAILING_INSET: Dp = 8.dp

    /** The add pill's 52 pt height and 26 pt capsule radius (`BotDrawer.swift:288-290`). */
    public val ADD_PILL_HEIGHT: Dp = 52.dp
    public val ADD_PILL_RADIUS: Dp = 26.dp

    /** Hairline stroke of the add pill (`BotDrawer.swift:290`). */
    public val HAIRLINE: Dp = 0.5.dp

    /** Gap between the header and the add pill (`BotDrawer.swift:208`). */
    public val ADD_PILL_TOP_GAP: Dp = 8.dp

    /** Row list top inset (`BotDrawer.swift:335`). */
    public val ROWS_TOP_GAP: Dp = 10.dp

    /** Gap between rows (`BotDrawer.swift:319`). */
    public val ROW_GAP: Dp = 2.dp

    /** Row list side inset (`BotDrawer.swift:334`). */
    public val ROW_LIST_INSET: Dp = 8.dp

    /** Row inner horizontal inset (`BotDrawer.swift:451`). */
    public val ROW_INNER_INSET: Dp = 10.dp

    /** The 60 pt row (`BotDrawer.swift:452`). */
    public val ROW_HEIGHT: Dp = 60.dp

    /** Selected-row radius (`BotDrawer.swift:454`). */
    public val ROW_RADIUS: Dp = 12.dp

    /** Avatar/fish size in a row (`BotDrawer.swift:424`). */
    public val ROW_FISH: Dp = 38.dp

    /** Gap between the fish and the name/status column (`BotDrawer.swift:423`). */
    public val ROW_SPACING: Dp = 10.dp

    /** Gap between name and status (`BotDrawer.swift:427`). */
    public val ROW_TEXT_GAP: Dp = 2.dp

    /** Unread capsule minimum size (`BotDrawer.swift:444-445`). */
    public val UNREAD_MIN_SIZE: Dp = 20.dp

    /** Unread capsule horizontal padding (`BotDrawer.swift:444`). */
    public val UNREAD_PADDING_H: Dp = 6.dp

    /** Empty/error row vertical padding (`BotDrawer.swift:215-218,314-315`). */
    public val ROW_VERTICAL_PADDING: Dp = 12.dp

    /** Clear-button hit area in the add dialog (`BotDrawer.swift:730`). */
    public val CLEAR_BUTTON: Dp = 44.dp

    /** Add-dialog draft preview (`BotDrawer.swift:699`). */
    public val ADD_PREVIEW: Dp = 104.dp

    /** Add-dialog name field height/radius (`BotDrawer.swift:717-719`). */
    public val NAME_FIELD_HEIGHT: Dp = 48.dp
    public val NAME_FIELD_RADIUS: Dp = 12.dp

    /** Trailing room the clear button needs inside the field (`BotDrawer.swift:716`). */
    public val NAME_FIELD_TRAILING: Dp = 48.dp

    /** Dialog card width cap and padding (`HomeDrawer.swift:722-725`). */
    public val DIALOG_MAX_WIDTH: Dp = 360.dp
    public val DIALOG_RADIUS: Dp = 20.dp
    public val DIALOG_PADDING: Dp = 24.dp

    /** Manage-list fish size (`BotDrawer.swift:570`). */
    public val MANAGE_FISH: Dp = 36.dp

    /** Manage-list row horizontal inset (`BotDrawer.swift:568`). */
    public val MANAGE_ROW_INSET: Dp = 12.dp

    /** Manage-list hidden chip height (`BotDrawer.swift:590`). */
    public val HIDDEN_CHIP_HEIGHT: Dp = 18.dp
    public val HIDDEN_CHIP_PADDING_H: Dp = 6.dp

    /** The 20 pt icon that precedes the add label (`BotDrawer.swift:282`). */
    public val ADD_ICON: Dp = 20.dp

    /** Title/label type sizes (`BotDrawer.swift:252,284,429,434,442`). */
    public val TITLE_SIZE: TextUnit = 17.sp
    public val ADD_LABEL_SIZE: TextUnit = 17.sp
    public val NAME_SIZE: TextUnit = 15.sp
    public val STATUS_SIZE: TextUnit = 12.5.sp
    public val UNREAD_SIZE: TextUnit = 11.sp
    public val CAPTION_SIZE: TextUnit = 13.sp
    public val MANAGE_DESCRIPTION_SIZE: TextUnit = 12.5.sp

    /** Delete-confirm body inset (`HomeDrawer.swift:728`). */
    public val DIALOG_BODY_GAP: Dp = 16.dp
}

/**
 * Drawer copy that `spec/ui/v1/bot/strings.json` does not freeze. The normative
 * error/status/menu vocabulary stays in `BotUiStrings`; these are the drawer's
 * dialog titles and field labels (`BotDrawer.swift:231,240,604,706,758`).
 */
public object BotDrawerCopy {
    public const val PANEL_LABEL: String = "Bot 列表"
    public const val CLOSE_LABEL: String = "关闭 Bot 列表"
    public const val ADD_TITLE: String = "添加 Bot"
    public const val RENAME_TITLE: String = "给 Bot 改名"
    public const val NAME_LABEL: String = "名称"
    public const val NAME_PLACEHOLDER: String = "给这个 Bot 取个名字"
    public const val NAME_SECTION: String = "名字"
    public const val CLEAR_NAME: String = "清除名字"
    public const val CREATE_FAILED: String = "创建失败：{error}"
    public const val DELETE_TITLE: String = "删除「{name}」？"
    public const val DELETE_ACTION: String = "删除"
    public const val SAVE: String = "保存"
    public const val MANAGE_TITLE: String = "管理 Bot"
    public const val MANAGE_DONE: String = "完成"
    public const val MANAGE_SECTION: String = "全部 Bot"
    public const val MAIN_BOT: String = "主 Bot"
    public const val HIDDEN: String = "已隐藏"
    public const val NO_DESCRIPTION: String = "还没有描述"
    public const val MANAGE_MENU: String = "{name} 的操作"
    public const val RENAME_FAILED: String = "改名失败：{error}"
    public const val DELETE_FAILED: String = "删除失败：{error}"
    public const val NEW_BOT_PREVIEW: String = "新 Bot 预览，{color}，{hairstyle}"

    public fun format(template: String, vararg values: Pair<String, String>): String {
        var text = template
        for ((key, value) in values) text = text.replace("{$key}", value)
        return text
    }
}

/** Stable ids from `spec/ui/v1/pages/bot-drawer.md` and the Swift identifiers. */
public object BotDrawerTags {
    public const val PANEL: String = "bot.drawer.panel"
    public const val SCRIM: String = "bot.drawer.scrim"
    public const val MANAGE: String = "bot.drawer.manage"
    public const val ADD: String = "bot.drawer.add"
    public const val EMPTY: String = "bot.drawer.empty"
    public const val ERROR: String = "bot.drawer.error"
    public const val RETRY: String = "bot.drawer.retry"
    public const val ROW_PREFIX: String = "bot.drawer.row."
    public const val UNREAD_PREFIX: String = "bot.drawer.unread."

    public const val MANAGE_PANEL: String = "bot.manage.panel"
    public const val MANAGE_DONE: String = "bot.manage.done"
    public const val MANAGE_ERROR: String = "bot.manage.error"
    public const val MANAGE_ROW_PREFIX: String = "bot.manage.row."
    public const val MANAGE_MENU_PREFIX: String = "bot.manage.menu."

    public const val ADD_PANEL: String = "bot.add.panel"
    public const val ADD_NAME: String = "bot.add.name"
    public const val ADD_NAME_CLEAR: String = "bot.add.name.clear"
    public const val ADD_PREVIEW: String = "bot.add.preview"
    public const val ADD_CREATE: String = "bot.add.create"
    public const val ADD_CANCEL: String = "bot.add.cancel"
    public const val ADD_ERROR: String = "bot.add.error"

    public const val RENAME_PANEL: String = "bot.rename.panel"
    public const val RENAME_FIELD: String = "bot.rename.name"
    public const val RENAME_SAVE: String = "bot.rename.save"
    public const val RENAME_CANCEL: String = "bot.rename.cancel"
    public const val RENAME_ERROR: String = "bot.rename.error"

    public const val DELETE_PANEL: String = "bot.delete.panel"
    public const val DELETE_CONFIRM: String = "bot.drawer.delete.confirm"
    public const val DELETE_CANCEL: String = "bot.drawer.delete.cancel"
    public const val DELETE_MESSAGE: String = "bot.drawer.delete.message"

    public fun row(botID: String): String = ROW_PREFIX + botID
    public fun unread(botID: String): String = UNREAD_PREFIX + botID
    public fun manageRow(botID: String): String = MANAGE_ROW_PREFIX + botID
    public fun manageMenu(botID: String): String = MANAGE_MENU_PREFIX + botID
}

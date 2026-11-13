// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

/**
 * The Bot chat page's geometry and type, transcribed once from the reference
 * card system (`BotCardKit.swift:19-47`), the page (`BotChatPage.swift`) and
 * `spec/ui/v1/pages/bot-chat.md` §2. Every composable reads this object; no view
 * retypes a number. Colours and durations still come from
 * `LocalUiTokens`/`LocalUiType` and `BotTimers` where those own the value.
 */
public object BotChatMetrics {
    // ---- shared width (`BotCardKit.swift:22-24`, bot-chat.md §2) -----------
    /** Bot replies and cards stop at this share of the transcript column. */
    public const val CONTENT_WIDTH_RATIO: Float = 0.86f
    /** The user bubble's own cap (`BotChatPage.swift:889`). */
    public const val USER_BUBBLE_RATIO: Float = 0.80f

    // ---- card surface (`BotCardKit.swift:28-37`) --------------------------
    public const val CARD_PADDING_PT: Float = 12f
    public const val CARD_RADIUS_PT: Float = 16f
    public const val ROW_MIN_HEIGHT_PT: Float = 44f
    public const val GLYPH_COLUMN_PT: Float = 20f
    public const val TILE_PT: Float = 32f
    public const val BUTTON_HEIGHT_PT: Float = 44f
    public const val HEADING_GAP_PT: Float = 4f
    public const val BLOCK_GAP_PT: Float = 10f

    // ---- card type (`BotCardKit.swift:39-46`) -----------------------------
    public const val TITLE_SIZE_PT: Float = 15f
    public const val TITLE_LINE_PT: Float = 22f
    public const val BODY_SIZE_PT: Float = 14f
    public const val BODY_LINE_PT: Float = 20f
    public const val META_SIZE_PT: Float = 12f
    public const val META_LINE_PT: Float = 18f
    public const val EYEBROW_ICON_PT: Float = 13f
    public const val TAG_HEIGHT_PT: Float = 20f
    public const val TAG_PAD_H_PT: Float = 8f
    public const val TAG_SIZE_PT: Float = 12f
    public const val TAG_RADIUS_SHARE: Float = 0.5f
    public const val TAG_TINT_ALPHA: Float = 0.10f

    // ---- header (`bot-chat.md` §1/§6) -------------------------------------
    public const val HEADER_AVATAR_PT: Float = 32f
    public const val HEADER_NAME_SIZE_PT: Float = 17f
    public const val HEADER_NAME_PAD_LEADING_PT: Float = 6f
    public const val HEADER_NAME_PAD_TRAILING_PT: Float = 14f
    public const val DRAWER_STROKE_LONG_PT: Float = 18f
    public const val DRAWER_STROKE_SHORT_PT: Float = 12f
    public const val DRAWER_STROKE_HEIGHT_PT: Float = 2.4f
    public const val DRAWER_STROKE_GAP_PT: Float = 5f
    public const val HEADER_PILL_ICON_PT: Float = 19f
    public const val HEADER_MENU_ICON_PT: Float = 18f
    public const val HEADER_DEVICE_DOT_PT: Float = 6f
    public const val HEADER_DEVICE_DOT_INSET_PT: Float = 8f
    public const val HEADER_DEVICE_DOT_BORDER_PT: Float = 1f

    // ---- empty state (`BotChatPage.swift:361-376`, bot-chat.md §1) --------
    public const val EMPTY_AVATAR_PT: Float = 96f
    public const val EMPTY_TITLE_SIZE_PT: Float = 15f
    public const val EMPTY_TITLE_LINE_PT: Float = 22f
    public const val EMPTY_BODY_SIZE_PT: Float = 13f
    public const val EMPTY_BODY_LINE_PT: Float = 18f
    public const val EMPTY_GAP_PT: Float = 12f
    public const val EMPTY_VERTICAL_PAD_PT: Float = 24f
    public const val EMPTY_TEXT_MAX_WIDTH_PT: Float = 300f

    // ---- activity line (`BotActivityLine.swift:26-43`, bot-chat.md §4) -----
    public const val ACTIVITY_SIZE_PT: Float = 13f
    public const val ACTIVITY_LINE_PT: Float = 18f
    public const val ACTIVITY_HORIZONTAL_PAD_PT: Float = 24f
    public const val ACTIVITY_TOP_PAD_PT: Float = 4f
    public const val ACTIVITY_BOTTOM_PAD_PT: Float = 14f
    public const val ACTIVITY_FADE_SHARE: Float = 0.55f
    public const val ACTIVITY_SWAP_OFFSET_PT: Float = 8f
    public const val ACTIVITY_SWAP_BLUR_PT: Float = 2f
    public const val ACTIVITY_SHIMMER_MS: Int = 1_600
    public const val ACTIVITY_BREATH_MS: Int = 1_400
    public const val ACTIVITY_BREATH_MIN_ALPHA: Float = 0.70f
    public const val ACTIVITY_SWAP_RESPONSE: Float = 0.42f
    public const val ACTIVITY_SWAP_DAMPING: Float = 0.90f
    public const val ACTIVITY_APPEAR_MS: Int = 250
    public const val ACTIVITY_APPEAR_OFFSET_PT: Float = 6f

    // ---- transcript -------------------------------------------------------
    /** Room for the status line, reserved at all times (`BotChatPage.swift:307`). */
    public const val TRANSCRIPT_TOP_EXTRA_PT: Float = 14f
    public const val TRANSCRIPT_BOTTOM_PAD_PT: Float = 16f
    public const val TRANSCRIPT_ROW_GAP_SHARE: Float = 0.5f
    /** The card collapse animation (`bot-chat.md` §3: 0.25s easeInOut). */
    public const val SETTLE_ANIM_MS: Int = 250
    /** Expansion controls use 0.16s easeOut (`BotCardView.swift:254,271`). */
    public const val EXPAND_ANIM_MS: Int = 160
    public const val SETTLEMENT_MIN_HEIGHT_PT: Float = 28f
    public const val SETTLEMENT_PAD_H_PT: Float = 4f
    public const val SETTLEMENT_ICON_PT: Float = 12f
    public const val SETTLEMENT_TITLE_SIZE_PT: Float = 13f
    public const val SETTLEMENT_DETAIL_SIZE_PT: Float = 13f
    public const val SETTLEMENT_MONO_SIZE_PT: Float = 12f

    // ---- text bubbles (`BotChatPage.swift:874-947`) -----------------------
    public const val BUBBLE_PAD_H_PT: Float = 16f
    public const val BUBBLE_PAD_V_PT: Float = 12f
    public const val BUBBLE_LINE_SPACING_PT: Float = 4f
    public const val ATTACHMENT_CARD_RADIUS_PT: Float = 10f
    public const val ATTACHMENT_CARD_PAD_PT: Float = 8f
    public const val ATTACHMENT_ICON_BOX_PT: Float = 32f
    public const val ATTACHMENT_ICON_RADIUS_PT: Float = 8f
    public const val ATTACHMENT_NAME_SIZE_PT: Float = 13f
    public const val ATTACHMENT_META_SIZE_PT: Float = 11f

    // ---- composer (`BotChatPage.swift:384-447`, bot-chat.md §4) -----------
    public const val COMPOSER_MIN_HEIGHT_PT: Float = 52f
    public const val COMPOSER_RADIUS_PT: Float = 26f
    public const val COMPOSER_INSET_PT: Float = 8f
    public const val COMPOSER_CONTROL_PT: Float = 36f
    public const val COMPOSER_INPUT_GAP_PT: Float = 4f
    public const val COMPOSER_INPUT_PAD_V_PT: Float = 14f
    public const val COMPOSER_MAX_LINES: Int = 5
    public const val COMPOSER_TOP_PAD_PT: Float = 8f
    public const val COMPOSER_BOTTOM_PAD_PT: Float = 8f
    public const val COMPOSER_ATTACH_GLYPH_PT: Float = 16f
    public const val COMPOSER_SEND_GLYPH_PT: Float = 15f
    public const val CHIP_HEIGHT_PT: Float = 44f
    public const val CHIP_MAX_NAME_WIDTH_PT: Float = 150f
    public const val CHIP_REMOVE_TARGET_PT: Float = 28f

    // ---- approval command block (`BotWorkCardView.swift:357-401`) ---------
    public const val COMMAND_PAD_PT: Float = 12f
    public const val COMMAND_RADIUS_PT: Float = 12f
    public const val COMMAND_LINE_PT: Float = 18f
    public const val COMMAND_MAX_HEIGHT_PT: Float = 320f
    public const val COMMAND_LONG_CHARS: Int = 240
    public const val COMMAND_LONG_LINES: Int = 5

    // ---- progress / link (`BotCardKit.swift:473-495`, BotWorkCardView) ----
    public const val PROGRESS_TRACK_PT: Float = 4f
    public const val PROGRESS_GAP_PT: Float = 10f
    public const val LINK_ROW_MIN_PT: Float = 56f
    public const val LINK_ICON_PT: Float = 13f
    public const val AUTOMATION_DURATION_DIGITS: Int = 1

    // ---- agent-comm row (`BotChatPage.swift:812-872`) ---------------------
    public const val COMM_AVATAR_PT: Float = 28f
    public const val COMM_GAP_PT: Float = 10f
    public const val COMM_ICON_PT: Float = 11f
    public const val COMM_TEXT_SIZE_PT: Float = 13f
    public const val COMM_LINE_LIMIT: Int = 2
    public const val COMM_CLIP_CHARS: Int = 80


    // ---- shared spacing/hairline scale ------------------------------------
    /** Structural hairline (`BotCardKit.swift:307-317`). */
    public const val HAIRLINE_PT: Float = 0.5f
    /** One 1pt card edge/border (`BotCardKit.swift:133-134`). */
    public const val BORDER_PT: Float = 1f
    public const val GAP_1_PT: Float = 1f
    public const val GAP_2_PT: Float = 2f
    public const val GAP_3_PT: Float = 3f
    public const val GAP_4_PT: Float = 4f
    public const val GAP_5_PT: Float = 5f
    public const val GAP_6_PT: Float = 6f
    public const val GAP_8_PT: Float = 8f
    public const val GAP_10_PT: Float = 10f
    public const val GAP_12_PT: Float = 12f
    public const val GAP_14_PT: Float = 14f
    public const val GAP_16_PT: Float = 16f
    public const val ICON_10_PT: Float = 10f
    public const val ICON_11_PT: Float = 11f
    public const val ICON_12_PT: Float = 12f
    public const val ICON_13_PT: Float = 13f
    public const val ICON_15_PT: Float = 15f
    public const val ICON_16_PT: Float = 16f
    public const val ICON_17_PT: Float = 17f
    /** The empty state's minimum centering box (`BotChatPage.swift:285`). */
    public const val EMPTY_MIN_HEIGHT_PT: Float = 360f
    /** The attachment tray's measured height (`BotChatPage.swift:465`). */
    public const val CHIP_TRAY_HEIGHT_PT: Float = 46f
    /** Local document/source preview height cap (`BotChatPage.swift:1062-1091`). */
    public const val DIALOG_MAX_HEIGHT_PT: Float = 400f
    /** The composer's command/size labels (`BotWorkCardView.swift:367`). */
    public const val COMMAND_SIZE_PT: Float = 13f

    // ---- source/document dialogs -----------------------------------------
    public const val DIALOG_PAD_PT: Float = 20f
    public const val DOCUMENT_PREVIEW_MAX_LINES: Int = 3
}

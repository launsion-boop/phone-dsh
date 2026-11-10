// The Chat family's PR22 geometry, declared once.
// SPDX-License-Identifier: MIT
//
// Authority order used for every number below:
//
//   1. `examples/probe-app/PhoneDSHProbe/HomeSpec.swift` + the PR22 page source —
//      the home implementation at 430 x 932 pt: nav row, transcript, bubble and
//      open/closed composer all read HomeSpec directly.
//   2. `NativeParityTokens.swift` and the subcomponent Swift files PR22 kept
//      (question composer, todo dock, plan review, tool cards) — those rows are
//      still drawn from the parity table, so their literals remain exact.
//   3. PNG measurements from the audit screenshots; `pt = px / 3`.
//
// `UiMetrics` owns the frame/yardstick; this object owns the Chat page's
// per-surface numbers. Values PR22 no longer states keep their last measured
// parity value and say `inferred` / `legacy` in their own KDoc; no value below
// was invented for the new design.
//
// Confidence vocabulary (same in every `*Metrics.kt` file):
//
//   * `exact`    — a numeric literal (or token) in the Swift source.
//   * `measured` — read off a PNG; the KDoc gives the pixel evidence so it can
//                  be reproduced (`y=...px / 3 = ...pt`).
//   * `inferred` — derived from other values, not stated anywhere; every such
//                  constant says what it was derived from and why.
//
// This file is a declaration site, not a drawing site. A page that draws one of
// these reads the constant; that is how the page layer keeps `N.dp` out of its
// own source (`PageTokenReferenceTest`).

package com.phonedsh.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Chat page geometry: header, transcript, bubble, composer and the cards that
 * hang off the composer.
 *
 * Overlap with [UiMetrics] is intentional and documented per constant: that
 * object is the **official web** yardstick, this one is the **iOS
 * implementation**. Where the two disagree (e.g. the header, 50 vs 44) the
 * difference is a product decision, not a copy error, and the page lane must
 * pick the surface it is implementing.
 */
public object ChatMetrics {
    /** No additional inset; iOS ChatPage.spacing uses zero for the first row. */
    public const val NO_GAP_PT: Int = 0

    // ------------------------------------------------------ About identity row

    /** About page brand logo. Source: `NativeShell.swift:844-847`. Confidence: exact. */
    public const val ABOUT_BRANDING_LOGO_SIZE_PT: Int = 64
    /** About page branding stack gap. Source: `NativeShell.swift:843`. Confidence: exact. */
    public const val ABOUT_BRANDING_STACK_GAP_PT: Int = 8
    /** About page branding row vertical padding. Source: `NativeShell.swift:856`. Confidence: exact. */
    public const val ABOUT_BRANDING_ROW_PADDING_V_PT: Int = 12

    // ------------------------------------------------------------------ header

    /** PR22 floating nav row height. Source: `HomeSpec.navButton = 44`, `.nav { height: 44 }`. Confidence: exact. */
    public const val HEADER_HEIGHT_PT: Int = 44

    /**
     * PR22 nav title size. Source: `HomeSpec.navTitleSize = 17.5`.
     * Reference only: Android text sizes come from `LocalUiType`.
     * Confidence: exact.
     */
    public const val HEADER_TITLE_REF_PT: Float = 17.5f

    /** PR22 nav title weight (`.semibold`). Source: design spec `nav.title 600`. Reference only. Confidence: exact. */
    public const val HEADER_TITLE_WEIGHT_REF: Int = 600

    /** PR22 nav horizontal inset. Source: `HomeSpec.chromeInset = 16`. Confidence: exact. */
    public const val HEADER_HORIZONTAL_INSET_PT: Int = 16

    /** Drawer button slot: 44 x 44. Source: `HomeSpec.navButton`, `ChatPage.swift:207`. Confidence: exact. */
    public const val HEADER_LEADING_SLOT_WIDTH_PT: Int = 44

    /** Device entry half of the 92 pt pill: 46 x 44. Source: `ChatPage.swift:247`. Confidence: exact. */
    public const val HEADER_DEVICE_SLOT_WIDTH_PT: Int = 46

    /** Overflow ("more") half of the 92 pt pill: 46 x 44. Source: `ChatPage.swift:330`. Confidence: exact. */
    public const val HEADER_TRAILING_SLOT_WIDTH_PT: Int = 46

    /** Every nav control's height (the row is 44). Source: `HomeSpec.navButton`. Confidence: exact. */
    public const val HEADER_SLOT_HEIGHT_PT: Int = 44

    /** Side reserve the centred title must clear: 16 + 44 + 16 left, 92 + 16 right. Source: `HomeSpec.chromeInset/navButton/navPillWidth`. Confidence: inferred. */
    public const val HEADER_TITLE_SIDE_RESERVE_PT: Int = 108

    /** PR22 has no header hairline: the nav row floats on the page. Source: `ChatPage.swift:384` (`.background(HomeSpec.page)`). Confidence: exact. */
    public const val HEADER_DIVIDER_PT: Float = 0f

    /** More SF Symbol size and weight are represented by the bold registry vector. Source: `ChatPage.swift:329`. Confidence: exact. */
    public const val CHAT_HEADER_MORE_ICON_PT: Int = 18
    /** Vertical text gap in system-event message rows. Source: `NativeMessageRows.swift:113`. Confidence: exact. */
    public const val SYSTEM_EVENT_TEXT_GAP_PT: Int = 2

    // -------------------------------------------------------------- transcript

    /** PR22 content column at 430 pt: `430 - 2 x 20`. Source: `HomeSpec.contentInset`. Confidence: exact. */
    public const val CONTENT_COLUMN_WIDTH_PT: Int = 390

    /** PR22 transcript side inset. Source: `HomeSpec.contentInset = 20`, `ChatPage.swift:1219`. Confidence: exact. */
    public const val TRANSCRIPT_SIDE_INSET_PT: Int = 20

    /** Nav bottom -> timestamp gap. Source: design spec spacing table (`20`). Confidence: exact. */
    public const val TRANSCRIPT_TOP_INSET_PT: Int = 20

    /** Clearance for the floating latest-message control. Source: `ChatPage.swift:1224-1225`. Confidence: exact. */
    public const val TRANSCRIPT_LATEST_CLEARANCE_PT: Int = 48
    /** Failed-message row inline gap. Source: `ChatPage.swift:955`. Confidence: exact. */
    public const val FAILURE_LINE_GAP_PT: Int = 6
    /** Failed-message row top gap. Source: `ChatPage.swift:976`. Confidence: exact. */
    public const val FAILURE_LINE_TOP_PT: Int = 6
    /** Failure banner body and action font size. Source: `ChatPage.swift:957-972,1025-1038`. Confidence: exact. */
    public const val FAILURE_TEXT_SIZE_PT: Int = 13
    /** Top error banner inline gap. Source: `ChatPage.swift:1023`. Confidence: exact. */
    public const val FAILURE_BANNER_GAP_PT: Int = 12
    /** Top error banner horizontal inset. Source: `ChatPage.swift:1045`. Confidence: exact. */
    public const val FAILURE_BANNER_INSET_H_PT: Int = 4
    /** Top error banner vertical inset. Source: `ChatPage.swift:1046`. Confidence: exact. */
    public const val FAILURE_BANNER_INSET_V_PT: Int = 6

    /** Bottom clearance under the last row: composer height + 16. Source: design spec (`输入框高度 + 16`); open composer is 104. Confidence: inferred. */
    public const val TRANSCRIPT_BOTTOM_INSET_PT: Int = 104 + 16

    /** Block gap between transcript blocks. Source: `HomeSpec.blockGap = 20`. Confidence: exact. */
    public const val FLOW_GAP_PT: Int = 20

    /** Gap after a response row. Source: `HomeSpec.blockGap = 20`. Confidence: exact. */
    public const val RESPONSE_GAP_PT: Int = 20

    /** Gap after a turn-process control row. Source: `HomeSpec.blockGap = 20`. Confidence: exact. */
    public const val TURN_GAP_PT: Int = 20

    /** Paragraph gap after a user bubble / between paragraphs. Source: `HomeSpec.paragraphGap = 16`. Confidence: exact. */
    public const val PARAGRAPH_GAP_PT: Int = 16

    /** Process row -> its opened card. Source: `HomeSpec.disclosureGap = 8`. Confidence: exact. */
    public const val DISCLOSURE_GAP_PT: Int = 8

    /** Collapsed process row. Source: `HomeSpec.processRowHeight = 24`. Confidence: exact. */
    public const val DISCLOSURE_ROW_HEIGHT_PT: Int = 24

    /** Process row leading icon box. Source: `HomeSpec.processIcon = 18`. Confidence: exact. */
    public const val DISCLOSURE_ICON_PT: Int = 18

    /** Icon-to-title gap. Source: design spec (`间隔 6`). Confidence: exact. */
    public const val DISCLOSURE_ICON_GAP_PT: Int = 6

    /** List disclosure artwork box. Source: `NativeMessageRows.swift:34-35`. Confidence: exact. */
    public const val DISCLOSURE_LIST_ICON_BOX_PT: Int = 16
    /** List disclosure category artwork. Source: `NativeMessageRows.swift:32`. Confidence: exact. */
    public const val DISCLOSURE_LIST_CATEGORY_ICON_PT: Int = 14
    /** List disclosure artwork-to-title gap. Source: `NativeMessageRows.swift:36`. Confidence: exact. */
    public const val DISCLOSURE_LIST_ICON_GAP_PT: Int = 8

    /** Compact Markdown block gap. Source: `NativeMarkdownBody.swift` variant blockSpacing. Confidence: exact. */
    public const val MARKDOWN_COMPACT_BLOCK_SPACING_PT: Int = 4
    /** Compact Markdown list stack gap. Source: `NativeMarkdownBody.swift` list spacing. Confidence: exact. */
    public const val MARKDOWN_COMPACT_LIST_STACK_SPACING_PT: Int = 2
    /** Compact Markdown marker-to-text gap. Source: `NativeMarkdownBody.swift` list HStack. Confidence: exact. */
    public const val MARKDOWN_COMPACT_LIST_ITEM_GAP_PT: Int = 8
    /** Compact inline-code font. Source: `NativeMarkdownBody.swift:267-272`. Confidence: exact. */
    public const val MARKDOWN_COMPACT_INLINE_CODE_SIZE_PT: Int = 13
    /** Normal inline code uses the chosen code font size plus one. Source: `NativeMarkdownBody.swift:267-272`. Confidence: exact. */
    public const val MARKDOWN_INLINE_CODE_SIZE_OFFSET_PT: Int = 1

    /** Expanded thinking body's leading indent. Source: `NativeMessageRows.swift:92` (`.padding(.leading, 22)`). Confidence: exact. */
    public const val THINKING_CONTENT_INDENT_PT: Int = 22

    /** Expanded thinking body's vertical inset. Source: `NativeMessageRows.swift:93` (`.padding(.vertical, 4)`). Confidence: exact. */
    public const val THINKING_CONTENT_VERTICAL_PT: Int = 4

    /** Closed-turn process control row height. PR22 uses the 24 pt process row. Source: `HomeSpec.processRowHeight`. Confidence: exact. */
    public const val TURN_PROCESS_HEIGHT_PT: Int = 24

    // --------------------------------------------------------------- user bubble

    /** User bubble corner radius. Source: `HomeSpec.bubbleRadius = 24`, top-trailing square. Confidence: exact. */
    public const val USER_BUBBLE_RADIUS_PT: Int = 24

    /**
     * User-bubble maximum width runtime rule: `(containerWidth - 2 * contentInset) * 0.8`.
     * Source: `ChatPage.swift:3906`. The 312 pt result belongs to the 430 pt frame;
     * a split pane or narrow container must pass its own width.
     */
    public fun userBubbleMaxWidth(containerWidth: Dp, contentInset: Dp): Dp =
        ((containerWidth.value - 2f * contentInset.value) * HomeMetrics.BUBBLE_MAX_WIDTH_RATIO).dp

    // The user bubble's 16 h / 10 v text insets (`ChatPage.swift:3738-3739`) are
    // **not** declared here any more: L22 landed the spec split, so the bubble
    // surface reads `geometry.bubblePaddingH/V` (16/10) from the theme and this
    // file no longer holds a second copy of those two numbers. Keeping a constant
    // next to a token with the same value is the drift this repo rejects.

    /** User bubble line box. Source: `HomeSpec.bodyLine = 24`. Confidence: exact. */
    public const val USER_BUBBLE_LINE_HEIGHT_PT: Int = 24

    /** Assistant paragraph spacing. Source: `HomeSpec.paragraphGap = 16`. Confidence: exact. */
    public const val MESSAGE_PARAGRAPH_SPACING_PT: Int = 16

    /** Assistant list spacing. Source: `NativeChatTheme.swift:50`. Confidence: exact. */
    public const val MESSAGE_LIST_SPACING_PT: Int = 10

    /** Assistant body content margin. Source: `NativeChatTheme.swift:48`. Confidence: exact. */
    public const val MESSAGE_CONTENT_MARGIN_PT: Int = 20

    /** NativeComposerStats.swift: compact/detailed row both pad top by2, including empty detailed row. */
    public const val COMPOSER_STATS_TOP_PT: Int = 2

    // ----------------------------------------------------------------- composer

    /** Open composer width at 430 pt: `430 - 2 x 16`. Source: `HomeSpec.chromeInset`, design spec `左右边距 16, 宽 398`. Confidence: exact. */
    public const val COMPOSER_WIDTH_PT: Int = 398

    /** Open composer minimum; intrinsic text/control content may be taller. Source: `HomeSpec.composerOpenMinHeight`. Confidence: exact. */
    public const val COMPOSER_HEIGHT_PT: Int = 104

    /** Closed composer height. Source: design spec `.composer.closed { height: 56 }`. Confidence: exact. */
    public const val COMPOSER_CLOSED_HEIGHT_PT: Int = 56

    /** Open composer corner radius. Source: `HomeSpec.composerOpenRadius = 24`. Confidence: exact. */
    public const val COMPOSER_RADIUS_PT: Int = 24

    /** Closed composer corner radius. Source: design spec `.composer.closed { border-radius: 28 }`. Confidence: exact. */
    public const val COMPOSER_CLOSED_RADIUS_PT: Int = 28

    /** Composer outer side inset. Source: `HomeSpec.chromeInset = 16`. Confidence: exact. */
    public const val COMPOSER_OUTER_MARGIN_H_PT: Int = 16

    /** Composer dock outer top inset. Source: `ChatPage.swift:1931` (`.padding(.top, 8)`). Confidence: exact. */
    public const val COMPOSER_OUTER_MARGIN_TOP_PT: Int = 8

    /**
     * Composer outer bottom inset, now **0**.
     *
     * Source: commit `86a39aac` changed `ChatPage.swift:1894` `.padding(.bottom, 8)`
     * to `.padding(.bottom, 0)` — the stats line sits against the home-indicator
     * safe area instead of stacking an 8 pt card inset on top of it. `tokens.json`
     * had retained an obsolete bottom-inset role; the live component now reads
     * this source-owned zero value directly.
     * Confidence: exact.
     */
    public const val COMPOSER_OUTER_MARGIN_BOTTOM_PT: Int = 0

    /** Input port minimum height (one line). Source: `ChatPage.swift:1851` (`.frame(minHeight: 36)`). Confidence: exact. */
    public const val COMPOSER_PORT_MIN_HEIGHT_PT: Int = 36

    /** Input port maximum height before it scrolls internally. Source: `ChatPage.swift:1841` (`maxHeight: 336`). Confidence: exact. */
    public const val COMPOSER_PORT_MAX_HEIGHT_PT: Int = 336

    /** Input port leading inset. Source: `ChatPage.swift:1991` (`.padding(.leading, 11)`). Confidence: exact. */
    public const val COMPOSER_PORT_LEADING_PT: Int = 11

    /** Input port trailing inset (the send column is outside it). Source: design spec `.composer.open .row { right: 8 }`. Confidence: exact. */
    public const val COMPOSER_PORT_TRAILING_PT: Int = 8

    /** Input port top inset. Source: `ChatPage.swift:1993` (`.padding(.top, 8)`). Confidence: exact. */
    public const val COMPOSER_PORT_TOP_PT: Int = 8

    /**
     * Composer font size, forced to 16 so iOS focus zoom never triggers.
     * Source: `NativeParityTokens.swift:79`. Reference only: Android text sizes
     * come from `LocalUiType`. Confidence: exact.
     */
    public const val COMPOSER_FONT_REF_PT: Int = 16

    /** Control row height. Source: `ChatPage.swift:2007` (`.frame(height: 44)`). Confidence: exact. */
    public const val COMPOSER_CONTROL_ROW_HEIGHT_PT: Int = 44

    /** Control row leading inset. Source: `ChatPage.swift:2005`. Confidence: exact. */
    public const val COMPOSER_CONTROL_LEADING_PT: Int = 8

    /** Trailing width reserved for the send circle. Source: `ChatPage.swift:1866` (`.padding(.trailing, 40)`). Confidence: exact. */
    public const val COMPOSER_CONTROL_TRAILING_RESERVE_PT: Int = 40

    /** Control row top padding. Source: `ChatPage.swift:2008`. Confidence: exact. */
    public const val COMPOSER_CONTROL_TOP_PT: Int = 4

    /** Control row bottom padding. Source: `ChatPage.swift:2009`. Confidence: exact. */
    public const val COMPOSER_CONTROL_BOTTOM_PT: Int = 4

    /** Send/stop circle diameter. Source: `HomeSpec.sendButton = 36`. Confidence: exact. */
    public const val SEND_DIAMETER_PT: Int = 36

    /** Android touch frame; paint stays at the source 36pt diameter, trailing-aligned to preserve its 8pt visual gaps. Confidence: platform adaptation. */
    public const val SEND_HIT_PT: Int = 44

    /** Send/stop overlay inset from the card's trailing/bottom edges. Source: design spec (`离右边和底边各 8`). Confidence: exact. */
    public const val SEND_OVERLAY_INSET_PT: Int = 8

    /** Stop circle when it shares the row with a submit control. PR22 uses the 36 pt send circle. Source: `HomeSpec.sendButton`. Confidence: exact. */
    public const val STOP_INLINE_DIAMETER_PT: Int = 36

    /** Stop circle when it replaces the send control. Source: `HomeSpec.sendButton = 36`. Confidence: exact. */
    public const val STOP_DIAMETER_PT: Int = 36

    /** "回到最新" pill horizontal padding. Source: `ChatPage.swift:1337`. Confidence: exact. */
    public const val BACK_TO_LATEST_PADDING_H_PT: Int = 12

    /** "回到最新" pill vertical padding. Source: `ChatPage.swift:1338`. Confidence: exact. */
    public const val BACK_TO_LATEST_PADDING_V_PT: Int = 8

    /** "回到最新" pill bottom inset and separator stroke. Source: `ChatPage.swift:1343-1345`. Confidence: exact. */
    public const val BACK_TO_LATEST_BOTTOM_PT: Int = 12
    public const val BACK_TO_LATEST_BORDER_PT: Int = 1

    /** Default Large Caption 1 label size. Source: Apple HIG Typography, “Text styles”; `ChatPage.swift:1335`. Confidence: exact. */
    public const val BACK_TO_LATEST_LABEL_PT: Int = 12
    /** Default Large Caption 1 line height. Source: Apple HIG Typography, “Text styles”. Confidence: exact. */
    public const val BACK_TO_LATEST_LABEL_LINE_HEIGHT_PT: Int = 16

    /** "回到最新" pill corner radius. Source: `ChatPage.swift:1341-1342`. Confidence: exact. */
    public const val BACK_TO_LATEST_RADIUS_PT: Int = 12

    // -------------------------------------------------------------------- queue

    /** One queued-message row. Source: `ChatPage.swift:1690` (`.frame(height: 28)`), radius at `:1692`. Confidence: exact. */
    public const val QUEUE_ROW_HEIGHT_PT: Int = 28

    /** Queued-message row corner radius. Source: `ChatPage.swift:1692` (`RoundedRectangle(cornerRadius: 8)`). Confidence: exact. */
    public const val QUEUE_ROW_RADIUS_PT: Int = 8

    /** Queue strip's collapsed header row. Source: `ChatPage.swift:1557`. Confidence: exact. */
    public const val QUEUE_DOCK_HEADER_HEIGHT_PT: Int = 32

    /** Queue strip background corner radius. Source: `ChatPage.swift:1577`. Confidence: exact. */
    public const val QUEUE_DOCK_RADIUS_PT: Int = 12

    /** Queue row inner horizontal padding. Source: `ChatPage.swift:1641`. Confidence: exact. */
    public const val QUEUE_ROW_INSET_H_PT: Int = 10

    // ------------------------------------------------------------------- cards

    /** Permission card corner radius. Source: `ChatPage.swift:4467`. Confidence: exact. */
    public const val PERMISSION_CARD_RADIUS_PT: Int = 12

    /** Permission card inner padding. Source: `ChatPage.swift:4465` (`.padding(14)`). Confidence: exact. */
    public const val PERMISSION_CARD_PADDING_PT: Int = 14

    /** Permission card row spacing. Source: `ChatPage.swift:4425` (`VStack(spacing: 10)`). Confidence: exact. */
    public const val PERMISSION_CARD_SPACING_PT: Int = 10

    /** Permission card outer margin. Source: `ChatPage.swift:4468-4469`. Confidence: exact. */
    public const val PERMISSION_CARD_OUTER_MARGIN_H_PT: Int = 16

    /** Permission card outer vertical margin. Source: `ChatPage.swift:4469`. Confidence: exact. */
    public const val PERMISSION_CARD_OUTER_MARGIN_V_PT: Int = 8

    /** Allow-once button height. Source: `ChatPage.swift:4447` (`.frame(height: 48)`). Confidence: exact. */
    public const val PERMISSION_PRIMARY_HEIGHT_PT: Int = 48

    /** Allow-once button radius. Source: `ChatPage.swift:4448`. Confidence: exact. */
    public const val PERMISSION_PRIMARY_RADIUS_PT: Int = 12

    /** Deny button height (the 44 pt hit minimum). Source: `ChatPage.swift:4460`. Confidence: exact. */
    public const val PERMISSION_DENY_HEIGHT_PT: Int = 44

    /** Single-choice marker outer diameter in the current Android question fallback; source is the 20pt question marker in the PR22 reference capture. Confidence: image-measured. */
    public const val QUESTION_RADIO_OUTLINE_PT: Int = 20
    /** Selected radio center in the question fallback. Source: PR22 reference capture. Confidence: image-measured. */
    public const val QUESTION_RADIO_DOT_PT: Int = 8
    /** Multi-select checkbox frame. Source: `NativeQuestionComposer.swift:724`. Confidence: exact. */
    public const val QUESTION_CHECKBOX_FRAME_PT: Int = 20
    /** Multi-select checkbox corner radius. Source: `NativeQuestionComposer.swift:675-691`. Confidence: exact. */
    public const val QUESTION_CHECKBOX_RADIUS_PT: Int = 4
    /** Multi-select check glyph. Source: `NativeQuestionComposer.swift:691`. Confidence: exact. */
    public const val QUESTION_CHECKBOX_GLYPH_PT: Int = 14
    /** Legacy question-answer add icon. Source: PR22 reference capture. Confidence: image-measured. */
    public const val QUESTION_ANSWER_ADD_ICON_PT: Int = 16
    /** Question pager chevron drawing. Source: `NativeQuestionComposer.swift:723-724`. Confidence: exact. */
    public const val QUESTION_PAGER_ICON_PT: Int = 13
    /** Question header action glyph. Source: `NativeQuestionComposer.swift:723-724`. Confidence: exact. */
    public const val QUESTION_HEADER_ACTION_GLYPH_PT: Int = 13
    /** Plan-review change glyph. Source: `ChatPage.swift:1585`. Confidence: exact. */
    public const val PLAN_REVIEW_CHANGE_GLYPH_PT: Int = 14
    /** Goal clear glyph. Source: `ChatPage.swift:1514-1515`. Confidence: exact. */
    public const val GOAL_CLEAR_GLYPH_PT: Int = 11
    /** Todo dock leading checklist glyph. Source: `NativeTodoDock.swift:103-104`. Confidence: exact. */
    public const val TODO_DOCK_GLYPH_PT: Int = 14
    /** Todo dock disclosure chevron. Source: `NativeTodoDock.swift:130`. Confidence: exact. */
    public const val TODO_DOCK_CHEVRON_PT: Int = 14
    /** Pending attachment document glyph box. Source: PR22 reference capture. Confidence: image-measured. */
    public const val ATTACHMENT_DOCUMENT_GLYPH_PT: Int = 16
    /** Pending attachment remove glyph box. Source: PR22 reference capture. Confidence: image-measured. */
    public const val ATTACHMENT_REMOVE_GLYPH_PT: Int = 14
    /** Space between the access-mode shield and disclosure. Source: `ChatPage.swift` accessModeMenu. Confidence: exact. */
    public const val ACCESS_MODE_ICON_GAP_PT: Int = 2
    /** Access-mode shield glyph. Source: `ChatPage.swift:2210-2218`. Confidence: exact. */
    public const val ACCESS_MODE_SHIELD_GLYPH_PT: Int = 20
    /** Access-mode disclosure glyph. Source: `ChatPage.swift:2210-2218`. Confidence: exact. */
    public const val ACCESS_MODE_CHEVRON_GLYPH_PT: Int = 10
    /** Access-mode failure mark after automatic retries. Source: `ChatPage.swift` accessModeMenu label. Confidence: exact. */
    public const val ACCESS_MODE_ALERT_DOT_PT: Int = 6
    /** Access-mode retry spinner stroke (iOS `ProgressView().controlSize(.mini)`). Source: `ChatPage.swift` accessModeMenu label. Confidence: approximated. */
    public const val ACCESS_MODE_SPINNER_STROKE_PT: Float = 1.5f
    /** Model name/effort gap. Source: `ChatPage.swift:2354`. Confidence: exact. */
    public const val MODEL_EFFORT_GAP_PT: Int = 6
    /** Model-menu disclosure glyph. Source: `ChatPage.swift:2363`. Confidence: exact. */
    public const val MODEL_MENU_CHEVRON_GLYPH_PT: Int = 12
    /** Composer menu row check glyph. Source: `ChatPage.swift` model/access menu selection rows. Confidence: exact. */
    public const val COMPOSER_MENU_CHECK_GLYPH_PT: Int = 16

    /** Queue dock header text/icon gap. Source: `ChatPage.swift:1632`. Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_GAP_PT: Int = 10
    /** Queue dock leading glyph. Source: `ChatPage.swift:1625-1626`. Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_ICON_PT: Int = 14
    /** Queue dock header line height. Source: `ChatPage.swift:1636`. Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_HEIGHT_PT: Int = 32
    /** Queue dock title font size. Source: `ChatPage.swift:1628`. Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_FONT_PT: Int = 13
    /** Queue header disclosure glyph size. Source: `ChatPage.swift:1633`. Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_CHEVRON_PT: Int = 12
    /** Single-row queue marker glyph size. Source: `ChatPage.swift:1680`. Confidence: exact. */
    public const val CHAT_QUEUE_ROW_GLYPH_PT: Int = 12
    /** Single-row marker layout box width. Source: `ChatPage.swift:1682`. Confidence: exact. */
    public const val CHAT_QUEUE_ROW_GLYPH_BOX_PT: Int = 16
    /** Queue row title font size. Source: `ChatPage.swift:1685`. Confidence: exact. */
    public const val CHAT_QUEUE_ROW_FONT_PT: Int = 13
    /** Queue row action glyph size. Source: `ChatPage.swift:1729`. Confidence: exact. */
    public const val CHAT_QUEUE_ACTION_GLYPH_PT: Int = 13
    /** Queue row action painted icon frame. Source: `ChatPage.swift:1731`. Confidence: exact. */
    public const val CHAT_QUEUE_ACTION_ICON_BOX_PT: Int = 28
    /** Queue row action hit target width. Source: `ChatPage.swift:1732`. Confidence: exact. */
    public const val CHAT_QUEUE_ACTION_TARGET_WIDTH_PT: Int = 34
    /** Queue row action hit target height. Source: `ChatPage.swift:1732`. Confidence: exact. */
    public const val CHAT_QUEUE_ACTION_TARGET_HEIGHT_PT: Int = 36
    /** Queue row minimum height. Source: `ChatPage.swift:1721`. Confidence: exact. */
    public const val CHAT_QUEUE_ROW_MIN_HEIGHT_PT: Int = 36
    /** Queue row horizontal inset. Source: `ChatPage.swift:1720`. Confidence: exact. */
    public const val CHAT_QUEUE_ROW_INSET_H_PT: Int = 10
    /** Queue row content spacing. Source: `ChatPage.swift:1677`. Confidence: exact. */
    public const val CHAT_QUEUE_ROW_GAP_PT: Int = 8
    /** Queue dock vertical stack gap. Source: `ChatPage.swift:1619`. Confidence: exact. */
    public const val CHAT_QUEUE_STACK_GAP_PT: Int = 4
    /** Queue card vertical inset. Source: `ChatPage.swift:1654`. Confidence: exact. */
    public const val CHAT_QUEUE_CARD_INSET_V_PT: Int = 2
    /** Queue divider inset after the leading row glyph. Source: `ChatPage.swift:1649`. Confidence: exact. */
    public const val CHAT_QUEUE_DIVIDER_INSET_PT: Int = 38
    /** Pending-send row stack gap. Source: `ChatPage.swift:1753`. Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_STACK_GAP_PT: Int = 4
    /** Pending-send row content gap. Source: `ChatPage.swift:1755`. Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_CONTENT_GAP_PT: Int = 8
    /** Pending-send row text size. Source: `ChatPage.swift:1759,1762`. Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_TEXT_PT: Int = 13
    /** Pending-send row height. Source: `ChatPage.swift:1769`. Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_HEIGHT_PT: Int = 28
    /** Pending-send row horizontal inset. Source: `ChatPage.swift:1768`. Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_INSET_H_PT: Int = 10
    /** Pending-send spinner size. Source: `ChatPage.swift:1756` (`controlSize(.mini)`). Confidence: inferred. */
    public const val CHAT_QUEUE_PENDING_SPINNER_PT: Int = 12

    /** Expanded tool card corner radius. Source: `NativeToolCardChrome.swift:33` (`radiusLG` = 16). Confidence: exact. */
    public const val TOOL_CARD_RADIUS_PT: Int = 16

    /** Expanded tool card hairline border. Source: `NativeToolCardChrome.swift:34`. Confidence: exact. */
    public const val TOOL_CARD_BORDER_PT: Float = 0.5f

    /** Expanded tool card outer margin (top = bottom = leading). Source: `NativeToolCardChrome.swift:34`. Confidence: exact. */
    public const val TOOL_CARD_OUTER_PT: Int = 4

    /** Code/tool banner padding: top. Source: `NativeToolCardChrome.swift:37`. Confidence: exact. */
    public const val TOOL_CARD_HEADER_TOP_PT: Int = 10

    /** Code/tool banner padding: bottom. Source: `NativeToolCardChrome.swift:37`. Confidence: exact. */
    public const val TOOL_CARD_HEADER_BOTTOM_PT: Int = 8

    /** Code/tool banner padding: leading. Source: `NativeToolCardChrome.swift:38`. Confidence: exact. */
    public const val TOOL_CARD_HEADER_LEADING_PT: Int = 22

    /** Code/tool banner padding: trailing. Source: `NativeToolCardChrome.swift:38`. Confidence: exact. */
    public const val TOOL_CARD_HEADER_TRAILING_PT: Int = 18

    /** Copy / wrap action target. Source: `NativeToolCardChrome.swift:43`. Confidence: exact. */
    public const val TOOL_CARD_ACTION_TARGET_PT: Int = 24

    /** Code body horizontal padding. Source: `NativeToolCardChrome.swift:48`. Confidence: exact. */
    public const val TOOL_CARD_BODY_HORIZONTAL_PT: Int = 22

    /** Code body top padding. Source: `NativeToolCardChrome.swift:49`. Confidence: exact. */
    public const val TOOL_CARD_BODY_TOP_PT: Int = 6

    /** Code body bottom padding. Source: `NativeToolCardChrome.swift:49`. Confidence: exact. */
    public const val TOOL_CARD_BODY_BOTTOM_PT: Int = 20

    /** IN/OUT section padding. Source: `NativeToolCardChrome.swift:56`. Confidence: exact. */
    public const val TOOL_CARD_IO_HORIZONTAL_PT: Int = 16

    /** IN/OUT section vertical padding. Source: `NativeToolCardChrome.swift:56`. Confidence: exact. */
    public const val TOOL_CARD_IO_VERTICAL_PT: Int = 12

    /** IN/OUT section max height. Source: `NativeToolCardChrome.swift:57`. Confidence: exact. */
    public const val TOOL_CARD_IO_MAX_HEIGHT_PT: Int = 150

    /** Details-card outer padding. Source: `NativeToolDetailsCard.swift:23`. Confidence: exact. */
    public const val TOOL_DETAILS_PADDING_PT: Int = 12

    /** Details-card per-item vertical padding. Source: `NativeToolDetailsCard.swift:24`. Confidence: exact. */
    public const val TOOL_DETAILS_ITEM_PADDING_V_PT: Int = 10

    /** Details-card per-item horizontal padding. Source: `NativeToolDetailsCard.swift:24`. Confidence: exact. */
    public const val TOOL_DETAILS_ITEM_PADDING_H_PT: Int = 14

    /** Details-card list max height. Source: `NativeToolDetailsCard.swift:25`. Confidence: exact. */
    public const val TOOL_DETAILS_LIST_MAX_HEIGHT_PT: Int = 320

    /** Standalone code block (non-tool-card) corner radius. Source: `Components.swift:221` (`.clipShape(RoundedRectangle(cornerRadius: 12 ...))`). Confidence: exact. */
    public const val CODE_BLOCK_RADIUS_PT: Int = 12

    /** Code block banner strip height. Source: `Components.swift:196` (`.frame(height: 34)`). Confidence: exact. */
    public const val CODE_BLOCK_BANNER_HEIGHT_PT: Int = 34

    /** Code block body padding. Source: `Components.swift:209` (`.padding(12)`). Confidence: exact. */
    public const val CODE_BLOCK_PADDING_PT: Int = 12

    /** Code block "expand all" footer height. Source: `Components.swift:216` (`.frame(height: 32)`). Confidence: exact. */
    public const val CODE_BLOCK_EXPAND_HEIGHT_PT: Int = 32

    /** Collapsed long-code max height. Source: `Components.swift:207` (`isLong ? 300 : nil`). Confidence: exact. */
    public const val CODE_BLOCK_COLLAPSED_MAX_HEIGHT_PT: Int = 300

    /** Todo dock height. Source: `NativeParityTokens.swift:102`. Confidence: exact. */
    public const val TODO_DOCK_HEIGHT_PT: Int = 36

    /** Todo list maximum height. Source: `NativeParityTokens.swift:103`. Confidence: exact. */
    public const val TODO_LIST_MAX_HEIGHT_PT: Int = 180

    /** Question composer maximum height. Source: `NativeParityTokens.swift:104`. Confidence: exact. */
    public const val QUESTION_MAX_HEIGHT_PT: Int = 520

    /** Question option minimum row height. Source: `NativeParityTokens.swift:105`. Confidence: exact. */
    public const val QUESTION_OPTION_MIN_HEIGHT_PT: Int = 40

    /** Submitted plan card height. Source: `NativeParityTokens.swift:106`. Confidence: exact. */
    public const val PLAN_CARD_HEIGHT_PT: Int = 60

    /** Subagent menu width. Source: `NativeParityTokens.swift:107`. Confidence: exact. */
    public const val SUBAGENT_MENU_WIDTH_PT: Int = 336
    /** Subagent menu height cap. Source: `NativeSubagentCatalogSheet.swift:124`. Confidence: exact. */
    public const val SUBAGENT_MENU_MAX_HEIGHT_PT: Int = 560
    /** Subagent menu lower bound. Source: `NativeSubagentCatalogSheet.swift:125`. Confidence: exact. */
    public const val SUBAGENT_MENU_MIN_HEIGHT_PT: Int = 120
    /** The card's top offset in the phone sheet. Source: `ChatPage.swift:481`. Confidence: exact. */
    public const val SUBAGENT_SHEET_TOP_INSET_PT: Int = 20
    /** Catalog card's content inset. Source: `NativeSubagentCatalogSheet.swift:107`. Confidence: exact. */
    public const val SUBAGENT_MENU_CARD_PADDING_PT: Int = 4
    /** Zero gap in the title/secondary label stack. Source: `NativeSubagentCatalogSheet.swift:282`. Confidence: exact. */
    public const val SUBAGENT_TITLE_STACK_GAP_PT: Int = 0
    /** All-side inset retained by the Android inline notice, with no visual change. Confidence: existing implementation. */
    public const val SUBAGENT_ERROR_MESSAGE_PADDING_PT: Int = 8
    /** Subagent catalog rows. Source: `NativeSubagentCatalogSheet.swift:246`. Confidence: exact. */
    public const val SUBAGENT_ROW_MIN_HEIGHT_PT: Int = 44
    /** Catalog row vertical inset. Source: `NativeSubagentCatalogSheet.swift:245`. Confidence: exact. */
    public const val SUBAGENT_ROW_INSET_V_PT: Int = 6
    /** Subagent catalog row leading inset. Source: `NativeSubagentCatalogSheet.swift:243`. Confidence: exact. */
    public const val SUBAGENT_ROW_INSET_LEADING_PT: Int = 9
    /** Subagent catalog row trailing inset. Source: `NativeSubagentCatalogSheet.swift:244`. Confidence: exact. */
    public const val SUBAGENT_ROW_INSET_TRAILING_PT: Int = 7
    /** Gap between row's identity, title and action. Source: `NativeSubagentCatalogSheet.swift:236,280`. Confidence: exact. */
    public const val SUBAGENT_ROW_GAP_PT: Int = 6
    /** Running/idle indicator slot. Source: `NativeSubagentCatalogSheet.swift:325`. Confidence: exact. */
    public const val SUBAGENT_ACTIVITY_SLOT_PT: Int = 14
    /** Idle activity dot. Source: `NativeSubagentCatalogSheet.swift:313-316`. Confidence: exact. */
    public const val SUBAGENT_ACTIVITY_DOT_PT: Int = 6
    /** Catalog title reference size. Source: `NativeSubagentCatalogSheet.swift:284`. Confidence: exact. */
    public const val SUBAGENT_TITLE_REF_PT: Int = 15
    /** Catalog secondary-line reference size. Source: `NativeSubagentCatalogSheet.swift:324`. Confidence: exact. */
    public const val SUBAGENT_SECONDARY_REF_PT: Int = 13
    /** Secondary-line height. Source: `NativeSubagentCatalogSheet.swift:321-324`. Confidence: exact. */
    public const val SUBAGENT_SECONDARY_HEIGHT_PT: Int = 15
    /** Sheet height budget removed from the device viewport. Source: `NativeSubagentCatalogSheet.swift:125` with its ChatPage caller's screenH−120. Confidence: exact. */
    public const val SUBAGENT_SHEET_HEIGHT_REDUCTION_PT: Int = 260
    /** Empty-card/content floor. Source: `NativeSubagentCatalogSheet.swift:130`. Confidence: exact. */
    public const val SUBAGENT_CARD_MIN_HEIGHT_PT: Int = 44
    /** Card's base content padding in the row-count height estimate. Source: `NativeSubagentCatalogSheet.swift:130`. Confidence: exact. */
    public const val SUBAGENT_CARD_BASE_PADDING_PT: Int = 8
    /** Per-row content height estimate for the source card. Source: `NativeSubagentCatalogSheet.swift:130`. Confidence: exact. */
    public const val SUBAGENT_ROW_CARD_HEIGHT_PT: Int = 44
    /** Always-empty disclosure slot for the flat ChatPage caller. Source: `NativeSubagentCatalogSheet.swift:257-275`. Confidence: exact. */
    public const val SUBAGENT_DISCLOSURE_SLOT_PT: Int = 14
    /** Disclosure/activity slot height. Source: `NativeSubagentCatalogSheet.swift:266,320`. Confidence: exact. */
    public const val SUBAGENT_DISCLOSURE_HEIGHT_PT: Int = 17
    /** Title line box height. Source: `NativeSubagentCatalogSheet.swift:288`. Confidence: exact. */
    public const val SUBAGENT_TITLE_LINE_HEIGHT_PT: Int = 22
    /** Gap inside the secondary metadata line. Source: `NativeSubagentCatalogSheet.swift:324`. Confidence: exact. */
    public const val SUBAGENT_SECONDARY_GAP_PT: Int = 4
    /** Mode chip corner radius. Source: `NativeSubagentCatalogSheet.swift:335`. Confidence: exact. */
    public const val SUBAGENT_MODE_CHIP_RADIUS_PT: Int = 4
    /** Mode chip horizontal inset. Source: `NativeSubagentCatalogSheet.swift:332`. Confidence: exact. */
    public const val SUBAGENT_MODE_CHIP_INSET_H_PT: Int = 4
    /** Error notice measured height. Source: `NativeSubagentCatalogSheet.swift:218-220`. Confidence: exact. */
    public const val SUBAGENT_ERROR_ROW_HEIGHT_PT: Int = 48
    /** No notice adds no height. Source: `NativeSubagentCatalogSheet.swift` cardHeight. */
    public const val SUBAGENT_NO_NOTICE_HEIGHT_PT: Int = 0

    // ---------------------------------------------------------------- native header controls

    /** ChatPage's drawer control width. Source: `HomeSpec.navButton = 44`. Confidence: exact. */
    public const val CHAT_DRAWER_WIDTH_PT: Int = 44
    /** Device entry control width (half the 92 pt pill). Source: `HomeSpec.navPillWidth`. Confidence: exact. */
    public const val CHAT_DEVICE_ENTRY_WIDTH_PT: Int = 46
    /** Overflow menu control width (half the 92 pt pill). Source: `HomeSpec.navPillWidth`. Confidence: exact. */
    public const val CHAT_HEADER_MENU_WIDTH_PT: Int = 46
    /** Fixed side reserve around the centered session title. Source: `HomeSpec.chromeInset/navButton/navPillWidth`. Confidence: inferred. */
    public const val CHAT_HEADER_TITLE_RESERVE_PT: Int = 108
    /** Gap inside the device/menu group. Source: design spec (two 46 pt halves, no gap). Confidence: exact. */
    public const val CHAT_HEADER_GROUP_GAP_PT: Int = 0
    /** Two-stroke drawer artwork box. Source: `HomeSpec.swift:207-211`. Confidence: exact. */
    public const val CHAT_DRAWER_ICON_PT: Int = 22
    /** Online marker diameter. Source: `NativeDeviceConnectionPage.swift:16-19`. Confidence: exact. */
    public const val CHAT_DEVICE_STATUS_DOT_PT: Int = 6
    /** Online marker border. Source: `NativeDeviceConnectionPage.swift:19`. Confidence: exact. */
    public const val CHAT_DEVICE_STATUS_BORDER_PT: Int = 1
    /** Online marker top/right offsets in the 36x44 entry. Source: `NativeDeviceConnectionPage.swift:17-19`. Confidence: exact. */
    public const val CHAT_DEVICE_STATUS_INSET_PT: Int = 9
    /** Device radio SF Symbol size. Source: `ChatPage.swift:246`. Confidence: exact. */
    public const val CHAT_DEVICE_ICON_SIZE_PT: Int = 19

    /** Empty-state column offset from the transcript viewport top. Source: `ChatPage.swift:1402-1408`. Confidence: exact. */
    public const val EMPTY_STATE_TOP_PT: Int = 88
    /** Empty-state title size. Source: `ChatPage.swift:1420,1442`. Confidence: exact. */
    public const val EMPTY_STATE_TITLE_SIZE_PT: Float = 17.5f
    /** Empty-state supporting line size. Source: `ChatPage.swift:1423,1445`. Confidence: exact. */
    public const val EMPTY_STATE_HINT_SIZE_PT: Int = 14
    /** Empty-state title-to-hint gap. Source: `ChatPage.swift:1425,1447`. Confidence: exact. */
    public const val EMPTY_STATE_HINT_TOP_PT: Int = 8
    /** Empty-state hint-to-primary-action gap. Source: `ChatPage.swift:1433,1455`. Confidence: exact. */
    public const val EMPTY_STATE_ACTION_TOP_PT: Int = 24
    /** Empty-state primary action height. Source: `HomeSpec.swift:211-220`. Confidence: exact. */
    public const val EMPTY_STATE_ACTION_HEIGHT_PT: Int = 50
    /** Empty-state primary action label size. Source: `HomeSpec.swift:215`. Confidence: exact. */
    public const val EMPTY_STATE_ACTION_LABEL_SIZE_PT: Int = 16

    // ----------------------------------------------------------- question composer

    /** Question takeover's card radius. Source: `NativeParityTokens.swift:112` (`radiusXL`). Confidence: exact. */
    public const val QUESTION_CARD_RADIUS_PT: Int = 20
    /** Bottom breathing room below the question footer. Source: `NativeQuestionComposer.swift:269`. Confidence: exact. */
    public const val QUESTION_CARD_BOTTOM_PT: Int = 10
    /** Composer-seat bottom inset around the takeover. Source: `ChatPage.swift:1718,1732`. Confidence: exact. */
    public const val QUESTION_SEAT_BOTTOM_PT: Int = 8
    /** Question header top inset. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. */
    public const val QUESTION_HEADER_TOP_PT: Int = 20
    /** Question header leading inset. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. */
    public const val QUESTION_HEADER_LEADING_PT: Int = 24
    /** Question header trailing inset. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. */
    public const val QUESTION_HEADER_TRAILING_PT: Int = 16
    /** Minimized question header bottom inset. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. */
    public const val QUESTION_HEADER_MINIMIZED_BOTTOM_PT: Int = 14
    /** Gap between question copy and header actions. Source: `NativeQuestionComposer.swift:290`. Confidence: exact. */
    public const val QUESTION_HEADER_COPY_ACTION_GAP_PT: Int = 16
    /** Question eyebrow-to-prompt stack gap. Source: `NativeQuestionComposer.swift:290`. Confidence: exact. */
    public const val QUESTION_HEADER_STACK_GAP_PT: Int = 5
    /** Question eyebrow size. Source: `NativeQuestionComposer.swift:293`. Confidence: exact. */
    public const val QUESTION_EYEBROW_SIZE_PT: Int = 11
    /** Question prompt size. Source: `NativeQuestionComposer.swift:299`. Confidence: exact. */
    public const val QUESTION_PROMPT_SIZE_PT: Int = 16
    /** Question minimize and close hit-area size. Source: `NativeQuestionComposer.swift:323-328`. Confidence: exact. */
    public const val QUESTION_HEADER_ACTION_SIZE_PT: Int = 32
    /** Gap between minimize and close controls. Source: `NativeQuestionComposer.swift:312`. Confidence: exact. */
    public const val QUESTION_HEADER_ACTION_GAP_PT: Int = 4
    /** Collapsed question header bottom inset is zero. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. */
    public const val QUESTION_HEADER_EXPANDED_BOTTOM_PT: Int = 0
    /** Question choice-list top inset. Source: `NativeQuestionComposer.swift:397`. Confidence: exact. */
    public const val QUESTION_OPTIONS_TOP_PT: Int = 12
    /** Question choice-list horizontal inset. Source: `NativeQuestionComposer.swift:397`. Confidence: exact. */
    public const val QUESTION_OPTIONS_INSET_H_PT: Int = 8
    /** Question choice-list bottom inset. Source: `NativeQuestionComposer.swift:397`. Confidence: exact. */
    public const val QUESTION_OPTIONS_BOTTOM_PT: Int = 4
    /** Question option row gap. Source: `NativeQuestionComposer.swift:389`. Confidence: exact. */
    public const val QUESTION_OPTION_GAP_PT: Int = 1
    /** Question option row vertical inset. Source: `NativeQuestionComposer.swift:433`. Confidence: exact. */
    public const val QUESTION_OPTION_PADDING_V_PT: Int = 8
    /** Question option row horizontal inset. Source: `NativeQuestionComposer.swift:433`. Confidence: exact. */
    public const val QUESTION_OPTION_PADDING_H_PT: Int = 6
    /** Question option corner radius. Source: `NativeParityTokens.swift:113` (`radiusMD`). Confidence: exact. */
    public const val QUESTION_OPTION_RADIUS_PT: Int = 12
    /** Question option number/check box diameter. Source: `NativeQuestionOptionRow.swift:17`. Confidence: exact. */
    public const val QUESTION_OPTION_MARK_SIZE_PT: Int = 24
    /** Question no-options answer field minimum height. Source: `NativeQuestionComposer.swift:361`. Confidence: exact. */
    public const val QUESTION_FREE_ANSWER_HEIGHT_PT: Int = 64
    /** Question footer top inset. Source: `NativeQuestionComposer.swift:512`. Confidence: exact. */
    public const val QUESTION_FOOTER_TOP_PT: Int = 12
    /** Question footer horizontal inset. Source: `NativeQuestionComposer.swift:512`. Confidence: exact. */
    public const val QUESTION_FOOTER_INSET_H_PT: Int = 10
    /** Question pager/action gap. Source: `NativeQuestionComposer.swift:489,512`. Confidence: exact. */
    public const val QUESTION_FOOTER_GAP_PT: Int = 12
    /** Question pager icon target. Source: `NativeQuestionComposer.swift:517-525`. Confidence: exact. */
    public const val QUESTION_PAGER_TARGET_PT: Int = 28
    /** Question action button height. Source: `NativeQuestionComposer.swift:674`. Confidence: exact. */
    public const val QUESTION_ACTION_HEIGHT_PT: Int = 36
    /** Question action button corner radius. Source: `NativeParityTokens.swift:114` (`radiusMD`). Confidence: exact. */
    public const val QUESTION_ACTION_RADIUS_PT: Int = 12
    /** Question action horizontal inset. Source: `NativeQuestionComposer.swift:687`. Confidence: exact. */
    public const val QUESTION_ACTION_PADDING_H_PT: Int = 14
    /** Question option text size. Source: `NativeQuestionComposer.swift:418`. Confidence: exact. */
    public const val QUESTION_OPTION_TEXT_SIZE_PT: Int = 14
    /** Question details horizontal inset. Source: `NativeQuestionComposer.swift:355`. Confidence: exact. */
    public const val QUESTION_DETAIL_INSET_H_PT: Int = 2
    /** Question detail vertical padding. Source: `NativeQuestionComposer.swift:356`. Confidence: exact. */
    public const val QUESTION_DETAIL_INSET_V_PT: Int = 8
    /** Question answer row vertical inset. Source: `NativeQuestionComposer.swift:462`. Confidence: exact. */
    public const val QUESTION_ANSWER_INSET_V_PT: Int = 8
    /** Question answer row horizontal inset. Source: `NativeQuestionComposer.swift:464`. Confidence: exact. */
    public const val QUESTION_ANSWER_INSET_H_PT: Int = 6
    /** Question action text button horizontal inset. Source: `NativeQuestionComposer.swift:682`. Confidence: exact. */
    public const val QUESTION_ACTION_TEXT_INSET_H_PT: Int = 10
    /** Question action text button vertical inset. Source: `NativeQuestionComposer.swift:682`. Confidence: exact. */
    public const val QUESTION_ACTION_TEXT_INSET_V_PT: Int = 8
    /** Question option list member minimum. Source: `NativeParityTokens.swift:105` (`questionOptionMinHeight`). Confidence: exact. */
    public const val QUESTION_OPTION_ROW_HEIGHT_PT: Int = 40
    /** Question footer error slot minimum height. Source: `NativeQuestionComposer.swift:493`. Confidence: exact. */
    public const val QUESTION_ERROR_SLOT_HEIGHT_PT: Int = 16
    /** Question card outer shadow approximation. Source: `NativeQuestionComposer.swift:282-283`; Android elevation differs. Confidence: approximated. */
    public const val QUESTION_CARD_SHADOW_PT: Int = 4
    /** Question answer body horizontal inset. Source: `NativeQuestionComposer.swift:397`. Confidence: exact. */
    public const val QUESTION_BODY_INSET_H_PT: Int = 8
    /** Question footer pager gap. Source: `NativeQuestionComposer.swift:516`. Confidence: exact. */
    public const val QUESTION_PAGER_GAP_PT: Int = 6
    /** Question panel interior bottom inset. Source: `NativeQuestionComposer.swift:269`. Confidence: exact. */
    public const val QUESTION_PANEL_BOTTOM_PT: Int = 10

    // -------------------------------------------------------------- plan review

    /** Plan-review card corner radius. Source: `NativeParityTokens.swift:110` (`radiusXL`). Confidence: exact. */
    public const val PLAN_REVIEW_CARD_RADIUS_PT: Int = 20
    /** Plan-review button height. Source: `NativePlanReviewCard.swift:200-210`. Confidence: exact. */
    public const val PLAN_REVIEW_BUTTON_HEIGHT_PT: Int = 36
    /** Plan-review button radius. Source: `NativeParityTokens.swift:111` (`radiusMD`). Confidence: exact. */
    public const val PLAN_REVIEW_BUTTON_RADIUS_PT: Int = 12
    /** Plan-review button horizontal inset. Source: `NativePlanReviewCard.swift:210`. Confidence: exact. */
    public const val PLAN_REVIEW_BUTTON_INSET_H_PT: Int = 14
    /** Gap between plan-review decision buttons. Source: `NativePlanReviewCard.swift:174`. Confidence: exact. */
    public const val PLAN_REVIEW_BUTTON_GAP_PT: Int = 8
    /** Plan-review section gap. Source: `NativePlanReviewCard.swift:141`. Confidence: exact. */
    public const val PLAN_REVIEW_SECTION_GAP_PT: Int = 8
    /** Plan-review card shadow approximation. Source: `NativePlanReviewCard.swift:97-98`; Android elevation differs. Confidence: approximated. */
    public const val PLAN_REVIEW_SHADOW_PT: Int = 3

    // ---------------------------------------------------------------- goal + todo dock

    /** GoalBar row height. Source: `ChatPage.swift:1452`. Confidence: exact. */
    public const val GOAL_BAR_HEIGHT_PT: Int = 40
    /** GoalBar radius. Source: `ChatPage.swift:1454`. Confidence: exact. */
    public const val GOAL_BAR_RADIUS_PT: Int = 10
    /** GoalBar horizontal inset. Source: `ChatPage.swift:1451`. Confidence: exact. */
    public const val GOAL_BAR_INSET_H_PT: Int = 10
    /** GoalBar icon size. Source: `ChatPage.swift:1421`. Confidence: exact. */
    public const val GOAL_BAR_ICON_SIZE_PT: Int = 14
    /** GoalBar element gap. Source: `ChatPage.swift:1420`. Confidence: exact. */
    public const val GOAL_BAR_GAP_PT: Int = 8
    /** GoalBar phase text size. Source: `ChatPage.swift:1425`. Confidence: exact. */
    public const val GOAL_BAR_PHASE_SIZE_PT: Int = 11
    /** GoalBar objective text size. Source: `ChatPage.swift:1428`. Confidence: exact. */
    public const val GOAL_BAR_OBJECTIVE_SIZE_PT: Int = 13
    /** GoalBar action text size. Source: `ChatPage.swift:1437,1440`. Confidence: exact. */
    public const val GOAL_BAR_ACTION_SIZE_PT: Int = 12
    /** Android target icon stroke approximation for the iOS target symbol. Confidence: approximated. */
    public const val GOAL_BAR_ICON_STROKE_TENTH_PT: Float = 1.4f
    /** Todo dock horizontal inset. Source: `NativeTodoDock.swift:93`. Confidence: exact. */
    public const val TODO_DOCK_INSET_H_PT: Int = 12
    /** Todo dock vertical inset. Source: `NativeTodoDock.swift:94`. Confidence: exact. */
    public const val TODO_DOCK_INSET_V_PT: Int = 6
    /** Todo dock/list row gap. Source: `NativeTodoDock.swift:89,166`. Confidence: exact. */
    public const val TODO_DOCK_GAP_PT: Int = 8
    /** Todo dock header line box. Source: `NativeTodoDock.swift:138`. Confidence: exact. */
    public const val TODO_DOCK_HEADER_LINE_PT: Int = 24
    /** Todo item line box. Source: `NativeTodoDock.swift:196`. Confidence: exact. */
    public const val TODO_ROW_HEIGHT_PT: Int = 20
    /** Todo status slot size. Source: `NativeTodoDock.swift:187`. Confidence: exact. */
    public const val TODO_STATUS_SLOT_PT: Int = 16
    /** Todo checklist artwork size. Source: `NativeTodoDock.swift:118`. Confidence: exact. */
    public const val TODO_CHECKLIST_ICON_PT: Int = 14
    /** Todo status dot size. Source: `NativeTodoDock.swift:187-188`. Confidence: exact. */
    public const val TODO_STATUS_DOT_PT: Int = 6
    /** Todo card radius. Source: `NativeParityTokens.swift:101` (`radiusLG`). Confidence: exact. */
    public const val TODO_DOCK_RADIUS_PT: Int = 16
    /** Todo line font size. Source: `NativeTodoDock.swift:121,125,190`. Confidence: exact. */
    public const val TODO_TEXT_SIZE_PT: Int = 13
    /** Todo glyph stroke width. Source: `NativeTodoDock.swift:206`. Confidence: approximated. */
    public const val TODO_GLYPH_STROKE_PT: Float = 0.875f
    /** Todo glyph dot radius. Source: `NativeTodoDock.swift:218-220`. Confidence: exact. */
    public const val TODO_GLYPH_DOT_RADIUS_PT: Float = 1.75f
    /** Todo glyph circle y centers. Source: `NativeTodoDock.swift:217`. Confidence: exact. */
    public const val TODO_GLYPH_ROW1_Y_PT: Float = 4.5f
    public const val TODO_GLYPH_ROW2_Y_PT: Float = 11.5f
    /** Todo glyph bullet center x. Source: `NativeTodoDock.swift:218`. Confidence: exact. */
    public const val TODO_GLYPH_BULLET_X_PT: Float = 2.0f
    /** Todo glyph text start and end. Source: `NativeTodoDock.swift:219-220`. Confidence: exact. */
    public const val TODO_GLYPH_LINE_START_X_PT: Int = 6
    public const val TODO_GLYPH_LINE_END_X_PT: Int = 13
    /** Todo panel shadow approximation. Source: `NativeTodoDock.swift:99-100`; Android elevation differs. Confidence: approximated. */
    public const val TODO_DOCK_SHADOW_PT: Int = 3
    /** Todo status dot row spacing. Source: `NativeTodoDock.swift:186-196`. Confidence: exact. */
    public const val TODO_STATUS_GAP_PT: Int = 10
    /** Todo status dot dimensions. Source: `NativeTodoDock.swift:187-188`. Confidence: exact. */
    public const val TODO_STATUS_DOT_CONTAINER_PT: Int = 16



    // Native component metrics required by the scoped C/D/F consumers.

    /** Category artwork inside the process icon box. Source: `NativeMessageRows.swift:32`. Confidence: exact. */
    public const val DISCLOSURE_CATEGORY_ICON_PT: Int = 16

    /** Expanded disclosure chevron artwork. Source: `NativeMessageRows.swift:31`. Confidence: exact. */
    public const val DISCLOSURE_CHEVRON_ICON_PT: Int = 14

    /** Actual editable text-view floor inside the port. Source: `ChatPage.swift:1987` (`max(56, composerHeight)`). Confidence: exact. */
    public const val COMPOSER_TEXT_MIN_HEIGHT_PT: Int = 56

    /** Placeholder leading inset inside the port. Source: `ChatPage.swift:1972`. Confidence: exact. */
    public const val COMPOSER_PLACEHOLDER_LEADING_PT: Int = 5

    /** Placeholder top inset inside the port. Source: `ChatPage.swift:1973`. Confidence: exact. */
    public const val COMPOSER_PLACEHOLDER_TOP_PT: Int = 8

    /** Control row trailing inset. Source: `ChatPage.swift:2006`. Confidence: exact. */
    public const val COMPOSER_CONTROL_TRAILING_PT: Int = 8

    /** Plus/access target minimum width. Source: `ChatPage.swift:2126,2140,2179`. Confidence: exact. */
    public const val COMPOSER_CONTROL_MIN_WIDTH_PT: Int = 40

    /** Flexible separation before the model. Source: `ChatPage.swift:2148` (`Spacer(minLength: 8)`). Confidence: exact. */
    public const val COMPOSER_MODEL_MIN_GAP_PT: Int = 8

    /** Action group leading inset and dual-button spacing. Source: `ChatPage.swift:2151,2155`. Confidence: exact. */
    public const val COMPOSER_ACTION_GAP_PT: Int = 8

    /** Send arrow font size inside its circle. Source: `ChatPage.swift:2067`. Confidence: exact. */
    public const val SEND_GLYPH_PT: Int = 15

    /** Stop artwork square edge. Source: `ChatPage.swift:2099`. Confidence: exact. */
    public const val STOP_GLYPH_PT: Int = 12

    /** Stop artwork corner radius. Source: `ChatPage.swift:2097`. Confidence: exact. */
    public const val STOP_GLYPH_RADIUS_PT: Int = 3

    /** Source text font applied by `NativeCodeHighlighter.attributed` in DSSCodeBlock. Source: `NativeCodeHighlighter.swift:19`. Separate from the user code preference (14pt). Confidence: exact. */
    public const val CODE_BLOCK_SOURCE_FONT_SIZE_PT: Int = 13

    /** Gap between code-language label and controls. Source: `Components.swift:164`. Confidence: exact. */
    public const val CODE_BLOCK_HEADER_GAP_PT: Int = 8

    /** Code toolbar horizontal inset. Source: `Components.swift:195`. Confidence: exact. */
    public const val CODE_BLOCK_HEADER_INSET_H_PT: Int = 12

    /** Code-language label size. Source: `Components.swift:166`. Confidence: exact. */
    public const val CODE_BLOCK_LABEL_SIZE_PT: Int = 11

    /** Wrap/copy toolbar action label size. Source: `Components.swift:172,187`. Confidence: exact. */
    public const val CODE_BLOCK_ACTION_SIZE_PT: Int = 11

    /** Wrap artwork inside the 28pt control. Source: `Components.swift:172-173`. Confidence: exact. */
    public const val CODE_BLOCK_WRAP_ICON_SIZE_PT: Int = 11

    /** Expand/collapse label size. Source: `Components.swift:213`. Confidence: exact. */
    public const val CODE_BLOCK_EXPAND_LABEL_SIZE_PT: Int = 12

    /** Copy icon-to-label gap. Source: `Components.swift:185`. Confidence: exact. */
    public const val CODE_BLOCK_COPY_GAP_PT: Int = 5

    /** Copy/check artwork size. Source: `Components.swift:186`. Confidence: exact. */
    public const val CODE_BLOCK_COPY_ICON_SIZE_PT: Int = 13

    /** Copy control minimum width. Source: `Components.swift:189`. Confidence: exact. */
    public const val CODE_BLOCK_COPY_MIN_WIDTH_PT: Int = 44

    /** Copy/wrap control square size. Source: `Components.swift:173,189`. Confidence: exact. */
    public const val CODE_BLOCK_CONTROL_SIZE_PT: Int = 28

    /** Attributed source extra line spacing. Source: `Components.swift:201`. Confidence: exact. */
    public const val CODE_BLOCK_LINE_SPACING_PT: Int = 5

    /** Code block outer vertical inset. Source: `Components.swift:224`. Confidence: exact. */
    public const val CODE_BLOCK_OUTER_INSET_V_PT: Int = 2

    /** NativeMarkdownBody block gap, separate from HomeSpec transcript blockGap. Source: `NativeChatTheme.swift:49`. Confidence: exact. */
    public const val MARKDOWN_BLOCK_SPACING_PT: Int = 20

    /** Markdown body line box; extra leading is computed at the preference's actual font size. Source: `NativeParityTokens.swift:55`. Confidence: exact. */
    public const val MARKDOWN_BODY_LINE_HEIGHT_PT: Int = 24

    /** Expanded list indentation. Source: `NativeMarkdownBody.swift:88`. Confidence: exact. */
    public const val MARKDOWN_LIST_INDENT_PT: Int = 8

    /** Compact list indentation. Source: `NativeMarkdownBody.swift:88`. Confidence: exact. */
    public const val MARKDOWN_LIST_COMPACT_INDENT_PT: Int = 4

    /** Ordered list marker column. Source: `NativeMarkdownBody.swift:77`. Confidence: exact. */
    public const val MARKDOWN_ORDERED_MARKER_MIN_WIDTH_PT: Int = 24

    /** Bullet/checkbox marker column. Source: `NativeMarkdownBody.swift:77`. Confidence: exact. */
    public const val MARKDOWN_BULLET_MARKER_MIN_WIDTH_PT: Int = 18

    /** List marker baseline top inset. Source: `NativeMarkdownBody.swift:78`. Confidence: exact. */
    public const val MARKDOWN_MARKER_TOP_INSET_PT: Int = 1

    /** Expanded quote child gap. Source: `NativeMarkdownBody.swift:90`. Confidence: exact. */
    public const val MARKDOWN_QUOTE_CHILD_GAP_PT: Int = 12

    /** Compact quote child gap. Source: `NativeMarkdownBody.swift:90`. Confidence: exact. */
    public const val MARKDOWN_QUOTE_COMPACT_CHILD_GAP_PT: Int = 4

    /** Expanded quote leading inset. Source: `NativeMarkdownBody.swift:96`. Confidence: exact. */
    public const val MARKDOWN_QUOTE_INSET_PT: Int = 14

    /** Compact quote leading inset. Source: `NativeMarkdownBody.swift:96`. Confidence: exact. */
    public const val MARKDOWN_QUOTE_COMPACT_INSET_PT: Int = 8

    /** Quote vertical bar width. Source: `NativeMarkdownBody.swift:98`. Confidence: exact. */
    public const val MARKDOWN_QUOTE_BAR_WIDTH_PT: Int = 2

    /** Regular table cell horizontal inset. Source: `NativeMarkdownBody.swift:219`. Confidence: exact. */
    public const val MARKDOWN_TABLE_CELL_INSET_H_PT: Int = 16

    /** Regular table cell vertical inset. Source: `NativeMarkdownBody.swift:220`. Confidence: exact. */
    public const val MARKDOWN_TABLE_CELL_INSET_V_PT: Int = 10

    /** Compact table cell horizontal inset. Source: `NativeMarkdownBody.swift:219`. Confidence: exact. */
    public const val MARKDOWN_TABLE_COMPACT_CELL_INSET_H_PT: Int = 8

    /** Compact table cell vertical inset. Source: `NativeMarkdownBody.swift:220`. Confidence: exact. */
    public const val MARKDOWN_TABLE_COMPACT_CELL_INSET_V_PT: Int = 4

    /** Table grid/card minimum column width. Source: `NativeMarkdownBody.swift:218`. Confidence: exact. */
    public const val MARKDOWN_TABLE_COLUMN_MIN_WIDTH_PT: Int = 100

    /** Table grid/card maximum column width. Source: `NativeMarkdownBody.swift:218`. Confidence: exact. */
    public const val MARKDOWN_TABLE_COLUMN_MAX_WIDTH_PT: Int = 320

    /** Table card row stack gap. Source: `NativeMarkdownBody.swift:165`. Confidence: exact. */
    public const val MARKDOWN_TABLE_CARD_GAP_PT: Int = 8

    /** Table card field stack gap. Source: `NativeMarkdownBody.swift:167`. Confidence: exact. */
    public const val MARKDOWN_TABLE_FIELD_GAP_PT: Int = 10

    /** Table card field label/value gap. Source: `NativeMarkdownBody.swift:169`. Confidence: exact. */
    public const val MARKDOWN_TABLE_LABEL_VALUE_GAP_PT: Int = 2

    /** Table card content inset. Source: `NativeMarkdownBody.swift:184`. Confidence: exact. */
    public const val MARKDOWN_TABLE_CARD_INSET_PT: Int = 12

    /** Table card corner radius. Source: `NativeMarkdownBody.swift:187`. Confidence: exact. */
    public const val MARKDOWN_TABLE_CARD_RADIUS_PT: Int = 12

    /** Markdown H1 size. Source: `NativeMarkdownBody.swift:123`. Confidence: exact. */
    public const val MARKDOWN_H1_SIZE_PT: Int = 24

    /** Markdown H2 size. Source: `NativeMarkdownBody.swift:124`. Confidence: exact. */
    public const val MARKDOWN_H2_SIZE_PT: Int = 22

    /** Markdown H3 size. Source: `NativeMarkdownBody.swift:125`. Confidence: exact. */
    public const val MARKDOWN_H3_SIZE_PT: Int = 20

    /** Markdown H4 size. Source: `NativeMarkdownBody.swift:126`. Confidence: exact. */
    public const val MARKDOWN_H4_SIZE_PT: Int = 17

    /** Markdown footnote size. Source: `NativeMarkdownBody.swift:292`. Confidence: exact. */
    public const val MARKDOWN_FOOTNOTE_SIZE_PT: Int = 9

    /** Markdown footnote baseline offset. Source: `NativeMarkdownBody.swift:292`. Confidence: exact. */
    public const val MARKDOWN_FOOTNOTE_BASELINE_OFFSET_PT: Int = 6

    /** Regular thematic-rule vertical inset. Source: `NativeMarkdownBody.swift:116`. Confidence: exact. */
    public const val MARKDOWN_RULE_INSET_V_PT: Int = 16

    /** Compact thematic-rule vertical inset. Source: `NativeMarkdownBody.swift:116`. Confidence: exact. */
    public const val MARKDOWN_RULE_COMPACT_INSET_V_PT: Int = 4

    /** Thematic-rule thickness. Source: `NativeMarkdownBody.swift:115`. Confidence: exact. */
    public const val MARKDOWN_RULE_HEIGHT_PT: Float = 0.5f

    /** Header HStack icon-to-title gap. Source: `NativeChangedFilesCard.swift:18`. Confidence: exact. */
    public const val CHANGED_FILES_HEADER_GAP_PT: Int = 10

    /** File glyph frame. Source: `NativeChangedFilesCard.swift:29`. Confidence: exact. */
    public const val CHANGED_FILES_HEADER_GLYPH_BOX_PT: Int = 40

    /** File-type glyph itself. Source: `NativeChangedFilesCard.swift:25-26`. Confidence: exact. */
    public const val CHANGED_FILES_HEADER_GLYPH_SIZE_PT: Int = 20

    /** File-glyph tile corner radius. Source: `NativeChangedFilesCard.swift:20,22`. Confidence: exact. */
    public const val CHANGED_FILES_HEADER_GLYPH_RADIUS_PT: Int = 10

    /** Header title/summary vertical gap. Source: `NativeChangedFilesCard.swift:30`. Confidence: exact. */
    public const val CHANGED_FILES_TITLE_STACK_GAP_PT: Int = 2

    /** Changed-files header title size. Source: `NativeChangedFilesCard.swift:33`. Confidence: exact. */
    public const val CHANGED_FILES_TITLE_SIZE_PT: Int = 13

    /** Changed-files header title weight (`.medium`). Source: `NativeChangedFilesCard.swift:33`. Confidence: exact. */
    public const val CHANGED_FILES_TITLE_WEIGHT: Int = 500

    /** Changed-files header count size. Source: `NativeChangedFilesCard.swift:40`. Confidence: exact. */
    public const val CHANGED_FILES_HEADER_COUNT_SIZE_PT: Int = 10

    /** Added/deleted count gap. Source: `NativeChangedFilesCard.swift:36`. Confidence: exact. */
    public const val CHANGED_FILES_DIFF_COUNT_GAP_PT: Int = 6

    /** Header internal padding. Source: `NativeChangedFilesCard.swift:44`. Confidence: exact. */
    public const val CHANGED_FILES_HEADER_INSET_PT: Int = 10

    /** Header row height. Source: `NativeChangedFilesCard.swift:45`. Confidence: exact. */
    public const val CHANGED_FILES_HEADER_HEIGHT_PT: Int = 60

    /** File row text/count gap. Source: `NativeChangedFilesCard.swift:55,62`. Confidence: exact. */
    public const val CHANGED_FILES_ROW_GAP_PT: Int = 10

    /** File path size. Source: `NativeChangedFilesCard.swift:57`. Confidence: exact. */
    public const val CHANGED_FILES_ROW_PATH_SIZE_PT: Int = 12

    /** Added/deleted row counter size. Source: `NativeChangedFilesCard.swift:66`. Confidence: exact. */
    public const val CHANGED_FILES_ROW_COUNT_SIZE_PT: Int = 11

    /** File row horizontal inset. Source: `NativeChangedFilesCard.swift:68`. Confidence: exact. */
    public const val CHANGED_FILES_ROW_INSET_H_PT: Int = 14

    /** File row vertical inset. Source: `NativeChangedFilesCard.swift:69`. Confidence: exact. */
    public const val CHANGED_FILES_ROW_INSET_V_PT: Int = 7

    /** File/toggle interactive minimum row height. Source: `NativeChangedFilesCard.swift:70,86`. Confidence: exact. */
    public const val CHANGED_FILES_ROW_MIN_HEIGHT_PT: Int = 44

    /** Expand/collapse row content gap. Source: `NativeChangedFilesCard.swift:77`. Confidence: exact. */
    public const val CHANGED_FILES_TOGGLE_GAP_PT: Int = 4

    /** Expand/collapse label size. Source: `NativeChangedFilesCard.swift:82`. Confidence: exact. */
    public const val CHANGED_FILES_TOGGLE_SIZE_PT: Int = 12

    /** Expand/collapse chevron glyph size. Source: `NativeChangedFilesCard.swift:79`. Confidence: exact. */
    public const val CHANGED_FILES_TOGGLE_CHEVRON_SIZE_PT: Int = 14

    /** Expand/collapse row horizontal inset. Source: `NativeChangedFilesCard.swift:84`. Confidence: exact. */
    public const val CHANGED_FILES_TOGGLE_INSET_H_PT: Int = 14

    /** Expand/collapse row vertical inset. Source: `NativeChangedFilesCard.swift:85`. Confidence: exact. */
    public const val CHANGED_FILES_TOGGLE_INSET_V_PT: Int = 10

    // ------------------------------------------------------------ dp accessors

    /** [HEADER_HEIGHT_PT] as a Compose length. */
    public val headerHeight: Dp get() = HEADER_HEIGHT_PT.dp

    /** [HEADER_HORIZONTAL_INSET_PT] as a Compose length. */
    public val headerHorizontalInset: Dp get() = HEADER_HORIZONTAL_INSET_PT.dp

    /** [TRANSCRIPT_SIDE_INSET_PT] as a Compose length. */
    public val transcriptSideInset: Dp get() = TRANSCRIPT_SIDE_INSET_PT.dp

    /** [FLOW_GAP_PT] as a Compose length. */
    public val flowGap: Dp get() = FLOW_GAP_PT.dp

    /** [RESPONSE_GAP_PT] as a Compose length. */
    public val responseGap: Dp get() = RESPONSE_GAP_PT.dp

    /** [TURN_GAP_PT] as a Compose length. */
    public val turnGap: Dp get() = TURN_GAP_PT.dp

    /** [DISCLOSURE_ROW_HEIGHT_PT] as a Compose length. */
    public val disclosureRowHeight: Dp get() = DISCLOSURE_ROW_HEIGHT_PT.dp

    /** [COMPOSER_WIDTH_PT] as a Compose length. */
    public val composerWidth: Dp get() = COMPOSER_WIDTH_PT.dp

    /** [COMPOSER_HEIGHT_PT] as a Compose length. */
    public val composerHeight: Dp get() = COMPOSER_HEIGHT_PT.dp

    /** [COMPOSER_RADIUS_PT] as a Compose length. */
    public val composerRadius: Dp get() = COMPOSER_RADIUS_PT.dp

    /** [SEND_DIAMETER_PT] as a Compose length. */
    public val sendDiameter: Dp get() = SEND_DIAMETER_PT.dp

    /** [PERMISSION_CARD_RADIUS_PT] as a Compose length. */
    public val permissionCardRadius: Dp get() = PERMISSION_CARD_RADIUS_PT.dp
}

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
import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * Chat page geometry: header, transcript, bubble, composer and the cards that
 * hang off the composer.
 *
 * [UiMetrics] owns only the capture frame; this object owns the Chat page's
 * per-surface numbers. Constants whose value is a `tokens.json` leaf now read
 * the generated `UiTokenData` table instead of re-typing the number, so the
 * token contract stays the single source of truth.
 */
public object ChatMetrics {
    /** No additional inset; iOS ChatPage.spacing uses zero for the first row. Page-local: one page/surface layout value; no token fit. */
    public const val NO_GAP_PT: Int = 0

    // ------------------------------------------------------ About identity row

    /** About page brand logo. Source: `NativeShell.swift:1056` (`.frame(width: 64, height: 64)`) Confidence: exact. */
    public const val ABOUT_BRANDING_LOGO_SIZE_PT: Int = 64
    /** About page branding stack gap. Source: `NativeShell.swift:1052` (`VStack(spacing: 8)`) Confidence: exact. */
    public const val ABOUT_BRANDING_STACK_GAP_PT: Int = 8
    /** About page branding row vertical padding. Source: `NativeShell.swift:1065` (`.padding(.vertical, 12)`) Confidence: exact. */
    public const val ABOUT_BRANDING_ROW_PADDING_V_PT: Int = 12

    // ------------------------------------------------------------------ header

    /** PR22 floating nav row height. Source: `HomeSpec.navButton = 44`, `.nav { height: 44 }`. Confidence: exact. */
    public val HEADER_HEIGHT_PT: Int get() = UiTokenData.geometryNavButton.value.toInt()

    /** PR22 nav horizontal inset. Source: `HomeSpec.chromeInset = 16`. Confidence: exact. */
    public val HEADER_HORIZONTAL_INSET_PT: Int get() = UiTokenData.geometryChromeInset.value.toInt()

    /** More SF Symbol size and weight are represented by the bold registry vector. Source: `HeaderActionPill.swift:59` (ellipsis glyph is 18 pt) Confidence: exact. */
    public const val CHAT_HEADER_MORE_ICON_PT: Int = 18
    /** Vertical text gap in system-event message rows. Source: `NativeMessageRows.swift:128` (`VStack(alignment: .leading, spacing: 2)`) Confidence: exact. */
    public const val SYSTEM_EVENT_TEXT_GAP_PT: Int = 2

    // -------------------------------------------------------------- transcript

    /** PR22 content column at 430 pt: `430 - 2 x 20`. Source: `HomeSpec.contentInset`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val CONTENT_COLUMN_WIDTH_PT: Int = 390

    /** PR22 transcript side inset. Source: `HomeSpec.contentInset = 20`, `ChatPage.swift:1385` (`.padding(.horizontal, HomeSpec.contentInset)`) Confidence: exact. */
    public val TRANSCRIPT_SIDE_INSET_PT: Int get() = UiTokenData.geometryContentInset.value.toInt()

    /** Clearance for the floating latest-message control. Source: `ChatPage.swift:1389` (`.padding(.bottom, 48)`) Confidence: exact. */
    public const val TRANSCRIPT_LATEST_CLEARANCE_PT: Int = 48
    /** Failed-message row inline gap. Source: `ChatPage.swift:1045` (`HStack(alignment: .firstTextBaseline, spacing: 6)`) Confidence: exact. */
    public const val FAILURE_LINE_GAP_PT: Int = 6
    /** Failed-message row top gap. Source: `ChatPage.swift:1066` (`.padding(.top, 6)`) Confidence: exact. */
    public const val FAILURE_LINE_TOP_PT: Int = 6
    /** Failure banner body and action font size. Source: `ChatPage.swift:1051,1062,1176,1181,1189` (failure-line and banner fonts are 13 pt) Confidence: exact. */
    public val FAILURE_TEXT_SIZE_PT: Int get() = UiTokenData.typeSecondary.baseSize.toInt()
    /** Top error banner inline gap. Source: `ChatPage.swift:1174` (`HStack(alignment: .firstTextBaseline, spacing: 12)`) Confidence: exact. */
    public val FAILURE_BANNER_GAP_PT: Int get() = UiTokenData.geometryBannerGap.value.toInt()
    /** Top error banner horizontal inset. Source: `ChatPage.swift:1196` (`.padding(.horizontal, 4)`) Confidence: exact. */
    public val FAILURE_BANNER_INSET_H_PT: Int get() = UiTokenData.geometryBannerInsetH.value.toInt()
    /** Top error banner vertical inset. Source: `ChatPage.swift:1197` (`.padding(.vertical, 6)`) Confidence: exact. */
    public val FAILURE_BANNER_INSET_V_PT: Int get() = UiTokenData.geometryBannerInsetV.value.toInt()

    /** Block gap between transcript blocks. Source: `HomeSpec.blockGap = 20`. Confidence: exact. */
    public val FLOW_GAP_PT: Int get() = UiTokenData.spacingBlockGap.value.toInt()

    /** Gap after a response row. Source: `HomeSpec.blockGap = 20`. Confidence: exact. */
    public val RESPONSE_GAP_PT: Int get() = UiTokenData.spacingBlockGap.value.toInt()

    /** Gap after a turn-process control row. Source: `HomeSpec.blockGap = 20`. Confidence: exact. */
    public val TURN_GAP_PT: Int get() = UiTokenData.spacingBlockGap.value.toInt()

    /** Paragraph gap after a user bubble / between paragraphs. Source: `HomeSpec.paragraphGap = 16`. Confidence: exact. */
    public val PARAGRAPH_GAP_PT: Int get() = UiTokenData.spacingParagraphGap.value.toInt()

    /** Process row -> its opened card. Source: `HomeSpec.disclosureGap = 8`. Confidence: exact. */
    public val DISCLOSURE_GAP_PT: Int get() = UiTokenData.spacingDisclosureGap.value.toInt()

    /** Collapsed process row. Source: `HomeSpec.processRowHeight = 24`. Confidence: exact. */
    public val DISCLOSURE_ROW_HEIGHT_PT: Int get() = UiTokenData.geometryProcessRowHeight.value.toInt()

    /** Process row leading icon box. Source: `HomeSpec.processIcon = 18`. Confidence: exact. */
    public val DISCLOSURE_ICON_PT: Int get() = UiTokenData.geometryProcessIcon.value.toInt()

    /** Icon-to-title gap. Source: design spec (`间隔 6`). Confidence: exact. */
    public val DISCLOSURE_ICON_GAP_PT: Int get() = UiTokenData.geometryDisclosureIconGap.value.toInt()

    /** List disclosure artwork box. Source: `NativeMessageRows.swift:38-39` (in-list glyph box is 16 pt) Confidence: exact. */
    public const val DISCLOSURE_LIST_ICON_BOX_PT: Int = 16
    /** List disclosure category artwork. Source: `NativeMessageRows.swift:36` (in-list glyph is 14 pt) Confidence: exact. */
    public const val DISCLOSURE_LIST_CATEGORY_ICON_PT: Int = 14
    /** List disclosure artwork-to-title gap. Source: `NativeMessageRows.swift:40` (`.padding(.trailing, inListCard ? 8 : 6)`) Confidence: exact. */
    public const val DISCLOSURE_LIST_ICON_GAP_PT: Int = 8

    /** Compact Markdown block gap. Source: `NativeMarkdownBody.swift` variant blockSpacing. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val MARKDOWN_COMPACT_BLOCK_SPACING_PT: Int = 4
    /** Compact Markdown list stack gap. Source: `NativeMarkdownBody.swift` list spacing. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val MARKDOWN_COMPACT_LIST_STACK_SPACING_PT: Int = 2
    /** Compact Markdown marker-to-text gap. Source: `NativeMarkdownBody.swift` list HStack. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val MARKDOWN_COMPACT_LIST_ITEM_GAP_PT: Int = 8
    /** Compact inline-code font. Source: `NativeMarkdownBody.swift:320` (compact inline code is 13 pt) Confidence: exact. */
    public const val MARKDOWN_COMPACT_INLINE_CODE_SIZE_PT: Int = 13
    /** Normal inline code uses the chosen code font size plus one. Source: `NativeMarkdownBody.swift:320` (`fontSize(for: .code) + 1`) Confidence: exact. */
    public const val MARKDOWN_INLINE_CODE_SIZE_OFFSET_PT: Int = 1

    /** Closed-turn process control row height. PR22 uses the 24 pt process row. Source: `HomeSpec.processRowHeight`. Confidence: exact. */
    public val TURN_PROCESS_HEIGHT_PT: Int get() = UiTokenData.geometryProcessRowHeight.value.toInt()

    // --------------------------------------------------------------- user bubble

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

    /** Assistant list spacing. Source: `NativeChatTheme.swift:49` (`messageListSpacing: CGFloat = 10`) Confidence: exact. */
    public const val MESSAGE_LIST_SPACING_PT: Int = 10

    /** NativeComposerStats.swift: compact/detailed row both pad top by2, including empty detailed row. Page-local: one page/surface layout value; no token fit. */
    public const val COMPOSER_STATS_TOP_PT: Int = 2

    // ----------------------------------------------------------------- composer

    /** Open composer width at 430 pt: `430 - 2 x 16`. Source: `HomeSpec.chromeInset`, design spec `左右边距 16, 宽 398`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val COMPOSER_WIDTH_PT: Int = 398

    /** Open composer minimum; intrinsic text/control content may be taller. Source: `HomeSpec.composerOpenMinHeight`. Confidence: exact. */
    public val COMPOSER_HEIGHT_PT: Int get() = UiTokenData.geometryComposerOpenMinHeight.value.toInt()

    /** Closed composer height. Source: design spec `.composer.closed { height: 56 }`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val COMPOSER_CLOSED_HEIGHT_PT: Int = 56

    /** Open composer corner radius. Source: `HomeSpec.composerOpenRadius = 24`. Confidence: exact. */
    public val COMPOSER_RADIUS_PT: Int get() = UiTokenData.radiusComposerOpen.value.toInt()

    /**
     * Composer outer bottom inset, now **0**.
     *
     * Source: `ChatPage.swift:2352` (`.padding(.bottom, 0)`) Confidence: exact.
     */
    public val COMPOSER_OUTER_MARGIN_BOTTOM_PT: Int get() = UiTokenData.geometryComposerOuterMarginBottom.value.toInt()

    /** Input port leading inset. Source: `ChatPage.swift:2409` (`.padding(.leading, 11)`) Confidence: exact. */
    public val COMPOSER_PORT_LEADING_PT: Int get() = UiTokenData.geometryComposerPortLeading.value.toInt()

    /** Input port trailing inset (the send column is outside it). Source: `ChatPage.swift:2410` (`.padding(.trailing, 8)`) Confidence: exact. */
    public val COMPOSER_PORT_TRAILING_PT: Int get() = UiTokenData.geometryComposerPortTrailing.value.toInt()

    /** Control row height. Source: `ChatPage.swift:2425` (`.frame(height: 44)`) Confidence: exact. */
    public val COMPOSER_CONTROL_ROW_HEIGHT_PT: Int get() = UiTokenData.geometryComposerControlHeight.value.toInt()

    /** Control row leading inset. Source: `ChatPage.swift:2423` (`.padding(.leading, 8)`) Confidence: exact. */
    public const val COMPOSER_CONTROL_LEADING_PT: Int = 8

    /** Control row bottom padding. Source: `ChatPage.swift:2427` (`.padding(.bottom, 4)`) Confidence: exact. */
    public val COMPOSER_CONTROL_BOTTOM_PT: Int get() = UiTokenData.geometryComposerControlBottom.value.toInt()

    /** Send/stop circle diameter. Source: `HomeSpec.sendButton = 36`. Confidence: exact. */
    public val SEND_DIAMETER_PT: Int get() = UiTokenData.geometrySendButton.value.toInt()

    /** Android touch frame; paint stays at the source 36pt diameter, trailing-aligned to preserve its 8pt visual gaps. Confidence: platform adaptation. Android-only: Android touch frame (44dp) around the 36pt iOS paint; no §5 id covers touch-target size — platform adaptation, keep local. */
    public const val SEND_HIT_PT: Int = 44

    /** "回到最新" pill horizontal padding. Source: `ChatPage.swift:1501` (`.padding(.horizontal, 12)`) Confidence: exact. */
    public const val BACK_TO_LATEST_PADDING_H_PT: Int = 12

    /** "回到最新" pill vertical padding. Source: `ChatPage.swift:1502` (`.padding(.vertical, 8)`) Confidence: exact. */
    public const val BACK_TO_LATEST_PADDING_V_PT: Int = 8

    /** "回到最新" pill bottom inset and separator stroke. Source: `ChatPage.swift:1509` (`.padding(.bottom, 12)`) Confidence: exact. */
    public const val BACK_TO_LATEST_BOTTOM_PT: Int = 12
    /** Page-local: one page/surface layout value; no token fit. */
    public const val BACK_TO_LATEST_BORDER_PT: Int = 1

    /** Default Large Caption 1 label size. Source: Apple HIG Caption 1; `ChatPage.swift:1499` (`.font(.caption.weight(.semibold))`) Confidence: exact. */
    public const val BACK_TO_LATEST_LABEL_PT: Int = 12
    /** Default Large Caption 1 line height. Source: Apple HIG Typography, “Text styles”. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val BACK_TO_LATEST_LABEL_LINE_HEIGHT_PT: Int = 16

    /** "回到最新" pill corner radius. Source: `ChatPage.swift:1505-1506` (`cornerRadius: 12`) Confidence: exact. */
    public const val BACK_TO_LATEST_RADIUS_PT: Int = 12

    // -------------------------------------------------------------------- queue

    /** Queued-message row corner radius. Source: `ChatPage.swift:2189` (the pending queue row keeps the 8 pt radius; durable rows inherit the dock r12 at line 2042) Confidence: exact. */
    public const val QUEUE_ROW_RADIUS_PT: Int = 8

    // ------------------------------------------------------------------- cards

    /** Permission card corner radius. Source: `ChatPage.swift:5263` (`cornerRadius: 12`) Confidence: exact. */
    public val PERMISSION_CARD_RADIUS_PT: Int get() = UiTokenData.radiusCard.value.toInt()

    /** Permission card inner padding. Source: `ChatPage.swift:5261` (`.padding(14)`) Confidence: exact. */
    public val PERMISSION_CARD_PADDING_PT: Int get() = UiTokenData.geometryCardPadding.value.toInt()

    /** Permission card row spacing. Source: `ChatPage.swift:5210` (`VStack(alignment: .leading, spacing: 10)`) Confidence: exact. */
    public val PERMISSION_CARD_SPACING_PT: Int get() = UiTokenData.geometryApprovalCardSpacing.value.toInt()

    /** Permission card outer margin. Source: `ChatPage.swift:5264` (`.padding(.horizontal, 16)`) Confidence: exact. */
    public val PERMISSION_CARD_OUTER_MARGIN_H_PT: Int get() = UiTokenData.geometryCardOuterMarginH.value.toInt()

    /** Permission card outer vertical margin. Source: `ChatPage.swift:5265` (`.padding(.vertical, 8)`) Confidence: exact. */
    public val PERMISSION_CARD_OUTER_MARGIN_V_PT: Int get() = UiTokenData.geometryCardOuterMarginV.value.toInt()

    /** Allow-once button height. Source: `ChatPage.swift:5243` (`.frame(height: 48)`) Confidence: exact. */
    public val PERMISSION_PRIMARY_HEIGHT_PT: Int get() = UiTokenData.geometryPrimaryButtonHeight.value.toInt()

    /** Allow-once button radius. Source: `ChatPage.swift:5244` (`cornerRadius: 12`) Confidence: exact. */
    public val PERMISSION_PRIMARY_RADIUS_PT: Int get() = UiTokenData.radiusCard.value.toInt()

    /** Deny button height (the 44 pt hit minimum). Source: `ChatPage.swift:5256` (`.frame(height: 44)`) Confidence: exact. */
    public val PERMISSION_DENY_HEIGHT_PT: Int get() = UiTokenData.geometrySecondaryButtonHeight.value.toInt()

    /** Single-choice marker outer diameter in the current Android question fallback; source is the 20pt question marker in the PR22 reference capture. Confidence: image-measured. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_RADIO_OUTLINE_PT: Int = 20
    /** Selected radio center in the question fallback. Source: PR22 reference capture. Confidence: image-measured. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_RADIO_DOT_PT: Int = 8
    /** Multi-select checkbox frame. Source: `NativeQuestionComposer.swift:697` (`.frame(width: 20, height: 20)`) Confidence: exact. */
    public const val QUESTION_CHECKBOX_FRAME_PT: Int = 20
    /** Multi-select checkbox corner radius. Source: `NativeParityTokens.swift:111` (`radiusXS: CGFloat = 4`) Confidence: exact. */
    public const val QUESTION_CHECKBOX_RADIUS_PT: Int = 4
    /** Multi-select check glyph. Source: `NativeQuestionComposer.swift:691`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_CHECKBOX_GLYPH_PT: Int = 14
    /** Legacy question-answer add icon. Source: PR22 reference capture. Confidence: image-measured. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_ANSWER_ADD_ICON_PT: Int = 16
    /** Question pager chevron drawing. Source: `NativeQuestionComposer.swift:723-724`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_PAGER_ICON_PT: Int = 13
    /** Question header action glyph. Source: `NativeQuestionComposer.swift:723-724`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_HEADER_ACTION_GLYPH_PT: Int = 13
    /** Plan-review change glyph. Source: `NativePlanReviewCard.swift:125` (chevron glyph is 14 pt) Confidence: exact. */
    public const val PLAN_REVIEW_CHANGE_GLYPH_PT: Int = 14
    /** Goal clear glyph. Source: `ChatPage.swift:1874` (`.font(.system(size: 11, weight: .semibold))`) Confidence: exact. */
    public const val GOAL_CLEAR_GLYPH_PT: Int = 11
    /** Todo dock leading checklist glyph. Source: `NativeTodoDock.swift:118` (`.frame(width: 14, height: 14)`) Confidence: exact. */
    public const val TODO_DOCK_GLYPH_PT: Int = 14
    /** Todo dock disclosure chevron. Source: `NativeTodoDock.swift:130`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val TODO_DOCK_CHEVRON_PT: Int = 14
    /** Pending attachment document glyph box. Source: PR22 reference capture. Confidence: image-measured. Page-local: one page/surface layout value; no token fit. */
    public const val ATTACHMENT_DOCUMENT_GLYPH_PT: Int = 16
    /** Pending attachment remove glyph box. Source: PR22 reference capture. Confidence: image-measured. Page-local: one page/surface layout value; no token fit. */
    public const val ATTACHMENT_REMOVE_GLYPH_PT: Int = 14
    /** Space between the access-mode shield and disclosure. Source: `ChatPage.swift` accessModeMenu. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val ACCESS_MODE_ICON_GAP_PT: Int = 2
    /** Access-mode shield glyph. Source: `ChatPage.swift:2676` (`NativeChatIcon(name: .shield, size: 20)`) Confidence: exact. */
    public const val ACCESS_MODE_SHIELD_GLYPH_PT: Int = 20
    /** Access-mode disclosure glyph. Source: `ChatPage.swift:2692` (`NativeChatIcon(name: .chevronDown, size: 10)`) Confidence: exact. */
    public const val ACCESS_MODE_CHEVRON_GLYPH_PT: Int = 10
    /** Access-mode failure mark after automatic retries. Source: `ChatPage.swift` accessModeMenu label. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val ACCESS_MODE_ALERT_DOT_PT: Int = 6
    /** Access-mode retry spinner stroke (iOS `ProgressView().controlSize(.mini)`). Source: `ChatPage.swift` accessModeMenu label. Confidence: approximated. Android-only: Compose circular-progress stroke has no iOS `ProgressView` equivalent; §5 has no id — platform-forced approximation. */
    public const val ACCESS_MODE_SPINNER_STROKE_PT: Float = 1.5f
    /** Model name/effort gap. Source: `ChatPage.swift:2793` (`HStack(spacing: 6)`) Confidence: exact. */
    public const val MODEL_EFFORT_GAP_PT: Int = 6
    /** Model-menu disclosure glyph. Source: `ChatPage.swift:2803-2804` (`chevron.down` at 12 pt) Confidence: exact. */
    public const val MODEL_MENU_CHEVRON_GLYPH_PT: Int = 12
    /** Composer menu row check glyph. Source: `ChatPage.swift` model/access menu selection rows. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val COMPOSER_MENU_CHECK_GLYPH_PT: Int = 16

    /** Queue dock header text/icon gap. Source: `ChatPage.swift:2010` (`HStack(spacing: 10)`) Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_GAP_PT: Int = 10
    /** Queue dock leading glyph. Source: `ChatPage.swift:2012` (`.font(.system(size: 14))`) Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_ICON_PT: Int = 14
    /** Queue dock header line height. Source: `ChatPage.swift:2022` (`.frame(height: 32)`) Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_HEIGHT_PT: Int = 32
    /** Queue dock title font size. Source: `ChatPage.swift:2014` (`.font(.system(size: 13, weight: .medium))`) Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_FONT_PT: Int = 13
    /** Queue header disclosure glyph size. Source: `ChatPage.swift:2019` (`.font(.system(size: 12, weight: .semibold))`) Confidence: exact. */
    public const val CHAT_QUEUE_HEADER_CHEVRON_PT: Int = 12
    /** Single-row queue marker glyph size. Source: `ChatPage.swift:2066` (`.font(.system(size: 12))`) Confidence: exact. */
    public const val CHAT_QUEUE_ROW_GLYPH_PT: Int = 12
    /** Queue row title font size. Source: `ChatPage.swift:2071` (`.font(.system(size: 13))`) Confidence: exact. */
    public const val CHAT_QUEUE_ROW_FONT_PT: Int = 13
    /** Queue row action glyph size. Source: `ChatPage.swift:2115` (`.font(.system(size: 13))`) Confidence: exact. */
    public const val CHAT_QUEUE_ACTION_GLYPH_PT: Int = 13
    /** Queue row action painted icon frame. Source: `ChatPage.swift:2117` (`.frame(width: 28, height: 28)`) Confidence: exact. */
    public const val CHAT_QUEUE_ACTION_ICON_BOX_PT: Int = 28
    /** Queue row action hit target width. Source: `ChatPage.swift:2118` (`.frame(width: 34, height: 36)`) Confidence: exact. */
    public const val CHAT_QUEUE_ACTION_TARGET_WIDTH_PT: Int = 34
    /** Queue row action hit target height. Source: `ChatPage.swift:2118` (`.frame(width: 34, height: 36)`) Confidence: exact. */
    public const val CHAT_QUEUE_ACTION_TARGET_HEIGHT_PT: Int = 36
    /** Queue row minimum height. Source: `ChatPage.swift:2107` (`.frame(minHeight: 36)`) Confidence: exact. */
    public const val CHAT_QUEUE_ROW_MIN_HEIGHT_PT: Int = 36
    /** Queue row horizontal inset. Source: `ChatPage.swift:2106` (`.padding(.horizontal, 10)`) Confidence: exact. */
    public const val CHAT_QUEUE_ROW_INSET_H_PT: Int = 10
    /** Queue row content spacing. Source: `ChatPage.swift:2063` (`HStack(spacing: 8)`) Confidence: exact. */
    public const val CHAT_QUEUE_ROW_GAP_PT: Int = 8
    /** Queue dock vertical stack gap. Source: `ChatPage.swift:2005` (`VStack(alignment: .leading, spacing: 4)`) Confidence: exact. */
    public const val CHAT_QUEUE_STACK_GAP_PT: Int = 4
    /** Queue card vertical inset. Source: `ChatPage.swift:2040` (`.padding(.vertical, 2)`) Confidence: exact. */
    public const val CHAT_QUEUE_CARD_INSET_V_PT: Int = 2
    /** Queue divider inset after the leading row glyph. Source: `ChatPage.swift:2035` (`.padding(.leading, showsLeadingGlyph ? 38 : 10)`) Confidence: exact. */
    public const val CHAT_QUEUE_DIVIDER_INSET_PT: Int = 38
    /** Pending-send row stack gap. Source: `ChatPage.swift:2171` (`VStack(alignment: .leading, spacing: 4)`) Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_STACK_GAP_PT: Int = 4
    /** Pending-send row content gap. Source: `ChatPage.swift:2173` (`HStack(spacing: 8)`) Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_CONTENT_GAP_PT: Int = 8
    /** Pending-send row text size. Source: `ChatPage.swift:2177,2180` (`.font(.system(size: 13))`) Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_TEXT_PT: Int = 13
    /** Pending-send row height. Source: `ChatPage.swift:2187` (`.frame(height: 28)`) Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_HEIGHT_PT: Int = 28
    /** Pending-send row horizontal inset. Source: `ChatPage.swift:2186` (`.padding(.horizontal, 10)`) Confidence: exact. */
    public const val CHAT_QUEUE_PENDING_INSET_H_PT: Int = 10
    /** Pending-send spinner size. Source: `ChatPage.swift:2174-2175` (`ProgressView().controlSize(.mini)`) Confidence: inferred. */
    public const val CHAT_QUEUE_PENDING_SPINNER_PT: Int = 12

    /** Code block body padding. Source: `Components.swift:205` (`.padding(12)`) Confidence: exact. */
    public const val CODE_BLOCK_PADDING_PT: Int = 12

    /** Collapsed long-code max height. Source: `Components.swift:207` (`isLong ? 300 : nil`). Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val CODE_BLOCK_COLLAPSED_MAX_HEIGHT_PT: Int = 300

    /** Todo list maximum height. Source: `NativeParityTokens.swift:103`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val TODO_LIST_MAX_HEIGHT_PT: Int = 180

    /** Question composer maximum height. Source: `NativeParityTokens.swift:104`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_MAX_HEIGHT_PT: Int = 520

    /** Subagent menu width. Source: `NativeParityTokens.swift:107`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val SUBAGENT_MENU_WIDTH_PT: Int = 336
    /** Subagent menu height cap. Source: `NativeSubagentCatalogSheet.swift:126` (`min(560, ...)`) Confidence: exact. */
    public const val SUBAGENT_MENU_MAX_HEIGHT_PT: Int = 560
    /** Subagent menu lower bound. Source: `NativeSubagentCatalogSheet.swift:126` (`max(120, ...)`) Confidence: exact. */
    public const val SUBAGENT_MENU_MIN_HEIGHT_PT: Int = 120
    /** The card's top offset in the phone sheet. Source: `ChatPage.swift:561` (`.padding(.top, 20)`) Confidence: exact. */
    public const val SUBAGENT_SHEET_TOP_INSET_PT: Int = 20
    /** Catalog card's content inset. Source: `NativeSubagentCatalogSheet.swift:101` (`.padding(4)`) Confidence: exact. */
    public const val SUBAGENT_MENU_CARD_PADDING_PT: Int = 4
    /** Zero gap in the title/secondary label stack. Source: `NativeSubagentCatalogSheet.swift:285` (`VStack(alignment: .leading, spacing: 0)`) Confidence: exact. */
    public const val SUBAGENT_TITLE_STACK_GAP_PT: Int = 0
    /** All-side inset retained by the Android inline notice, with no visual change. Confidence: existing implementation. Page-local: one page/surface layout value; no token fit. */
    public const val SUBAGENT_ERROR_MESSAGE_PADDING_PT: Int = 8
    /** Subagent catalog rows. Source: `NativeSubagentCatalogSheet.swift:247` (`.frame(minHeight: 44, alignment: .center)`) Confidence: exact. */
    public const val SUBAGENT_ROW_MIN_HEIGHT_PT: Int = 44
    /** Catalog row vertical inset. Source: `NativeSubagentCatalogSheet.swift:246` (`.padding(.vertical, 6)`) Confidence: exact. */
    public const val SUBAGENT_ROW_INSET_V_PT: Int = 6
    /** Subagent catalog row leading inset. Source: `NativeSubagentCatalogSheet.swift:244` (`.padding(.leading, CGFloat(depth - 1) * 19 + 9)`) Confidence: exact. */
    public const val SUBAGENT_ROW_INSET_LEADING_PT: Int = 9
    /** Subagent catalog row trailing inset. Source: `NativeSubagentCatalogSheet.swift:245` (`.padding(.trailing, 7)`) Confidence: exact. */
    public const val SUBAGENT_ROW_INSET_TRAILING_PT: Int = 7
    /** Gap between row's identity, title and action. Source: `NativeSubagentCatalogSheet.swift:237,283` (`HStack(alignment: .top, spacing: 6)`) Confidence: exact. */
    public const val SUBAGENT_ROW_GAP_PT: Int = 6
    /** Running/idle indicator slot. Source: `NativeSubagentCatalogSheet.swift:323` (`.frame(width: 14, height: 17)`) Confidence: exact. */
    public const val SUBAGENT_ACTIVITY_SLOT_PT: Int = 14
    /** Idle activity dot. Source: `NativeSubagentCatalogSheet.swift:313-316`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val SUBAGENT_ACTIVITY_DOT_PT: Int = 6
    /** Catalog title reference size. Source: `NativeSubagentCatalogSheet.swift:287` (`.font(.system(size: 15, weight: ...))`) Confidence: exact. */
    public const val SUBAGENT_TITLE_REF_PT: Int = 15
    /** Catalog secondary-line reference size. Source: `NativeSubagentCatalogSheet.swift:344` (`.font(.system(size: 13))`) Confidence: exact. */
    public const val SUBAGENT_SECONDARY_REF_PT: Int = 13
    /** Secondary-line height. Source: `NativeSubagentCatalogSheet.swift:336,346` (`.frame(height: 15)`) Confidence: exact. */
    public const val SUBAGENT_SECONDARY_HEIGHT_PT: Int = 15
    /** Sheet height budget removed from the device viewport. Source: `ChatPage.swift:555` and `NativeSubagentCatalogSheet.swift:126` (screen height - 120 - 140 = 260) Confidence: exact. */
    public const val SUBAGENT_SHEET_HEIGHT_REDUCTION_PT: Int = 260
    /** Empty-card/content floor. Source: `NativeSubagentCatalogSheet.swift:131` (`max(44, 8 + notice + ... )`) Confidence: exact. */
    public const val SUBAGENT_CARD_MIN_HEIGHT_PT: Int = 44
    /** Card's base content padding in the row-count height estimate. Source: `NativeSubagentCatalogSheet.swift:131` (`8 + notice + CGFloat(visibleRows.count) * 44`) Confidence: exact. */
    public const val SUBAGENT_CARD_BASE_PADDING_PT: Int = 8
    /** Per-row content height estimate for the source card. Source: `NativeSubagentCatalogSheet.swift:131` (`... * 44`) Confidence: exact. */
    public const val SUBAGENT_ROW_CARD_HEIGHT_PT: Int = 44
    /** Always-empty disclosure slot for the flat ChatPage caller. Source: `NativeSubagentCatalogSheet.swift:257-275`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val SUBAGENT_DISCLOSURE_SLOT_PT: Int = 14
    /** Disclosure/activity slot height. Source: `NativeSubagentCatalogSheet.swift:269,323` (`.frame(width: 14, height: 17)`) Confidence: exact. */
    public const val SUBAGENT_DISCLOSURE_HEIGHT_PT: Int = 17
    /** Title line box height. Source: `NativeSubagentCatalogSheet.swift:291` (`.frame(height: 22)`) Confidence: exact. */
    public const val SUBAGENT_TITLE_LINE_HEIGHT_PT: Int = 22
    /** Gap inside the secondary metadata line. Source: `NativeSubagentCatalogSheet.swift:327` (`HStack(spacing: 4)`) Confidence: exact. */
    public const val SUBAGENT_SECONDARY_GAP_PT: Int = 4
    /** Mode chip corner radius. Source: `NativeSubagentCatalogSheet.swift:335`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val SUBAGENT_MODE_CHIP_RADIUS_PT: Int = 4
    /** Mode chip horizontal inset. Source: `NativeSubagentCatalogSheet.swift:335` (`.padding(.horizontal, 4)`) Confidence: exact. */
    public const val SUBAGENT_MODE_CHIP_INSET_H_PT: Int = 4
    /** Error notice measured height. Source: `NativeSubagentCatalogSheet.swift:130` (`errorText != nil ? 48 : (isLoading ? 32 : 0)`) Confidence: exact. */
    public const val SUBAGENT_ERROR_ROW_HEIGHT_PT: Int = 48
    /** No notice adds no height. Source: `NativeSubagentCatalogSheet.swift` cardHeight. Page-local: one page/surface layout value; no token fit. */
    public const val SUBAGENT_NO_NOTICE_HEIGHT_PT: Int = 0

    // ---------------------------------------------------------------- native header controls

    /** Device entry control width (half the 92 pt pill). Source: `HomeSpec.navPillWidth`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val CHAT_DEVICE_ENTRY_WIDTH_PT: Int = 46
    /** Gap inside the device/menu group. Source: design spec (two 46 pt halves, no gap). Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val CHAT_HEADER_GROUP_GAP_PT: Int = 0
    /** Two-stroke drawer artwork box. Source: `HomeSpec.swift:67` (`navIcon: CGFloat = 22`) Confidence: exact. */
    public val CHAT_DRAWER_ICON_PT: Int get() = UiTokenData.geometryNavIcon.value.toInt()
    /** Online marker diameter. Source: `NativeDeviceConnectionPage.swift:16-19`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val CHAT_DEVICE_STATUS_DOT_PT: Int = 6
    /** Online marker border. Source: `NativeDeviceConnectionPage.swift:18` (`lineWidth: 1`) Confidence: exact. */
    public const val CHAT_DEVICE_STATUS_BORDER_PT: Int = 1
    /** Online marker top/right offsets in the 36x44 entry. Source: `NativeDeviceConnectionPage.swift:19` (current marker offset is x4/y-2; this constant keeps the old 9 pt inset) Confidence: exact. */
    public const val CHAT_DEVICE_STATUS_INSET_PT: Int = 9
    /** Device radio SF Symbol size. Source: `HeaderActionPill.swift:28` (device glyph is 19 pt) Confidence: exact. */
    public const val CHAT_DEVICE_ICON_SIZE_PT: Int = 19

    /** Empty-state column offset from the transcript viewport top. Source: `ChatPage.swift:1707-1713` (`.padding(.top, 88)`) Confidence: exact. */
    public const val EMPTY_STATE_TOP_PT: Int = 88
    /** Empty-state title size. Source: `ChatPage.swift:1725,1763,1787` (`.font(.system(size: 17.5, weight: .semibold))`) Confidence: exact. */
    public const val EMPTY_STATE_TITLE_SIZE_PT: Float = 17.5f
    /** Empty-state supporting line size. Source: `ChatPage.swift:1728,1766,1790` (`.font(.system(size: 14))`) Confidence: exact. */
    public const val EMPTY_STATE_HINT_SIZE_PT: Int = 14
    /** Empty-state title-to-hint gap. Source: `ChatPage.swift:1730,1768,1792` (`.padding(.top, 8)`) Confidence: exact. */
    public const val EMPTY_STATE_HINT_TOP_PT: Int = 8
    /** Empty-state hint-to-primary-action gap. Source: `ChatPage.swift:1777,1799` (`.padding(.top, 24)`) Confidence: exact. */
    public const val EMPTY_STATE_ACTION_TOP_PT: Int = 24
    /** Empty-state primary action height. Source: `HomeSpec.swift:239` (`.frame(height: 50)`) Confidence: exact. */
    public val EMPTY_STATE_ACTION_HEIGHT_PT: Int get() = UiTokenData.geometryHomePrimaryButtonHeight.value.toInt()
    /** Empty-state primary action label size. Source: `HomeSpec.swift:236` (`.font(.system(size: HomeSpec.bodySize, weight: .semibold))`) Confidence: exact. */
    public val EMPTY_STATE_ACTION_LABEL_SIZE_PT: Float get() = UiTokenData.typeButtonLabel.baseSize

    // ----------------------------------------------------------- question composer

    /** Question takeover's card radius. Source: `NativeParityTokens.swift:115` (`radiusXL: CGFloat = 20`) Confidence: exact. */
    public const val QUESTION_CARD_RADIUS_PT: Int = 20
    /** Bottom breathing room below the question footer. Source: `NativeQuestionComposer.swift:269`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_CARD_BOTTOM_PT: Int = 10
    /** Question header top inset. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_HEADER_TOP_PT: Int = 20
    /** Question header leading inset. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_HEADER_LEADING_PT: Int = 24
    /** Question header trailing inset. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_HEADER_TRAILING_PT: Int = 16
    /** Minimized question header bottom inset. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_HEADER_MINIMIZED_BOTTOM_PT: Int = 14
    /** Gap between question copy and header actions. Source: `NativeQuestionComposer.swift:290`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_HEADER_COPY_ACTION_GAP_PT: Int = 16
    /** Question eyebrow-to-prompt stack gap. Source: `NativeQuestionComposer.swift:291` (`VStack(alignment: .leading, spacing: 5)`) Confidence: exact. */
    public const val QUESTION_HEADER_STACK_GAP_PT: Int = 5
    /** Question eyebrow size. Source: `NativeQuestionComposer.swift:293`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_EYEBROW_SIZE_PT: Int = 11
    /** Question prompt size. Source: `NativeQuestionComposer.swift:299`. Confidence: exact. */
    public val QUESTION_PROMPT_SIZE_PT: Int get() = UiTokenData.typeBody.baseSize.toInt()
    /** Question minimize and close hit-area size. Source: `NativeQuestionComposer.swift:723-724` (current header hit area is 24 pt; this constant keeps the 32 pt target) Confidence: exact. */
    public const val QUESTION_HEADER_ACTION_SIZE_PT: Int = 32
    /** Collapsed question header bottom inset is zero. Source: `NativeQuestionComposer.swift:308`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_HEADER_EXPANDED_BOTTOM_PT: Int = 0
    /** Question choice-list top inset. Source: `NativeQuestionComposer.swift:397`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_OPTIONS_TOP_PT: Int = 12
    /** Question choice-list bottom inset. Source: `NativeQuestionComposer.swift:397`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_OPTIONS_BOTTOM_PT: Int = 4
    /** Question option row vertical inset. Source: `NativeQuestionComposer.swift:433`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_OPTION_PADDING_V_PT: Int = 8
    /** Question option row horizontal inset. Source: `NativeQuestionComposer.swift:433`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_OPTION_PADDING_H_PT: Int = 6
    /** Question option corner radius. Source: `NativeParityTokens.swift:113` (`radiusMD`). Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_OPTION_RADIUS_PT: Int = 12
    /** Question option number/check box diameter. Source: `NativeQuestionComposer.swift:697` (current option marker is 20 pt; this constant keeps the 24 pt PR22 reading) Confidence: exact. */
    public const val QUESTION_OPTION_MARK_SIZE_PT: Int = 24
    /** Question no-options answer field minimum height. Source: `NativeQuestionComposer.swift:366` (`.frame(minHeight: 64, alignment: .topLeading)`) Confidence: exact. */
    public const val QUESTION_FREE_ANSWER_HEIGHT_PT: Int = 64
    /** Question footer top inset. Source: `NativeQuestionComposer.swift:512`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_FOOTER_TOP_PT: Int = 12
    /** Question footer horizontal inset. Source: `NativeQuestionComposer.swift:512`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_FOOTER_INSET_H_PT: Int = 10
    /** Question pager/action gap. Source: `NativeQuestionComposer.swift:489,512`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_FOOTER_GAP_PT: Int = 12
    /** Question pager icon target. Source: `NativeQuestionComposer.swift:515-527` (current pager target is 24 pt; this constant keeps the 28 pt target) Confidence: exact. */
    public const val QUESTION_PAGER_TARGET_PT: Int = 28
    /** Question action button height. Source: `NativeQuestionComposer.swift:747` (`.frame(height: 36)`) Confidence: exact. */
    public const val QUESTION_ACTION_HEIGHT_PT: Int = 36
    /** Question action button corner radius. Source: `NativeParityTokens.swift:113` (`radiusMD: CGFloat = 12`) Confidence: exact. */
    public const val QUESTION_ACTION_RADIUS_PT: Int = 12
    /** Question action horizontal inset. Source: `NativeQuestionComposer.swift:747` (`.padding(.horizontal, 14)`) Confidence: exact. */
    public const val QUESTION_ACTION_PADDING_H_PT: Int = 14
    /** Question option text size. Source: `NativeQuestionComposer.swift:418`. Confidence: exact. */
    public val QUESTION_OPTION_TEXT_SIZE_PT: Int get() = UiTokenData.typeListItem.baseSize.toInt()
    /** Question details horizontal inset. Source: `NativeQuestionComposer.swift:358` (`.padding(.horizontal, 2)`) Confidence: exact. */
    public const val QUESTION_DETAIL_INSET_H_PT: Int = 2
    /** Question detail vertical padding. Source: `NativeQuestionComposer.swift:358` (`.padding(.top, 8).padding(.bottom, 8)`) Confidence: exact. */
    public const val QUESTION_DETAIL_INSET_V_PT: Int = 8
    /** Question answer row vertical inset. Source: `NativeQuestionComposer.swift:365` (`.padding(.vertical, 8)`) Confidence: exact. */
    public const val QUESTION_ANSWER_INSET_V_PT: Int = 8
    /** Question answer row horizontal inset. Source: `NativeQuestionComposer.swift:464`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_ANSWER_INSET_H_PT: Int = 6
    /** Question action text button horizontal inset. Source: `NativeQuestionComposer.swift:747` (current action label inset is 14 pt; this constant keeps 10) Confidence: exact. */
    public const val QUESTION_ACTION_TEXT_INSET_H_PT: Int = 10
    /** Question action text button vertical inset. Source: `NativeQuestionComposer.swift:747` (current action label has no vertical inset; this constant keeps 8) Confidence: exact. */
    public const val QUESTION_ACTION_TEXT_INSET_V_PT: Int = 8
    /** Question option list member minimum. Source: `NativeParityTokens.swift:105` (`questionOptionMinHeight`). Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_OPTION_ROW_HEIGHT_PT: Int = 40
    /** Question card outer shadow approximation. Source: `NativeQuestionComposer.swift:282-283` (current shadows use radius 8/16; this constant keeps the 4 pt approximation) Confidence: approximated. */
    public const val QUESTION_CARD_SHADOW_PT: Int = 4
    /** Question answer body horizontal inset. Source: `NativeQuestionComposer.swift:397`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_BODY_INSET_H_PT: Int = 8
    /** Question footer pager gap. Source: `NativeQuestionComposer.swift:516`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_PAGER_GAP_PT: Int = 6
    /** Question panel interior bottom inset. Source: `NativeQuestionComposer.swift:269`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val QUESTION_PANEL_BOTTOM_PT: Int = 10

    // -------------------------------------------------------------- plan review

    /** Plan-review button height. Source: `NativePlanReviewCard.swift:200-210`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val PLAN_REVIEW_BUTTON_HEIGHT_PT: Int = 36
    /** Plan-review button radius. Source: `NativeParityTokens.swift:113` (`radiusMD: CGFloat = 12`) Confidence: exact. */
    public const val PLAN_REVIEW_BUTTON_RADIUS_PT: Int = 12
    /** Gap between plan-review decision buttons. Source: `NativePlanReviewCard.swift:174`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val PLAN_REVIEW_BUTTON_GAP_PT: Int = 8
    // ---------------------------------------------------------------- goal + todo dock

    /** GoalBar row height. Source: `ChatPage.swift:1880` (`.frame(height: 40)`) Confidence: exact. */
    public const val GOAL_BAR_HEIGHT_PT: Int = 40
    /** GoalBar radius. Source: `ChatPage.swift:1882` (`cornerRadius: 10`) Confidence: exact. */
    public const val GOAL_BAR_RADIUS_PT: Int = 10
    /** GoalBar horizontal inset. Source: `ChatPage.swift:1879` (`.padding(.horizontal, 10)`) Confidence: exact. */
    public const val GOAL_BAR_INSET_H_PT: Int = 10
    /** GoalBar icon size. Source: `ChatPage.swift:1850` (current target glyph is 13 pt) Confidence: exact. */
    public const val GOAL_BAR_ICON_SIZE_PT: Int = 14
    /** GoalBar element gap. Source: `ChatPage.swift:1848` (`HStack(spacing: 8)`) Confidence: exact. */
    public const val GOAL_BAR_GAP_PT: Int = 8
    /** GoalBar phase text size. Source: `ChatPage.swift:1854` (`.font(.system(size: 11))`) Confidence: exact. */
    public const val GOAL_BAR_PHASE_SIZE_PT: Int = 11
    /** GoalBar objective text size. Source: `ChatPage.swift:1857` (`.font(.system(size: 13))`) Confidence: exact. */
    public const val GOAL_BAR_OBJECTIVE_SIZE_PT: Int = 13
    /** GoalBar action text size. Source: `ChatPage.swift:1865,1868` (`.font(.system(size: 12))`) Confidence: exact. */
    public const val GOAL_BAR_ACTION_SIZE_PT: Int = 12
    /** Todo dock horizontal inset. Source: `NativeTodoDock.swift:93`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val TODO_DOCK_INSET_H_PT: Int = 12
    /** Todo dock vertical inset. Source: `NativeTodoDock.swift:94`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val TODO_DOCK_INSET_V_PT: Int = 6
    /** Todo dock/list row gap. Source: `NativeTodoDock.swift:89,166`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val TODO_DOCK_GAP_PT: Int = 8
    /** Todo dock header line box. Source: `NativeTodoDock.swift:138`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val TODO_DOCK_HEADER_LINE_PT: Int = 24
    /** Todo item line box. Source: `NativeTodoDock.swift:196`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val TODO_ROW_HEIGHT_PT: Int = 20
    /** Todo status dot size. Source: `NativeTodoDock.swift:258` (`.frame(width: 6, height: 6)`) Confidence: exact. */
    public const val TODO_STATUS_DOT_PT: Int = 6
    /** Todo card radius. Source: `NativeParityTokens.swift:114` (`radiusLG: CGFloat = 16`) Confidence: exact. */
    public const val TODO_DOCK_RADIUS_PT: Int = 16
    /** Todo line font size. Source: `NativeTodoDock.swift:121,125,190`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val TODO_TEXT_SIZE_PT: Int = 13
    /** Todo panel shadow approximation. Source: `NativeTodoDock.swift:99-100`; Android elevation differs. Confidence: approximated. Android-only: Android elevation approximation of the iOS shadow; §5 has no elevation id — platform-forced. */
    public const val TODO_DOCK_SHADOW_PT: Int = 3
    /** Todo status dot row spacing. Source: `NativeTodoDock.swift:186-196`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val TODO_STATUS_GAP_PT: Int = 10
    // Native component metrics required by the scoped C/D/F consumers.

    /** Category artwork inside the process icon box. Source: `NativeMessageRows.swift:36` (in-list glyph is 16 pt) Confidence: exact. */
    public const val DISCLOSURE_CATEGORY_ICON_PT: Int = 16

    /** Expanded disclosure chevron artwork. Source: `NativeMessageRows.swift:35` (chevron glyph is 14 pt) Confidence: exact. */
    public const val DISCLOSURE_CHEVRON_ICON_PT: Int = 14

    /** Actual editable text-view floor inside the port. Source: `ChatPage.swift:2405` (`.frame(height: max(56, composerHeight))`) Confidence: exact. */
    public const val COMPOSER_TEXT_MIN_HEIGHT_PT: Int = 56

    /** Placeholder leading inset inside the port. Source: `ChatPage.swift:2388` (`.padding(.leading, 5)`) Confidence: exact. */
    public const val COMPOSER_PLACEHOLDER_LEADING_PT: Int = 5

    /** Placeholder top inset inside the port. Source: `ChatPage.swift:2389` (`.padding(.top, 8)`) Confidence: exact. */
    public const val COMPOSER_PLACEHOLDER_TOP_PT: Int = 8

    /** Control row trailing inset. Source: `ChatPage.swift:2424` (`.padding(.trailing, 8)`) Confidence: exact. */
    public const val COMPOSER_CONTROL_TRAILING_PT: Int = 8

    /** Plus/access target minimum width. Source: `ChatPage.swift:2555` (`.frame(minWidth: 40)`) Confidence: exact. */
    public const val COMPOSER_CONTROL_MIN_WIDTH_PT: Int = 40

    /** Flexible separation before the model. Source: `ChatPage.swift:2562` (`Spacer(minLength: 8)`) Confidence: exact. */
    public const val COMPOSER_MODEL_MIN_GAP_PT: Int = 8

    /**
     * Action group leading inset and stop/send spacing. Source: `ChatPage.swift:2567`
     * (`HStack(spacing: 8)`) and `:2571` (`.padding(.leading, 8)`). Confidence: exact.
     * Consumed by `ComposerSendRule.STOP_SEND_GAP` (interaction §5 rule 1); page-local until
     * the contract adds a `composerSend` gap token.
     */
    public const val COMPOSER_ACTION_GAP_PT: Int = 8

    /** Send arrow font size inside its circle. Source: `ChatPage.swift:2485` (`.font(.system(size: 15, weight: .bold))`) Confidence: exact. */
    public const val SEND_GLYPH_PT: Int = 15

    /** Stop artwork square edge. Source: `ChatPage.swift:2518` (`.frame(width: 12, height: 12)`) Confidence: exact. */
    public const val STOP_GLYPH_PT: Int = 12

    /** Stop artwork corner radius. Source: `ChatPage.swift:2516` (`cornerRadius: 3`) Confidence: exact. */
    public const val STOP_GLYPH_RADIUS_PT: Int = 3

    /** Source text font applied by `NativeCodeHighlighter.attributed` in DSSCodeBlock. Source: `NativeCodeHighlighter.swift:49` (`.system(size: 13, design: .monospaced)`) Confidence: exact. */
    public const val CODE_BLOCK_SOURCE_FONT_SIZE_PT: Int = 13

    /** Gap between code-language label and controls. Source: `Components.swift:164`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val CODE_BLOCK_HEADER_GAP_PT: Int = 8

    /** Code toolbar horizontal inset. Source: `Components.swift:195`. Confidence: exact. */
    public val CODE_BLOCK_HEADER_INSET_H_PT: Int get() = UiTokenData.spacingCodeToolbar.value.toInt()

    /** Wrap artwork inside the 28pt control. Source: `Components.swift:172-173`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val CODE_BLOCK_WRAP_ICON_SIZE_PT: Int = 11

    /** Copy/check artwork size. Source: `Components.swift:186`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val CODE_BLOCK_COPY_ICON_SIZE_PT: Int = 13

    /** Copy/wrap control square size. Source: `Components.swift:173,189`. Confidence: exact. */
    public val CODE_BLOCK_CONTROL_SIZE_PT: Int get() = UiTokenData.spacingCodeWrapButton.value.toInt()

    /** NativeMarkdownBody block gap, separate from HomeSpec transcript blockGap. Source: `NativeChatTheme.swift:48` (`messageParagraphSpacing: CGFloat = 20`) Confidence: exact. */
    public const val MARKDOWN_BLOCK_SPACING_PT: Int = 20

    /** Expanded list indentation. Source: `NativeMarkdownBody.swift:90` (`.padding(.leading, variant == .compact ? 4 : 8)`) Confidence: exact. */
    public const val MARKDOWN_LIST_INDENT_PT: Int = 8

    /** Compact list indentation. Source: `NativeMarkdownBody.swift:90` (`.padding(.leading, variant == .compact ? 4 : 8)`) Confidence: exact. */
    public const val MARKDOWN_LIST_COMPACT_INDENT_PT: Int = 4

    /** Ordered list marker column. Source: `NativeMarkdownBody.swift:79` (`minWidth: ordered ? 24 : 18`) Confidence: exact. */
    public const val MARKDOWN_ORDERED_MARKER_MIN_WIDTH_PT: Int = 24

    /** Bullet/checkbox marker column. Source: `NativeMarkdownBody.swift:79` (`minWidth: ordered ? 24 : 18`) Confidence: exact. */
    public const val MARKDOWN_BULLET_MARKER_MIN_WIDTH_PT: Int = 18

    /** List marker baseline top inset. Source: `NativeMarkdownBody.swift:80` (`.padding(.top, 1)`) Confidence: exact. */
    public const val MARKDOWN_MARKER_TOP_INSET_PT: Int = 1

    /** Expanded quote child gap. Source: `NativeMarkdownBody.swift:92` (`spacing: variant == .compact ? 4 : 12`) Confidence: exact. */
    public const val MARKDOWN_QUOTE_CHILD_GAP_PT: Int = 12

    /** Compact quote child gap. Source: `NativeMarkdownBody.swift:92` (`spacing: variant == .compact ? 4 : 12`) Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val MARKDOWN_QUOTE_COMPACT_CHILD_GAP_PT: Int = 4

    /** Expanded quote leading inset. Source: `NativeMarkdownBody.swift:98` (`.padding(.leading, variant == .compact ? 8 : 14)`) Confidence: exact. */
    public const val MARKDOWN_QUOTE_INSET_PT: Int = 14

    /** Compact quote leading inset. Source: `NativeMarkdownBody.swift:98` (`.padding(.leading, variant == .compact ? 8 : 14)`) Confidence: exact. */
    public const val MARKDOWN_QUOTE_COMPACT_INSET_PT: Int = 8

    /** Quote vertical bar width. Source: `NativeMarkdownBody.swift:100` (`frame(width: 2)`) Confidence: exact. */
    public const val MARKDOWN_QUOTE_BAR_WIDTH_PT: Int = 2

    /** Regular table cell horizontal inset. Source: `NativeMarkdownBody.swift:221` (`.padding(.horizontal, variant == .compact ? 8 : 16)`) Confidence: exact. */
    public const val MARKDOWN_TABLE_CELL_INSET_H_PT: Int = 16

    /** Regular table cell vertical inset. Source: `NativeMarkdownBody.swift:222` (`.padding(.vertical, variant == .compact ? 4 : 10)`) Confidence: exact. */
    public const val MARKDOWN_TABLE_CELL_INSET_V_PT: Int = 10

    /** Compact table cell horizontal inset. Source: `NativeMarkdownBody.swift:221` (`.padding(.horizontal, variant == .compact ? 8 : 16)`) Confidence: exact. */
    public const val MARKDOWN_TABLE_COMPACT_CELL_INSET_H_PT: Int = 8

    /** Compact table cell vertical inset. Source: `NativeMarkdownBody.swift:222` (`.padding(.vertical, variant == .compact ? 4 : 10)`) Confidence: exact. */
    public const val MARKDOWN_TABLE_COMPACT_CELL_INSET_V_PT: Int = 4

    /** Table grid/card minimum column width. Source: `NativeMarkdownBody.swift:220` (`minWidth: 100`) Confidence: exact. */
    public const val MARKDOWN_TABLE_COLUMN_MIN_WIDTH_PT: Int = 100

    /** Table grid/card maximum column width. Source: `NativeMarkdownBody.swift:220` (`maxWidth: 320`) Confidence: exact. */
    public const val MARKDOWN_TABLE_COLUMN_MAX_WIDTH_PT: Int = 320

    /** Table card row stack gap. Source: `NativeMarkdownBody.swift:167` (`VStack(alignment: .leading, spacing: 8)`) Confidence: exact. */
    public const val MARKDOWN_TABLE_CARD_GAP_PT: Int = 8

    /** Table card field stack gap. Source: `NativeMarkdownBody.swift:169` (`VStack(alignment: .leading, spacing: 10)`) Confidence: exact. */
    public const val MARKDOWN_TABLE_FIELD_GAP_PT: Int = 10

    /** Table card field label/value gap. Source: `NativeMarkdownBody.swift:171` (`VStack(alignment: .leading, spacing: 2)`) Confidence: exact. */
    public const val MARKDOWN_TABLE_LABEL_VALUE_GAP_PT: Int = 2

    /** Table card content inset. Source: `NativeMarkdownBody.swift:186` (`.padding(12)`) Confidence: exact. */
    public const val MARKDOWN_TABLE_CARD_INSET_PT: Int = 12

    /** Table card corner radius. Source: `NativeMarkdownBody.swift:189` (`cornerRadius: 12`) Confidence: exact. */
    public const val MARKDOWN_TABLE_CARD_RADIUS_PT: Int = 12

    /** Markdown H1 size. Source: `NativeMarkdownBody.swift:125` (`.system(size: 24, weight: .bold)`) Confidence: exact. */
    public const val MARKDOWN_H1_SIZE_PT: Int = 24

    /** Markdown H2 size. Source: `NativeMarkdownBody.swift:126` (`.system(size: 22, weight: .bold)`) Confidence: exact. */
    public const val MARKDOWN_H2_SIZE_PT: Int = 22

    /** Markdown H3 size. Source: `NativeMarkdownBody.swift:127` (`.system(size: 20, weight: .semibold)`) Confidence: exact. */
    public const val MARKDOWN_H3_SIZE_PT: Int = 20

    /** Markdown H4 size. Source: `NativeMarkdownBody.swift:128` (`.system(size: 17, weight: .semibold)`) Confidence: exact. */
    public const val MARKDOWN_H4_SIZE_PT: Int = 17

    /** Markdown footnote size. Source: `NativeMarkdownBody.swift:350` (`font(.system(size: 9))`) Confidence: exact. */
    public const val MARKDOWN_FOOTNOTE_SIZE_PT: Int = 9

    /** Markdown footnote baseline offset. Source: `NativeMarkdownBody.swift:350` (`.baselineOffset(6)`) Confidence: exact. */
    public const val MARKDOWN_FOOTNOTE_BASELINE_OFFSET_PT: Int = 6

    /** Regular thematic-rule vertical inset. Source: `NativeMarkdownBody.swift:118` (`.padding(.vertical, variant == .compact ? 4 : 16)`) Confidence: exact. */
    public const val MARKDOWN_RULE_INSET_V_PT: Int = 16

    /** Compact thematic-rule vertical inset. Source: `NativeMarkdownBody.swift:118` (`.padding(.vertical, variant == .compact ? 4 : 16)`) Confidence: exact. */
    public const val MARKDOWN_RULE_COMPACT_INSET_V_PT: Int = 4

    /** Thematic-rule thickness. Source: `NativeMarkdownBody.swift:117` (`.frame(height: 0.5)`) Confidence: exact. */
    public const val MARKDOWN_RULE_HEIGHT_PT: Float = 0.5f

    /** Header HStack icon-to-title gap. Source: `NativeChangedFilesCard.swift:19` (`HStack(spacing: 10)`) Confidence: exact. */
    public const val CHANGED_FILES_HEADER_GAP_PT: Int = 10

    /** File glyph frame. Source: `NativeChangedFilesCard.swift:30` (`.frame(width: 40, height: 40)`) Confidence: exact. */
    public const val CHANGED_FILES_HEADER_GLYPH_BOX_PT: Int = 40

    /** File-type glyph itself. Source: `NativeChangedFilesCard.swift:25-26`. Confidence: exact. Page-local: one page/surface layout value; no token fit. */
    public const val CHANGED_FILES_HEADER_GLYPH_SIZE_PT: Int = 20

    /** File-glyph tile corner radius. Source: `NativeChangedFilesCard.swift:21,23` (`cornerRadius: 10`) Confidence: exact. */
    public const val CHANGED_FILES_HEADER_GLYPH_RADIUS_PT: Int = 10

    /** Header title/summary vertical gap. Source: `NativeChangedFilesCard.swift:31` (`VStack(alignment: .leading, spacing: 2)`) Confidence: exact. */
    public const val CHANGED_FILES_TITLE_STACK_GAP_PT: Int = 2

    /** Changed-files header count size. Source: `NativeChangedFilesCard.swift:41` (`.font(.system(size: 10, design: .monospaced))`) Confidence: exact. */
    public const val CHANGED_FILES_HEADER_COUNT_SIZE_PT: Int = 10

    /** Added/deleted count gap. Source: `NativeChangedFilesCard.swift:37` (`HStack(spacing: 6)`) Confidence: exact. */
    public const val CHANGED_FILES_DIFF_COUNT_GAP_PT: Int = 6

    /** Header internal padding. Source: `NativeChangedFilesCard.swift:45` (`.padding(10)`) Confidence: exact. */
    public const val CHANGED_FILES_HEADER_INSET_PT: Int = 10

    /** Header row height. Source: `NativeChangedFilesCard.swift:46` (`.frame(height: 60)`) Confidence: exact. */
    public const val CHANGED_FILES_HEADER_HEIGHT_PT: Int = 60

    /** File row text/count gap. Source: `NativeChangedFilesCard.swift:56` (`HStack(spacing: 10)`) Confidence: exact. */
    public const val CHANGED_FILES_ROW_GAP_PT: Int = 10

    /** File row horizontal inset. Source: `NativeChangedFilesCard.swift:69` (`.padding(.horizontal, 14)`) Confidence: exact. */
    public const val CHANGED_FILES_ROW_INSET_H_PT: Int = 14

    /** File row vertical inset. Source: `NativeChangedFilesCard.swift:70` (`.padding(.vertical, 7)`) Confidence: exact. */
    public const val CHANGED_FILES_ROW_INSET_V_PT: Int = 7

    /** File/toggle interactive minimum row height. Source: `NativeChangedFilesCard.swift:71,87` (`.frame(minHeight: 44)`) Confidence: exact. */
    public const val CHANGED_FILES_ROW_MIN_HEIGHT_PT: Int = 44

    /** Expand/collapse row content gap. Source: `NativeChangedFilesCard.swift:78` (`HStack(spacing: 4)`) Confidence: exact. */
    public const val CHANGED_FILES_TOGGLE_GAP_PT: Int = 4

    /** Expand/collapse chevron glyph size. Source: `NativeChangedFilesCard.swift:80` (`NativeChatIcon(name: .chevronDown, size: 14)`) Confidence: exact. */
    public const val CHANGED_FILES_TOGGLE_CHEVRON_SIZE_PT: Int = 14

    /** Expand/collapse row horizontal inset. Source: `NativeChangedFilesCard.swift:85` (`.padding(.horizontal, 14)`) Confidence: exact. */
    public const val CHANGED_FILES_TOGGLE_INSET_H_PT: Int = 14

    /** Expand/collapse row vertical inset. Source: `NativeChangedFilesCard.swift:86` (`.padding(.vertical, 10)`) Confidence: exact. */
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

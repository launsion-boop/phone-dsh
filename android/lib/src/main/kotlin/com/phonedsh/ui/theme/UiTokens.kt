// Resolved token values for one theme mode.
// SPDX-License-Identifier: MIT
//
// Every value here comes from `spec/ui/v1/tokens.json` through generated
// `UiTokenData`; nothing is re-typed. A semantic colour with no literal Android
// projection (UIKit system colours, glass material) stays [Color.Unspecified]:
// that marks a real gap instead of inventing a sample.
package com.phonedsh.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.theme.generated.HomeSpecData
import com.phonedsh.ui.theme.generated.TokenColor
import com.phonedsh.ui.theme.generated.TokenDp
import com.phonedsh.ui.theme.generated.TokenGeometry
import com.phonedsh.ui.theme.generated.UiTokenData

/** The parity colour roles plus the appended PR22 HomeSpec palette, resolved for one mode. */
@Immutable
public data class UiColors(
    public val primary: Color,
    public val secondary: Color,
    public val tertiary: Color,
    public val caption: Color,
    /** `colors.background` is the published alias of HomeSpec.page. */
    public val background: Color,
    public val input: Color,
    public val selector: Color,
    public val code: Color,
    public val codeBanner: Color,
    public val inlineCode: Color,
    public val border: Color,
    public val borderLight: Color,
    public val accent: Color,
    /** NativeParityTokens success for retained session components. */
    public val success: Color,
    public val danger: Color,
    public val warning: Color,
    public val onAccent: Color,
    /** Legacy approval CTA accent alias; HomeSpec primary buttons use their own roles. */
    public val ctaOverride: Color,
    /** The page-layer fill (`NativePagePalette.accentFill`), distinct from the parity accent. */
    public val pageAccent: Color,
    /** Unresolved `UIColor.systemGreen`; Color.Unspecified is not an implementation. */
    public val switchOn: Color,
    /** Unresolved `.primary`; Android does not resolve this adaptive label here. */
    public val systemLabel: Color,
    /** Unresolved `.secondary`; Android does not resolve this adaptive label here. */
    public val systemSecondary: Color,
    /** Canonical HomeSpec page fill (#F7F7F7 / #101012). */
    public val page: Color,
    /** Verified pure black task-screen fill in both appearances. */
    public val taskScreen: Color,
    /** Unresolved `UIColor.systemGroupedBackground`. */
    public val groupedBackground: Color,
    /** No current PR22 owner; retained as an unresolved compatibility slot. */
    public val segmentTrack: Color,
    /** Unresolved footnote `.secondary` role. */
    public val settingsFootnoteInk: Color,
    /** HomeSpec user bubble fill (#E8E8E8 / #2C2C2E). */
    public val userBubble: Color,
    /** NativeParityTokens selector role for retained approval components. */
    public val approvalCard: Color,
    /** Unresolved `UIColor.separator` compatibility role. */
    public val separator: Color,
    // ---- PR22 HomeSpec palette (430x932pt) --------------------------------
    /** `HomeSpec.surface`: nav buttons, composer, step-list card, table body. */
    public val surface: Color,
    /** `HomeSpec.primaryButton`: the black pill / send-stop fill (#191919 light). */
    public val primaryButton: Color,
    /** `HomeSpec.primaryButtonInk`: the pill's label / send glyph. */
    public val primaryButtonInk: Color,
    /** `HomeSpec.textPrimary`: titles, body, bubble and table content. */
    public val textPrimary: Color,
    /** `HomeSpec.textSecondary`: process rows, table toolbar, action icons. */
    public val textSecondary: Color,
    /** `HomeSpec.textTertiary`: every step-list row. */
    public val textTertiary: Color,
    /** `HomeSpec.textSubtle`: nav subtitle. */
    public val textSubtle: Color,
    /** `HomeSpec.textPlaceholder`: timestamp and row values. */
    public val textPlaceholder: Color,
    /** `HomeSpec.inputPlaceholder`: composer placeholder (#8B8B8B light). */
    public val inputPlaceholder: Color,
    /** `HomeSpec.iconMuted`: composer voice and plus glyphs. */
    public val iconMuted: Color,
    /** `HomeSpec.borderList`: 1pt step-list card border (#E2E2E2 light). */
    public val borderList: Color,
    /** HomeSpec success (#3DC979 in both appearances), distinct from parity success. */
    public val homeSuccess: Color,
    /** NativeParityTokens surface (#FFFFFF / #151517), distinct from HomeSpec surface. */
    public val sessionSurface: Color,
    /** NativePagePalette warning, distinct from the parity warning role. */
    public val pageWarning: Color,
    /** NativePagePalette danger, distinct from the parity danger role. */
    public val pageDanger: Color,
) {
    /** True only if the background compatibility slot is unresolved. */
    public val backgroundUnmeasured: Boolean get() = background == Color.Unspecified
}

/** Spacing tokens, in dp. */
@Immutable
public data class UiSpacing(
    public val iconText: Dp,
    public val badgeInsetH: Dp,
    public val badgeInsetV: Dp,
    public val codeToolbar: Dp,
    public val cardInset: Dp,
    public val copyGap: Dp,
    public val codeExpandInset: Dp,
    public val jsonStack: Dp,
    public val jsonChevronGap: Dp,
    public val codeHeaderHeight: Dp,
    public val codeLineSpacing: Dp,
    public val codeWrapButton: Dp,
    public val codeCopyMinWidth: Dp,
    public val codeExpandHeight: Dp,
    public val codeBlockOuterInsetV: Dp,
)

/** Radius tokens, in dp. */
@Immutable
public data class UiRadius(
    public val card: Dp,
    public val codeBlock: Dp,
    public val bubble: Dp,
    public val composer: Dp,
)

/** Stroke tokens, in dp. */
@Immutable
public data class UiStroke(
    public val hairline: Dp,
)

/**
 * Motion tokens: duration, the spec's curve name and its repeat mode.
 *
 * The curve is a *name* (`linear`, `easeOut`); [easing] is the platform reading
 * of that name, never a second numeric source.
 */
@Immutable
public data class UiMotion(
    public val shimmerMs: Int,
    public val shimmerCurve: String,
    public val shimmerRepeat: Boolean,
    public val copyConfirmHoldMs: Int,
    public val copyConfirmHoldCurve: String,
    public val disclosureMs: Int,
    public val disclosureCurve: String,
    public val composerSendMs: Int,
    public val composerSendCurve: String,
    public val drawerOpenMs: Int,
    public val drawerOpenCurve: String,
    public val drawerCloseMs: Int,
    public val drawerCloseCurve: String,
    public val drawerSettleMs: Int,
    public val drawerSettleCurve: String,
) {
    /**
     * Maps a spec curve name to a Compose easing.
     *
     * An unknown name is a spec/code mismatch, not a reason to animate with a
     * different curve: the old fallback to linear hid exactly that divergence.
     */
    public fun easing(curve: String): androidx.compose.animation.core.Easing =
        when (curve) {
            LINEAR -> androidx.compose.animation.core.LinearEasing
            EASE_OUT -> androidx.compose.animation.core.CubicBezierEasing(0f, 0f, 0.58f, 1f)
            EASE_IN_OUT -> androidx.compose.animation.core.CubicBezierEasing(0.42f, 0f, 0.58f, 1f)
            else -> error("unknown motion curve '$curve' in spec/ui/v1/tokens.json")
        }

    public val shimmerEasing: androidx.compose.animation.core.Easing get() = easing(shimmerCurve)
    public val disclosureEasing: androidx.compose.animation.core.Easing get() = easing(disclosureCurve)
    public val composerSendEasing: androidx.compose.animation.core.Easing get() = easing(composerSendCurve)
    public val drawerOpenEasing: androidx.compose.animation.core.Easing get() = easing(drawerOpenCurve)
    public val drawerCloseEasing: androidx.compose.animation.core.Easing get() = easing(drawerCloseCurve)
    public val drawerSettleEasing: androidx.compose.animation.core.Easing get() = easing(drawerSettleCurve)

    public companion object {
        public const val LINEAR: String = "linear"
        public const val EASE_OUT: String = "easeOut"
        public const val EASE_IN_OUT: String = "easeInOut"
        public const val FOREVER: String = "forever"
    }
}

/**
 * Page-layer geometry tokens. `unit` is `pt` (dp on Android) or `screenRatio`.
 *
 * The first block is geometry the six signature surfaces declare; the page-level
 * block at the end is declared for pages. Compatibility names resolve through
 * declared aliases in `tokens.json`.
 */
@Immutable
public data class UiGeometry(
    public val disclosureRowHeight: Dp,
    public val disclosureIconGap: Dp,
    public val summaryDotDiameter: Dp,
    public val summaryDotGap: Dp,
    public val thinkingContentIndent: Dp,
    public val thinkingContentVertical: Dp,
    public val toolDetailIndent: Dp,
    public val toolDetailVertical: Dp,
    public val toolCardInset: Dp,
    public val terminalCardMaxHeight: Dp,
    /** User-bubble horizontal text inset (PR22 16 h). */
    public val bubblePaddingH: Dp,
    /** User-bubble vertical text inset (PR22 12 v). */
    public val bubblePaddingV: Dp,
    /** Gap between the bubble and its queue label (`ChatPage.swift:941`, 6). */
    public val bubbleBadgeGap: Dp,
    /** Screen-width compatibility cap; use [maxBubbleWidth] with an actual container where available. */
    public val bubbleMaxWidth: Dp,
    public val cardPadding: Dp,
    public val cardOuterMarginH: Dp,
    public val cardOuterMarginV: Dp,
    public val primaryButtonHeight: Dp,
    public val secondaryButtonHeight: Dp,
    /** `geometry.cardAreaMaxHeightRatio` is a `screenRatio`, not a dp. */
    public val cardAreaMaxHeightRatio: Float,
    public val composerMaxHeight: Dp,
    /** Input port top inset; its own token, same 8 as the row bottom. */
    public val composerPortTop: Dp,
    public val composerControlSize: Dp,
    /** Fixed tool-row height (`geometry.composerControlHeight`, 44). */
    public val composerControlRowHeight: Dp,
    /** Tool-row top inset. */
    public val composerControlTop: Dp,
    /** Tool-row bottom inset. */
    public val composerControlBottom: Dp,
    public val sendButtonDiameter: Dp,
    public val inlineStopDiameter: Dp,
    public val composerOuterMarginH: Dp,
    public val composerOuterMarginTop: Dp,
    public val statPillMinHeight: Dp,
    public val bannerGap: Dp,
    public val bannerInsetH: Dp,
    public val bannerInsetV: Dp,
    public val toolFailureBannerInset: Dp,
    // Page-level geometry: declared for the page layer, not for a signature surface.
    public val pageOuterMarginH: Dp,
    public val pageHeaderMinHeight: Dp,
    public val pageRowMinHeight: Dp,
    public val pageListRowMinHeight: Dp,
    public val statusDotDiameter: Dp,
    /** PR22 runtime rule: `(containerWidth - 2 * contentInset) * ratio`. */
    public val bubbleMaxWidthRatio: Float,
    /** Grouped list/form minimum row height (HomeSpec 48). */
    public val defaultMinListRowHeight: Dp,
    /** HomeSpec primary capsule height (50). */
    public val homePrimaryButtonHeight: Dp,
)

/** Computes the PR22 bubble maximum from the actual container width. */
public fun UiGeometry.maxBubbleWidth(containerWidth: Dp, contentInset: Dp): Dp =
    ((containerWidth.value - 2f * contentInset.value) * bubbleMaxWidthRatio).dp

/**
 * PR22 HomeSpec shadow helpers.
 *
 * `opacity` is black's alpha; `radius` is the SwiftUI blur radius and `y` the
 * offset, both in dp. Compose's `shadow()` takes an elevation, not this triple,
 * so a consumer maps it at the drawing site (the theme never pretends the two
 * primitives are identical).
 */
@Immutable
public data class UiShadow(
    public val floatingOpacity: Float,
    public val floatingRadius: Dp,
    public val floatingX: Dp,
    public val floatingY: Dp,
    public val composerOpacity: Float,
    public val composerRadius: Dp,
    public val composerX: Dp,
    public val composerY: Dp,
    public val drawerOpacity: Float,
    public val drawerRadius: Dp,
    public val drawerX: Dp,
    public val drawerY: Dp,
)

/**
 * The drawer's `interaction.drawer` values, already resolved for rendering.
 *
 * Width, corner radius, overhang and thresholds are the contract's own values;
 * the open/close curves live in [UiMotion] and the panel shadow in [UiShadow].
 */
@Immutable
public data class UiDrawer(
    public val width: Dp,
    public val panelTrailingRadius: Dp,
    public val closedOverhang: Dp,
    public val scrimMaxOpacity: Float,
    public val dragMinimumDistance: Dp,
    public val closeThresholdFraction: Float,
    public val velocityProjectionSeconds: Float,
) {
    /** The panel x when closed: `-(width + closedOverhang)`. */
    public val closedOffset: Dp get() = -(width + closedOverhang)
}

/** The complete resolved token set for one theme mode. */
@Immutable
public data class UiTokens(
    public val dark: Boolean,
    public val colors: UiColors,
    public val spacing: UiSpacing,
    public val radius: UiRadius,
    public val stroke: UiStroke,
    public val motion: UiMotion,
    public val geometry: UiGeometry,
    public val shadow: UiShadow,
    public val drawer: UiDrawer,
) {
    public companion object {
        /**
         * Resolves every token for [dark] straight from the generated spec model.
         *
         * [viewportWidth] feeds only the legacy fixed-width bubble cap; a layout
         * with a narrower local container must call [maxBubbleWidth] with the
         * real container width instead.
         */
        public fun resolve(dark: Boolean, viewportWidth: Dp = Dp.Unspecified): UiTokens = UiTokens(
            dark = dark,
            colors = UiColors(
                primary = UiTokenData.colorPrimary.color(dark),
                secondary = UiTokenData.colorSecondary.color(dark),
                tertiary = UiTokenData.colorTertiary.color(dark),
                caption = UiTokenData.colorCaption.color(dark),
                background = UiTokenData.colorPage.color(dark),
                input = UiTokenData.colorInput.color(dark),
                selector = UiTokenData.colorSelector.color(dark),
                code = UiTokenData.colorCode.color(dark),
                codeBanner = UiTokenData.colorCodeBanner.color(dark),
                inlineCode = UiTokenData.colorInlineCode.color(dark),
                border = UiTokenData.colorBorder.color(dark),
                borderLight = UiTokenData.colorBorderLight.color(dark),
                accent = UiTokenData.colorAccent.color(dark),
                // Legacy success consumers read the NativeParityTokens role
                // (declared alias colors.success -> colors.sessionSuccess).
                success = UiTokenData.colorSessionSuccess.color(dark),
                danger = UiTokenData.colorDanger.color(dark),
                warning = UiTokenData.colorWarning.color(dark),
                onAccent = UiTokenData.colorOnAccent.color(dark),
                ctaOverride = UiTokenData.colorCtaOverride.color(dark),
                pageAccent = UiTokenData.colorPageAccent.color(dark),
                switchOn = UiTokenData.colorSwitchOn.color(dark),
                systemLabel = UiTokenData.colorSystemLabel.color(dark),
                systemSecondary = UiTokenData.colorSystemSecondary.color(dark),
                page = UiTokenData.colorPage.color(dark),
                taskScreen = UiTokenData.colorTaskScreen.color(dark),
                groupedBackground = UiTokenData.colorGroupedBackground.color(dark),
                segmentTrack = UiTokenData.colorSegmentTrack.color(dark),
                settingsFootnoteInk = UiTokenData.colorSettingsFootnoteInk.color(dark),
                userBubble = UiTokenData.colorUserBubble.color(dark),
                approvalCard = UiTokenData.colorApprovalCard.color(dark),
                separator = UiTokenData.colorSeparator.color(dark),
                surface = UiTokenData.colorSurface.color(dark),
                primaryButton = UiTokenData.colorPrimaryButton.color(dark),
                primaryButtonInk = UiTokenData.colorPrimaryButtonInk.color(dark),
                textPrimary = UiTokenData.colorTextPrimary.color(dark),
                textSecondary = UiTokenData.colorTextSecondary.color(dark),
                textTertiary = UiTokenData.colorTextTertiary.color(dark),
                textSubtle = UiTokenData.colorTextSubtle.color(dark),
                textPlaceholder = UiTokenData.colorTextPlaceholder.color(dark),
                inputPlaceholder = UiTokenData.colorInputPlaceholder.color(dark),
                iconMuted = UiTokenData.colorIconMuted.color(dark),
                borderList = UiTokenData.colorBorderList.color(dark),
                homeSuccess = UiTokenData.colorSuccess.color(dark),
                sessionSurface = UiTokenData.colorSessionSurface.color(dark),
                pageWarning = UiTokenData.colorPageWarning.color(dark),
                pageDanger = UiTokenData.colorPageDanger.color(dark),
            ),
            spacing = UiSpacing(
                iconText = UiTokenData.spacingIconText.dp(),
                badgeInsetH = UiTokenData.spacingBadgeInsetH.dp(),
                badgeInsetV = UiTokenData.spacingBadgeInsetV.dp(),
                codeToolbar = UiTokenData.spacingCodeToolbar.dp(),
                cardInset = UiTokenData.spacingCardInset.dp(),
                copyGap = UiTokenData.spacingCopyGap.dp(),
                codeExpandInset = UiTokenData.spacingCodeExpandInset.dp(),
                jsonStack = UiTokenData.spacingJsonStack.dp(),
                jsonChevronGap = UiTokenData.spacingJsonChevronGap.dp(),
                codeHeaderHeight = UiTokenData.spacingCodeHeaderHeight.dp(),
                codeLineSpacing = UiTokenData.spacingCodeLineSpacing.dp(),
                codeWrapButton = UiTokenData.spacingCodeWrapButton.dp(),
                codeCopyMinWidth = UiTokenData.spacingCodeCopyMinWidth.dp(),
                codeExpandHeight = UiTokenData.spacingCodeExpandHeight.dp(),
                codeBlockOuterInsetV = UiTokenData.spacingCodeBlockOuterInsetV.dp(),
            ),
            radius = UiRadius(
                card = UiTokenData.radiusCard.dp(),
                codeBlock = UiTokenData.radiusCodeBlock.dp(),
                bubble = UiTokenData.radiusBubble.dp(),
                composer = UiTokenData.radiusComposer.dp(),
            ),
            stroke = UiStroke(hairline = UiTokenData.strokeHairline.dp()),
            motion = UiMotion(
                shimmerMs = UiTokenData.motionShimmer.durationMs,
                shimmerCurve = UiTokenData.motionShimmer.curve,
                shimmerRepeat = UiTokenData.motionShimmer.repeat == UiMotion.FOREVER,
                copyConfirmHoldMs = UiTokenData.motionCopyConfirmHold.durationMs,
                copyConfirmHoldCurve = UiTokenData.motionCopyConfirmHold.curve,
                disclosureMs = UiTokenData.motionDisclosure.durationMs,
                disclosureCurve = UiTokenData.motionDisclosure.curve,
                composerSendMs = UiTokenData.motionComposerSend.durationMs,
                composerSendCurve = UiTokenData.motionComposerSend.curve,
                drawerOpenMs = UiTokenData.drawer.openMotion.durationMs,
                drawerOpenCurve = UiTokenData.drawer.openMotion.curve,
                drawerCloseMs = UiTokenData.drawer.closeMotion.durationMs,
                drawerCloseCurve = UiTokenData.drawer.closeMotion.curve,
                drawerSettleMs = UiTokenData.drawer.settleMotion.durationMs,
                drawerSettleCurve = UiTokenData.drawer.settleMotion.curve,
            ),
            geometry = UiGeometry(
                disclosureRowHeight = UiTokenData.geometryDisclosureRowHeight.dp(),
                disclosureIconGap = UiTokenData.geometryDisclosureIconGap.dp(),
                summaryDotDiameter = UiTokenData.geometrySummaryDotDiameter.dp(),
                summaryDotGap = UiTokenData.geometrySummaryDotGap.dp(),
                thinkingContentIndent = UiTokenData.geometryThinkingContentIndent.dp(),
                thinkingContentVertical = UiTokenData.geometryThinkingContentVertical.dp(),
                toolDetailIndent = UiTokenData.geometryToolDetailIndent.dp(),
                toolDetailVertical = UiTokenData.geometryToolDetailVertical.dp(),
                toolCardInset = UiTokenData.geometryToolCardInset.dp(),
                terminalCardMaxHeight = UiTokenData.geometryTerminalCardMaxHeight.dp(),
                bubblePaddingH = UiTokenData.geometryBubblePaddingH.dp(),
                bubblePaddingV = UiTokenData.geometryBubblePaddingV.dp(),
                bubbleBadgeGap = UiTokenData.geometryBubbleBadgeGap.dp(),
                // The Dp compatibility slot derives from the current viewport;
                // callers with a narrower local container use maxBubbleWidth().
                bubbleMaxWidth = if (viewportWidth != Dp.Unspecified) {
                    ((viewportWidth.value - 2f * UiTokenData.geometryContentInset.value) *
                        UiTokenData.geometryBubbleMaxWidthRatio.value).dp
                } else {
                    Dp.Unspecified
                },
                cardPadding = UiTokenData.geometryCardPadding.dp(),
                cardOuterMarginH = UiTokenData.geometryCardOuterMarginH.dp(),
                cardOuterMarginV = UiTokenData.geometryCardOuterMarginV.dp(),
                primaryButtonHeight = UiTokenData.geometryPrimaryButtonHeight.dp(),
                secondaryButtonHeight = UiTokenData.geometrySecondaryButtonHeight.dp(),
                cardAreaMaxHeightRatio = UiTokenData.geometryCardAreaMaxHeightRatio.ratio(),
                composerMaxHeight = UiTokenData.geometryComposerMaxHeight.dp(),
                composerPortTop = UiTokenData.geometryComposerPortTop.dp(),
                composerControlSize = UiTokenData.geometryComposerControlSize.dp(),
                composerControlRowHeight = UiTokenData.geometryComposerControlRowHeight.dp(),
                composerControlTop = UiTokenData.geometryComposerControlTop.dp(),
                composerControlBottom = UiTokenData.geometryComposerControlBottom.dp(),
                sendButtonDiameter = UiTokenData.geometrySendButtonDiameter.dp(),
                inlineStopDiameter = UiTokenData.geometryInlineStopDiameter.dp(),
                composerOuterMarginH = UiTokenData.geometryComposerOuterMarginH.dp(),
                composerOuterMarginTop = UiTokenData.geometryComposerOuterMarginTop.dp(),
                statPillMinHeight = UiTokenData.geometryStatPillMinHeight.dp(),
                bannerGap = UiTokenData.geometryBannerGap.dp(),
                bannerInsetH = UiTokenData.geometryBannerInsetH.dp(),
                bannerInsetV = UiTokenData.geometryBannerInsetV.dp(),
                toolFailureBannerInset = UiTokenData.geometryToolFailureBannerInset.dp(),
                pageOuterMarginH = UiTokenData.geometryPageOuterMarginH.dp(),
                pageHeaderMinHeight = UiTokenData.geometryPageHeaderMinHeight.dp(),
                pageRowMinHeight = UiTokenData.geometryPageRowMinHeight.dp(),
                pageListRowMinHeight = UiTokenData.geometryPageListRowMinHeight.dp(),
                statusDotDiameter = UiTokenData.geometryStatusDotDiameter.dp(),
                bubbleMaxWidthRatio = UiTokenData.geometryBubbleMaxWidthRatio.ratio(),
                defaultMinListRowHeight = UiTokenData.geometryDefaultMinListRowHeight.dp(),
                homePrimaryButtonHeight = UiTokenData.geometryHomePrimaryButtonHeight.dp(),
            ),
            shadow = UiShadow(
                floatingOpacity = HomeSpecData.Shadow.FLOATING_OPACITY,
                floatingRadius = HomeSpecData.Shadow.FLOATING_RADIUS.dp,
                floatingX = HomeSpecData.Shadow.FLOATING_X.dp,
                floatingY = HomeSpecData.Shadow.FLOATING_Y.dp,
                composerOpacity = HomeSpecData.Shadow.COMPOSER_OPACITY,
                composerRadius = HomeSpecData.Shadow.COMPOSER_RADIUS.dp,
                composerX = HomeSpecData.Shadow.COMPOSER_X.dp,
                composerY = HomeSpecData.Shadow.COMPOSER_Y.dp,
                drawerOpacity = HomeSpecData.Shadow.DRAWER_OPACITY,
                drawerRadius = HomeSpecData.Shadow.DRAWER_RADIUS.dp,
                drawerX = HomeSpecData.Shadow.DRAWER_X.dp,
                drawerY = HomeSpecData.Shadow.DRAWER_Y.dp,
            ),
            drawer = UiDrawer(
                width = UiTokenData.drawer.width.dp(),
                panelTrailingRadius = UiTokenData.drawer.panelTrailingRadius.dp(),
                closedOverhang = UiTokenData.drawer.closedOverhangPt.dp,
                scrimMaxOpacity = UiTokenData.drawer.scrimMaxOpacity,
                dragMinimumDistance = UiTokenData.drawer.dragMinimumDistancePt.dp,
                closeThresholdFraction = UiTokenData.drawer.closeThresholdFraction,
                velocityProjectionSeconds = UiTokenData.drawer.velocityProjectionSeconds,
            ),
        )
    }
}

/** Resolves literal colour tokens; semantic and unmeasured colours remain unresolved. */
internal fun TokenColor.color(dark: Boolean): Color {
    if (semantic != null) return Color.Unspecified
    val value = (if (dark) this.dark else this.light) ?: return Color.Unspecified
    val alpha = if (dark) darkAlpha else lightAlpha
    return Color(value).copy(alpha = alpha)
}

/** A `pt` token is a dp on Android (the unit only changes at render time, through the font scale). */
internal fun TokenDp.dp(): Dp = value.dp

/** Geometry with `unit: pt` renders as dp; a ratio token has no dp form. */
internal fun TokenGeometry.dp(): Dp {
    require(unit == PT) { "${name}: unit '$unit' is not a length; read it through ratio() instead" }
    return value.dp
}

/** Reads a `screenRatio` geometry token; a length token is a caller bug. */
internal fun TokenGeometry.ratio(): Float {
    require(unit == RATIO) { "${name}: unit '$unit' is not a screen ratio" }
    return value
}

/** The one length unit the page layer uses. */
public const val PT: String = "pt"

/** The one unit-free geometry unit the page layer uses. */
public const val RATIO: String = "screenRatio"

// Resolved token values for one theme mode.
// SPDX-License-Identifier: MIT
//
// Every value here comes from `spec/ui/v1/tokens.json` through the generated
// `UiTokenData`; nothing is re-typed. A `null` channel in the spec (only
// `colors.background`) stays unmeasured and resolves to [Color.Unspecified] so
// the caller renders on the platform surface instead of an invented colour.
package com.phonedsh.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.theme.generated.TokenColor
import com.phonedsh.ui.theme.generated.TokenDp
import com.phonedsh.ui.theme.generated.TokenGeometry
import com.phonedsh.ui.theme.generated.UiTokenData

/** The eighteen colour tokens, resolved for one mode. */
@Immutable
public data class UiColors(
    public val primary: Color,
    public val secondary: Color,
    public val tertiary: Color,
    public val caption: Color,
    /** `colors.background` is `tier: unmeasured`; [Color.Unspecified] means "platform surface". */
    public val background: Color,
    public val input: Color,
    public val selector: Color,
    public val code: Color,
    public val codeBanner: Color,
    public val inlineCode: Color,
    public val border: Color,
    public val borderLight: Color,
    public val accent: Color,
    public val success: Color,
    public val danger: Color,
    public val warning: Color,
    public val onAccent: Color,
    /** Page-layer override for the approval CTA (baseline inconsistency, mirrored on purpose). */
    public val ctaOverride: Color,
) {
    /** True when the spec could not measure `colors.background` (it never could: a dynamic system colour). */
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
) {
    /** Maps a spec curve name to a Compose easing. */
    public fun easing(curve: String): androidx.compose.animation.core.Easing =
        when (curve) {
            LINEAR -> androidx.compose.animation.core.LinearEasing
            // CSS-style easeOut; the spec names the curve, not the control points.
            EASE_OUT -> androidx.compose.animation.core.CubicBezierEasing(0f, 0f, 0.58f, 1f)
            else -> androidx.compose.animation.core.LinearEasing
        }

    public val shimmerEasing: androidx.compose.animation.core.Easing get() = easing(shimmerCurve)
    public val disclosureEasing: androidx.compose.animation.core.Easing get() = easing(disclosureCurve)
    public val composerSendEasing: androidx.compose.animation.core.Easing get() = easing(composerSendCurve)

    public companion object {
        public const val LINEAR: String = "linear"
        public const val EASE_OUT: String = "easeOut"
        public const val FOREVER: String = "forever"
    }
}

/**
 * Page-layer geometry tokens. `unit` is `pt` (dp on Android) or `screenRatio`.
 *
 * The first block is the geometry the six signature surfaces declare; the
 * page-level block at the end is declared for pages and is not part of any
 * signature surface (`spec/ui/v1/README.md` §4 page-level subsection).
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
    public val bubblePadding: Dp,
    public val bubbleLineSpacing: Dp,
    public val bubbleMaxWidth: Dp,
    public val cardPadding: Dp,
    public val cardOuterMarginH: Dp,
    public val cardOuterMarginV: Dp,
    public val primaryButtonHeight: Dp,
    public val secondaryButtonHeight: Dp,
    /** `geometry.cardAreaMaxHeightRatio` is a `screenRatio`, not a dp: keep it unit-free. */
    public val cardAreaMaxHeightRatio: Float,
    public val composerMinHeight: Dp,
    public val composerMaxHeight: Dp,
    public val composerControlSize: Dp,
    public val sendButtonDiameter: Dp,
    public val inlineStopDiameter: Dp,
    public val composerTrailingReserve: Dp,
    public val composerOuterMarginH: Dp,
    public val composerOuterMarginTop: Dp,
    public val composerOuterMarginBottom: Dp,
    public val statPillMinHeight: Dp,
    public val bannerGap: Dp,
    public val bannerInsetH: Dp,
    public val bannerInsetV: Dp,
    public val toolFailureBannerInset: Dp,
    // Page-level geometry: declared for the page layer, not for a signature surface.
    // `PageGeometryTokenTest` requires each of these to have at least two page users.
    public val pageOuterMarginH: Dp,
    public val pageHeaderMinHeight: Dp,
    public val pageRowMinHeight: Dp,
    public val pageListRowMinHeight: Dp,
    public val statusDotDiameter: Dp,
)

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
) {
    public companion object {
        /** Resolves every token for [dark] straight from the generated spec model. */
        public fun resolve(dark: Boolean): UiTokens = UiTokens(
            dark = dark,
            colors = UiColors(
                primary = UiTokenData.colorPrimary.color(dark),
                secondary = UiTokenData.colorSecondary.color(dark),
                tertiary = UiTokenData.colorTertiary.color(dark),
                caption = UiTokenData.colorCaption.color(dark),
                background = UiTokenData.colorBackground.color(dark),
                input = UiTokenData.colorInput.color(dark),
                selector = UiTokenData.colorSelector.color(dark),
                code = UiTokenData.colorCode.color(dark),
                codeBanner = UiTokenData.colorCodeBanner.color(dark),
                inlineCode = UiTokenData.colorInlineCode.color(dark),
                border = UiTokenData.colorBorder.color(dark),
                borderLight = UiTokenData.colorBorderLight.color(dark),
                accent = UiTokenData.colorAccent.color(dark),
                success = UiTokenData.colorSuccess.color(dark),
                danger = UiTokenData.colorDanger.color(dark),
                warning = UiTokenData.colorWarning.color(dark),
                onAccent = UiTokenData.colorOnAccent.color(dark),
                ctaOverride = UiTokenData.colorCtaOverride.color(dark),
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
                bubblePadding = UiTokenData.geometryBubblePadding.dp(),
                bubbleLineSpacing = UiTokenData.geometryBubbleLineSpacing.dp(),
                bubbleMaxWidth = UiTokenData.geometryBubbleMaxWidth.dp(),
                cardPadding = UiTokenData.geometryCardPadding.dp(),
                cardOuterMarginH = UiTokenData.geometryCardOuterMarginH.dp(),
                cardOuterMarginV = UiTokenData.geometryCardOuterMarginV.dp(),
                primaryButtonHeight = UiTokenData.geometryPrimaryButtonHeight.dp(),
                secondaryButtonHeight = UiTokenData.geometrySecondaryButtonHeight.dp(),
                cardAreaMaxHeightRatio = UiTokenData.geometryCardAreaMaxHeightRatio.ratio(),
                composerMinHeight = UiTokenData.geometryComposerMinHeight.dp(),
                composerMaxHeight = UiTokenData.geometryComposerMaxHeight.dp(),
                composerControlSize = UiTokenData.geometryComposerControlSize.dp(),
                sendButtonDiameter = UiTokenData.geometrySendButtonDiameter.dp(),
                inlineStopDiameter = UiTokenData.geometryInlineStopDiameter.dp(),
                composerTrailingReserve = UiTokenData.geometryComposerTrailingReserve.dp(),
                composerOuterMarginH = UiTokenData.geometryComposerOuterMarginH.dp(),
                composerOuterMarginTop = UiTokenData.geometryComposerOuterMarginTop.dp(),
                composerOuterMarginBottom = UiTokenData.geometryComposerOuterMarginBottom.dp(),
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
            ),
        )
    }
}

/** Resolves one colour token; an unmeasured channel is never replaced by a guess. */
internal fun TokenColor.color(dark: Boolean): Color =
    (if (dark) this.dark else this.light)?.let { Color(it) } ?: Color.Unspecified

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

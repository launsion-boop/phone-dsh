// Signature surface 4/6 - the approval card.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §2 "审批卡" + §3 + §4 + `tokens.json`
// `signatureSurfaces.approvalCard`.
//
// One slot serves both pending cards (permission and question). The card is
// disabled-adjacent by nature: while it is on screen the composer stays visible
// but disabled, never hidden.
package com.phonedsh.ui.surface

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.text.font.FontWeight
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/**
 * The token inventory of this surface: exactly `signatureSurfaces.approvalCard.tokens`.
 *
 * The card title's primary ink and the title-to-subtitle gap used to be documented
 * gaps because the spec's list did not declare them. They are declared now, so the
 * gaps list is empty and a missing token must fail this surface instead of being
 * excused as review debt.
 */
public object ApprovalCardTokens {
    /** Tokens the spec declares for this surface. */
    public val declared: List<String> = listOf(
        UiTokenNames.COLORS_APPROVAL_CARD,
        UiTokenNames.COLORS_CTA_OVERRIDE,
        UiTokenNames.COLORS_ON_ACCENT,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.TYPOGRAPHY_PAGE_TITLE,
        UiTokenNames.TYPOGRAPHY_PROCESS,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.GEOMETRY_CARD_PADDING,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_V,
        UiTokenNames.GEOMETRY_APPROVAL_CARD_SPACING,
        UiTokenNames.GEOMETRY_PRIMARY_BUTTON_HEIGHT,
        UiTokenNames.GEOMETRY_SECONDARY_BUTTON_HEIGHT,
        UiTokenNames.GEOMETRY_CARD_AREA_MAX_HEIGHT_RATIO,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.SPACING_ICON_TEXT,
    )

    /** No reviewed deviations: every token this surface uses is declared by the spec. */
    public val gaps: List<String> = emptyList()

    public val refs: List<String> get() = declared + gaps
}

/**
 * A pending permission or question card.
 *
 * @param title e.g. "需要授权"; the card's heading.
 * @param subtitle the request summary / question prompt.
 * @param primaryLabel the accept action ("允许一次").
 * @param onPrimary accept.
 * @param secondaryLabel the decline action ("拒绝"); `null` hides it.
 * @param onSecondary decline.
 * @param maxHeight `geometry.cardAreaMaxHeightRatio` x screen height, computed by
 *   the slot; the card scrolls internally beyond it.
 */
@Composable
public fun ApprovalCard(
    title: String,
    subtitle: String,
    primaryLabel: String,
    onPrimary: () -> Unit,
    modifier: Modifier = Modifier,
    secondaryLabel: String? = null,
    onSecondary: (() -> Unit)? = null,
    maxHeight: Dp = Dp.Unspecified,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val shape = RoundedCornerShape(tokens.radius.card)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.cardOuterMarginH,
                vertical = tokens.geometry.cardOuterMarginV,
            )
            .testTag(UiTags.APPROVAL_CARD)
            // A pending ask must interrupt, but politely: it is a live region.
            .semantics(mergeDescendants = false) { liveRegion = LiveRegionMode.Polite }
            // iOS fills the card with `NativeChatTheme.selector` (#F5F6F7);
            // `colors.selector` (#F2F3F5) is 3/255 off in the green channel, which
            // the pixel comparator counts across the card's whole area.
            .background(color = tokens.colors.approvalCard, shape = shape)
            .padding(tokens.geometry.cardPadding),
        verticalArrangement = Arrangement.spacedBy(com.phonedsh.ui.ChatMetrics.PERMISSION_CARD_SPACING_PT.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = maxHeight)
                .verticalScroll(rememberScrollState()),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
                BasicText(
                    text = title,
                    style = type.pageTitle.copy(color = tokens.colors.primary, lineHeight = TextUnit.Unspecified),
                    modifier = Modifier.semantics { heading() },
                )
                BasicText(
                    text = subtitle,
                    style = type.processBody.copy(color = tokens.colors.primary, fontWeight = FontWeight.SemiBold, lineHeight = TextUnit.Unspecified),
                )
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.primaryButtonHeight)
                .background(color = tokens.colors.ctaOverride, shape = shape)
                .clickable(role = Role.Button, onClick = onPrimary)
                .testTag(UiTags.APPROVAL_PRIMARY)
                .padding(horizontal = tokens.geometry.cardPadding),
            contentAlignment = Alignment.Center,
        ) {
            BasicText(
                text = primaryLabel,
                style = type.pageTitle.copy(color = tokens.colors.onAccent, lineHeight = TextUnit.Unspecified),
            )
        }
        if (secondaryLabel != null && onSecondary != null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = tokens.geometry.secondaryButtonHeight)
                    .clickable(role = Role.Button, onClick = onSecondary)
                    .testTag(UiTags.APPROVAL_SECONDARY)
                    .padding(horizontal = tokens.geometry.cardPadding),
                contentAlignment = Alignment.Center,
            ) {
                BasicText(
                    text = secondaryLabel,
                    style = type.processBody.copy(color = tokens.colors.secondary, lineHeight = TextUnit.Unspecified),
                )
            }
        }
    }
}

/**
 * The folded second pending card: "还有 1 个待确认".
 *
 * The slot rule allows one card plus this one line, so the second ask never
 * disappears from sight, it just folds.
 */
@Composable
public fun FoldedPendingRow(
    label: String,
    onExpand: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    // The baseline draws this line as flat page chrome, not as a card: 16 pt page
    // margin, one grey sentence and a trailing `chevron.down`, no fill and no
    // radius (ios-chat-default.png: the row above the permission card, y 103–140 pt).
    // The fill + radius it used to draw turned a one-line fold into a second card.
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onExpand)
            .padding(
                horizontal = tokens.geometry.cardOuterMarginH,
                vertical = tokens.geometry.cardOuterMarginV,
            )
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = label,
            style = type.processBody.copy(color = tokens.colors.secondary, lineHeight = TextUnit.Unspecified),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = FOLD_CHEVRON,
            style = type.processBody.copy(color = tokens.colors.secondary, lineHeight = TextUnit.Unspecified),
        )
    }
}

/** The fold line's trailing `chevron.down` (an SF Symbol; drawn as text here). */
private const val FOLD_CHEVRON: String = "⌄"

/** The standard pair of labels for a permission card. */
public object ApprovalLabels {
    public val allowOnce: String get() = UiStrings.ALLOW_ONCE
    public val deny: String get() = UiStrings.DENY
}

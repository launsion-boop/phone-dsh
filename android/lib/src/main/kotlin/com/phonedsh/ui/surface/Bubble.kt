// Signature surface 1/6 - the message bubble.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §4 "气泡" + `tokens.json`
// `BubbleTokens.refs` is the source inventory of values this component reads.
//
// The user bubble's text insets are 16 h / 12 v (`ChatPage.swift:3902-3903`,
// PR22) and are read from `geometry.bubblePaddingH/V` — the pair this surface
// declares in `signatureSurfaces.bubble.tokens`. The queue label's 6 pt gap is
// its own token, `geometry.bubbleBadgeGap` (`ChatPage.swift:891`). Surface
// ownership is what keeps both off `PageGeometryTokenTest`'s "used by two pages"
// rule (no page file reads the bubble). The old scalar `bubblePadding` was a
// misnamed device-session error inset; that page uses the shared 12pt card inset.
//
// The surface is two pieces: `ChatBubble` draws the bubble, `BubbleBadge` draws
// the queue label a user row puts under it (spec §3 "行下标签"). The row owns
// the placement, so the bubble itself never knows that a label exists.
package com.phonedsh.ui.surface

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/** Who spoke. The assistant answer carries no bubble chrome (spec §4 note). */
public enum class BubbleRole {
    /** Own message: HomeSpec userBubble fill + the 24pt asymmetric shape. */
    USER,

    /** Assistant answer: text on the platform background, no fill, no radius. */
    ASSISTANT,
}

/**
 * Canonical tokens read by the bubble and its queue badge.
 * `spacing.paragraphGap` stays row-owned by the transcript; it is not claimed
 * here merely to satisfy the surface-level inventory check.
 */
public object BubbleTokens {
    public val refs: List<String> = listOf(
        UiTokenNames.COLORS_USER_BUBBLE,
        UiTokenNames.COLORS_TEXT_PRIMARY,
        UiTokenNames.COLORS_TEXT_SECONDARY,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.RADIUS_BUBBLE,
        UiTokenNames.GEOMETRY_CONTENT_INSET,
        UiTokenNames.GEOMETRY_BUBBLE_PADDING_H,
        UiTokenNames.GEOMETRY_BUBBLE_PADDING_V,
        UiTokenNames.GEOMETRY_BUBBLE_MAX_WIDTH_RATIO,
        UiTokenNames.GEOMETRY_BUBBLE_BADGE_GAP,
    )
}

/** Uses the provider's complete preferred text role, including its line box. */
@Composable
public fun bubbleBodyStyle(): TextStyle {
    val type: UiType = LocalUiType.current
    val tokens = LocalUiTokens.current
    return type.homeBody.copy(color = tokens.colors.textPrimary)
}

/**
 * The queue-label style: `typography.secondary` + HomeSpec textSecondary (spec §3
 * "行下标签"; iOS `queueLine` is system 13 pt + `ChatPage.inkSecondary`). The values come
 * from the theme, never from this file.
 */
@Composable
internal fun bubbleBadgeStyle(): TextStyle {
    val type: UiType = LocalUiType.current
    val tokens = LocalUiTokens.current
    return type.secondary.copy(
        color = tokens.colors.textSecondary,
        lineHeight = TextUnit.Unspecified,
    )
}

/**
 * The queue label of a user row: the row's badge text in `typography.secondary`
 * + HomeSpec.textSecondary, 6 pt under the bubble (spec §3 "行下标签").
 *
 * It is a separate piece on purpose: the chat row places the bubble at its
 * trailing edge and this label at its leading edge, matching the iOS
 * `queueLine` under a trailing `userBubble`. [ChatBubble] stays a pure bubble
 * and never learns that a label exists.
 *
 * @param text the row's `ChatRow.User.badge`; the row decides when it exists.
 *   It is display text, passed through verbatim.
 * @param modifier layout modifier from the caller.
 */
@Composable
public fun BubbleBadge(
    text: String,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = text,
        // iOS `queueLine` sits 6 pt under the bubble (`ChatPage.swift:891`), read
        // from `geometry.bubbleBadgeGap` — its own token, no longer `bubblePadding/2`.
        modifier = modifier.padding(top = tokens.geometry.bubbleBadgeGap),
        style = bubbleBadgeStyle(),
    )
}

/**
 * One message row.
 *
 * @param role user or assistant.
 * @param text the message body, already projected by the UiState projector
 *   (bounded to 20000 chars there; this component never truncates silently).
 * @param modifier layout modifier from the caller.
 */
@Composable
public fun ChatBubble(
    role: BubbleRole,
    text: String,
    modifier: Modifier = Modifier,
    containerWidth: Dp? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val windowWidth = LocalConfiguration.current.screenWidthDp.dp
    val actualContainerWidth = containerWidth ?: windowWidth
    val common = modifier
        .testTag(UiTags.BUBBLE)
        // One utterance per message: the role and the body are read together.
        .semantics(mergeDescendants = true) {}

    when (role) {
        BubbleRole.USER -> BasicText(
            text = text,
            modifier = common
                .widthIn(
                    max = ChatMetrics.userBubbleMaxWidth(
                        containerWidth = actualContainerWidth,
                        contentInset = HomeMetrics.contentInset,
                    ),
                )
                .background(
                    color = tokens.colors.userBubble,
                    shape = RoundedCornerShape(
                        topStart = tokens.radius.bubble,
                        topEnd = HomeMetrics.BUBBLE_TOP_TRAILING_RADIUS_PT.dp,
                        bottomEnd = tokens.radius.bubble,
                        bottomStart = tokens.radius.bubble,
                    ),
                )
                .padding(
                    horizontal = tokens.geometry.bubblePaddingH,
                    vertical = tokens.geometry.bubblePaddingV,
                ),
            style = bubbleBodyStyle(),
        )

        BubbleRole.ASSISTANT -> BasicText(
            text = text,
            modifier = common,
            style = type.homeBody.copy(color = tokens.colors.textPrimary),
        )
    }
}

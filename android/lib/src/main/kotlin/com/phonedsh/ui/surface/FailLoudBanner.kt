// Signature surface 6/6 - the fail-loud banner.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §2 "fail-loud 横幅" + §3 + §4 + `tokens.json`
// `signatureSurfaces.failLoudBanner`.
//
// Three placements share one component: the turn failure sits at the top of the
// list, the send failure sits under the rejected message, and the tool failure
// sits inside the tool row's expanded detail. None of them may disappear on its
// own: only a user gesture or the next successful send clears one.
package com.phonedsh.ui.surface

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/** Where the failure is shown. */
public enum class FailLoudKind {
    /** A turn ended in error: top banner with retry + dismiss. */
    TURN,

    /** A send was rejected: the draft survives, the row sticks to the message. */
    SEND,

    /** A tool result reported an error: a card inside the tool row. */
    TOOL,
}

/**
 * The token inventory of this surface; exactly
 * `signatureSurfaces.failLoudBanner.tokens`.
 *
 * Note: the declared list has no radius, no surface fill and no divider, so the
 * banner is an ink-only row (see the token-gap report).
 */
public object FailLoudBannerTokens {
    public val refs: List<String> = listOf(
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.GEOMETRY_BANNER_GAP,
        UiTokenNames.GEOMETRY_BANNER_INSET_H,
        UiTokenNames.GEOMETRY_BANNER_INSET_V,
        UiTokenNames.GEOMETRY_TOOL_FAILURE_BANNER_INSET,
    )
}

/**
 * A failure that must reach the screen.
 *
 * @param kind turn / send / tool.
 * @param message the failure line (already projected; never empty — the caller
 *   supplies a fallback when the host gave no text).
 * @param onRetry retry action; turn and tool failures offer it.
 * @param onDismiss the only way to clear it besides a successful send.
 */
@Composable
public fun FailLoudBanner(
    kind: FailLoudKind,
    message: String,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismiss: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val label = when (kind) {
        FailLoudKind.TURN -> UiStrings.TURN_FAILED
        FailLoudKind.SEND -> UiStrings.SEND_FAILED
        FailLoudKind.TOOL -> UiStrings.TOOL_FAILED
    }
    val labelInk = when (kind) {
        FailLoudKind.TURN -> tokens.colors.warning
        FailLoudKind.SEND -> tokens.colors.warning
        FailLoudKind.TOOL -> tokens.colors.danger
    }
    val horizontal = when (kind) {
        FailLoudKind.TOOL -> tokens.geometry.toolFailureBannerInset
        else -> tokens.geometry.bannerInsetH
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag(UiTags.FAIL_LOUD_BANNER)
            // Fail-loud is audible too: an assertive live region interrupts.
            .semantics { liveRegion = LiveRegionMode.Assertive }
            .padding(horizontal = horizontal, vertical = tokens.geometry.bannerInsetV),
        verticalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
        ) {
            BasicText(
                text = label,
                style = type.secondary.copy(color = labelInk),
                modifier = Modifier.semantics { contentDescription = "$label: $message" },
            )
            BasicText(
                text = message,
                style = type.caption.copy(color = tokens.colors.secondary),
                modifier = Modifier.weight(1f),
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
        ) {
            if (onRetry != null) {
                BasicText(
                    text = UiStrings.RETRY,
                    style = type.caption.copy(color = labelInk),
                    modifier = Modifier
                        .clickable(role = Role.Button, onClick = onRetry)
                        .testTag(UiTags.BANNER_RETRY)
                        .padding(vertical = tokens.geometry.bannerInsetV),
                )
            }
            if (onDismiss != null) {
                BasicText(
                    text = UiStrings.DISMISS,
                    style = type.caption.copy(color = tokens.colors.secondary),
                    modifier = Modifier
                        .clickable(role = Role.Button, onClick = onDismiss)
                        .testTag(UiTags.BANNER_DISMISS)
                        .padding(vertical = tokens.geometry.bannerInsetV),
                )
            }
        }
    }
}

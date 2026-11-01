// The bits the session pages need on top of the shared page frame.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (page list), §3 (fail-loud), §5 (`insets`,
// `back-gesture`). The session pages are not among the six signature surfaces
// (§4), so their chrome is accepted on semantics: the visible copy and the
// ScreenState sequence, never a screenshot.
//
// Why this file is not `PageScaffold.kt`: that frame belongs to the
// settings/tools/files lane. Reusing its public helpers is fine, editing it is
// not, so the session-only pieces live here under `Session*` names and never
// collide.
//
// Geometry: `tokens.json` declares the page-level tokens this file reads
// (`geometry.pageOuterMarginH`, `geometry.pageRowMinHeight`). The fail-loud line
// and the section label's vertical gap still reuse signature-surface geometry,
// and each such reuse is marked `unverified geometry` where it is used; no value
// is invented.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/**
 * The token inventory of the session-page chrome; `PageTokenReferenceTest` fails
 * if a use site reads a token that is not listed here, and the test itself reads
 * the spec so a token the spec does not declare cannot be listed either.
 */
internal object SessionPageChromeTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.GEOMETRY_BANNER_INSET_H,
        UiTokenNames.GEOMETRY_BANNER_INSET_V,
        UiTokenNames.GEOMETRY_BANNER_GAP,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_V,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
    )
}

/** The ink a session-page action uses; the caller picks the semantic role. */
internal enum class SessionActionTone { ACCENT, SECONDARY, DANGER, TERTIARY }

/**
 * A fail-loud line for a page that is not the chat page: a list read failure is
 * neither a turn, a send nor a tool failure, so it must not wear one of the
 * signature banners' labels. It is still fail-loud: on screen, retryable and
 * dismissible, never a log line.
 *
 * @param message the failure text.
 * @param tag the stable test tag.
 * @param retryLabel the retry verb; `null` hides the action.
 * @param onRetry retry action.
 * @param onDismiss dismiss action; `null` hides it.
 */
@Composable
internal fun SessionFailureLine(
    message: String,
    tag: String,
    modifier: Modifier = Modifier,
    retryLabel: String? = null,
    onRetry: (() -> Unit)? = null,
    onDismiss: (() -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .testTag(tag)
            // Fail-loud is audible too: an assertive live region interrupts.
            .semantics { liveRegion = LiveRegionMode.Assertive }
            // unverified geometry: the fail-loud banner's inset reused for a
            // page-level failure line (the spec declares it for the banner).
            .padding(
                horizontal = tokens.geometry.bannerInsetH,
                vertical = tokens.geometry.bannerInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
    ) {
        BasicText(
            text = message,
            style = type.secondary.copy(color = tokens.colors.warning),
            modifier = Modifier.weight(1f),
        )
        if (retryLabel != null && onRetry != null) {
            SessionTextAction(label = retryLabel, onClick = onRetry, tone = SessionActionTone.ACCENT)
        }
        if (onDismiss != null) {
            SessionTextAction(
                label = DISMISS_GLYPH,
                onClick = onDismiss,
                tone = SessionActionTone.TERTIARY,
                description = UiStrings.DISMISS,
            )
        }
    }
}

/**
 * A text action inside a session page row.
 *
 * @param label the visible verb (from `UiStrings`).
 * @param onClick the action.
 * @param tone which token ink.
 * @param enabled false renders it disabled rather than hiding it.
 * @param description the a11y description when the glyph is not a word.
 */
@Composable
internal fun SessionTextAction(
    label: String,
    onClick: () -> Unit,
    tone: SessionActionTone,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    description: String = label,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val ink = when {
        !enabled -> tokens.colors.tertiary
        tone == SessionActionTone.ACCENT -> tokens.colors.accent
        tone == SessionActionTone.DANGER -> tokens.colors.danger
        tone == SessionActionTone.SECONDARY -> tokens.colors.secondary
        else -> tokens.colors.tertiary
    }
    BasicText(
        text = label,
        style = type.secondary.copy(color = ink),
        maxLines = 1,
        modifier = modifier
            // Page-level geometry: a text action is a page control, so its floor is
            // the page row minimum rather than the approval card's button height.
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .padding(tokens.spacing.iconText),
    )
}

/** A section caption above a group of rows. */
@Composable
internal fun SessionSectionLabel(text: String, modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = modifier
            .fillMaxWidth()
            // Page-level geometry: the section label aligns to the page margin.
            // unverified geometry: the approval card's outer vertical margin reused
            // as the section's vertical breathing room; the spec has no page token
            // for that value.
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.geometry.cardOuterMarginV,
            )
            .semantics { heading() },
    )
}

/** A hairline divider; the stroke token is the only declared width. */
@Composable
internal fun SessionHairline(modifier: Modifier = Modifier) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(tokens.stroke.hairline)
            .background(tokens.colors.border),
    )
}

/** The dismiss glyph a failure line uses (labelled by [UiStrings.DISMISS]). */
internal const val DISMISS_GLYPH: String = "×"

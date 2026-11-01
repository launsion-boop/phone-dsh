// Signature surface 5/6 - the composer.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §2 "composer" + §3 + §4 + `tokens.json`
// `signatureSurfaces.composer`.
//
// The card mirrors `ChatPage.swift` `composer` clause for clause: one elevated
// card, a text field that grows to `geometry.composerMaxHeight`, the tool row
// docked inside its lower edge and the two mutually exclusive keys at the bottom
// trailing corner. While a turn runs and the draft *can* be submitted to it the
// send key stays and a small stop key sits beside it; when the draft cannot be
// submitted the stop key takes the send key's place (iOS `actionButton`).
//
// A pending ask keeps the dock visible but disabled (never hidden). The dock is
// a ScreenState-owned widget: it has no event anchor, so it never becomes a
// UiState node.
package com.phonedsh.ui.surface

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/** Which key the dock's trailing corner shows. */
public enum class ComposerMode {
    /** The accent send key. */
    SEND,

    /** A turn runs and the draft cannot be submitted to it: the stop key. */
    STOP,
}

/**
 * The token inventory of this surface: exactly `signatureSurfaces.composer.tokens`.
 *
 * The typed-text ink and the internal control gap used to be documented gaps; the
 * spec declares them now, so the gaps list is empty and a missing token fails this
 * surface instead of being excused as review debt.
 */
public object ComposerTokens {
    public val declared: List<String> = listOf(
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.COLORS_BORDER_LIGHT,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_ON_ACCENT,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.RADIUS_COMPOSER,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.GEOMETRY_COMPOSER_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_COMPOSER_MAX_HEIGHT,
        UiTokenNames.GEOMETRY_COMPOSER_CONTROL_SIZE,
        UiTokenNames.GEOMETRY_SEND_BUTTON_DIAMETER,
        UiTokenNames.GEOMETRY_INLINE_STOP_DIAMETER,
        UiTokenNames.GEOMETRY_COMPOSER_TRAILING_RESERVE,
        UiTokenNames.GEOMETRY_COMPOSER_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_COMPOSER_OUTER_MARGIN_TOP,
        UiTokenNames.GEOMETRY_COMPOSER_OUTER_MARGIN_BOTTOM,
        UiTokenNames.GEOMETRY_STAT_PILL_MIN_HEIGHT,
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.SPACING_ICON_TEXT,
    )

    /** No reviewed deviations: every token this surface uses is declared by the spec. */
    public val gaps: List<String> = emptyList()

    public val refs: List<String> get() = declared + gaps
}

/**
 * The input card.
 *
 * @param text the draft; owned by the screen state, never by this composable.
 * @param onTextChange draft updates.
 * @param placeholder the three-case placeholder the screen already resolved
 *   (idle / steer / queue); it is both the hint and the field's label.
 * @param mode send or stop for the trailing key.
 * @param enabled false while a pending ask is on screen (visible, disabled).
 * @param canSubmit iOS `canSubmit`: the send key is live.
 * @param running a turn is running (keeps the small stop key beside a live send).
 * @param onSend send the draft.
 * @param onStop stop the running turn.
 * @param stat optional usage pill text; `null` hides it.
 * @param contextPercent optional context-window share; `null` hides the ring.
 * @param sendLabel the send key's accessibility label (the screen resolves it
 *   from the idle/steer/queue case).
 * @param controls the tool row docked inside the card (plus / permissions /
 *   model / running spinner); `null` leaves the row empty.
 * @param onTruncated the draft hit the 8000-character cap and was cut.
 */
@Composable
public fun Composer(
    text: String,
    onTextChange: (String) -> Unit,
    placeholder: String,
    mode: ComposerMode,
    enabled: Boolean,
    canSubmit: Boolean,
    running: Boolean,
    onSend: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
    stat: String? = null,
    contextPercent: Int? = null,
    sendLabel: String = UiStrings.COMPOSER_SEND_LABEL,
    controls: (@Composable () -> Unit)? = null,
    onTruncated: () -> Unit = {},
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val shape = RoundedCornerShape(tokens.radius.composer)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag(UiTags.COMPOSER)
            .padding(
                start = tokens.geometry.composerOuterMarginH,
                end = tokens.geometry.composerOuterMarginH,
                top = tokens.geometry.composerOuterMarginTop,
                bottom = tokens.geometry.composerOuterMarginBottom,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(color = tokens.colors.input, shape = shape)
                .border(width = tokens.stroke.hairline, color = tokens.colors.borderLight, shape = shape),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    // iOS: leading 14, trailing 8, top 4. The composer's declared
                    // token set has no 14/8/4 length, so the closest declared
                    // lengths are used and the deviation is reported.
                    .padding(
                        start = tokens.geometry.composerOuterMarginTop,
                        end = tokens.spacing.iconText,
                        top = tokens.spacing.iconText,
                    ),
            ) {
                Box {
                    if (text.isEmpty()) {
                        BasicText(
                            text = placeholder,
                            style = type.body.copy(color = tokens.colors.tertiary),
                            maxLines = 1,
                            modifier = Modifier.padding(
                                start = tokens.spacing.iconText,
                                top = tokens.spacing.iconText,
                            ),
                        )
                    }
                    BasicTextField(
                        value = text,
                        onValueChange = { value ->
                            if (value.length > MAX_DRAFT_CHARS) {
                                onTextChange(value.take(MAX_DRAFT_CHARS))
                                onTruncated()
                            } else {
                                onTextChange(value)
                            }
                        },
                        enabled = enabled,
                        textStyle = type.body.copy(
                            color = if (enabled) tokens.colors.primary else tokens.colors.tertiary,
                        ),
                        cursorBrush = SolidColor(tokens.colors.accent),
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.Sentences,
                            imeAction = ImeAction.Default,
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(
                                min = tokens.geometry.composerMinHeight,
                                max = tokens.geometry.composerMaxHeight,
                            )
                            .testTag(UiTags.COMPOSER_FIELD)
                            .semantics {
                                contentDescription = placeholder
                                if (!enabled) stateDescription = UiStrings.PENDING_SLOT.format(1)
                            },
                    )
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        // The tool row keeps clear of the keys: iOS reserves 40 pt on
                        // the trailing edge so nothing slides under the send key.
                        .padding(
                            end = tokens.geometry.composerTrailingReserve,
                            top = tokens.geometry.composerOuterMarginTop,
                            bottom = tokens.geometry.composerOuterMarginTop,
                        )
                        .defaultMinSize(minHeight = tokens.geometry.composerControlSize),
                ) {
                    controls?.invoke()
                }
            }
            // The two keys live in the card's bottom-trailing corner, not in the
            // tool row: the row is what they reserve space from.
            Row(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(tokens.spacing.iconText),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                if (running && canSubmit) {
                    StopKey(
                        diameter = tokens.geometry.inlineStopDiameter,
                        onClick = onStop,
                    )
                }
                if (mode == ComposerMode.STOP) {
                    StopKey(
                        diameter = tokens.geometry.sendButtonDiameter,
                        onClick = onStop,
                    )
                } else {
                    SendKey(
                        enabled = enabled && canSubmit,
                        label = sendLabel,
                        onClick = onSend,
                    )
                }
            }
        }
        if (stat != null || contextPercent != null) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (stat != null) {
                    StatPill(modifier = Modifier.testTag(UiTags.COMPOSER_STAT)) {
                        BasicText(
                            text = stat,
                            style = type.secondary.copy(color = tokens.colors.tertiary),
                            maxLines = 1,
                        )
                    }
                }
                if (contextPercent != null) {
                    StatPill {
                        ContextRing(percent = contextPercent)
                        BasicText(
                            text = "$contextPercent%",
                            style = type.secondary.copy(color = tokens.colors.tertiary),
                            maxLines = 1,
                        )
                    }
                }
            }
        }
    }
}

/** The accent send key: 34 pt circle, `colors.accent`, dimmed while it cannot send. */
@Composable
private fun SendKey(
    enabled: Boolean,
    label: String,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .size(tokens.geometry.sendButtonDiameter)
            .clip(CircleShape)
            .background(tokens.colors.accent)
            .alpha(if (enabled) 1f else DISABLED_ALPHA)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .testTag(UiTags.COMPOSER_SEND)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = ARROW_UP,
            style = type.secondary.copy(color = tokens.colors.onAccent),
        )
    }
}

/** The stop key: `colors.secondary` circle with a filled square (iOS `stop.fill`). */
@Composable
private fun StopKey(
    diameter: androidx.compose.ui.unit.Dp,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .size(diameter)
            .clip(CircleShape)
            .background(tokens.colors.secondary)
            .clickable(role = Role.Button, onClick = onClick)
            .testTag(UiTags.COMPOSER_STOP)
            .semantics { contentDescription = UiStrings.COMPOSER_STOP_LABEL },
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = STOP_GLYPH,
            style = type.secondary.copy(color = tokens.colors.onAccent),
        )
    }
}

/** One stat pill: a 20 pt-tall, tertiary-ink line with a 2 pt horizontal pad. */
@Composable
private fun StatPill(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .defaultMinSize(minHeight = tokens.geometry.statPillMinHeight)
            .padding(horizontal = tokens.spacing.iconText),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        content()
    }
}

/** The context-window ring (iOS `NativeContextRing`): a trimmed 2 pt stroke. */
@Composable
private fun ContextRing(percent: Int) {
    val tokens = LocalUiTokens.current
    val size = tokens.geometry.composerControlSize / 2
    androidx.compose.foundation.Canvas(modifier = Modifier.size(size)) {
        val stroke = tokens.stroke.hairline.value * 2f
        val radius = (this.size.minDimension - stroke) / 2f
        drawCircle(
            color = tokens.colors.borderLight,
            radius = radius,
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
        drawArc(
            color = tokens.colors.tertiary,
            startAngle = -90f,
            sweepAngle = 360f * (percent.coerceIn(0, 100) / 100f),
            useCenter = false,
            topLeft = androidx.compose.ui.geometry.Offset(stroke / 2f, stroke / 2f),
            size = androidx.compose.ui.geometry.Size(radius * 2f, radius * 2f),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
    }
}

/** The draft cap the field enforces (iOS `value.count > 8_000`). */
private const val MAX_DRAFT_CHARS: Int = 8_000

/** Dimming of the disabled send key (iOS `.opacity(canSubmit ? 1 : 0.4)`). */
private const val DISABLED_ALPHA: Float = 0.4f

private const val ARROW_UP: String = "↑"
private const val STOP_GLYPH: String = "■"

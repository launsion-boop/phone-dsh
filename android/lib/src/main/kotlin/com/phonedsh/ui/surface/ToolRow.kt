// Signature surface 2/6 - the tool row.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §2 "工具行" + §4 + `tokens.json`
// `signatureSurfaces.toolRow`. The row is the *fold target*: the screen state
// merges consecutive call/result rows into one row (`ChatScreenState`), while
// every UiState node stays event-anchored.
package com.phonedsh.ui.surface

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

/** The four states the state machine can put a tool row in. */
public enum class ToolRowState {
    RUNNING,
    OK,
    ERROR,
    STOPPED,
    ;

    /** The state description announced to accessibility services. */
    public val label: String
        get() = when (this) {
            RUNNING -> UiStrings.TOOL_RUNNING
            OK -> UiStrings.TOOL_OK
            ERROR -> UiStrings.TOOL_ERROR
            STOPPED -> UiStrings.TOOL_STOPPED
        }
}

/**
 * The token inventory of this surface; exactly
 * `signatureSurfaces.toolRow.tokens`.
 *
 * Note: §2 asks for a sweep on a running summary. The declared list has no
 * `motion.shimmer`, so the sweep is not rendered here (the thinking pill owns
 * it); see the token-gap report.
 */
public object ToolRowTokens {
    public val refs: List<String> = listOf(
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_CODE,
        UiTokenNames.COLORS_CODE_BANNER,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.TYPOGRAPHY_CODE_LABEL,
        UiTokenNames.RADIUS_CODE_BLOCK,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.MOTION_DISCLOSURE,
        UiTokenNames.GEOMETRY_DISCLOSURE_ROW_HEIGHT,
        UiTokenNames.GEOMETRY_DISCLOSURE_ICON_GAP,
        UiTokenNames.GEOMETRY_TOOL_DETAIL_INDENT,
        UiTokenNames.GEOMETRY_TOOL_DETAIL_VERTICAL,
        UiTokenNames.GEOMETRY_TOOL_CARD_INSET,
        UiTokenNames.GEOMETRY_TERMINAL_CARD_MAX_HEIGHT,
    )
}

/**
 * One folded tool run.
 *
 * @param title tool name (the row's title).
 * @param summary one-line result summary.
 * @param state running / ok / error / stopped.
 * @param expanded whether the detail is open; only the screen state flips it.
 * @param onToggle expand/collapse; disabled when [detail] is `null`.
 * @param detail the expanded body; `null` means "nothing to show", which makes
 *   the toggle disabled instead of opening an empty card.
 */
@Composable
public fun ToolRow(
    title: String,
    summary: String,
    state: ToolRowState,
    expanded: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    detail: (@Composable () -> Unit)? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val chevronRotation by animateFloatAsState(
        targetValue = if (expanded) 90f else 0f,
        animationSpec = tween(tokens.motion.disclosureMs, easing = tokens.motion.disclosureEasing),
        label = "tool-row-chevron",
    )
    val canExpand = detail != null
    val summaryColor = if (state == ToolRowState.RUNNING) tokens.colors.tertiary else tokens.colors.secondary

    // The tag sits on the merged, clickable row: a semantics assertion on
    // `TOOL_ROW` must see the title, the summary, the state and the click action.
    Column(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = tokens.geometry.disclosureRowHeight)
                .clip(RoundedCornerShape(tokens.radius.codeBlock))
                .clickable(
                    enabled = canExpand,
                    role = Role.Button,
                    onClickLabel = if (expanded) UiStrings.COLLAPSED else UiStrings.EXPANDED,
                    onClick = onToggle,
                )
                .semantics(mergeDescendants = true) {
                    stateDescription = state.label
                    contentDescription = "$title · ${state.label}"
                }
                .testTag(UiTags.TOOL_ROW)
                .padding(horizontal = tokens.geometry.disclosureIconGap),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.geometry.disclosureIconGap),
        ) {
            BasicText(
                text = title,
                style = type.codeLabel.copy(color = tokens.colors.secondary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            BasicText(
                text = summary,
                style = type.secondary.copy(color = summaryColor),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = CHEVRON,
                style = type.codeLabel.copy(color = tokens.colors.tertiary),
                modifier = Modifier
                    .rotate(chevronRotation)
                    // Decorative: the row's own semantics carry the state.
                    .clearAndSetSemantics {},
            )
        }

        AnimatedVisibility(
            visible = expanded && canExpand,
            enter = expandVertically(
                animationSpec = tween(tokens.motion.disclosureMs, easing = tokens.motion.disclosureEasing),
            ) + fadeIn(tween(tokens.motion.disclosureMs, easing = tokens.motion.disclosureEasing)),
            exit = shrinkVertically(
                animationSpec = tween(tokens.motion.disclosureMs, easing = tokens.motion.disclosureEasing),
            ) + fadeOut(tween(tokens.motion.disclosureMs, easing = tokens.motion.disclosureEasing)),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(
                        start = tokens.geometry.toolDetailIndent,
                        top = tokens.geometry.toolDetailVertical,
                        bottom = tokens.geometry.toolDetailVertical,
                    )
                    .testTag(UiTags.TOOL_ROW_DETAIL),
            ) {
                detail?.invoke()
            }
        }
    }
}

/**
 * The expanded body of a tool row: a banner line plus a height-bounded,
 * vertically scrollable monospace card (`geometry.terminalCardMaxHeight`).
 */
@Composable
public fun ToolDetailCard(
    banner: String,
    body: String,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(tokens.radius.codeBlock))
            .background(tokens.colors.code)
            .border(
                width = tokens.stroke.hairline,
                color = tokens.colors.border,
                shape = RoundedCornerShape(tokens.radius.codeBlock),
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(tokens.colors.codeBanner)
                .padding(horizontal = tokens.geometry.toolCardInset, vertical = tokens.geometry.toolDetailVertical),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.geometry.disclosureIconGap),
        ) {
            BasicText(
                text = banner,
                style = type.codeLabel.copy(color = tokens.colors.secondary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        BasicText(
            text = body,
            style = type.code.copy(color = tokens.colors.secondary),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = tokens.geometry.terminalCardMaxHeight)
                .verticalScroll(rememberScrollState())
                .padding(tokens.geometry.toolCardInset),
        )
    }
}

private const val CHEVRON: String = "›"

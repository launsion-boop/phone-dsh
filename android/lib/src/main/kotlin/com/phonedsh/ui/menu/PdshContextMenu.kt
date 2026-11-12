// Long-press context menu: `combinedClickable` + an anchored `DropdownMenu`.
// SPDX-License-Identifier: MIT
//
// Spec authority: spec/ui/v1/interaction.md §3 rules 1-7. The visible rows,
// order, labels, roles and dividers all come from [ContextMenuModel]; this file
// only draws them and implements the close-before-action hand-off.
package com.phonedsh.ui.menu

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.PopupProperties
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** Stable tags for the shared menu, its rows and its contract divider. */
public object ContextMenuTags {
    public const val MENU: String = "pdsh.context-menu"
    public const val DIVIDER: String = "pdsh.context-menu.divider"

    /** One visible row, identified by its contract surface and token position. */
    public fun itemTag(surfaceId: String, order: Int): String =
        "pdsh.context-menu.$surfaceId.$order"
}

/**
 * Wraps one row in the long-press menu for [surfaceId] (rule 1).
 *
 * The [DropdownMenu] is composed inside the same `Box` as [content], so it is
 * anchored to the row that received the long press (rule 6); a tap still calls
 * [onClick] and never replaces the row's own action (rule 1).
 *
 * Selecting an action first closes the menu and then dispatches it from a
 * composition effect, so the menu is gone before the caller mutates state
 * (rule 7). A second selection before that dispatch is ignored, which keeps one
 * action per open. [ContextMenuItem.isInfo] rows have no click action.
 *
 * A [ContextMenuItem.isShare] row is handed to [onShare] so the caller can start
 * the system share sheet; when no share callback is supplied it falls back to
 * [onAction]. This component creates no Intent and registers no share target.
 *
 * @param surfaceId one of `interaction.contextMenu.surfaces[].id`.
 * @param state the row's `when` predicate set and hidden state.
 * @param onAction invoked for every selected `action`/`share` row after closing.
 * @param modifier applied to the row anchor, not to the popup.
 * @param onClick the row's normal tap action, if it has one.
 * @param onShare optional system-share-sheet callback for `share` rows.
 * @param interactionSource optional caller-owned source for this row's press
 *   and long-press interactions. When non-null it replaces the component's
 *   private source, so a page can render the row's §6 pressed state from the
 *   same stream instead of observing the pointer separately. `null` keeps the
 *   internal source and the previous behaviour for every existing caller.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
public fun PdshContextMenu(
    surfaceId: String,
    state: ContextMenuRowState,
    onAction: (ContextMenuItem) -> Unit,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    onShare: ((ContextMenuItem) -> Unit)? = null,
    interactionSource: MutableInteractionSource? = null,
    content: @Composable () -> Unit,
) {
    val items = ContextMenuModel.items(surfaceId, state)
    val session = remember(surfaceId) { ContextMenuSession() }
    var expanded by remember(surfaceId) { mutableStateOf(false) }
    var pending by remember(surfaceId) { mutableStateOf<ContextMenuItem?>(null) }
    val fallbackInteractionSource = remember { MutableInteractionSource() }
    val rowInteractionSource = interactionSource ?: fallbackInteractionSource
    val activePress = remember(rowInteractionSource) { mutableStateOf<PressInteraction.Press?>(null) }
    val latestOnAction by rememberUpdatedState(onAction)
    val latestOnShare by rememberUpdatedState(onShare)

    // The row owns the press stream, so the component itself clears the press
    // when a long press turns into the menu. Compose's tap detector cancels its
    // own internal gesture on a long press but does not cancel the public
    // interaction source; without this the caller's pressed fill would stay lit
    // until the finger lifts.
    LaunchedEffect(rowInteractionSource) {
        // No caller can observe the private fallback source, so it needs no
        // cancellation bookkeeping and keeps the previous behaviour exactly.
        if (interactionSource == null) return@LaunchedEffect
        rowInteractionSource.interactions.collect { interaction ->
            when (interaction) {
                is PressInteraction.Press -> activePress.value = interaction
                is PressInteraction.Release ->
                    if (activePress.value == interaction.press) activePress.value = null
                is PressInteraction.Cancel ->
                    if (activePress.value == interaction.press) activePress.value = null
                else -> Unit
            }
        }
    }

    // Rule 7: the selection closes the popup first. This effect starts after the
    // recomposition that removed the menu, then invokes exactly one action.
    LaunchedEffect(pending) {
        val selected = pending ?: return@LaunchedEffect
        pending = null
        when {
            selected.isInfo -> Unit
            selected.isShare && latestOnShare != null -> latestOnShare?.invoke(selected)
            else -> latestOnAction(selected)
        }
    }

    Box(
        modifier = modifier.combinedClickable(
            interactionSource = rowInteractionSource,
            indication = null,
            role = if (onClick != null) Role.Button else null,
            onClick = { onClick?.invoke() },
            onLongClick = {
                // An empty filtered menu is not a menu (rule 2): do not open an
                // empty popup for a surface whose every item is hidden.
                if (items.isNotEmpty() && session.open()) {
                    pending = null
                    expanded = true
                    activePress.value?.let { press ->
                        if (rowInteractionSource.tryEmit(PressInteraction.Cancel(press))) {
                            activePress.value = null
                        }
                    }
                }
            },
        ),
    ) {
        content()
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = {
                expanded = false
                session.dismiss()
            },
            modifier = Modifier.testTag(ContextMenuTags.MENU),
            properties = PopupProperties(focusable = true, clippingEnabled = true),
        ) {
            val tokens = LocalUiTokens.current
            val type = LocalUiType.current
            items.forEach { item ->
                if (item.dividerBefore) {
                    HorizontalDivider(Modifier.testTag(ContextMenuTags.DIVIDER))
                }
                if (item.isInfo) {
                    ContextMenuInfoRow(item, type.body, tokens.colors.textSecondary)
                } else {
                    DropdownMenuItem(
                        text = { Text(item.label, style = type.body) },
                        onClick = {
                            // Rule 7: close the session before the effect runs.
                            // A rapid second tap gets null and cannot dispatch a
                            // second action for this open.
                            val selected = session.select(item)
                            if (selected != null) {
                                expanded = false
                                pending = selected
                            }
                        },
                        colors = MenuDefaults.itemColors(
                            textColor = if (item.isDestructive) {
                                tokens.colors.danger
                            } else {
                                tokens.colors.textPrimary
                            },
                        ),
                        modifier = Modifier.testTag(
                            ContextMenuTags.itemTag(item.surfaceId, item.order),
                        ),
                    )
                }
            }
        }
    }
}

/**
 * Rule 4: `info` is an explanation row. It has no click semantics and no
 * selected state; the divider above it comes from the token table.
 */
@Composable
private fun ContextMenuInfoRow(
    item: ContextMenuItem,
    style: androidx.compose.ui.text.TextStyle,
    color: androidx.compose.ui.graphics.Color,
) {
    Text(
        text = item.label,
        style = style.copy(color = color),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .testTag(ContextMenuTags.itemTag(item.surfaceId, item.order)),
    )
}

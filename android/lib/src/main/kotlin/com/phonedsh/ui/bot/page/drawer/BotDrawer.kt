// The Bot roster drawer: ordering, live status/unread, the shared row context
// menu, create/rename/delete, set-primary and the management list.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotDrawer.swift` and
// `spec/ui/v1/pages/bot-drawer.md`. The roster order and the row status/unread
// rules are K3's (`BotRosterOrdering`, `BotUiStateDerivation.drawerStatus` /
// `unreadBadge`); this file only draws them and reports `BotDrawerIntent`.
// The panel reuses the shell drawer's geometry and gesture rules:
// `spec/ui/v1/tokens.json#interaction.drawer` through `UiTokens.drawer`, and
// `com.phonedsh.ui.nav.DrawerGesture` (the same pure rules `HomeDrawer.kt:475-518`
// and `PdshDrawer.kt:178-191` use).
package com.phonedsh.ui.bot.page.drawer

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.unit.dp
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.ui.bot.page.BotFishSlot
import com.phonedsh.ui.bot.page.appearance.BotAppearancePicker
import com.phonedsh.ui.bot.page.appearance.BotAppearanceTags
import com.phonedsh.ui.bot.state.BotAppearanceIntent
import com.phonedsh.ui.bot.state.BotDrawerIntent
import com.phonedsh.ui.bot.state.BotDrawerState
import com.phonedsh.ui.bot.state.BotDrawerStatusColor
import com.phonedsh.ui.bot.state.BotNameValidation
import com.phonedsh.ui.bot.state.BotRosterEntry
import com.phonedsh.ui.bot.state.BotRosterOrdering
import com.phonedsh.ui.bot.state.BotUiContext
import com.phonedsh.ui.bot.state.BotUiStateDerivation
import com.phonedsh.ui.bot.state.BotUiStateInput
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.menu.ContextMenuItem
import com.phonedsh.ui.menu.ContextMenuModel
import com.phonedsh.ui.menu.ContextMenuRowState
import com.phonedsh.ui.menu.PdshContextMenu
import com.phonedsh.ui.nav.DrawerGesture
import com.phonedsh.ui.nav.DrawerRelease
import com.phonedsh.ui.press.pillPressed
import com.phonedsh.ui.press.rowPressed
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.TokenContextMenuWhen
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The Bot tab's roster drawer.
 *
 * Values in, intents out: the host owns the roster, the selected Bot and every
 * write. [entries] is the full roster (hidden Bots included); the drawer shows
 * [BotRosterOrdering.visibleEntries] and the management list shows
 * [BotRosterOrdering.ordered].
 *
 * @param entries the host roster, insertion order.
 * @param selection the currently selected Bot id; `null` when nothing is.
 * @param onIntent one `BotDrawerActions` write (select/create/rename/…).
 * @param fish the host fish renderer, used for every row avatar.
 * @param now the clock for the relative-time status line; the page never reads
 *   the wall clock implicitly.
 * @param isOpen the host's open flag. Enter/exit use `tokens.motion.drawer*`;
 *   the drawer calls [onClose] once when the exit finishes or the scrim is hit.
 * @param error the host's roster/action failure; the row also shows a local
 *   rename validation message.
 * @param persistent true for a wide-screen sidebar: no dialog, no scrim.
 * @param onClose the host's close action; defaults to `BotDrawerIntent.Close`.
 */
@Composable
public fun BotDrawer(
    entries: List<BotRosterEntry>,
    selection: String?,
    onIntent: (BotDrawerIntent) -> Unit,
    fish: BotFishSlot,
    modifier: Modifier = Modifier,
    now: Long = System.currentTimeMillis(),
    isOpen: Boolean = true,
    error: String? = null,
    persistent: Boolean = false,
    onClose: () -> Unit = { onIntent(BotDrawerIntent.Close) },
) {
    val tokens = LocalUiTokens.current
    val drawer = tokens.drawer
    val panelShape = if (persistent) {
        RoundedCornerShape(0.dp)
    } else {
        RoundedCornerShape(
            topEnd = drawer.panelTrailingRadius,
            bottomEnd = drawer.panelTrailingRadius,
        )
    }

    if (persistent) {
        BotDrawerPanel(
            entries = entries,
            selection = selection,
            now = now,
            error = error,
            fish = fish,
            onIntent = onIntent,
            onClose = {},
            modifier = modifier.fillMaxHeight().width(drawer.width),
            shape = panelShape,
        )
        return
    }

    val closedOffset = drawer.closedOffset.value
    var visible by remember { mutableStateOf(isOpen) }
    var panelOffset by remember { mutableFloatStateOf(if (isOpen) 0f else closedOffset) }
    var closing by remember { mutableStateOf(false) }
    var notified by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val latestClose by rememberUpdatedState(onClose)

    suspend fun moveTo(target: Float, durationMs: Int, easing: Easing) {
        animate(
            initialValue = panelOffset,
            targetValue = target,
            animationSpec = tween(durationMillis = durationMs, easing = easing),
        ) { value, _ -> panelOffset = value }
    }

    fun requestClose() {
        if (closing || !visible) return
        closing = true
        scope.launch {
            moveTo(closedOffset, tokens.motion.drawerCloseMs, tokens.motion.drawerCloseEasing)
            visible = false
            closing = false
            if (!notified) {
                notified = true
                latestClose()
            }
        }
    }

    // Open from the closed overhang; close only after the token motion ends
    // (`HomeDrawer.kt:290-324`).
    LaunchedEffect(isOpen) {
        if (isOpen) {
            notified = false
            closing = false
            visible = true
            moveTo(0f, tokens.motion.drawerOpenMs, tokens.motion.drawerOpenEasing)
        } else if (visible && !closing) {
            closing = true
            moveTo(closedOffset, tokens.motion.drawerCloseMs, tokens.motion.drawerCloseEasing)
            visible = false
            closing = false
            if (!notified) {
                notified = true
                latestClose()
            }
        }
    }

    if (!visible && !isOpen) return

    // The overlay is a plain full-size layer, the same shape `PdshDrawer` uses
    // (`PdshDrawer.kt:174-236`): the Bot page mounts it last, so it covers the
    // page without starting a second window. A popup menu inside a `Dialog`
    // window would be positioned by the activity token and not by this layer.
    BackHandler(enabled = visible) { requestClose() }
    BoxWithConstraints(
        modifier.fillMaxSize().semantics {
            paneTitle = BotDrawerCopy.PANEL_LABEL
            isTraversalGroup = true
        },
    ) {
        // 320 pt, but a narrow window keeps a page strip visible
        // (`PdshDrawer.kt:174-179`).
        val panelWidth = minOf(drawer.width, maxWidth - BotDrawerMetrics.MIN_PAGE_STRIP)
        // Panel + page strip, the same two-column geometry `PdshDrawer.kt:179-235`
        // uses: the strip is the scrim and can never steal a panel hit.
        Row(Modifier.fillMaxSize()) {
            BotDrawerPanel(
                entries = entries,
                selection = selection,
                now = now,
                error = error,
                fish = fish,
                onIntent = onIntent,
                onClose = ::requestClose,
                modifier = Modifier
                    .width(panelWidth)
                    .fillMaxHeight()
                    .offset { IntOffset(panelOffset.dp.roundToPx(), 0) }
                    .shadow(elevation = tokens.shadow.drawerRadius, shape = panelShape)
                    .clip(panelShape)
                    .pointerInput(drawer) {
                        botDrawerDrag(
                            dragMinimumDistance = drawer.dragMinimumDistance,
                            initialOffset = { panelOffset },
                            onOffset = { if (!closing) panelOffset = it },
                            onRelease = { dx, velocity ->
                                if (!closing) {
                                    when (DrawerGesture.release(dx, velocity)) {
                                        DrawerRelease.Close -> requestClose()
                                        DrawerRelease.Settle -> scope.launch {
                                            moveTo(
                                                0f,
                                                tokens.motion.drawerSettleMs,
                                                tokens.motion.drawerSettleEasing,
                                            )
                                        }
                                    }
                                }
                            },
                        )
                    },
                shape = panelShape,
            )
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .background(Color.Black.copy(alpha = DrawerGesture.scrimAlpha(panelOffset)))
                    .pointerInput(drawer) {
                        botDrawerDrag(
                            dragMinimumDistance = drawer.dragMinimumDistance,
                            initialOffset = { panelOffset },
                            onOffset = { if (!closing) panelOffset = it },
                            onRelease = { dx, velocity ->
                                if (!closing) {
                                    when (DrawerGesture.release(dx, velocity)) {
                                        DrawerRelease.Close -> requestClose()
                                        DrawerRelease.Settle -> scope.launch {
                                            moveTo(
                                                0f,
                                                tokens.motion.drawerSettleMs,
                                                tokens.motion.drawerSettleEasing,
                                            )
                                        }
                                    }
                                }
                            },
                            onTap = ::requestClose,
                        )
                    }
                    .semantics {
                        contentDescription = "关闭抽屉"
                        role = Role.Button
                        onClick(label = "关闭抽屉") { requestClose(); true }
                    }
                    .testTag(BotDrawerTags.SCRIM),
            )
        }
    }
}

/**
 * The panel body, shared by the phone drawer and the persistent sidebar.
 *
 * The local state is only presentation: which dialog is open and the local
 * validation message. Every mutation is reported through [onIntent].
 */
@Composable
private fun BotDrawerPanel(
    entries: List<BotRosterEntry>,
    selection: String?,
    now: Long,
    error: String?,
    fish: BotFishSlot,
    onIntent: (BotDrawerIntent) -> Unit,
    onClose: () -> Unit,
    modifier: Modifier,
    shape: androidx.compose.ui.graphics.Shape,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val lastBot = entries.size <= 1
    val visibleEntries = remember(entries) { BotRosterOrdering.visibleEntries(entries) }
    val managedEntries = remember(entries) { BotRosterOrdering.ordered(entries) }
    val scrollState = rememberScrollState()

    var showingAdd by remember { mutableStateOf(false) }
    var renameEntry by remember { mutableStateOf<BotRosterEntry?>(null) }
    var deleteEntry by remember { mutableStateOf<BotRosterEntry?>(null) }
    var showingManage by remember { mutableStateOf(false) }
    var actionError by remember { mutableStateOf<String?>(null) }

    fun choose(entry: BotRosterEntry, item: ContextMenuItem) {
        when (botRowMenuAction(item)) {
            BotRowMenuAction.Rename -> { actionError = null; renameEntry = entry }
            BotRowMenuAction.Appearance -> onIntent(BotDrawerIntent.Appearance(entry.id))
            BotRowMenuAction.SetMain -> onIntent(BotDrawerIntent.SetMain(entry.id))
            BotRowMenuAction.Hide -> onIntent(BotDrawerIntent.SetHidden(entry.id, !entry.isHidden))
            BotRowMenuAction.Delete -> {
                // The last-Bot guard is both the token table's info row and this
                // defensive handler (`ui-state.md` §3.2, `BotDrawer.swift:492-496`).
                if (lastBot) {
                    actionError = BotUiStrings.DRAWER_MENU_LASTBOT
                } else {
                    deleteEntry = entry
                }
            }
            null -> Unit
        }
    }

    Column(
        modifier = modifier
            .background(tokens.colors.page, shape)
            .windowInsetsPadding(WindowInsets.statusBars.only(WindowInsetsSides.Top))
            .focusGroup()
            .customBotDrawerActions(onClose)
            .semantics {
                paneTitle = BotDrawerCopy.PANEL_LABEL
                isTraversalGroup = true
            }
            .testTag(BotDrawerTags.PANEL),
    ) {
        Column(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(scrollState)
                .padding(
                    top = tokens.geometry.pageHeaderMinHeight,
                    bottom = drawerNavigationBarInset() + BotDrawerMetrics.CHROME_INSET,
                ),
        ) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(BotDrawerMetrics.HEADER_HEIGHT)
                    .padding(
                        start = BotDrawerMetrics.CHROME_INSET,
                        end = BotDrawerMetrics.HEADER_TRAILING_INSET,
                    ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(
                    text = BotUiStrings.DRAWER_TITLE,
                    style = type.body.copy(
                        fontSize = BotDrawerMetrics.TITLE_SIZE,
                        fontWeight = FontWeight.SemiBold,
                        color = tokens.colors.textPrimary,
                    ),
                    modifier = Modifier.semantics { heading() },
                )
                Spacer(Modifier.weight(1f))
                Box(
                    Modifier
                        .size(BotDrawerMetrics.HEADER_ACTION)
                        .clickable(role = Role.Button, onClick = {
                            actionError = null
                            showingManage = true
                            onIntent(BotDrawerIntent.Manage)
                        })
                        .semantics { contentDescription = BotUiStrings.DRAWER_MANAGE }
                        .testTag(BotDrawerTags.MANAGE),
                    contentAlignment = Alignment.Center,
                ) {
                    PdshIconView(
                        PdshIcon.MORE,
                        BotDrawerMetrics.MANAGE_ICON,
                        tokens.colors.textSecondary,
                        null,
                    )
                }
            }

            BotAddPill(onClick = {
                actionError = null
                showingAdd = true
            })

            val message = error ?: actionError
            if (message != null) {
                BotDrawerErrorRow(
                    message = message,
                    onRetry = {
                        actionError = null
                        onIntent(BotDrawerIntent.Retry)
                    },
                )
            }

            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = BotDrawerMetrics.ROW_LIST_INSET)
                    .padding(top = BotDrawerMetrics.ROWS_TOP_GAP),
                verticalArrangement = Arrangement.spacedBy(BotDrawerMetrics.ROW_GAP),
            ) {
                visibleEntries.forEach { entry ->
                    BotDrawerRow(
                        entry = entry,
                        selected = selection == entry.id,
                        lastBot = lastBot,
                        now = now,
                        fish = fish,
                        onClick = {
                            onIntent(BotDrawerIntent.Select(entry.id))
                            onClose()
                        },
                        onMenuAction = { choose(entry, it) },
                    )
                }
            }

            if (visibleEntries.isEmpty()) {
                BasicText(
                    text = BotUiStrings.DRAWER_EMPTY,
                    style = type.caption.copy(
                        fontSize = BotDrawerMetrics.CAPTION_SIZE,
                        color = tokens.colors.textPlaceholder,
                    ),
                    modifier = Modifier
                        .padding(horizontal = BotDrawerMetrics.CHROME_INSET)
                        .padding(top = BotDrawerMetrics.CHROME_INSET)
                        .testTag(BotDrawerTags.EMPTY),
                )
            }
        }
    }

    if (showingAdd) {
        BotAddDialog(
            fish = fish,
            onDismiss = { showingAdd = false },
            onCreate = { name, color, hairstyle ->
                showingAdd = false
                actionError = null
                onIntent(BotDrawerIntent.Create(name, color, hairstyle))
            },
        )
    }

    renameEntry?.let { entry ->
        BotRenameDialog(
            entry = entry,
            onDismiss = { renameEntry = null },
            onSave = { name ->
                val problem = BotNameValidation.problem(name)
                if (problem != null) {
                    actionError = problem
                } else {
                    renameEntry = null
                    actionError = null
                    onIntent(BotDrawerIntent.Rename(entry.id, BotNameValidation.trimmed(name)))
                }
            },
        )
    }

    deleteEntry?.let { entry ->
        BotDeleteDialog(
            entry = entry,
            onDismiss = { deleteEntry = null },
            onConfirm = {
                deleteEntry = null
                actionError = null
                onIntent(BotDrawerIntent.Delete(entry.id))
            },
        )
    }

    if (showingManage) {
        BotManageList(
            entries = managedEntries,
            lastBot = lastBot,
            fish = fish,
            onDismiss = { showingManage = false },
            onMenuAction = ::choose,
            onAppearance = { entry ->
                showingManage = false
                onIntent(BotDrawerIntent.Appearance(entry.id))
            },
        )
    }
}

@Composable
private fun BotAddPill(onClick: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val interaction = remember { MutableInteractionSource() }
    val shape = RoundedCornerShape(BotDrawerMetrics.ADD_PILL_RADIUS)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = BotDrawerMetrics.CHROME_INSET)
            .padding(top = BotDrawerMetrics.ADD_PILL_TOP_GAP)
            .height(BotDrawerMetrics.ADD_PILL_HEIGHT)
            .clip(shape)
            .background(tokens.colors.surface, shape)
            .border(BotDrawerMetrics.HAIRLINE, tokens.colors.borderList, shape)
            .pillPressed(interaction)
            .clickable(
                interactionSource = interaction,
                indication = null,
                role = Role.Button,
                onClick = onClick,
            )
            .semantics { contentDescription = BotUiStrings.DRAWER_ADD }
            .testTag(BotDrawerTags.ADD),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BotDrawerMetrics.ROW_SPACING),
        ) {
            PdshIconView(
                PdshIcon.PLUS,
                BotDrawerMetrics.ADD_ICON,
                tokens.colors.textPrimary,
                null,
            )
            BasicText(
                text = BotUiStrings.DRAWER_ADD,
                style = type.body.copy(
                    fontSize = BotDrawerMetrics.ADD_LABEL_SIZE,
                    fontWeight = FontWeight.Medium,
                    color = tokens.colors.textPrimary,
                ),
            )
        }
    }
}

@Composable
private fun BotDrawerErrorRow(message: String, onRetry: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = BotDrawerMetrics.CHROME_INSET)
            .padding(top = BotDrawerMetrics.ROW_VERTICAL_PADDING)
            .semantics { liveRegion = LiveRegionMode.Polite }
            .testTag(BotDrawerTags.ERROR),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BotDrawerMetrics.ROW_SPACING),
    ) {
        BasicText(
            text = message,
            style = type.caption.copy(
                fontSize = BotDrawerMetrics.CAPTION_SIZE,
                color = tokens.colors.danger,
            ),
            modifier = Modifier.weight(1f),
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        BasicText(
            text = UiStrings.RETRY,
            style = type.secondary.copy(color = tokens.colors.textPrimary),
            modifier = Modifier
                .clickable(role = Role.Button, onClick = onRetry)
                .semantics { contentDescription = UiStrings.RETRY }
                .testTag(BotDrawerTags.RETRY)
                .padding(vertical = BotDrawerMetrics.ROW_VERTICAL_PADDING),
        )
    }
}

@Composable
private fun BotDrawerRow(
    entry: BotRosterEntry,
    selected: Boolean,
    lastBot: Boolean,
    now: Long,
    fish: BotFishSlot,
    onClick: () -> Unit,
    onMenuAction: (ContextMenuItem) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val status = remember(entry, now) { botDrawerStatus(entry, now) }
    val badge = remember(entry.unreadCount) {
        BotUiStateDerivation.unreadBadge(entry.unreadCount)
    }
    val menuState = remember(entry, lastBot) {
        ContextMenuRowState.of(
            TokenContextMenuWhen.ALWAYS to true,
            TokenContextMenuWhen.NOT_MAIN_BOT to !entry.isMainBot,
            TokenContextMenuWhen.NOT_LAST_BOT to !lastBot,
            TokenContextMenuWhen.LAST_BOT to lastBot,
            botHidden = entry.isHidden,
        )
    }
    val interaction = remember(entry.id) { MutableInteractionSource() }
    val rowShape = RoundedCornerShape(BotDrawerMetrics.ROW_RADIUS)
    val description = buildString {
        append(entry.name)
        if (entry.isMainBot) append("，").append(BotDrawerCopy.MAIN_BOT)
        append("，").append(status.text)
        if (badge.shown) append("，").append(badge.accessibility)
    }

    PdshContextMenu(
        surfaceId = BOT_ROW_SURFACE,
        state = menuState,
        onAction = onMenuAction,
        interactionSource = interaction,
        modifier = Modifier.fillMaxWidth().testTag(BotDrawerTags.row(entry.id)),
        onClick = onClick,
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .height(BotDrawerMetrics.ROW_HEIGHT)
                .clip(rowShape)
                .background(if (selected) tokens.colors.userBubble else Color.Transparent)
                .rowPressed(interaction, shape = rowShape)
                .padding(horizontal = BotDrawerMetrics.ROW_INNER_INSET)
                .semantics {
                    contentDescription = description
                    this.selected = selected
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BotDrawerMetrics.ROW_SPACING),
        ) {
            // The fish is decorative here: the row description already names the
            // Bot, its status and its unread count (`BotDrawer.swift:424-426`).
            fish(
                entry.fishState,
                entry.appearance,
                entry.isMainBot,
                BotDrawerMetrics.ROW_FISH,
                false,
                Modifier,
            )
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(BotDrawerMetrics.ROW_TEXT_GAP),
            ) {
                BasicText(
                    text = entry.name,
                    style = type.body.copy(
                        fontSize = BotDrawerMetrics.NAME_SIZE,
                        fontWeight = FontWeight.SemiBold,
                        color = tokens.colors.textPrimary,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                BasicText(
                    text = status.text,
                    style = type.caption.copy(
                        fontSize = BotDrawerMetrics.STATUS_SIZE,
                        color = if (status.color == BotDrawerStatusColor.WARNING) {
                            tokens.colors.warning
                        } else {
                            tokens.colors.textSecondary
                        },
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (badge.shown) {
                Box(
                    Modifier
                        .height(BotDrawerMetrics.UNREAD_MIN_SIZE)
                        .widthIn(min = BotDrawerMetrics.UNREAD_MIN_SIZE)
                        .clip(CircleShape)
                        .background(tokens.colors.danger)
                        .padding(horizontal = BotDrawerMetrics.UNREAD_PADDING_H)
                        .semantics { contentDescription = badge.accessibility }
                        .testTag(BotDrawerTags.unread(entry.id)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = badge.text,
                        style = type.caption.copy(
                            fontSize = BotDrawerMetrics.UNREAD_SIZE,
                            fontWeight = FontWeight.SemiBold,
                            color = tokens.colors.primaryButtonInk,
                        ),
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

@Composable
private fun BotManageList(
    entries: List<BotRosterEntry>,
    lastBot: Boolean,
    fish: BotFishSlot,
    onDismiss: () -> Unit,
    onMenuAction: (BotRosterEntry, ContextMenuItem) -> Unit,
    onAppearance: (BotRosterEntry) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .widthIn(max = BotDrawerMetrics.DIALOG_MAX_WIDTH)
                .fillMaxWidth()
                .background(tokens.colors.page, RoundedCornerShape(BotDrawerMetrics.DIALOG_RADIUS))
                .padding(vertical = BotDrawerMetrics.DIALOG_PADDING)
                .testTag(BotDrawerTags.MANAGE_PANEL),
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = BotDrawerMetrics.DIALOG_PADDING),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(
                    text = BotDrawerCopy.MANAGE_TITLE,
                    style = type.headline.copy(color = tokens.colors.textPrimary),
                    modifier = Modifier.weight(1f).semantics { heading() },
                )
                BasicText(
                    text = BotDrawerCopy.MANAGE_DONE,
                    style = type.secondary.copy(color = tokens.colors.textPrimary),
                    modifier = Modifier
                        .clickable(role = Role.Button, onClick = onDismiss)
                        .semantics { contentDescription = BotDrawerCopy.MANAGE_DONE }
                        .testTag(BotDrawerTags.MANAGE_DONE)
                        .padding(horizontal = BotDrawerMetrics.ROW_VERTICAL_PADDING),
                )
            }
            BasicText(
                text = BotDrawerCopy.MANAGE_SECTION,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
                modifier = Modifier
                    .padding(horizontal = BotDrawerMetrics.DIALOG_PADDING)
                    .padding(top = BotDrawerMetrics.CHROME_INSET)
                    .semantics { heading() },
            )
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = BotDrawerMetrics.ROW_LIST_INSET),
            ) {
                entries.forEach { entry ->
                    BotManageRow(
                        entry = entry,
                        lastBot = lastBot,
                        fish = fish,
                        onMenuAction = { onMenuAction(entry, it) },
                        onAppearance = { onAppearance(entry) },
                    )
                }
            }
        }
    }
}

@Composable
private fun BotManageRow(
    entry: BotRosterEntry,
    lastBot: Boolean,
    fish: BotFishSlot,
    onMenuAction: (ContextMenuItem) -> Unit,
    onAppearance: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val menuState = remember(entry, lastBot) {
        ContextMenuRowState.of(
            TokenContextMenuWhen.ALWAYS to true,
            TokenContextMenuWhen.NOT_MAIN_BOT to !entry.isMainBot,
            TokenContextMenuWhen.NOT_LAST_BOT to !lastBot,
            TokenContextMenuWhen.LAST_BOT to lastBot,
            botHidden = entry.isHidden,
        )
    }
    val interaction = remember(entry.id) { MutableInteractionSource() }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = BotDrawerMetrics.MANAGE_ROW_INSET)
            .padding(vertical = BotDrawerMetrics.ROW_VERTICAL_PADDING)
            .testTag(BotDrawerTags.manageRow(entry.id)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BotDrawerMetrics.ROW_SPACING),
    ) {
        fish(
            entry.fishState,
            entry.appearance,
            entry.isMainBot,
            BotDrawerMetrics.MANAGE_FISH,
            true,
            Modifier,
        )
        Column(Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BotDrawerMetrics.ROW_TEXT_GAP),
            ) {
                BasicText(
                    text = entry.name,
                    style = type.body.copy(
                        fontSize = BotDrawerMetrics.NAME_SIZE,
                        fontWeight = FontWeight.SemiBold,
                        color = tokens.colors.textPrimary,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (entry.isMainBot) {
                    BasicText(
                        text = BotDrawerCopy.MAIN_BOT,
                        style = type.caption.copy(
                            fontSize = BotDrawerMetrics.UNREAD_SIZE,
                            color = tokens.colors.warning,
                        ),
                    )
                }
                if (entry.isHidden) {
                    Box(
                        Modifier
                            .height(BotDrawerMetrics.HIDDEN_CHIP_HEIGHT)
                            .clip(CircleShape)
                            .background(tokens.colors.userBubble)
                            .padding(horizontal = BotDrawerMetrics.HIDDEN_CHIP_PADDING_H),
                        contentAlignment = Alignment.Center,
                    ) {
                        BasicText(
                            text = BotDrawerCopy.HIDDEN,
                            style = type.caption.copy(
                                fontSize = BotDrawerMetrics.UNREAD_SIZE,
                                color = tokens.colors.textSecondary,
                            ),
                        )
                    }
                }
            }
            BasicText(
                text = entry.description.ifBlank { BotDrawerCopy.NO_DESCRIPTION },
                style = type.caption.copy(
                    fontSize = BotDrawerMetrics.MANAGE_DESCRIPTION_SIZE,
                    color = tokens.colors.textSecondary,
                ),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        PdshContextMenu(
            surfaceId = BOT_ROW_SURFACE,
            state = menuState,
            onAction = { item ->
                // The appearance row also closes the management list, matching
                // `BotDrawer.swift:625-628`; every other row is the shared action.
                if (botRowMenuAction(item) == BotRowMenuAction.Appearance) {
                    onAppearance()
                } else {
                    onMenuAction(item)
                }
            },
            interactionSource = interaction,
            modifier = Modifier.testTag(BotDrawerTags.manageMenu(entry.id)),
            onClick = null,
        ) {
            Box(
                Modifier
                    .size(BotDrawerMetrics.HEADER_ACTION)
                    .rowPressed(interaction, shape = CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(
                    PdshIcon.MORE,
                    BotDrawerMetrics.MANAGE_ICON,
                    tokens.colors.textSecondary,
                    null,
                )
            }
        }
    }
}

@Composable
private fun BotAddDialog(
    fish: BotFishSlot,
    onDismiss: () -> Unit,
    onCreate: (String, BotFishColor, BotFishHairstyle) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var name by remember { mutableStateOf("") }
    var color by remember { mutableStateOf(BotFishColor.BLUE) }
    var hairstyle by remember { mutableStateOf(BotFishHairstyle.LONG) }
    var error by remember { mutableStateOf<String?>(null) }
    val appearance = BotFishAppearance(color, hairstyle, autoColor = false, autoHairstyle = false)
    val valid = BotNameValidation.isValid(name)

    BotDialogCard(
        tag = BotDrawerTags.ADD_PANEL,
        title = BotDrawerCopy.ADD_TITLE,
        onDismiss = onDismiss,
    ) {
        Box(
            Modifier.fillMaxWidth().testTag(BotDrawerTags.ADD_PREVIEW),
            contentAlignment = Alignment.Center,
        ) {
            fish(BotFishLifecycle.IDLE, appearance, false, BotDrawerMetrics.ADD_PREVIEW, true, Modifier)
        }
        BasicText(
            text = BotDrawerCopy.NAME_SECTION,
            style = type.secondary.copy(color = tokens.colors.textSecondary),
        )
        BotNameField(
            value = name,
            onValueChange = { name = BotNameValidation.capped(it) },
            placeholder = BotDrawerCopy.NAME_PLACEHOLDER,
            tag = BotDrawerTags.ADD_NAME,
            clearTag = BotDrawerTags.ADD_NAME_CLEAR,
            clearLabel = BotDrawerCopy.CLEAR_NAME,
        )
        BotAppearancePicker(
            appearance = appearance,
            onIntent = { intent ->
                when (intent) {
                    is BotAppearanceIntent.SelectColor -> color = intent.color
                    is BotAppearanceIntent.SelectHairstyle -> hairstyle = intent.hairstyle
                    is BotAppearanceIntent.Rename -> Unit
                }
            },
            fish = fish,
            identifierPrefix = BotAppearanceTags.ADD_PREFIX,
            showsPreview = false,
        )
        if (error != null) {
            BasicText(
                text = error.orEmpty(),
                style = type.caption.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .semantics { liveRegion = LiveRegionMode.Polite }
                    .testTag(BotDrawerTags.ADD_ERROR),
            )
        }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = UiStrings.CANCEL,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onDismiss)
                    .semantics { contentDescription = UiStrings.CANCEL }
                    .testTag(BotDrawerTags.ADD_CANCEL)
                    .padding(BotDrawerMetrics.ROW_VERTICAL_PADDING),
            )
            BasicText(
                text = BotUiStrings.DRAWER_CREATE,
                style = type.secondary.copy(
                    color = if (valid) tokens.colors.primaryButton else tokens.colors.textTertiary,
                ),
                modifier = Modifier
                    .clickable(enabled = valid, role = Role.Button, onClick = {
                        val problem = BotNameValidation.problem(name)
                        if (problem != null) {
                            error = problem
                            return@clickable
                        }
                        onCreate(BotNameValidation.trimmed(name), color, hairstyle)
                    })
                    .semantics { contentDescription = BotUiStrings.DRAWER_CREATE }
                    .testTag(BotDrawerTags.ADD_CREATE)
                    .padding(BotDrawerMetrics.ROW_VERTICAL_PADDING),
            )
        }
    }
}

@Composable
private fun BotRenameDialog(
    entry: BotRosterEntry,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var name by remember(entry.id) {
        mutableStateOf(BotNameValidation.capped(entry.name))
    }
    var error by remember(entry.id) { mutableStateOf<String?>(null) }

    BotDialogCard(
        tag = BotDrawerTags.RENAME_PANEL,
        title = BotDrawerCopy.RENAME_TITLE,
        onDismiss = onDismiss,
    ) {
        BotNameField(
            value = name,
            onValueChange = {
                error = null
                name = BotNameValidation.capped(it)
            },
            placeholder = BotDrawerCopy.NAME_LABEL,
            tag = BotDrawerTags.RENAME_FIELD,
            clearTag = null,
            clearLabel = null,
        )
        if (error != null) {
            BasicText(
                text = error.orEmpty(),
                style = type.caption.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .semantics { liveRegion = LiveRegionMode.Polite }
                    .testTag(BotDrawerTags.RENAME_ERROR),
            )
        }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
        ) {
            BasicText(
                text = UiStrings.CANCEL,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onDismiss)
                    .testTag(BotDrawerTags.RENAME_CANCEL)
                    .padding(BotDrawerMetrics.ROW_VERTICAL_PADDING),
            )
            BasicText(
                text = BotDrawerCopy.SAVE,
                style = type.secondary.copy(color = tokens.colors.primaryButton),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = {
                        val problem = BotNameValidation.problem(name)
                        if (problem != null) {
                            error = problem
                        } else {
                            onSave(name)
                        }
                    })
                    .testTag(BotDrawerTags.RENAME_SAVE)
                    .padding(BotDrawerMetrics.ROW_VERTICAL_PADDING),
            )
        }
    }
}

@Composable
private fun BotDeleteDialog(
    entry: BotRosterEntry,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BotDialogCard(
        tag = BotDrawerTags.DELETE_PANEL,
        title = BotDrawerCopy.format(BotDrawerCopy.DELETE_TITLE, "name" to entry.name),
        onDismiss = onDismiss,
    ) {
        BasicText(
            text = BotUiStrings.DRAWER_DELETE_CONFIRM,
            style = type.secondary.copy(color = tokens.colors.textSecondary),
            modifier = Modifier.testTag(BotDrawerTags.DELETE_MESSAGE),
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            BasicText(
                text = UiStrings.CANCEL,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onDismiss)
                    .testTag(BotDrawerTags.DELETE_CANCEL)
                    .padding(BotDrawerMetrics.ROW_VERTICAL_PADDING),
            )
            BasicText(
                text = BotDrawerCopy.DELETE_ACTION,
                style = type.secondary.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onConfirm)
                    .testTag(BotDrawerTags.DELETE_CONFIRM)
                    .padding(BotDrawerMetrics.ROW_VERTICAL_PADDING),
            )
        }
    }
}

@Composable
private fun BotDialogCard(
    tag: String,
    title: String,
    onDismiss: () -> Unit,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .widthIn(max = BotDrawerMetrics.DIALOG_MAX_WIDTH)
                .background(
                    tokens.colors.surface,
                    RoundedCornerShape(BotDrawerMetrics.DIALOG_RADIUS),
                )
                .focusRequester(focus)
                .padding(BotDrawerMetrics.DIALOG_PADDING)
                .testTag(tag),
            verticalArrangement = Arrangement.spacedBy(BotDrawerMetrics.DIALOG_BODY_GAP),
        ) {
            BasicText(
                text = title,
                style = type.headline.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.semantics { heading() },
            )
            content()
        }
    }
}

@Composable
private fun BotNameField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    tag: String,
    clearTag: String?,
    clearLabel: String?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val shape = RoundedCornerShape(BotDrawerMetrics.NAME_FIELD_RADIUS)
    Box(Modifier.fillMaxWidth()) {
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = type.body.copy(color = tokens.colors.textPrimary),
            cursorBrush = SolidColor(tokens.colors.primaryButton),
            modifier = Modifier
                .fillMaxWidth()
                .height(BotDrawerMetrics.NAME_FIELD_HEIGHT)
                .background(tokens.colors.surface, shape)
                .border(BotDrawerMetrics.HAIRLINE, tokens.colors.borderList, shape)
                .padding(start = BotDrawerMetrics.ROW_VERTICAL_PADDING)
                .padding(end = BotDrawerMetrics.NAME_FIELD_TRAILING)
                .semantics { contentDescription = placeholder }
                .testTag(tag),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (value.isEmpty()) {
                        BasicText(
                            text = placeholder,
                            style = type.body.copy(color = tokens.colors.textPlaceholder),
                        )
                    }
                    inner()
                }
            },
        )
        if (value.isNotEmpty() && clearTag != null) {
            Box(
                Modifier
                    .align(Alignment.CenterEnd)
                    .size(BotDrawerMetrics.CLEAR_BUTTON)
                    .clickable(role = Role.Button, onClick = { onValueChange("") })
                    .semantics {
                        contentDescription = clearLabel ?: BotDrawerCopy.CLEAR_NAME
                    }
                    .testTag(clearTag),
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(
                    PdshIcon.CLOSE,
                    BotDrawerMetrics.MANAGE_ICON,
                    tokens.colors.textTertiary,
                    null,
                )
            }
        }
    }
}

/** The action a visible `botRow` menu item maps to; order comes from the token table. */
private enum class BotRowMenuAction { Rename, Appearance, SetMain, Hide, Delete }

private fun botRowMenuAction(item: ContextMenuItem): BotRowMenuAction? = when (item.order) {
    // `interaction.contextMenu.surfaces[botRow]` fixes this order:
    // 改名, 外观, 设为主 Bot, 隐藏/取消隐藏, 删除 Bot, 最后一个 Bot 的说明行.
    0 -> BotRowMenuAction.Rename
    1 -> BotRowMenuAction.Appearance
    2 -> BotRowMenuAction.SetMain
    3 -> BotRowMenuAction.Hide
    4 -> BotRowMenuAction.Delete
    else -> null
}

/** The row status is K3's rule, fed with this roster row only. */
private fun botDrawerStatus(entry: BotRosterEntry, now: Long) =
    BotUiStateDerivation.drawerStatus(
        BotUiStateInput(
            context = BotUiContext(botID = entry.id, botName = entry.name),
            rows = emptyList(),
            now = now,
            drawer = BotDrawerState(
                isRunning = entry.isRunning,
                lastMessageAt = entry.lastMessageAt,
                unreadCount = entry.unreadCount,
                activity = entry.activity,
                fishState = entry.fishState,
            ),
        ),
        pendingApprovals = entry.pendingApprovalCount,
    )

/**
 * One system back while the drawer is open. `Dialog` installs its own callback;
 * this custom action is the panel's accessibility escape and named close
 * (`BotDrawer.swift:109-110`).
 */
private fun Modifier.customBotDrawerActions(onClose: () -> Unit): Modifier =
    this.semantics {
        customActions = listOf(
            CustomAccessibilityAction(BotDrawerCopy.CLOSE_LABEL) {
                onClose()
                true
            },
        )
    }

/** The panel clears the navigation bar, as the shell drawer does (`PdshDrawer.kt:190`). */
@Composable
private fun drawerNavigationBarInset(): androidx.compose.ui.unit.Dp =
    WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()

/** Drag rule from `HomeDrawer.kt:808-848`: 12 dp start distance, horizontal lock, shared release. */
private suspend fun PointerInputScope.botDrawerDrag(
    dragMinimumDistance: androidx.compose.ui.unit.Dp,
    initialOffset: () -> Float,
    onOffset: (Float) -> Unit,
    onRelease: (dx: Float, velocity: Float) -> Unit,
    onTap: (() -> Unit)? = null,
) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val tracker = VelocityTracker()
        tracker.addPosition(down.uptimeMillis, down.position)
        var total = Offset.Zero
        var started = false
        var followed = false
        var lastOffset = 0f
        while (true) {
            val event = awaitPointerEvent()
            val change = event.changes.firstOrNull { it.id == down.id } ?: break
            tracker.addPosition(change.uptimeMillis, change.position)
            if (!change.pressed) {
                if (followed) {
                    onRelease(total.x / density, tracker.calculateVelocity().x / density)
                } else if (!started && onTap != null) {
                    onTap()
                }
                break
            }
            total += change.positionChange()
            if (!started && total.getDistance() >= dragMinimumDistance.toPx()) {
                started = true
                lastOffset = initialOffset()
            }
            if (!started) continue
            if (abs(total.x) <= abs(total.y)) continue
            followed = true
            lastOffset = DrawerGesture.followOffset(total.x / density, total.y / density, lastOffset)
            onOffset(lastOffset)
            change.consume()
        }
    }
}

private const val BOT_ROW_SURFACE: String = "botRow"


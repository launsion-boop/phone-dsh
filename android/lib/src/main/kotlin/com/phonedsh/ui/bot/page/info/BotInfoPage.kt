// Bot information: the avatar/name header, the name editor, the appearance
// entry, presence, disturbance and the four data destinations, plus the local
// navigation into each sub-page.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift` and
// `spec/ui/v1/pages/bot-info.md`. The load states and every value are K3's
// (`BotInfoModelState`); this page only draws them and reports `BotInfoIntent`.
// Sub-pages are pushed inside this page's own route state, exactly where iOS
// uses `NavigationStack`/`navigationDestination`; no global `PdshRoute` is
// added (the nav files belong to lane K5a).
package com.phonedsh.ui.bot.page.info

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.window.Dialog
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.bot.page.BotFishSlot
import com.phonedsh.ui.bot.page.appearance.BotAppearancePicker
import com.phonedsh.ui.bot.state.BotAppearanceIntent
import com.phonedsh.ui.bot.state.BotInfoIntent
import com.phonedsh.ui.bot.state.BotInfoLoadState
import com.phonedsh.ui.bot.state.BotInfoModelState
import com.phonedsh.ui.bot.state.BotInfoSection
import com.phonedsh.ui.bot.state.BotNameValidation
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.page.PageFrame
import com.phonedsh.ui.page.SessionSectionLabel
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** The info flow's local route; the global nav files are lane K5a's. */
internal enum class BotInfoRoute { ROOT, MEMORY, ROUTINES, APPROVALS, GRANTS }

/**
 * Bot 信息.
 *
 * @param state the one load result plus the three independent section states.
 * @param appearance the Bot's current appearance (the header fish and the picker
 *   both read it; selecting saves through [onAppearanceIntent]).
 * @param isMainBot draws the crown on the header fish.
 * @param onIntent one info write (`BotInfoDriver` vocabulary).
 * @param fish the host fish renderer.
 * @param onAppearanceIntent one appearance write; kept separate because the
 *   picker's frozen vocabulary is `BotAppearanceIntent`, not `BotInfoIntent`.
 * @param botDescription the profile description; empty renders the baseline
 *   default line.
 * @param initialSection pushes one data section immediately (a Bot-page menu
 *   entry or a routine deep link).
 * @param highlightRoutineID marks and scrolls to one routine row.
 * @param onBack the root back action; a null value keeps the page a root.
 * @param onDelete the full deletion cascade; null hides the 危险操作 section.
 * @param now the explicit clock for every date rendering.
 */
@Composable
public fun BotInfoPage(
    state: BotInfoModelState,
    appearance: BotFishAppearance,
    isMainBot: Boolean,
    onIntent: (BotInfoIntent) -> Unit,
    fish: BotFishSlot,
    modifier: Modifier = Modifier,
    onAppearanceIntent: (BotAppearanceIntent) -> Unit = {},
    botDescription: String = "",
    initialSection: BotInfoSection? = null,
    highlightRoutineID: String? = null,
    onBack: (() -> Unit)? = null,
    onDelete: (() -> Unit)? = null,
    now: Long = System.currentTimeMillis(),
) {
    var route by remember(initialSection) {
        mutableStateOf(initialSection?.toRoute() ?: BotInfoRoute.ROOT)
    }
    // The 刷新 control re-asks the driver; the local route is untouched.
    val refresh = { onIntent(BotInfoIntent.Load) }

    when (route) {
        BotInfoRoute.ROOT -> BotInfoRoot(
            state = state,
            appearance = appearance,
            isMainBot = isMainBot,
            botDescription = botDescription,
            onIntent = onIntent,
            onAppearanceIntent = onAppearanceIntent,
            fish = fish,
            onBack = onBack,
            onDelete = onDelete,
            now = now,
            onRefresh = refresh,
            onOpen = { route = it },
            modifier = modifier,
        )

        BotInfoRoute.MEMORY -> BotInfoMemoryPage(
            state = state,
            onIntent = onIntent,
            onBack = { route = BotInfoRoute.ROOT },
            modifier = modifier,
            now = now,
        )

        BotInfoRoute.ROUTINES -> BotInfoRoutinesPage(
            state = state,
            onIntent = onIntent,
            onBack = { route = BotInfoRoute.ROOT },
            highlightRoutineID = highlightRoutineID,
            modifier = modifier,
            now = now,
        )

        BotInfoRoute.APPROVALS -> BotInfoApprovalsPage(
            state = state,
            onIntent = onIntent,
            onBack = { route = BotInfoRoute.ROOT },
            modifier = modifier,
            now = now,
        )

        BotInfoRoute.GRANTS -> BotInfoGrantsPage(
            state = state,
            onIntent = onIntent,
            onBack = { route = BotInfoRoute.ROOT },
            modifier = modifier,
            now = now,
        )
    }
}

@Composable
private fun BotInfoRoot(
    state: BotInfoModelState,
    appearance: BotFishAppearance,
    isMainBot: Boolean,
    botDescription: String,
    onIntent: (BotInfoIntent) -> Unit,
    onAppearanceIntent: (BotAppearanceIntent) -> Unit,
    fish: BotFishSlot,
    onBack: (() -> Unit)?,
    onDelete: (() -> Unit)?,
    now: Long,
    onRefresh: () -> Unit,
    onOpen: (BotInfoRoute) -> Unit,
    modifier: Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val botName = state.snapshot?.botName.orEmpty()
    var draftName by remember(botName) { mutableStateOf(botName) }
    var renameError by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    val trimmedDraft = BotNameValidation.trimmed(draftName)
    val nameChanged = trimmedDraft.isNotEmpty() && trimmedDraft != botName

    PageFrame(
        title = BotInfoCopy.TITLE,
        onBack = onBack,
        rootTag = BotInfoTags.ROOT,
        modifier = modifier,
        actions = {
            Box(
                Modifier
                    .size(BotInfoMetrics.ACTION)
                    .clickable(role = Role.Button, onClick = onRefresh)
                    .semantics { contentDescription = BotInfoCopy.REFRESH },
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(
                    PdshIcon.REFRESH,
                    BotInfoMetrics.ENTRY_ICON_SIZE,
                    tokens.colors.textSecondary,
                    null,
                )
            }
            if (onBack != null) {
                BasicText(
                    text = BotInfoCopy.DONE,
                    style = type.secondary.copy(
                        color = tokens.colors.primaryButton,
                        fontWeight = FontWeight.SemiBold,
                    ),
                    modifier = Modifier
                        .clickable(role = Role.Button, onClick = onBack)
                        .padding(horizontal = BotInfoMetrics.ENTRY_GAP),
                )
            }
        },
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(BotInfoTags.LIST),
            verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.HEADER_GAP),
        ) {
            item(key = "header") {
                BotInfoHeader(
                    botName = botName,
                    description = botDescription,
                    appearance = appearance,
                    isMainBot = isMainBot,
                    fish = fish,
                )
            }
            item(key = "name") {
                BotInfoNameSection(
                    value = draftName,
                    onValueChange = {
                        renameError = null
                        draftName = BotNameValidation.capped(it)
                    },
                    showSave = nameChanged,
                    error = renameError,
                    onSave = {
                        val problem = BotNameValidation.problem(draftName)
                        if (problem != null) {
                            renameError = problem
                        } else {
                            renameError = null
                            onIntent(BotInfoIntent.Rename(BotNameValidation.trimmed(draftName)))
                        }
                    },
                )
            }
            item(key = "appearance") {
                SessionSectionLabel(BotInfoCopy.APPEARANCE_SECTION)
                Column(
                    Modifier
                        .fillMaxWidth()
                        .padding(vertical = BotInfoMetrics.APPEARANCE_PADDING_V)
                        .testTag(BotInfoTags.APPEARANCE),
                ) {
                    BotAppearancePicker(
                        appearance = appearance,
                        onIntent = onAppearanceIntent,
                        fish = fish,
                        showsPreview = false,
                    )
                }
            }
            item(key = "presence") {
                BotInfoPresenceSection(state = state)
            }
            item(key = "disruption") {
                BotInfoDisruptionSection(state = state, onIntent = onIntent)
            }
            item(key = "data") {
                BotInfoDataSection(state = state, onOpen = onOpen)
            }
            state.actionError?.let { message ->
                item(key = "error") {
                    SessionSectionLabel(BotInfoCopy.DANGER_SECTION)
                    BasicText(
                        text = message,
                        style = type.secondary.copy(color = tokens.colors.danger),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = tokens.geometry.pageOuterMarginH)
                            .semantics { liveRegion = LiveRegionMode.Polite }
                            .testTag(BotInfoTags.ERROR),
                    )
                }
            }
            if (onDelete != null) {
                item(key = "delete") {
                    SessionSectionLabel(BotInfoCopy.DANGER_SECTION)
                    BasicText(
                        text = BotInfoCopy.DELETE_BOT,
                        style = type.secondary.copy(color = tokens.colors.danger),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(role = Role.Button, onClick = { confirmDelete = true })
                            .padding(
                                horizontal = tokens.geometry.pageOuterMarginH,
                                vertical = tokens.spacing.iconText,
                            )
                            .testTag(BotInfoTags.DELETE),
                    )
                }
            }
        }
    }

    if (confirmDelete && onDelete != null) {
        BotInfoConfirmDialog(
            title = BotInfoCopy.DELETE_TITLE,
            message = BotUiStrings.DRAWER_DELETE_CONFIRM,
            confirmLabel = BotInfoCopy.DELETE_CONFIRM,
            confirmTag = BotInfoTags.DELETE_CONFIRM,
            cancelTag = BotInfoTags.DELETE_CANCEL,
            messageTag = BotInfoTags.DELETE_MESSAGE,
            onDismiss = { confirmDelete = false },
            onConfirm = {
                confirmDelete = false
                onDelete()
            },
        )
    }
}

@Composable
private fun BotInfoHeader(
    botName: String,
    description: String,
    appearance: BotFishAppearance,
    isMainBot: Boolean,
    fish: BotFishSlot,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val displayDescription = description.trim().ifEmpty { BotInfoCopy.DEFAULT_DESCRIPTION }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(vertical = BotInfoMetrics.HEADER_PADDING_V)
            .testTag(BotInfoTags.HEADER),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.HEADER_GAP),
    ) {
        fish(
            BotFishLifecycle.IDLE,
            appearance,
            isMainBot,
            BotInfoMetrics.HEADER_FISH,
            true,
            Modifier.testTag(BotInfoTags.HEADER_FISH),
        )
        BasicText(
            text = botName,
            style = type.headline.copy(
                fontSize = BotInfoMetrics.HEADER_NAME_SIZE,
                fontWeight = FontWeight.Bold,
                color = tokens.colors.textPrimary,
            ),
            modifier = Modifier.semantics { heading() },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        BasicText(
            text = displayDescription,
            style = type.secondary.copy(
                fontSize = BotInfoMetrics.HEADER_DESCRIPTION_SIZE,
                color = tokens.colors.textPlaceholder,
            ),
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun BotInfoNameSection(
    value: String,
    onValueChange: (String) -> Unit,
    showSave: Boolean,
    error: String?,
    onSave: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    SessionSectionLabel(BotInfoCopy.NAME_SECTION)
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = type.homeBody.copy(color = tokens.colors.textPrimary),
            cursorBrush = SolidColor(tokens.colors.primaryButton),
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = tokens.spacing.iconText)
                .semantics { contentDescription = BotInfoCopy.NAME_PLACEHOLDER }
                .testTag(BotInfoTags.NAME),
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty()) {
                        BasicText(
                            text = BotInfoCopy.NAME_PLACEHOLDER,
                            style = type.homeBody.copy(color = tokens.colors.textPlaceholder),
                        )
                    }
                    inner()
                }
            },
        )
        if (showSave) {
            BasicText(
                text = BotInfoCopy.SAVE_NAME,
                style = type.secondary.copy(
                    color = tokens.colors.primaryButton,
                    fontWeight = FontWeight.SemiBold,
                ),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onSave)
                    .semantics { contentDescription = BotInfoCopy.SAVE_NAME }
                    .testTag(BotInfoTags.RENAME)
                    .padding(vertical = tokens.spacing.iconText),
            )
        }
        if (error != null) {
            BasicText(
                text = error,
                style = type.caption.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .semantics { liveRegion = LiveRegionMode.Polite }
                    .testTag(BotInfoTags.RENAME_ERROR),
            )
        }
    }
}

@Composable
private fun BotInfoPresenceSection(state: BotInfoModelState) {
    val tokens = LocalUiTokens.current
    val presence = state.snapshot?.presence
    SessionSectionLabel(BotInfoCopy.PRESENCE_SECTION)
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH)
            .testTag(BotInfoTags.PRESENCE),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        if (presence == null) {
            BasicText(
                text = BotUiStrings.INFO_READFAILED,
                style = LocalUiType.current.secondary.copy(color = tokens.colors.danger),
                modifier = Modifier.testTag(BotInfoTags.PRESENCE_LEVEL),
            )
            return@Column
        }
        BotInfoValueRow(
            label = BotInfoCopy.PRESENCE_LEVEL,
            value = when (presence.level) {
                com.phonedsh.ui.bot.state.RoutinePresenceLevel.FOREGROUND ->
                    BotInfoCopy.PRESENCE_LEVEL_FOREGROUND
                com.phonedsh.ui.bot.state.RoutinePresenceLevel.BACKGROUND_KEEP_ALIVE ->
                    BotInfoCopy.PRESENCE_LEVEL_BACKGROUND
                com.phonedsh.ui.bot.state.RoutinePresenceLevel.SCHEDULED_NOTIFICATION ->
                    BotInfoCopy.PRESENCE_LEVEL_SCHEDULED
            },
            tag = BotInfoTags.PRESENCE_LEVEL,
        )
        if (presence.level ==
            com.phonedsh.ui.bot.state.RoutinePresenceLevel.SCHEDULED_NOTIFICATION
        ) {
            BotInfoValueRow(
                label = BotInfoCopy.PRESENCE_NOTIFICATIONS,
                value = "${presence.scheduledNotificationCount} 条",
                tag = BotInfoTags.PRESENCE_NOTIFICATIONS,
            )
        }
        if (presence.deferred.isEmpty()) {
            BasicText(
                text = BotInfoCopy.PRESENCE_NONE_DEFERRED,
                style = LocalUiType.current.caption.copy(color = tokens.colors.textSecondary),
            )
        } else {
            presence.deferred.forEach { deferred ->
                Column(
                    Modifier
                        .fillMaxWidth()
                        .testTag(BotInfoTags.presenceDeferred(deferred.routineId)),
                ) {
                    BasicText(
                        text = deferred.title,
                        style = LocalUiType.current.secondary.copy(
                            color = tokens.colors.textPrimary,
                            fontWeight = FontWeight.Medium,
                        ),
                    )
                    BasicText(
                        text = BotInfoCopy.format(
                            BotInfoCopy.PRESENCE_DEFERRED_FROM,
                            "from" to BotInfoFormat.dateTime(deferred.scheduledFor),
                            "until" to BotInfoFormat.dateTime(deferred.deferredUntil),
                        ),
                        style = LocalUiType.current.caption.copy(color = tokens.colors.textSecondary),
                    )
                }
            }
        }
    }
}

@Composable
private fun BotInfoDisruptionSection(
    state: BotInfoModelState,
    onIntent: (BotInfoIntent) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val settings = state.snapshot?.proactiveSettings
        ?: com.phonedsh.ui.bot.state.ProactiveSettings.productionDefault()
    var editingQuietStart by remember { mutableStateOf(false) }
    var editingQuietEnd by remember { mutableStateOf(false) }
    SessionSectionLabel(BotInfoCopy.DISRUPTION_SECTION)
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = BotInfoCopy.DND,
                style = type.homeBody.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.weight(1f),
            )
            Switch(
                checked = settings.dnd,
                onCheckedChange = {
                    onIntent(BotInfoIntent.SaveProactiveSettings(settings.copy(dnd = it)))
                },
                modifier = Modifier.testTag(BotInfoTags.DND),
            )
        }
        BotInfoTimeRow(
            label = BotInfoCopy.QUIET_START,
            value = settings.quietStart,
            tag = BotInfoTags.QUIET_START,
            onClick = { editingQuietStart = true },
        )
        BotInfoTimeRow(
            label = BotInfoCopy.QUIET_END,
            value = settings.quietEnd,
            tag = BotInfoTags.QUIET_END,
            onClick = { editingQuietEnd = true },
        )
    }
    if (editingQuietStart) {
        BotInfoTimePickerDialog(
            title = BotInfoCopy.QUIET_START,
            initial = settings.quietStart,
            onDismiss = { editingQuietStart = false },
            onConfirm = { value ->
                editingQuietStart = false
                onIntent(
                    BotInfoIntent.SaveProactiveSettings(settings.copy(quietStart = value)),
                )
            },
        )
    }
    if (editingQuietEnd) {
        BotInfoTimePickerDialog(
            title = BotInfoCopy.QUIET_END,
            initial = settings.quietEnd,
            onDismiss = { editingQuietEnd = false },
            onConfirm = { value ->
                editingQuietEnd = false
                onIntent(BotInfoIntent.SaveProactiveSettings(settings.copy(quietEnd = value)))
            },
        )
    }
}

@Composable
private fun BotInfoTimeRow(
    label: String,
    value: String,
    tag: String,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = "$label $value"
                role = Role.Button
            }
            .padding(vertical = tokens.spacing.iconText)
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            text = label,
            style = type.homeBody.copy(color = tokens.colors.textPrimary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = value,
            style = type.homeBody.copy(color = tokens.colors.textSecondary),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BotInfoTimePickerDialog(
    title: String,
    initial: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val pieces = initial.split(':')
    val hour = pieces.getOrNull(0)?.toIntOrNull()?.coerceIn(0, 23) ?: 23
    val minute = pieces.getOrNull(1)?.toIntOrNull()?.coerceIn(0, 59) ?: 0
    val picker = rememberTimePickerState(initialHour = hour, initialMinute = minute, is24Hour = true)
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .background(
                    tokens.colors.surface,
                    RoundedCornerShape(tokens.radius.card),
                )
                .padding(BotInfoMetrics.RECONCILIATION_PADDING),
            verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.RECONCILIATION_PADDING),
        ) {
            BasicText(
                text = title,
                style = type.headline.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.semantics { heading() },
            )
            TimePicker(state = picker)
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = onDismiss) { Text(UiStrings.CANCEL) }
                TextButton(onClick = {
                    onConfirm("%02d:%02d".format(picker.hour, picker.minute))
                }) {
                    Text(BotInfoCopy.TIME_CONFIRM)
                }
            }
        }
    }
}

@Composable
private fun BotInfoDataSection(
    state: BotInfoModelState,
    onOpen: (BotInfoRoute) -> Unit,
) {
    SessionSectionLabel(BotInfoCopy.DATA_SECTION)
    Column(Modifier.fillMaxWidth()) {
        BotInfoEntryRow(
            title = BotInfoCopy.DATA_MEMORY,
            icon = PdshIcon.THINK,
            section = "memory",
            loadState = state.memoryState,
            count = state.snapshot?.memories?.size ?: 0,
            tag = BotInfoTags.DATA_MEMORY,
            onClick = { onOpen(BotInfoRoute.MEMORY) },
        )
        BotInfoEntryRow(
            title = BotInfoCopy.DATA_ROUTINES,
            icon = PdshIcon.CLOCK,
            section = "routines",
            loadState = state.routinesState,
            count = state.snapshot?.routines?.size ?: 0,
            tag = BotInfoTags.DATA_ROUTINES,
            onClick = { onOpen(BotInfoRoute.ROUTINES) },
        )
        BotInfoEntryRow(
            title = BotInfoCopy.DATA_APPROVALS,
            icon = PdshIcon.CHECK,
            section = "approvals",
            loadState = state.approvalsState,
            count = state.snapshot?.approvals?.size ?: 0,
            tag = BotInfoTags.DATA_APPROVALS,
            onClick = { onOpen(BotInfoRoute.APPROVALS) },
        )
        BotInfoEntryRow(
            title = BotInfoCopy.DATA_GRANTS,
            icon = PdshIcon.LOCK_SHIELD,
            section = "grants",
            // iOS uses `model.approvalsState` for the grant entry as well
            // (`BotInfoPage.swift:645-649`).
            loadState = state.approvalsState,
            count = state.snapshot?.grants?.count {
                it.scope != "once"
            } ?: 0,
            tag = BotInfoTags.DATA_GRANTS,
            onClick = { onOpen(BotInfoRoute.GRANTS) },
        )
    }
}

@Composable
private fun BotInfoEntryRow(
    title: String,
    icon: PdshIcon,
    section: String,
    loadState: BotInfoLoadState,
    count: Int,
    tag: String,
    onClick: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val statusText = when (loadState) {
        BotInfoLoadState.Loading -> "正在读取"
        is BotInfoLoadState.Failed -> BotUiStrings.INFO_READFAILED
        BotInfoLoadState.Loaded -> "$count 个"
    }
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = "$title，$statusText"
            }
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.iconText,
            )
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BotInfoMetrics.ENTRY_GAP),
    ) {
        PdshIconView(
            icon,
            BotInfoMetrics.ENTRY_ICON_SIZE,
            tokens.colors.textPrimary,
            null,
            Modifier.size(BotInfoMetrics.ENTRY_ICON),
        )
        BasicText(
            text = title,
            style = type.homeBody.copy(color = tokens.colors.textPrimary),
            modifier = Modifier.weight(1f),
        )
        when (loadState) {
            BotInfoLoadState.Loading -> CircularProgressIndicator(
                modifier = Modifier
                    .size(BotInfoMetrics.ENTRY_PROGRESS)
                    .testTag(BotInfoTags.entryState(section, "loading")),
                strokeWidth = BotInfoMetrics.ENTRY_PROGRESS_STROKE,
                color = tokens.colors.textSecondary,
            )
            is BotInfoLoadState.Failed -> BasicText(
                text = BotUiStrings.INFO_READFAILED,
                style = type.homeBody.copy(
                    fontSize = BotInfoMetrics.ENTRY_STATUS_SIZE,
                    color = tokens.colors.danger,
                ),
                modifier = Modifier.testTag(BotInfoTags.entryState(section, "failed")),
            )
            BotInfoLoadState.Loaded -> BasicText(
                text = count.toString(),
                style = type.homeBody.copy(
                    fontSize = BotInfoMetrics.ENTRY_STATUS_SIZE,
                    color = tokens.colors.textPlaceholder,
                ),
                modifier = Modifier.testTag(BotInfoTags.entryState(section, "count")),
            )
        }
    }
}

@Composable
internal fun BotInfoValueRow(label: String, value: String, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) { contentDescription = "$label $value" }
            .padding(vertical = tokens.spacing.iconText)
            .testTag(tag),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(
            text = label,
            style = type.homeBody.copy(color = tokens.colors.textPrimary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = value,
            style = type.homeBody.copy(color = tokens.colors.textSecondary),
        )
    }
}

/** The one confirmation dialog shared by the info page's destructive actions. */
@Composable
internal fun BotInfoConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    confirmTag: String,
    cancelTag: String,
    messageTag: String? = null,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Dialog(onDismissRequest = onDismiss) {
        Column(
            Modifier
                .widthIn(max = BotInfoMetrics.CONFIRM_MAX_WIDTH)
                .background(tokens.colors.surface, RoundedCornerShape(tokens.radius.card))
                .padding(BotInfoMetrics.RECONCILIATION_PADDING),
            verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.RECONCILIATION_PADDING),
        ) {
            BasicText(
                text = title,
                style = type.headline.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.semantics { heading() },
            )
            BasicText(
                text = message,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
                modifier = if (messageTag != null) {
                    Modifier.testTag(messageTag)
                } else {
                    Modifier
                },
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                BasicText(
                    text = UiStrings.CANCEL,
                    style = type.secondary.copy(color = tokens.colors.textSecondary),
                    modifier = Modifier
                        .clickable(role = Role.Button, onClick = onDismiss)
                        .testTag(cancelTag)
                        .padding(horizontal = BotInfoMetrics.RECONCILIATION_PADDING),
                )
                BasicText(
                    text = confirmLabel,
                    style = type.secondary.copy(color = tokens.colors.danger),
                    modifier = Modifier
                        .clickable(role = Role.Button, onClick = onConfirm)
                        .testTag(confirmTag)
                        .padding(horizontal = BotInfoMetrics.RECONCILIATION_PADDING),
                )
            }
        }
    }
}

private fun BotInfoSection.toRoute(): BotInfoRoute = when (this) {
    BotInfoSection.MEMORY -> BotInfoRoute.MEMORY
    BotInfoSection.ROUTINES -> BotInfoRoute.ROUTINES
    BotInfoSection.APPROVALS -> BotInfoRoute.APPROVALS
    BotInfoSection.GRANTS -> BotInfoRoute.GRANTS
}

// 手机 | PC segment and the PC list region of the home drawer (P09/P28).
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/HomeDrawer.swift:44-70,716-755`
// and `PCDrawerSection.swift`. The component is a pure function of
// [PcDrawerUiState]: the host owns the persisted selection (`phone-dsh.drawer.backend`,
// P18) and the PC roster; this file never reads or writes a preference.
package com.phonedsh.ui.nav

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.PcDrawerBackend
import com.phonedsh.ui.page.PcDrawerGroup
import com.phonedsh.ui.page.PcDrawerListState
import com.phonedsh.ui.page.PcDrawerPhase
import com.phonedsh.ui.page.PcDrawerSession
import com.phonedsh.ui.page.PcDrawerUiState
import com.phonedsh.ui.page.PcLinkText
import com.phonedsh.ui.page.PcLinkPresence
import com.phonedsh.ui.page.SessionActionTone
import com.phonedsh.ui.page.SessionTextAction
import com.phonedsh.ui.press.pillPressed
import com.phonedsh.ui.press.rowPressed
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** Stable test tags for the drawer's backend segment and PC list region. */
public object PcDrawerTags {
    public const val ROOT: String = "home.drawer.pc"
    public const val SEGMENT: String = "home.drawer.pc.segment"
    public const val BACKEND_PREFIX: String = "home.drawer.pc.backend."
    public const val STATE_CARD: String = "home.drawer.pc.state-card"
    public const val PAIR: String = "home.drawer.pc.pair"
    public const val RETRY: String = "home.drawer.pc.retry"
    public const val CACHED_NOTE: String = "home.drawer.pc.cached-note"
    public const val LOADING: String = "home.drawer.pc.loading"
    public const val EMPTY: String = "home.drawer.pc.empty"
    public const val ERROR: String = "home.drawer.pc.error"
    public const val GROUP_PREFIX: String = "home.drawer.pc.group."
    public const val SESSION_PREFIX: String = "home.drawer.pc.session."
}

/**
 * 手机 | PC and the PC region below 新会话 (`HomeDrawer.swift:44-48`).
 *
 * The selection is reported through [onSelectBackend]; it is never written here
 * (P18 keeps the preference in the host). Selecting PC while unpaired opens the
 * pairing entry but never falls back to 手机 (`HomeDrawer.swift:716-723`).
 *
 * @param state the host's selection, presence and PC-scope roster.
 * @param onSelectBackend 手机 or PC was tapped.
 * @param onPair 连接电脑 from the unpaired card (`PCDrawerSection.swift:26`).
 * @param onRetry 重试 from the offline card (`PCDrawerSection.swift:48`).
 * @param onOpenSession a PC session row was tapped.
 * @param onOpenConnectedComputer optional entry to 我的 › 已连接的电脑 from the card.
 * @param segment the segment body. The default draws the two contract labels;
 *   a host that composes its own segment keeps the same [PcSegmentButton] so the
 *   labels and pressed tokens do not fork.
 */
@Composable
public fun PcDrawer(
    state: PcDrawerUiState,
    onSelectBackend: (PcDrawerBackend) -> Unit,
    onPair: () -> Unit = {},
    onRetry: () -> Unit = {},
    onOpenSession: ((String) -> Unit)? = null,
    onOpenConnectedComputer: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    segment: @Composable RowScope.() -> Unit = {
        PcSegmentButton(
            label = UiStrings.PC_BACKEND_PHONE,
            selected = state.selected == PcDrawerBackend.PHONE,
            onClick = { onSelectBackend(PcDrawerBackend.PHONE) },
            modifier = Modifier.weight(1f),
        )
        PcSegmentButton(
            label = UiStrings.PC_BACKEND_PC,
            selected = state.selected == PcDrawerBackend.PC,
            onClick = { onSelectBackend(PcDrawerBackend.PC) },
            modifier = Modifier.weight(1f),
        )
    },
) {
    Column(modifier.fillMaxWidth().testTag(PcDrawerTags.ROOT)) {
        PcDrawerSegment(modifier = Modifier.padding(horizontal = 16.dp), content = segment)
        if (state.selected != PcDrawerBackend.PC) return@Column
        Spacer(Modifier.height(10.dp))
        if (state.showsStateCard) {
            PcDrawerStateCard(
                state = state,
                onPair = onPair,
                onRetry = onRetry,
                onOpenConnectedComputer = onOpenConnectedComputer,
            )
        } else {
            if (state.cachedListNote != null) {
                PcCachedListNote(state.cachedListNote)
            }
            when (state.resolvedListState) {
                PcDrawerListState.LOADING -> BasicText(
                    text = PcLinkText.LOADING_PC_SESSIONS,
                    style = LocalUiType.current.secondary.copy(color = LocalUiTokens.current.colors.textPlaceholder),
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp)
                        .testTag(PcDrawerTags.LOADING),
                )

                PcDrawerListState.ERROR -> Column(
                    Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp)
                        .testTag(PcDrawerTags.ERROR),
                ) {
                    BasicText(
                        text = state.error.orEmpty(),
                        style = LocalUiType.current.secondary.copy(color = LocalUiTokens.current.colors.pageDanger),
                    )
                    SessionTextAction(
                        label = UiStrings.PC_PAIRING_RETRY,
                        onClick = onRetry,
                        tone = SessionActionTone.ACCENT,
                        modifier = Modifier.testTag(PcDrawerTags.RETRY),
                    )
                }

                PcDrawerListState.EMPTY -> BasicText(
                    text = PcLinkText.NO_PC_SESSIONS,
                    style = LocalUiType.current.secondary.copy(color = LocalUiTokens.current.colors.textPlaceholder),
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp)
                        .testTag(PcDrawerTags.EMPTY),
                )

                PcDrawerListState.ROWS -> PcDrawerGroups(
                    groups = state.groups,
                    onOpenSession = onOpenSession,
                )
            }
        }
    }
}

/** The capsule track that holds the two segment buttons (`HomeDrawer.swift:734-752`). */
@Composable
public fun PcDrawerSegment(
    modifier: Modifier = Modifier,
    content: @Composable RowScope.() -> Unit,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(percent = 50))
            .background(tokens.colors.userBubble)
            .padding(2.dp)
            .testTag(PcDrawerTags.SEGMENT)
            .semantics { contentDescription = UiStrings.PC_BACKEND_GROUP },
        horizontalArrangement = Arrangement.spacedBy(0.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/**
 * One segment control. First parameter is the visible `label` so the page
 * structure checker can resolve the 手机 / PC contract actions; the pressed fill
 * is `interaction.md` §6's `drawerPill` table.
 */
@Composable
public fun PcSegmentButton(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val interaction = remember { MutableInteractionSource() }
    val shape = RoundedCornerShape(percent = 50)
    Box(
        modifier = modifier
            .height(34.dp)
            .clip(shape)
            .background(if (selected) tokens.colors.surface else androidx.compose.ui.graphics.Color.Transparent)
            .border(0.5.dp, if (selected) tokens.colors.borderList else androidx.compose.ui.graphics.Color.Transparent, shape)
            .pillPressed(interaction)
            .clickable(
                interactionSource = interaction,
                indication = null,
                role = Role.Button,
                onClick = onClick,
            )
            .testTag(PcDrawerTags.BACKEND_PREFIX + label)
            .semantics { stateDescription = if (selected) "已选择" else "" },
        contentAlignment = Alignment.Center,
    ) {
        BasicText(
            text = label,
            style = type.homeBody.copy(
                fontSize = 15.sp,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                color = if (selected) tokens.colors.textPrimary else tokens.colors.textSecondary,
            ),
        )
    }
}

@Composable
private fun PcDrawerStateCard(
    state: PcDrawerUiState,
    onPair: () -> Unit,
    onRetry: () -> Unit,
    onOpenConnectedComputer: (() -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val title: String?
    val message: String
    val actionLabel: String?
    val action: (() -> Unit)?
    when (state.phase) {
        PcDrawerPhase.PAIR -> {
            title = null
            message = PcLinkText.PAIR_DESCRIPTION
            actionLabel = UiStrings.PC_CONNECT_COMPUTER
            action = onPair
        }

        PcDrawerPhase.CONNECTING -> {
            title = PcLinkText.CONNECTING_TITLE
            message = PcLinkText.RESUME_CONNECTING
            actionLabel = null
            action = null
        }

        PcDrawerPhase.OFFLINE -> {
            title = PcLinkText.OFFLINE_TITLE
            message = PcLinkText.offlineReason(state.offlineReason)
            actionLabel = UiStrings.PC_PAIRING_RETRY
            action = onRetry
        }

        PcDrawerPhase.READY, PcDrawerPhase.PHONE -> return
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(tokens.colors.surface)
            .border(0.5.dp, tokens.colors.borderList, RoundedCornerShape(18.dp))
            .padding(20.dp)
            .testTag(PcDrawerTags.STATE_CARD),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (title != null) {
            BasicText(
                text = title,
                style = type.headline.copy(color = tokens.colors.textPrimary),
            )
        }
        BasicText(
            text = message,
            style = type.secondary.copy(color = tokens.colors.textSecondary),
        )
        if (actionLabel != null && action != null) {
            SessionTextAction(
                label = actionLabel,
                onClick = action,
                tone = SessionActionTone.ACCENT,
                modifier = Modifier.testTag(if (state.phase == PcDrawerPhase.PAIR) PcDrawerTags.PAIR else PcDrawerTags.RETRY),
            )
        }
        if (state.phase == PcDrawerPhase.OFFLINE && state.longOffline) {
            BasicText(
                text = PcLinkText.LONG_OFFLINE,
                style = type.caption.copy(color = tokens.colors.textSecondary),
            )
            if (onOpenConnectedComputer != null) {
                SessionTextAction(
                    label = PcLinkText.LONG_OFFLINE_RECOVERY,
                    onClick = onOpenConnectedComputer,
                    tone = SessionActionTone.SECONDARY,
                )
            }
        }
    }
}

@Composable
private fun PcCachedListNote(note: String) {
    val tokens = LocalUiTokens.current
    BasicText(
        text = note,
        style = LocalUiType.current.caption.copy(color = tokens.colors.textSecondary),
        modifier = Modifier.fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(tokens.colors.userBubble)
            .padding(horizontal = 12.dp, vertical = 7.dp)
            .testTag(PcDrawerTags.CACHED_NOTE),
    )
}

@Composable
private fun PcDrawerGroups(
    groups: List<PcDrawerGroup>,
    onOpenSession: ((String) -> Unit)?,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        groups.forEach { group ->
            Row(
                Modifier.fillMaxWidth()
                    .heightIn(min = 36.dp)
                    .padding(horizontal = 16.dp)
                    .testTag(PcDrawerTags.GROUP_PREFIX + group.id),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(
                    text = group.title,
                    style = type.secondary.copy(color = tokens.colors.textPrimary, fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (group.sessions.isNotEmpty()) {
                    BasicText(
                        text = group.sessions.size.toString(),
                        style = type.caption.copy(color = tokens.colors.textPlaceholder),
                    )
                }
            }
            group.sessions.forEach { session ->
                PcSessionRow(
                    session = session,
                    onClick = onOpenSession?.let { { it(session.id) } },
                )
            }
        }
    }
}

@Composable
private fun PcSessionRow(session: PcDrawerSession, onClick: (() -> Unit)?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val interaction = remember { MutableInteractionSource() }
    Row(
        Modifier.fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(10.dp))
            .then(
                if (onClick != null) {
                    Modifier
                        .clickable(
                            interactionSource = interaction,
                            indication = null,
                            role = Role.Button,
                            onClick = onClick,
                        )
                        .rowPressed(interaction, shape = RoundedCornerShape(10.dp))
                } else {
                    Modifier
                },
            )
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .testTag(PcDrawerTags.SESSION_PREFIX + session.id),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        BasicText(
            text = session.title.ifBlank { PcLinkText.UNKNOWN_VALUE },
            style = type.homeBody.copy(
                color = if (session.running) tokens.colors.primary else tokens.colors.textPrimary,
                fontWeight = if (session.running) FontWeight.SemiBold else FontWeight.Normal,
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (session.relativeTime != null) {
            BasicText(
                text = session.relativeTime,
                style = type.caption.copy(color = tokens.colors.textPlaceholder),
            )
        }
    }
}

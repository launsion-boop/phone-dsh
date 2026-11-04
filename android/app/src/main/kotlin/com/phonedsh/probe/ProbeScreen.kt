// D3: the one screen. It renders the :engine contract verbatim — lifecycle,
// SPDX-License-Identifier: MIT
// channel counters and the HELLO summary — and never invents a connected state:
// while `handshake` is null the middle card says 「等待握手」 and shows the
// engine's safe error, if any.
//
// Every colour, length and text style is read from [PdshTheme], i.e. from the
// generated accessors over `spec/ui/v1/tokens.json` (`:lib`), so no token value
// is re-typed here. The five lengths the spec publishes no token for are the
// `unverified` constants at the bottom of this file.
package com.phonedsh.probe

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.controller.HostState
import com.phonedsh.engine.ChannelStatus
import com.phonedsh.engine.EngineState
import com.phonedsh.platform.EngineHostState
import com.phonedsh.engine.HandshakeSummary
import com.phonedsh.ui.page.WorkbenchSection
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.PdshThemeValues
import com.phonedsh.ui.theme.UiTokens

/** The whole demo screen: state card, HELLO card, channel card, actions. */
@Composable
internal fun ProbeScreen(
    state: EngineState,
    hostState: HostState,
    handshake: HandshakeSummary?,
    channel: ChannelStatus,
    turn: AppTurnState,
    notice: RecoveryNotice?,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onRunTurn: () -> Unit,
    onOpenDrawer: () -> Unit,
    onOpenConfiguration: () -> Unit,
    onOpenRuntime: () -> Unit,
    onOpenWorkbench: (WorkbenchSection, String?) -> Unit,
    // The resolved 外观 choice. The probe draws its own `PdshTheme`, so without
    // this parameter it would follow the system even when the person picked
    // 浅色 / 深色 in settings — the one surface that would silently disagree with
    // the rest of the app. Defaults to the system answer.
    darkTheme: Boolean = isSystemInDarkTheme(),
) {
    PdshTheme(darkTheme = darkTheme) {
        val tokens = PdshThemeValues.tokens
        Box(Modifier.fillMaxSize().background(tokens.colors.selector)) {
            Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
                Column(
                    Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .padding(
                            horizontal = tokens.geometry.cardOuterMarginH,
                            vertical = tokens.geometry.cardOuterMarginV,
                        ),
                ) {
                    ScreenHeader(
                        state = state,
                        hostState = hostState,
                        onOpenDrawer = onOpenDrawer,
                        onOpenConfiguration = onOpenConfiguration,
                        onOpenRuntime = onOpenRuntime,
                    )
                    Spacer(Modifier.height(tokens.geometry.cardOuterMarginV))
                    EngineStatusCard(state, hostState)
                    // P10: an engine that is Running while the host is not (Draining,
                    // Parked, Recovering, ...) used to read exactly like a usable app.
                    // The banner is what makes the two facts distinguishable.
                    if (!hostUsable(hostState) && state is EngineHostState.Running) {
                        Spacer(Modifier.height(tokens.geometry.cardOuterMarginV))
                        HostUnavailableBanner(hostState)
                    }
                    if (state is EngineHostState.Failed) {
                        Spacer(Modifier.height(tokens.geometry.cardOuterMarginV))
                        FailureBanner(state.reason)
                    }
                    if (notice != null) {
                        Spacer(Modifier.height(tokens.geometry.cardOuterMarginV))
                        RecoveryBanner(notice)
                    }
                    Spacer(Modifier.height(tokens.geometry.cardOuterMarginV))
                    HandshakeCard(state, handshake, channel)
                    Spacer(Modifier.height(tokens.geometry.cardOuterMarginV))
                    ChannelCard(channel, hostState)
                    Spacer(Modifier.height(tokens.geometry.cardOuterMarginV))
                    TurnCard(turn, onOpenWorkbench)
                    Spacer(Modifier.height(tokens.geometry.cardOuterMarginV))
                    FooterNote()
                }
                ActionBar(state, hostState, turn, onStart, onStop, onRunTurn)
            }
        }
    }
}

// --------------------------------------------------------------------- pieces

@Composable
private fun ScreenHeader(
    state: EngineState,
    hostState: HostState,
    onOpenDrawer: () -> Unit,
    onOpenConfiguration: () -> Unit,
    onOpenRuntime: () -> Unit,
) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        HeaderAction(glyph = "☰", description = "打开抽屉", onClick = onOpenDrawer)
        Spacer(Modifier.width(tokens.spacing.iconText))
        Column(Modifier.weight(1f)) {
            Line("PDSH 引擎探针", type.headline, tokens.colors.primary)
            Spacer(Modifier.height(tokens.spacing.jsonStack))
            Line("Android demo · 单视图 · loopback origin", type.caption, tokens.colors.secondary)
        }
        HeaderRuntimeDot(state = state, hostState = hostState, onClick = onOpenRuntime)
        HeaderAction(glyph = "⋯", description = "本会话设置", onClick = onOpenConfiguration)
    }
}

/**
 * One header entry: a glyph with a spoken name.
 *
 * The glyph carries the meaning for a sighted reader; [description] is the
 * accessibility name, so uiautomator and a screen reader find the same control.
 */
@Composable
private fun HeaderAction(
    glyph: String,
    description: String,
    onClick: () -> Unit,
) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    BasicText(
        text = glyph,
        style = type.secondary.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            // unverified geometry: no header-action token; the icon gap keeps the
            // touch target at least two text lines tall.
            .padding(tokens.spacing.iconText),
    )
}

/** The page-header status dot; tapping it opens the runtime sheet (§1). */
@Composable
private fun HeaderRuntimeDot(state: EngineState, hostState: HostState, onClick: () -> Unit) {
    val tokens = PdshThemeValues.tokens
    Box(
        modifier = Modifier
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "运行状态" }
            // unverified geometry: same reason as [HeaderAction]; the dot itself
            // keeps the published statusDotDiameter.
            .padding(tokens.spacing.iconText),
        contentAlignment = Alignment.Center,
    ) {
        // The dot is the host's answer, not the engine's: a Running engine behind a
        // closed admission must not be shown as green (P10, same rule as BUG-2).
        val color = if (hostUsable(hostState)) stateColor(state, tokens) else hostStateColor(hostState, tokens)
        Box(Modifier.size(STATUS_DOT).clip(CircleShape).background(color))
    }
}

/** One openable tool path/command line in the turn card (§1's workbench entry). */
@Composable
private fun ToolLink(text: String, onClick: () -> Unit) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    Line(
        text = text,
        style = type.code.copy(color = tokens.colors.accent),
        color = tokens.colors.accent,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = text }
            .padding(vertical = ROW_INSET),
    )
}

@Composable
private fun EngineStatusCard(state: EngineState, hostState: HostState) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    SectionCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(STATUS_DOT).clip(CircleShape).background(hostStateColor(hostState, tokens)))
            Spacer(Modifier.width(tokens.spacing.iconText))
            Line("宿主状态", type.secondary, tokens.colors.secondary)
            Spacer(Modifier.weight(1f))
            Line(hostStateLabel(hostState), type.secondary, hostStateColor(hostState, tokens))
        }
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        // Two rows, because they are two facts: the D14 host state decides whether
        // anything may be written, the engine state only says whether the page is up.
        KeyValueRow(
            "D14",
            "${hostState.wireName} · admission ${hostState.admission.wireName}",
            hostStateColor(hostState, tokens),
        )
        KeyValueRow("引擎", stateLabel(state), stateColor(state, tokens))
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        Line(stateCode(state), type.codeLabel, tokens.colors.tertiary)
        when (state) {
            EngineHostState.Stopped -> Unit // the action bar already says how to start
            EngineHostState.Starting -> {
                Spacer(Modifier.height(tokens.spacing.jsonStack))
                Line("正在物化 worker bundle 并绑定 loopback origin。", type.caption, tokens.colors.secondary)
            }
            EngineHostState.Recovering -> {
                Spacer(Modifier.height(tokens.spacing.jsonStack))
                // Two causes reach Recovering: the renderer died (a new WebView is
                // built) and the ordered channel died while the page was healthy (the
                // same page is reloaded, with backoff). The row says both instead of
                // claiming a renderer exit that may not have happened (P22 measured
                // the second one).
                Line(
                    "正在恢复：渲染进程已退出则重建 WebView，有序通道已断开则重载同一页 " +
                        "（带退避，恢复后通道重新打开）。",
                    type.caption,
                    tokens.colors.secondary,
                )
            }
            is EngineHostState.Running -> {
                Spacer(Modifier.height(tokens.spacing.jsonStack))
                KeyValueRow("origin", state.origin)
                KeyValueRow("port", state.port.toString())
            }
            is EngineHostState.Failed -> {
                Spacer(Modifier.height(tokens.spacing.jsonStack))
                Line("原因见下方失败横幅。", type.caption, tokens.colors.secondary)
            }
        }
    }
}

/**
 * The P10 banner: the engine is up, the host is not usable.
 *
 * Before this banner existed, `Draining` rendered exactly like a healthy app —
 * 「引擎状态 运行中」, 「通道 已连接」, 「最近错误 —」 — while every write was
 * refused (measured 12:01, emulator API 35). The engine state and the D14 host
 * state are two facts, and this is the surface that says so.
 */
@Composable
private fun HostUnavailableBanner(hostState: HostState) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    val shape = RoundedCornerShape(tokens.radius.card)
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clip(shape)
            .background(tokens.colors.input)
            .border(tokens.stroke.hairline, hostStateColor(hostState, tokens), shape),
    ) {
        Box(Modifier.width(BANNER_ACCENT_BAR).fillMaxHeight().background(hostStateColor(hostState, tokens)))
        Column(Modifier.weight(1f).padding(tokens.geometry.toolFailureBannerInset)) {
            Line("宿主不可用：${hostState.wireName}", type.secondary, hostStateColor(hostState, tokens))
            Spacer(Modifier.height(tokens.geometry.bannerGap))
            Line(
                "引擎进程仍在（${hostState.admission.wireName} admission），" +
                    "但 D14 已关闭 admission：这一轮请求会被拒绝。",
                type.code,
                tokens.colors.primary,
            )
            Spacer(Modifier.height(tokens.spacing.jsonStack))
            Line(
                "这条横幅只随宿主回到 Running 消失，不能手动关掉。",
                type.caption,
                tokens.colors.secondary,
            )
        }
    }
}

@Composable
private fun FailureBanner(reason: String) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    val shape = RoundedCornerShape(tokens.radius.card)
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clip(shape)
            .background(tokens.colors.input)
            .border(tokens.stroke.hairline, tokens.colors.danger, shape),
    ) {
        // The fail-loud accent: the banner is not dismissible, only a state change
        // removes it (spec §2: fail-loud is closed by a user gesture or recovery).
        Box(Modifier.width(BANNER_ACCENT_BAR).fillMaxHeight().background(tokens.colors.danger))
        Column(Modifier.weight(1f).padding(tokens.geometry.toolFailureBannerInset)) {
            Line("引擎失败", type.secondary, tokens.colors.danger)
            Spacer(Modifier.height(tokens.geometry.bannerGap))
            Line(reason, type.code, tokens.colors.primary)
            Spacer(Modifier.height(tokens.spacing.jsonStack))
            Line("点「启动」重试；重新进入 Starting 前横幅不会消失。", type.caption, tokens.colors.secondary)
        }
    }
}

/**
 * The fail-loud surface for a previous process death, a truncated WAL tail or an
 * unreadable reclaim token.
 *
 * Distinct from [FailureBanner] because the engine is healthy in these cases: the
 * damage is already repaired, and hiding it would be the silent degradation the
 * receipt forbids. The banner stays until the state changes.
 */
@Composable
private fun RecoveryBanner(notice: RecoveryNotice) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    val shape = RoundedCornerShape(tokens.radius.card)
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clip(shape)
            .background(tokens.colors.input)
            .border(tokens.stroke.hairline, tokens.colors.warning, shape),
    ) {
        Box(Modifier.width(BANNER_ACCENT_BAR).fillMaxHeight().background(tokens.colors.warning))
        Column(Modifier.weight(1f).padding(tokens.geometry.toolFailureBannerInset)) {
            Line(notice.title, type.secondary, tokens.colors.warning)
            Spacer(Modifier.height(tokens.geometry.bannerGap))
            Line(notice.detail, type.code, tokens.colors.primary)
            Spacer(Modifier.height(tokens.spacing.jsonStack))
            Line("已按 fail-closed 处理；这条报告不会自动消失。", type.caption, tokens.colors.secondary)
        }
    }
}

@Composable
private fun HandshakeCard(
    state: EngineState,
    handshake: HandshakeSummary?,
    channel: ChannelStatus,
) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    SectionCard {
        Line("HELLO 摘要", type.secondary, tokens.colors.primary)
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        if (handshake == null) {
            Line("等待握手", type.subheadline, tokens.colors.secondary)
            Spacer(Modifier.height(tokens.spacing.jsonStack))
            Line(waitingReason(state, channel), type.caption, tokens.colors.secondary)
            channel.lastError?.let { error ->
                Spacer(Modifier.height(tokens.spacing.jsonStack))
                Line("原因：$error", type.code, tokens.colors.danger)
            }
        } else {
            KeyValueRow("proto", handshake.proto.toString())
            KeyValueRow("worker caps", capsText(handshake.workerCapabilities))
            KeyValueRow("host caps", capsText(handshake.hostCapabilities))
            KeyValueRow("next_mseq", handshake.nextMseq.toString())
            KeyValueRow("acked_mseq", handshake.ackedMseq.toString())
            if (handshake.hostCapabilities.isEmpty() && channel.framesToWorker == 0L) {
                Spacer(Modifier.height(tokens.spacing.jsonStack))
                Line(
                    "宿主侧尚未发出 HELLO：host caps 为空，next_mseq / acked_mseq 尚未赋值。",
                    type.caption,
                    tokens.colors.tertiary,
                )
            }
        }
    }
}

@Composable
private fun ChannelCard(channel: ChannelStatus, hostState: HostState) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    // A live socket is not a usable host. While admission is closed the transport
    // may still be up, so the row says the host is unavailable instead of claiming
    // 「已连接」 (P10; BUG-2 fixed the same lie for a missing wal/1).
    val usable = hostUsable(hostState)
    val statusText = when {
        usable && channel.connected -> "已连接"
        usable -> "未连接"
        else -> "宿主不可用"
    }
    val statusColor = when {
        usable && channel.connected -> tokens.colors.success
        usable -> tokens.colors.tertiary
        else -> hostStateColor(hostState, tokens)
    }
    SectionCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Line("通道", type.secondary, tokens.colors.primary)
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(STATUS_DOT).clip(CircleShape).background(statusColor))
            Spacer(Modifier.width(tokens.spacing.iconText))
            Line(statusText, type.caption, statusColor)
        }
        if (!usable) {
            Spacer(Modifier.height(tokens.spacing.jsonStack))
            Line(
                "socket 的连通性与可写性是两件事：宿主处于 ${hostState.wireName}" +
                    "（admission ${hostState.admission.wireName}），新写入会被拒绝。",
                type.caption,
                tokens.colors.warning,
            )
        }
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        Line("收帧 = worker → 宿主；发帧 = 宿主 → worker。", type.caption, tokens.colors.tertiary)
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        KeyValueRow("收帧", channel.framesFromWorker.toString())
        KeyValueRow("发帧", channel.framesToWorker.toString())
        KeyValueRow("末帧类型", channel.lastFrameType ?: "—")
        KeyValueRow(
            label = "最近错误",
            value = channel.lastError ?: "—",
            valueColor = if (channel.lastError == null) tokens.colors.secondary else tokens.colors.danger,
        )
    }
}

@Composable
private fun TurnCard(turn: AppTurnState, onOpenWorkbench: (WorkbenchSection, String?) -> Unit) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    SectionCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Line("回合", type.secondary, tokens.colors.primary)
            Spacer(Modifier.weight(1f))
            Line(
                turn.label(),
                type.caption,
                when (turn) {
                    AppTurnState.Idle -> tokens.colors.tertiary
                    AppTurnState.Running -> tokens.colors.warning
                    is AppTurnState.Completed -> tokens.colors.success
                    is AppTurnState.Failed -> tokens.colors.danger
                },
            )
        }
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        when (turn) {
            AppTurnState.Idle ->
                Line("点「跑一轮」经宿主 /api 车道发起 session/prompt。", type.caption, tokens.colors.secondary)
            AppTurnState.Running ->
                Line("已发起，等待 worker 自己的 turn_ended。", type.caption, tokens.colors.secondary)
            is AppTurnState.Completed -> {
                // A restored completion is the *previous* process's turn; the card
                // says so instead of letting 「完成」 stand for "you just ran this".
                if (turn.restored) {
                    Line(AppTurnState.RESTORED_LINE, type.caption, tokens.colors.secondary)
                    Spacer(Modifier.height(tokens.spacing.jsonStack))
                }
                KeyValueRow("session", turn.sessionId)
                KeyValueRow("事件", turn.kinds.joinToString(", "))
                // §1: a tool-written path in the conversation opens the workbench
                // sheet. The row exists only when a tool event named the path, so
                // nothing here is inferred from a tool name alone.
                if (turn.commands.isNotEmpty()) {
                    Spacer(Modifier.height(tokens.spacing.jsonStack))
                    Line("工具命令", type.caption, tokens.colors.secondary)
                    turn.commands.forEach { command ->
                        ToolLink(
                            text = "· ${command.command}",
                            onClick = { onOpenWorkbench(WorkbenchSection.COMMANDS, null) },
                        )
                    }
                }
                if (turn.writes.isNotEmpty()) {
                    Spacer(Modifier.height(tokens.spacing.jsonStack))
                    Line("写出的文件", type.caption, tokens.colors.secondary)
                    turn.writes.forEach { write ->
                        ToolLink(
                            text = "· ${write.path}",
                            onClick = { onOpenWorkbench(WorkbenchSection.FILES, write.path) },
                        )
                    }
                }
            }
            is AppTurnState.Failed ->
                Line("原因：${turn.reason}", type.code, tokens.colors.danger)
        }
    }
}

@Composable
private fun ActionBar(
    state: EngineState,
    hostState: HostState,
    turn: AppTurnState,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onRunTurn: () -> Unit,
) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    val canStart = state == EngineHostState.Stopped || state is EngineHostState.Failed
    val canStop = state == EngineHostState.Starting || state == EngineHostState.Recovering || state is EngineHostState.Running
    Column(
        Modifier
            .fillMaxWidth()
            .background(tokens.colors.selector)
            .padding(
                horizontal = tokens.geometry.cardOuterMarginH,
                vertical = tokens.geometry.cardOuterMarginV,
            ),
    ) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.codeToolbar),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ActionButton(
                label = "启动",
                enabled = canStart,
                primary = true,
                modifier = Modifier.weight(1f).height(tokens.geometry.primaryButtonHeight),
                onClick = onStart,
            )
            ActionButton(
                label = "停止",
                enabled = canStop,
                primary = false,
                modifier = Modifier.weight(1f).height(tokens.geometry.secondaryButtonHeight),
                onClick = onStop,
            )
        }
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        ActionButton(
            label = "跑一轮",
            // Only an open admission can run a turn; a Running engine behind a
            // closed admission would fail every request (measured 12:01:19, P10).
            enabled = hostUsable(hostState) &&
                state is EngineHostState.Running &&
                turn != AppTurnState.Running,
            primary = false,
            modifier = Modifier.fillMaxWidth().height(tokens.geometry.secondaryButtonHeight),
            onClick = onRunTurn,
        )
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        Line(actionHint(state, hostState), type.caption, tokens.colors.tertiary)
    }
}

@Composable
private fun ActionButton(
    label: String,
    enabled: Boolean,
    primary: Boolean,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    val shape = RoundedCornerShape(tokens.radius.card)
    val background = when {
        !enabled -> tokens.colors.code
        primary -> tokens.colors.accent
        else -> tokens.colors.input
    }
    val ink = when {
        !enabled -> tokens.colors.tertiary
        primary -> tokens.colors.onAccent
        else -> tokens.colors.primary
    }
    val outline =
        if (enabled && !primary) Modifier.border(tokens.stroke.hairline, tokens.colors.border, shape) else Modifier
    Box(
        modifier
            .clip(shape)
            .background(background)
            .then(outline)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = BUTTON_INSET_H),
        contentAlignment = Alignment.Center,
    ) {
        Line(label, if (primary) type.body else type.secondary, ink)
    }
}

@Composable
private fun FooterNote() {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    Column(Modifier.fillMaxWidth()) {
        Line(
            "单视图不变量：本屏不创建、不持有浏览器视图，引擎独占那一个实例。",
            type.caption,
            tokens.colors.tertiary,
        )
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        Line(
            "数值来自 DemoEngine.state / channel / handshake；未握手时显示「等待握手」，不伪造结果。",
            type.caption,
            tokens.colors.tertiary,
        )
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        Line("所有数值与帧类型使用等宽字体。", type.caption, tokens.colors.tertiary)
        Spacer(Modifier.height(tokens.spacing.jsonStack))
        // The honest durability claim this round actually has evidence for
        // (docs/design/android-durability-decision-2026-11-01.md). The level-2
        // phrase is deliberately not printed: no device bench exists.
        Line(
            "持久化承诺：进程被杀不丢已实测；掉电（level-2）在真机未验证，" +
                "本屏不宣称「掉电最多丢最后一个纪元」。",
            type.caption,
            tokens.colors.tertiary,
        )
    }
}

// --------------------------------------------------------------------- atoms

@Composable
private fun SectionCard(content: @Composable () -> Unit) {
    val tokens = PdshThemeValues.tokens
    val shape = RoundedCornerShape(tokens.radius.card)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(tokens.colors.input)
            .border(tokens.stroke.hairline, tokens.colors.border, shape)
            .padding(tokens.geometry.cardPadding),
    ) {
        content()
    }
}

@Composable
private fun KeyValueRow(
    label: String,
    value: String,
    valueColor: Color? = null,
) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    Row(Modifier.fillMaxWidth().padding(vertical = ROW_INSET)) {
        Box(Modifier.width(LABEL_COLUMN)) {
            Line(label, type.caption, tokens.colors.secondary)
        }
        Spacer(Modifier.width(tokens.spacing.jsonStack))
        Line(value, type.code, valueColor ?: tokens.colors.primary, Modifier.weight(1f))
    }
}

@Composable
private fun Line(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
) {
    BasicText(text = text, modifier = modifier, style = style.copy(color = color))
}

// ------------------------------------------------------- unverified lengths
//
// tokens.json publishes no token for these five lengths. Each is named
// `unverified token` on purpose: the gap stays greppable instead of looking
// spec-derived. Every other length on this screen is a spec token.

/** unverified token: no rule-width token exists for the banner accent bar. */
private val BANNER_ACCENT_BAR: Dp = 3.dp

/** unverified token: no status-dot token; summaryDotDiameter (2) is a text separator. */
private val STATUS_DOT: Dp = 8.dp

/** unverified token: no label-column token; keeps monospaced values aligned. */
private val LABEL_COLUMN: Dp = 92.dp

/** unverified token: no button content-inset token. */
private val BUTTON_INSET_H: Dp = 12.dp

/** unverified token: no row-inset token; 2.dp keeps label/value rows readable. */
private val ROW_INSET: Dp = 2.dp

// ------------------------------------------------------------------ mappings

private fun stateLabel(state: EngineState): String = when (state) {
    EngineHostState.Stopped -> "已停止"
    EngineHostState.Starting -> "启动中"
    EngineHostState.Recovering -> "恢复中"
    is EngineHostState.Running -> "运行中"
    is EngineHostState.Failed -> "失败"
}

private fun stateCode(state: EngineState): String = when (state) {
    EngineHostState.Stopped -> "EngineHostState.Stopped"
    EngineHostState.Starting -> "EngineHostState.Starting"
    EngineHostState.Recovering -> "EngineHostState.Recovering"
    is EngineHostState.Running -> "EngineHostState.Running"
    is EngineHostState.Failed -> "EngineHostState.Failed"
}

private fun stateColor(state: EngineState, tokens: UiTokens): Color = when (state) {
    EngineHostState.Stopped -> tokens.colors.tertiary
    EngineHostState.Starting -> tokens.colors.warning
    EngineHostState.Recovering -> tokens.colors.warning
    is EngineHostState.Running -> tokens.colors.success
    is EngineHostState.Failed -> tokens.colors.danger
}

private fun waitingReason(state: EngineState, channel: ChannelStatus): String = when {
    state is EngineHostState.Failed -> "引擎失败，握手未发生。"
    state == EngineHostState.Stopped -> "引擎未启动，尚未建立通道。"
    state == EngineHostState.Starting -> "引擎启动中：正在物化 worker bundle。"
    state == EngineHostState.Recovering -> "渲染进程恢复中，等待页面重新握手。"
    channel.connected && channel.framesFromWorker > 0L ->
        "通道已连接，已收到 ${channel.framesFromWorker} 帧，但没有可解码的 HELLO。"
    channel.connected -> "通道已连接，尚未收到 HELLO。"
    else -> "页面已加载，通道尚未连接。"
}

private fun capsText(capabilities: List<String>): String =
    if (capabilities.isEmpty()) "—" else capabilities.joinToString(", ")

private fun actionHint(state: EngineState, hostState: HostState): String = when {
    // The host state wins: it is what actually decides whether a turn can run.
    !hostUsable(hostState) -> when (hostState) {
        HostState.DRAINING ->
            "收尾中：正在关闭 admission 并落盘当前纪元，随后自动进入后台暂停；回前台会自动恢复。"
        HostState.PARKED -> "已暂停（后台）：回到前台会重启 worker 并校验租约，然后恢复运行。"
        HostState.RECOVERING -> "恢复中：worker 与租约尚未就绪，admission 仍关闭。"
        HostState.FAILED -> "失败：只能由显式重置离开该状态（budgets.md §1），先看横幅里的原因。"
        else -> "宿主处于 ${hostState.wireName}（admission ${hostState.admission.wireName}），暂不可用。"
    }
    state == EngineHostState.Stopped -> "点「启动」物化内置 worker bundle，绑定 loopback origin 后加载页面。"
    state == EngineHostState.Starting -> "启动中；停止会取消本次启动。"
    state == EngineHostState.Recovering -> "恢复中；停止会释放 origin 与通道。"
    state is EngineHostState.Running -> "运行中；停止会关闭通道、origin，并清空 HELLO 摘要。"
    else -> "失败后可点「启动」重试；先看横幅里的原因。"
}

/** Whether the D14 host will accept work: only `Running` has an open admission. */
private fun hostUsable(hostState: HostState): Boolean = hostState == HostState.RUNNING

/** The host state's own words; the page never renders a state it is not in. */
private fun hostStateLabel(hostState: HostState): String = when (hostState) {
    HostState.RUNNING -> "运行中"
    HostState.DRAINING -> "收尾中（不可用）"
    HostState.PARKED -> "已暂停（后台）"
    HostState.RECOVERING -> "恢复中（不可用）"
    HostState.BACKOFF -> "等待网络（不可用）"
    HostState.HANDING_OFF -> "交接中（不可用）"
    HostState.REMOTE -> "远端持有（本机不可用）"
    HostState.RECLAIMING -> "收回中（不可用）"
    HostState.FAILED -> "已失败"
}

/** Green only for an open admission; everything else is a warning or a failure. */
private fun hostStateColor(hostState: HostState, tokens: UiTokens): Color = when (hostState) {
    HostState.RUNNING -> tokens.colors.success
    HostState.FAILED -> tokens.colors.danger
    else -> tokens.colors.warning
}

// The fixed sample data every baseline is captured from.
// SPDX-License-Identifier: MIT
//
// Screenshots compare pixels, so the input state must be frozen here and never
// read a clock, a locale, a file or the engine: these builders are pure and
// deterministic. The content is realistic (the kind of rows the six surfaces and
// the three pages actually render), not placeholder lorem ipsum, because a
// baseline only catches the layout a real state produces.
package com.phonedsh.ui.screenshot

import com.phonedsh.ui.page.BusyEnterMode
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.PermissionTier
import com.phonedsh.ui.page.SessionListing
import com.phonedsh.ui.page.SessionRunStatus
import com.phonedsh.ui.page.SessionsLocalState
import com.phonedsh.ui.page.SessionsScreenState
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.SettingsPlatformFacts
import com.phonedsh.ui.page.WebSearchSummary
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.state.BannerState
import com.phonedsh.ui.state.ChatPhase
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.ComposerState
import com.phonedsh.ui.state.ToolEntry
import com.phonedsh.ui.state.GoalBarState
import com.phonedsh.ui.state.PendingSlot
import com.phonedsh.ui.surface.ComposerMode
import com.phonedsh.ui.surface.ToolRowState
import java.time.ZoneId

/** Frozen sample states for the page baselines. */
object ScreenshotSamples {
    /** A fixed instant; every relative time label is computed against it. */
    const val NOW_MS: Long = 1_760_000_000_000L

    /** The zone relative labels are resolved in; passed explicitly, never the host's. */
    val ZONE: ZoneId = ZoneId.of("UTC")

    const val USER_TEXT: String = "把 PDSH 的像素基线跑一遍，先确认抓到的是真像素。"
    const val ASSISTANT_TEXT: String = "基线覆盖 6 个签名面、3 个整页，外加一个字高探针。"
    const val THINKING_SUMMARY: String = "先确认这条链路抓到的是真像素，再决定覆盖范围。"
    const val TOOL_TITLE: String = "screenshot-capture"
    const val TOOL_SUMMARY: String = "ok · 10 张"
    const val TOOL_BANNER: String = "bash android/tools/screenshot-capture.sh"
    const val TOOL_BODY: String =
        "capture  ok   10/10 PNG\n" +
            "compare  pass 0 changed pixels\n" +
            "probe    fontScale 1.0 -> 2.0, text box 52 px -> 99 px"
    const val APPROVAL_SUBTITLE: String = "工具 bash 想在工作区写入 3 个新文件（screenshots/*.png）。"
    const val APPROVAL_PRIMARY: String = "允许一次"
    const val APPROVAL_SECONDARY: String = "拒绝"
    const val COMPOSER_DRAFT: String = "确认一下像素阈值的理由"
    const val COMPOSER_STAT: String = "12.4k / 200k"
    const val BANNER_MESSAGE: String = "上游返回 502，本轮未完成；草稿已保留。"

    /** The chat page: a settled turn, one folded tool run, one thinking pill. */
    fun chatState(): ChatScreenState = ChatScreenState(
        sessionID = "sess-pixels",
        phase = ChatPhase.IDLE,
        rows = listOf(
            ChatRow.User("row-user-1", USER_TEXT),
            ChatRow.Thinking("row-thinking-1", THINKING_SUMMARY, streaming = false),
            ChatRow.ToolRun(
                id = "row-tool-1",
                entries = listOf(
                    ToolEntry(
                        id = "row-tool-1",
                        title = TOOL_TITLE,
                        summary = TOOL_SUMMARY,
                        state = ToolRowState.OK,
                        banner = TOOL_BANNER,
                        body = TOOL_BODY,
                    ),
                ),
            ),
            ChatRow.Assistant("row-assistant-1", ASSISTANT_TEXT),
        ),
        pending = PendingSlot(),
        banners = emptyList(),
        goal = GoalBarState.Hidden,
        expandedRowIds = emptySet(),
        stats = COMPOSER_STAT,
        // The host facts a screenshot sample pins: the engine is up and the
        // provider is configured, so the page shows the ready empty state behind
        // the rows instead of the "engine not started" one.
        empty = com.phonedsh.ui.state.ChatEmpty.READY,
        runStatus = com.phonedsh.ui.state.RunStatus.STARTED,
        transcript = com.phonedsh.ui.state.TranscriptState(),
        composer = ComposerState(
            draft = COMPOSER_DRAFT,
            mode = ComposerMode.SEND,
            enabled = true,
            canSubmit = true,
            placeholder = com.phonedsh.ui.UiStrings.COMPOSER_PLACEHOLDER_IDLE,
        ),
    )

    /** The chat page with a pending approval: the dock is visible but locked. */
    fun chatStateWithBanner(): ChatScreenState = chatState().copy(
        phase = ChatPhase.FAILED,
        banners = listOf(
            BannerState(
                id = "banner-1",
                message = BANNER_MESSAGE,
                reason = "upstream",
                retryable = true,
                dismissible = true,
            ),
        ),
    )

    /** The sessions page: four statuses, one selected row, one running row. */
    fun sessionsState(): SessionsScreenState = SessionsScreenState.from(
        sessions = listOf(
            SessionListing(
                id = "sess-a",
                title = "像素基线复盘",
                updatedAtMs = NOW_MS - 2L * 60_000L,
                status = SessionRunStatus.IDLE,
            ),
            SessionListing(
                id = "sess-b",
                title = "字体缩放验证",
                updatedAtMs = NOW_MS - 3L * 3_600_000L,
                status = SessionRunStatus.RUNNING,
            ),
            SessionListing(
                id = "sess-c",
                title = "会话列表回归",
                updatedAtMs = NOW_MS - 2L * 86_400_000L,
                status = SessionRunStatus.FAILED,
            ),
            SessionListing(
                id = "sess-d",
                title = "截图工具链",
                updatedAtMs = NOW_MS - 10L * 86_400_000L,
                status = SessionRunStatus.IDLE,
            ),
        ),
        local = SessionsLocalState(selectedID = "sess-a"),
        nowMs = NOW_MS,
        zone = ZONE,
    )

    /** The settings index: the mirrored rows with representative values. */
    fun settingsState(): SettingsScreenState = SettingsScreenState.from(
        facts = SettingsFacts(
            defaultPermissionTier = PermissionTier.WORKSPACE_WRITE,
            modelProviderName = "DeepSeek（本机）",
            mcpServerCount = 3,
            backgroundKeepAlive = FactState.YES,
            webSearch = WebSearchSummary.SEARCH_API,
            egressAddressCount = 4,
            busyEnterMode = BusyEnterMode.QUEUE,
            versionName = "0.1.0",
            engineStarted = FactState.YES,
            platform = SettingsPlatformFacts(
                notifications = FactState.YES,
                batteryExemption = FactState.NO,
                predictiveBack = FactState.YES,
            ),
        ),
    )
}

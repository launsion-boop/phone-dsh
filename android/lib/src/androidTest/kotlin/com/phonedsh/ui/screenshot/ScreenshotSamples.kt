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
import com.phonedsh.ui.page.AutomationFacts
import com.phonedsh.ui.page.AutomationScreenState
import com.phonedsh.ui.page.AutomationSnapshot
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.PermissionTier
import com.phonedsh.ui.page.NewSessionBlock
import com.phonedsh.ui.page.SessionListing
import com.phonedsh.ui.page.SessionRunStatus
import com.phonedsh.ui.page.SessionsLocalState
import com.phonedsh.ui.page.SessionsScreenState
import com.phonedsh.ui.page.SessionWorkspace
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
            enabled = true,
            canSubmit = true,
            placeholder = com.phonedsh.ui.UiStrings.COMPOSER_PLACEHOLDER_IDLE,
        ),
    )

    /**
     * `ios-chat-failed` / `page-chat-banner`: a failed turn with the top banner.
     *
     * `userFacingError` is set explicitly because this sample builds the screen
     * state directly instead of going through the projector, which derives it as
     * `banners.firstOrNull()?.message` (`ChatScreenState.kt:945`). Until L22 only
     * `banners` was set, so `ChatPage`'s `failedItemID == null &&
     * userFacingError != null` clause never fired: this state rendered the exact
     * same PNG as [chatState] and the `page-chat-banner` baseline was a false
     * green. `PageScreenshotTest` now asserts the banner node is actually on
     * screen before it captures.
     */
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
        // The field the page's banner clause reads; the projector sets it from
        // `banners` on the live path, this hand-built sample has to set it too.
        userFacingError = BANNER_MESSAGE,
    )

    /** The parity suite's name for [chatStateWithBanner]; kept for `ParityScreenshotTest`. */
    fun chatStateWithTopError(): ChatScreenState = chatStateWithBanner()

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

    // ------------------------------------------------- ios-parity profile only
    //
    // The three samples below exist because the iOS baseline publishes three chat
    // states the gate profile never needed (`ios-chat-draft`, `ios-chat-long`,
    // and the failed turn). They are extra *states*, not extra pages: no page
    // source had to change for them, which is the point of a state baseline.

    /** The draft length `ios-chat-draft.png` was captured with: exactly 5000 characters. */
    val LONG_DRAFT: String = run {
        val unit = "把 PDSH 的像素基线跑一遍，先确认抓到的是真像素。"
        val text = unit.repeat(5_000 / unit.length + 1).take(5_000)
        check(text.length == 5_000) { "the long draft must be exactly 5000 characters" }
        text
    }

    /** One assistant answer long enough to fill several lines at 402 pt. */
    const val LONG_ANSWER: String =
        "同口径采集只保证两件事：同样的视口、同样的状态名。字体栅格属于平台，" +
            "所以跨平台不做逐像素 diff，只把两张图并排审；Android 自己的 golden 才跑阈值比较。" +
            "这条回答刻意写长，让长会话状态里能出现换行、行高与段间距。"

    /**
     * `ios-chat-draft`: empty host + a 5000-character draft.
     *
     * The iOS shot shows the composer at its maximum height, which is what the
     * draft length is here to exercise (`geometry.composerMaxHeight`).
     */
    fun chatStateWithLongDraft(): ChatScreenState = chatState().copy(
        rows = emptyList(),
        empty = com.phonedsh.ui.state.ChatEmpty.ENGINE_NOT_STARTED,
        runStatus = com.phonedsh.ui.state.RunStatus.STOPPED,
        composer = chatState().composer.copy(draft = LONG_DRAFT, canSubmit = true),
    )

    /**
     * `ios-chat-long`: six long turns.
     *
     * The harness captures the first viewport of the transcript (it has no scroll
     * position), so this state measures row density and turn spacing, not the
     * bottom of a long conversation.
     */
    fun chatStateLongThread(): ChatScreenState {
        val rows = buildList {
            repeat(6) { turn ->
                add(ChatRow.User("row-user-long-$turn", "$USER_TEXT（第 ${turn + 1} 轮）"))
                add(ChatRow.Assistant("row-assistant-long-$turn", LONG_ANSWER, closing = true))
            }
        }
        return chatState().copy(rows = rows, expandedRowIds = emptySet())
    }

    // ------------------------------------------------------ sessions family
    //
    // The six `ios-sessions-*.png` drawer states plus the schedules page. Every
    // state mirrors the baseline's own preview data, not a convenient one:
    // `DSHManagementModel.installPreviewData` in the iOS probe app builds
    // `会话Count` rows titled 预览会话 N (every 7th one untitled, starting at
    // index 3), `updatedAt = now - index hours`, `running = index == 1`, and deals
    // them across the workspaces by `index % workspaceCount`. The numbers below
    // are that generator's, so a row's title, its relative time and its folder
    // are the ones the screenshot shows.

    /** The engine-off sentence the drawer shows under 新建会话 in every capture. */
    private val engineOff: NewSessionBlock = NewSessionBlock.ENGINE_NOT_STARTED

    /** The host's forced read failure in `ios-sessions-error.png`. */
    const val SESSIONS_FAILURE: String = "读不到会话"

    /**
     * The baseline's preview generator for one workspace index.
     *
     * @param sessionCount how many sessions the host lists.
     * @param workspaceCount how many folders it lists; 0 leaves every session
     *   ungrouped, which is the `ungrouped` state.
     */
    private fun previewSessions(
        sessionCount: Int,
        workspaceCount: Int,
    ): Pair<List<SessionListing>, List<SessionWorkspace>> {
        val ids = (0 until sessionCount).map { "preview-s-$it" }
        val rows = (0 until sessionCount).map { index ->
            SessionListing(
                id = ids[index],
                // Every 7th index (starting at 3) has no host title: the page
                // rewords it to 新会话 instead of printing an empty row.
                title = if (index % 7 == 3) "" else "预览会话 ${index + 1}",
                updatedAtMs = NOW_MS - index * 3_600_000L,
                status = if (index == 1) SessionRunStatus.RUNNING else SessionRunStatus.IDLE,
            )
        }
        val folders = (0 until workspaceCount).map { index ->
            val title = if (index == 0) "项目资料" else "设计稿 $index"
            SessionWorkspace(
                id = "preview-ws-$index",
                title = title,
                // The model deals sessions by `index % workspaceCount`.
                sessionIDs = ids.filterIndexed { session, _ ->
                    session % workspaceCount.coerceAtLeast(1) == index
                },
            )
        }
        return rows to folders
    }

    private fun sessionState(
        sessionCount: Int,
        workspaceCount: Int,
        failure: String? = null,
    ): SessionsScreenState {
        val (rows, folders) = previewSessions(sessionCount, workspaceCount)
        return SessionsScreenState.from(
            sessions = rows,
            nowMs = NOW_MS,
            zone = ZONE,
            failure = failure,
            workspaces = folders,
            archivedSessions = emptyList(),
            newSessionBlock = engineOff,
        )
    }

    /**
     * `ios-sessions-default.png` and `ios-sessions-nothing.png`: no folder, no
     * session, no archive, engine off — the drawer's big empty block.
     *
     * The two iOS shots are the same *state* in two containers: `.sessions`
     * renders `SessionsPage` directly in the 402 pt window and `sessions.nothing`
     * wraps it in `DrawerPreview` at 320 pt (`NativeShell.swift:842`, `:872-879`).
     * Measured, they differ by 74,939 px in y 223.7–398.3 pt: the empty block's
     * centre (201 vs 159.7), its hint, the CTA width (370 vs 288) and the
     * new-session separator (57 → 345 vs 16 → 304). No section label differs —
     * neither shot draws one. Since L73 the page fills its container, so the two
     * Android captures differ the same way; see
     * `SessionsParityScreenshotTest.captureSessions(drawer = …)`.
     */
    fun sessionsNothing(): SessionsScreenState = sessionState(sessionCount = 0, workspaceCount = 0)

    /** `ios-sessions-empty.png`: two folders, each showing 还没有会话. */
    fun sessionsEmpty(): SessionsScreenState = sessionState(sessionCount = 0, workspaceCount = 2)

    /** `ios-sessions-many.png`: 40 sessions dealt across two folders (20 each). */
    fun sessionsMany(): SessionsScreenState = sessionState(sessionCount = 40, workspaceCount = 2)

    /** `ios-sessions-ungrouped.png`: three sessions and no folder at all. */
    fun sessionsUngrouped(): SessionsScreenState =
        sessionState(sessionCount = 3, workspaceCount = 0)

    /** `ios-sessions-error.png`: one folder with two rows over a failed read. */
    fun sessionsError(): SessionsScreenState = sessionState(
        sessionCount = 2,
        workspaceCount = 1,
        failure = SESSIONS_FAILURE,
    )

    /**
     * `ios-sessions-schedules.png`: no schedule, plus the host's raw read failure.
     *
     * The baseline prints the untranslated probe error verbatim (a real baseline
     * defect, recorded in `VISUAL.md`); this sample uses the same sentence so the
     * error row is compared against the same width.
     */
    fun automationState(): AutomationScreenState = AutomationScreenState.from(
        AutomationFacts(
            snapshot = AutomationSnapshot(schedules = emptyList()),
            failure = "The operation couldn't be completed. (ProbeKit.ProbeHostError error 3.)",
        ),
    )
}

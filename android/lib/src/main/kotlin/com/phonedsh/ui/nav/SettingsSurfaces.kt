// The two settings-sheet surfaces that are not routes: 关于 and 开发者工具.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1. The iOS settings sheet owns both faces:
// `SettingsAboutPage` is the settings family's about page (`NativeShell.swift:897`,
// preview-only after PR #13), and the developer-tools page that hosted
// `MemoryPage` / `ProbesPage` / `BackgroundPage` / `TaskScreenPage` was deleted by
// the same PR (§1 records all four as 不可达). Android implements every one of
// those pages and every one of them had no caller — the L55 audit's zero-call
// list.
//
// They are rendered here instead of on the route stack on purpose:
//
//   * the about page and the developer index are **children of the settings
//     sheet** in the baseline, exactly like 新会话默认权限, which this router
//     already swaps in place (`SettingsRoute`'s `permissionDefaults`);
//   * adding `PdshRoute` subtypes would break `:app`'s exhaustive
//     `hostRouteNote(route: PdshRoute)` when-expression, a file this lane may not
//     edit, for surfaces that are not routes on either platform.
//
// So the reachable path is: drawer → 设置 → 通用 (or the tab that was open) →
// 版本 → 关于, and 设置 → 通用 → 开发者工具 → one page. The contract gate cannot
// see a settings row, which is why every one of these paths is also proven on a
// device (the L55 report carries the uiautomator dumps).
//
// L72 appended 工作文件夹 and 命令 for a different reason: their iOS entries are
// surfaces of the chat page (the DEBUG preview router, and 工作面板's 命令
// segment), and this host's chat page still has neither. They live here rather
// than in the drawer because iOS's drawer is the session list plus 定时任务 and
// 设置 — the eight Android rows that used to mirror the app map were the defect
// this lane removed.
//
// ---- the empty-callback rule (L81) ----------------------------------------
// L75 counted twelve empty callbacks and twenty-three never passed. Every one of
// them in this file is now one of three things, and none is a silent tap:
//
//   * **real** — 工作文件夹's 重试 and 命令's 运行 reach a `PdshHostAction` whose
//     handler in `:app` performs a read or answers with its own fact; the two
//     local scripts (会话活动's disclosure and dialog, 每日简报's share sheet) move
//     the page's own state or start the system chooser;
//   * **answered** — the diagnostic pages' run gestures ask for a probe runner
//     (memory overlay, probe batch, background matrix) that no part of this build
//     carries. Their pages own their whole frame and several draw the verb
//     unconditionally, so the answer is a transient band over the page naming what
//     is missing ([SurfaceAnswerBand]) instead of a tap that does nothing. The
//     page stays reachable (the L55 win) and nothing claims a run happened;
//   * **absent** — where a page already gates a verb on a callback, it stays
//     `null`, which the page draws as disabled (`ProbesPage`'s Reset / Run one
//     group, `BackgroundPage`'s three matrix cells and its Cancel). A disabled
//     control is a state a screen reader reports; a missing one is not the same
//     claim as a dead one.
//
// 后台保活 also stops drawing its matrix cells and Cancel: the page's own
// `BackgroundScreenState` disables them because the host measured no cell, and the
// surface passes them as `null` instead of pretending they are live.
package com.phonedsh.ui.nav

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.AboutFacts
import com.phonedsh.ui.page.AboutLocalState
import com.phonedsh.ui.page.AboutPage
import com.phonedsh.ui.page.AboutScreenState
import com.phonedsh.ui.page.AboutUiEvent
import com.phonedsh.ui.page.BackgroundPage
import com.phonedsh.ui.page.BackgroundScreenState
import com.phonedsh.ui.page.DailyBriefFacts
import com.phonedsh.ui.page.DailyBriefPage
import com.phonedsh.ui.page.DailyBriefScreenState
import com.phonedsh.ui.page.InfoRow
import com.phonedsh.ui.page.MemoryFacts
import com.phonedsh.ui.page.MemoryPage
import com.phonedsh.ui.page.MemoryScreenState
import com.phonedsh.ui.page.PDSHShellPage
import com.phonedsh.ui.page.PageFrame
import com.phonedsh.ui.page.ProbesFacts
import com.phonedsh.ui.page.ProbesPage
import com.phonedsh.ui.page.ProbesScreenState
import com.phonedsh.ui.page.SessionActivityPage
import com.phonedsh.ui.page.SessionActivityLocalState
import com.phonedsh.ui.page.SessionActivityScreenState
import com.phonedsh.ui.page.SessionActivitySource
import com.phonedsh.ui.page.SessionActivityUiEvent
import com.phonedsh.ui.page.ShellLocalState
import com.phonedsh.ui.page.ShellUiEvent
import com.phonedsh.ui.page.TaskScreenFacts
import com.phonedsh.ui.page.TaskScreenLocalState
import com.phonedsh.ui.page.TaskScreenPage
import com.phonedsh.ui.state.StateRequestId
import java.util.UUID
import com.phonedsh.ui.page.TaskScreenScreenState
import com.phonedsh.ui.page.TaskScreenUiEvent
import com.phonedsh.ui.page.ToolsScreenState
import com.phonedsh.ui.page.WorkspaceFoldersLocalState
import com.phonedsh.ui.page.WorkspaceFoldersPage
import com.phonedsh.ui.page.WorkspaceFoldersScreenState
import com.phonedsh.ui.page.WorkspaceFoldersUiEvent
import com.phonedsh.ui.page.apply
import com.phonedsh.ui.surface.preview.PreviewShare
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import kotlinx.coroutines.delay

/** Which settings-sheet surface replaced the index (and [NONE] is the index). */
internal enum class SettingsSurface {
    /** The 通用 tab's own body. */
    NONE,

    /** 关于: the settings about page. */
    ABOUT,

    /** 开发者工具: the Android-only index of the pages iOS left without an entry. */
    DEV_TOOLS,
}

/**
 * The one page the developer index can open.
 *
 * The last two entries are not orphaned in the baseline the way the first six are
 * (`MemoryPage` … `SessionActivityPage` have no call site at all): iOS reaches
 * 工作文件夹 only from its DEBUG preview router, and 命令 only from the chat
 * page's 右侧边栏 → 工作面板 命令 segment. Neither edge exists on this host —
 * the chat page's page-head menu is the chat lane's file, and `PreviewScreen` is a
 * DEBUG launch router this host does not carry — so the two pages live here while
 * they have no product entry. They are the same pages, rendered from the same
 * facts and local state their routes use (`PdshNavHost`'s `WorkspaceFoldersRoute` /
 * `ToolsRoute`); when those entries land, the rows below are the duplicate to drop.
 *
 * @param label the page's own title, so the row and the header are one word.
 * @param readOnly why this host cannot run this page's gestures, or `null` for the
 *   three pages that work (工作文件夹's retry and run handoffs, 命令's form).
 */
private enum class DevTool(val label: String, val readOnly: String?) {
    MEMORY(UiStrings.MEMORY_PROBE_TITLE, MEMORY_READ_ONLY),
    PROBES(UiStrings.PROBES_TITLE, PROBES_READ_ONLY),
    BACKGROUND(UiStrings.BACKGROUND_TITLE, BACKGROUND_READ_ONLY),
    TASK_SCREEN(UiStrings.TASK_SCREEN_TITLE, TASK_SCREEN_READ_ONLY),
    DAILY_BRIEF(UiStrings.DAILY_BRIEF_TITLE, DAILY_BRIEF_READ_ONLY),
    ACTIVITY(UiStrings.ACTIVITY_TITLE, ACTIVITY_READ_ONLY),
    WORKSPACE_FOLDERS(UiStrings.WORKSPACE_FOLDERS, null),
    COMMAND(UiStrings.TOOLS, null),
}

/**
 * 关于: source branding and the host's actual package version/build facts.
 * The raw version avoids carrying an index-only signing annotation into About.
 *
 * @param facts the host snapshot.
 * @param onBack return to the settings index.
 * @param backLevel the host's inner-level back chain, registered while the page is
 *   open so the system gesture returns to the index instead of closing the sheet.
 */
@Composable
internal fun AboutSurface(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    backLevel: PdshBackLevel? = null,
) {
    // One registration while this surface is the sheet's body: `PdshBackLevel` holds
    // one entry, so the surface owns it and the page never nests a second one.
    SurfaceBackLevel(backLevel, enabled = true) { onBack() }
    var local by remember { mutableStateOf(AboutLocalState()) }
    AboutPage(
        state = AboutScreenState.from(
            facts = AboutFacts(
                version = facts.settings.rawVersionName ?: facts.settings.versionName,
                buildNumber = facts.settings.buildNumber,
            ),
            local = local,
        ),
        onToggleSection = { id -> local = local.apply(AboutUiEvent.ToggleSection(id)) },
        onBack = onBack,
        onOpenLicenses = null,
        onOpenDeveloper = null,
    )
}

/**
 * 开发者工具: the index of the pages this host cannot reach the way iOS does.
 *
 * Two kinds of row live here: the pages the baseline deleted an entry for
 * (`MemoryPage` … `SessionActivityPage`, see [DevTool]), and the pages whose iOS
 * entry is a surface of the chat page this host has not wired yet (工作文件夹's
 * preview router, 命令's 工作面板 segment). The drawer is not a home for either —
 * iOS's drawer is the session list plus 定时任务 / 设置 and nothing else.
 *
 * A read-only row says so *before* the page opens ([DevTool.readOnly] is its value
 * column), and a gesture made inside one answers over the page
 * ([SurfaceAnswerBand]) instead of tapping into nothing.
 *
 * @param facts the host snapshot; the background page reads its own field from it.
 * @param onBack return to the settings index.
 * @param backLevel the host's inner-level back chain; the sheet-level back leaves
 *   the open page first, then the index.
 * @param onAction the host action channel: the two action rows (revoking the
 *   session's Ubuntu approval, and 工作文件夹's "open this folder's files") and the
 *   command page's run gesture.
 */
@Composable
internal fun DeveloperToolsSurface(
    facts: PdshNavFacts,
    onBack: () -> Unit,
    backLevel: PdshBackLevel? = null,
    onAction: (PdshHostAction) -> Unit = {},
    actionAvailability: PdshActionAvailabilities = PdshActionAvailabilities(),
) {
    val context = LocalContext.current
    var open by remember { mutableStateOf<DevTool?>(null) }
    // The revoke row is an action, not a page: it clears the session's Ubuntu
    // approval and leaves the index open, so the person sees the row's own
    // answer instead of landing on a screen with nothing on it.
    var revoked by remember { mutableStateOf<String?>(null) }
    // The answer band's one line: whatever gesture this build cannot perform said
    // what it was missing, over the page that offered it.
    var answer by remember { mutableStateOf<String?>(null) }
    // The surface always owns the one level while it is the sheet's body: a page
    // open means "back to the index", the index means "back to the settings".
    SurfaceBackLevel(backLevel, enabled = true) {
        if (open != null) open = null else onBack()
    }
    val tool = open
    if (tool == null) {
        PageFrame(title = DEV_TOOLS_TITLE, onBack = onBack) {
            LazyColumn(Modifier.fillMaxSize()) {
                items(DevTool.entries.size) { index ->
                    val entry = DevTool.entries[index]
                    InfoRow(
                        title = entry.label,
                        // The read-only sentence is the row's value, so it is read
                        // before the page opens rather than discovered by tapping.
                        value = entry.readOnly,
                        onClick = {
                            answer = null
                            open = entry
                        },
                    )
                }
                item {
                    InfoRow(
                        title = REVOKE_UBUNTU_TITLE,
                        // The value is the host's answer, never a local guess: the
                        // row only says something after the host wrote back.
                        value = revoked,
                        onClick = {
                            revoked = null
                            onAction(PdshHostAction.RevokeUbuntuApproval)
                            revoked = REVOKE_UBUNTU_ANSWER
                        },
                    )
                }
            }
        }
        return
    }
    Box(Modifier.fillMaxSize()) {
        when (tool) {
            DevTool.MEMORY -> MemoryPage(
                state = MemoryScreenState.from(MemoryFacts()),
                // The page's rows are already disabled (the host measured no probe
                // bundle), so these cannot fire today; if a future host measures one,
                // the tap answers instead of running a probe this build does not have.
                onRunOverlay = { answer = MEMORY_READ_ONLY },
                onRunLongSession = { answer = MEMORY_READ_ONLY },
                onCancel = { answer = MEMORY_READ_ONLY },
                onBack = { open = null; answer = null },
            )

            DevTool.PROBES -> ProbesPage(
                state = ProbesScreenState.from(ProbesFacts()),
                onBack = { open = null; answer = null },
                onRunAll = { answer = PROBES_READ_ONLY },
                // Reset and Run one group stay `null`: the page draws both disabled
                // (a state a screen reader reports) instead of a dead press.
            )

            DevTool.BACKGROUND -> BackgroundPage(
                state = BackgroundScreenState.from(facts.background),
                onBack = { open = null; answer = null },
                onStart = { answer = BACKGROUND_READ_ONLY },
                // The matrix cells and Cancel stay `null`: the page disables them,
                // and this host has no background runner to feed them.
            )

            DevTool.TASK_SCREEN -> {
                var local by remember { mutableStateOf(TaskScreenLocalState()) }
                TaskScreenPage(
                    state = TaskScreenScreenState.from(TaskScreenFacts(), local),
                    onBack = { open = null; answer = null },
                    // The cover is the page's own state (`TaskScreenPage.swift:15`);
                    // the host handoff is a notification, and this build has no
                    // background task screen to show. Answering keeps the tap from
                    // looking missed even though the cover still opens locally.
                    onShowTaskScreen = { _, _ -> answer = TASK_SCREEN_READ_ONLY },
                    onStatusLineChange = { text ->
                        local = local.apply(TaskScreenUiEvent.EditStatusLine(text))
                    },
                    onBrightnessChange = { value ->
                        local = local.apply(TaskScreenUiEvent.EditMinimumBrightness(value))
                    },
                )
            }

            DevTool.DAILY_BRIEF -> {
                // The share sheet is the page's own action (`:310`-style ShareLink):
                // the text comes from the host's brief snapshot, and the page itself
                // hides the verb while the host has no text worth sharing.
                val briefFacts = DailyBriefFacts()
                val briefState = DailyBriefScreenState.from(briefFacts)
                val shareText = briefFacts.snapshot?.shareText?.takeIf { it.isNotBlank() }
                DailyBriefPage(
                    state = briefState,
                    onRefresh = { answer = DAILY_BRIEF_READ_ONLY },
                    onBack = { open = null; answer = null },
                    onShare = shareText?.let { text ->
                        {
                            if (!sharePlainText(context, text)) {
                                answer = UiStrings.PREVIEW_SHARE_FAILED
                            }
                        }
                    },
                )
            }

            DevTool.ACTIVITY -> {
                // The page's disclosure and its dialog are local scripts, so they
                // move `local`; a refresh needs an activity read this host does not
                // have, and 确认 would need the command behind the dialog. Both
                // answer instead of doing nothing.
                var local by remember { mutableStateOf(SessionActivityLocalState()) }
                SessionActivityPage(
                    state = SessionActivityScreenState.from(SessionActivitySource(), local),
                    onRefresh = { answer = ACTIVITY_READ_ONLY },
                    onToggleError = { key ->
                        local = local.apply(SessionActivityUiEvent.ToggleError(key))
                    },
                    onConfirm = {
                        local = local.apply(SessionActivityUiEvent.Confirmed)
                        answer = ACTIVITY_READ_ONLY
                    },
                    onCancel = { local = local.apply(SessionActivityUiEvent.Cancel) },
                    onBack = { open = null; answer = null },
                )
            }

            // 工作文件夹: the baseline's preview-only folder page. Its one navigation
            // relation (§1: 每行打开 FilesPage) is the documented handoff whose whole
            // meaning is "this folder asked for its file listing"
            // (`PdshHostAction.OpenWorkspaceFiles`); the shell answers it by pushing
            // the files route, because this surface has no route stack of its own.
            // 重试 is the same kind of handoff (`RefreshWorkspace`): the host re-reads
            // the one workspace fact it owns, so the verb really re-reads.
            DevTool.WORKSPACE_FOLDERS -> {
                var local by remember { mutableStateOf(WorkspaceFoldersLocalState()) }
                WorkspaceFoldersPage(
                    state = WorkspaceFoldersScreenState.from(facts.workspaceFolders, local),
                    onBack = { open = null; answer = null },
                    onOpenFiles = { folder ->
                        onAction(PdshHostAction.OpenWorkspaceFiles(folder.id))
                    },
                    onSwitch = { folder -> onAction(PdshHostAction.WorkspaceSwitch(folder.id)) },
                    onBeginCreate = { local = local.apply(WorkspaceFoldersUiEvent.BeginCreate) },
                    onDraftChange = { text ->
                        local = local.apply(WorkspaceFoldersUiEvent.DraftChange(text))
                    },
                    onCancelCreate = { local = local.apply(WorkspaceFoldersUiEvent.CancelCreate) },
                    onCreate = { onAction(PdshHostAction.WorkspaceCreate(local.draft)) },
                    onDeleteRequest = { folder ->
                        local = local.apply(WorkspaceFoldersUiEvent.RequestDelete(folder.id))
                    },
                    onDeleteConfirm = { folder ->
                        local = local.apply(WorkspaceFoldersUiEvent.CancelDelete)
                        onAction(PdshHostAction.WorkspaceDelete(folder.id))
                    },
                    onDeleteCancel = { local = local.apply(WorkspaceFoldersUiEvent.CancelDelete) },
                    onRetry = { onAction(PdshHostAction.RefreshWorkspace) },
                )
            }

            // 命令: the read-only accelerator shell uses the same typed ExecBridge
            // actions as the standalone tools route.
            DevTool.COMMAND -> {
                var local by remember { mutableStateOf(ShellLocalState()) }
                val state = ToolsScreenState.from(facts.shell, local)
                val runCapability = actionAvailability.forAction(PdshActionKey.EXECUTE_COMMAND)
                val cancelCapability = actionAvailability.forAction(PdshActionKey.SHELL_CANCEL)
                PDSHShellPage(
                    state = state,
                    onSelectCommand = { name ->
                        local = local.apply(ShellUiEvent.SelectCommand(name))
                    },
                    onWorkingDirectoryChange = { value ->
                        local = local.apply(ShellUiEvent.SetWorkingDirectory(value))
                    },
                    onArgumentsChange = { value ->
                        local = local.apply(ShellUiEvent.SetArguments(value))
                    },
                    onRun = when (runCapability) {
                        is PdshActionAvailability.Unavailable -> null
                        is PdshActionAvailability.Available -> {
                            {
                                runCapability.callback(
                                    PdshUiHostCommand.ExecuteCommand(
                                        command = state.selectedCommand,
                                        workingDirectory = state.workingDirectory,
                                        arguments = state.arguments,
                                        requestId = StateRequestId("ui.exec." + UUID.randomUUID().toString()),
                                    ),
                                )
                            }
                        }
                    },
                    onCancel = when (cancelCapability) {
                        is PdshActionAvailability.Unavailable -> null
                        is PdshActionAvailability.Available -> facts.shell.run.runningExecId?.let { execId ->
                            {
                                cancelCapability.callback(
                                    PdshUiHostCommand.ShellCancel(
                                        execId,
                                        StateRequestId("ui.exec.cancel." + UUID.randomUUID().toString()),
                                    ),
                                )
                            }
                        }
                    },
                    onBack = { open = null; answer = null },
                )
            }
        }
        SurfaceAnswerBand(answer) { answer = null }
    }
}

/**
 * The one-line answer a read-only diagnostic page gives, over the page itself.
 *
 * It is transient ([ANSWER_MILLIS]) and it never claims an action ran: it names
 * the command the gesture needed. The alternative — leaving the callback empty —
 * is a tap that reads as a missed one, which is the defect this band exists to
 * remove. Drawn over the page rather than inside it because these pages own their
 * whole frame and this file may not change them.
 *
 * @param text the sentence, or `null` when there is nothing to say.
 * @param onDismiss clear the line (it is also cleared when the page is left).
 */
@Composable
private fun SurfaceAnswerBand(text: String?, onDismiss: () -> Unit) {
    if (text == null) return
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    LaunchedEffect(text) {
        delay(ANSWER_MILLIS)
        onDismiss()
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        BasicText(
            text = text,
            style = type.secondary.copy(color = tokens.colors.warning),
            modifier = Modifier
                .fillMaxWidth()
                .background(tokens.colors.input)
                .padding(
                    horizontal = tokens.geometry.pageOuterMarginH,
                    vertical = tokens.spacing.cardInset,
                )
                // Fail-loud is audible too: an assertive live region interrupts.
                .semantics { liveRegion = LiveRegionMode.Assertive },
        )
    }
}

/**
 * Starts the system share sheet with one block of text — the Android form of the
 * baseline's `ShareLink(item: brief.shareText)`.
 *
 * A refused start (no activity can receive it) is reported by the caller; nothing
 * here invents a share.
 */
private fun sharePlainText(context: Context, text: String): Boolean {
    val send = Intent(Intent.ACTION_SEND).apply {
        type = TEXT_PLAIN
        putExtra(Intent.EXTRA_TEXT, text)
    }
    return PreviewShare.start(context, Intent.createChooser(send, UiStrings.DAILY_BRIEF_SHARE_ACTION))
}

/**
 * Registers the index→page back level while a page is open.
 *
 * `RouteBackLevel` is private to `PdshNavHost.kt`; this is the same registration
 * for a surface that file does not own. The identity-checked unregister inside
 * [PdshBackLevel] keeps the nesting safe when the index leaves the composition
 * while the settings sheet is still open.
 */
@Composable
private fun SurfaceBackLevel(backLevel: PdshBackLevel?, enabled: Boolean, onBack: () -> Unit) {
    val current by rememberUpdatedState(onBack)
    DisposableEffect(backLevel, enabled) {
        if (backLevel == null || !enabled) {
            return@DisposableEffect onDispose {}
        }
        val action: () -> Unit = { current() }
        backLevel.register(action)
        onDispose { backLevel.unregister(action) }
    }
}

/** The 开发者工具 header. The baseline deleted this page, so there is no iOS word. */
private const val DEV_TOOLS_TITLE: String = "开发者工具"

/** The revoke row: it names the thing and the scope, not just the verb. */
private const val REVOKE_UBUNTU_TITLE: String = "撤销本地 Ubuntu 授权（本会话）"

/**
 * What the row says after the action is dispatched.
 *
 * It stops short of "revoked": the host owns the gate and this surface cannot see
 * whether one was granted, so the sentence says what was asked, and the next
 * `ubuntu run` is what proves it either way.
 */
private const val REVOKE_UBUNTU_ANSWER: String = "已请求撤销；下一次 ubuntu run 会重新询问"

/** How long an answer band stays up; long enough to read one sentence, then gone. */
private const val ANSWER_MILLIS: Long = 4_000

/** The one type a text share can declare honestly. */
private const val TEXT_PLAIN: String = "text/plain"

// The read-only sentences. Each names the command the gesture needed, so the
// answer is a fact about this build rather than a generic refusal.

/** Memory overlay: iOS runs a probe bundle this build does not install. */
private const val MEMORY_READ_ONLY: String =
    "本宿主没有安装内存探针 bundle，也没有它的运行命令；页面保持只读，本次没有开始测量"

/** Probe batch: the probe runner is an engine capability this build does not carry. */
private const val PROBES_READ_ONLY: String =
    "本宿主没有探针执行器，本次没有运行任何探针"

/** Background matrix: no background runner, so no cell can be started or observed. */
private const val BACKGROUND_READ_ONLY: String =
    "本宿主没有后台矩阵执行器，本次没有开始测量"

/** Task screen: the cover is local, but the host has no task-screen command. */
private const val TASK_SCREEN_READ_ONLY: String =
    "本宿主没有任务屏命令；屏幕只按页面自己的状态显示"

/** Daily brief: a refresh needs a brief generator this build does not carry. */
private const val DAILY_BRIEF_READ_ONLY: String =
    "本宿主没有简报生成命令，本次没有刷新"

/** Session activity: the host has no activity read, so 刷新/确认 cannot run one. */
private const val ACTIVITY_READ_ONLY: String =
    "本宿主没有读取或改写本会话活动的命令，页面保持只读"

/** Shell cancel: the run verb is a handoff; no exec channel exists to cancel. */
private const val SHELL_CANCEL_READ_ONLY: String =
    "本宿主没有可取消的执行通道；上一次运行没有在本机开始"

// The host shell: drawer, page stack, back gesture and the Web surface container.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (the 入口 column: 抽屉「工作文件夹」、
// 抽屉「定时任务」、页头 `⋯`、设置首行/设置内、页头运行状态点、引擎就绪时的默认面),
// §2 (`back-gesture` in §5: the stack pops one level per gesture) and §3.1 (a page
// is a pure function of facts and local state; nothing here reads the engine for
// a page).
//
// This file owns the three things a page library cannot own:
//
//   * the page stack ([PdshNavState]) and the system back gesture;
//   * the drawer and the page-header entries §1 names;
//   * the engine's one WebView as the Web surface's `surface` slot — the engine
//     owns the instance, this app only attaches it and never creates a second.
//
// Facts come from [ProbeEngineViewModel.navFacts]; every field the host could
// not read stays unknown inside that snapshot, so no page here shows a value the
// host did not measure. Write gestures reach [handleHostAction], which logs the
// handoff and performs only the actions this host really owns (engine stop and
// engine start).
//
// The one deliberate deviation from §1 is recorded at [HostShell]: the Web
// surface is the engine-ready default face only when the launch asks for it
// (`pdsh.face.web`), because the demo acceptance taps 跑一轮 on the native face
// after the worker is ready.
package com.phonedsh.probe

import android.util.Log
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import com.phonedsh.engine.ChannelStatus
import com.phonedsh.engine.EngineState
import com.phonedsh.engine.HandshakeSummary
import com.phonedsh.engine.KernelVerdict
import com.phonedsh.platform.EngineHostState
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.nav.SettingsWrite
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.page.WorkbenchSection
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.PdshThemeValues

/**
 * The app's one screen: the navigation shell around every routed page.
 *
 * @param engine the composition root, read for facts and the WebView instance.
 * @param state the engine lifecycle state (also the runtime page's engine fact).
 * @param handshake the merged HELLO; its presence is what makes the Web surface
 *   live, because a HELLO can only come from the loaded page.
 * @param channel the channel counters (the native face renders them).
 * @param turn the one turn's state (the workbench's tool output comes from it).
 * @param recoveryNotice the fail-loud report from a previous process death, a torn
 *   WAL tail or an unreadable reclaim token; `null` when nothing is wrong.
 * @param onStart start the engine.
 * @param onStop stop the engine.
 * @param onRunTurn run one turn through the App's own `/api` lane.
 */
@Composable
internal fun HostShell(
    engine: ProbeEngineViewModel,
    state: EngineState,
    hostState: com.phonedsh.controller.HostState,
    handshake: HandshakeSummary?,
    channel: ChannelStatus,
    turn: AppTurnState,
    recoveryNotice: RecoveryNotice?,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onRunTurn: () -> Unit,
) {
    // The facts are one host walk per lifecycle/HELLO/turn change: a page never
    // asks the host for anything itself.
    val facts: PdshNavFacts = remember(state, handshake, turn) {
        engine.navFacts(state, handshake, turn)
    }
    var nav by remember { mutableStateOf(PdshNavState()) }
    var drawerOpen by remember { mutableStateOf(false) }
    // The sessions page is the drawer's body in the baseline. It is not one of
    // the routed pages (`:lib`'s routes do not name it yet), so this host keeps
    // it as a full-screen layer over the native face instead of inventing a
    // route the router cannot resolve.
    var sessionsOpen by remember { mutableStateOf(false) }
    var webFaceOpened by remember { mutableStateOf(false) }
    val webFaceOnLaunch = remember { engine.webFaceOnLaunch() }

    // The host's own voice. A page owns its controls, so this host cannot render
    // a button disabled; what it can do is state the truth on every route that
    // has no write command, and state the outcome of every gesture it cannot
    // complete. A dead button that says nothing reads as a missed tap.
    var notice by remember { mutableStateOf<String?>(null) }
    val routeNote: String? = hostRouteNote(nav.current)
    LaunchedEffect(notice) {
        if (notice != null) {
            delay(NOTICE_MILLIS)
            notice = null
        }
    }

    PdshTheme {
        val tokens = PdshThemeValues.tokens
        // §1 says the Web surface is 引擎就绪时的默认面. This host makes that
        // opt-in (`pdsh.face.web`) instead of unconditional: the demo acceptance
        // waits for the worker and then taps 跑一轮 on the native face, so an
        // automatic switch would take the button off screen and break the demo.
        LaunchedEffect(state, webFaceOnLaunch) {
            if (webFaceOnLaunch && !webFaceOpened && state is EngineHostState.Running) {
                webFaceOpened = true
                nav = nav.push(PdshRoute.WebSurface)
            }
        }
        BackHandler(enabled = drawerOpen || nav.canGoBack || sessionsOpen) {
            if (sessionsOpen) {
                sessionsOpen = false
            } else if (drawerOpen) {
                drawerOpen = false
            } else {
                nav = nav.pop()
            }
        }
        val note = notice ?: routeNote
        val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
        Box(Modifier.fillMaxSize().background(tokens.colors.selector)) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    // Only a route with a note consumes the status bar here: the
                    // strip painted below then owns that area, and the page's own
                    // statusBarsPadding sees zero instead of pushing the page
                    // header down a second time.
                    .then(
                        if (note != null) {
                            Modifier.windowInsetsPadding(WindowInsets.statusBars)
                        } else {
                            Modifier
                        },
                    ),
            ) {
                if (note != null) HostNoteBar(text = note)
                Box(Modifier.weight(1f)) {
                    PdshNavHost(
                        nav = nav,
                        facts = facts,
                        onNavigate = { route ->
                            drawerOpen = false
                            nav = nav.push(route)
                        },
                        onBack = { nav = nav.pop() },
                        onHome = { nav = nav.popToHome() },
                        onHostAction = { action ->
                            val feedback = handleHostAction(action, onStart, onStop)
                            if (feedback != null) notice = feedback
                        },
                        // The mirrored settings index has three write gestures and
                        // this host has no settings write: say so instead of leaving
                        // a switch that moves and changes nothing.
                        onSettingsWrite = { write ->
                            notice = "宿主未实现：${settingsWriteLabel(write)}，本次未保存"
                        },
                        home = {
                            ProbeScreen(
                                state = state,
                                hostState = hostState,
                                handshake = handshake,
                                channel = channel,
                                turn = turn,
                                notice = recoveryNotice,
                                onStart = onStart,
                                onStop = onStop,
                                onRunTurn = onRunTurn,
                                onOpenDrawer = { drawerOpen = true },
                                onOpenConfiguration = { nav = nav.push(PdshRoute.Configuration) },
                                onOpenRuntime = { nav = nav.push(PdshRoute.Runtime) },
                                onOpenWorkbench = { section, path ->
                                    nav = nav.push(
                                        PdshRoute.Workbench(previewPath = path, section = section),
                                    )
                                },
                            )
                        },
                        webSurface = { EngineWebSurface(engine, state) },
                    )
                }
            }
            if (sessionsOpen) {
                // Opaque on purpose: the native face stays composed under this
                // layer, so the page's own (possibly unspecified) background
                // must not let it show through. The note bar sits inside this
                // layer and follows the routed pages' rule: when it shows, the
                // column has consumed the status-bar inset, so the page's own
                // statusBarsPadding sees zero instead of doubling it.
                Box(Modifier.fillMaxSize().background(tokens.colors.selector)) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .then(
                                if (note != null) {
                                    Modifier.windowInsetsPadding(WindowInsets.statusBars)
                                } else {
                                    Modifier
                                },
                            ),
                    ) {
                        if (note != null) HostNoteBar(text = note)
                        HostSessionsScreen(
                            engine = engine,
                            state = state,
                            turn = turn,
                            onBack = { sessionsOpen = false },
                            onHostNotice = { notice = it },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
            if (note != null && statusBarTop > 0.dp) {
                // The consumed status-bar strip: the same ink as the note bar, so
                // the note reads as one band from the system bar down. Drawn after
                // the sessions layer so it paints over the page, not under it.
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(statusBarTop)
                        .background(tokens.colors.code),
                )
            }
            if (drawerOpen) {
                HostDrawer(
                    onDismiss = { drawerOpen = false },
                    onNavigate = { route ->
                        drawerOpen = false
                        nav = nav.push(route)
                    },
                    onOpenSessions = {
                        // A line from a routed page is not about this page.
                        notice = null
                        drawerOpen = false
                        sessionsOpen = true
                    },
                )
            }
        }
    }
}

/**
 * Hands one page gesture to the composition root and returns the line to show.
 *
 * This host has no settings/folder/MCP write command (§1 names none), so those
 * actions only log and hand off; the facts do not move, and the returned line
 * says so. The engine stop, start and Web-surface retry are real host commands
 * and are performed here; their line says what was requested.
 *
 * @return the note-bar line for the gesture, or `null` when nothing should be
 *   shown (no action currently returns null; the seam keeps that possible).
 */
private fun handleHostAction(
    action: PdshHostAction,
    onStart: () -> Unit,
    onStop: () -> Unit,
): String? {
    // The label is token-free: an action never carries user text into the log.
    Log.i(TAG_NAV, "host action handed off: ${action.wire}")
    return when (action) {
        PdshHostAction.StopRuntime -> {
            onStop()
            "已请求：停止本地引擎"
        }

        PdshHostAction.RestartRuntime -> {
            onStart()
            "已请求：启动本地引擎"
        }

        PdshHostAction.RetryWebSurface -> {
            onStart()
            "已请求：重试本地引擎"
        }

        // §1 assigns the MCP save to the host, so the gesture is a handoff. The
        // parenthetical is the other half of the truth: this host cannot persist
        // it yet, and the page must not be told otherwise.
        is PdshHostAction.SaveMcpServer ->
            "已提交给宿主：保存 MCP 服务器（本宿主未实现持久化）"

        else -> "宿主未实现：${actionLabel(action)}，本次未提交"
    }
}

/** The person-facing name of one handed-off action; every action has one. */
private fun actionLabel(action: PdshHostAction): String = when (action) {
    is PdshHostAction.WorkspaceCreate -> "新建文件夹"
    is PdshHostAction.WorkspaceSwitch -> "切换文件夹"
    is PdshHostAction.WorkspaceDelete -> "删除文件夹"
    is PdshHostAction.OpenWorkspaceFiles -> "打开文件夹的文件列表"
    PdshHostAction.RefreshWorkspace -> "重新读取文件夹"
    PdshHostAction.RefreshAutomation -> "重新读取定时任务"
    PdshHostAction.LoadMoreAutomationHistory -> "加载更多定时任务历史"
    is PdshHostAction.OpenAutomationEditor -> "定时任务编辑器"
    PdshHostAction.RefreshConfiguration -> "重新读取会话配置"
    is PdshHostAction.OpenProviderEditor -> "模型服务编辑器"
    PdshHostAction.RefreshModelProvider -> "重新读取模型服务"
    is PdshHostAction.SetWebSearchEnabled -> "网页搜索开关"
    is PdshHostAction.SelectWebSearchBackend -> "网页搜索后端"
    PdshHostAction.RefreshWebSearch -> "重新读取网页搜索"
    PdshHostAction.RefreshMcp -> "重新读取 MCP 服务器"
    is PdshHostAction.SaveMcpServer -> "保存 MCP 服务器"
    PdshHostAction.StopRuntime -> "停止本地引擎"
    PdshHostAction.RestartRuntime -> "启动本地引擎"
    PdshHostAction.RefreshRuntime -> "重新读取运行时"
    PdshHostAction.RefreshEgress -> "重新读取出网白名单"
    is PdshHostAction.OpenWorkbenchFile -> "读取文件预览"
    PdshHostAction.RetryWebSurface -> "重试本地引擎"
}

/**
 * The route-wide read-only statement, or `null` on a route whose actions are real.
 *
 * These are the routes §1 gives host-owned writes that this host has no command
 * for. The note is the host's disclosure, not a page string: the page keeps its
 * own wording and stays unmodified.
 */
private fun hostRouteNote(route: PdshRoute): String? = when (route) {
    PdshRoute.WorkspaceFolders ->
        "只读：本宿主未实现文件夹的新建、切换、删除与文件读取"

    // Another lane now reads a real local provider profile into these facts; what
    // this route cannot do is edit or save one, so the note says only that.
    PdshRoute.ModelProvider ->
        "本宿主未接入模型服务的编辑与保存"

    PdshRoute.WebSearch ->
        "只读：本宿主未实现网页搜索的读取与保存"

    PdshRoute.Mcp ->
        "只读：本宿主未实现 MCP 服务器注册表的读取"

    is PdshRoute.McpEditor ->
        "保存会提交给宿主；本宿主未实现持久化"

    PdshRoute.Configuration ->
        "只读：本宿主未实现会话配置的读取与写入"

    PdshRoute.Automation ->
        "只读：本宿主未实现定时任务存储"

    // The rules are real: they are the App's own /v1/http policy. The note is
    // what keeps them from being mistaken for the DSH settings allow-list.
    PdshRoute.Egress ->
        "本机 App 的出网规则（不是 DSH 设置里的白名单）"

    is PdshRoute.Workbench ->
        "本宿主未实现文件内容读取；预览保持待读"

    // 命令 and 导出诊断 became reachable from the settings index (N4). This host
    // has neither a shell snapshot nor an export command, and the note says so
    // instead of letting an empty page look like a broken one.
    PdshRoute.Tools ->
        "只读：本宿主没有命令快照，运行命令需要宿主实现"

    PdshRoute.Export ->
        "本宿主没有导出诊断的命令，页面只显示它读到的状态"

    PdshRoute.Home, PdshRoute.Settings, PdshRoute.Runtime, PdshRoute.WebSurface -> null
}

/** The person-facing name of one settings write the host cannot persist. */
private fun settingsWriteLabel(write: SettingsWrite): String = when (write) {
    is SettingsWrite.BackgroundKeepAlive -> "后台运行开关"
    is SettingsWrite.BusyEnter -> "发送消息时的排队方式"
    is SettingsWrite.DefaultPermissionTier -> "新会话默认权限"
}

/** One host-owned line above the page: a disclosure, then a gesture's outcome. */
@Composable
private fun HostNoteBar(text: String) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(tokens.colors.code)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.geometry.bannerInsetV,
            ),
    ) {
        BasicText(
            text = text,
            style = type.caption.copy(color = tokens.colors.secondary),
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}

/**
 * The engine's one WebView, attached as the Web surface — or the honest notice
 * that replaces it.
 *
 * The view is owned by the engine; [key] on the instance is what makes a
 * renderer-death rebuild attach the fresh view instead of the destroyed one.
 *
 * A failed engine, or a kernel whose runtime probe says the worker cannot run
 * there, must not be rendered as the WebView: an attached blank WebView is
 * indistinguishable from a hang, and the plan's §6.2/§6.3 rule is a fail-loud
 * report instead. The notice names the reason the host actually measured (the
 * engine's failure reason, or the missing feature ids) — it is not a generic
 * "something went wrong".
 */
@Composable
private fun EngineWebSurface(engine: ProbeEngineViewModel, state: EngineState) {
    val kernel = engine.kernelReport()
    val failure = (state as? EngineHostState.Failed)?.reason
    val unsupportedKernel = kernel?.verdict == KernelVerdict.UNSUPPORTED
    if (failure != null || unsupportedKernel) {
        EngineUnavailableNotice(
            title = if (unsupportedKernel) {
                UiStrings.RUNTIME_WEBVIEW_GATE_MISSING
            } else {
                UiStrings.RUNTIME_SECTION_ENGINE + "不可用"
            },
            reason = failure,
            detail = kernel?.featureGateDetail(),
        )
        return
    }
    val view: View? = engine.currentWebView()
    if (view == null) {
        Box(Modifier.fillMaxSize())
        return
    }
    key(view) {
        AndroidView(factory = { view }, modifier = Modifier.fillMaxSize())
    }
}

/**
 * The page the host renders when the engine cannot be the page.
 *
 * Same tokens and type as every other host-owned line, so it looks like part of
 * the app rather than a debug dump; the technical detail stays on its own line
 * and is allowed to be English because it is evidence (feature ids, provider).
 */
@Composable
private fun EngineUnavailableNotice(title: String, reason: String?, detail: String?) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(tokens.colors.background)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(tokens.geometry.pageOuterMarginH),
        contentAlignment = Alignment.Center,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap)) {
            BasicText(text = title, style = type.body.copy(color = tokens.colors.primary))
            if (reason != null) {
                BasicText(text = reason, style = type.caption.copy(color = tokens.colors.secondary))
            }
            if (detail != null) {
                BasicText(text = detail, style = type.caption.copy(color = tokens.colors.tertiary))
            }
        }
    }
}

/**
 * The drawer §1's entry column names.
 *
 * The baseline's drawer body is the session list; this host has no session store
 * of its own, so the drawer opens the sessions page as its own layer (会话) and
 * carries the four routes this lane can push. 设置 is the sheet §1 names; the Web
 * surface row is the full-screen face.
 *
 * @param onOpenSessions open the sessions page layer (the baseline's drawer body).
 */
@Composable
private fun HostDrawer(
    onDismiss: () -> Unit,
    onNavigate: (PdshRoute) -> Unit,
    onOpenSessions: () -> Unit,
) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    Row(Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxHeight()
                .fillMaxWidth(DRAWER_WIDTH_FRACTION)
                .background(tokens.colors.input)
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .verticalScroll(rememberScrollState())
                .padding(vertical = tokens.geometry.cardOuterMarginV),
        ) {
            BasicText(
                text = "导航",
                style = type.caption.copy(color = tokens.colors.tertiary),
                modifier = Modifier.padding(horizontal = tokens.geometry.pageOuterMarginH),
            )
            Spacer(Modifier.height(tokens.geometry.cardOuterMarginV))
            // The baseline's drawer body row (NativeShell.swift:275); UiStrings
            // names the page 会话列表, while the drawer's own word is 会话.
            DrawerRow(label = SESSIONS_DRAWER_LABEL, onClick = onOpenSessions)
            DrawerRow(label = UiStrings.WORKSPACE_FOLDERS, onClick = { onNavigate(PdshRoute.WorkspaceFolders) })
            DrawerRow(label = UiStrings.AUTOMATION_TITLE, onClick = { onNavigate(PdshRoute.Automation) })
            DrawerRow(label = UiStrings.SETTINGS, onClick = { onNavigate(PdshRoute.Settings) })
            DrawerRow(label = UiStrings.WEB_SURFACE_TITLE, onClick = { onNavigate(PdshRoute.WebSurface) })
        }
        // The right strip is the dismiss target; it dims the page below so the
        // drawer reads as a modal. The panel itself takes no scrim, so a tap on
        // its background does not close it.
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxHeight()
                .background(tokens.colors.primary.copy(alpha = DRAWER_SCRIM_ALPHA))
                // unverified token: no scrim opacity token exists; the page ink at
                // a fixed opacity is the only non-invented dimming available.
                .clickable(role = Role.Button, onClick = onDismiss)
                .semantics { contentDescription = "关闭抽屉" },
        )
    }
}

/** One drawer row; the label is the visible text and the accessibility name. */
@Composable
private fun DrawerRow(label: String, onClick: () -> Unit) {
    val tokens = PdshThemeValues.tokens
    val type = PdshThemeValues.type
    BasicText(
        text = label,
        style = type.body.copy(color = tokens.colors.primary),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label }
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.geometry.cardOuterMarginV,
            ),
    )
}

/** The host's navigation log tag; only stable action labels are written to it. */
private const val TAG_NAV = "PDSHNav"

/** The drawer's word for the sessions page (the baseline's NativeShell.swift:275). */
private const val SESSIONS_DRAWER_LABEL: String = "会话"

/** unverified geometry: no drawer-width token exists; 0.82 keeps the page visible. */
private const val DRAWER_WIDTH_FRACTION = 0.82f

/** unverified token: no scrim-opacity token exists for the dimmed page strip. */
private const val DRAWER_SCRIM_ALPHA = 0.32f

/** How long a gesture's outcome line stays on screen (four seconds). */
private const val NOTICE_MILLIS: Long = 4_000L

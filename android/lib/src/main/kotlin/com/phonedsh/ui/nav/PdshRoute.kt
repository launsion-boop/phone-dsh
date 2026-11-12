// The host navigation vocabulary: routes, their presentation and the page stack.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (the page list, its 入口 column and its 导航关系
// column). §1 names three forms a page can be opened with, and each one is a
// [PdshPresentation] here:
//
//   * PUSH      — a page stack; the page header's back pops one level
//                 (工作文件夹, 网页搜索, MCP 服务器, 出网白名单);
//   * SHEET     — a modal over the current page, closed by its own 完成/返回
//                 (定时任务, 设置, 模型服务, 运行状态, 本会话设置, 工作面板);
//   * FULLSCREEN — the Web surface: no header and no back stack.
//
// This file owns navigation state only. It never reads the engine, the clock or
// the filesystem: the host supplies the facts ([PdshNavFacts]) and receives every
// action it cannot perform as a [PdshHostAction] handoff. Keeping the stack a
// pure value is what makes the router replayable on a JVM and keeps every page a
// pure function of (facts, local script), as §3.1 requires.
//
// The five `later` pages (BackgroundPage, DailyBriefPage, ExportPage, ProbesPage,
// TaskScreenPage) are deliberately absent: another lane owns them and they will
// hand their own callbacks to this router when they land.
package com.phonedsh.ui.nav

import com.phonedsh.ui.page.SettingsDestination
import com.phonedsh.ui.page.WorkbenchSection

/** How a route is presented; the three 入口 forms of §1. */
public enum class PdshPresentation {
    /** Pushed on the stack; the page header's back pops it. */
    PUSH,

    /** A modal over the current page; its own 完成/返回 action closes it. */
    SHEET,

    /** The Web surface: full screen, no header, no back stack. */
    FULLSCREEN,
}

/**
 * One addressable face of the host.
 *
 * Every route names a page of §1. The caller navigates with [PdshNavState]; a
 * route never carries a callback, so the stack stays a plain value.
 */
public sealed interface PdshRoute {
    /** The presentation form §1's 入口 column names for this route. */
    public val presentation: PdshPresentation

    /** The demo's native face: the engine probe screen (the launch destination). */
    public data object Home : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.FULLSCREEN
    }

    /**
     * 对话: §1's root native face (`ChatPage`).
     *
     * §1 gives it no 入口 — it is the face the shell opens on — so no route was
     * declared for it until the page needed one to render at all. It keeps the
     * FULLSCREEN form: the page draws its own head and back stack, and the shell
     * layer around it is the same one [Home] gets.
     */
    public data object Chat : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.FULLSCREEN
    }

    /** 抽屉「工作文件夹」; §1: push, every row opens the files page. */
    public data object WorkspaceFolders : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /**
     * 工作区文件树 (`FilesPage`), pushed from one 工作文件夹 row.
     *
     * §1's navigation relation is "每行打开 FilesPage", so this is the push the
     * baseline's `NavigationLink` performs (`NativeShell.swift:326`–`:336`).
     *
     * @param folderId the folder whose files are shown, or `null` when the host
     *   reported no folder id. The baseline's `FilesPage()` is rooted at the
     *   materialized workspace and takes no folder argument, so the page does not
     *   read this value today; it is carried so the navigation edge names its
     *   source and a host that roots the tree per folder can pass it through.
     */
    public data class Files(public val folderId: String? = null) : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /**
     * 设置 › 定时任务; the drawer no longer carries a duplicate entry.
     *
     * iOS presents it as `NavigationStack { NativeAutomationPage() }` inside a
     * `.sheet` with `homeSheetChrome()` and no `.presentationDetents`
     * (`SettingsPage.swift:115`), so the row keeps SHEET and renders through the
     * contract's default detent set (`interaction.md` §2 rule 2).
     */
    public data object Automation : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 页头 `⋯`; §1: sheet, closed by 完成. Read-only on this host.
     *
     * iOS presents `NativeConfigurationPage(presentedAsSheet: true)` in a
     * `NavigationStack` with `homeSheetChrome()` and no `.presentationDetents`
     * (`ChatPage.swift:526`–`:533`), so the sheet takes the contract default.
     * The `configurationInfo` page id is the nested 插件说明 sheet
     * (`NativeConfigurationPage.swift:66`–`:83`), not this route.
     */
    public data object Configuration : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 抽屉底行「设置」; §1: a sheet (NavigationStack).
     *
     * iOS: `NavigationStack { SettingsPage(...) }.homeSheetChrome()` with no
     * `.presentationDetents` (`ChatPage.swift:522`–`:525`), so the contract default
     * applies. The sheet chrome owns the visible grabber; the settings content
     * draws none (`SheetChrome.HomeSheet`).
     */
    public data object Settings : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 我的: the bottom menu's settings tab (`SettingsPage(isTab: true)`,
     * `NativeShell.swift:234-239`). A first-level page like [Chat]: no back, and the
     * bottom menu stays under it.
     */
    public data object MeTab : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.FULLSCREEN
    }

    /** 我的 › 设置: everything the tab leaves out (`SettingsPage(mode: .more)`); push. */
    public data object SettingsMore : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 发现: the bottom menu's connectors tab (`ConnectorsPage`); first-level like [MeTab]. */
    public data object Discover : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.FULLSCREEN
    }

    /**
     * 设置首行; §1: sheet.
     *
     * iOS also pushes it from the settings index, and presents it as `NavigationStack
     * { ModelProviderSettingsPage().homeSheetDone() }.homeSheetChrome()` with no
     * `.presentationDetents` (`ChatPage.swift:518`–`:521`), so the sheet consumes
     * the contract default.
     */
    public data object ModelProvider : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /** 设置行; §1: push or sheet. */
    public data object WebSearch : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 设置行; §1: push or sheet; its editor child is [McpEditor]. */
    public data object Mcp : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 设置行「SSH 主机」; §1: push; its editor child is [SshEditor]. */
    public data object Ssh : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /**
     * 设置行「GitHub Agent」; §1: push (`SettingsPage.swift:168`).
     *
     * The iOS row is a `NavigationLink`, so the token page keeps a back stack;
     * its own sections are the contract's `git-hub-agent-settings`.
     */
    public data object GitHubAgent : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /**
     * The SSH connection editor, opened from [Ssh]'s list.
     *
     * @param connectionId the saved connection to edit, or `null` when adding one.
     */
    public data class SshEditor(public val connectionId: String? = null) : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 设置行「蓝牙设备」; §1: push. Scan + standard GATT only (android-standard-gatt.md). */
    public data object Bluetooth : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 设置行「Android ADB」; §1: push. The android_* tools' saved target (native-mcp.md). */
    public data object AndroidAdb : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 设置行「Tono 账号」; §1: push. SMS sign-in for the cloud service (tono-account.md). */
    public data object TonoAccount : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /**
     * The MCP server editor, opened from [Mcp]'s list.
     *
     * @param serverId the server to edit, or `null` when adding a new one.
     * @param discoveredUrl the HTTPS URL of a selected, still unverified LAN
     *   discovery candidate; a new-server form opens pre-filled with it (the
     *   iOS `MCPEditorPage(candidate:)`). Selecting is not saving or granting.
     */
    public data class McpEditor(
        public val serverId: String? = null,
        public val discoveredUrl: String? = null,
    ) : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /**
     * 设置内「运行时详情」, also the page-header status dot; §1: sheet.
     *
     * iOS: `NavigationStack { RuntimeDetailsPage(...).homeSheetDone() }
     * .homeSheetChrome()` (`ChatPage.swift:541`–`:544`), no `.presentationDetents`
     * → contract default.
     */
    public data object Runtime : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /** 设置内「出网白名单」; §1: push. Read-only by §1's duty description. */
    public data object Egress : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /**
     * The session workbench sheet, opened from a tool-written path in the turn.
     *
     * Not a PUSH: iOS presents `NativeWorkbenchPage(...)` in a `.sheet` with
     * `.homeSheetChrome()` (`ChatPage.swift:504`–`:507`), and the page itself pins
     * `.presentationDetents([.large])` (`NativeWorkbenchPage.swift:40`), i.e. the
     * frozen page id `workbench` with the `large` set.
     *
     * @param previewPath the path the chat page was asked to preview, if any.
     * @param section the segment to show first; `null` keeps the page default.
     */
    public data class Workbench(
        public val previewPath: String? = null,
        public val section: WorkbenchSection? = null,
    ) : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 命令: the read-only accelerator shell (`PDSHShellPage`).
     *
     * §1's SettingsPage row 命令 opens it; the Android screen is `ToolsPage`.
     */
    public data object Tools : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 导出诊断: the diagnostics export page (the settings row 导出诊断). */
    public data object Export : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** The engine-ready default face: the full-screen DSH Web surface. */
    public data object WebSurface : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.FULLSCREEN
    }

    /**
     * 会话: the sessions family's list face (`SessionsPage`).
     *
     * Declared here with the rest of the vocabulary; it briefly lived as a
     * top-level object in `PdshNavHost.kt` while that file was being edited by
     * another lane, which made it the one route whose name did not read
     * `PdshRoute.*`. Every route is now named the same way.
     */
    public data object Sessions : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    // -----------------------------------------------------------------------
    // Appended by the L5 lane: the three device-connector faces. They exist so the
    // pages are addressable; no drawer row owns them (the host opens [DeviceConnection],
    // which pushes [DeviceSession], and [SessionArtifacts] is opened per session).
    // -----------------------------------------------------------------------

    /**
     * 设备连接: which devices a connector publishes, and which session each opens.
     *
     * The baseline presents it as `NavigationStack { NativeDeviceConnectionPage() }
     * .homeSheetChrome()` (`ChatPage.swift:495`–`:497`), which is the site the
     * contract records as `interaction.sheet.defaultDetents` (no
     * `.presentationDetents`), so the sheet keeps the default set.
     */
    public data object DeviceConnection : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 设备会话: one device's fixed session, watched read-only.
     *
     * The baseline pushes it from a device row (`navigationDestination(item:)`), and
     * its header's back pops one level, so it is a PUSH.
     *
     * @param deviceId the device whose session is monitored; the route carries the
     *   device, not the session, so a reopened page re-resolves the saved mapping.
     */
    public data class DeviceSession(public val deviceId: String) : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /**
     * 本 session 产物: the files one session's tools produced, plus the unassigned rest.
     *
     * A sheet closed by 完成 in the baseline: `NavigationStack { SessionArtifactsPage(...) }`
     * with `.presentationDetents([.medium, .large])` and `.homeSheetChrome()`
     * (`ChatPage.swift:584`–`:590`), i.e. page id `chatArtifacts`.
     *
     * @param sessionId the session whose artifacts are listed.
     */
    public data class SessionArtifacts(public val sessionId: String) : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    // -----------------------------------------------------------------------
    // Appended by the L14 lane: the three B-group page contracts that landed with
    // the iOS HEAD 86a39aac regeneration (`native-agent-presets`,
    // `native-plugin-inventory`, `phone-permissions`). Each is a settings-sheet tab
    // body in the baseline too (`SettingsPage.swift:82-90`), so the sheet renders
    // them embedded through `SettingsPage`'s `tabContent` slot; these routes are the
    // addressable standalone face, exactly as the contract models the page.
    // -----------------------------------------------------------------------

    /**
     * Agent 预设: the preset roster and its read-only YAML panel.
     *
     * The baseline presents it as a tab body of the settings sheet and never as a
     * pushed page; standalone it keeps that modal form, closed by the shell's 完成.
     */
    public data object AgentPresets : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 内置插件: the read-only plugin inventory.
     *
     * The baseline gives it the settings sheet's 插件 tab, and the page's own 插件配置
     * row pushes the configuration page, so the standalone form is a PUSH like the
     * page it links to.
     */
    public data object PluginInventory : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /**
     * 手机权限: the 23-capability matrix.
     *
     * A tab body of the settings sheet in the baseline; standalone it is a sheet
     * closed by 完成 (`PhonePermissionsPage.swift:33`).
     */
    public data object PhonePermissions : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    // -----------------------------------------------------------------------
    // Appended by the L13 lane: the three iOS pages Android did not carry
    // (`chat-preferences`, `native-settings-document`, `native-shortcuts`). Two
    // are `later`/unreachable in §1 and exist so the pages are addressable (the
    // preview and the screenshot tests open them by route); NativeShortcutsPage
    // is §1's `must`, pushed from the 通用 tab's 快捷键 row — that row's owner
    // wires the push, this list only names the edge.
    // -----------------------------------------------------------------------

    /**
     * 聊天外观: the chat appearance, font-size and process-collapse controls.
     *
     * §1: `later`, no entry in the baseline (`不可达（全仓无调用点）`); the baseline
     * presents it as a sheet closed by 完成, which is the form kept here.
     */
    public data object ChatPreferences : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 配置文件: the redacted settings document, read-only, shareable.
     *
     * §1: `later`/unreachable on iOS (only the preview configures it); the baseline
     * presents it as a sheet (`NativeSettingsDocumentPage.swift:22-33`), the same
     * form as its sibling [Configuration].
     */
    public data object SettingsDocument : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 快捷键: the keyboard shortcut reference (`NativeShortcutsPage.swift`).
     *
     * §1: `must`; the 通用 tab's 快捷键 row pushes it (`SettingsPage.swift:145`),
     * and its header's back pops one level.
     */
    public data object Shortcuts : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    // -----------------------------------------------------------------------
    // Appended by the L24 lane: the chat page's three 内嵌子页. README §1 line 86
    // makes them part of ChatPage (they are `private struct`s in ChatPage.swift),
    // so each keeps the modal form the baseline presents it with — a `.sheet`
    // closed by 完成/关闭 — and no drawer row owns any of them. Their data is the
    // page's own read (`ChatSubpageFacts`), and the facts-only default renders the
    // honest 读取不到 body rather than an empty list.
    // -----------------------------------------------------------------------

    /**
     * 命令结果: one `/command` execution's settlement (`ChatPage.swift:4243`).
     *
     * The baseline opens it from `executeCommand`'s success path
     * (`ChatPage.swift:2516`), never from a menu row, so there is no in-page entry
     * on this host either: a host that owns `commands/execute` pushes this route
     * when the execution returns. iOS presents it with `.homeSheetChrome()` and no
     * `.presentationDetents` (`ChatPage.swift:534`–`:540`), so the sheet uses the
     * contract default set.
     */
    public data object CommandResult : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 后台任务: this session's background jobs (`ChatPage.swift:3554`).
     *
     * The page-head menu opens it only while the list has rows (`:247`), which is
     * why this route has no other entrance. iOS presents `NativeJobListSheet` with
     * `.presentationDetents([.medium, .large])` and `.homeSheetChrome()`
     * (`ChatPage.swift:568`–`:575`), i.e. page id `chatJobs`.
     */
    public data object SessionJobs : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 定时任务: this session's scheduled tasks (`ChatPage.swift:3504`).
     *
     * Same entrance rule as [SessionJobs] (`:252`). Not to be confused with
     * [Automation], the drawer's schedule *catalog* page, which is a different read.
     * iOS presents `NativeScheduleListSheet` with `.presentationDetents([.medium,
     * .large])` and `.homeSheetChrome()` (`ChatPage.swift:576`–`:583`), i.e. page id
     * `chatSchedules`.
     */
    public data object SessionSchedules : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    // -----------------------------------------------------------------------
    // Appended by the L29 lane: the one preview face.
    //
    // iOS PR #15 (`8dd17496`) deleted `FilePreviewPage` and `EmbeddedQuickLook` and
    // replaced both entrances with a single `PreviewTarget.workspaceFile(path)`:
    // the files list pushes `PreviewSurface` (`FilesPage.swift:59`) and the chat page
    // presents it as a full-screen cover (`ChatPage.swift:389`). Android kept the
    // preview *inside* two pages instead, so this route is the address that makes it
    // one surface again: whichever page opens it, one back returns there.
    //
    // The path is the route's identity and it is normalized before use
    // (`PreviewPathResolver`), so `./notes.md`, `/dsh/workspace/notes.md` and a
    // percent-encoded spelling are the same route — exactly like
    // `PreviewTarget.workspaceFile`'s single `path` payload. Presentation
    // parameters (a line number, a scroll offset) are deliberately *not* part of the
    // route, per `PreviewPresentation`'s comment in `PreviewSurface.swift:28`.
    // -----------------------------------------------------------------------

    /**
     * 文件预览: one workspace file, read by the single preview face.
     *
     * @param path any spelling a caller has — `notes.md`, `./notes.md`,
     *   `/dsh/workspace/notes.md`, `file://…`, percent-encoded or NFD. The preview
     *   resolves it against the host's materialized workspace; a path it refuses
     *   renders the honest 无法预览 card rather than a blank page.
     */
    public data class Preview(public val path: String) : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    // -----------------------------------------------------------------------
    // Appended by the C5 PCLink lane. Both pages already exist as Swift sheets/
    // pushes; the Android route keeps the same form so the host's one back
    // gesture matches the baseline (`PCPairingPage.swift:79`, `SettingsPage.swift:353`).
    // -----------------------------------------------------------------------

    /**
     * 连接电脑: the PCLink pairing flow.
     *
     * Presented as a sheet at both iOS call sites (`HomeDrawer.swift:109`,
     * `ConnectedComputerPage.swift:34`); its scanner is a second sheet inside the
     * page (`PCPairingPage.swift:79`). `interaction.sheet.pageDetents` declares no
     * entry for it, so it keeps the system default detent. The route carries no
     * flow state; the host owns the pairing flow and passes a
     * [com.phonedsh.ui.page.PCPairingUiState] to the page.
     */
    public data object PcPairing : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /**
     * 已连接的电脑: the one paired PC, its verified DSH version and unpairing.
     *
     * The iOS settings row is a `NavigationLink` push (`SettingsPage.swift:353`),
     * so the Android route is a PUSH; the page keeps its own back.
     */
    public data object ConnectedComputer : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }
}

/**
 * The navigation state: one route stack per home tab plus the selected tab.
 *
 * `interaction.md` §4 rule 1 gives every tab an independent `NavigationStack`;
 * switching tabs swaps which stack is visible and never clears the target's
 * depth. [stack] is still the selected tab's stack, so a caller that renders or
 * mutates the visible route keeps the pre-per-tab API; [selectHomeTab] restores
 * the target tab's own stack, and re-selecting the current tab returns this value
 * (rule 2, never pop-to-root).
 *
 * The top of [stack] is the visible route. A stack's floor is its tab root
 * ([HomeTab.root]) or, on the diagnostic face, [PdshRoute.Home]; [pop] on a root
 * is a no-op and the back gesture can never empty a stack.
 */
public data class PdshNavState(
    public val stacks: Map<HomeTab, List<PdshRoute>> = mapOf(
        HomeTab.TASKS to listOf(PdshRoute.Home),
    ),
    public val selectedTab: HomeTab = HomeTab.TASKS,
) {
    /**
     * The pre-per-tab source shape: one visible stack.
     *
     * The tab is inferred from the stack's floor, so `PdshNavState(listOf(Chat,
     * Settings))` still means "the tasks tab, two levels down" and
     * `PdshNavState(listOf(Chat, Discover))` means "the discover tab at its
     * root". A stack whose pushed page repeats a tab root does not move the tab:
     * the first occurrence of the root is the floor, later ones are pages.
     */
    public constructor(stack: List<PdshRoute>) : this(
        stacks = mapOf(inferredTab(stack) to stack),
        selectedTab = inferredTab(stack),
    )

    init {
        require(stacks.isNotEmpty()) { "the navigation state needs the selected tab's stack" }
        require(stacks.values.all { it.isNotEmpty() }) { "a navigation stack needs at least its floor route" }
        require(selectedTab in stacks) { "the selected tab has no stack: $selectedTab" }
    }

    /** The selected tab's route stack; its top is the visible route (rule 1). */
    public val stack: List<PdshRoute> get() = stacks.getValue(selectedTab)

    /** The visible route. */
    public val current: PdshRoute get() = stack.last()

    /** True when a back gesture pops a page instead of leaving the app. */
    public val canGoBack: Boolean get() = stack.size > 1

    /**
     * How many pages sit above [tab]'s root (rules 1 and 3); a tab never opened
     * is at its root. The first occurrence of the tab's root is its floor — a
     * later route that repeats the root is a pushed page, not a new floor.
     */
    public fun depthOf(tab: HomeTab): Int {
        val tabStack = stacks[tab] ?: return 0
        val rootIndex = tabStack.indexOfFirst { it == tab.root }
        val floorIndex = if (rootIndex >= 0) rootIndex else 0
        return (tabStack.lastIndex - floorIndex).coerceAtLeast(0)
    }

    /** Opens [route] on top of the selected tab's current page. */
    public fun push(route: PdshRoute): PdshNavState {
        val target = HomeTab.entries.firstOrNull { it != selectedTab && it.root == route }
        // A tab root pushed from another tab's floor shows that tab, it is not a
        // page over the current one. Once a page is pushed, a tab root is just a
        // page: 会话 → 对话 pushes Chat one level above its floor.
        if (target != null && depthOf(selectedTab) == 0) return selectHomeTab(target)
        val next = stacks.toMutableMap()
        next[selectedTab] = stack + route
        return PdshNavState(next.toMap(), selectedTab)
    }

    /** Pops one level of the selected tab; the root is a fixed point. */
    public fun pop(): PdshNavState {
        if (!canGoBack) return this
        val nextStack = stack.dropLast(1)
        val nextTab = inferredTab(nextStack)
        val next = stacks.toMutableMap()
        if (nextTab != selectedTab) next.remove(selectedTab)
        next[nextTab] = nextStack
        return PdshNavState(next.toMap(), nextTab)
    }

    /** Returns to the root page (the Web surface's 原生恢复 path). */
    public fun popToHome(): PdshNavState = PdshNavState()

    /** Replaces the top route of the selected tab, keeping its depth. */
    public fun replaceTop(route: PdshRoute): PdshNavState {
        val nextStack = stack.dropLast(1) + route
        val nextTab = inferredTab(nextStack)
        val next = stacks.toMutableMap()
        if (nextTab != selectedTab) next.remove(selectedTab)
        next[nextTab] = nextStack
        return PdshNavState(next.toMap(), nextTab)
    }

    /** True when [route] is already somewhere on the selected tab's stack. */
    public fun contains(route: PdshRoute): Boolean = stack.any { it == route }

    /**
     * `interaction.md` §4 rules 1-2: show [tab]'s own stack. A tab that has not
     * been opened starts at its root on the current home floor; a tab that has
     * keeps every pushed page. Re-tapping the selected tab returns this value, so
     * it can never pop to root.
     */
    public fun selectHomeTab(tab: HomeTab): PdshNavState {
        if (tab == selectedTab) return this
        val target = stacks[tab] ?: chatFloor().let { floor ->
            if (tab == HomeTab.TASKS) floor else floor + tab.root
        }
        return PdshNavState(stacks + (tab to target), tab)
    }

    /** The leading Home/Chat floor every tab root sits on (`HomeTabBar.kt`). */
    private fun chatFloor(): List<PdshRoute> {
        val floor = stack.takeWhile { it == PdshRoute.Home || it == PdshRoute.Chat }
        val chatIndex = floor.indexOfFirst { it == PdshRoute.Chat }
        return if (chatIndex >= 0) floor.take(chatIndex + 1) else floor + PdshRoute.Chat
    }
}

/**
 * The tab a visible stack belongs to: the route just above the Home/Chat floor
 * when it is a non-tasks tab root, otherwise tasks. A pushed page never changes
 * the tab.
 */
private fun inferredTab(stack: List<PdshRoute>): HomeTab {
    val floorEnd = stack.takeWhile { it == PdshRoute.Home || it == PdshRoute.Chat }.size
    val root = stack.getOrNull(floorEnd)
    return HomeTab.entries.firstOrNull { it != HomeTab.TASKS && it.root == root } ?: HomeTab.TASKS
}

/**
 * The route a mirrored settings row opens.
 *
 * The settings page is the iOS baseline's fixed index, whose rows name destination
 * ids instead of host-built row ids (`SettingsDestination`), so the router maps the
 * destination. Four destinations have no route this host owns: 新会话默认权限 and
 * 关于 are the settings sheet's own child pages, 开源许可 (LicensesPage) is an
 * iOS-only list this app does not have — its row is a non-navigating explanation
 * instead — and 开发者工具 is the Android-only index of the pages the iOS baseline
 * left without an entry. `SettingsRoute` renders those three surfaces itself, so a
 * `null` here is "the sheet swaps its own body", never "the row does nothing".
 */
public object PdshSettingsRows {
    /** Settings-page host rows which already have a concrete route in this app. */
    public enum class HostRow { AGENT_PRESETS, PHONE_PERMISSIONS, PLUGINS_TOOLS, FOLDERS }

    /** The host-owned settings rows' direct route targets. */
    public fun targetOf(row: HostRow): PdshRoute = when (row) {
        HostRow.AGENT_PRESETS -> PdshRoute.AgentPresets
        HostRow.PHONE_PERMISSIONS -> PdshRoute.PhonePermissions
        HostRow.PLUGINS_TOOLS -> PdshRoute.PluginInventory
        HostRow.FOLDERS -> PdshRoute.WorkspaceFolders
    }

    public fun targetOf(destination: SettingsDestination): PdshRoute? = when (destination) {
        SettingsDestination.MODEL_PROVIDER -> PdshRoute.ModelProvider
        SettingsDestination.WEB_SEARCH -> PdshRoute.WebSearch
        SettingsDestination.MCP -> PdshRoute.Mcp
        SettingsDestination.SSH -> PdshRoute.Ssh
        SettingsDestination.GITHUB_AGENT -> PdshRoute.GitHubAgent
        SettingsDestination.BLUETOOTH -> PdshRoute.Bluetooth
        SettingsDestination.ANDROID_ADB -> PdshRoute.AndroidAdb
        SettingsDestination.TONO_ACCOUNT -> PdshRoute.TonoAccount
        SettingsDestination.EGRESS -> PdshRoute.Egress
        SettingsDestination.PLUGIN_CONFIGURATION -> PdshRoute.Configuration
        SettingsDestination.COMMAND -> PdshRoute.Tools
        SettingsDestination.RUNTIME_DETAILS -> PdshRoute.Runtime
        SettingsDestination.EXPORT_DIAGNOSTICS -> PdshRoute.Export
        SettingsDestination.SHORTCUTS -> PdshRoute.Shortcuts
        SettingsDestination.SCHEDULES -> PdshRoute.Automation
        SettingsDestination.MORE_SETTINGS -> PdshRoute.SettingsMore
        SettingsDestination.PERMISSION_DEFAULTS,
        SettingsDestination.LICENSES,
        SettingsDestination.ABOUT,
        SettingsDestination.DEV_TOOLS,
        -> null
    }
}

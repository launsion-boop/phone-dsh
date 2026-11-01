// The host navigation vocabulary: routes, their presentation and the page stack.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §1 (the page list, its 入口 column and its 导航关系
// column). §1 names three forms a page can be opened with, and each one is a
// [PdshPresentation] here:
//
//   * PUSH      — a page stack; the page header's back pops one level
//                 (工作文件夹, 定时任务, 网页搜索, MCP 服务器, 出网白名单);
//   * SHEET     — a modal over the current page, closed by its own 完成/返回
//                 (设置, 模型服务, 运行状态, 本会话设置, 工作面板);
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

    /** 抽屉「工作文件夹」; §1: push, every row opens the files page. */
    public data object WorkspaceFolders : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 抽屉「定时任务」; §1: push, child detail/history views are page-local. */
    public data object Automation : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 页头 `⋯`; §1: sheet, closed by 完成. Read-only on this host. */
    public data object Configuration : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /** 抽屉底行「设置」; §1: a sheet (NavigationStack). */
    public data object Settings : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.SHEET
    }

    /** 设置首行; §1: sheet. */
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

    /**
     * The MCP server editor, opened from [Mcp]'s list.
     *
     * @param serverId the server to edit, or `null` when adding a new one.
     */
    public data class McpEditor(public val serverId: String? = null) : PdshRoute {
        override val presentation: PdshPresentation = PdshPresentation.PUSH
    }

    /** 设置内「运行时详情」, also the page-header status dot; §1: sheet. */
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
}

/**
 * The page stack: a list of routes plus push/pop.
 *
 * The top of [stack] is the visible route. [Home] is the floor, so [pop] on the
 * root is a no-op and the back gesture can never empty the stack.
 */
public data class PdshNavState(public val stack: List<PdshRoute> = listOf(PdshRoute.Home)) {
    init {
        require(stack.isNotEmpty()) { "the navigation stack needs at least the Home route" }
    }

    /** The visible route. */
    public val current: PdshRoute get() = stack.last()

    /** True when a back gesture pops a page instead of leaving the app. */
    public val canGoBack: Boolean get() = stack.size > 1

    /** Opens [route] on top of the current page. */
    public fun push(route: PdshRoute): PdshNavState = copy(stack = stack + route)

    /** Pops one level; the root is a fixed point. */
    public fun pop(): PdshNavState = if (canGoBack) copy(stack = stack.dropLast(1)) else this

    /** Returns to the root page (the Web surface's 原生恢复 path). */
    public fun popToHome(): PdshNavState = PdshNavState()

    /** Replaces the top route, keeping its depth (used by the opt-in Web face). */
    public fun replaceTop(route: PdshRoute): PdshNavState =
        copy(stack = stack.dropLast(1) + route)

    /** True when [route] is already somewhere on the stack. */
    public fun contains(route: PdshRoute): Boolean = stack.any { it == route }
}

/**
 * The route a mirrored settings row opens.
 *
 * The settings page is the iOS baseline's fixed index, whose rows name destination
 * ids instead of host-built row ids (`SettingsDestination`), so the router maps the
 * destination. Two destinations have no route this host owns: 新会话默认权限 is the
 * settings sheet's own child page, and 开源许可 (LicensesPage) is an iOS-only list
 * this app does not have — its row is a non-navigating explanation instead.
 */
public object PdshSettingsRows {
    public fun targetOf(destination: SettingsDestination): PdshRoute? = when (destination) {
        SettingsDestination.MODEL_PROVIDER -> PdshRoute.ModelProvider
        SettingsDestination.WEB_SEARCH -> PdshRoute.WebSearch
        SettingsDestination.MCP -> PdshRoute.Mcp
        SettingsDestination.EGRESS -> PdshRoute.Egress
        SettingsDestination.PLUGIN_CONFIGURATION -> PdshRoute.Configuration
        SettingsDestination.COMMAND -> PdshRoute.Tools
        SettingsDestination.RUNTIME_DETAILS -> PdshRoute.Runtime
        SettingsDestination.EXPORT_DIAGNOSTICS -> PdshRoute.Export
        SettingsDestination.PERMISSION_DEFAULTS,
        SettingsDestination.LICENSES,
        -> null
    }
}

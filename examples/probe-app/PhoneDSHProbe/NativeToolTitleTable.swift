// SPDX-License-Identifier: MIT
//
// NativeToolTitleTable — the official `tool.call.toolview` title / icon / row
// variant table, as audited in docs/receipts/ios-session-audit/06-tools.md §2.1.
//
// Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2). The shipped web
// app registers exactly 54 keyed tool views (toolviews/*, ui-skill,
// ui-deliverables, ui-cordis); the Chinese titles below are copied verbatim
// from ui-conversation/src/client/locales.ts (`tool.title.*`, `todo.rowTitle`,
// `ask.rowTitle`), ui-skill/locales.ts (`row.title`), ui-deliverables/locales.ts
// (`row.title`) and ui-cordis/locales.ts (`row.defineTitle`, `row.runTitle`).
//
// This table is data only: it does not import NativeChatIcon (a closed enum) and
// returns a `Icon` value — either an asset-catalog SVG the probe app already
// ships, or an SF Symbol used as the stand-in while the official SVG is not
// imported. `officialIcon` records which official glyph each row should use, so
// a later asset drop is a one-line change per row (see T-14 in 06-tools.md).

import SwiftUI

enum NativeToolTitleTable {

    // MARK: - Row variant

    /// Presentation variant used to pick the row/card family for a tool.
    ///
    /// This is a superset of the official `ToolRowVariant`
    /// (`search|read|bash|write|edit|code|others`, tool-call-model.ts:16) split
    /// by the business clusters the details card renders (`goal`, `schedule`,
    /// `job`, `subagent`, ...). `officialRowVariant` maps back to the official
    /// seven so the summary/icon rules keep matching the web app.
    enum RowVariant: String, CaseIterable {
        case bash, read, search, web, write, edit, image, todo, ask
        case subagent, job, schedule, goal, workflow, details, generic

        /// The official atomic row variant this presentation variant renders as.
        var officialRowVariant: String {
            switch self {
            case .bash: "bash"
            case .read, .image: "read"
            case .search, .web: "search"
            case .write: "write"
            case .edit: "edit"
            case .todo, .ask, .subagent, .job, .schedule, .goal,
                 .workflow, .details, .generic: "others"
            }
        }
    }

    // MARK: - Icon

    /// Either a bundled template SVG (`DSH*.imageset`) or an SF Symbol stand-in.
    enum Icon: Equatable {
        case asset(String)
        case system(String)

        var name: String {
            switch self {
            case .asset(let name), .system(let name): name
            }
        }

        var isAsset: Bool {
            if case .asset = self { return true }
            return false
        }
    }

    // MARK: - Entry

    struct Entry {
        let key: String
        let title: String
        let icon: Icon
        /// Official primitives glyph (`Icon*OutlineRegular`), kept for the asset pass.
        let officialIcon: String
        let variant: RowVariant

        init(_ key: String, _ title: String, icon: Icon, official: String, variant: RowVariant) {
            self.key = key
            self.title = title
            self.icon = icon
            officialIcon = official
            self.variant = variant
        }
    }

    // MARK: - Fallback

    /// Official generic title (`tool.title.generic`) used for unknown tools.
    static let missingTitle = "工具调用"
    static let missingIcon: Icon = .asset("DSHSparkle")
    static let missingVariant: RowVariant = .generic

    // MARK: - The 54 shipped `tool.call.toolview` keys

    static let entries: [Entry] = [
        // 1-11: dedicated toolviews (bash-sample, read-row, read-image-row,
        // search-row, web-row, file-mutation-row, todo-row, ask-question-row).
        Entry("bash", "运行命令", icon: .asset("DSHTerminal"), official: "IconApiOutlineRegular", variant: .bash),
        Entry("read", "读取", icon: .asset("DSHRead"), official: "IconBrowseOutlineRegular", variant: .read),
        Entry("read_image", "读取图片", icon: .asset("DSHRead"), official: "IconBrowseOutlineRegular", variant: .image),
        Entry("grep", "搜索文件内容", icon: .asset("DSHSearch"), official: "IconSearchOutlineRegular", variant: .search),
        Entry("glob", "查找文件", icon: .asset("DSHSearch"), official: "IconSearchOutlineRegular", variant: .search),
        Entry("web_search", "网页搜索", icon: .system("globe"), official: "IconGlobeOutlineRegular", variant: .web),
        Entry("web_fetch", "网页获取", icon: .asset("DSHRead"), official: "IconBrowseOutlineRegular", variant: .web),
        Entry("edit", "编辑", icon: .asset("DSHEdit"), official: "IconEditOutlineRegular", variant: .edit),
        Entry("write", "写入", icon: .asset("DSHEdit"), official: "IconEditOutlineRegular", variant: .write),
        Entry("todo_write", "更新任务清单", icon: .system("checklist"), official: "IconChecklistOutlineRegular", variant: .todo),
        Entry("ask_user_question", "提问", icon: .system("questionmark.circle"), official: "IconQuestionOutlineRegular", variant: .ask),

        // 12-18: goal and schedule (details-row.tsx:80-86).
        Entry("create_goal", "创建目标", icon: .system("target"), official: "IconGoalOutlineRegular", variant: .goal),
        Entry("get_goal", "查看目标", icon: .system("target"), official: "IconGoalOutlineRegular", variant: .goal),
        Entry("update_goal", "更新目标", icon: .system("target"), official: "IconGoalOutlineRegular", variant: .goal),
        Entry("schedule_create", "创建定时任务", icon: .system("clock"), official: "IconClockOutlineRegular", variant: .schedule),
        Entry("schedule_list", "查看定时任务", icon: .system("clock"), official: "IconClockOutlineRegular", variant: .schedule),
        Entry("schedule_delete", "删除定时任务", icon: .system("clock"), official: "IconClockOutlineRegular", variant: .schedule),
        Entry("schedule_update", "修改定时任务", icon: .system("clock"), official: "IconClockOutlineRegular", variant: .schedule),

        // 19-23: cordis inspection and workflows.
        Entry("cordis_inspect_list", "检查提供方", icon: .system("puzzlepiece.extension"), official: "IconCordisPluginOutlineRegular", variant: .details),
        Entry("cordis_inspect_query", "查询运行时", icon: .system("puzzlepiece.extension"), official: "IconCordisPluginOutlineRegular", variant: .details),
        Entry("cordis_inspect_self", "检查动态插件", icon: .system("puzzlepiece.extension"), official: "IconCordisPluginOutlineRegular", variant: .details),
        Entry("workflow", "运行工作流", icon: .asset("DSHBranch"), official: "IconBranchOutlineRegular", variant: .workflow),
        Entry("ralph", "运行循环工作流", icon: .asset("DSHBranch"), official: "IconBranchOutlineRegular", variant: .workflow),

        // 24-29: session inspection and subagent-model discovery.
        Entry("session_event_read", "读取事件", icon: .asset("DSHSearch"), official: "IconSearchOutlineRegular", variant: .details),
        Entry("session_event_search", "搜索事件", icon: .asset("DSHSearch"), official: "IconSearchOutlineRegular", variant: .details),
        Entry("session_event_trace", "追踪事件", icon: .asset("DSHSearch"), official: "IconSearchOutlineRegular", variant: .details),
        Entry("session_search", "搜索会话", icon: .asset("DSHSearch"), official: "IconSearchOutlineRegular", variant: .details),
        Entry("session_trace", "追踪会话", icon: .asset("DSHSearch"), official: "IconSearchOutlineRegular", variant: .details),
        Entry("list_subagent_models", "查看可用模型", icon: .system("cpu"), official: "IconAgentPresetOutlineRegular", variant: .subagent),

        // 30-33: agent coordination (TEAMMATE_TOOLS, details-row.tsx:27).
        Entry("subagent", "创建子智能体", icon: .system("person.2"), official: "IconUsersOutlineRegular", variant: .subagent),
        Entry("list_agents", "查看子智能体", icon: .system("person.2"), official: "IconUsersOutlineRegular", variant: .subagent),
        Entry("send_message", "发送消息", icon: .system("person.2"), official: "IconUsersOutlineRegular", variant: .subagent),
        Entry("interrupt_agent", "中断智能体", icon: .system("person.2"), official: "IconUsersOutlineRegular", variant: .subagent),

        // 34-36: background jobs (checklist family).
        Entry("job_list", "查看后台任务", icon: .system("checklist"), official: "IconChecklistOutlineRegular", variant: .job),
        Entry("job_output", "读取任务输出", icon: .system("checklist"), official: "IconChecklistOutlineRegular", variant: .job),
        Entry("job_kill", "取消后台任务", icon: .system("checklist"), official: "IconChecklistOutlineRegular", variant: .job),

        // 37-41: terminal sessions (code family).
        Entry("terminal_open", "创建终端", icon: .asset("DSHCode"), official: "IconCodeOutlineRegular", variant: .details),
        Entry("terminal_read", "读取终端", icon: .asset("DSHCode"), official: "IconCodeOutlineRegular", variant: .details),
        Entry("terminal_list", "查看终端", icon: .asset("DSHCode"), official: "IconCodeOutlineRegular", variant: .details),
        Entry("terminal_signal", "发送终端信号", icon: .asset("DSHCode"), official: "IconCodeOutlineRegular", variant: .details),
        Entry("terminal_close", "关闭终端", icon: .asset("DSHCode"), official: "IconCodeOutlineRegular", variant: .details),

        // 42-48: language server, teammates, team tasks, waiting.
        Entry("lsp", "查询代码符号", icon: .asset("DSHSearch"), official: "IconSearchOutlineRegular", variant: .details),
        Entry("spawn_teammate", "创建队友", icon: .system("person.2"), official: "IconUsersOutlineRegular", variant: .subagent),
        Entry("team_task_create", "创建团队任务", icon: .system("checklist"), official: "IconChecklistOutlineRegular", variant: .subagent),
        Entry("team_task_get", "读取团队任务", icon: .system("checklist"), official: "IconChecklistOutlineRegular", variant: .subagent),
        Entry("team_task_update", "更新团队任务", icon: .system("checklist"), official: "IconChecklistOutlineRegular", variant: .subagent),
        Entry("team_task_list", "查看团队任务", icon: .system("checklist"), official: "IconChecklistOutlineRegular", variant: .subagent),
        Entry("wait_agent", "等待子智能体", icon: .system("person.2"), official: "IconUsersOutlineRegular", variant: .subagent),

        // 49-54: plugin-owned keyed views (ui-skill, ui-deliverables, ui-cordis).
        Entry("skill", "加载技能", icon: .system("sparkles"), official: "IconSkillOutlineRegular", variant: .generic),
        Entry("present", "交付文件", icon: .system("doc.text"), official: "IconDeliverDocRegular", variant: .generic),
        Entry("cordis_define", "注册 Cordis 插件", icon: .system("puzzlepiece.extension"), official: "IconCordisPluginOutlineRegular", variant: .details),
        Entry("cordis_run", "运行 Cordis 插件", icon: .system("puzzlepiece.extension"), official: "IconCordisPluginOutlineRegular", variant: .details),
        Entry("cordis_stop", "停止 Cordis 插件", icon: .system("puzzlepiece.extension"), official: "IconCordisPluginOutlineRegular", variant: .details),
        Entry("cordis_undefine", "移除 Cordis 插件", icon: .system("puzzlepiece.extension"), official: "IconCordisPluginOutlineRegular", variant: .details),
    ]

    /// Tool names the iOS side already receives that own no keyed toolview of
    /// their own but reuse an existing row (kept out of `entries` so the official
    /// 54-key count stays checkable).
    static let aliases: [Entry] = [
        Entry("pwsh", "运行命令", icon: .asset("DSHTerminal"), official: "IconApiOutlineRegular", variant: .bash),
        Entry("run_code", "代码", icon: .asset("DSHCode"), official: "IconCodeOutlineRegular", variant: .generic),
        Entry("code", "代码", icon: .asset("DSHCode"), official: "IconCodeOutlineRegular", variant: .generic),
        Entry("str_replace_editor", "编辑", icon: .asset("DSHEdit"), official: "IconEditOutlineRegular", variant: .edit),
        Entry("cordis_package_inspect", "查询 Cordis 环境", icon: .system("puzzlepiece.extension"), official: "IconCordisPluginOutlineRegular", variant: .details),
        Entry("cordis_runtime_inspect", "查询 Cordis 环境", icon: .system("puzzlepiece.extension"), official: "IconCordisPluginOutlineRegular", variant: .details),
    ]

    /// `lsp` narrows its title by `args.operation` (details-row.tsx:19-26).
    static let lspOperationTitles: [String: String] = [
        "goToDefinition": "查找定义",
        "findReferences": "查找引用",
        "goToImplementation": "查找实现",
        "hover": "查看符号信息",
    ]

    /// The 37 recorded-result keys that `details-row.tsx:80-116` registers: they
    /// render through `NativeToolDetailsCard` rather than a bespoke card.
    static let detailsKeys: Set<String> = [
        "create_goal", "get_goal", "update_goal",
        "schedule_create", "schedule_list", "schedule_delete", "schedule_update",
        "cordis_inspect_list", "cordis_inspect_query", "cordis_inspect_self",
        "workflow", "ralph",
        "session_event_read", "session_event_search", "session_event_trace",
        "session_search", "session_trace",
        "list_subagent_models", "subagent", "list_agents", "send_message", "interrupt_agent",
        "job_list", "job_output", "job_kill",
        "terminal_open", "terminal_read", "terminal_list", "terminal_signal", "terminal_close",
        "lsp", "spawn_teammate",
        "team_task_create", "team_task_get", "team_task_update", "team_task_list",
        "wait_agent",
    ]

    /// Whether the tool's recorded result uses the generic details card.
    static func usesDetailsCard(for key: String) -> Bool { detailsKeys.contains(key) }

    private static let index: [String: Entry] = {
        var table: [String: Entry] = [:]
        for entry in entries + aliases { table[entry.key] = entry }
        return table
    }()

    // MARK: - API

    /// The full entry for a wire tool name, or nil when the app has never seen it.
    static func entry(for key: String) -> Entry? { index[key] }

    /// Official row title; unknown tools fall back to 工具调用 (`tool.title.generic`).
    static func title(for key: String, operation: String? = nil) -> String {
        if key == "lsp", let operation, let title = lspOperationTitles[operation] { return title }
        return entry(for: key)?.title ?? missingTitle
    }

    /// Official leading glyph for a tool: a bundled asset, else an SF Symbol stand-in.
    static func icon(for key: String) -> Icon { entry(for: key)?.icon ?? missingIcon }

    /// The glyph name only, for call sites that resolve the asset themselves.
    static func iconName(for key: String) -> String { icon(for: key).name }

    /// Asset-catalog name, or nil when the entry renders an SF Symbol.
    static func assetName(for key: String) -> String? {
        guard case .asset(let name) = icon(for: key) else { return nil }
        return name
    }

    /// Presentation variant used to choose the row/card family.
    static func variant(for key: String) -> RowVariant { entry(for: key)?.variant ?? missingVariant }
}

// MARK: - Icon view

/// Renders a `NativeToolTitleTable.Icon` in the official 14pt glyph inside a 16pt
/// leading box (DisclosureRow.module.css:50-72).
struct NativeToolTitleIconView: View {
    let icon: NativeToolTitleTable.Icon
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch icon {
            case .asset(let name):
                Image(name).resizable().renderingMode(.template).interpolation(.high)
            case .system(let name):
                Image(systemName: name).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#if DEBUG
private struct NativeToolTitleTablePreview: View {
    private let keys = ["bash", "grep", "web_search", "todo_write", "create_goal",
                        "schedule_list", "job_output", "subagent", "terminal_read",
                        "lsp", "workflow", "skill", "present", "mystery"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(keys, id: \.self) { key in
                HStack(spacing: 6) {
                    NativeToolTitleIconView(icon: NativeToolTitleTable.icon(for: key))
                        .frame(width: 16)
                    Text(NativeToolTitleTable.title(for: key))
                        .font(.system(size: 13))
                        .foregroundStyle(NativeParityTokens.labelTertiary)
                    Circle().fill(NativeParityTokens.labelCaption)
                        .frame(width: 2, height: 2).padding(.horizontal, 8)
                    Text(key)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(NativeParityTokens.labelTertiary)
                    Spacer(minLength: 0)
                }
                .frame(height: 24)
            }
        }
        .padding(NativeParityTokens.transcriptSide)
        .background(NativeParityTokens.surface)
    }
}

struct NativeToolTitleTablePreviewProvider: PreviewProvider {
    static var previews: some View { NativeToolTitleTablePreview() }
}
#endif

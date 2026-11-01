// SPDX-License-Identifier: MIT
// Official process-group classification and title rules.
//
// Source of truth: deepseek-harness 7be5505b0b `step-process.ts` (activity
// families + labels) and `locales/zh` (`message.process.*`). This file is pure
// data so the grouping rule can be unit-tested without SwiftUI.

import Foundation

enum NativeProcessCategory: String, CaseIterable {
    case thinking, read, readImage, search, edit, write, commands, code
    case webSearch, webFetch, subagents, plan, questions, tools

    /// Official running label (`process.running.*`).
    var runningLabel: String {
        switch self {
        case .thinking: return "正在分析请求"
        case .read: return "正在读取文件"
        case .readImage: return "正在读取图片"
        case .search: return "正在搜索代码"
        case .edit: return "正在编辑文件"
        case .write: return "正在写入文件"
        case .commands: return "正在运行命令"
        case .code: return "正在运行代码"
        case .webSearch: return "正在搜索网页"
        case .webFetch: return "正在访问网页"
        case .subagents: return "正在协调子智能体"
        case .plan: return "正在更新计划"
        case .questions: return "等待你的操作"
        case .tools: return "正在调用工具"
        }
    }

    /// Official finished label (`process.done.*`).
    var finishedLabel: String {
        switch self {
        case .thinking: return "已完成分析"
        case .read: return "已读取文件"
        case .readImage: return "已读取图片"
        case .search: return "已搜索代码"
        case .edit: return "修改了文件"
        case .write: return "已写入文件"
        case .commands: return "执行了命令"
        case .code: return "运行了代码"
        case .webSearch: return "已搜索网页"
        case .webFetch: return "已访问网页"
        case .subagents: return "已协调子智能体"
        case .plan: return "更新了计划"
        case .questions: return "向用户提出了问题"
        case .tools: return "已调用工具"
        }
    }

    /// Official glyph family (ChatGroupSeat.tsx `PROCESS_ICONS`).
    var glyph: NativeProcessGroupGlyph {
        switch self {
        case .thinking: return .thinking
        case .read: return .read
        case .readImage: return .readImage
        case .search: return .search
        case .edit: return .edit
        case .write: return .write
        case .commands: return .commands
        case .code: return .code
        case .webSearch: return .webSearch
        case .webFetch: return .webFetch
        case .subagents: return .subagents
        case .plan: return .plan
        case .questions: return .questions
        case .tools: return .tools
        }
    }

    /// Official tool-name → activity mapping (`step-process.ts`).
    static func forTool(_ name: String) -> NativeProcessCategory {
        switch name {
        case "read": return .read
        case "read_image": return .readImage
        case "grep", "glob", "session_search", "session_event_search", "session_trace":
            return .search
        case "edit", "apply_patch", "str_replace_editor": return .edit
        case "write": return .write
        case "bash", "pwsh", "exec_command", "write_stdin":
            return .commands
        case _ where name.hasPrefix("terminal_"): return .commands
        case "run_code": return .code
        case "web_search": return .webSearch
        case "web_fetch": return .webFetch
        case "subagent", "list_agents", "list_subagent_models", "send_message",
             "wait_agent", "interrupt_agent", "spawn_teammate":
            return .subagents
        case "todo_write", "exit_plan_mode":
            return .plan
        case "ask_user_question", "request_user_input": return .questions
        default: return .tools
        }
    }
}

enum NativeProcessGroupModel {
    /// A closed group's title. Rules from `step-process.ts`:
    /// - 1 category: its finished label.
    /// - 2 categories: `{first}并{second}`; drop the second `已` when both
    ///   labels start with `已`.
    /// - >2: first three joined with `，` plus `等`.
    static func title(for categories: [NativeProcessCategory], running: Bool) -> String {
        let unique = uniqueCategories(categories)
        guard let first = unique.first else {
            return running ? NativeProcessCategory.thinking.runningLabel
                : NativeProcessCategory.thinking.finishedLabel
        }
        if running {
            if unique.count == 1 { return first.runningLabel }
            return unique.map(\.runningLabel).joined(separator: "，") + "等"
        }
        if unique.count == 1 { return first.finishedLabel }
        if unique.count == 2 {
            let second = unique[1].finishedLabel
            if first.finishedLabel.hasPrefix("已"), second.hasPrefix("已") {
                return first.finishedLabel + "并" + second.dropFirst()
            }
            return first.finishedLabel + "并" + second
        }
        return unique.prefix(3).map(\.finishedLabel).joined(separator: "，") + "等"
    }

    private static func uniqueCategories(_ categories: [NativeProcessCategory]) -> [NativeProcessCategory] {
        var seen: Set<NativeProcessCategory> = []
        return categories.filter { seen.insert($0).inserted }
    }
}

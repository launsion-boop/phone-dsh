// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

struct NativeToolCallModel {
    enum Variant {
        case search, read, bash, write, edit, code, others
    }

    let item: ChatItem
    let name: String
    let variant: Variant
    let state: NativeToolState

    init(item: ChatItem) {
        self.item = item
        name = item.toolName ?? item.title.replacingOccurrences(of: "Tool call: ", with: "")
        switch name {
        case "grep", "glob", "web_search": variant = .search
        case "read", "read_image", "web_fetch", "cordis_package_inspect", "cordis_runtime_inspect": variant = .read
        case "bash", "pwsh": variant = .bash
        case "write": variant = .write
        case "edit", "str_replace_editor": variant = .edit
        case "run_code": variant = .code
        default: variant = .others
        }
        if let explicit = item.toolState { state = explicit }
        else if case .toolResult(let isError) = item.kind { state = isError ? .error : .ok }
        else { state = .running }
    }

    var icon: NativeChatIcon.Name {
        switch variant {
        case .search: .search
        case .read: .read
        case .bash: .terminal
        case .write, .edit: .edit
        case .code: .code
        case .others: .sparkle
        }
    }

    var title: String {
        switch name {
        case "web_search": return "网页搜索"
        case "web_fetch": return "网页获取"
        case "read_image": return "读取图片"
        case "todo_write": return "更新任务清单"
        case "ask_user_question": return "向你提问"
        case "subagent": return "子 Agent"
        default:
            switch variant {
            case .search: return "搜索"
            case .read: return "读取"
            case .bash: return "运行命令"
            case .write: return "写入"
            case .edit: return "编辑"
            case .code: return "代码"
            case .others: return "工具调用"
            }
        }
    }

    var argumentsObject: [String: JSONValue]? { item.arguments?.objectValue }
    var input: String? {
        guard let raw = item.argumentsRaw, !raw.isEmpty else { return item.text.isEmpty ? nil : item.text }
        if variant == .code, let code = argumentsObject?["code"]?.stringValue, !code.isEmpty { return code }
        return nativePrettyJSON(item.arguments ?? .string(raw))
    }
    var output: String? {
        if let value = item.toolOutput, !value.isEmpty { return value }
        if case .toolResult = item.kind, !item.text.isEmpty { return item.text }
        return nil
    }

    var filePath: String? {
        guard [.read, .write, .edit].contains(variant) else { return nil }
        return item.toolMetadata?["path"]?.stringValue
            ?? argumentsObject?["file_path"]?.stringValue
            ?? argumentsObject?["path"]?.stringValue
    }

    var summary: String {
        if state == .error, let output, let line = output.components(separatedBy: .newlines).first, !line.isEmpty { return line }
        if state == .stopped { return "已停止" }
        if let filePath { return filePath }
        if let args = argumentsObject {
            let keys: [String]
            switch variant {
            case .bash: keys = ["description", "command"]
            case .read: keys = ["path", "file_path", "url"]
            case .search: keys = ["query", "pattern", "url", "queries"]
            case .write, .edit: keys = ["path", "file_path"]
            case .code: keys = ["description"]
            case .others: keys = []
            }
            for key in keys {
                if let value = args[key]?.stringValue, let line = value.components(separatedBy: .newlines).first, !line.isEmpty { return line }
                if key == "queries", let values = args[key]?.arrayValue?.compactMap(\.stringValue), !values.isEmpty {
                    return values.joined(separator: ", ")
                }
            }
            if variant == .others, let first = args.values.compactMap(\.stringValue).first { return first }
            if variant == .others { return name }
        }
        return item.text.components(separatedBy: .newlines).first ?? ""
    }

    var hasDetails: Bool { input != nil || output != nil || filePath != nil }
}

// SPDX-License-Identifier: MIT
// 工具在界面上的说法:分档、行标题、权限卡标题与第二行。
// 宿主的工具名、英文 title、reason 一个字都不上屏;认不出就留白。

import Foundation

enum ToolCategory: String {
    case read, write, edit, delete, move, search, execute, fetch, other

    /// 消息里那一行。兜底只写「做了个操作」,前面不加「调用工具 · 」。
    var rowTitle: String {
        switch self {
        case .read: return "读文件"
        case .write: return "写文件"
        case .edit: return "改文件"
        case .delete: return "删文件"
        case .move: return "移动文件"
        case .search: return "搜索"
        case .execute: return "跑命令"
        case .fetch: return "打开网页"
        case .other: return "做了个操作"
        }
    }

    /// 权限卡的标题,一律是问句。
    var permissionTitle: String {
        switch self {
        case .read: return "要读一个文件,可以吗?"
        case .write: return "要写一个文件,可以吗?"
        case .edit: return "要改这个文件,可以吗?"
        case .delete: return "要删掉一个文件,可以吗?"
        case .move: return "要挪动一个文件,可以吗?"
        case .search: return "要在文件夹里搜东西,可以吗?"
        case .execute: return "要跑一条命令,可以吗?"
        case .fetch: return "要打开一个网页,可以吗?"
        case .other: return "要继续吗?"
        }
    }
}

enum ToolWording {
    /// 宿主只给工具名和参数,没有档位字段;按名字推一档,推不出就是 other。
    static func category(forToolName name: String) -> ToolCategory {
        let n = name.lowercased()
        func has(_ keys: [String]) -> Bool { keys.contains { n.contains($0) } }

        // 顺序有讲究:move/delete 里也可能带 file,先判更具体的。
        if has(["move", "rename"]) { return .move }
        if has(["delete", "remove", "rm_"]) { return .delete }
        if has(["search", "grep", "glob", "find", "list_files", "listdir"]) { return .search }
        if has(["execute", "run_command", "shell", "bash", "terminal", "exec"]) { return .execute }
        if has(["fetch", "http", "url", "browse", "web"]) { return .fetch }
        if has(["edit", "patch", "replace", "insert", "append"]) { return .edit }
        if has(["write", "create", "save_file"]) { return .write }
        if has(["read", "open_file", "cat", "view"]) { return .read }
        return .other
    }

    /// 权限卡的第二行。认不出、或拿不到参数时返回 nil:整行不出现。
    static func detail(for category: ToolCategory, arguments: [String: String]) -> String? {
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let v = arguments.first(where: { $0.key.lowercased() == key })?.value,
                   !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v }
            }
            return nil
        }

        switch category {
        case .read, .write, .edit, .delete:
            guard let path = value(["path", "file_path", "filepath", "target_file", "file"]) else { return nil }
            return relative(path)
        case .move:
            guard let from = value(["from", "old_path", "source", "src"]),
                  let to = value(["to", "new_path", "destination", "dest"]) else { return nil }
            return "\(relative(from)) → \(relative(to))"
        case .search:
            return value(["query", "pattern", "q", "term"])
        case .execute:
            return value(["command", "cmd", "script"])
        case .fetch:
            guard let raw = value(["url", "uri", "href"]),
                  let url = URL(string: raw) else { return nil }
            // 只写域名和路径,不带协议、参数和锚点。
            let path = url.path
            return path.isEmpty || path == "/" ? url.host : "\(url.host ?? "")\(path)"
        case .other:
            return nil
        }
    }

    /// 路径一律相对工作文件夹:手机上整条绝对路径对人没有意义。
    static func relative(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = ChatModel.shared.workspaceRoot
        for prefix in [root.path, root.standardizedFileURL.path] where !prefix.isEmpty {
            if trimmed.hasPrefix(prefix) {
                trimmed = String(trimmed.dropFirst(prefix.count))
                break
            }
        }
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        return trimmed.isEmpty ? path : trimmed
    }
}

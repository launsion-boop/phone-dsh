// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

/// File-write effects and their directory Grant granularity.
///
/// A Bot's DSH session cwd is its own workspace root
/// (`BotWorkspaceLayout.botRoot`). A `write`/`edit` whose target stays inside
/// that root needs no structural approval; the DSH file sandbox is the
/// enforcement boundary. A target outside the root is an egress-class write
/// and is authorized per parent directory, not per argument digest, so an
/// "always" decision can be reused for the next write in the same directory.
///
/// The resource is `dir=<standardized absolute parent>`. The file name,
/// content and argument digest never participate. Containment is decided on
/// the standardized absolute path, so `notes/../outside.txt` resolves outside
/// the root before the decision.
public enum BotEgressEffects {
    public static let toolName = "egress"

    // MARK: - File writes

    /// One `write`/`edit` effect, or `[]` when the target is inside the Bot
    /// workspace root (auto-policy, no approval card).
    public static func fileEffects(tool: String, arguments: BotJSONValue,
                                   workspaceRoot: String,
                                   language: BotToolLanguage = .zh) -> [BotToolEffect] {
        guard tool == "write" || tool == "edit" else { return [] }
        guard case .object(let args) = arguments,
              case .string(let rawPath)? = args["file_path"],
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A malformed file call must never fall through to auto-policy: the
            // unknown effect keeps the "always" scope at session and asks.
            return [BotToolEffect(
                tool: tool, operation: "tool.unclassified",
                resource: "unclassified=\(tool)&args=invalid", target: tool,
                mutability: .write, policy: .ask,
                label: language == .zh ? "執行未分類檔案工具 \(tool)" : "Run unclassified file tool \(tool)",
                detail: language == .zh
                    ? "file_path 缺失或為空；依預設需要使用者審批。"
                    : "file_path is missing or empty; it needs approval by default.",
                ui: false, execution: nil, known: false, isMcp: false)]
        }
        let target = resolve(path: rawPath, workspaceRoot: workspaceRoot)
        guard !isInsideWorkspace(target, workspaceRoot: workspaceRoot) else { return [] }
        let directory = directoryResource(path: target)
        let operation = tool == "write" ? "file.write" : "file.edit"
        let label: String
        let detail: String
        if language == .zh {
            label = tool == "write" ? "寫入工作區外的檔案" : "編輯工作區外的檔案"
            detail = "目標 \(target) 不在這個 Bot 的工作區 \(workspaceRoot) 內；授權按目錄 \(directory) 記住。"
        } else {
            label = tool == "write" ? "Write a file outside the Bot workspace"
                                  : "Edit a file outside the Bot workspace"
            detail = "The target \(target) is outside this Bot's workspace \(workspaceRoot); "
                + "the approval is remembered per directory \(directory)."
        }
        return [BotToolEffect(
            tool: tool, operation: operation, resource: directory, target: target,
            mutability: .write, policy: .ask, label: label, detail: detail,
            ui: false, execution: nil, known: true, isMcp: false)]
    }

    /// Standardized absolute target path for one `file_path` argument.
    public static func resolve(path: String, workspaceRoot: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute: String
        if (trimmed as NSString).isAbsolutePath {
            absolute = trimmed
        } else {
            absolute = (workspaceRoot as NSString).appendingPathComponent(trimmed)
        }
        return (absolute as NSString).standardizingPath
    }

    /// True when `path` is the workspace root or a descendant of it.
    public static func isInsideWorkspace(_ path: String, workspaceRoot: String) -> Bool {
        let root = (workspaceRoot as NSString).standardizingPath
        let normalizedRoot = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        if normalizedRoot == "/" { return true }
        let candidate = (path as NSString).standardizingPath
        return candidate == normalizedRoot || candidate.hasPrefix(normalizedRoot + "/")
    }

    /// `dir=<standardized absolute parent>` for one target path.
    public static func directoryResource(path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let directory = parent.isEmpty ? "/" : (parent as NSString).standardizingPath
        return "dir=\(directory)"
    }

    // MARK: - Network writes

    /// Grant operation for one network-write method: `egress.post`, …
    public static func egressOperation(method: String) -> String {
        "egress.\(method.lowercased())"
    }

    /// Host-only Grant resource for one URL host. Scheme, port, path and query
    /// are deliberately excluded; the user approves "this host, this method".
    public static func egressResource(host: String) -> String {
        "host=\(host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// One approval effect for a Bot network write.
    public static func egressEffect(method: String, host: String, target: String,
                                    language: BotToolLanguage = .zh) -> BotToolEffect {
        let upper = method.uppercased()
        let resource = egressResource(host: host)
        let label = language == .zh
            ? "向 \(host) 傳送網路 \(upper) 請求"
            : "Send a network \(upper) request to \(host)"
        let detail = language == .zh
            ? "這是 Bot 會話在宿主出口發出的網路寫入；授權按主機與方法記住。"
            : "This is a Bot-session network write at the host exit; the approval is "
                + "remembered per host and method."
        return BotToolEffect(
            tool: toolName, operation: egressOperation(method: upper), resource: resource,
            target: target, mutability: .externalSend, policy: .ask,
            label: label, detail: detail, ui: false, execution: nil,
            known: true, isMcp: false)
    }
}

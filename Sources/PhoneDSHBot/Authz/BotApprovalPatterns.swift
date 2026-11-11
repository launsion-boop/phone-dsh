// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public struct BotApprovalPatternMatch: Codable, Sendable, Equatable {
    public let kind: String
    public let label: String
    public let detail: String
    public let target: String
    public let resource: String
    public let askAction: String
    public let grantKeys: [String]

    public init(kind: String, label: String, detail: String, target: String,
                resource: String, askAction: String = "run-command", grantKeys: [String]) {
        self.kind = kind
        self.label = label
        self.detail = detail
        self.target = target
        self.resource = resource
        self.askAction = askAction
        self.grantKeys = grantKeys
    }
}

public enum BotApprovalPatternAnalyzer {
    public static func analyze(tool: String, arguments: BotJSONValue,
                               workspace: String, language: BotToolLanguage = .en) -> [BotApprovalPatternMatch] {
        guard tool == "bash", case .object(let args) = arguments,
              case .string(let command)? = args["command"], !command.isEmpty else { return [] }
        if matches(#"(?:^|[;&|]\s*)rm\s+(?:[^\s;&|]+\s+)*-"#, command) || command.hasPrefix("rm ") {
            let resource = rmResource(command: command, workspace: workspace)
            return [match(kind: "rm-destructive", zhLabel: "删除文件或目录（rm）",
                          enLabel: "Delete files or directories (rm)",
                          zhDetail: "这个命令会删除文件或目录：\(command)",
                          enDetail: "This command deletes files or directories: \(command)",
                          command: command, resource: resource, language: language)]
        }
        if matches(#"(?:^|[;&|]\s*)git\s+reset\s+[^\n]*--hard"#, command) {
            return [match(kind: "git-destructive", zhLabel: "丢弃 Git 工作区变更",
                          enLabel: "Discard Git working-tree changes",
                          zhDetail: "这个命令会丢弃未提交的变更：\(command)",
                          enDetail: "This command discards uncommitted changes: \(command)",
                          command: command, resource: command, language: language)]
        }
        if matches(#"(?:^|[;&|]\s*)find\s+[^\n]*(?:\s|^)-delete(?:\s|$)"#, command) {
            return [match(kind: "find-delete", zhLabel: "使用 find -delete 删除文件",
                          enLabel: "Delete files with find -delete",
                          zhDetail: "find -delete 会移除符合条件的文件：\(command)",
                          enDetail: "find -delete removes the matching files: \(command)",
                          command: command, resource: command, language: language)]
        }
        // Network writes are deliberately not classified here any more. The
        // command text is model-controlled (script files, variable
        // concatenation, interpreters), so it is not a security boundary; the
        // host `/v1/http` exit owns the host+method approval instead
        // (spec/bot/v1/README.md §2.4). The destructive patterns above stay as
        // advisory hints on the approval card.
        return []
    }

    public static func effects(tool: String, arguments: BotJSONValue,
                               workspace: String, language: BotToolLanguage = .en) -> [BotToolEffect] {
        analyze(tool: tool, arguments: arguments, workspace: workspace, language: language).map {
            BotToolEffect(tool: tool, operation: $0.kind, resource: $0.resource,
                          target: $0.target, mutability: .destructive,
                          policy: .ask, label: $0.label, detail: $0.detail)
        }
    }

    private static func match(kind: String, zhLabel: String, enLabel: String,
                              zhDetail: String, enDetail: String, command: String,
                              resource: String, language: BotToolLanguage) -> BotApprovalPatternMatch {
        BotApprovalPatternMatch(kind: kind, label: language == .zh ? zhLabel : enLabel,
                                detail: language == .zh ? zhDetail : enDetail,
                                target: command, resource: resource, grantKeys: [command])
    }

    private static func rmResource(command: String, workspace: String) -> String {
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let rmIndex = tokens.firstIndex(of: "rm") else { return command }
        let operands = tokens[(rmIndex + 1)..<tokens.count].filter {
            !$0.hasPrefix("-") && $0 != "--"
        }
        guard let operand = operands.first else { return command }
        let path = (operand as NSString).isAbsolutePath
            ? operand : (workspace as NSString).appendingPathComponent(operand)
        return (path as NSString).standardizingPath
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

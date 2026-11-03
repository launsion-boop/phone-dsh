// SPDX-License-Identifier: MIT

import Foundation

public enum PersonalAgentTextPolicy {
    public static let conciseSystemPrompt = """
    结论先行，不复述用户问题。简单回答只用 1–3 个短句；行动结果只说明完成了什么，
    必要时附一个来源或下一步。不要输出思考过程、命令、工具原始结果、JSON、token、
    session、turn、TaskRun 或内部路由。复杂依据放入可展开 Artifact。用户明确要求详细解释时才展开。
    """

    public static func visibleAssistantText(_ raw: String, allowEmpty: Bool = false) -> String {
        var text = raw
        let blocks = [
            #"(?is)<thinking>.*?</thinking>"#, #"(?is)<reasoning>.*?</reasoning>"#,
            #"(?is)<analysis>.*?</analysis>"#, #"(?is)```(?:bash|sh|shell|json|tool|tool_result)?\s*.*?```"#,
        ]
        for pattern in blocks {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let lines = text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if trimmed.isEmpty { return true }
            if lower.hasPrefix("bash ") || lower.hasPrefix("shell ") || lower.hasPrefix("$ ") ||
                lower.hasPrefix("tool_result") || lower.hasPrefix("tool_use") ||
                lower.hasPrefix("taskrun") || lower.contains("taskrun id") ||
                lower.contains("sessionid") || lower.contains("turnid") ||
                lower.hasPrefix("mcp ") { return false }
            if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
                (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) { return false }
            return true
        }
        let visible = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if visible.isEmpty, !allowEmpty { return "已完成，但没有可展示的文字结果。" }
        return visible
    }

    public static func failureText(_ failure: MainFailure) -> String {
        switch failure {
        case .unsupportedProtocol:
            return "暂不支持该模型协议，可改用 DSH。"
        case .notConfigured:
            return "模型尚未配置，请先完成配置。"
        case .cancelled:
            return "已停止，未自动重试。"
        case .toolLimitExceeded:
            return "这次处理步骤过多，请缩小范围后重试。"
        case .provider:
            return "模型服务暂时不可用，请稍后重试。"
        case .invalidResponse:
            return "回答格式无法显示，请重试。"
        }
    }
}

public enum DailyBriefChatArtifact {
    public static func make(snapshot: DailyBriefSnapshot, newItemCount: Int) -> ConversationArtifactRef? {
        guard newItemCount > 0, !snapshot.items.isEmpty else { return nil }
        return ConversationArtifactRef(id: snapshot.id, kind: "dailyBrief",
                                       title: "每日简报 · \(newItemCount) 条更新",
                                       locator: "daily-brief://snapshot/\(snapshot.id)",
                                       createdAt: snapshot.createdAt)
    }
}

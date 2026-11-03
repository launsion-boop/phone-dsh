// SPDX-License-Identifier: MIT

import Foundation

public enum PersonalAgentTextPolicy {
    public static let conciseSystemPrompt = """
    Lead with the answer and stay concise. Preserve requested code, commands, evidence, and failures.
    Do not expose hidden reasoning or raw tool protocols unless a technical explanation was requested.
    """

    public static func visibleAssistantText(_ raw: String, allowEmpty: Bool = false) -> String {
        var sections: [String] = []
        var plainLines: [String] = []
        var insideFence = false
        for line in raw.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !insideFence {
                    sections.append(visiblePlainText(plainLines.joined(separator: "\n")))
                    plainLines = []
                    insideFence = true
                } else {
                    insideFence = false
                }
                sections.append(line)
            } else if insideFence {
                sections.append(line)
            } else {
                plainLines.append(line)
            }
        }
        if !plainLines.isEmpty {
            sections.append(visiblePlainText(plainLines.joined(separator: "\n")))
        }
        return sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func visiblePlainText(_ raw: String) -> String {
        var text = raw
        let blocks = [
            #"(?is)<thinking>.*?</thinking>"#, #"(?is)<reasoning>.*?</reasoning>"#,
            #"(?is)<analysis>.*?</analysis>"#,
        ]
        for pattern in blocks {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.components(separatedBy: .newlines).filter { line in
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
        }.joined(separator: "\n")
            .replacingOccurrences(of: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
                                  with: "", options: .regularExpression)
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

// SPDX-License-Identifier: MIT

import Foundation

/// The only memory content injected every turn: the two root INDEX.md
/// documents plus the ownership/visibility explanation. There is deliberately
/// no clipping here; an over-limit index is rejected at write time.
public enum BotMemoryInjector {
    public static func render(
        userIndex: BotMemoryDocument?,
        agentIndex: BotMemoryDocument?,
        language: BotMemoryPromptLanguage = .zh
    ) -> BotMemoryInjection {
        let zh = language != .en
        let header = zh ? zhHeader : enHeader
        let userBody = body(userIndex, zh: zh)
        let agentBody = body(agentIndex, zh: zh)
        let userHeading = heading("user/INDEX.md", userIndex, zh: zh)
        let agentHeading = heading("agent/INDEX.md", agentIndex, zh: zh)
        let text = [
            header,
            "",
            userHeading,
            "",
            userBody,
            "",
            agentHeading,
            "",
            agentBody,
            "",
        ].joined(separator: "\n")
        return BotMemoryInjection(text: text)
    }

    private static let zhHeader = """
    ## 记忆

    记忆是你自己组织的 Markdown 文档树，跨对话保留。每回合只注入两个根下的 INDEX.md；正文用 `ReadMemory` 读，较早或相关的文档用 `RecallMemory` 搜。可以不记：只写值得跨对话保留的规则、决定与承诺、偏好、策略和原因；能从原始记录重新读到的内容不要复制，需要原文时留下 `record://` 引用。

    - `user/`：关于用户，所有 Bot 共享、彼此可见。写入需要用户消息引用；Task 和 routine 只能提交到 `agent/inbox/<会话>/`。
    - `agent/`：这个 Bot 自己的工作知识，其他 Bot 看不到。
    """

    private static let enHeader = """
    ## Memory

    Memory is a Markdown document tree you organize. Only each root's INDEX.md is injected each turn; use `ReadMemory` to read a document or list a directory, and `RecallMemory` to search older or related documents. You may choose not to remember: keep verified rules, decisions and commitments, preferences, strategies and reasons; do not copy what can be re-read from raw records — leave a `record://` reference when you need the exact source.

    - `user/`: about the user, shared by and visible to every Bot. A write needs a user-message reference; Task and routine sessions may only submit under `agent/inbox/<session>/`.
    - `agent/`: this Bot's own working knowledge, invisible to other Bots.
    """

    private static func heading(_ path: String, _ document: BotMemoryDocument?, zh: Bool) -> String {
        if let document {
            return zh
                ? "### \(path)（v\(document.version)）"
                : "### \(path) (v\(document.version))"
        }
        return "### \(path)"
    }

    private static func body(_ document: BotMemoryDocument?, zh: Bool) -> String {
        let text = document?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return zh ? "（空）" : "(empty)" }
        return text
    }
}

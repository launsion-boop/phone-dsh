// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

/**
 * The only memory content injected every turn (v2 §1.4): the two root
 * `INDEX.md` documents plus the ownership/visibility explanation. There is
 * deliberately no clipping here; an over-limit index is rejected at write
 * time.
 */
public enum class BotMemoryPromptLanguage { ZH, EN }

public object BotMemoryInjector {
    public fun render(
        userIndex: BotMemoryDocument?,
        agentIndex: BotMemoryDocument?,
        language: BotMemoryPromptLanguage = BotMemoryPromptLanguage.ZH,
    ): BotMemoryInjection {
        val zh = language != BotMemoryPromptLanguage.EN
        val header = if (zh) ZH_HEADER else EN_HEADER
        val userHeading = heading("user/INDEX.md", userIndex, zh)
        val agentHeading = heading("agent/INDEX.md", agentIndex, zh)
        val text = listOf(
            header,
            "",
            userHeading,
            "",
            body(userIndex, zh),
            "",
            agentHeading,
            "",
            body(agentIndex, zh),
            "",
        ).joinToString("\n")
        return BotMemoryInjection(text)
    }

    private val ZH_HEADER = """
        ## 记忆

        记忆是你自己组织的 Markdown 文档树，跨对话保留。每回合只注入两个根下的 INDEX.md；正文用 `ReadMemory` 读，较早或相关的文档用 `RecallMemory` 搜。可以不记：只写值得跨对话保留的规则、决定与承诺、偏好、策略和原因；能从原始记录重新读到的内容不要复制，需要原文时留下 `record://` 引用。

        - `user/`：关于用户，所有 Bot 共享、彼此可见。写入需要用户消息引用；Task 和 routine 只能提交到 `agent/inbox/<会话>/`。
        - `agent/`：这个 Bot 自己的工作知识，其他 Bot 看不到。
    """.trimIndent()

    private val EN_HEADER = """
        ## Memory

        Memory is a Markdown document tree you organize. Only each root's INDEX.md is injected each turn; use `ReadMemory` to read a document or list a directory, and `RecallMemory` to search older or related documents. You may choose not to remember: keep verified rules, decisions and commitments, preferences, strategies and reasons; do not copy what can be re-read from raw records — leave a `record://` reference when you need the exact source.

        - `user/`: about the user, shared by and visible to every Bot. A write needs a user-message reference; Task and routine sessions may only submit under `agent/inbox/<session>/`.
        - `agent/`: this Bot's own working knowledge, invisible to other Bots.
    """.trimIndent()

    private fun heading(path: String, document: BotMemoryDocument?, zh: Boolean): String =
        if (document != null) {
            if (zh) "### $path（v${document.version}）" else "### $path (v${document.version})"
        } else {
            "### $path"
        }

    private fun body(document: BotMemoryDocument?, zh: Boolean): String {
        val text = document?.content?.let(BotMemoryText::trimWhitespace).orEmpty()
        if (text.isEmpty()) return if (zh) "（空）" else "(empty)"
        return text
    }
}

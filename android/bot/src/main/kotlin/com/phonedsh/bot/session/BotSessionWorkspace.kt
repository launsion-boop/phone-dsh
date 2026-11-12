// SPDX-License-Identifier: MIT
package com.phonedsh.bot.session

import com.phonedsh.bot.attachments.BotWorkspaceLayout

/**
 * The Bot VFS root (`session-lifecycle.md` §2.1/§2.2).
 *
 * This is the P27 session entry point. It deliberately delegates the id
 * sanitising and grapheme truncation to the one implementation in
 * [BotWorkspaceLayout] so the session lane and the attachment lane cannot
 * drift: §2.1 step 5 counts extended grapheme clusters, while UTF-16 code
 * units would truncate the frozen 64 decomposed `e`+acute pairs at 32
 * clusters.
 */
public object BotSessionWorkspace {
    /** `BotWorkspaceLayout.defaultBotDataDirectory`. */
    public const val DEFAULT_BOT_DATA_DIRECTORY: String =
        BotWorkspaceLayout.DEFAULT_BOT_DATA_DIRECTORY

    /** `<dataDirectory>/agents/<safePathComponent(botId)>` (§2.2). */
    public fun botRoot(
        botId: String,
        dataDirectory: String = DEFAULT_BOT_DATA_DIRECTORY,
    ): String = BotWorkspaceLayout.botRoot(botId, dataDirectory)

    /**
     * §2.1: keep Unicode general categories `L*`, `M*`, `N*` and `.`, `_`, `-`
     * unchanged; replace every other scalar with `_`; fall back to `bot` for
     * `""`, `"."` and `".."`; finally truncate to 64 extended grapheme
     * clusters. One output scalar per input scalar.
     */
    public fun safePathComponent(raw: String): String =
        BotWorkspaceLayout.safePathComponent(raw)
}

// SPDX-License-Identifier: MIT
package com.phonedsh.bot.session

/**
 * `BotSessionKind` (`session-lifecycle.md` §2.3/§3). The wire value is the
 * DSH session kind; `chat` is the Bot main chat this contract owns.
 */
public enum class BotSessionKind(public val wire: String) {
    CHAT("chat"),
    TASK("task"),
    ROUTINE("routine"),
    VERIFIER("verifier"),
    TEAM("team"),
    PROACTIVE("proactive"),
    WATCHDOG("watchdog"),
    MAINTAINER("maintainer"),
    ;

    public companion object {
        public fun fromWire(value: String): BotSessionKind =
            entries.firstOrNull { it.wire == value }
                ?: throw BotSessionException("invalidInput", "unknown session kind: $value")
    }
}

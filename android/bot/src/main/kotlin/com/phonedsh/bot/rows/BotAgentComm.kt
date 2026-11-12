// SPDX-License-Identifier: MIT
package com.phonedsh.bot.rows

/**
 * The four row directions the upstream agent-comm transcript uses.
 *
 * - `outbound`: the sender's row for a message it just sent.
 * - `inbound`: the sender's row carrying the target's reply.
 * - `incoming`: the target's user row opened by an `[agent]` prompt.
 * - `reply`: the target's assistant row patched to name the sender.
 */
public enum class BotAgentCommDirection(public val wire: String) {
    OUTBOUND("outbound"),
    INBOUND("inbound"),
    INCOMING("incoming"),
    REPLY("reply"),
}

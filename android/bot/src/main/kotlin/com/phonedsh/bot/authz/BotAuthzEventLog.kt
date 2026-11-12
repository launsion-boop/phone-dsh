// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonObject

/**
 * The principal carried by one authz event. It is deliberately narrower than
 * the P25 `BotPrincipal`: authz only needs the Bot/session identity and the
 * session kind, and the B5a1 adapter maps the store envelope both ways.
 */
public data class BotAuthzPrincipal(
    public val botId: String?,
    public val sessionId: String?,
    public val kind: String,
    public val capabilities: List<String> = emptyList(),
)

/**
 * The minimal durable-event seam used by grants, audit and the approval
 * coordinator. It is a port, not a second event log: the B5a1 adapter wraps
 * `com.phonedsh.bot.store.BotDomainStore` so both sides keep using P25's
 * envelope, WAL and event ids.
 *
 * [sequence] is assigned by the log on append and is monotonic. [events]
 * returns events with a sequence strictly greater than [after], oldest first.
 */
public data class BotAuthzEvent(
    public val sequence: Long,
    public val type: String,
    public val eventId: String,
    public val time: Long,
    public val principal: BotAuthzPrincipal?,
    public val data: JsonObject,
    public val schemaVersion: Int = 1,
)

public interface BotAuthzEventLog {
    /** Appends one event; the returned value is the committed sequence. */
    public fun append(event: BotAuthzEvent): Long

    /** Events after [after], oldest first, at most [limit]. */
    public fun events(after: Long, limit: Int = 500): List<BotAuthzEvent>
}

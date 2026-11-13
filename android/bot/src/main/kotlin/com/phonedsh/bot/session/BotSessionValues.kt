// SPDX-License-Identifier: MIT
package com.phonedsh.bot.session

/**
 * One principal the Bot gateway token registry issued (`session-lifecycle.md`
 * §8.2/§8.3). Tokens and incarnations are opaque; consumers never parse them.
 */
public data class BotSessionPrincipal(
    public val botId: String,
    public val sessionId: String,
    public val kind: BotSessionKind,
    public val capabilities: List<String> = emptyList(),
    public val expiresAt: Long,
    public val incarnation: String,
)

/** One issued registry token plus the principal it authenticates. */
public data class BotIssuedSessionToken(
    public val token: String,
    public val principal: BotSessionPrincipal,
)

/** A host-side session failure. [code] is the frozen short class name. */
public class BotSessionException(
    public val code: String,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/**
 * A DSH Remote call failed. The transport reports the Remote error `code` and
 * `message`; the lifecycle state machine only special-cases `session/conflict`
 * and `session/not-found`.
 */
public class BotSessionRemoteException(
    public val code: String,
    public val detail: String,
) : Exception("$code: $detail")

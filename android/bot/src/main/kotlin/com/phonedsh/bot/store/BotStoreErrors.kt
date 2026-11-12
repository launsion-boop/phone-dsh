// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

/**
 * A store failure with the observable code frozen by `spec/bot/v1/store.md`
 * §12: the condition is normative, the type spelling is not.
 */
public open class BotStoreException(
    public val code: String,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/** An envelope validation failure (`store.md` §4.5). */
public class BotEventValidationException(
    code: String,
    public val field: String,
    message: String,
) : BotStoreException(code, message)

public fun invalidEvent(field: String, message: String): BotEventValidationException =
    BotEventValidationException("INVALID_EVENT", field, message)

public fun commitGap(expected: Long, actual: Long): BotStoreException =
    BotStoreException("commitGap:$expected:$actual", "commit sequence gap: expected $expected, found $actual")

public fun corrupted(message: String): BotStoreException =
    BotStoreException("corrupted", message)

public fun invalidConfiguration(message: String): BotStoreException =
    BotStoreException("invalidConfiguration", message)

public fun invalidCursor(message: String): BotStoreException =
    BotStoreException("invalidCursor", message)

public fun invalidTransition(message: String): BotStoreException =
    BotStoreException("invalidTransition", message)

public fun staleLease(effectKey: String): BotStoreException =
    BotStoreException("staleLease", "stale lease for effect $effectKey")

public fun unknownEffect(effectKey: String): BotStoreException =
    BotStoreException("unknownEffect", "unknown effect $effectKey")

public fun unknownEffectKind(kind: String): BotStoreException =
    BotStoreException("unknown_effect_kind", "effect kind has no registered executor: $kind")

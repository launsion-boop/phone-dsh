// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import java.security.MessageDigest

/**
 * The durable seam the monitor needs: append one event and look one event id
 * up. [BotDomainStoreWatchdogEventLog] binds it to the existing Bot store; a
 * fake may implement it to exercise the retry path.
 */
public interface BotWatchdogEventLog {
    public fun append(event: BotEvent): Long

    public fun event(eventId: String): BotEvent?
}

/** Adapter over the existing P25 [BotDomainStore]. */
public class BotDomainStoreWatchdogEventLog(
    private val store: BotDomainStore,
) : BotWatchdogEventLog {
    override fun append(event: BotEvent): Long = store.append(event)

    override fun event(eventId: String): BotEvent? = store.event(eventId)
}

/**
 * Observe-only watchdog monitor (`spec/bot/v1/watchdog.md` §3–§6).
 *
 * Units, `seen` and the recent flag history are in memory. The durable
 * `watchdog.flagged` event id is the real once-per-unit identity, so finishing
 * and restarting the same `(kind,id)` cannot publish a second event for the
 * same check. The monitor never sleeps; the host calls [tick] on `tickMs` and
 * immediately after each observed event.
 */
public class BotWatchdogMonitor(
    private val eventLog: BotWatchdogEventLog,
    public val config: BotWatchdogConfig = BotWatchdogConfig.DEFAULT,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val log: (String) -> Unit = {},
) {
    private data class UnitKey(val kind: BotWatchdogUnitKind, val id: String)

    private data class SeenKey(val unit: UnitKey, val check: BotWatchdogCheck)

    private data class TrackedUnit(
        var state: BotWatchdogUnit,
        val pendingCalls: MutableMap<String, String> = LinkedHashMap(),
    )

    private val units: MutableMap<UnitKey, TrackedUnit> = LinkedHashMap()
    private val pending: MutableSet<SeenKey> = LinkedHashSet()
    private val seen: MutableSet<SeenKey> = LinkedHashSet()
    private val recentFlags: MutableList<BotWatchdogFlag> = ArrayList()

    /** Convenience adapter for callers that already own the Bot store. */
    public constructor(
        store: BotDomainStore,
        config: BotWatchdogConfig = BotWatchdogConfig.DEFAULT,
        clock: () -> Long = { System.currentTimeMillis() },
        log: (String) -> Unit = {},
    ) : this(BotDomainStoreWatchdogEventLog(store), config, clock, log)

    @Synchronized
    public fun startUnit(
        kind: BotWatchdogUnitKind,
        id: String,
        botId: String? = null,
        sessionId: String? = null,
        startedAt: Long? = null,
        deadlineOverrideMs: Long? = null,
        at: Long? = null,
    ): List<BotWatchdogFlag> {
        val unitId = id.trim()
        if (unitId.isEmpty()) return emptyList()
        val now = at ?: clock()
        val key = UnitKey(kind, unitId)
        val existing = units[key]
        if (existing != null) {
            val state = existing.state
            existing.state = state.copy(
                botId = state.botId ?: botId,
                sessionId = state.sessionId ?: sessionId,
                lastEventAt = maxOf(state.lastEventAt ?: now, now),
            )
            return evaluate(key, now)
        }
        evictIfNeeded()
        val start = startedAt ?: now
        val deadlineMs = config.deadlineMs(kind, deadlineOverrideMs)
        val state = BotWatchdogUnit(
            kind = kind,
            id = unitId,
            botId = botId,
            sessionId = sessionId,
            startedAt = start,
            lastEventAt = now,
            deadlineAt = if (deadlineMs > 0) start + deadlineMs else null,
        )
        units[key] = TrackedUnit(state)
        return evaluate(key, now)
    }

    @Synchronized
    public fun finishUnit(kind: BotWatchdogUnitKind, id: String) {
        val key = UnitKey(kind, id)
        units.remove(key)
        seen.removeIf { it.unit == key }
    }

    @Synchronized
    public fun unit(kind: BotWatchdogUnitKind, id: String): BotWatchdogUnit? =
        units[UnitKey(kind, id)]?.state

    @Synchronized
    public fun observeActivity(
        kind: BotWatchdogUnitKind,
        id: String,
        at: Long? = null,
    ): List<BotWatchdogFlag> {
        val now = at ?: clock()
        val key = UnitKey(kind, id)
        val tracked = units[key] ?: return emptyList()
        tracked.state = tracked.state.copy(lastEventAt = maxOf(tracked.state.lastEventAt ?: now, now))
        return evaluate(key, now)
    }

    @Synchronized
    public fun observeApproval(
        kind: BotWatchdogUnitKind,
        id: String,
        requested: Boolean,
        at: Long? = null,
    ): List<BotWatchdogFlag> {
        val key = UnitKey(kind, id)
        val tracked = units[key] ?: return emptyList()
        tracked.state = tracked.state.copy(
            pendingApproval = maxOf(0, tracked.state.pendingApproval + if (requested) 1 else -1),
        )
        return observeActivity(kind, id, at)
    }

    @Synchronized
    public fun observeToolCall(
        kind: BotWatchdogUnitKind,
        id: String,
        name: String,
        argumentsDigest: String? = null,
        callId: String? = null,
        at: Long? = null,
    ): List<BotWatchdogFlag> {
        val key = UnitKey(kind, id)
        val tracked = units[key] ?: return emptyList()
        val signature = if (!argumentsDigest.isNullOrEmpty()) "$name|$argumentsDigest" else name
        val state = tracked.state
        tracked.state = if (signature == state.lastToolSignature) {
            state.copy(repeatedToolSignatureCount = state.repeatedToolSignatureCount + 1)
        } else {
            state.copy(lastToolSignature = signature, repeatedToolSignatureCount = 1)
        }
        if (!callId.isNullOrEmpty()) {
            tracked.pendingCalls[callId] = name
            while (tracked.pendingCalls.size > 200) {
                val oldest = tracked.pendingCalls.keys.sorted().firstOrNull() ?: break
                tracked.pendingCalls.remove(oldest)
            }
        }
        return observeActivity(kind, id, at)
    }

    @Synchronized
    public fun observeToolResult(
        kind: BotWatchdogUnitKind,
        id: String,
        name: String? = null,
        status: String,
        error: String? = null,
        resultDigest: String? = null,
        callId: String? = null,
        at: Long? = null,
    ): List<BotWatchdogFlag> {
        val key = UnitKey(kind, id)
        val tracked = units[key] ?: return emptyList()
        val pendingName = callId?.let { tracked.pendingCalls[it] }
        if (callId != null) tracked.pendingCalls.remove(callId)
        val toolName = pendingName ?: name ?: "unknown"
        val state = tracked.state
        tracked.state = if (status.lowercase() == "error") {
            val errorText = error ?: resultDigest ?: "error"
            val signature = "$toolName|${sha256(errorText)}"
            if (signature == state.lastToolErrorSignature) {
                state.copy(repeatedToolErrorCount = state.repeatedToolErrorCount + 1)
            } else {
                state.copy(lastToolErrorSignature = signature, repeatedToolErrorCount = 1)
            }
        } else {
            state.copy(lastToolErrorSignature = null, repeatedToolErrorCount = 0)
        }
        return observeActivity(kind, id, at)
    }

    @Synchronized
    public fun observeUsage(
        kind: BotWatchdogUnitKind,
        id: String,
        tokens: Long = 0,
        costUsd: Double = 0.0,
        at: Long? = null,
    ): List<BotWatchdogFlag> {
        val key = UnitKey(kind, id)
        val tracked = units[key] ?: return emptyList()
        val state = tracked.state
        tracked.state = state.copy(
            tokens = if (tokens > 0) state.tokens + tokens else state.tokens,
            costUsd = if (costUsd.isFinite() && costUsd > 0) state.costUsd + costUsd else state.costUsd,
        )
        return observeActivity(kind, id, at)
    }

    /**
     * Emits one mobile flag from evidence the host has already read. The unit
     * need not be tracked; identity is exactly what the caller supplies
     * (`watchdog.md` §3, CCR-2). Empty thermal/battery evidence is treated as
     * unavailable and emits nothing.
     */
    @Synchronized
    public fun observeMobile(
        event: BotMobileWatchdogEvent,
        kind: BotWatchdogUnitKind,
        id: String,
        botId: String? = null,
        sessionId: String? = null,
        evidence: Map<String, JsonValue> = emptyMap(),
        at: Long? = null,
    ): List<BotWatchdogFlag> {
        val finding = BotWatchdogChecks.mobileFinding(event, evidence) ?: return emptyList()
        val flag = emit(
            unitKind = kind,
            unitId = id,
            botId = botId,
            sessionId = sessionId,
            finding = finding,
            at = at ?: clock(),
        )
        return flag?.let { listOf(it) } ?: emptyList()
    }

    /** Convenience overload for a portable [BotMobileWatchdogSignal]. */
    @Synchronized
    public fun observeMobile(
        signal: BotMobileWatchdogSignal?,
        kind: BotWatchdogUnitKind,
        id: String,
        botId: String? = null,
        sessionId: String? = null,
        at: Long? = null,
    ): List<BotWatchdogFlag> {
        signal ?: return emptyList()
        return observeMobile(signal.event, kind, id, botId, sessionId, signal.evidence, at)
    }

    /**
     * Reads one host signal through [port]. `null` means unavailable, so no
     * durable event is written and no placeholder reading is invented.
     */
    @Synchronized
    public fun observeMobile(
        port: BotMobileWatchdogSignalPort,
        event: BotMobileWatchdogEvent,
        kind: BotWatchdogUnitKind,
        id: String,
        botId: String? = null,
        sessionId: String? = null,
        at: Long? = null,
    ): List<BotWatchdogFlag> {
        val signal = port.read(event) ?: return emptyList()
        if (signal.event != event) return emptyList()
        return observeMobile(signal, kind, id, botId, sessionId, at)
    }

    @Synchronized
    public fun tick(at: Long? = null): List<BotWatchdogFlag> {
        val now = at ?: clock()
        val flags = ArrayList<BotWatchdogFlag>()
        val keys = units.keys.sortedWith(compareBy({ it.kind.wireValue }, { it.id }))
        for (key in keys) flags += evaluate(key, now)
        return flags
    }

    @Synchronized
    public fun hasFlagged(kind: BotWatchdogUnitKind, id: String, check: BotWatchdogCheck): Boolean =
        SeenKey(UnitKey(kind, id), check) in seen

    @Synchronized
    public fun flags(limit: Int = 50): List<BotWatchdogFlag> {
        val configured = config.historyLimit.coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
        val take = maxOf(0, minOf(limit, configured))
        return recentFlags.take(take)
    }

    private fun evaluate(key: UnitKey, now: Long): List<BotWatchdogFlag> {
        val tracked = units[key] ?: return emptyList()
        val findings = BotWatchdogChecks.run(tracked.state, now, config)
        val flags = ArrayList<BotWatchdogFlag>(findings.size)
        for (finding in findings) {
            emit(
                unitKind = key.kind,
                unitId = key.id,
                botId = tracked.state.botId,
                sessionId = tracked.state.sessionId,
                finding = finding,
                at = now,
            )?.let(flags::add)
        }
        return flags
    }

    private fun emit(
        unitKind: BotWatchdogUnitKind,
        unitId: String,
        botId: String?,
        sessionId: String?,
        finding: BotWatchdogFinding,
        at: Long,
    ): BotWatchdogFlag? {
        val trimmedId = unitId.trim()
        if (trimmedId.isEmpty()) return null
        val seenKey = SeenKey(UnitKey(unitKind, trimmedId), finding.check)
        if (seenKey in seen || seenKey in pending) return null
        pending += seenKey
        try {
            val eventId = eventId(unitKind, trimmedId, finding.check)
            if (eventLog.event(eventId) != null) {
                seen += seenKey
                return null
            }
            val event = BotEvent(
                schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
                type = "watchdog.flagged",
                eventId = eventId,
                commitSeq = null,
                time = at,
                origin = BotEventOrigin.Local("watchdog"),
                traceId = "trace:watchdog:$eventId",
                principal = BotPrincipal(
                    botId = botId,
                    sessionId = sessionId,
                    kind = "watchdog",
                    capabilities = emptyList(),
                ),
                causationId = null,
                correlationId = trimmedId,
                data = JsonObject(
                    linkedMapOf(
                        "unitKind" to com.phonedsh.agentcore.JsonString(unitKind.wireValue),
                        "unitId" to com.phonedsh.agentcore.JsonString(trimmedId),
                        "botId" to nullableString(botId),
                        "sessionId" to nullableString(sessionId),
                        "check" to com.phonedsh.agentcore.JsonString(finding.check.wireValue),
                        "at" to number(at),
                        "evidence" to JsonObject(LinkedHashMap(finding.evidence)),
                    ),
                ),
            )
            val commitSeq = eventLog.append(event)
            seen += seenKey
            val flag = BotWatchdogFlag(
                unitKind = unitKind,
                unitId = trimmedId,
                botId = botId,
                sessionId = sessionId,
                check = finding.check,
                evidence = finding.evidence,
                at = at,
                eventId = eventId,
                commitSeq = commitSeq,
            )
            recentFlags.add(0, flag)
            val cap = maxOf(1L, config.historyLimit)
            while (recentFlags.size.toLong() > cap && recentFlags.isNotEmpty()) {
                recentFlags.removeAt(recentFlags.lastIndex)
            }
            return flag
        } catch (error: Throwable) {
            log(
                "watchdog flag publish failed " +
                    "(${unitKind.wireValue}/$trimmedId/${finding.check.wireValue}): ${error.message}",
            )
            return null
        } finally {
            pending -= seenKey
        }
    }

    private fun evictIfNeeded() {
        val cap = maxOf(1L, config.maxUnits)
        while (units.size.toLong() >= cap) {
            val oldest = units.entries.minWithOrNull(
                compareBy(
                    { it.value.state.lastEventAt ?: it.value.state.startedAt },
                    { it.key.kind.wireValue },
                    { it.key.id },
                ),
            ) ?: return
            units.remove(oldest.key)
        }
    }

    private companion object {
        fun sha256(text: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            val out = StringBuilder(digest.size * 2)
            for (byte in digest) out.append("%02x".format(byte))
            return "sha256:$out"
        }

        fun eventId(
            kind: BotWatchdogUnitKind,
            id: String,
            check: BotWatchdogCheck,
        ): String {
            val raw = "watchdog.flagged:${kind.wireValue}:$id:${check.wireValue}"
            if (raw.length <= 400) return raw
            val digest = sha256(raw).removePrefix("sha256:").take(32)
            return "watchdog.flagged:${kind.wireValue}:$digest:${check.wireValue}"
        }
    }
}

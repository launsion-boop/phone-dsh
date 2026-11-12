// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToLong

/** The four optional volatile blocks (`BotVolatileBlocks`). */
public data class BotVolatileBlocks(
    public val variant: String? = null,
    public val persona: String? = null,
    public val memory: String? = null,
    public val automation: String? = null,
) {
    public companion object {
        public val EMPTY: BotVolatileBlocks = BotVolatileBlocks()
    }
}

/** `{"schemaVersion":1,"sessionId","revision","blocks"}` (§8.1). */
public data class BotVolatileSnapshot(
    public val sessionId: String,
    public val revision: Int,
    public val blocks: BotVolatileBlocks,
) {
    public fun toJson(): JsonObject {
        val fields = LinkedHashMap<String, JsonValue>()
        blocks.variant?.takeIf { it.isNotEmpty() }?.let { fields["variant"] = JsonString(it) }
        blocks.persona?.takeIf { it.isNotEmpty() }?.let { fields["persona"] = JsonString(it) }
        blocks.memory?.takeIf { it.isNotEmpty() }?.let { fields["memory"] = JsonString(it) }
        blocks.automation?.takeIf { it.isNotEmpty() }?.let { fields["automation"] = JsonString(it) }
        return BotJson.objectOf(
            "schemaVersion" to JsonNumber("1"),
            "sessionId" to JsonString(sessionId),
            "revision" to JsonNumber(revision.toString()),
            "blocks" to JsonObject(fields),
        )
    }
}

/** The domain provider seam. The App supplies the assembled blocks. */
public fun interface BotVolatileContextProviding {
    public suspend fun snapshot(
        botId: String,
        sessionId: String,
        kind: BotMCPPrincipalKind,
    ): BotVolatileBlocks
}

public object EmptyBotVolatileContextProvider : BotVolatileContextProviding {
    override suspend fun snapshot(
        botId: String,
        sessionId: String,
        kind: BotMCPPrincipalKind,
    ): BotVolatileBlocks = BotVolatileBlocks.EMPTY
}

/**
 * The producer of §8: exact-one-member request validation, cross-session
 * denial, revision accounting, a 5 s default timeout, scalar caps and the
 * credential-shaped-content rejection. A failed provider call is a tool
 * failure and never a stale snapshot (PC ruling 6).
 */
public class BotVolatileContextProducer(
    private val provider: BotVolatileContextProviding,
    timeoutSeconds: Double = DEFAULT_TIMEOUT_SECONDS,
) {
    public companion object {
        public const val DEFAULT_TIMEOUT_SECONDS: Double = 5.0
        public const val VARIANT_LIMIT: Int = 12_000
        public const val PERSONA_LIMIT: Int = 12_000
        public const val MEMORY_LIMIT: Int = 4_000
        public const val AUTOMATION_LIMIT: Int = 4_000
        public const val TOTAL_LIMIT: Int = 24_000

        private val SECRET_PATTERNS: List<Regex> = listOf(
            Regex("(?i)bearer\\s+[A-Za-z0-9._~+/=-]{8,}"),
            Regex("\\bsk-[A-Za-z0-9][A-Za-z0-9_-]{14,}\\b"),
            Regex("-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"),
            Regex("(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password)\\s*[:=]\\s*[^\\s]{4,}"),
            Regex("\\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\\b"),
        )
    }

    private val timeoutMillis: Long =
        maxOf(1L, (timeoutSeconds * 1_000.0).roundToLong())
    private val revision = AtomicInteger(0)

    /** The last attempted revision; a failed attempt still consumed one. */
    public val currentRevision: Int get() = revision.get()

    public suspend fun snapshot(
        request: JsonValue,
        principal: BotMCPPrincipal,
    ): BotVolatileSnapshot {
        val members = (request as? JsonObject)?.members
        val validObject = members != null && members.keys == setOf("sessionId")
        val sessionId = (members?.get("sessionId") as? JsonString)?.value
        if (!validObject || sessionId.isNullOrEmpty() || BotMCPScalars.length(sessionId) > 200) {
            throw BotMCPToolException(
                "invalid_arguments",
                "BotVolatileContext requires only sessionId (1–200 characters)",
            )
        }
        if (sessionId != principal.sessionId) {
            throw BotMCPToolException("cross_session_read_denied", "请求的会话不属于当前调用方")
        }
        // Every attempt, including a failed one, consumes a revision.
        val current = revision.incrementAndGet()
        val blocks = try {
            withTimeout(timeoutMillis) {
                provider.snapshot(principal.botId, sessionId, principal.kind)
            }
        } catch (_: TimeoutCancellationException) {
            throw BotMCPToolException("timeout", "操作超时了")
        }
        validate(blocks)
        return BotVolatileSnapshot(sessionId, current, blocks)
    }

    private fun validate(blocks: BotVolatileBlocks) {
        var total = 0
        val values = listOf(
            blocks.variant to VARIANT_LIMIT,
            blocks.persona to PERSONA_LIMIT,
            blocks.memory to MEMORY_LIMIT,
            blocks.automation to AUTOMATION_LIMIT,
        )
        for ((text, limit) in values) {
            if (text == null) continue
            val count = BotMCPScalars.length(text)
            if (count > limit) {
                throw BotMCPToolException("unavailable", "volatile context block exceeds its size limit")
            }
            total += count
            if (containsSecret(text)) {
                throw BotMCPToolException("unavailable", "volatile context contains credential-shaped data")
            }
        }
        if (total > TOTAL_LIMIT) {
            throw BotMCPToolException("unavailable", "volatile context exceeds its total size limit")
        }
    }

    private fun containsSecret(text: String): Boolean = SECRET_PATTERNS.any { it.containsMatchIn(text) }
}

/** One other Bot the caller may message. */
public data class BotTeammateSummary(
    public val id: String,
    public val name: String,
    public val description: String = "",
    public val isMain: Boolean = false,
)

/**
 * The App provider of §8.3. It assembles variant, persona, memory, automation
 * and the `<teammates>` sub-block; the routine status text and memory prompt
 * block come from the B2/B3 adapters through [BotMemoryLookup] and
 * [BotRoutineLookup].
 */
public class BotDomainVolatileContextProvider(
    private val memory: BotMemoryLookup,
    private val routines: BotRoutineLookup,
    private val persona: ((botId: String, sessionId: String, kind: BotMCPPrincipalKind) -> String)? = null,
    private val variant: ((sessionId: String, kind: BotMCPPrincipalKind) -> String)? = null,
    private val teammates: (suspend (botId: String) -> List<BotTeammateSummary>)? = null,
    private val botDescription: (suspend (botId: String) -> String?)? = null,
    private val now: () -> Long = { System.currentTimeMillis() },
    private val language: String = "zh",
) : BotVolatileContextProviding {
    public companion object {
        public const val DEFAULT_PERSONA: String = "你的名字是大肥鱼。用户问起名字时如实回答。"
        public const val BOT_DESCRIPTION_LIMIT: Int = 300
        public const val TEAMMATES_LIMIT: Int = 999
        public const val TEAMMATE_DESCRIPTION_LIMIT: Int = 200
        public const val AUTOMATION_WITH_TEAMMATES_LIMIT: Int = 3_900

        public fun variantFor(kind: BotMCPPrincipalKind, language: String): String {
            val en = language == "en"
            return when (kind) {
                BotMCPPrincipalKind.TASK -> if (en) {
                    "# 2. Task variant\n\nComplete the delegated task autonomously. Return one concise, " +
                        "self-contained final result to the parent. You cannot message the user directly; do not " +
                        "ask follow-up questions. Approval denial is final; report it instead of working around it."
                } else {
                    "# 2. 子代理变体\n\n自主完成被委派的任务，用一条简洁、自包含的最终结果回复父对话。" +
                        "你不能直接向用户发消息，不要追问。审批被拒绝是终局，不要绕过；如实报告。"
                }
                BotMCPPrincipalKind.ROUTINE -> if (en) {
                    "# 2. Routine variant\n\nYou are running a routine as a hidden turn with the same tools as a " +
                        "normal turn. Carry out the saved instruction autonomously. Do not surface cards (ask_user, " +
                        "show_next_steps, show_*), do not ask questions in the reply, and do not call SendToUser or " +
                        "SendToAgent; the only card this run may raise is RequestApproval. Stay quiet by default: " +
                        "no acknowledgement or progress narration. Your final assistant text is the routine result " +
                        "shown on the routine card; when the saved instruction requires silence and nothing " +
                        "changed, write exactly [quiet]."
                } else {
                    "# 2. 例行任务变体\n\n你正以隐藏回合运行一次例行任务，具备和正常回合相同的工具能力。" +
                        "自主完成已保存的指令。不要出卡片（ask_user、show_next_steps、show_*），不要在回复里问问题，" +
                        "也不要调用 SendToUser 或 SendToAgent；唯一可能出现的卡片是 RequestApproval。" +
                        "默认保持安静：不确认收到，不播报进度。最后一条助手文本就是本次结果，会显示在例行任务卡片上；" +
                        "保存的指令要求安静且没有新结果时，最终只写 [quiet]。"
                }
                else -> ""
            }
        }

        public fun personaBlock(persona: String, description: String?): String {
            val trimmed = persona.trim()
            if (description == null) return trimmed
            val detail = BotMCPScalars.prefix(description.trim(), BOT_DESCRIPTION_LIMIT)
            if (detail.isEmpty()) return trimmed
            return if (trimmed.isEmpty()) detail else "$trimmed\n\n$detail"
        }

        public fun sanitizedField(value: String, limit: Int): String {
            val escaped = value
                .replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace(Regex("\\s+"), " ")
                .trim()
            return BotMCPScalars.prefix(escaped, limit)
        }

        public fun teammatesBlock(
            teammates: List<BotTeammateSummary>,
            callerId: String,
            language: String,
            available: Int = TEAMMATES_LIMIT,
        ): String {
            val limit = minOf(TEAMMATES_LIMIT, available)
            if (limit <= 0) return ""
            val zh = language != "en"
            val lines = teammates
                .filter { it.id.isNotEmpty() && it.id != callerId }
                .map { teammate ->
                    val name = sanitizedField(teammate.name, 60)
                    val description =
                        sanitizedField(teammate.description, TEAMMATE_DESCRIPTION_LIMIT)
                    val id = sanitizedField(teammate.id, 120)
                    val main = if (teammate.isMain) (if (zh) "，主 Bot" else ", main Bot") else ""
                    val detail = if (description.isEmpty()) "" else (if (zh) "：$description" else ": $description")
                    if (zh) {
                        "- $name（id: $id$main）$detail"
                    } else {
                        "- $name (id: $id$main)$detail"
                    }
                }
            if (lines.isEmpty()) return ""
            val start = "<teammates>\n"
            val end = "</teammates>"
            val builder = StringBuilder(start)
            var used = BotMCPScalars.length(start) + BotMCPScalars.length(end)
            var included = 0
            for (line in lines) {
                val cost = BotMCPScalars.length(line) + 1
                if (used + cost > limit) break
                builder.append(line).append('\n')
                used += cost
                included += 1
            }
            if (included == 0) return ""
            builder.append(end)
            return builder.toString()
        }

        public fun appendTeammates(block: String, automation: String): String =
            if (block.isEmpty()) automation else if (automation.isEmpty()) block else "$automation\n\n$block"

        public fun unreadable(error: Throwable, language: String): String {
            val zh = language != "en"
            val reason = BotMCPScalars.prefix(
                (error.message ?: error.javaClass.simpleName).replace(Regex("\\s+"), " ").trim(),
                200,
            )
            return listOf(
                "<automation_status>",
                if (zh) {
                    "下面列出你的例行任务。这条提醒是权威来源：没有列出时，你没有任何例行任务。"
                } else {
                    "Your routines are listed below. This reminder is authoritative: with none listed, you have none."
                },
                if (zh) {
                    "例行任务状态暂时无法读取（$reason）；这不代表没有例行任务。"
                } else {
                    "Routine status is temporarily unavailable ($reason); this does not mean you have no routines."
                },
                "</automation_status>",
            ).joinToString("\n")
        }
    }

    override suspend fun snapshot(
        botId: String,
        sessionId: String,
        kind: BotMCPPrincipalKind,
    ): BotVolatileBlocks {
        val variantText = (variant?.invoke(sessionId, kind) ?: variantFor(kind, language)).trim()
        val basePersona = persona?.invoke(botId, sessionId, kind) ?: DEFAULT_PERSONA
        val description = botDescription?.invoke(botId)
        val personaText = personaBlock(basePersona, description)
        val memoryText = memory.promptBlock(botId, language).trim()
        val automationStatus = try {
            routines.automationStatus(botId, now(), language)
        } catch (error: Throwable) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            unreadable(error, language)
        }
        val teammateValues = teammates?.invoke(botId) ?: emptyList()
        val teammateBlock = teammatesBlock(
            teammateValues,
            callerId = botId,
            language = language,
            available = maxOf(
                0,
                AUTOMATION_WITH_TEAMMATES_LIMIT - BotMCPScalars.length(automationStatus),
            ),
        )
        val automation = appendTeammates(teammateBlock, automationStatus)
        return BotVolatileBlocks(
            variant = variantText.ifEmpty { null },
            persona = personaText.ifEmpty { null },
            memory = memoryText.ifEmpty { null },
            automation = automation.ifEmpty { null },
        )
    }
}

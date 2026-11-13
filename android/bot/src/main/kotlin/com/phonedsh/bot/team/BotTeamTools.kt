// SPDX-License-Identifier: MIT
package com.phonedsh.bot.team

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.mcp.BotMCPCallResult
import com.phonedsh.bot.mcp.BotMCPPrincipal
import com.phonedsh.bot.mcp.BotTeamToolHandler
import com.phonedsh.bot.mcp.BotToolCallContext
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRoster
import com.phonedsh.bot.rows.BotAgentCommDirection
import com.phonedsh.bot.rows.BotAgentCommHeld
import com.phonedsh.bot.rows.BotAgentCommIdentity
import com.phonedsh.bot.rows.BotAgentCommSequence
import com.phonedsh.bot.rows.BotAgentCommText
import com.phonedsh.bot.rows.BotAgentRef
import com.phonedsh.bot.rows.BotTeamAgentCommRecord
import com.phonedsh.bot.wake.BotTurnAuthority
import com.phonedsh.bot.wake.BotTurnOrigin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The two team tools exposed through the Bot MCP surface.
 *
 * The implementation only depends on [BotTeamHost]; the App composition
 * supplies the roster, per-Bot turn delivery, held inbox and row persistence.
 * All sentences below are frozen by `spec/bot/v1/team.md` §2–§3; the shared
 * `team-cases.phone.json` vector is the comparison form.
 */
public class BotTeamTools(
    public val host: BotTeamHost,
    timeoutMilliseconds: Int = DEFAULT_TIMEOUT_MILLISECONDS,
    private val now: () -> Long = { System.currentTimeMillis() },
) : BotTeamToolHandler {
    public val timeoutMilliseconds: Int = maxOf(1, timeoutMilliseconds)
    private val sequence: BotAgentCommSequence = BotAgentCommSequence(now)

    override fun handles(name: String): Boolean =
        name == SEND_TO_AGENT_NAME || name == CREATE_TEAMMATE_NAME

    /** MCP-runtime path without turn authority (direct tool calls). */
    override suspend fun execute(
        name: String,
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult = executeWithAuthority(
        name = name,
        arguments = arguments,
        principal = context.principal,
        context = context,
        authority = null,
    )

    /**
     * Runtime path: `CreateTeammate` sees the frozen turn authority so a
     * non-user creation can require and record the approval.
     */
    public suspend fun executeWithAuthority(
        name: String,
        arguments: JsonValue,
        principal: BotMCPPrincipal,
        context: BotToolCallContext,
        authority: BotTurnAuthority?,
    ): BotMCPCallResult = when (name) {
        SEND_TO_AGENT_NAME -> sendToAgent(arguments, principal, context)
        CREATE_TEAMMATE_NAME -> createTeammate(arguments, principal, authority)
        else -> BotMCPCallResult.failure("unknown_tool", "未知工具：$name")
    }

    // ------------------------------------------------------------------
    // SendToAgent
    // ------------------------------------------------------------------

    private suspend fun sendToAgent(
        arguments: JsonValue,
        principal: BotMCPPrincipal,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        val args = (arguments as? JsonObject)?.members
            ?: return BotMCPCallResult.failure(
                "invalid_arguments",
                "SendToAgent 的参数必须是一个对象",
            )
        val delivery = when (val resolved = resolveDelivery(args)) {
            is DeliveryResolution.Ok -> resolved.delivery
            is DeliveryResolution.Err ->
                return BotMCPCallResult.failure("invalid_arguments", resolved.message)
        }
        val targetReference = firstTrimmedString(
            args,
            listOf("agent_id", "target_id", "bot_name", "agentId"),
        ) ?: return BotMCPCallResult.failure(
            "invalid_arguments",
            "SendToAgent 需要提供队友。",
        )
        val message = firstTrimmedString(args, listOf("message", "text"))
            ?: return BotMCPCallResult.failure(
                "invalid_arguments",
                "SendToAgent 需要提供非空的消息。",
            )

        val roster = try {
            host.roster()
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            return BotMCPCallResult.failure("execution_failed", describe(error))
        }
        val senderProfile = roster.bots.firstOrNull { it.id == principal.botId }
        val sender = BotAgentRef(
            id = principal.botId,
            name = senderProfile?.name ?: principal.botId,
            kind = "agent",
        )
        val targetProfile = resolve(targetReference, roster)
            ?: return BotMCPCallResult.failure(
                "invalid_arguments",
                "没有找到队友「$targetReference」。可选的 Bot：" +
                    "${availableList(roster, principal.botId)}。",
            )
        val target = BotAgentRef(
            id = targetProfile.id,
            name = targetProfile.name,
            kind = "agent",
        )
        if (target.id == principal.botId) {
            return BotMCPCallResult.failure(
                "invalid_arguments",
                "SendToAgent 不能发给自己；请直接回答当前请求。",
            )
        }

        val commContext = host.agentCommContext(principal.botId)
        val depth = commContext.depth + 1
        if (depth > MAXIMUM_HOPS) {
            return BotMCPCallResult.failure(
                "invalid_arguments",
                "转交层数已经达到上限（最多 $MAXIMUM_HOPS 层）。" +
                    "不要再转给别人了，请直接回答当前请求。",
            )
        }
        if (commContext.chain.contains(target.id)) {
            val names = commContext.chain.map { id ->
                roster.bots.firstOrNull { it.id == id }?.name ?: "对方"
            }
            val path = (names + target.name).joinToString(" → ")
            return BotMCPCallResult.failure(
                "invalid_arguments",
                "转交链已经走过 $path，${target.name} 在这条链上，不能再转回去。" +
                    "请直接回答当前请求。",
            )
        }

        val callID = context.callId
        val requestID = BotTurnOrigin.agentRequestId(callID)
        // Compatibility: pre-WP4 rows stored the bare call id as requestId.
        var existingThread = host.existingAgentCommThread(principal.botId, requestID)
        if (existingThread == null) {
            existingThread = host.existingAgentCommThread(principal.botId, callID)
        }
        existingThread?.let { threadID ->
            return sendToAgentSuccess(
                target = target,
                threadID = threadID,
                requestID = requestID,
                delivery = delivery,
                duplicated = true,
                heldID = null,
            )
        }

        val title = firstTrimmedString(args, listOf("title"))
        val seq = sequence.next()
        val rowID = BotAgentCommIdentity.outboundRowID(
            senderAgentID = sender.id,
            targetID = target.id,
            requestID = requestID,
            seq = seq,
        )
        val threadID = BotAgentCommIdentity.threadID(rowID, seq)
        val nextChain = LinkedHashSet(commContext.chain).apply {
            add(sender.id)
            add(target.id)
        }.toList()

        val outbound = BotTeamAgentCommRecord(
            rowID = rowID,
            botID = sender.id,
            direction = BotAgentCommDirection.OUTBOUND,
            role = "assistant",
            text = message,
            threadID = threadID,
            requestID = requestID,
            toAgent = target,
            delivery = delivery,
            status = if (delivery == "queued") "held" else null,
            title = title,
            hop = depth,
            callID = context.callId,
        )
        try {
            host.recordAgentComm(outbound)
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            return BotMCPCallResult.failure("execution_failed", describe(error))
        }

        if (delivery == "queued") {
            val item = try {
                BotAgentCommHeld.queuedItem(
                    id = BotAgentCommHeld.heldID(now()),
                    fromAgent = sender,
                    title = title,
                    message = message,
                    requestId = requestID,
                    threadId = threadID,
                    createdAt = now(),
                )
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                return BotMCPCallResult.failure("execution_failed", describe(error))
            }
            val enqueued = try {
                host.enqueueHeld(
                    BotTeamHeldRequest(
                        botID = target.id,
                        item = item,
                        handOff = BotAgentCommContext(depth = depth, chain = nextChain),
                    ),
                )
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                return BotMCPCallResult.failure(
                    "execution_failed",
                    "held inbox write failed: ${describe(error)}",
                )
            }
            return sendToAgentSuccess(
                target = target,
                threadID = threadID,
                requestID = requestID,
                delivery = delivery,
                duplicated = enqueued.duplicate,
                heldID = enqueued.item.id,
            )
        }

        val titleSuffix = title?.let { " — $it" } ?: ""
        val promptText = "[agent] ${sender.name} (id: ${sender.id})$titleSuffix: $message"
        val request = BotAgentDeliveryRequest(
            sender = sender,
            target = target,
            promptText = promptText,
            message = message,
            title = title,
            threadId = threadID,
            requestId = requestID,
            delivery = "now",
            hop = depth,
            chain = nextChain,
        )
        when (val outcome = deliver(request)) {
            is DeliveryOutcome.Success -> {
                val inboundRowID = BotAgentCommIdentity.turnRowID(
                    turn = commContext.turn,
                    existingIDs = commContext.existingRowIDs,
                )
                val inbound = BotTeamAgentCommRecord(
                    rowID = inboundRowID,
                    botID = sender.id,
                    direction = BotAgentCommDirection.INBOUND,
                    role = "user",
                    text = outcome.reply.text,
                    threadID = threadID,
                    requestID = requestID,
                    fromAgent = BotAgentRef(id = target.id, name = target.name),
                    turn = commContext.turn,
                    replyEntryID = outcome.reply.replyEntryId,
                )
                try {
                    host.recordAgentComm(inbound)
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    return BotMCPCallResult.failure("execution_failed", describe(error))
                }

                val replyItem = try {
                    BotAgentCommHeld.replyItem(
                        id = BotAgentCommHeld.heldID(now()),
                        fromAgent = target,
                        originalTitle = title,
                        replyText = outcome.reply.text,
                        requestId = requestID,
                        threadId = threadID,
                        createdAt = now(),
                    )
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    return BotMCPCallResult.failure("execution_failed", describe(error))
                }
                try {
                    // A reply is the end of this hand-off, not a new hop. It
                    // must not install a chain or the sender's next send to
                    // this teammate would be rejected as a cycle.
                    host.enqueueHeld(BotTeamHeldRequest(botID = sender.id, item = replyItem))
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    return BotMCPCallResult.failure(
                        "execution_failed",
                        "reply was received but the held inbox write failed: ${describe(error)}",
                    )
                }
                return sendToAgentSuccess(
                    target = target,
                    threadID = threadID,
                    requestID = requestID,
                    delivery = delivery,
                    duplicated = false,
                    heldID = null,
                )
            }

            is DeliveryOutcome.Failure -> {
                val failure = outcome.message
                val inbound = BotTeamAgentCommRecord(
                    rowID = BotAgentCommIdentity.turnRowID(
                        turn = commContext.turn,
                        existingIDs = commContext.existingRowIDs,
                    ),
                    botID = sender.id,
                    direction = BotAgentCommDirection.INBOUND,
                    role = "user",
                    text = "",
                    threadID = threadID,
                    requestID = requestID,
                    fromAgent = BotAgentRef(id = target.id, name = target.name),
                    turn = commContext.turn,
                    error = failure,
                )
                try {
                    host.recordAgentComm(inbound)
                } catch (_: Throwable) {
                    // The delivery failure is the answer; the row is best effort.
                }
                if (outcome.timeout) {
                    return BotMCPCallResult.failure(
                        "timeout",
                        BotTeamHostError.DeliveryTimeout.message ?: "",
                    )
                }
                return BotMCPCallResult.failure("execution_failed", "发送失败：$failure")
            }
        }
    }

    private fun sendToAgentSuccess(
        target: BotAgentRef,
        threadID: String,
        requestID: String,
        delivery: String,
        duplicated: Boolean,
        heldID: String?,
    ): BotMCPCallResult {
        val members = LinkedHashMap<String, JsonValue>()
        members["ok"] = JsonBool(true)
        members["threadId"] = JsonString(threadID)
        members["requestId"] = JsonString(requestID)
        members["target"] = BotJson.objectOf(
            "id" to JsonString(target.id),
            "name" to JsonString(target.name),
        )
        members["delivery"] = JsonString(delivery)
        heldID?.let { members["heldId"] = JsonString(it) }
        if (duplicated) members["duplicated"] = JsonBool(true)
        if (delivery == "queued") members["status"] = JsonString("held")
        val text = if (delivery == "queued") {
            "已扣住给 ${target.name}：消息会在对方下一个回合开头交付，不会唤醒对方。"
        } else {
            "已发送给 ${target.name}，回复稍后以 agent-comm 消息送达。"
        }
        return BotMCPCallResult.success(JsonObject(members), text = text)
    }

    // ------------------------------------------------------------------
    // CreateTeammate
    // ------------------------------------------------------------------

    private suspend fun createTeammate(
        arguments: JsonValue,
        principal: BotMCPPrincipal,
        authority: BotTurnAuthority?,
    ): BotMCPCallResult {
        val args = (arguments as? JsonObject)?.members
            ?: return BotMCPCallResult.failure(
                "invalid_arguments",
                "CreateTeammate 的参数必须是一个对象",
            )
        val rawName = BotJson.string(args["name"])
            ?: return BotMCPCallResult.failure(
                "invalid_arguments",
                "CreateTeammate 需要提供名字。",
            )
        val name = rawName.trim()
        if (name.isEmpty()) {
            return BotMCPCallResult.failure(
                "invalid_arguments",
                "CreateTeammate 需要提供名字。",
            )
        }
        if (name.length > 60) {
            return BotMCPCallResult.failure(
                "invalid_arguments",
                "CreateTeammate 的名字太长了（${name.length} 个字符，最多 60 个）。",
            )
        }
        val description = BotJson.string(args["description"])
            ?.let { BotAgentCommText.truncateUtf16(it, 300) }
            ?: ""

        val color = when (val resolved = optionalEnum(
            args["color"],
            BotFishColor.entries.map { it.wire },
            "color",
        )) {
            is EnumResolution.Ok -> resolved.value?.let(BotFishColor::fromWire)
            is EnumResolution.Err ->
                return BotMCPCallResult.failure("invalid_arguments", resolved.message)
        }
        val hairstyle = when (val resolved = optionalEnum(
            args["hairstyle"],
            BotFishHairstyle.entries.map { it.wire },
            "hairstyle",
        )) {
            is EnumResolution.Ok -> resolved.value?.let(BotFishHairstyle::fromWire)
            is EnumResolution.Err ->
                return BotMCPCallResult.failure("invalid_arguments", resolved.message)
        }

        val roster = try {
            host.roster()
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            return BotMCPCallResult.failure("execution_failed", describe(error))
        }
        val senderName = roster.bots.firstOrNull { it.id == principal.botId }?.name
            ?: principal.botId
        if (roster.mainBotID != principal.botId) {
            return BotMCPCallResult.failure(
                "permission_denied",
                "CreateTeammate 只能由主 Bot 调用；当前 Bot $senderName" +
                    "（id: ${principal.botId}）不是主 Bot。",
            )
        }
        var author: BotTeammateAuthor? = null
        if (authority != null) {
            author = BotTeammateAuthor.fromAuthority(authority)
                ?: return BotMCPCallResult.failure(
                    "permission_denied",
                    "创建队友需要你在当前回合确认",
                )
        }

        val created = try {
            host.createBot(
                name = name,
                description = description,
                color = color,
                hairstyle = hairstyle,
                author = author,
            )
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            return BotMCPCallResult.failure(
                "execution_failed",
                "创建队友失败：${describe(error)}",
            )
        }

        val text = StringBuilder()
        text.append("已创建队友「${created.name}」（agent_id: ${created.id}）")
        if (description.isNotEmpty()) text.append(" — $description")
        when {
            color != null && hairstyle != null ->
                text.append("；外观：颜色=${color.wire}、发型=${hairstyle.wire}")
            color != null -> text.append("；外观：颜色=${color.wire}")
            hairstyle != null -> text.append("；外观：发型=${hairstyle.wire}")
            else -> text.append("；外观：按 Bot ID 自动组合")
        }
        text.append("。")
        return BotMCPCallResult.success(
            BotJson.objectOf(
                "ok" to JsonBool(true),
                "agent_id" to JsonString(created.id),
                "name" to JsonString(created.name),
            ),
            text = text.toString(),
        )
    }

    // ------------------------------------------------------------------
    // Delivery
    // ------------------------------------------------------------------

    private sealed interface DeliveryOutcome {
        data class Success(val reply: BotAgentDeliveryReply) : DeliveryOutcome

        data class Failure(val message: String, val timeout: Boolean) : DeliveryOutcome
    }

    private suspend fun deliver(request: BotAgentDeliveryRequest): DeliveryOutcome {
        return try {
            val reply = withTimeoutOrNull(timeoutMilliseconds.toLong()) {
                host.deliverToAgent(request)
            }
            if (reply == null) {
                DeliveryOutcome.Failure(
                    BotTeamHostError.DeliveryTimeout.message ?: "",
                    timeout = true,
                )
            } else {
                DeliveryOutcome.Success(reply)
            }
        } catch (error: TimeoutCancellationException) {
            DeliveryOutcome.Failure(
                BotTeamHostError.DeliveryTimeout.message ?: "",
                timeout = true,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            DeliveryOutcome.Failure(
                message = describe(error),
                timeout = error is BotTeamHostError.DeliveryTimeout,
            )
        }
    }

    private fun describe(error: Throwable): String =
        if (error is BotTeamHostError) error.message ?: error.toString() else error.toString()

    // ------------------------------------------------------------------
    // Argument parsing
    // ------------------------------------------------------------------

    private sealed interface DeliveryResolution {
        data class Ok(val delivery: String) : DeliveryResolution

        data class Err(val message: String) : DeliveryResolution
    }

    private fun resolveDelivery(args: Map<String, JsonValue>): DeliveryResolution {
        val priorityValue = args["priority"]
        val deliveryValue = args["delivery"]
        val hasPriority = priorityValue?.let { !isEmpty(it) } ?: false
        val hasDelivery = deliveryValue?.let { !isEmpty(it) } ?: false

        var priority: Boolean? = null
        if (hasPriority) {
            priority = when (val value = priorityValue) {
                is JsonBool -> value.value
                is JsonString -> when (value.value) {
                    "true" -> true
                    "false" -> false
                    else -> null
                }
                else -> null
            }
            if (priority == null) {
                return DeliveryResolution.Err(
                    "priority must be a boolean (true = wake now, false = hold for their next turn)",
                )
            }
        }

        var delivery: String? = null
        if (hasDelivery) {
            val value = (deliveryValue as? JsonString)?.value
            if (value != "now" && value != "queued") {
                return DeliveryResolution.Err("delivery must be \"now\" or \"queued\"")
            }
            delivery = value
        }

        if (!hasPriority && !hasDelivery) {
            return DeliveryResolution.Err(
                "SendToAgent 需要 priority：true 表示立即唤醒，false 表示等对方下一个回合。",
            )
        }
        if (priority != null) {
            val implied = if (priority) "now" else "queued"
            if (delivery != null && delivery != implied) {
                return DeliveryResolution.Err(
                    "priority ${jsonLiteral(priorityValue)} implies delivery \"$implied\" " +
                        "but delivery \"$delivery\" was also given",
                )
            }
            return DeliveryResolution.Ok(implied)
        }
        return DeliveryResolution.Ok(delivery ?: "now")
    }

    private fun isEmpty(value: JsonValue): Boolean = when (value) {
        is JsonNull -> true
        is JsonArray -> value.values.isEmpty()
        is JsonObject -> value.members.isEmpty()
        is JsonString -> value.value.isEmpty()
        else -> false
    }

    private fun jsonLiteral(value: JsonValue?): String = when (value) {
        null -> "undefined"
        is JsonBool -> if (value.value) "true" else "false"
        is JsonString -> "\"${value.value}\""
        else -> BotJson.canonical(value)
    }

    private fun firstTrimmedString(
        args: Map<String, JsonValue>,
        keys: List<String>,
    ): String? {
        for (key in keys) {
            val text = BotJson.string(args[key]) ?: continue
            val trimmed = text.trim()
            if (trimmed.isNotEmpty()) return trimmed
        }
        return null
    }

    private fun resolve(reference: String, roster: BotRoster): BotProfile? {
        val needle = reference.trim()
        if (needle.isEmpty()) return null
        roster.bots.firstOrNull { it.id == needle }?.let { return it }
        val lowered = needle.lowercase()
        roster.bots.firstOrNull { it.id.lowercase() == lowered }?.let { return it }
        return roster.bots.firstOrNull { it.name.lowercase() == lowered }
    }

    private sealed interface EnumResolution {
        data class Ok(val value: String?) : EnumResolution

        data class Err(val message: String) : EnumResolution
    }

    private fun optionalEnum(
        value: JsonValue?,
        all: List<String>,
        label: String,
    ): EnumResolution {
        if (value == null || isEmpty(value)) return EnumResolution.Ok(null)
        val raw = (value as? JsonString)?.value
            ?: return EnumResolution.Err(enumMessage(all, label))
        val normalized = raw.trim().lowercase()
        if (normalized.isEmpty()) return EnumResolution.Ok(null)
        if (normalized !in all) return EnumResolution.Err(enumMessage(all, label))
        return EnumResolution.Ok(normalized)
    }

    private fun enumMessage(all: List<String>, label: String): String =
        "CreateTeammate 的 $label 只能是这些值之一：${all.joinToString("、")}"

    // ------------------------------------------------------------------
    // Advertising
    // ------------------------------------------------------------------

    private fun availableList(roster: BotRoster, callerBotId: String?): String {
        val entries = roster.visibleBots.mapNotNull { bot ->
            if (bot.id == callerBotId) return@mapNotNull null
            if (bot.id == roster.mainBotID) {
                "${bot.name} (id: ${bot.id}, main Bot)"
            } else {
                "${bot.name} (id: ${bot.id})"
            }
        }
        return if (entries.isEmpty()) "(none)" else entries.joinToString(", ")
    }

    public companion object {
        public const val SEND_TO_AGENT_NAME: String = "SendToAgent"
        public const val CREATE_TEAMMATE_NAME: String = "CreateTeammate"
        public const val MAXIMUM_HOPS: Int = 2
        public const val DEFAULT_TIMEOUT_MILLISECONDS: Int = 300_000
        public const val HELD_TEXT_LIMIT: Int = 1_200
    }
}

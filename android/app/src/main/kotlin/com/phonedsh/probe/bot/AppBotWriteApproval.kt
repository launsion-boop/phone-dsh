// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.authz.BotApprovalCoordinator
import com.phonedsh.bot.authz.BotApprovalPersistence
import com.phonedsh.bot.authz.BotArgumentsDigest
import com.phonedsh.bot.authz.BotEgressEffects
import com.phonedsh.bot.authz.BotResolvedToolCall
import com.phonedsh.bot.gateway.BotAttribution
import com.phonedsh.bot.gateway.BotGatewayPrincipal
import com.phonedsh.bot.gateway.BotIdentityRegistrationService
import com.phonedsh.bot.session.BotSessionKind
import com.phonedsh.gateway.GatewayFailure
import com.phonedsh.gateway.GatewayFailureCode
import com.phonedsh.gateway.GatewayUrl
import java.util.UUID

internal class AppBotWriteApproval(
    private val identity: BotIdentityRegistrationService,
    private val tokens: AppBotSessionPrincipals,
    private val approvals: BotApprovalCoordinator,
    private val now: () -> Long,
) {
    fun check(method: String, url: GatewayUrl, workbenchRunning: Boolean, connected: (() -> Boolean)? = null): GatewayFailure? {
        val unattributed = GatewayFailure(GatewayFailureCode.BOT_EGRESS_UNATTRIBUTED, "没有可确认的 Bot 身份")
        val ambiguous = GatewayFailure(GatewayFailureCode.BOT_EGRESS_AMBIGUOUS, "无法确认这次写入属于哪个 Bot")
        val forbidden = GatewayFailure(GatewayFailureCode.TASK_NETWORK_WRITE_DENIED, "Task 没有网络写权限")
        val registrations = identity.liveBashRegistrations()
        val call = if (registrations.isNotEmpty()) {
            val live = registrations.mapNotNull { identity.resolve(identity.runtimeId, it.sessionId, it.callId) }
            if (live.isEmpty()) return unattributed
            val matching = live.filter { command(it).contains(url.host, ignoreCase = true) }
            val candidates = matching.ifEmpty { live }
            if (candidates.map { it.botId }.distinct().size != 1) return ambiguous
            if (candidates.any { lacksNetworkWrite(it.principal) }) return forbidden
            candidates.first()
        } else {
            if (workbenchRunning) return GatewayFailure(GatewayFailureCode.EGRESS_APPROVAL_DENIED, "工作台请求没有 Bot 写授权")
            val active = tokens.activePrincipals()
            if (active.isEmpty()) return unattributed
            if (active.map { it.botId }.distinct().size != 1) return ambiguous
            if (active.any(::lacksNetworkWrite)) return forbidden
            backgroundCall(active.firstOrNull { it.kind == BotSessionKind.CHAT } ?: active.first())
        }
        val target = "${url.scheme}://${url.host}" + (url.explicitPort?.let { ":$it" } ?: "")
        val effect = BotEgressEffects.egressEffect(method, url.host, target)
        if (connected?.invoke() == false) return GatewayFailure(GatewayFailureCode.EGRESS_APPROVAL_DENIED, "请求已断开")
        val waitMillis = if (connected != null && call.principal.kind == BotSessionKind.CHAT) 20_000L else 0L
        val outcome = approvals.request(call, listOf(effect), effect.label, effect.detail, command(call),
            "until", BotApprovalPersistence.DURABLE, "egress", interactiveWaitMilliseconds = waitMillis)
        if (!outcome.allowed || connected?.invoke() == false || tokens.lookupSession(call.sessionId)?.incarnation != call.principal.incarnation ||
            (outcome.onceGrantIDs.isNotEmpty() && !approvals.consumeOnceGrants(outcome.onceGrantIDs))) {
            val reason = if (outcome.pending) "已提交审批，批准后请重试" else "这次网络写入未获授权"
            return GatewayFailure(GatewayFailureCode.EGRESS_APPROVAL_DENIED, reason)
        }
        return null
    }

    private fun command(call: BotResolvedToolCall) =
        ((call.arguments as? JsonObject)?.get("command") as? JsonString)?.value.orEmpty()

    private fun lacksNetworkWrite(p: BotGatewayPrincipal) =
        p.kind == BotSessionKind.TASK && "task.network-write" !in p.capabilities

    private fun backgroundCall(principal: BotGatewayPrincipal): BotResolvedToolCall {
        val id = "egress-" + UUID.randomUUID()
        val args = JsonObject(mapOf("command" to JsonString("")))
        val at = now()
        val attribution = BotAttribution(id, principal.sessionId, principal.incarnation, id, "bash",
            BotArgumentsDigest.string(args), null, at, at + 330000)
        return BotResolvedToolCall(principal.sessionId, id, principal.botId, principal, attribution, args)
    }
}

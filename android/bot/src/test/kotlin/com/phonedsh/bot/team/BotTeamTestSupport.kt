// SPDX-License-Identifier: MIT
package com.phonedsh.bot.team

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRoster
import com.phonedsh.bot.rows.BotAgentRef
import com.phonedsh.bot.rows.BotTeamAgentCommRecord
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.SqliteJdbcDriver
import com.phonedsh.bot.wake.BotTurnAuthority
import com.phonedsh.bot.wake.WakeInboxEnqueue
import kotlinx.coroutines.delay
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID

/** A real SQLite event log; every durable row/event in the tests lands here. */
internal class SqliteBotStore private constructor(
    val path: Path,
    val store: BotDomainStore,
) : AutoCloseable {
    override fun close() {
        runCatching { store.close() }
        runCatching { Files.deleteIfExists(path) }
        runCatching { Files.deleteIfExists(Path.of("${path}-wal")) }
        runCatching { Files.deleteIfExists(Path.of("${path}-shm")) }
    }

    companion object {
        fun open(): SqliteBotStore {
            val path = Files.createTempFile("pdsh-bot-team-", ".sqlite")
            return SqliteBotStore(path, BotDomainStore(SqliteJdbcDriver(path.toString())))
        }
    }
}

/** The fake host seam; its `recordAgentComm` writes the real P25 event. */
internal class FakeBotTeamHost(
    initialRoster: BotRoster = botTeamRoster(),
    private val sqlite: SqliteBotStore? = null,
    private val now: () -> Long = { 1_700_000_000_000L },
) : BotTeamHost {
    var rosterValue: BotRoster = initialRoster
    val created: MutableList<CreatedBot> = ArrayList()
    val createdAuthors: MutableList<BotTeammateAuthor?> = ArrayList()
    val delivered: MutableList<BotAgentDeliveryRequest> = ArrayList()
    val heldRequests: MutableList<BotTeamHeldRequest> = ArrayList()
    val records: MutableList<BotTeamAgentCommRecord> = ArrayList()
    private val contexts: MutableMap<String, BotAgentCommContext> = LinkedHashMap()
    private val threads: MutableMap<String, String> = LinkedHashMap()
    private val heldRequestIDs: MutableSet<String> = LinkedHashSet()
    private var createdCount = 0

    var reply: BotAgentDeliveryReply = BotAgentDeliveryReply("reply text", "t0u")
    var deliveryDelayMilliseconds: Int = 0
    var deliveryError: Throwable? = null
    var enqueueError: Throwable? = null
    var createdProfileID: String? = null

    data class CreatedBot(
        val name: String,
        val description: String,
        val color: BotFishColor?,
        val hairstyle: BotFishHairstyle?,
    )

    override suspend fun roster(): BotRoster = rosterValue

    override suspend fun createBot(
        name: String,
        description: String,
        color: BotFishColor?,
        hairstyle: BotFishHairstyle?,
        author: BotTeammateAuthor?,
    ): BotProfile {
        createdCount += 1
        created += CreatedBot(name, description, color, hairstyle)
        createdAuthors += author
        val profile = BotProfile(
            id = createdProfileID ?: "agent-00000000000000%02d".format(createdCount),
            name = name,
            fishColor = color ?: BotFishColor.BLUE,
            fishHairstyle = hairstyle ?: BotFishHairstyle.LONG,
            nameExplicit = true,
            createdAt = 1,
            updatedAt = 1,
            description = description,
        )
        rosterValue = rosterValue.copy(bots = rosterValue.bots + profile)
        return profile
    }

    override suspend fun agentCommContext(botID: String): BotAgentCommContext =
        contexts[botID] ?: BotAgentCommContext()

    override suspend fun existingAgentCommThread(
        botID: String,
        requestID: String,
    ): String? {
        threads[threadKey(botID, requestID)]?.let { return it }
        val durable = sqlite ?: return null
        var cursor = 0
        while (true) {
            val events = durable.store.events(cursor, 1_000)
            for (event in events) {
                if (event.type != "agent.comm") continue
                if (event.principal.botId != botID) continue
                val data = event.data as? JsonObject ?: continue
                val members = data.members
                if ((members["direction"] as? com.phonedsh.agentcore.JsonString)?.value !=
                    "outbound"
                ) {
                    continue
                }
                val durableRequestID = (members["requestId"] as? com.phonedsh.agentcore.JsonString)
                    ?.value
                    ?: event.correlationId
                if (durableRequestID != requestID) continue
                return (members["threadId"] as? com.phonedsh.agentcore.JsonString)?.value
            }
            if (events.size != 1_000) break
            cursor = events.last().commitSeq?.toInt() ?: break
        }
        return null
    }

    override suspend fun deliverToAgent(
        request: BotAgentDeliveryRequest,
    ): BotAgentDeliveryReply {
        delivered += request
        if (deliveryDelayMilliseconds > 0) delay(deliveryDelayMilliseconds.toLong())
        deliveryError?.let { throw it }
        return reply
    }

    override suspend fun enqueueHeld(request: BotTeamHeldRequest): WakeInboxEnqueue {
        enqueueError?.let { throw it }
        heldRequests += request
        val key = request.item.requestId ?: request.item.id
        val duplicate = !heldRequestIDs.add(key)
        return WakeInboxEnqueue(ok = true, item = request.item, duplicate = duplicate)
    }

    override suspend fun recordAgentComm(record: BotTeamAgentCommRecord) {
        records += record
        if (record.direction == com.phonedsh.bot.rows.BotAgentCommDirection.OUTBOUND) {
            threads[threadKey(record.botID, record.requestID)] = record.threadID
        }
        sqlite?.store?.append(record.toEvent(now()))
    }

    fun setContext(context: BotAgentCommContext, forBotID: String) {
        contexts[forBotID] = context
    }

    fun seedThread(botID: String, requestID: String, threadID: String) {
        threads[threadKey(botID, requestID)] = threadID
    }

    private fun threadKey(botID: String, requestID: String): String = "$botID\u0000$requestID"
}

internal fun botTeamRoster(): BotRoster = BotRoster(
    bots = listOf(
        BotProfile(
            id = "bot-a", name = "Alpha", fishColor = BotFishColor.BLUE,
            fishHairstyle = BotFishHairstyle.LONG, pinned = true,
        ),
        BotProfile(
            id = "bot-b", name = "Bee", fishColor = BotFishColor.RED,
            fishHairstyle = BotFishHairstyle.BOB,
        ),
        BotProfile(id = "bot-c", name = "Hidden", hiddenByUser = true),
        BotProfile(id = "bot-x", name = "Xray"),
    ),
    mainBotID = "bot-a",
)

internal fun botTeamPrincipal(
    botId: String,
    kind: com.phonedsh.bot.mcp.BotMCPPrincipalKind =
        com.phonedsh.bot.mcp.BotMCPPrincipalKind.CHAT,
    sessionId: String = "gb-$botId",
): com.phonedsh.bot.mcp.BotMCPPrincipal = com.phonedsh.bot.mcp.BotMCPPrincipal(
    botId = botId,
    sessionId = sessionId,
    kind = kind,
)

internal fun botTeamResultText(result: com.phonedsh.bot.mcp.BotMCPCallResult): String =
    result.text() ?: ""

internal fun botTeamAuthority(
    isUserTurn: Boolean = true,
    approvalId: String? = null,
): BotTurnAuthority = BotTurnAuthority(
    rpcId = if (isUserTurn) "bot-${UUID.randomUUID()}" else "agent:call-1",
    turnId = "turn-1",
    sessionId = "gb-bot-a",
    origin = if (isUserTurn) {
        com.phonedsh.bot.wake.BotTurnOriginKind.USER
    } else {
        com.phonedsh.bot.wake.BotTurnOriginKind.AGENT
    },
    isUserTurn = isUserTurn,
    approvalId = approvalId,
)

internal fun agentRef(id: String, name: String): BotAgentRef = BotAgentRef(id, name, "agent")

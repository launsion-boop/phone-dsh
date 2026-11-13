// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.driver

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBatch
import com.phonedsh.bot.rows.BotUserAction
import com.phonedsh.ui.bot.state.BotRuntimePresentation
import com.phonedsh.ui.bot.state.BotUIHistoryPage
import com.phonedsh.ui.bot.state.BotUIRowCodec
import java.io.File
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf

/**
 * Reads the pure-data export of `BotFixtures.swift`
 * (`spec/ui/v1/bot/golden/fixtures.json`, `ui-state.md` §6).
 *
 * The file is the one fixture authority for the Kotlin previews and tests; no
 * test carries a hand-copied row. The file is supplied as data so the same
 * driver works from a JVM test (`fromFile`) and from an Android preview asset
 * (`fromJson`).
 */
public object BotFixtureData {
    /** The fixture document's schema version this reader understands. */
    public const val SCHEMA_VERSION: Long = 1

    /** The pinned `now` the export froze (`fixtures.json.pinnedNow`). */
    public fun pinnedNow(fixtures: JsonObject): Long =
        (fixtures["pinnedNow"] as? com.phonedsh.agentcore.JsonNumber)?.asLongOrNull()
            ?: 0L

    /** Every exported scenario name, in file order. */
    public fun scenarios(fixtures: JsonObject): List<String> =
        exported(fixtures).mapNotNull { entry -> (entry["scenario"] as? JsonString)?.value }

    /** One scenario's rows, decoded through the real P09 row decoder. */
    public fun rows(fixtures: JsonObject, scenario: String): List<BotRow> {
        val entry = exported(fixtures).firstOrNull {
            (it["scenario"] as? JsonString)?.value == scenario
        } ?: error("fixtures.json has no exported scenario '$scenario'")
        val rows = entry["rows"] as? JsonArray ?: JsonArray(emptyList())
        return BotUIRowCodec.fromJsonList(rows.values)
    }

    /** The scenario's `draft` text, if it exports one (`composerLongDraft`). */
    public fun draft(fixtures: JsonObject, scenario: String): String? {
        val entry = exported(fixtures).firstOrNull {
            (it["scenario"] as? JsonString)?.value == scenario
        } ?: return null
        return (entry["draft"] as? JsonString)?.value
    }

    /** Reads a fixture document from disk. */
    public fun fromFile(file: File): JsonObject {
        val value = JsonValue.parse(file.readText(Charsets.UTF_8)) as? JsonObject
            ?: error("fixtures.json must be a JSON object")
        val version = (value["schemaVersion"] as? com.phonedsh.agentcore.JsonNumber)
            ?.asLongOrNull()
        require(version == SCHEMA_VERSION) {
            "unsupported fixtures.json schemaVersion: $version"
        }
        return value
    }

    private fun exported(fixtures: JsonObject): List<JsonObject> =
        (fixtures["exported"] as? JsonArray)?.values?.mapNotNull { it as? JsonObject }
            ?: emptyList()
}

/**
 * A fixture-backed [BotChatDriver] for tests and previews.
 *
 * `watch` replays one `reset` batch built from the chosen fixture scenarios;
 * `history` pages through the chosen history scenarios; `perform` records every
 * action and answers from [actionResults] (then `accepted`). No fixture scenario
 * is invented or copied: the rows come from
 * `spec/ui/v1/bot/golden/fixtures.json`.
 */
public class FixtureBotChatDriver private constructor(
    private val watchRows: List<BotRow>,
    private val historyRows: List<BotRow>,
    private val presentations: List<BotRuntimePresentation>,
    private val frames: List<BotLiveFrame>,
    private val processes: Map<Int, BotTurnProcess>,
    actionResults: List<BotActionResult>,
) : BotChatDriver {
    private val queuedResults: ArrayDeque<BotActionResult> = ArrayDeque(actionResults)
    private val consumedNonces: MutableMap<String, String> = LinkedHashMap()
    private var acceptedCount: Int = 0

    /** Every `history(before, limit)` call, in order. */
    public val historyCalls: MutableList<Pair<String?, Int>> = mutableListOf()

    /** Every `perform` call, in order. */
    public val performed: MutableList<BotUserAction> = mutableListOf()

    /** Every `stopCurrentTurn` argument, in order. */
    public val stopCalls: MutableList<String?> = mutableListOf()

    /** Extra batches `watch` emits after the first reset batch. */
    private val extraBatches: MutableList<BotRowBatch> = mutableListOf()

    /** Queues a later watch batch (a progress update, a delete, a notice). */
    public fun enqueueBatch(batch: BotRowBatch) {
        extraBatches.add(batch)
    }

    /** Replaces the remaining scripted action results. */
    public fun enqueueResults(vararg results: BotActionResult) {
        queuedResults.addAll(results)
    }

    override suspend fun history(before: String?, limit: Int): BotUIHistoryPage {
        historyCalls.add(before to limit)
        if (historyRows.isEmpty()) return BotUIHistoryPage(emptyList(), null, false)
        val end = if (before == null) {
            historyRows.size
        } else {
            historyRows.indexOfFirst { it.id == before }.let { if (it < 0) historyRows.size else it }
        }
        val start = (end - limit.coerceAtLeast(1)).coerceAtLeast(0)
        val page = historyRows.subList(start, end)
        return BotUIHistoryPage(
            rows = page.toList(),
            nextCursor = page.firstOrNull()?.id,
            hasMore = start > 0,
        )
    }

    override fun watch(cursor: Long): Flow<BotRowBatch> = flow {
        if (cursor > 0) return@flow
        val batch = BotRowBatch(
            rows = watchRows,
            deletes = emptyList(),
            cursor = watchRows.size.toLong(),
            reset = true,
        )
        emit(batch)
        for (extra in extraBatches) emit(extra)
    }

    override suspend fun perform(action: BotUserAction): BotActionResult {
        performed.add(action)
        queuedResults.removeFirstOrNull()?.let { return it }
        val prior = consumedNonces[action.nonce]
        if (prior != null) return BotActionResult.Duplicate(prior)
        acceptedCount += 1
        val eventID = "evt-action-$acceptedCount"
        consumedNonces[action.nonce] = eventID
        return BotActionResult.Accepted(eventID)
    }

    override suspend fun stopCurrentTurn(turnID: String?) {
        stopCalls.add(turnID)
    }

    override suspend fun turnProcesses(): Map<Int, BotTurnProcess> = processes

    override fun liveFrames(): Flow<BotLiveFrame> = flow {
        for (frame in frames) emit(frame)
    }

    override fun presentation(): Flow<BotRuntimePresentation> = flowOf(*presentations.toTypedArray())

    public companion object {
        /**
         * Builds a driver from the fixture document.
         *
         * @param scenario the transcript scenario `watch` replays.
         * @param historyScenarios older rows `history` pages through.
         * @param actionResults scripted results, consumed in order; afterwards
         *   every new nonce is accepted.
         */
        public fun fromJson(
            fixtures: JsonObject,
            scenario: String = "chat",
            historyScenarios: List<String> = emptyList(),
            actionResults: List<BotActionResult> = emptyList(),
            presentations: List<BotRuntimePresentation> =
                listOf(BotRuntimePresentation()),
            frames: List<BotLiveFrame> = emptyList(),
            processes: Map<Int, BotTurnProcess> = emptyMap(),
        ): FixtureBotChatDriver = FixtureBotChatDriver(
            watchRows = BotFixtureData.rows(fixtures, scenario),
            historyRows = historyScenarios.flatMap { BotFixtureData.rows(fixtures, it) },
            presentations = presentations,
            frames = frames,
            processes = processes,
            actionResults = actionResults,
        )

        /** Builds a driver from `spec/ui/v1/bot/golden/fixtures.json` on disk. */
        public fun fromFile(
            file: File,
            scenario: String = "chat",
            historyScenarios: List<String> = emptyList(),
            actionResults: List<BotActionResult> = emptyList(),
            presentations: List<BotRuntimePresentation> =
                listOf(BotRuntimePresentation()),
            frames: List<BotLiveFrame> = emptyList(),
            processes: Map<Int, BotTurnProcess> = emptyMap(),
        ): FixtureBotChatDriver = fromJson(
            fixtures = BotFixtureData.fromFile(file),
            scenario = scenario,
            historyScenarios = historyScenarios,
            actionResults = actionResults,
            presentations = presentations,
            frames = frames,
            processes = processes,
        )
    }
}

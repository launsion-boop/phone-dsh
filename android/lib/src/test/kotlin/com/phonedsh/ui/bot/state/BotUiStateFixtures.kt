// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.rows.BotRow
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import org.junit.Assert.assertEquals

/**
 * Reads the normative P09 vectors from the repository at test time. The root
 * arrives as the `pdsh.repo.root` system property (`:lib`'s build sets it); a
 * walk-up fallback keeps the suite runnable from an IDE. No vector is copied
 * into this source tree.
 */
object BotUiStateFixtures {
    val repoRoot: Path by lazy { locate() }

    const val BOT_SPEC: String = "spec/ui/v1/bot"

    fun json(relative: String): JsonObject =
        JsonValue.parse(String(Files.readAllBytes(repoRoot.resolve(relative)), Charsets.UTF_8))
            as JsonObject

    fun golden(name: String): JsonObject = json("$BOT_SPEC/golden/$name")

    fun strings(): JsonObject = json("$BOT_SPEC/strings.json")

    fun activityPhrases(): JsonObject = json("$BOT_SPEC/activity-phrases.json")

    fun canonical(value: JsonValue): String = BotJson.canonical(value)

    fun assertJsonEquals(message: String, expected: JsonValue, actual: JsonValue) {
        assertEquals(
            "$message\nexpected: ${canonical(expected)}\nactual:   ${canonical(actual)}",
            canonical(expected),
            canonical(actual),
        )
    }

    fun cases(file: String): List<JsonObject> =
        (golden(file)["cases"] as JsonArray).values.map { it as JsonObject }

    fun rows(value: JsonValue): List<BotRow> =
        (value as JsonArray).values.map { BotUIRowCodec.fromJson(it) }

    fun rowForBody(body: JsonObject, id: String = "row"): BotRow {
        val row = BotJson.objectOf(
            "id" to JsonString(id),
            "botID" to JsonString("main"),
            "seq" to JsonNumber("1"),
            "updatedSeq" to JsonNumber("1"),
            "kind" to JsonString("event"),
            "body" to body,
            "provenance" to BotJson.objectOf(
                "eventIDs" to JsonArray(listOf(JsonString("evt-$id"))),
                "trust" to JsonString("model"),
                "tainted" to JsonBool(false),
            ),
            "streaming" to JsonBool(false),
            "createdAt" to JsonNumber("1760000000000"),
        )
        return BotUIRowCodec.fromJson(row)
    }

    fun actionStates(value: JsonValue): Map<String, BotActionState> {
        val members = (value as JsonObject).members
        return members.mapValues { (_, raw) ->
            when ((raw as JsonString).value) {
                "pending" -> BotActionState.Pending
                "accepted" -> BotActionState.Accepted
                "failed" -> BotActionState.Failed("")
                else -> throw BotJsonException("unknown action state")
            }
        }
    }

    fun checklistProgress(value: JsonValue): Map<String, BotChecklistProgress> {
        val members = (value as JsonObject).members
        return members.mapValues { (_, raw) ->
            val item = (raw as JsonObject).members
            BotChecklistProgress(
                done = JsonSupport.requiredNonNegativeInt(item, "done", "progress.done"),
                total = JsonSupport.requiredNonNegativeInt(item, "total", "progress.total"),
                sending = JsonSupport.requiredBool(item, "sending", "progress.sending"),
                sent = JsonSupport.requiredBool(item, "sent", "progress.sent"),
            )
        }
    }

    fun presentation(value: JsonValue?): BotRuntimePresentation =
        if (value == null || value is JsonNull) BotRuntimePresentation()
        else BotRuntimePresentation.fromJson(value)

    fun presentationOrNull(value: JsonValue?): BotRuntimePresentation? =
        if (value == null || value is JsonNull) null else BotRuntimePresentation.fromJson(value)

    fun liveTurn(value: JsonValue?): BotLiveTurn? {
        if (value == null || value is JsonNull) return null
        val members = (value as JsonObject).members
        return BotLiveTurn(
            turn = JsonSupport.optionalNonNegativeInt(members, "turn", "live.turn"),
            ended = JsonSupport.requiredBool(members, "ended", "live.ended"),
        )
    }

    fun uiStateInput(value: JsonValue): BotUiStateInput {
        val members = JsonSupport.objectMembers(value, "input")
        val context = JsonSupport.objectMembers(
            members["context"] ?: throw BotJsonException("missing context"), "context")
        val streaming = JsonSupport.objectMembers(
            members["streaming"] ?: throw BotJsonException("missing streaming"), "streaming")
        val drawer = JsonSupport.objectMembers(
            members["drawer"] ?: throw BotJsonException("missing drawer"), "drawer")
        val drawerActivity = JsonSupport.optionalObject(drawer["activity"], "drawer.activity")
            ?.let { BotActivity.fromJson(JsonObject(it)) }
        val drawerFish = JsonSupport.string(drawer["fishState"])?.let {
            BotFishLifecycle.fromWire(it)
                ?: throw BotJsonException("drawer.fishState has unknown value: $it")
        } ?: BotFishLifecycle.IDLE
        val decodedRows = rows(members["rows"] ?: throw BotJsonException("missing rows"))
        val decodedActionStates = actionStates(
            members["actionStates"] ?: throw BotJsonException("missing actionStates"))
        return BotUiStateInput(
            context = BotUiContext(
                botID = JsonSupport.requiredString(context, "botID", "context.botID"),
                botName = JsonSupport.requiredString(context, "botName", "context.botName"),
                followingCount = JsonSupport.optionalNonNegativeInt(
                    context, "followingCount", "context.followingCount"),
            ),
            rows = decodedRows,
            actionStates = decodedActionStates,
            dismissedCardIDs = stringSet(members["dismissedCardIDs"]),
            autoDeclinedApprovalIDs = stringSet(members["autoDeclinedApprovalIDs"]),
            answeredOptionIDs = stringMap(members["answeredOptionIDs"]),
            checklistProgress = checklistProgress(
                members["checklistProgress"] ?: throw BotJsonException("missing checklistProgress")),
            runtimePresentation = presentation(
                members["runtimePresentation"] ?: throw BotJsonException("missing presentation")),
            livePresentation = presentationOrNull(members["livePresentation"]),
            live = liveTurn(members["live"]),
            runningTurnID = JsonSupport.optionalString(members, "runningTurnID", "input.runningTurnID"),
            awaitingTurn = JsonSupport.requiredBool(members, "awaitingTurn", "input.awaitingTurn"),
            lineSuppressed = JsonSupport.requiredBool(
                members, "lineSuppressed", "input.lineSuppressed"),
            idleSleeping = JsonSupport.requiredBool(members, "idleSleeping", "input.idleSleeping"),
            streaming = BotStreamingState(
                pendingDelta = JsonSupport.requiredString(
                    streaming, "pendingDelta", "streaming.pendingDelta"),
                streamingText = JsonSupport.optionalString(
                    streaming, "streamingText", "streaming.streamingText"),
                liveBuffer = JsonSupport.requiredString(
                    streaming, "liveBuffer", "streaming.liveBuffer"),
            ),
            pendingApprovalCount = JsonSupport.optionalNonNegativeInt(
                members, "pendingApprovalCount", "input.pendingApprovalCount"),
            running = JsonSupport.optionalBool(members, "running", "input.running") ?: false,
            problem = JsonSupport.optionalString(members, "problem", "input.problem"),
            now = JsonSupport.requiredNonNegativeLong(members, "now", "input.now"),
            drawer = BotDrawerState(
                isRunning = JsonSupport.requiredBool(drawer, "isRunning", "drawer.isRunning"),
                lastMessageAt = JsonSupport.optionalNonNegativeLong(
                    drawer, "lastMessageAt", "drawer.lastMessageAt"),
                unreadCount = JsonSupport.requiredNonNegativeInt(
                    drawer, "unreadCount", "drawer.unreadCount"),
                activity = drawerActivity,
                fishState = drawerFish,
            ),
        )
    }

    private fun stringSet(value: JsonValue?): Set<String> =
        (value as JsonArray).values.map { (it as JsonString).value }.toSet()

    private fun stringMap(value: JsonValue?): Map<String, String> =
        (value as JsonObject).members.mapValues { (_, item) -> (item as JsonString).value }

    private fun locate(): Path {
        // Test-only override so a lane can replay another worktree's in-progress
        // spec snapshot without copying a vector into this tree. Normal runs use
        // the Gradle-provided `pdsh.repo.root`.
        val property = System.getenv("PDSH_TEST_REPO_ROOT")
            ?: System.getProperty("pdsh.repo.root")
        if (!property.isNullOrEmpty()) {
            val path = Paths.get(property).toAbsolutePath().normalize()
            if (Files.isDirectory(path.resolve(BOT_SPEC))) return path
        }
        var candidate: Path? = Paths.get("").toAbsolutePath().normalize()
        while (candidate != null) {
            if (Files.isDirectory(candidate.resolve(BOT_SPEC))) return candidate
            candidate = candidate.parent
        }
        throw IllegalStateException(
            "cannot locate the repository: set -Dpdsh.repo.root or run from the repo tree")
    }
}

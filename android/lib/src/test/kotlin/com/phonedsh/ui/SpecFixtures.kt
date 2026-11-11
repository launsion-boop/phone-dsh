// Normative fixtures, read from the spec at test time.
// SPDX-License-Identifier: MIT
//
// The tests never carry a copy of the spec: `tokens.json`, the trajectory
// goldens, `ui-state-sequence.schema.json` and `event-kinds.md`'s crosswalk are
// read from the repository. The repo root arrives as the `pdsh.repo.root` system
// property (set by :lib's build script); a walk-up fallback keeps the suite
// runnable from an IDE.
package com.phonedsh.ui

import com.phonedsh.agentcore.HarnessEvent
import com.phonedsh.agentcore.HarnessKind
import com.phonedsh.agentcore.HarnessKindName
import com.phonedsh.agentcore.HarnessPermissionRequest
import com.phonedsh.agentcore.HarnessToolRisk
import com.phonedsh.agentcore.HarnessTurnEnd
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.nio.file.Files
import java.nio.file.Path

/** Locates the repository and reads the normative fixtures. */
object SpecFixtures {
    /** The repository root; resolved once per test JVM. */
    val repoRoot: Path by lazy { locate() }

    /** `spec/ui/v1/tokens.json`, parsed. */
    val tokens: JsonObject by lazy {
        readJson(repoRoot.resolve("spec/ui/v1/tokens.json"))
    }

    /** `spec/v1/schema/ui-state-sequence.schema.json`, parsed. */
    val uiStateSchema: JsonObject by lazy {
        readJson(repoRoot.resolve("spec/v1/schema/ui-state-sequence.schema.json"))
    }

    /** The five golden trajectory case names. */
    fun trajectoryCases(): List<String> {
        val dir = repoRoot.resolve("spec/v1/golden/trajectory")
        return Files.list(dir).use { stream ->
            stream.filter { Files.isDirectory(it) }
                .filter { Files.exists(it.resolve("expected.jsonl")) }
                .map { it.fileName.toString() }
                .sorted()
                .toList()
        }
    }

    /** Reads one golden file (default `expected.jsonl`) as trajectory rows. */
    fun trajectoryRows(case: String, file: String = "expected.jsonl"): List<TrajectoryRow> {
        val path = repoRoot.resolve("spec/v1/golden/trajectory/$case/$file")
        return Files.readAllLines(path)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { TrajectoryRow.fromJson(JsonValue.parse(it) as JsonObject) }
    }

    /** Reads `notes.json` for a case. */
    fun notes(case: String): JsonObject =
        readJson(repoRoot.resolve("spec/v1/golden/trajectory/$case/notes.json"))

    /** Reads any normative JSON fixture by repository-relative path. */
    fun repoJson(relative: String): JsonObject = readJson(repoRoot.resolve(relative))

    /**
     * Rebuilds the host stream from normalized rows, re-inserting the turn
     * boundary the fixtures omit (`turn/start` is `golden: no` in
     * `event-kinds.md` §1).
     */
    fun eventsFor(rows: List<TrajectoryRow>): List<HarnessEvent> {
        val events = mutableListOf<HarnessEvent>()
        var turn: String? = null
        rows.forEach { row ->
            if (row.turnID != turn) {
                TrajectoryRow.turnBoundary(row.turnID, row.sessionID)?.let { events.add(it) }
                turn = row.turnID
            }
            row.toEvent()?.let { events.add(it) }
        }
        return events
    }

    /** Projects one golden case end to end: normalized rows -> UiState nodes. */
    fun projectCase(case: String, file: String = "expected.jsonl"): List<com.phonedsh.ui.projection.UiStateNode> =
        com.phonedsh.ui.projection.UiStateProjector.project(eventsFor(trajectoryRows(case, file)))

    /** Reads a pinned UiState expectation from `src/test/resources/ui-state/`. */
    fun pinnedUiState(name: String): String {
        val resource = requireNotNull(javaClass.getResourceAsStream("/ui-state/$name")) {
            "missing test resource /ui-state/$name; the pinned sequence is the acceptance data"
        }
        return resource.bufferedReader().use { it.readText() }
    }

    private fun readJson(path: Path): JsonObject =
        JsonValue.parse(String(Files.readAllBytes(path), Charsets.UTF_8)) as JsonObject

    private fun locate(): Path {
        System.getProperty("pdsh.repo.root")?.let { property ->
            val root = Path.of(property)
            if (Files.exists(root.resolve("spec/ui/v1/tokens.json"))) return root
        }
        var current: Path? = Path.of(System.getProperty("user.dir")).toAbsolutePath()
        while (current != null) {
            if (Files.exists(current.resolve("spec/ui/v1/tokens.json"))) return current
            current = current.parent
        }
        error("cannot locate the repository root (spec/ui/v1/tokens.json) from the test working directory")
    }
}

/**
 * One normalized trajectory row (`trajectory/1`).
 *
 * The projection acceptance test starts from these rows: they are the norm's
 * own output, already free of platform noise.
 */
data class TrajectoryRow(
    val sessionID: String,
    val turnID: String,
    val seq: Long?,
    val type: String,
    val data: JsonObject,
) {
    /**
     * Rebuilds the host event this row projects from
     * (`spec/host/v1/event-kinds.md` §1 crosswalk, read backwards).
     *
     * Two documented adapter decisions:
     *  * `seq` is attached only to a durable host kind
     *    ([HarnessKindName.durable]); a best-effort ask carries no `seq`, so the
     *    projector has to allocate the writer's own ordinal — which is exactly
     *    what the goldens authored.
     *  * `permission/result` has no host kind at all (it is a client-written
     *    synthetic row), so it is dropped here: the card leaves the screen on the
     *    user's tap, not on an event.
     */
    fun toEvent(): HarnessEvent? {
        val kind: HarnessKind = when (type) {
            "user/message" -> HarnessKind.UserMessage(
                text = data.text("text").orEmpty(),
                source = data.text("source") ?: UNKNOWN_SOURCE,
            )

            "assistant/message" -> HarnessKind.AssistantMessage(text = data.text("text").orEmpty())
            "tool/call" -> HarnessKind.ToolCall(
                callId = data.text("callId").orEmpty(),
                name = data.text("name").orEmpty(),
                arguments = parseArguments(data["arguments"]),
            )

            "tool/result" -> HarnessKind.ToolResult(
                callId = data.text("callId").orEmpty(),
                isError = (data["isError"] as? JsonBool)?.value ?: false,
                summary = data.text("output") ?: data.text("summary") ?: "",
            )

            "permission/request" -> HarnessKind.PermissionRequested(
                HarnessPermissionRequest(
                    requestId = data.text("id").orEmpty(),
                    // The trajectory row carries the tool *action*; the host field is `tool`.
                    tool = data.text("action") ?: data.text("tool") ?: "",
                    summary = data.text("text") ?: "",
                    // `risk` is a policy input the row does not carry and the card
                    // does not render; the projector never reads it.
                    risk = HarnessToolRisk.READ_ONLY,
                ),
            )

            "question/request" -> HarnessKind.QuestionRequested(
                com.phonedsh.agentcore.HarnessQuestion(
                    requestId = data.text("id").orEmpty(),
                    prompt = data.text("text") ?: "",
                ),
            )

            // `session_status` maps to the session/start row; the projector turns it
            // into the structural session node.
            "session/start" -> HarnessKind.SessionStatus(status = SESSION_RUNNING)

            "turn/start" -> HarnessKind.TurnStarted(turnId = turnID)

            "turn/end" -> HarnessKind.TurnEnded(
                turnId = turnID,
                reason = reason(),
            )

            else -> return null
        }
        val durable = HarnessKindName.fromWire(kind.kindName.wire)?.durable ?: false
        return HarnessEvent(
            sessionId = sessionID,
            timeMs = 0L,
            seq = if (durable) seq else null,
            kind = kind,
            rawTurnEndKind = if (type == "turn/end") data.reasonKind() else null,
        )
    }

    private fun reason(): HarnessTurnEnd {
        val kind = data.reasonKind()
        return when (kind) {
            "completed" -> HarnessTurnEnd.Completed
            "error", "failed" -> HarnessTurnEnd.Failed(data.reasonMessage().orEmpty())
            else -> HarnessTurnEnd.Cancelled
        }
    }

    companion object {
        const val UNKNOWN_SOURCE: String = "unknown"
        const val SESSION_RUNNING: String = "running"

        fun fromJson(value: JsonObject): TrajectoryRow = TrajectoryRow(
            sessionID = value.text("sessionID").orEmpty(),
            turnID = value.text("turnID").orEmpty(),
            seq = (value["seq"] as? JsonNumber)?.asLongOrNull(),
            type = value.text("type").orEmpty(),
            data = value["data"] as? JsonObject ?: JsonObject(emptyMap()),
        )

        /**
         * The turn boundary a golden row implies.
         *
         * `turn/start` rows are declared in `event-kinds.md` §1 with
         * `golden: no`, so the fixtures carry no boundary row while every row is
         * turn-attributed. The adapter re-inserts the boundary; it carries no
         * `seq` because a boundary is structural (the projector consumes no
         * ordinal for it).
         */
        fun turnBoundary(turnID: String, sessionID: String): HarnessEvent? {
            if (turnID == "-") return null
            return HarnessEvent(
                sessionId = sessionID,
                timeMs = 0L,
                seq = null,
                kind = HarnessKind.TurnStarted(turnId = turnID),
            )
        }
    }
}

/** Reads a string member. */
fun JsonObject.text(key: String): String? = (this[key] as? JsonString)?.value

/** Reads `data.reason.kind`. */
fun JsonObject.reasonKind(): String? = ((this["reason"] as? JsonObject)?.get("kind") as? JsonString)?.value

/** Reads `data.reason.error.message`. */
fun JsonObject.reasonMessage(): String? =
    (((this["reason"] as? JsonObject)?.get("error")) as? JsonObject)?.let { error ->
        (error["message"] as? JsonString)?.value
    }

/** Tool arguments: the golden stores compact JSON text; parse it so props stay typed. */
private fun parseArguments(value: JsonValue?): JsonValue = when (value) {
    null -> JsonObject(emptyMap())
    is JsonString -> runCatching { JsonValue.parse(value.value) }.getOrDefault(value)
    else -> value
}

/** The `(kind, surface)` pair every signature surface must be able to render. */
data class SurfaceRef(val id: String, val tokens: List<String>)

/** Reads `signatureSurfaces` as id -> token list. */
fun SpecFixtures.surfaces(): List<SurfaceRef> {
    val surfaces = tokens["signatureSurfaces"] as JsonObject
    return surfaces.members.map { (id, raw) ->
        val entry = raw as JsonObject
        val tokens = (entry["tokens"] as JsonArray).values.map { (it as JsonString).value }
        SurfaceRef(id, tokens)
    }
}

/** Every leaf token name in `tokens.json`, in the spec's own path spelling. */
fun SpecFixtures.tokenNames(): Set<String> {
    val names = LinkedHashSet<String>()
    (tokens["colors"] as JsonObject).members.forEach { (key, _) -> names.add("colors.$key") }
    ((tokens["typography"] as JsonObject)["styles"] as JsonObject).members
        .forEach { (key, _) -> names.add("typography.$key") }
    for (family in listOf("spacing", "radius", "stroke", "motion", "geometry", "shadows")) {
        (tokens[family] as JsonObject).members.forEach { (key, _) -> names.add("$family.$key") }
    }
    return names
}

/**
 * A JSON-Schema subset validator for the two schemas the projections are checked
 * against: `type`, `required`, `additionalProperties`, `properties`, `const`,
 * `enum`, `pattern`, `maxLength`, `minimum`, `maximum` and `items`.
 *
 * It is deliberately literal: it reads the real schema file instead of a
 * hand-written shape, so a schema edit reaches the test.
 */
object JsonSchemaLite {
    fun validate(schema: JsonObject, value: JsonValue, path: String = "$"): List<String> {
        val problems = mutableListOf<String>()
        val expected = (schema["type"] as? JsonString)?.value
        val allowedTypes = (schema["type"] as? JsonArray)?.values?.mapNotNull { (it as? JsonString)?.value }
            ?: listOfNotNull(expected)
        if (allowedTypes.isNotEmpty() && allowedTypes.none { matchesType(it, value) }) {
            problems.add("$path: expected type $allowedTypes, got $value")
            return problems
        }
        (schema["const"] as? JsonString)?.let { constant ->
            if ((value as? JsonString)?.value != constant.value) {
                problems.add("$path: expected const '${constant.value}', got $value")
            }
        }
        (schema["enum"] as? JsonArray)?.let { enum ->
            if (enum.values.none { it == value }) problems.add("$path: $value is not in the enum")
        }
        (schema["maxLength"] as? JsonNumber)?.asLongOrNull()?.let { max ->
            if (value is JsonString && value.value.length > max) {
                problems.add("$path: length ${value.value.length} > maxLength $max")
            }
        }
        (schema["pattern"] as? JsonString)?.let { pattern ->
            if (value is JsonString && !Regex(pattern.value).matches(value.value)) {
                problems.add("$path: '${value.value}' does not match ${pattern.value}")
            }
        }
        if (value is JsonNumber) {
            val number = value.asLongOrNull()
            (schema["minimum"] as? JsonNumber)?.asLongOrNull()?.let { min ->
                if (number == null || number < min) problems.add("$path: $number < minimum $min")
            }
            (schema["maximum"] as? JsonNumber)?.asLongOrNull()?.let { max ->
                if (number == null || number > max) problems.add("$path: $number > maximum $max")
            }
        }
        if (value is JsonObject) {
            val required = (schema["required"] as? JsonArray)?.values?.mapNotNull { (it as? JsonString)?.value }
                ?: emptyList()
            required.filterNot { value.members.containsKey(it) }.forEach {
                problems.add("$path: missing required member '$it'")
            }
            val properties = schema["properties"] as? JsonObject
            if (properties != null) {
                value.members.forEach { (key, member) ->
                    val memberSchema = properties[key] as? JsonObject
                    if (memberSchema == null) {
                        if ((schema["additionalProperties"] as? JsonBool)?.value == false) {
                            problems.add("$path: unexpected member '$key'")
                        }
                    } else {
                        problems.addAll(validate(memberSchema, member, "$path.$key"))
                    }
                }
            }
        }
        if (value is JsonArray) {
            val items = schema["items"] as? JsonObject
            if (items != null) {
                value.values.forEachIndexed { index, item ->
                    problems.addAll(validate(items, item, "$path[$index]"))
                }
            }
        }
        return problems
    }

    private fun matchesType(type: String, value: JsonValue): Boolean = when (type) {
        "object" -> value is JsonObject
        "array" -> value is JsonArray
        "string" -> value is JsonString
        "integer" -> value is JsonNumber
        "number" -> value is JsonNumber
        "boolean" -> value is JsonBool
        "null" -> value is com.phonedsh.agentcore.JsonNull
        else -> true
    }
}

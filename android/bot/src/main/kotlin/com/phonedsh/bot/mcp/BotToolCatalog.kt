// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRoster

/**
 * The P0 tool catalog and the phone delta, built from the untouched shared
 * vectors `tool-catalog.json` + `tool-catalog.phone.json`.
 *
 * The catalog is deliberately data-driven: descriptions and input schemas for
 * the sixteen upstream P0 tools are read from the golden rather than typed
 * into Kotlin, and the five phone content-card entries replace their upstream
 * names. `ReadMemory` predates the exporter batch and has no full entry in
 * either file (the phone vector only freezes its property names), so its
 * description comes from the frozen Swift literal; everything else is data.
 *
 * The app supplies [roster] so the team descriptions carry the live
 * `Available bots:` line and `CreateTeammate` is hidden from a non-main Bot.
 */
public class BotToolCatalog(
    public val p0: List<BotMCPToolDefinition>,
    public val p1: List<BotMCPToolDefinition>,
    public val fishAction: BotMCPToolDefinition,
    public val volatileContext: BotMCPToolDefinition,
    public val attachToModel: BotMCPToolDefinition,
    private val teamBase: List<BotMCPToolDefinition>,
    private val roster: BotRoster? = null,
) : BotMCPToolCatalogProvider {

    override fun definitions(callerBotId: String?): List<BotMCPToolDefinition> {
        val team = teamDefinitions(callerBotId)
        return p0 + fishAction + volatileContext + attachToModel + team
    }

    public fun teamDefinitions(callerBotId: String?): List<BotMCPToolDefinition> {
        val line = roster?.let { availableBotsLine(it, callerBotId) }
        val definitions = teamBase.map { definition ->
            if (line == null) definition
            else definition.copy(description = definition.description + "\n" + line)
        }
        if (roster != null && callerBotId != null && callerBotId != roster.mainBotID) {
            return definitions.filterNot { it.name == CREATE_TEAMMATE_NAME }
        }
        return definitions
    }

    public fun isP1(name: String): Boolean = p1.any { it.name == name }

    public companion object {
        public val P0_NAMES: List<String> = listOf(
            "ask_user", "show_next_steps", "show_attachment", "show_document", "show_progress",
            "show_checklist", "show_link", "UpdateMemory", "ReadMemory", "RecallMemory",
            "Task", "AwaitTask", "StopSubagent", "UpdateRoutine", "ListRoutines",
            "RequestApproval", "SendToUser",
        )
        public val P1_TARGET_NAMES: List<String> = listOf(
            "show_table", "show_callout", "show_info", "show_payload", "show_library",
        )
        public const val VOLATILE_CONTEXT_NAME: String = "BotVolatileContext"
        /**
         * One existing image handed to the model as an MCP image content block.
         * Not in [P0_NAMES]: it is an additive vision capability, so the
         * frozen P0 golden and every non-vision deployment stay unchanged.
         */
        public const val ATTACH_TO_MODEL_NAME: String = "attach_to_model"
        public const val FISH_ACTION_NAME: String = "FishAction"
        public const val SEND_TO_AGENT_NAME: String = "SendToAgent"
        public const val CREATE_TEAMMATE_NAME: String = "CreateTeammate"
        public val TEAM_TOOL_NAMES: List<String> = listOf(SEND_TO_AGENT_NAME, CREATE_TEAMMATE_NAME)
        public val CARD_TOOL_NAMES: Set<String> = setOf(
            "ask_user", "show_next_steps", "show_attachment", "show_document",
            "show_progress", "show_checklist", "show_link",
        )
        public val CONTENT_CARD_NAMES: Set<String> = setOf(
            "show_attachment", "show_document", "show_progress", "show_checklist", "show_link",
        )

        /** §8.1: P0 + BotVolatileContext + the additive vision tool. */
        public fun isRegistered(name: String): Boolean =
            name == VOLATILE_CONTEXT_NAME || name == ATTACH_TO_MODEL_NAME || P0_NAMES.contains(name)

        public fun isTeamTool(name: String): Boolean = TEAM_TOOL_NAMES.contains(name)

        /**
         * Build from `golden/tool-catalog.json` and `golden/tool-catalog.phone.json`.
         * Callers pass the parsed JSON values so production can load the same
         * bytes from an app asset and tests read the repository fixture.
         */
        public fun fromGolden(
            upstream: JsonValue,
            phone: JsonValue,
            roster: BotRoster? = null,
        ): BotToolCatalog {
            val upstreamValid = (upstream as? JsonObject)?.members?.get("valid") as? JsonObject
                ?: throw IllegalArgumentException("tool-catalog: valid must be an object")
            val upstreamP0 = arrayOfObjects(upstreamValid.members["p0"], "tool-catalog.valid.p0")
            val upstreamP1 = arrayOfObjects(upstreamValid.members["p1"], "tool-catalog.valid.p1")

            val phoneValid = (phone as? JsonObject)?.members?.get("valid") as? JsonObject
                ?: throw IllegalArgumentException("tool-catalog.phone: valid must be an object")
            val phoneEntries = arrayOfObjects(phoneValid.members["p0"], "tool-catalog.phone.valid.p0")

            val byName = LinkedHashMap<String, BotMCPToolDefinition>()
            for (value in upstreamP0) {
                val definition = BotMCPToolDefinition.fromJson(value)
                    ?: throw IllegalArgumentException("tool-catalog.valid.p0 entry has no name")
                byName[definition.name] = definition
            }
            // A phone entry replaces the same upstream name; it never adds a
            // second entry and never reorders the catalog.
            for (value in phoneEntries) {
                val definition = BotMCPToolDefinition.fromJson(value)
                    ?: throw IllegalArgumentException("tool-catalog.phone.valid.p0 entry has no name")
                if (byName.containsKey(definition.name)) byName[definition.name] = definition
            }

            val ordered = ArrayList<BotMCPToolDefinition>()
            var insertedReadMemory = false
            for (definition in byName.values) {
                ordered += definition
                if (definition.name == "UpdateMemory" && !byName.containsKey("ReadMemory")) {
                    ordered += readMemoryDefinition(phone as JsonObject)
                    insertedReadMemory = true
                }
            }
            if (!insertedReadMemory && ordered.none { it.name == "ReadMemory" }) {
                ordered += readMemoryDefinition(phone as JsonObject)
            }

            val p1 = upstreamP1.mapNotNull(BotMCPToolDefinition::fromJson)
            val fish = fishDefinition(phone as JsonObject)
            val volatile = volatileDefinition()
            val team = teamDefinitionsFrom(phone as JsonObject, roster)
            return BotToolCatalog(
                p0 = ordered,
                p1 = p1,
                fishAction = fish,
                volatileContext = volatile,
                attachToModel = attachToModelDefinition(),
                teamBase = team,
                roster = roster,
            )
        }

        /**
         * A catalog assembled from already-parsed definitions. Useful when the
         * app loads the same packaged data through its asset reader.
         */
        public fun fromDefinitions(
            p0: List<BotMCPToolDefinition>,
            p1: List<BotMCPToolDefinition> = emptyList(),
            roster: BotRoster? = null,
        ): BotToolCatalog {
            val phone = JsonObject(emptyMap())
            return BotToolCatalog(
                p0 = p0,
                p1 = p1,
                fishAction = fishDefinition(phone),
                volatileContext = volatileDefinition(),
                attachToModel = attachToModelDefinition(),
                teamBase = defaultTeamDefinitions(),
                roster = roster,
            )
        }

        private fun arrayOfObjects(value: JsonValue?, path: String): List<JsonValue> =
            (value as? JsonArray)?.values
                ?: throw IllegalArgumentException("$path must be an array")

        private fun readMemoryDefinition(phoneRoot: JsonObject): BotMCPToolDefinition {
            val memory = (phoneRoot.members["memory"] as? JsonObject)?.members
            val read = (memory?.get("readMemory") as? JsonObject)?.members
            val properties = (read?.get("properties") as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value }
                ?: listOf("path", "version")
            val required = (read?.get("required") as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value }
                ?: listOf("path")
            val schemaProperties = LinkedHashMap<String, JsonValue>()
            for (property in properties) {
                schemaProperties[property] = when (property) {
                    "version" -> BotJsonObject.of(
                        "type" to JsonString("integer"),
                        "minimum" to JsonNumber("1"),
                    )
                    else -> BotJsonObject.of("type" to JsonString("string"))
                }
            }
            val schema = BotJsonObject.of(
                "type" to JsonString("object"),
                "properties" to JsonObject(schemaProperties),
                "required" to JsonArray(required.map(::JsonString)),
                "additionalProperties" to JsonBool(false),
            )
            return BotMCPToolDefinition(
                name = "ReadMemory",
                description = READ_MEMORY_DESCRIPTION,
                inputSchema = schema,
            )
        }

        private fun fishDefinition(phoneRoot: JsonObject): BotMCPToolDefinition {
            val fish = (phoneRoot.members["fish"] as? JsonObject)?.members
            val actions = (fish?.get("actions") as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value }
                ?: emptyList()
            val expressions = (fish?.get("expressions") as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value }
                ?: emptyList()
            val description = fishActionDescription(actions, expressions)
            val schema = BotJsonObject.of(
                "type" to JsonString("object"),
                "properties" to BotJsonObject.of(
                    "action" to BotJsonObject.of(
                        "type" to JsonString("string"),
                        "enum" to JsonArray((actions + expressions).distinct().map(::JsonString)),
                    ),
                ),
                "required" to JsonArray(listOf(JsonString("action"))),
                "additionalProperties" to JsonBool(false),
            )
            return BotMCPToolDefinition(FISH_ACTION_NAME, description, schema)
        }

        private fun volatileDefinition(): BotMCPToolDefinition = BotMCPToolDefinition(
            name = VOLATILE_CONTEXT_NAME,
            description = "Return only the caller session's current Bot variant, persona, memory and automation snapshot.",
            inputSchema = BotJsonObject.of(
                "type" to JsonString("object"),
                "required" to JsonArray(listOf(JsonString("sessionId"))),
                "properties" to BotJsonObject.of(
                    "sessionId" to BotJsonObject.of(
                        "type" to JsonString("string"),
                        "minLength" to JsonNumber("1"),
                        "maxLength" to JsonNumber("200"),
                    ),
                ),
                "additionalProperties" to JsonBool(false),
            ),
        )

        /**
         * `BotToolCatalog.attachToModelDefinition` in the Swift reference. The
         * description and schema are the frozen P26 contract; the shared P0
         * golden deliberately does not carry them.
         */
        private fun attachToModelDefinition(): BotMCPToolDefinition = BotMCPToolDefinition(
            name = ATTACH_TO_MODEL_NAME,
            description = "Attach one image from the Bot workspace or an Office artifact to the model's " +
                "context so you can actually see it. Pass exactly one of path, fileId or photoId; for a " +
                "PDF pass page (1-8, default 1) to pick the page image; purpose is shown to the user in the " +
                "approval card. The user must approve sending the image to the model service. Use this after " +
                "camera.capture or when a user attached an image and you need its pixels; do not guess from " +
                "metadata alone.",
            inputSchema = BotJsonObject.of(
                "type" to JsonString("object"),
                "properties" to BotJsonObject.of(
                    "path" to BotJsonObject.of("type" to JsonString("string")),
                    "fileId" to BotJsonObject.of("type" to JsonString("string")),
                    "photoId" to BotJsonObject.of("type" to JsonString("string")),
                    "page" to BotJsonObject.of(
                        "type" to JsonString("integer"),
                        "minimum" to JsonNumber("1"),
                        "maximum" to JsonNumber("8"),
                    ),
                    "purpose" to BotJsonObject.of("type" to JsonString("string")),
                ),
                "required" to JsonArray(listOf(JsonString("purpose"))),
                "additionalProperties" to JsonBool(false),
            ),
        )

        private fun teamDefinitionsFrom(
            phoneRoot: JsonObject,
            roster: BotRoster?,
        ): List<BotMCPToolDefinition> {
            val team = (phoneRoot.members["team"] as? JsonObject)?.members
            val send = (team?.get("sendToAgent") as? JsonObject)?.members
            val create = (team?.get("createTeammate") as? JsonObject)?.members
            val sendProperties = (send?.get("properties") as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value }
            val sendRequired = (send?.get("required") as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value }
            val createProperties = (create?.get("properties") as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value }
            val createRequired = (create?.get("required") as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value }
            return listOf(
                BotMCPToolDefinition(
                    name = SEND_TO_AGENT_NAME,
                    description = SEND_TO_AGENT_DESCRIPTION,
                    inputSchema = teamSchema(sendProperties, sendRequired, "sendToAgent"),
                ),
                BotMCPToolDefinition(
                    name = CREATE_TEAMMATE_NAME,
                    description = CREATE_TEAMMATE_DESCRIPTION,
                    inputSchema = teamSchema(createProperties, createRequired, "createTeammate"),
                ),
            )
        }

        private fun defaultTeamDefinitions(): List<BotMCPToolDefinition> = listOf(
            BotMCPToolDefinition(
                SEND_TO_AGENT_NAME,
                SEND_TO_AGENT_DESCRIPTION,
                teamSchema(
                    listOf(
                        "agent_id", "message", "priority", "delivery", "title",
                        "target_id", "bot_name", "agentId", "text",
                    ),
                    listOf("agent_id", "message"),
                    "sendToAgent",
                ),
            ),
            BotMCPToolDefinition(
                CREATE_TEAMMATE_NAME,
                CREATE_TEAMMATE_DESCRIPTION,
                teamSchema(
                    listOf("name", "description", "color", "hairstyle", "section_id"),
                    listOf("name"),
                    "createTeammate",
                ),
            ),
        )

        private fun teamSchema(
            properties: List<String>?,
            required: List<String>?,
            tool: String,
        ): JsonValue {
            val names = properties ?: when (tool) {
                "sendToAgent" -> listOf(
                    "agent_id", "message", "priority", "delivery", "title",
                    "target_id", "bot_name", "agentId", "text",
                )
                else -> listOf("name", "description", "color", "hairstyle", "section_id")
            }
            val fields = LinkedHashMap<String, JsonValue>()
            for (property in names) {
                fields[property] = when (property) {
                    "priority" -> BotJsonObject.of("type" to JsonString("boolean"))
                    "delivery" -> BotJsonObject.of(
                        "type" to JsonString("string"),
                        "enum" to JsonArray(listOf(JsonString("now"), JsonString("queued"))),
                    )
                    "color" -> BotJsonObject.of(
                        "type" to JsonString("string"),
                        "enum" to JsonArray(BotFishColor.entries.map { JsonString(it.wire) }),
                    )
                    "hairstyle" -> BotJsonObject.of(
                        "type" to JsonString("string"),
                        "enum" to JsonArray(BotFishHairstyle.entries.map { JsonString(it.wire) }),
                    )
                    else -> BotJsonObject.of("type" to JsonString("string"))
                }
            }
            val schema = LinkedHashMap<String, JsonValue>()
            schema["type"] = JsonString("object")
            schema["properties"] = JsonObject(fields)
            (required ?: when (tool) {
                "sendToAgent" -> listOf("agent_id", "message")
                else -> listOf("name")
            }).let { schema["required"] = JsonArray(it.map(::JsonString)) }
            if (tool == "createTeammate") schema["additionalProperties"] = JsonBool(false)
            return JsonObject(schema)
        }

        private fun availableBotEntries(roster: BotRoster, callerBotId: String?): List<String> =
            roster.visibleBots.mapNotNull { bot: BotProfile ->
                if (bot.id == callerBotId) return@mapNotNull null
                if (bot.id == roster.mainBotID) {
                    "${bot.name} (id: ${bot.id}, main Bot)"
                } else {
                    "${bot.name} (id: ${bot.id})"
                }
            }

        private fun availableBotsLine(roster: BotRoster, callerBotId: String?): String {
            val entries = availableBotEntries(roster, callerBotId)
            return "Available bots: ${if (entries.isEmpty()) "(none)" else entries.joinToString("; ")}."
        }

        private fun fishActionDescription(actions: List<String>, expressions: List<String>): String {
            val actionList = if (actions.isEmpty()) FISH_ACTIONS.joinToString(", ") else actions.joinToString(", ")
            val expressionList =
                if (expressions.isEmpty()) FISH_EXPRESSIONS.joinToString(", ") else expressions.joinToString(", ")
            return "Play one cosmetic gesture or temporary facial expression on the DS big-fish character. " +
                "Use it at most once per reply, only when the emotional beat genuinely fits (celebration, apology, " +
                "shyness, cheering the user up). It never changes task state, progress, files, approvals or what " +
                "actually happened; never use it as evidence that work is done. Do not use it when the user asks " +
                "for a plain, serious answer. Actions: $actionList. Expressions: $expressionList."
        }

        private const val READ_MEMORY_DESCRIPTION =
            "Read one memory document (optionally a historical version) or list a directory under user/ or " +
                "agent/. Paths and versions come from the same durable authority as the injected INDEX.md."

        private val FISH_ACTIONS: List<String> = listOf(
            "waving", "bowing", "clapping", "kiss", "cheering", "shy", "smug", "crying",
            "sighing", "shaking-head", "stretching", "yawning", "high-five", "nod", "celebrate", "dancing",
        )
        private val FISH_EXPRESSIONS: List<String> = listOf(
            "happy", "sad", "surprised", "confused", "laughing", "love", "angry", "wink",
        )

        private const val SEND_TO_AGENT_DESCRIPTION =
            "Send an asynchronous message to another bot in the roster. The target receives it as a normal new " +
                "turn and answers in its own transcript; its reply later arrives here as an inbound agent-comm row " +
                "on the same thread. You must pass priority or delivery: priority true / delivery \"now\" wakes the " +
                "target now; priority false / delivery \"queued\" holds the message for their next turn and does not " +
                "wake them. Never send to yourself and do not poll for the reply."

        private const val CREATE_TEAMMATE_DESCRIPTION =
            "Create a teammate Bot in this DSH Bot roster. Only the main Bot may call this tool; any other Bot " +
                "receives a permission error. The new Bot gets its own transcript and memory. `section_id` is " +
                "accepted and ignored (sidebar sections are not rendered)."
    }
}

/** A helper shared by the catalog and the identity bodies. */
internal object BotJsonObject {
    fun of(vararg members: Pair<String, JsonValue>): JsonObject = JsonObject(linkedMapOf(*members))
}

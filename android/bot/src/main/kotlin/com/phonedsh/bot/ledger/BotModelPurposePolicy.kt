// SPDX-License-Identifier: MIT
package com.phonedsh.bot.ledger

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

/**
 * One model purpose (`llm-ledger.schema.json` and
 * `model-purpose-policy.schema.json`). The wire order is the schema enum
 * order; `memory-maintenance` is the P25 additive phone purpose.
 */
public enum class BotModelPurpose(
    public val wire: String,
    public val largeModelAllowed: Boolean,
) {
    FRONT_TURN("front-turn", true),
    WORKER_TURN("worker-turn", true),
    TRIAGE("triage", false),
    MEMORY_EXTRACT("memory-extract", false),
    REFLECT("reflect", false),
    COMPACT("compact", false),
    WATCHDOG("watchdog", false),
    COMPLETION_CHECK("completion-check", false),
    MEMORY_MAINTENANCE("memory-maintenance", false),
    ;

    /**
     * The `ledger.usage_recorded` principal kind for this purpose
     * (`BotLLMLedger.swift:29-35`): worker turns are `task`, watchdogs are
     * `watchdog`, maintainer runs are `maintainer`, everything else is `chat`.
     */
    public val principalKind: String
        get() = when (this) {
            WORKER_TURN -> "task"
            WATCHDOG -> "watchdog"
            MEMORY_MAINTENANCE -> "maintainer"
            else -> "chat"
        }

    public companion object {
        public fun parse(value: String?): BotModelPurpose? =
            entries.firstOrNull { it.wire == value }
    }
}

/** Per-purpose model/max-tokens/temperature defaults. */
public data class BotModelPurposeDefaults(
    public val model: String,
    public val maxTokens: Int,
    public val temperature: Double,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "model" to JsonString(model),
            "maxTokens" to BotLedgerJson.number(maxTokens.toLong()),
            "temperature" to BotLedgerJson.number(temperature),
        ),
    )

    public companion object {
        public fun fromJson(value: JsonValue?, path: String = "defaults"): BotModelPurposeDefaults {
            val members = BotLedgerJson.objectMembers(value, path)
            BotLedgerJson.rejectUnknown(members, path, setOf("model", "maxTokens", "temperature"))
            val model = BotLedgerJson.string(members["model"], "$path.model")
            if (model.isEmpty()) {
                throw BotLLMLedgerException("$path.model", "model must not be empty")
            }
            val maxTokens = BotLedgerJson.integer(members["maxTokens"], "$path.maxTokens")
            if (maxTokens < 1) {
                throw BotLLMLedgerException("$path.maxTokens", "must be at least 1")
            }
            val temperature = BotLedgerJson.number(members["temperature"], "$path.temperature")
            if (temperature < 0.0) {
                throw BotLLMLedgerException("$path.temperature", "must not be negative")
            }
            return BotModelPurposeDefaults(model = model, maxTokens = maxTokens, temperature = temperature)
        }
    }
}

/** One `purposes[]` row of the frozen policy. */
public data class BotModelPurposeRow(
    public val purpose: BotModelPurpose,
    public val largeModelAllowed: Boolean,
    public val defaults: BotModelPurposeDefaults,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "purpose" to JsonString(purpose.wire),
            "largeModelAllowed" to JsonBool(largeModelAllowed),
            "defaults" to defaults.toJson(),
        ),
    )

    public companion object {
        public fun fromJson(value: JsonValue?, path: String): BotModelPurposeRow {
            val members = BotLedgerJson.objectMembers(value, path)
            BotLedgerJson.rejectUnknown(
                members,
                path,
                setOf("purpose", "largeModelAllowed", "defaults"),
            )
            val purposeText = BotLedgerJson.string(members["purpose"], "$path.purpose")
            val purpose = BotModelPurpose.parse(purposeText)
                ?: throw BotLLMLedgerException("$path.purpose", "unknown purpose: $purposeText")
            return BotModelPurposeRow(
                purpose = purpose,
                largeModelAllowed = BotLedgerJson.boolean(
                    members["largeModelAllowed"],
                    "$path.largeModelAllowed",
                ),
                defaults = BotModelPurposeDefaults.fromJson(members["defaults"], "$path.defaults"),
            )
        }
    }
}

/** Two-variant model tier (`BotModelPurposePolicy.swift:101-114`). */
public enum class BotModelTier { SMALL, LARGE, UNKNOWN }

/**
 * The frozen model-purpose policy (`model-purpose-policy.schema.json`,
 * `BotModelPurposePolicy.swift`).
 *
 * `frozen` carries nine purposes: the eight rows exported in the shared
 * upstream golden plus the phone-additive `memory-maintenance` row. The
 * decoder accepts the upstream eight-row fixture (and any other schema-valid
 * row set) because the golden is the authority for shared rows; it does not
 * synthesize the ninth row from the fixture.
 */
public data class BotModelPurposePolicy(
    public val purposes: List<BotModelPurposeRow>,
    public val largeModelPurposes: List<BotModelPurpose>,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "purposes" to JsonArray(purposes.map { it.toJson() }),
            "largeModelPurposes" to JsonArray(largeModelPurposes.map { JsonString(it.wire) }),
        ),
    )

    public companion object {
        public const val SMALL_MODEL: String = "deepseek-flash"
        public const val LARGE_MODEL: String = "deepseek-v4-pro"

        private val largeModels: Set<String> =
            setOf(LARGE_MODEL, "deepseek-pro", "deepseek-reasoner", "deepseek-chat")

        private val largeSuffix: Regex =
            Regex("(?:^|[-_/])(pro|reasoner|max|opus)(?:\$|[-_.:/])")

        public val frozen: BotModelPurposePolicy = BotModelPurposePolicy(
            purposes = BotModelPurpose.entries.map { purpose ->
                BotModelPurposeRow(
                    purpose = purpose,
                    largeModelAllowed = purpose.largeModelAllowed,
                    defaults = defaults(purpose),
                )
            },
            largeModelPurposes = listOf(BotModelPurpose.FRONT_TURN, BotModelPurpose.WORKER_TURN),
        )

        public fun allowsLargeModel(purpose: BotModelPurpose): Boolean =
            purpose.largeModelAllowed

        /** Exact `model-purpose-policy.json` rows plus the phone-only maintenance row. */
        public fun defaults(purpose: BotModelPurpose): BotModelPurposeDefaults = when (purpose) {
            BotModelPurpose.FRONT_TURN, BotModelPurpose.WORKER_TURN ->
                BotModelPurposeDefaults(model = SMALL_MODEL, maxTokens = 8_192, temperature = 1.0)
            BotModelPurpose.TRIAGE, BotModelPurpose.WATCHDOG, BotModelPurpose.COMPLETION_CHECK ->
                BotModelPurposeDefaults(model = SMALL_MODEL, maxTokens = 256, temperature = 0.0)
            BotModelPurpose.MEMORY_MAINTENANCE ->
                BotModelPurposeDefaults(model = SMALL_MODEL, maxTokens = 4_096, temperature = 0.0)
            BotModelPurpose.MEMORY_EXTRACT ->
                BotModelPurposeDefaults(model = SMALL_MODEL, maxTokens = 1_024, temperature = 0.0)
            BotModelPurpose.REFLECT ->
                BotModelPurposeDefaults(model = SMALL_MODEL, maxTokens = 1_024, temperature = 0.7)
            BotModelPurpose.COMPACT ->
                BotModelPurposeDefaults(model = SMALL_MODEL, maxTokens = 2_048, temperature = 0.0)
        }

        /**
         * Trims [model]; an empty model fails `EPURPOSE_MODEL_REQUIRED`, and a
         * non-large purpose whose model is not a known small model fails
         * `EPURPOSE_MODEL_DENIED` (`BotModelPurposePolicy.swift:82-99`).
         */
        public fun assertModelAllowed(purpose: BotModelPurpose, model: String): String {
            val normalized = model.trim()
            if (normalized.isEmpty()) {
                throw BotModelPurposeException(
                    code = "EPURPOSE_MODEL_REQUIRED",
                    purpose = purpose,
                    model = model,
                    message = "model must be a non-empty string",
                )
            }
            if (!purpose.largeModelAllowed && modelTier(normalized) != BotModelTier.SMALL) {
                throw BotModelPurposeException(
                    code = "EPURPOSE_MODEL_DENIED",
                    purpose = purpose,
                    model = normalized,
                    message = "purpose \"${purpose.wire}\" requires a known small model",
                )
            }
            return normalized
        }

        public fun modelTier(model: String): BotModelTier {
            val normalized = model.trim().lowercase()
            if (normalized.isEmpty()) return BotModelTier.UNKNOWN
            if (normalized == SMALL_MODEL || normalized.startsWith("$SMALL_MODEL-")) {
                return BotModelTier.SMALL
            }
            if (normalized in largeModels) return BotModelTier.LARGE
            if (largeSuffix.containsMatchIn(normalized)) return BotModelTier.LARGE
            return BotModelTier.UNKNOWN
        }

        public fun fromJson(value: JsonValue): BotModelPurposePolicy {
            val members = BotLedgerJson.objectMembers(value, "policy")
            BotLedgerJson.rejectUnknown(
                members,
                "policy",
                setOf("purposes", "largeModelPurposes"),
            )
            val purposeValues = BotLedgerJson.array(members["purposes"], "purposes")
            if (purposeValues.size < 8) {
                throw BotLLMLedgerException("purposes", "must contain at least 8 rows")
            }
            val purposes = purposeValues.mapIndexed { index, row ->
                BotModelPurposeRow.fromJson(row, "purposes[$index]")
            }
            val largeValues = BotLedgerJson.array(
                members["largeModelPurposes"],
                "largeModelPurposes",
            )
            if (largeValues.size != 2) {
                throw BotLLMLedgerException("largeModelPurposes", "must contain exactly 2 purposes")
            }
            val large = largeValues.mapIndexed { index, item ->
                val path = "largeModelPurposes[$index]"
                val text = BotLedgerJson.string(item, path)
                val purpose = BotModelPurpose.parse(text)
                    ?: throw BotLLMLedgerException(path, "unknown purpose: $text")
                if (purpose != BotModelPurpose.FRONT_TURN && purpose != BotModelPurpose.WORKER_TURN) {
                    throw BotLLMLedgerException(path, "only front-turn and worker-turn may use a large model")
                }
                purpose
            }
            return BotModelPurposePolicy(purposes = purposes, largeModelPurposes = large)
        }

        public fun decode(json: String): BotModelPurposePolicy {
            val parsed = try {
                JsonValue.parse(json)
            } catch (error: Exception) {
                throw BotLLMLedgerException("policy", "policy is not valid JSON", error)
            }
            return fromJson(parsed)
        }
    }
}

/** A model-purpose gate rejection with the stable `EPURPOSE_*` code. */
public class BotModelPurposeException(
    public val code: String,
    public val purpose: BotModelPurpose,
    public val model: String,
    message: String,
) : Exception(message)

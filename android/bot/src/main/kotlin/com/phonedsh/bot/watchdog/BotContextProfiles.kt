// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException

/**
 * Context profiles are read-only DSH compaction data (`observability.md` §1).
 * The Bot runtime never runs compaction; these values exist only for display
 * and validation, and the unknown-profile fallback is a parse rule.
 */
public enum class BotContextProfileName(public val wireValue: String) {
    DEFAULT("default"),
    CONSERVATIVE("conservative");

    public companion object {
        public val default: BotContextProfileName get() = DEFAULT
        public val conservative: BotContextProfileName get() = CONSERVATIVE

        public fun resolve(requested: String?): BotContextProfileName {
            val normalized = requested?.trim()?.lowercase().orEmpty()
            return values().firstOrNull { it.wireValue == normalized } ?: DEFAULT
        }
    }
}

public data class BotContextCompaction(
    public val auto: Boolean,
    public val thresholdRatio: Double,
    public val headroomTokens: Long,
    public val retainRatio: Double,
    public val maxTokens: Long,
    public val summarizationProvider: String,
    public val summarizationModel: String,
    public val compactionRetries: Long,
    public val maxOverflowRetries: Long,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "auto" to JsonBool(auto),
            "thresholdRatio" to number(thresholdRatio),
            "headroomTokens" to number(headroomTokens),
            "retainRatio" to number(retainRatio),
            "maxTokens" to number(maxTokens),
            "summarizationProvider" to JsonString(summarizationProvider),
            "summarizationModel" to JsonString(summarizationModel),
            "compactionRetries" to number(compactionRetries),
            "maxOverflowRetries" to number(maxOverflowRetries),
        ),
    )
}

public data class BotContextPruner(
    public val thresholdChars: Long,
    public val headChars: Long,
    public val tailChars: Long,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "thresholdChars" to number(thresholdChars),
            "headChars" to number(headChars),
            "tailChars" to number(tailChars),
        ),
    )
}

public data class BotContextSpillPolicy(public val maxInlineTokens: Long) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf("maxInlineTokens" to number(maxInlineTokens)),
    )
}

public data class BotContextSpillLocal(public val cleanupPeriodDays: Long) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf("cleanupPeriodDays" to number(cleanupPeriodDays)),
    )
}

public data class BotContextProfile(
    public val compaction: BotContextCompaction,
    public val pruner: BotContextPruner,
    public val spillPolicy: BotContextSpillPolicy,
    public val spillLocal: BotContextSpillLocal,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "compaction" to compaction.toJson(),
            "pruner" to pruner.toJson(),
            "spillPolicy" to spillPolicy.toJson(),
            "spillLocal" to spillLocal.toJson(),
        ),
    )

    public companion object {
        public val default: BotContextProfile get() = DEFAULT
        public val conservative: BotContextProfile get() = CONSERVATIVE

        public val DEFAULT: BotContextProfile = BotContextProfile(
            compaction = BotContextCompaction(
                auto = true,
                thresholdRatio = 0.8,
                headroomTokens = 65_536,
                retainRatio = 0.16,
                maxTokens = 65_536,
                summarizationProvider = "",
                summarizationModel = "",
                compactionRetries = 1,
                maxOverflowRetries = 1,
            ),
            pruner = BotContextPruner(thresholdChars = 8_192, headChars = 4_096, tailChars = 1_024),
            spillPolicy = BotContextSpillPolicy(maxInlineTokens = 12_500),
            spillLocal = BotContextSpillLocal(cleanupPeriodDays = 30),
        )

        public val CONSERVATIVE: BotContextProfile = BotContextProfile(
            compaction = BotContextCompaction(
                auto = true,
                thresholdRatio = 0.4,
                headroomTokens = 32_768,
                retainRatio = 0.12,
                maxTokens = 32_768,
                summarizationProvider = "",
                summarizationModel = "",
                compactionRetries = 1,
                maxOverflowRetries = 1,
            ),
            pruner = BotContextPruner(thresholdChars = 4_096, headChars = 2_048, tailChars = 512),
            spillPolicy = BotContextSpillPolicy(maxInlineTokens = 4_096),
            spillLocal = BotContextSpillLocal(cleanupPeriodDays = 30),
        )

        public fun named(name: BotContextProfileName): BotContextProfile = when (name) {
            BotContextProfileName.DEFAULT -> DEFAULT
            BotContextProfileName.CONSERVATIVE -> CONSERVATIVE
        }
    }
}

public data class BotContextProfilePair(
    public val default: BotContextProfile,
    public val conservative: BotContextProfile,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "default" to default.toJson(),
            "conservative" to conservative.toJson(),
        ),
    )

    public companion object {
        public val FROZEN: BotContextProfilePair = BotContextProfilePair(
            BotContextProfile.DEFAULT,
            BotContextProfile.CONSERVATIVE,
        )
        public val frozen: BotContextProfilePair get() = FROZEN
    }
}

public data class BotContextProfileYAMLPair(
    public val default: String,
    public val conservative: String,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "default" to JsonString(default),
            "conservative" to JsonString(conservative),
        ),
    )

    public companion object {
        public val FROZEN: BotContextProfileYAMLPair = BotContextProfileYAMLPair(
            BotContextProfileYAML.render(BotContextProfileName.DEFAULT, BotContextProfile.DEFAULT),
            BotContextProfileYAML.render(
                BotContextProfileName.CONSERVATIVE,
                BotContextProfile.CONSERVATIVE,
            ),
        )
        public val frozen: BotContextProfileYAMLPair get() = FROZEN
    }
}

public data class BotContextProfileDocument(
    public val profiles: BotContextProfilePair,
    public val yaml: BotContextProfileYAMLPair,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "profiles" to profiles.toJson(),
            "yaml" to yaml.toJson(),
        ),
    )

    public companion object {
        public val FROZEN: BotContextProfileDocument = BotContextProfileDocument(
            BotContextProfilePair.FROZEN,
            BotContextProfileYAMLPair.FROZEN,
        )
        public val frozen: BotContextProfileDocument get() = FROZEN

        public fun fromJson(value: JsonValue): BotContextProfileDocument {
            val root = objectOf(value, "profiles document")
            val profiles = objectOf(root["profiles"], "profiles")
            val yaml = objectOf(root["yaml"], "yaml")
            return BotContextProfileDocument(
                profiles = BotContextProfilePair(
                    decodeProfile(objectOf(profiles["default"], "profiles.default")),
                    decodeProfile(objectOf(profiles["conservative"], "profiles.conservative")),
                ),
                yaml = BotContextProfileYAMLPair(
                    stringOf(yaml["default"], "yaml.default"),
                    stringOf(yaml["conservative"], "yaml.conservative"),
                ),
            )
        }

        private fun decodeProfile(value: Map<String, JsonValue>): BotContextProfile {
            val compaction = objectOf(value["compaction"], "compaction")
            val pruner = objectOf(value["pruner"], "pruner")
            val spillPolicy = objectOf(value["spillPolicy"], "spillPolicy")
            val spillLocal = objectOf(value["spillLocal"], "spillLocal")
            return BotContextProfile(
                compaction = BotContextCompaction(
                    auto = boolOf(compaction["auto"], "compaction.auto"),
                    thresholdRatio = doubleOf(compaction["thresholdRatio"], "compaction.thresholdRatio"),
                    headroomTokens = longOf(compaction["headroomTokens"], "compaction.headroomTokens"),
                    retainRatio = doubleOf(compaction["retainRatio"], "compaction.retainRatio"),
                    maxTokens = longOf(compaction["maxTokens"], "compaction.maxTokens"),
                    summarizationProvider = stringOf(
                        compaction["summarizationProvider"], "compaction.summarizationProvider",
                    ),
                    summarizationModel = stringOf(
                        compaction["summarizationModel"], "compaction.summarizationModel",
                    ),
                    compactionRetries = longOf(
                        compaction["compactionRetries"], "compaction.compactionRetries",
                    ),
                    maxOverflowRetries = longOf(
                        compaction["maxOverflowRetries"], "compaction.maxOverflowRetries",
                    ),
                ),
                pruner = BotContextPruner(
                    thresholdChars = longOf(pruner["thresholdChars"], "pruner.thresholdChars"),
                    headChars = longOf(pruner["headChars"], "pruner.headChars"),
                    tailChars = longOf(pruner["tailChars"], "pruner.tailChars"),
                ),
                spillPolicy = BotContextSpillPolicy(
                    maxInlineTokens = longOf(
                        spillPolicy["maxInlineTokens"], "spillPolicy.maxInlineTokens",
                    ),
                ),
                spillLocal = BotContextSpillLocal(
                    cleanupPeriodDays = longOf(
                        spillLocal["cleanupPeriodDays"], "spillLocal.cleanupPeriodDays",
                    ),
                ),
            )
        }

        private fun objectOf(value: JsonValue?, path: String): Map<String, JsonValue> =
            (value as? JsonObject)?.members ?: throw BotJsonException("$path must be an object")

        private fun stringOf(value: JsonValue?, path: String): String =
            (value as? JsonString)?.value ?: throw BotJsonException("$path must be a string")

        private fun longOf(value: JsonValue?, path: String): Long =
            (value as? JsonNumber)?.asLongOrNull()
                ?: throw BotJsonException("$path must be an integer")

        private fun doubleOf(value: JsonValue?, path: String): Double =
            (value as? JsonNumber)?.raw?.toDoubleOrNull()
                ?: throw BotJsonException("$path must be a number")

        private fun boolOf(value: JsonValue?, path: String): Boolean =
            (value as? JsonBool)?.value ?: throw BotJsonException("$path must be a boolean")
    }
}

public object BotContextProfileYAML {
    public fun render(name: BotContextProfileName, profile: BotContextProfile): String {
        val compaction = profile.compaction
        return listOf(
            "# M5 上下文工程：顯式寫出 compaction / pruner / spill 設定（contextProfile=${name.wireValue}）。",
            "# 數值與理由見 docs/upgrade/context-tuning.md；patch 會整段取代 bundle 預設 config。",
            "- id: compaction-basic",
            "  config:",
            "    auto: ${compaction.auto}",
            "    thresholdRatio: ${yamlNumber(compaction.thresholdRatio)}",
            "    headroomTokens: ${compaction.headroomTokens}",
            "    retainRatio: ${yamlNumber(compaction.retainRatio)}",
            "    maxTokens: ${compaction.maxTokens}",
            "    summarizationProvider: ${jsonString(compaction.summarizationProvider)}",
            "    summarizationModel: ${jsonString(compaction.summarizationModel)}",
            "    compactionRetries: ${compaction.compactionRetries}",
            "    maxOverflowRetries: ${compaction.maxOverflowRetries}",
            "    modelPolicies: []",
            "- id: tool-result-pruner",
            "  config:",
            "    thresholdChars: ${profile.pruner.thresholdChars}",
            "    headChars: ${profile.pruner.headChars}",
            "    tailChars: ${profile.pruner.tailChars}",
            "- id: spill-policy",
            "  config:",
            "    maxInlineTokens: ${profile.spillPolicy.maxInlineTokens}",
            "- id: spill-local",
            "  config:",
            "    cleanupPeriodDays: ${profile.spillLocal.cleanupPeriodDays}",
            "",
        ).joinToString("\n")
    }

    private fun yamlNumber(value: Double): String =
        if (value == Math.rint(value)) value.toLong().toString() else value.toString()

    private fun jsonString(value: String): String = BotJson.canonical(JsonString(value))
}

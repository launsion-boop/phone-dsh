// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import java.net.URI
import java.text.BreakIterator

/**
 * The 60-UTF-16-code-unit name cap (`ui-state.md` §4.10). [capped] walks
 * grapheme clusters so an emoji or combining sequence is never split; the
 * store rule ([problem]) is the same two rejections, so a client-side cap
 * never weakens it.
 */
public object BotNameValidation {
    public const val MAX_UTF16_UNITS: Int = 60

    public fun trimmed(name: String): String = name.trim()

    /** `名称不能为空。` / `名称最多 60 个字符，当前 <n> 个。` / null. */
    public fun problem(name: String): String? {
        val value = trimmed(name)
        if (value.isEmpty()) return BotUiStrings.VALIDATION_NAME_EMPTY
        if (value.length > MAX_UTF16_UNITS) {
            return BotUiStrings.format(
                "validation.name.tooLong",
                "max" to MAX_UTF16_UNITS,
                "count" to value.length,
            )
        }
        return null
    }

    public fun isValid(name: String): Boolean = problem(name) == null

    /** The trimmed name when it passes, else null. */
    public fun normalized(name: String): String? =
        if (isValid(name)) trimmed(name) else null

    /** Appends whole grapheme clusters while the UTF-16 budget allows. */
    public fun capped(name: String): String {
        if (name.length <= MAX_UTF16_UNITS) return name
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(name)
        val out = StringBuilder()
        var units = 0
        var start = iterator.first()
        var end = iterator.next()
        while (end != BreakIterator.DONE) {
            val cluster = name.substring(start, end)
            if (units + cluster.length > MAX_UTF16_UNITS) break
            out.append(cluster)
            units += cluster.length
            start = end
            end = iterator.next()
        }
        return out.toString()
    }
}

/** `phonedsh://bot/<botID>/<row|routine>/<id>` (`ui-state.md` §2.6/§4.13). */
public sealed interface BotDeepLinkDestination {
    public val id: String

    public data class Row(override val id: String) : BotDeepLinkDestination
    public data class Routine(override val id: String) : BotDeepLinkDestination
}

/** A parsed deep link value. */
public data class BotDeepLink(
    public val botID: String,
    public val destination: BotDeepLinkDestination,
) {
    public val rowID: String? get() = (destination as? BotDeepLinkDestination.Row)?.id
    public val routineID: String? get() = (destination as? BotDeepLinkDestination.Routine)?.id

    public fun toJson(): JsonObject = BotJson.objectOf(
        "botID" to JsonString(botID),
        "destination" to BotJson.objectOf(
            "kind" to JsonString(
                if (destination is BotDeepLinkDestination.Row) "row" else "routine"),
            "id" to JsonString(destination.id),
        ),
    )

    public companion object {
        /** Parses the frozen URL form; anything else is null, never a fallback. */
        public fun parse(url: String): BotDeepLink? {
            val uri = try {
                URI(url)
            } catch (_: Exception) {
                return null
            }
            if (uri.scheme?.lowercase() != "phonedsh") return null
            if (uri.rawAuthority != "bot") return null
            val path = uri.path ?: return null
            val components = path.split('/').filter { it.isNotEmpty() }
            if (components.size != 3) return null
            val botID = components[0]
            val id = components[2]
            if (botID.isEmpty() || id.isEmpty()) return null
            val destination = when (components[1]) {
                "row" -> BotDeepLinkDestination.Row(id)
                "routine" -> BotDeepLinkDestination.Routine(id)
                else -> return null
            }
            return BotDeepLink(botID, destination)
        }

        /** Reads the already-parsed value vector form. */
        public fun fromJson(value: JsonValue): BotDeepLink {
            val members = JsonSupport.objectMembers(value, "deepLink")
            val botID = JsonSupport.requiredString(members, "botID", "deepLink.botID")
            if (botID.isEmpty()) throw BotJsonException("deepLink.botID must not be empty")
            val destination = JsonSupport.objectMembers(
                members["destination"] ?: throw BotJsonException("missing destination"),
                "deepLink.destination",
            )
            val id = JsonSupport.requiredString(destination, "id", "destination.id")
            if (id.isEmpty()) throw BotJsonException("destination.id must not be empty")
            val resolved = when (val kind = JsonSupport.requiredString(
                destination, "kind", "destination.kind")) {
                "row" -> BotDeepLinkDestination.Row(id)
                "routine" -> BotDeepLinkDestination.Routine(id)
                else -> throw BotJsonException("unknown deep-link destination kind: $kind")
            }
            return BotDeepLink(botID, resolved)
        }
    }
}

/** The routing outcome of a deep link (`ui-state.md` §4.13). */
public sealed interface BotDeepLinkOutcome {
    /** Scroll the chat to this visible row. */
    public data class ScrollToRow(public val rowID: String) : BotDeepLinkOutcome

    /** The hub selects the Bot and opens the info routine section. */
    public data class OpenRoutine(
        public val botID: String,
        public val routineID: String,
    ) : BotDeepLinkOutcome

    /** Not a `phonedsh://bot/...` link. */
    public data object Invalid : BotDeepLinkOutcome

    /** A row/routine that is not available on this page (show the unavailable copy). */
    public data object Unavailable : BotDeepLinkOutcome
}

/** Deep-link routing: `main` always resolves through the roster pointer. */
public object BotDeepLinkResolution {
    public fun resolve(
        url: String,
        pageBotID: String,
        visibleRowIDs: Collection<String>,
        mainBotID: String?,
        routineIDs: Set<String>? = null,
    ): BotDeepLinkOutcome {
        val link = BotDeepLink.parse(url) ?: return BotDeepLinkOutcome.Invalid
        return resolve(link, pageBotID, visibleRowIDs, mainBotID, routineIDs)
    }

    public fun resolve(
        link: BotDeepLink,
        pageBotID: String,
        visibleRowIDs: Collection<String>,
        mainBotID: String?,
        routineIDs: Set<String>? = null,
    ): BotDeepLinkOutcome {
        val botID = if (link.botID == "main") mainBotID ?: return BotDeepLinkOutcome.Unavailable
        else link.botID
        if (botID != pageBotID) return BotDeepLinkOutcome.Unavailable
        return when (val destination = link.destination) {
            is BotDeepLinkDestination.Row ->
                if (destination.id in visibleRowIDs) {
                    BotDeepLinkOutcome.ScrollToRow(destination.id)
                } else {
                    BotDeepLinkOutcome.Unavailable
                }
            is BotDeepLinkDestination.Routine -> {
                if (routineIDs != null && destination.id !in routineIDs) {
                    BotDeepLinkOutcome.Unavailable
                } else {
                    BotDeepLinkOutcome.OpenRoutine(botID, destination.id)
                }
            }
        }
    }
}

/** The drawer intent vocabulary (`ui-state.md` §3.2). */
public sealed interface BotDrawerIntent {
    public data class Select(public val botID: String) : BotDrawerIntent
    public data class Create(
        public val name: String,
        public val color: BotFishColor,
        public val hairstyle: BotFishHairstyle,
    ) : BotDrawerIntent
    public data class Rename(public val botID: String, public val name: String) : BotDrawerIntent
    public data class SetMain(public val botID: String) : BotDrawerIntent
    public data class SetHidden(public val botID: String, public val hidden: Boolean) : BotDrawerIntent
    public data class Delete(public val botID: String) : BotDrawerIntent
    public data class Appearance(public val botID: String) : BotDrawerIntent
    public data object Manage : BotDrawerIntent
    public data object Retry : BotDrawerIntent
    public data object Close : BotDrawerIntent

    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        when (this) {
            is Select -> {
                members["kind"] = JsonString("select"); members["botID"] = JsonString(botID)
            }
            is Create -> {
                members["kind"] = JsonString("create")
                members["name"] = JsonString(name)
                members["color"] = JsonString(color.wire)
                members["hairstyle"] = JsonString(hairstyle.wire)
            }
            is Rename -> {
                members["kind"] = JsonString("rename")
                members["botID"] = JsonString(botID)
                members["name"] = JsonString(name)
            }
            is SetMain -> {
                members["kind"] = JsonString("setMain"); members["botID"] = JsonString(botID)
            }
            is SetHidden -> {
                members["kind"] = JsonString("setHidden")
                members["botID"] = JsonString(botID)
                members["hidden"] = com.phonedsh.agentcore.JsonBool(hidden)
            }
            is Delete -> {
                members["kind"] = JsonString("delete"); members["botID"] = JsonString(botID)
            }
            is Appearance -> {
                members["kind"] = JsonString("appearance")
                members["botID"] = JsonString(botID)
            }
            Manage -> members["kind"] = JsonString("manage")
            Retry -> members["kind"] = JsonString("retry")
            Close -> members["kind"] = JsonString("close")
        }
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue): BotDrawerIntent {
            val members = JsonSupport.objectMembers(value, "drawerIntent")
            return when (val kind = JsonSupport.requiredString(
                members, "kind", "drawerIntent.kind")) {
                "select" -> Select(requiredBotID(members))
                "create" -> {
                    val name = JsonSupport.requiredString(members, "name", "drawerIntent.name")
                    if (!BotNameValidation.isValid(name)) {
                        throw BotJsonException("drawerIntent.name is not a valid Bot name")
                    }
                    Create(
                        name = name,
                        color = BotFishColor.fromWire(
                            JsonSupport.requiredString(members, "color", "drawerIntent.color"))
                            ?: throw BotJsonException("drawerIntent.color has unknown value"),
                        hairstyle = BotFishHairstyle.fromWire(
                            JsonSupport.requiredString(
                                members, "hairstyle", "drawerIntent.hairstyle"))
                            ?: throw BotJsonException("drawerIntent.hairstyle has unknown value"),
                    )
                }
                "rename" -> {
                    val botID = requiredBotID(members)
                    val name = JsonSupport.requiredString(members, "name", "drawerIntent.name")
                    if (!BotNameValidation.isValid(name)) {
                        throw BotJsonException("drawerIntent.name is not a valid Bot name")
                    }
                    Rename(botID, name)
                }
                "setMain" -> SetMain(requiredBotID(members))
                "setHidden" -> SetHidden(
                    requiredBotID(members),
                    JsonSupport.requiredBool(members, "hidden", "drawerIntent.hidden"),
                )
                "delete" -> Delete(requiredBotID(members))
                "appearance" -> Appearance(requiredBotID(members))
                "manage" -> Manage
                "retry" -> Retry
                "close" -> Close
                else -> throw BotJsonException("unknown drawer intent kind: $kind")
            }
        }

        private fun requiredBotID(members: Map<String, JsonValue>): String {
            val botID = JsonSupport.requiredString(members, "botID", "drawerIntent.botID")
            if (botID.isEmpty()) throw BotJsonException("drawerIntent.botID must not be empty")
            return botID
        }
    }
}

/** `resolveReconciliation.decision` (`info-intent.schema.json`). */
public enum class BotReconciliationDecision(public val wire: String) {
    ACKNOWLEDGE("acknowledge"),
    RETRY("retry"),
    ;

    public companion object {
        public fun fromWire(value: String): BotReconciliationDecision =
            entries.firstOrNull { it.wire == value }
                ?: throw BotJsonException("unknown reconciliation decision: $value")
    }
}

/** The info-page intent vocabulary (`ui-state.md` §3.5). */
public sealed interface BotInfoIntent {
    public data object Load : BotInfoIntent
    public data class Rename(public val name: String) : BotInfoIntent
    public data class Forget(public val documentPath: String, public val version: Long) : BotInfoIntent
    public data class EraseDocument(public val documentPath: String) : BotInfoIntent
    public data object Erase : BotInfoIntent
    public data object EraseShared : BotInfoIntent
    public data class SetRoutineEnabled(
        public val routineID: String,
        public val enabled: Boolean,
    ) : BotInfoIntent
    public data class RevokeGrant(public val grantID: String) : BotInfoIntent
    public data class CancelRoutine(public val routineID: String) : BotInfoIntent
    public data class ResolveReconciliation(
        public val routineID: String,
        public val decision: BotReconciliationDecision,
    ) : BotInfoIntent
    public data class SaveProactiveSettings(
        public val settings: ProactiveSettings,
    ) : BotInfoIntent
    public data class SetMaintenanceEnabled(public val enabled: Boolean) : BotInfoIntent
    public data class RollbackMaintenance(public val batchID: String) : BotInfoIntent

    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        fun kind(name: String) {
            members["kind"] = JsonString(name)
        }
        when (this) {
            Load -> kind("load")
            is Rename -> {
                kind("rename"); members["name"] = JsonString(name)
            }
            is Forget -> {
                kind("forget")
                members["documentPath"] = JsonString(documentPath)
                members["version"] = BotJson.number(version)
            }
            is EraseDocument -> {
                kind("eraseDocument"); members["documentPath"] = JsonString(documentPath)
            }
            Erase -> kind("erase")
            EraseShared -> kind("eraseShared")
            is SetRoutineEnabled -> {
                kind("setRoutineEnabled")
                members["routineID"] = JsonString(routineID)
                members["enabled"] = com.phonedsh.agentcore.JsonBool(enabled)
            }
            is RevokeGrant -> {
                kind("revokeGrant"); members["grantID"] = JsonString(grantID)
            }
            is CancelRoutine -> {
                kind("cancelRoutine"); members["routineID"] = JsonString(routineID)
            }
            is ResolveReconciliation -> {
                kind("resolveReconciliation")
                members["routineID"] = JsonString(routineID)
                members["decision"] = JsonString(decision.wire)
            }
            is SaveProactiveSettings -> {
                kind("saveProactiveSettings")
                members["settings"] = BotJson.objectOf(
                    "mode" to JsonString(settings.mode.wire),
                    "dnd" to com.phonedsh.agentcore.JsonBool(settings.dnd),
                    "quietStart" to JsonString(settings.quietStart),
                    "quietEnd" to JsonString(settings.quietEnd),
                    "routineQuietWeekends" to
                        com.phonedsh.agentcore.JsonBool(settings.routineQuietWeekends),
                    "timeZone" to JsonString(settings.timeZone),
                )
            }
            is SetMaintenanceEnabled -> {
                kind("setMaintenanceEnabled")
                members["enabled"] = com.phonedsh.agentcore.JsonBool(enabled)
            }
            is RollbackMaintenance -> {
                kind("rollbackMaintenance"); members["batchID"] = JsonString(batchID)
            }
        }
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue): BotInfoIntent {
            val members = JsonSupport.objectMembers(value, "infoIntent")
            return when (val kind = JsonSupport.requiredString(
                members, "kind", "infoIntent.kind")) {
                "load" -> Load
                "rename" -> {
                    val name = JsonSupport.requiredString(members, "name", "infoIntent.name")
                    if (!BotNameValidation.isValid(name)) {
                        throw BotJsonException("infoIntent.name is not a valid Bot name")
                    }
                    Rename(name)
                }
                "forget" -> Forget(
                    requiredId(members, "documentPath"),
                    JsonSupport.requiredNonNegativeLong(members, "version", "infoIntent.version"),
                )
                "eraseDocument" -> EraseDocument(requiredId(members, "documentPath"))
                "erase" -> Erase
                "eraseShared" -> EraseShared
                "setRoutineEnabled" -> SetRoutineEnabled(
                    requiredId(members, "routineID"),
                    JsonSupport.requiredBool(members, "enabled", "infoIntent.enabled"),
                )
                "revokeGrant" -> RevokeGrant(requiredId(members, "grantID"))
                "cancelRoutine" -> CancelRoutine(requiredId(members, "routineID"))
                "resolveReconciliation" -> ResolveReconciliation(
                    requiredId(members, "routineID"),
                    BotReconciliationDecision.fromWire(
                        JsonSupport.requiredString(members, "decision", "infoIntent.decision")),
                )
                "saveProactiveSettings" -> SaveProactiveSettings(
                    ProactiveSettings.fromJson(
                        members["settings"] ?: throw BotJsonException("missing settings")),
                )
                "setMaintenanceEnabled" -> SetMaintenanceEnabled(
                    JsonSupport.requiredBool(members, "enabled", "infoIntent.enabled"))
                "rollbackMaintenance" -> RollbackMaintenance(requiredId(members, "batchID"))
                else -> throw BotJsonException("unknown info intent kind: $kind")
            }
        }

        private fun requiredId(members: Map<String, JsonValue>, key: String): String {
            val value = JsonSupport.requiredString(members, key, "infoIntent.$key")
            if (value.isEmpty()) throw BotJsonException("infoIntent.$key must not be empty")
            return value
        }
    }
}

/** The appearance write surface (`ui-state.md` §3.3). */
public sealed interface BotAppearanceIntent {
    public data class SelectColor(public val color: BotFishColor) : BotAppearanceIntent
    public data class SelectHairstyle(public val hairstyle: BotFishHairstyle) : BotAppearanceIntent
    public data class Rename(public val name: String) : BotAppearanceIntent

    public fun toJson(): JsonObject = when (this) {
        is SelectColor -> BotJson.objectOf(
            "kind" to JsonString("selectColor"), "color" to JsonString(color.wire))
        is SelectHairstyle -> BotJson.objectOf(
            "kind" to JsonString("selectHairstyle"), "hairstyle" to JsonString(hairstyle.wire))
        is Rename -> BotJson.objectOf(
            "kind" to JsonString("rename"), "name" to JsonString(name))
    }

    public companion object {
        public fun fromJson(value: JsonValue): BotAppearanceIntent {
            val members = JsonSupport.objectMembers(value, "appearanceIntent")
            return when (val kind = JsonSupport.requiredString(
                members, "kind", "appearanceIntent.kind")) {
                "selectColor" -> SelectColor(
                    BotFishColor.fromWire(
                        JsonSupport.requiredString(members, "color", "appearanceIntent.color"))
                        ?: throw BotJsonException("appearanceIntent.color has unknown value"))
                "selectHairstyle" -> SelectHairstyle(
                    BotFishHairstyle.fromWire(
                        JsonSupport.requiredString(
                            members, "hairstyle", "appearanceIntent.hairstyle"))
                        ?: throw BotJsonException("appearanceIntent.hairstyle has unknown value"))
                "rename" -> {
                    val name = JsonSupport.requiredString(members, "name", "appearanceIntent.name")
                    if (!BotNameValidation.isValid(name)) {
                        throw BotJsonException("appearanceIntent.name is not a valid Bot name")
                    }
                    Rename(name)
                }
                else -> throw BotJsonException("unknown appearance intent kind: $kind")
            }
        }
    }
}

/** The single profile field an appearance selection must persist. */
public enum class BotAppearanceField(public val field: String) {
    COLOR("color"),
    HAIRSTYLE("hairstyle"),
}

/** The local-first result of an appearance intent. */
public data class BotAppearanceChange(
    public val appearance: BotFishAppearance,
    public val changedField: BotAppearanceField,
)

/**
 * §3.3: selection applies immediately to the local appearance and clears the
 * matching auto flag; only [BotAppearanceChange.changedField] is persisted.
 * A write failure is surfaced by the caller and is never rolled back.
 */
public object BotAppearanceSelection {
    public fun apply(
        appearance: BotFishAppearance,
        intent: BotAppearanceIntent,
    ): BotAppearanceChange? = when (intent) {
        is BotAppearanceIntent.SelectColor -> BotAppearanceChange(
            appearance = appearance.copy(color = intent.color, autoColor = false),
            changedField = BotAppearanceField.COLOR,
        )
        is BotAppearanceIntent.SelectHairstyle -> BotAppearanceChange(
            appearance = appearance.copy(hairstyle = intent.hairstyle, autoHairstyle = false),
            changedField = BotAppearanceField.HAIRSTYLE,
        )
        is BotAppearanceIntent.Rename -> null
    }
}

// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.util.AtomicFile
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotProfileNormalizer
import com.phonedsh.bot.profile.BotRoster
import java.io.File
import java.io.FileNotFoundException

internal class AppBotProfileStore(directory: File, private val clock: () -> Long) {
    private val index = AtomicFile(File(directory, "agents-index.json"))
    private val settings = AtomicFile(File(directory, "runtime-settings.json"))

    @Synchronized
    fun read(): BotRoster {
        val root = read(index)
        val profiles = agents(root).mapNotNull { raw ->
            val record = (raw as? JsonObject)?.members ?: return@mapNotNull null
            fun text(name: String) = (record[name] as? JsonString)?.value
            fun number(name: String) = (record[name] as? JsonNumber)?.asLongOrNull()
            fun flag(name: String) = (record[name] as? JsonBool)?.value == true

            val id = text("id")?.takeIf(String::isNotBlank) ?: return@mapNotNull null
            BotProfile(
                id = id,
                name = text("name") ?: id,
                fishColor = BotProfileNormalizer.fishColor(text("fish_color")),
                fishHairstyle = BotProfileNormalizer.fishHairstyle(text("fish_hairstyle")),
                nameExplicit = flag("name_explicit"),
                createdAt = number("created_at") ?: 0,
                updatedAt = number("updated_at") ?: 0,
                description = text("description").orEmpty(),
                hiddenByUser = flag("hidden_by_user"),
                pinned = flag("pinned"),
                unreadCount = (number("unread_count") ?: 0).coerceIn(0, Int.MAX_VALUE.toLong()).toInt(),
                lastMessageAt = number("last_message_at"),
            )
        }
        val main = (read(settings)["mainAgentId"] as? JsonString)?.value
        return AppBotRoster.roster(profiles, main)
    }

    @Synchronized
    fun write(roster: BotRoster) {
        val indexRoot = read(index)
        val oldRecords = agents(indexRoot)
        val oldById = oldRecords.filterIsInstance<JsonObject>().associateBy { (it["id"] as? JsonString)?.value }
        val retainedUnknown = oldRecords.filter { (it as? JsonObject)?.get("id") !is JsonString }
        val encoded = roster.bots.map { profile ->
            val previous = oldById[profile.id]?.members.orEmpty()
            JsonObject(previous + mapOf(
                "schema" to (previous["schema"] ?: JsonNumber("3")),
                "id" to JsonString(profile.id),
                "name" to JsonString(profile.name),
                "fish_color" to (profile.fishColor?.let { JsonString(it.wire) } ?: JsonNull),
                "fish_hairstyle" to (profile.fishHairstyle?.let { JsonString(it.wire) } ?: JsonNull),
                "name_explicit" to JsonBool(profile.nameExplicit),
                "created_at" to JsonNumber(profile.createdAt.toString()),
                "updated_at" to JsonNumber(profile.updatedAt.toString()),
                "description" to JsonString(profile.description),
                "hidden_by_user" to JsonBool(profile.hiddenByUser),
                "pinned" to JsonBool(profile.pinned),
                "unread_count" to JsonNumber(profile.unreadCount.toString()),
                "last_message_at" to (profile.lastMessageAt?.let { JsonNumber(it.toString()) } ?: JsonNull),
            ))
        }
        write(index, JsonObject(indexRoot.members + mapOf(
            "schemaVersion" to (indexRoot["schemaVersion"] ?: JsonNumber("3")),
            "agents" to JsonArray(encoded + retainedUnknown),
        )))
    }

    @Synchronized
    fun setMain(id: String?) {
        val root = read(settings)
        write(settings, JsonObject(root.members + mapOf(
            "version" to (root["version"] ?: JsonNumber("1")),
            "mainAgentId" to (id?.let(::JsonString) ?: JsonNull),
            "updatedAt" to JsonNumber(clock().toString()),
        )))
    }

    private fun agents(root: JsonObject): List<JsonValue> = when (val value = root["agents"]) {
        null -> emptyList()
        is JsonArray -> value.values
        else -> error("Invalid Bot profile index")
    }

    private fun read(file: AtomicFile): JsonObject {
        val bytes = try {
            file.readFully()
        } catch (error: FileNotFoundException) {
            if (file.baseFile.exists()) throw error
            return JsonObject(emptyMap())
        }
        return JsonValue.parse(bytes.toString(Charsets.UTF_8)) as? JsonObject
            ?: error("Invalid Bot profile file")
    }

    private fun write(file: AtomicFile, value: JsonObject) {
        val stream = file.startWrite()
        try {
            stream.write(value.toJsonString().toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }
    }
}

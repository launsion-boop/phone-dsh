// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineError
import com.phonedsh.bot.routines.RoutineJson
import com.phonedsh.bot.routines.RoutineJson.requiredArray
import com.phonedsh.bot.routines.RoutineJson.requiredInt
import com.phonedsh.bot.routines.RoutineJson.requiredLong
import com.phonedsh.bot.routines.RoutineJson.requiredString

data class HeldConnectorUpdate(
    val connector: String,
    val cursorFrom: String,
    val cursorTo: String,
    val items: List<JsonObject>,
) {
    internal fun validate(requestId: String?, text: String) {
        val (cursor, metadata) = when (connector) {
            "gmail" -> gmailCursor to setOf("from", "subject")
            "github" -> githubCursor to setOf("repo", "title")
            else -> invalid("unknown connector")
        }
        if (!cursor.matches(cursorFrom) || !cursor.matches(cursorTo) || cursorFrom == cursorTo) {
            invalid("invalid cursor interval")
        }
        if (requestId != "$connector:$cursorFrom:$cursorTo" || text.isEmpty()) {
            invalid("invalid request ID or text")
        }
        if (items.size !in 1..20) invalid("invalid item count")
        val seen = mutableSetOf<String>()
        for (item in items) {
            val members = item.members
            val id = members.requiredString("id")
            if (RoutineJson.codePointLength(id) !in 1..256 || !seen.add(id) ||
                members.requiredLong("at") < 0 || !allowedMetadata(members, metadata)
            ) invalid("invalid metadata item")
        }
    }

    private fun allowedMetadata(members: Map<String, JsonValue>, names: Set<String>): Boolean =
        members.all { (key, value) ->
            key == "id" || key == "at" ||
                (key in names && value is JsonString && RoutineJson.codePointLength(value.value) <= 512)
        }

    internal fun toMembers(): List<Pair<String, JsonValue>> = listOf(
        "connector" to JsonString(connector),
        "cursorFrom" to JsonString(cursorFrom),
        "cursorTo" to JsonString(cursorTo),
        "count" to RoutineJson.number(items.size.toLong()),
        "items" to JsonArray(items),
    )

    internal companion object {
        const val KIND = "connector-update"
        private val gmailCursor = Regex("[0-9]{1,20}")
        private val githubCursor = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
        private val allowed = setOf(
            "id", "kind", "title", "text", "requestId", "createdAt", "fromAgentId", "fromAgentName",
            "threadId", "state", "stagedAt", "stagedKey", "connector", "cursorFrom", "cursorTo", "count", "items",
        )

        fun decode(members: Map<String, JsonValue>): HeldConnectorUpdate {
            if (!allowed.containsAll(members.keys)) invalid("unknown member")
            val items = members.requiredArray("items").map { it as? JsonObject ?: invalid("invalid metadata item") }
            if (members.requiredInt("count") != items.size) invalid("count does not match items")
            return HeldConnectorUpdate(
                members.requiredString("connector"),
                members.requiredString("cursorFrom"),
                members.requiredString("cursorTo"),
                items,
            )
        }

        private fun invalid(reason: String): Nothing =
            throw RoutineError.InvalidHeldItem("connector-update: $reason")
    }
}

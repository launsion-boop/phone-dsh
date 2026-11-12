// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineJson.objectOf
import com.phonedsh.bot.routines.RoutineJson.optionalObject
import com.phonedsh.bot.routines.RoutineJson.optionalString

/**
 * The frozen `{botId, document}` wrapper used by every durable snapshot event
 * (`spec/bot/v2/README.md` §2.3; Swift `DurableEventSnapshots`).
 *
 * `botId` is inside `data`, not in `principal`, and a snapshot for a different
 * Bot is skipped instead of being applied to this one.
 */
object DurableSnapshot {
    fun envelope(document: JsonValue, botId: String): JsonObject = objectOf(
        listOf(
            "botId" to JsonString(botId),
            "document" to document,
        ),
    )

    fun document(data: JsonValue, botId: String): JsonValue? {
        val members = (data as? JsonObject)?.members ?: return null
        if (members.optionalString("botId") != botId) return null
        return members["document"]
    }

    /** The `document` object of a snapshot, or null for another Bot/absent. */
    fun optionalDocumentObject(data: JsonValue, botId: String): Map<String, JsonValue>? {
        val members = (data as? JsonObject)?.members ?: return null
        if (members.optionalString("botId") != botId) return null
        return members.optionalObject("document")
    }
}

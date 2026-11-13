// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineJson.objectOf
import com.phonedsh.bot.routines.RoutineJson.optionalLong
import com.phonedsh.bot.routines.RoutineJson.optionalString
import com.phonedsh.bot.routines.RoutineJson.prefixCodePoints

/**
 * One routine-due notification the host asks the system to keep for a Bot.
 *
 * This is not a proactive result notification and does not consume the
 * frequency fuse. The field set, title, body and deep link are frozen by
 * `spec/bot/v2/routine-notification.schema.json` and
 * `golden/routine-notification.json`; the identifier is
 * `routine-due:<botId>:<routineId>:<fireAt>` so rescheduling cancels the old
 * registration instead of replacing it silently.
 */
data class RoutineScheduledNotification(
    val identifier: String,
    val botId: String,
    val routineId: String,
    val title: String,
    val body: String,
    val fireAt: Long,
    val deepLink: String,
) {
    val id: String get() = identifier

    fun toJson(): JsonObject = objectOf(
        listOf(
            "identifier" to JsonString(identifier),
            "botId" to JsonString(botId),
            "routineId" to JsonString(routineId),
            "title" to JsonString(title),
            "body" to JsonString(body),
            "fireAt" to RoutineJson.number(fireAt),
            "deepLink" to JsonString(deepLink),
        ),
    )

    fun validate(): RoutineScheduledNotification {
        if (identifier.isEmpty()) throw InvalidRoutineNotification("missing_identifier", "identifier is required")
        if (botId.isEmpty()) throw InvalidRoutineNotification("missing_bot_id", "botId is required")
        if (routineId.isEmpty()) throw InvalidRoutineNotification("missing_routine_id", "routineId is required")
        if (title != TITLE) throw InvalidRoutineNotification("wrong_title", "title must be $TITLE")
        val bodyLength = RoutineJson.codePointLength(body)
        if (bodyLength == 0) throw InvalidRoutineNotification("empty_body", "body must not be empty")
        if (bodyLength > 200) throw InvalidRoutineNotification("body_too_long", "body exceeds 200 characters")
        if (fireAt < 0) throw InvalidRoutineNotification("negative_fire_at", "fireAt must not be negative")
        if (deepLink.isEmpty()) {
            throw InvalidRoutineNotification("missing_deep_link", "deepLink is required")
        }
        if (!deepLink.startsWith(BotRoutineDeepLink.SCHEME)) {
            throw InvalidRoutineNotification("wrong_scheme", "deepLink must use the phonedsh scheme")
        }
        val parsed = BotRoutineDeepLink.parse(deepLink)
        if (parsed == null || parsed.first != botId || parsed.second != routineId) {
            throw InvalidRoutineNotification(
                "wrong_deep_link", "deepLink must address this bot and routine",
            )
        }
        return this
    }

    companion object {
        const val TITLE: String = "例行任务到期"

        fun identifier(botId: String, routineId: String, fireAt: Long): String =
            "routine-due:$botId:$routineId:$fireAt"

        fun forRoutine(botId: String, routineId: String, routineTitle: String, fireAt: Long): RoutineScheduledNotification {
            val title = prefixCodePoints(routineTitle, 120)
            return RoutineScheduledNotification(
                identifier = identifier(botId, routineId, fireAt),
                botId = botId,
                routineId = routineId,
                title = TITLE,
                body = prefixCodePoints("「$title」到点，点开运行。", 200),
                fireAt = fireAt,
                deepLink = BotRoutineDeepLink.make(botId, routineId),
            )
        }

        fun fromJson(value: JsonValue): RoutineScheduledNotification {
            val members = (value as? JsonObject)?.members
                ?: throw InvalidRoutineNotification("invalid_notification", "notification must be an object")
            return RoutineScheduledNotification(
                identifier = members.optionalString("identifier") ?: "",
                botId = members.optionalString("botId") ?: "",
                routineId = members.optionalString("routineId") ?: "",
                title = members.optionalString("title") ?: "",
                body = members.optionalString("body") ?: "",
                fireAt = members.optionalLong("fireAt") ?: -1,
                deepLink = members.optionalString("deepLink") ?: "",
            ).validate()
        }
    }
}

/** A routine notification does not satisfy the frozen shape; [reason] is the vector kind. */
class InvalidRoutineNotification(val reason: String, message: String) : Exception(message)

/**
 * The deep link carried by a routine-due notification. Unlike a proactive
 * result, a routine has no result row before it runs, so this link targets the
 * routine's row in the Bot information page.
 */
object BotRoutineDeepLink {
    const val SCHEME: String = "phonedsh://bot/"

    fun make(botId: String, routineId: String): String =
        "$SCHEME${escape(botId)}/routine/${escape(routineId)}"

    fun parse(value: String): Pair<String, String>? {
        if (!value.startsWith(SCHEME)) return null
        val parts = value.drop(SCHEME.length).split('/')
        if (parts.size != 3 || parts[1] != "routine") return null
        val botId = percentDecode(parts[0]) ?: return null
        val routineId = percentDecode(parts[2]) ?: return null
        if (botId.isEmpty() || routineId.isEmpty()) return null
        return botId to routineId
    }

    private fun escape(value: String): String {
        val out = StringBuilder()
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val unsigned = byte.toInt() and 0xFF
            val character = unsigned.toChar()
            val allowed = character.isLetterOrDigit() && unsigned < 0x80 ||
                character in "-._~!$&'()*+,;=:@"
            if (allowed) {
                out.append(character)
            } else {
                out.append('%')
                out.append(unsigned.toString(16).uppercase().padStart(2, '0'))
            }
        }
        return out.toString()
    }

    private fun percentDecode(value: String): String? {
        val bytes = ArrayList<Byte>()
        var index = 0
        while (index < value.length) {
            val character = value[index]
            if (character == '%') {
                if (index + 2 >= value.length) return null
                val hex = value.substring(index + 1, index + 3).toIntOrNull(16) ?: return null
                bytes += hex.toByte()
                index += 3
            } else {
                for (byte in character.toString().toByteArray(Charsets.UTF_8)) bytes += byte
                index++
            }
        }
        return String(bytes.toByteArray(), Charsets.UTF_8)
    }
}

/**
 * Host seam for the system notification center. Tests inject a fake; the
 * Android implementation belongs to the host wiring, not to `:bot`.
 */
interface RoutineNotificationScheduling {
    fun schedule(notification: RoutineScheduledNotification)

    fun pendingIdentifiers(prefix: String): List<String>

    fun cancel(identifiers: List<String>)
}

/**
 * In-memory fake used by tests and by the "no system notification support"
 * host. It records every registration so the scheduler's reconciliation can be
 * driven without `android.app.NotificationManager`.
 */
class InMemoryRoutineNotificationScheduling : RoutineNotificationScheduling {
    private val pending = LinkedHashMap<String, RoutineScheduledNotification>()
    private val failures = HashSet<String>()
    var scheduleCalls: Int = 0
        private set
    var cancelCalls: Int = 0
        private set

    fun failOn(identifier: String) {
        failures += identifier
    }

    fun pending(): List<RoutineScheduledNotification> = pending.values.toList()

    override fun schedule(notification: RoutineScheduledNotification) {
        scheduleCalls++
        if (notification.identifier in failures) {
            failures -= notification.identifier
            throw RoutineError.InvalidRoutine("notification registration failed")
        }
        notification.validate()
        pending[notification.identifier] = notification
    }

    override fun pendingIdentifiers(prefix: String): List<String> =
        pending.keys.filter { it.startsWith(prefix) }

    override fun cancel(identifiers: List<String>) {
        cancelCalls++
        for (identifier in identifiers) pending.remove(identifier)
    }

    /** Simulates the system dropping registrations (reboot, permission change). */
    fun purgeSystemPending(prefix: String) {
        pending.keys.filter { it.startsWith(prefix) }.forEach { pending.remove(it) }
    }
}

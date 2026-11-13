// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineError
import com.phonedsh.bot.routines.RoutineJson
import com.phonedsh.bot.routines.RoutineJson.objectOf
import com.phonedsh.bot.routines.RoutineJson.optionalString
import com.phonedsh.bot.routines.RoutineJson.prefixCodePoints
import com.phonedsh.bot.routines.RoutineJson.requiredLong
import com.phonedsh.bot.routines.RoutineJson.requiredString
import com.phonedsh.bot.store.sha256

/**
 * A read-only held-inbox notice describing the terminal result of a device
 * task (`Sources/PhoneDSHBot/Wake/DeviceTaskResultNotice.swift`;
 * `golden/held-inbox.phone.json`).
 *
 * The goal and result are device/model data. This type only carries them into
 * the next main turn: it never grants a tool and never provides a reply path
 * back to the device. `deviceID` / `taskID` are the upstream property names.
 */
data class DeviceTaskResultNotice(
    val deviceID: String,
    val deviceDisplayName: String,
    val taskID: String,
    val idempotencyKey: String,
    val goal: String,
    val status: Status,
    val result: String,
    val createdAt: Long,
) {
    enum class Status(val rawValue: String) {
        COMPLETED("completed"),
        DENIED("denied"),
        UNAVAILABLE("unavailable"),
        EXPIRED("expired"),
        FAILED("failed"),
        UNKNOWN_OUTCOME("unknown_outcome"),
        ;

        companion object {
            fun from(value: String?): Status =
                entries.firstOrNull { it.rawValue == value }
                    ?: throw RoutineError.InvalidHeldItem(
                        "invalid device task result status: ${value ?: "missing"}",
                    )
        }
    }

    fun toJson(): JsonObject = objectOf(
        listOf(
            "deviceID" to JsonString(deviceID),
            "deviceDisplayName" to JsonString(deviceDisplayName),
            "taskID" to JsonString(taskID),
            "idempotencyKey" to JsonString(idempotencyKey),
            "goal" to JsonString(goal),
            "status" to JsonString(status.rawValue),
            "result" to JsonString(result),
            "createdAt" to RoutineJson.number(createdAt),
        ),
    )

    /**
     * Lowercase SHA-256 of UTF-8 device id, one NUL byte, then UTF-8
     * idempotency key. It is the stable identity of one task's result: the
     * event id, the held item id and the dedupe request id all derive from it.
     */
    val digest: String
        get() {
            val device = deviceID.toByteArray(Charsets.UTF_8)
            val idempotency = idempotencyKey.toByteArray(Charsets.UTF_8)
            val data = ByteArray(device.size + 1 + idempotency.size)
            device.copyInto(data)
            data[device.size] = 0
            idempotency.copyInto(data, device.size + 1)
            return sha256(data)
        }

    val itemID: String get() = "${KIND}-$digest"

    val requestID: String get() = "device-task:$digest"

    val title: String get() = prefixCodePoints(deviceDisplayName, 80)

    /** Goal summary and result, capped at 1,200 scalars including the labels. */
    val text: String
        get() {
            val goalSummary = prefixCodePoints(goal, 120)
            return prefixCodePoints("Goal: $goalSummary\nResult: $result", 1_200)
        }

    fun wakeInboxItem(): WakeInboxItem = WakeInboxItem(
        id = itemID,
        kind = KIND,
        title = title,
        text = text,
        requestId = requestID,
        createdAt = createdAt,
        taskId = taskID,
        status = status.rawValue,
    )

    companion object {
        const val KIND: String = "device-task-result"

        fun fromJson(value: JsonValue?): DeviceTaskResultNotice {
            val members = (value as? JsonObject)?.members
                ?: throw RoutineError.InvalidHeldItem("device task result must be an object")
            return DeviceTaskResultNotice(
                deviceID = members.requiredString("deviceID"),
                deviceDisplayName = members.optionalString("deviceDisplayName") ?: "",
                taskID = members.requiredString("taskID"),
                idempotencyKey = members.requiredString("idempotencyKey"),
                goal = members.optionalString("goal") ?: "",
                status = Status.from(members.optionalString("status")),
                result = members.optionalString("result") ?: "",
                createdAt = members.requiredLong("createdAt"),
            )
        }
    }
}

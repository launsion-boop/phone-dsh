// phone-dsh — :net / com.phonedsh.adb: the saved Android target (P18).
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHADB/ADBSettings.swift`. The iOS value is the
// JSON `{"enabled":Bool,"host":String,"port":UInt16}` under the UserDefaults key
// `phone-dsh.android-adb.configuration.v1`; Android keeps the same key and the
// same JSON in its own app-private store ([AdbSettingsStorage], SharedPreferences
// in `:app`). Nothing crosses platforms: each host reads only what it wrote. An
// unreadable or malformed value reads as the default (disabled), like Swift's
// `try?` decode.

package com.phonedsh.adb

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString

public data class AdbConfiguration(
    public val enabled: Boolean = false,
    public val host: String = "",
    public val port: Int = 5555,
) {
    public fun endpoint(): AdbEndpoint {
        if (!enabled) {
            throw AdbFailure(
                "Android control is disabled. Call android_connect with the user-provided host and port to enable it.",
            )
        }
        return AdbEndpoint.of(host, port)
    }

    internal fun toJson(): String = JsonObject(
        linkedMapOf("enabled" to JsonBool(enabled), "host" to JsonString(host), "port" to JsonNumber(port.toString())),
    ).toJsonString()

    internal companion object {
        fun parse(text: String?): AdbConfiguration {
            if (text == null) return AdbConfiguration()
            return try {
                val value = JsonValue.parse(text) as? JsonObject ?: return AdbConfiguration()
                val enabled = (value["enabled"] as? JsonBool)?.value ?: return AdbConfiguration()
                val host = (value["host"] as? JsonString)?.value ?: return AdbConfiguration()
                val port = (value["port"] as? JsonNumber)?.asLongOrNull()?.takeIf { it in 0..65535 }
                    ?: return AdbConfiguration()
                AdbConfiguration(enabled, host, port.toInt())
            } catch (failure: Exception) {
                AdbConfiguration()
            }
        }
    }
}

/** One string slot; `:app` backs it with SharedPreferences. */
public interface AdbSettingsStorage {
    public fun read(key: String): String?

    /** Must be durable when it returns; throws [java.io.IOException] otherwise. */
    public fun write(key: String, value: String)
}

/** In-memory storage for tests and for a host without persistence. */
public class InMemoryAdbSettingsStorage : AdbSettingsStorage {
    private val values = HashMap<String, String>()
    override fun read(key: String): String? = synchronized(values) { values[key] }
    override fun write(key: String, value: String) {
        synchronized(values) { values[key] = value }
    }
}

public class AdbSettings(private val storage: AdbSettingsStorage) {
    private val lock = Any()

    public fun load(): AdbConfiguration = synchronized(lock) { AdbConfiguration.parse(storage.read(KEY)) }

    public fun save(configuration: AdbConfiguration) {
        if (configuration.enabled) configuration.endpoint()
        val text = configuration.toJson()
        synchronized(lock) { storage.write(KEY, text) }
    }

    public companion object {
        public const val KEY: String = "phone-dsh.android-adb.configuration.v1"
    }
}

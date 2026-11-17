// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.cloudtasks: what the phone keeps for the task queue.
//
// cloud-tasks.md §2, §3 and §7 name three stored things: the cloud device id
// (preference `phone-dsh.bot.cloud.device-id.v1`), the enable flag (preference
// `phone-dsh.cloud-tasks.enabled.v1`, absent = off) and one private-key record
// per `key_id` (Android: `SecureStore` key `cloud-tasks.key.<key_id>`). This
// file holds the seams and the record encoding; the app supplies the real
// preferences and the keystore-wrapped store. Nothing else is persisted here:
// which key is current is read from the cloud's device list, not from a local
// index.

package com.phonedsh.cloudtasks

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.io.IOException
import java.util.UUID

/** The app's preference file, by the contract's key names. */
interface CloudTaskPreferences {
    fun string(key: String): String?

    fun putString(key: String, value: String)

    /** `null` when the key is absent. */
    fun boolean(key: String): Boolean?

    fun putBoolean(key: String, value: Boolean)
}

/**
 * One private-key record per `key_id`. The app backs it with `SecureStore`,
 * using [storageKey] as the item name.
 */
interface CloudTaskKeyStore {
    /**
     * The record for [keyId], `null` when there is none.
     *
     * @throws IOException when the store cannot be read now (for example before
     *   first unlock). That is a transient condition: the caller sends no ack.
     */
    @Throws(IOException::class)
    fun load(keyId: String): ByteArray?

    @Throws(IOException::class)
    fun save(keyId: String, record: ByteArray)

    @Throws(IOException::class)
    fun delete(keyId: String)

    companion object {
        const val STORAGE_PREFIX: String = "cloud-tasks.key."

        /** The `SecureStore` item name for [keyId]: `cloud-tasks.key.<key_id>`. */
        fun storageKey(keyId: String): String = STORAGE_PREFIX + keyId
    }
}

/** A key store held in memory, for tests and previews. */
class InMemoryCloudTaskKeyStore : CloudTaskKeyStore {
    private val records = HashMap<String, ByteArray>()

    /** When true every call throws, like a store that is locked. */
    @Volatile
    var locked: Boolean = false

    val keyIds: Set<String> get() = synchronized(records) { records.keys.toSet() }

    override fun load(keyId: String): ByteArray? = synchronized(records) {
        if (locked) throw IOException("key store is locked")
        records[keyId]?.copyOf()
    }

    override fun save(keyId: String, record: ByteArray) = synchronized(records) {
        if (locked) throw IOException("key store is locked")
        records[keyId] = record.copyOf()
    }

    override fun delete(keyId: String) {
        synchronized(records) {
            if (locked) throw IOException("key store is locked")
            records.remove(keyId)
        }
    }
}

/** Preferences held in memory, for tests and previews. */
class InMemoryCloudTaskPreferences : CloudTaskPreferences {
    private val values = HashMap<String, Any>()

    override fun string(key: String): String? = synchronized(values) { values[key] as? String }

    override fun putString(key: String, value: String) {
        synchronized(values) { values[key] = value }
    }

    override fun boolean(key: String): Boolean? = synchronized(values) { values[key] as? Boolean }

    override fun putBoolean(key: String, value: Boolean) {
        synchronized(values) { values[key] = value }
    }
}

/** One stored key: the pair and its id. `toString` never prints the scalar. */
class CloudTaskKeyRecord(val keyId: String, val pair: CloudTaskKeyPair, val createdAtMs: Long) {
    val public: CloudTaskPublicKey get() = CloudTaskPublicKey(keyId, pair.publicKey)

    override fun toString(): String = "CloudTaskKeyRecord($keyId)"
}

object CloudTaskIdentity {
    const val DEVICE_ID_KEY: String = "phone-dsh.bot.cloud.device-id.v1"
    const val ENABLED_KEY: String = "phone-dsh.cloud-tasks.enabled.v1"
    const val RECORD_VERSION: Int = 1

    /** §7: off until the user enables it; an absent key is off. */
    fun isEnabled(preferences: CloudTaskPreferences): Boolean = preferences.boolean(ENABLED_KEY) == true

    /**
     * §2 device id: `dev-` + a lowercase UUIDv4, created once per install. A
     * stored value that is not one is returned as `null` and left untouched —
     * the key is shared with the Bot cloud scheduler, so it is not overwritten.
     */
    fun deviceId(preferences: CloudTaskPreferences, newUuid: () -> UUID = UUID::randomUUID): String? {
        val stored = preferences.string(DEVICE_ID_KEY)
        if (stored != null) return stored.takeIf(CloudTaskWire::isDeviceId)
        val created = "dev-" + newUuid().toString().lowercase()
        if (!CloudTaskWire.isDeviceId(created)) return null
        preferences.putString(DEVICE_ID_KEY, created)
        return created
    }

    /** A fresh `key_id`: `k-` + a lowercase UUIDv4. */
    fun newKeyId(newUuid: () -> UUID = UUID::randomUUID): String = "k-" + newUuid().toString().lowercase()

    /** The bytes kept under `cloud-tasks.key.<key_id>` (the store wraps them). */
    fun encodeRecord(record: CloudTaskKeyRecord): ByteArray = GatewayJson.canonicalBytes(JsonValue.obj(
        "version" to JsonValue.num(RECORD_VERSION),
        "key_id" to JsonValue.Str(record.keyId),
        "suite" to JsonValue.Str(CloudTaskWire.SUITE),
        "private_scalar" to JsonValue.Str(CloudTaskWire.base64UrlEncode(record.pair.privateScalar)),
        "public_key" to JsonValue.Str(CloudTaskWire.base64UrlEncode(record.pair.publicKey)),
        "created_at_ms" to JsonValue.num(record.createdAtMs),
    ))

    /** The record for [keyId], or `null` when [bytes] is not one (treated as "no key"). */
    fun decodeRecord(keyId: String, bytes: ByteArray): CloudTaskKeyRecord? {
        val root = GatewayJson.parseOrNull(bytes) as? JsonValue.Obj ?: return null
        if (root.int("version") != RECORD_VERSION) return null
        if (root.string("key_id") != keyId || root.string("suite") != CloudTaskWire.SUITE) return null
        val scalar = root.string("private_scalar")?.let(::decode) ?: return null
        val point = root.string("public_key")?.let(::decode) ?: return null
        if (scalar.size != 32 || !CloudTaskCrypto.isPublicKey(point)) return null
        val createdAt = (root.get("created_at_ms") as? JsonValue.Num)?.literal?.toLongOrNull() ?: return null
        return CloudTaskKeyRecord(keyId, CloudTaskKeyPair(scalar, point), createdAt)
    }

    private fun decode(text: String): ByteArray? = try {
        CloudTaskWire.base64UrlDecode(text)
    } catch (_: CloudTaskWireException) {
        null
    }
}

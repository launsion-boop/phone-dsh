// phone-dsh — :net / com.phonedsh.adb: durable receipts for Android side effects.
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHADB/ADBReceipts.swift` (native-mcp.md: "a
// dedicated persistent receipt store ... keyed by the journal's opaque
// X-PDSH-Idempotency-Key"). An intent is written and fsynced before OPEN reaches
// adbd; a saved intent with no result is an unknown outcome, never permission to
// repeat a device action. A corrupt receipt fails closed.
//
// File: `<dir>/<sha256(key) hex>.json` = `{"fingerprint":"<base64>","result":<MCP result>}`
// (`result` absent for an intent). Written to a sibling temp file, fsynced, then
// renamed over the target. The store is app-private and Android-only.

package com.phonedsh.adb

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Base64

public class AdbReceipt(public val fingerprint: ByteArray, public val result: JsonValue? = null)

public class AdbReceiptStore(private val directory: Path) {
    private fun path(key: String): Path = directory.resolve(sha256Hex(key.toByteArray(Charsets.UTF_8)) + ".json")

    /** Null when no receipt exists; throws when one exists but cannot be decoded. */
    public fun load(key: String): AdbReceipt? {
        val file = path(key)
        if (!Files.exists(file)) return null
        val value = JsonValue.parse(String(Files.readAllBytes(file), Charsets.UTF_8)) as? JsonObject
            ?: throw AdbFailure("Corrupt Android operation receipt")
        val fingerprint = (value["fingerprint"] as? JsonString)?.value
            ?: throw AdbFailure("Corrupt Android operation receipt")
        return AdbReceipt(Base64.getDecoder().decode(fingerprint), value["result"])
    }

    public fun save(key: String, receipt: AdbReceipt) {
        Files.createDirectories(directory)
        var result = receipt.result
        if (result != null && result.toJsonString().toByteArray(Charsets.UTF_8).size > 16 * 1024) {
            result = AdbTools.textResult(
                "This Android operation finished, but its large result is no longer retained after restart. " +
                    "It was not executed again. Capture a new screenshot or inspect device state as needed.",
                error = true,
            )
        }
        val members = linkedMapOf<String, JsonValue>(
            "fingerprint" to JsonString(Base64.getEncoder().encodeToString(receipt.fingerprint)),
        )
        if (result != null) members["result"] = result
        val target = path(key)
        val temporary = directory.resolve(target.fileName.toString() + ".tmp")
        FileOutputStream(temporary.toFile()).use { out ->
            out.write(JsonObject(members).toJsonString().toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
        Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    internal companion object {
        fun sha256Hex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}

// SPDX-License-Identifier: MIT
package com.phonedsh.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.nio.file.Files
import java.nio.file.Path

/**
 * Reads a Bot golden from disk and merges its same-name `.phone.json` overlay
 * exactly as `spec/bot/v1/README.md` §8.1 and Swift `BotGoldenFixture` do:
 *
 * - the upstream file is the untouched exporter batch;
 * - `schemaVersion`/`vector`/`source`/`upstream`/`delta` are documentation and
 *   never participate in the merge;
 * - object containers merge by key; array containers append or replace by
 *   identity (`name`, `id`, `nonce`, `action.nonce`), and an identity-less
 *   entry is skipped only when a byte-identical entry is already present; an
 *   overlay can never remove an upstream case.
 */
object GoldenFixture {
    val repoRoot: Path = System.getProperty("pdsh.repo.root")?.let(Path::of)
        ?: generateSequence(Path.of("").toAbsolutePath()) { it.parent }
            .first { Files.isDirectory(it.resolve("spec/bot/v1/golden")) }

    private val metadataKeys = setOf("schemaVersion", "vector", "source", "upstream", "delta")

    fun rawObject(name: String): JsonObject =
        JsonValue.parse(Files.readString(repoRoot.resolve("spec/bot/v1/golden/$name.json"))) as JsonObject

    fun mergedObject(name: String): JsonObject {
        val upstream = rawObject(name)
        val overlayPath = repoRoot.resolve("spec/bot/v1/golden/$name.phone.json")
        if (!Files.isRegularFile(overlayPath)) return upstream
        val overlay = JsonValue.parse(Files.readString(overlayPath)) as JsonObject
        return merge(upstream, overlay)
    }

    fun merge(upstream: JsonObject, overlay: JsonObject): JsonObject =
        JsonObject(mergeObject(upstream.members, overlay.members))

    private fun mergeObject(
        upstream: Map<String, JsonValue>,
        overlay: Map<String, JsonValue>,
    ): Map<String, JsonValue> {
        val merged = LinkedHashMap(upstream)
        for ((key, value) in overlay) {
            if (key in metadataKeys) continue
            val current = merged[key]
            merged[key] = if (current != null) mergeValue(current, value) else value
        }
        return merged
    }

    private fun mergeValue(upstream: JsonValue, overlay: JsonValue): JsonValue = when {
        upstream is JsonObject && overlay is JsonObject ->
            JsonObject(mergeObject(upstream.members, overlay.members))
        upstream is JsonArray && overlay is JsonArray ->
            JsonArray(mergeArray(upstream.values, overlay.values))
        else -> overlay
    }

    private fun mergeArray(upstream: List<JsonValue>, overlay: List<JsonValue>): List<JsonValue> {
        val merged = ArrayList(upstream)
        val positions = HashMap<String, Int>()
        for ((index, item) in merged.withIndex()) {
            identity(item)?.let { positions[it] = index }
        }
        val seen = merged.map { BotJson.canonical(it) }.toHashSet()
        for (item in overlay) {
            val identifier = identity(item)
            if (identifier != null) {
                val position = positions[identifier]
                if (position != null) {
                    merged[position] = item
                    continue
                }
            }
            val text = BotJson.canonical(item)
            if (identifier == null && text in seen) continue
            if (identifier != null) positions[identifier] = merged.size
            seen += text
            merged += item
        }
        return merged
    }

    private fun identity(value: JsonValue): String? {
        val members = (value as? JsonObject)?.members ?: return null
        for (key in listOf("name", "id", "nonce")) {
            val text = (members[key] as? JsonString)?.value ?: continue
            return "$key:$text"
        }
        val action = (members["action"] as? JsonObject)?.members ?: return null
        val nonce = (action["nonce"] as? JsonString)?.value ?: return null
        return "action.nonce:$nonce"
    }

    fun at(value: JsonValue?, vararg path: String): JsonValue? {
        var current = value
        for (key in path) {
            current = (current as? JsonObject)?.members?.get(key) ?: return null
        }
        return current
    }

    fun objects(value: JsonValue?, vararg path: String): List<JsonValue> =
        (at(value, *path) as? JsonArray)?.values ?: emptyList()

    fun string(value: JsonValue?, vararg path: String): String? =
        (at(value, *path) as? JsonString)?.value

    fun long(value: JsonValue?, vararg path: String): Long? =
        (at(value, *path) as? JsonNumber)?.asLongOrNull()

    fun bool(value: JsonValue?, vararg path: String): Boolean? =
        (at(value, *path) as? JsonBool)?.value

    fun objectValue(value: JsonValue?, vararg path: String): JsonObject =
        at(value, *path) as? JsonObject
            ?: throw AssertionError("missing object at ${path.joinToString(".")}")

    fun requireString(value: JsonValue?, vararg path: String): String =
        string(value, *path) ?: throw AssertionError("missing string at ${path.joinToString(".")}")

    fun requireLong(value: JsonValue?, vararg path: String): Long =
        long(value, *path) ?: throw AssertionError("missing integer at ${path.joinToString(".")}")

    fun requireBool(value: JsonValue?, vararg path: String): Boolean =
        bool(value, *path) ?: throw AssertionError("missing boolean at ${path.joinToString(".")}")

    /** Canonical JSON of an expected/actual value, for byte-level assertions. */
    fun canonical(value: JsonValue): String = BotJson.canonical(value)
}

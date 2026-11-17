// SPDX-License-Identifier: MIT
// Shared test support for the two host stores: the real `spec/host/v1` files,
// a literal JSON-Schema subset validator over them, and a file store that can
// stop the real atomic write at a named step.
package com.phonedsh.probe.outbox

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.io.File

internal object HostSpec {
    val root: File by lazy {
        File(System.getProperty("pdsh.repo.root") ?: error("pdsh.repo.root is not set; the :app test task supplies it"))
    }

    fun json(relativePath: String): JsonValue {
        val file = File(root, relativePath)
        check(file.isFile) { "missing spec file $relativePath" }
        return JsonValue.parse(file.readText(Charsets.UTF_8))
    }

    fun obj(relativePath: String): JsonObject = json(relativePath) as JsonObject

    /** The `instance` of one `spec/host/v1/golden` wrapper. */
    fun goldenInstance(name: String): JsonObject =
        obj("spec/host/v1/golden/$name")["instance"] as JsonObject
}

internal fun JsonObject.string(name: String): String = (this[name] as JsonString).value

internal fun JsonObject.long(name: String): Long = (this[name] as JsonNumber).asLongOrNull()!!

internal fun JsonObject.bool(name: String): Boolean = (this[name] as JsonBool).value

internal fun JsonObject.array(name: String): List<JsonValue> = (this[name] as JsonArray).values

internal fun JsonObject.objects(name: String): List<JsonObject> = array(name).map { it as JsonObject }

internal fun JsonObject.child(name: String): JsonObject = this[name] as JsonObject

internal fun JsonObject.with(vararg members: Pair<String, JsonValue>): JsonObject =
    JsonObject(LinkedHashMap(this.members).apply { putAll(members) })

internal fun JsonObject.without(vararg names: String): JsonObject =
    JsonObject(LinkedHashMap(this.members).apply { names.forEach(::remove) })

/**
 * The JSON-Schema subset the two schemas use, read from the real schema file so
 * that a schema edit reaches the test. A keyword outside the subset fails
 * loudly instead of being ignored.
 */
internal object SpecSchema {
    private val KNOWN = setOf(
        "title", "description", "type", "oneOf", "required", "properties", "additionalProperties",
        "const", "enum", "pattern", "minLength", "maxLength", "minimum", "maximum", "items",
        "minItems", "maxItems",
    )

    /** Returns the problems; empty means [value] is valid against [schema]. */
    fun validate(schema: JsonObject, value: JsonValue, path: String = "$"): List<String> {
        val unknown = schema.members.keys - KNOWN
        check(unknown.isEmpty()) { "schema keyword(s) $unknown at $path are outside the test validator's subset" }
        val problems = ArrayList<String>()
        (schema["type"] as? JsonString)?.value?.let { type ->
            if (!matchesType(type, value)) return listOf("$path: expected $type")
        }
        schema["const"]?.let { if (it != value) problems.add("$path: not the const value") }
        (schema["enum"] as? JsonArray)?.let { if (value !in it.values) problems.add("$path: not in the enum") }
        if (value is JsonString) {
            val length = value.value.codePointCount(0, value.value.length).toLong()
            limit(schema, "minLength")?.let { if (length < it) problems.add("$path: shorter than $it") }
            limit(schema, "maxLength")?.let { if (length > it) problems.add("$path: longer than $it") }
            (schema["pattern"] as? JsonString)?.value?.let {
                if (!Regex(it).containsMatchIn(value.value)) problems.add("$path: does not match $it")
            }
        }
        if (value is JsonNumber) {
            val number = value.asLongOrNull()
            limit(schema, "minimum")?.let { if (number == null || number < it) problems.add("$path: below $it") }
            limit(schema, "maximum")?.let { if (number == null || number > it) problems.add("$path: above $it") }
        }
        if (value is JsonArray) {
            limit(schema, "minItems")?.let { if (value.values.size < it) problems.add("$path: fewer than $it items") }
            limit(schema, "maxItems")?.let { if (value.values.size > it) problems.add("$path: more than $it items") }
            (schema["items"] as? JsonObject)?.let { items ->
                value.values.forEachIndexed { index, item -> problems.addAll(validate(items, item, "$path[$index]")) }
            }
        }
        if (value is JsonObject) {
            (schema["required"] as? JsonArray)?.values?.forEach { name ->
                val key = (name as JsonString).value
                if (key !in value.members) problems.add("$path: missing '$key'")
            }
            val properties = schema["properties"] as? JsonObject
            val closed = (schema["additionalProperties"] as? JsonBool)?.value == false
            for ((key, member) in value.members) {
                val memberSchema = properties?.get(key) as? JsonObject
                if (memberSchema != null) {
                    problems.addAll(validate(memberSchema, member, "$path.$key"))
                } else if (closed) {
                    problems.add("$path: unexpected member '$key'")
                }
            }
        }
        (schema["oneOf"] as? JsonArray)?.let { variants ->
            val matching = variants.values.count { validate(it as JsonObject, value, path).isEmpty() }
            if (matching != 1) problems.add("$path: matches $matching oneOf variants, not exactly one")
        }
        return problems
    }

    private fun limit(schema: JsonObject, name: String): Long? = (schema[name] as? JsonNumber)?.asLongOrNull()

    private fun matchesType(type: String, value: JsonValue): Boolean = when (type) {
        "object" -> value is JsonObject
        "array" -> value is JsonArray
        "string" -> value is JsonString
        "integer" -> (value as? JsonNumber)?.asLongOrNull() != null
        "number" -> value is JsonNumber
        "boolean" -> value is JsonBool
        "null" -> value is JsonNull
        else -> error("schema type '$type' is outside the test validator's subset")
    }
}

/** Thrown from a checkpoint to model a killed process. Not an IOException: nothing cleans up after it. */
internal class SimulatedKill(val where: String) : Error("simulated kill at $where")

/**
 * The real [DurableFileStore] with one armed kill. [killWrite] stops the next
 * atomic write whose target matches at the given step; [killAfterDelete] stops
 * right after the next matching durable delete.
 */
internal class KillingFileStore : DurableFileStore() {
    private var writeKill: Pair<DurableWriteStep, (File) -> Boolean>? = null
    private var deleteKill: ((File) -> Boolean)? = null

    fun killWrite(step: DurableWriteStep, target: (File) -> Boolean = { true }) {
        writeKill = step to target
    }

    fun killAfterDelete(target: (File) -> Boolean = { true }) {
        deleteKill = target
    }

    override fun checkpoint(step: DurableWriteStep, target: File) {
        val armed = writeKill ?: return
        if (armed.first == step && armed.second(target)) {
            writeKill = null
            throw SimulatedKill("${step.name} of ${target.name}")
        }
    }

    override fun deleteDurably(target: File): Boolean {
        val deleted = super.deleteDurably(target)
        val armed = deleteKill
        if (armed != null && armed(target)) {
            deleteKill = null
            throw SimulatedKill("after delete of ${target.name}")
        }
        return deleted
    }
}

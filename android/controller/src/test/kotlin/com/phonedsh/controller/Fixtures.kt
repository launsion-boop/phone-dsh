// phone-dsh Android — :controller fixture reader over :core's JSON value type.
// SPDX-License-Identifier: MIT
//
// The 16 normative perturbations under `spec/v1/golden/perturbations/` are JSON.
// :core already ships `JsonValue.parse` (RFC 8259, `com.phonedsh.agentcore`) and
// `:controller` declares `:core` as an `api` dependency, so this file owns only
// the typed member accessors the fixtures need — never a second parser.

package com.phonedsh.controller

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.io.File

internal fun JsonObject.str(key: String): String =
    optStr(key) ?: throw IllegalArgumentException("missing string member '$key'")

internal fun JsonObject.optStr(key: String): String? = when (val value = members[key]) {
    null, JsonNull -> null
    is JsonString -> value.value
    else -> throw IllegalArgumentException("member '$key' is not a string")
}

internal fun JsonObject.int(key: String): Int {
    val number = members[key] as? JsonNumber
        ?: throw IllegalArgumentException("missing numeric member '$key'")
    val exact = number.asLongOrNull()
        ?: throw IllegalArgumentException("member '$key' is not an integer: ${number.raw}")
    require(exact in Int.MIN_VALUE..Int.MAX_VALUE) { "member '$key' does not fit in an Int" }
    return exact.toInt()
}

internal fun JsonObject.arr(key: String): List<JsonValue> =
    (members[key] as? JsonArray)?.values
        ?: throw IllegalArgumentException("missing array member '$key'")

internal fun JsonObject.obj(key: String): JsonObject =
    members[key] as? JsonObject
        ?: throw IllegalArgumentException("missing object member '$key'")

internal fun JsonObject.optBool(key: String): Boolean? = when (val value = members[key]) {
    null, JsonNull -> null
    is JsonBool -> value.value
    else -> throw IllegalArgumentException("member '$key' is not a boolean")
}

internal fun JsonValue.asObj(context: String): JsonObject =
    this as? JsonObject ?: throw IllegalArgumentException("$context is not an object")

internal fun JsonValue.asStr(context: String): String =
    (this as? JsonString)?.value ?: throw IllegalArgumentException("$context is not a string")

/** One perturbation fixture. */
internal class Fixture(val file: File, val root: JsonObject) {
    val id: String get() = root.str("id")
    val verb: String get() = root.str("verb")
    val preconditions: JsonObject get() = root.obj("preconditions")
    val timeline: List<JsonObject>
        get() = root.arr("timeline").mapIndexed { index, value ->
            value.asObj("$id timeline[$index]")
        }

    val expected: JsonObject get() = root.obj("expected")
    val fieldEvidence: Map<String, JsonValue> get() = expected.obj("field_evidence").members
}

/** Loads the 16 normative fixtures from `spec/v1/golden/perturbations/`. */
internal object Fixtures {
    const val EXPECTED_COUNT: Int = 16
    const val SPEC_RELATIVE_DIR: String = "spec/v1/golden/perturbations"

    fun loadAll(): List<Fixture> {
        val files = directory().listFiles { file -> file.isFile && file.extension == "json" }
            ?: error("cannot list $SPEC_RELATIVE_DIR")
        return files.sortedBy { it.name }.map { file ->
            Fixture(file, JsonValue.parse(file.readText(Charsets.UTF_8)).asObj(file.name))
        }
    }

    fun load(id: String): Fixture =
        loadAll().firstOrNull { it.id == id } ?: error("no perturbation fixture with id $id")

    /** The fixture directory, located by the shared repository-root walk. */
    fun directory(): File = RepoRoot.file(SPEC_RELATIVE_DIR)
}

// :testkit trajectory — the two normative schemas and the shape gate before stage 1.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.trajectory

import java.io.IOException
import java.math.BigDecimal
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.util.concurrent.ConcurrentHashMap
import java.util.regex.Pattern
import java.util.regex.PatternSyntaxException

/**
 * The two schema documents of `spec/v1/schema`, loaded from the repository tree exactly as the
 * oracle's `load_schemas` does.
 *
 * Shape is the schema's job; noise removal never comes from a schema. The validator implements
 * the same JSON Schema subset as `validate_json` in `spec/v1/tools/spec_golden.py`: `type`,
 * `const`, `enum`, `pattern` (full match), `minLength`/`maxLength` in code points,
 * `minimum`/`maximum` on integers, `required`, `properties`, `additionalProperties`,
 * `propertyNames`, `dependentRequired`, `items`, `minItems`, `maxItems`, `uniqueItems` and
 * `oneOf`. No external validator is added.
 */
public class TrajectorySchemas private constructor(
    internal val trajectory: JsonTree,
    internal val uiState: JsonTree,
) {
    internal fun schemaFor(kind: RowKind): JsonTree = when (kind) {
        RowKind.TRAJECTORY -> trajectory
        RowKind.UI_STATE -> uiState
    }

    public companion object {
        private val CACHE = ConcurrentHashMap<Path, TrajectorySchemas>()

        /** Loads both schemas from `<repoRoot>/spec/v1/schema` (cached by resolved root). */
        public fun load(repoRoot: Path): TrajectorySchemas {
            val root = repoRoot.toAbsolutePath().normalize()
            val cached = CACHE[root]
            if (cached != null) return cached
            val loaded = loadUncached(root)
            CACHE[root] = loaded
            return loaded
        }

        /**
         * Loads the schemas from the repository root derived from `pdsh.repo.root`, or by
         * walking up from the working directory. No machine-local absolute path is embedded;
         * a caller outside the repository must pass an explicit root to [load].
         */
        public fun loadDefault(): TrajectorySchemas = load(defaultRepoRoot())

        private fun defaultRepoRoot(): Path {
            val property = System.getProperty("pdsh.repo.root")
            if (!property.isNullOrEmpty()) return Paths.get(property)
            var candidate: Path? = Paths.get("").toAbsolutePath().normalize()
            val marker = Paths.get("spec/v1/schema/trajectory.schema.json")
            while (candidate != null) {
                if (Files.isRegularFile(candidate.resolve(marker))) return candidate
                candidate = candidate.parent
            }
            throw NormError(
                "SCHEMA",
                "spec/v1/schema",
                "cannot locate the repository root; set the pdsh.repo.root system property",
            )
        }

        private fun loadUncached(root: Path): TrajectorySchemas {
            val directory = root.resolve("spec/v1/schema")
            return TrajectorySchemas(
                trajectory = readSchema(directory.resolve("trajectory.schema.json")),
                uiState = readSchema(directory.resolve("ui-state-sequence.schema.json")),
            )
        }

        private fun readSchema(path: Path): JsonTree {
            val text = try {
                String(Files.readAllBytes(path), Charsets.UTF_8)
            } catch (failure: IOException) {
                throw NormError("SCHEMA", path.toString(), failure.message ?: "cannot read schema", failure)
            }
            return try {
                JsonTreeCodec.parseDocument(text, path.toString())
            } catch (failure: NormError) {
                throw NormError("SCHEMA", path.toString(), failure.detail, failure)
            }
        }
    }
}

/** The `validate_json` port; every violation is a `NormError("SCHEMA", ...)`. */
internal object TrajectorySchemaValidator {
    private val PATTERNS = ConcurrentHashMap<String, Pattern>()

    /** Schema validation plus the oracle's `schemaVersion`-matches-kind check. */
    fun validateRow(row: JsonTree, schema: JsonTree, kind: RowKind, where: String) {
        validate(row, schema, where, "$")
        val version = (row as? JsonObjectTree)?.string("schemaVersion")
        if (version != kind.schemaVersion) {
            throw NormError(
                "SCHEMA",
                where,
                "schemaVersion '$version' does not match ${kind.schemaVersion}",
            )
        }
    }

    fun validate(instance: JsonTree, schema: JsonTree, where: String, path: String) {
        val schemaObject = schema as? JsonObjectTree
            ?: throw NormError("SCHEMA", where, "schema at $path is not an object")

        val oneOf = schemaObject["oneOf"]
        if (oneOf != null) {
            val variants = (oneOf as? JsonArrayTree)?.items
            if (variants.isNullOrEmpty()) throw NormError("SCHEMA", where, "malformed oneOf at $path")
            var matches = 0
            var firstFailure: String? = null
            for (variant in variants) {
                try {
                    validate(instance, variant, where, path)
                    matches++
                } catch (failure: NormError) {
                    if (firstFailure == null) firstFailure = failure.detail
                }
            }
            if (matches != 1) {
                val detail = if (firstFailure != null) "; first mismatch: $firstFailure" else ""
                throw NormError(
                    "SCHEMA",
                    where,
                    "$path matches $matches oneOf variants, expected exactly 1$detail",
                )
            }
            return
        }

        val type = schemaObject["type"]
        if (type != null) {
            val names = when (type) {
                is JsonStringTree -> listOf(type.value)
                is JsonArrayTree -> type.items.mapNotNull { (it as? JsonStringTree)?.value }
                else -> emptyList()
            }
            if (names.isEmpty() || names.none { typeOk(instance, it) }) {
                throw NormError("SCHEMA", where, "$path has the wrong JSON type for $names")
            }
        }

        val constant = schemaObject["const"]
        if (constant != null && !jsonEqual(instance, constant)) {
            throw NormError("SCHEMA", where, "$path value is not the required constant")
        }

        val choices = schemaObject["enum"]
        if (choices != null) {
            val items = (choices as? JsonArrayTree)?.items
            if (items == null || items.none { jsonEqual(instance, it) }) {
                throw NormError("SCHEMA", where, "$path value is not in the enum")
            }
        }

        if (instance is JsonStringTree) {
            val pattern = schemaObject.string("pattern")
            if (pattern != null) {
                val compiled = PATTERNS.getOrPut(pattern) {
                    try {
                        Pattern.compile(pattern, Pattern.UNICODE_CHARACTER_CLASS)
                    } catch (failure: PatternSyntaxException) {
                        throw NormError("SCHEMA", where, "$path pattern does not compile: ${failure.description}")
                    }
                }
                if (!compiled.matcher(instance.value).matches()) {
                    throw NormError("SCHEMA", where, "$path value does not match the pattern")
                }
            }
            val minimumLength = schemaObject.integer("minLength")
            if (minimumLength != null &&
                PythonSemantics.codePointLength(instance.value) < minimumLength.toInt()
            ) {
                throw NormError("SCHEMA", where, "$path is shorter than $minimumLength")
            }
            val maximumLength = schemaObject.integer("maxLength")
            if (maximumLength != null &&
                PythonSemantics.codePointLength(instance.value) > maximumLength.toInt()
            ) {
                throw NormError("SCHEMA", where, "$path is longer than $maximumLength")
            }
        }

        if (instance is JsonNumberTree && instance.value is JsonNum.IntValue) {
            val value = (instance.value as JsonNum.IntValue).value
            val minimum = schemaObject.integer("minimum")
            if (minimum != null && value < minimum) {
                throw NormError("SCHEMA", where, "$path is below $minimum")
            }
            val maximum = schemaObject.integer("maximum")
            if (maximum != null && value > maximum) {
                throw NormError("SCHEMA", where, "$path is above $maximum")
            }
        }

        if (instance is JsonObjectTree) {
            val required = (schemaObject["required"] as? JsonArrayTree)?.items
                ?.mapNotNull { (it as? JsonStringTree)?.value }
                .orEmpty()
            for (name in required) {
                if (name !in instance.members) {
                    throw NormError("SCHEMA", where, "$path is missing required member '$name'")
                }
            }
            val properties = schemaObject["properties"] as? JsonObjectTree
            if (schemaObject["properties"] != null && properties == null) {
                throw NormError("SCHEMA", where, "malformed properties at $path")
            }
            val propertyNames = schemaObject["propertyNames"] as? JsonObjectTree
            if (propertyNames != null) {
                for (name in instance.members.keys) {
                    validate(JsonStringTree(name), propertyNames, where, "$path member name")
                }
            }
            val dependentRequired = schemaObject["dependentRequired"] as? JsonObjectTree
            if (dependentRequired != null) {
                for ((name, neededValue) in dependentRequired.members) {
                    if (name !in instance.members) continue
                    val needed = (neededValue as? JsonArrayTree)?.items
                        ?.mapNotNull { (it as? JsonStringTree)?.value }
                        ?: throw NormError("SCHEMA", where, "malformed dependentRequired at $path")
                    for (other in needed) {
                        if (other !in instance.members) {
                            throw NormError("SCHEMA", where, "$path member '$name' requires '$other'")
                        }
                    }
                }
            }
            val additional = schemaObject["additionalProperties"]
            for ((name, value) in instance.members) {
                if (properties != null && name in properties.members) {
                    validate(value, properties.members.getValue(name), where, "$path.$name")
                } else {
                    when (additional) {
                        is JsonBoolTree -> if (!additional.value) {
                            throw NormError("SCHEMA", where, "$path has unexpected member '$name'")
                        }
                        is JsonObjectTree -> validate(value, additional, where, "$path.$name")
                        else -> Unit
                    }
                }
            }
        }

        if (instance is JsonArrayTree) {
            val minimumItems = schemaObject.integer("minItems")
            if (minimumItems != null && instance.items.size < minimumItems.toInt()) {
                throw NormError("SCHEMA", where, "$path has fewer than $minimumItems items")
            }
            val maximumItems = schemaObject.integer("maxItems")
            if (maximumItems != null && instance.items.size > maximumItems.toInt()) {
                throw NormError("SCHEMA", where, "$path has more than $maximumItems items")
            }
            if ((schemaObject["uniqueItems"] as? JsonBoolTree)?.value == true) {
                for (left in instance.items.indices) {
                    for (right in left + 1 until instance.items.size) {
                        if (jsonEqual(instance.items[left], instance.items[right])) {
                            throw NormError("SCHEMA", where, "$path violates uniqueItems")
                        }
                    }
                }
            }
            val itemSchema = schemaObject["items"]
            if (itemSchema != null) {
                for ((index, item) in instance.items.withIndex()) {
                    validate(item, itemSchema, where, "$path[$index]")
                }
            }
        }
    }

    private fun typeOk(instance: JsonTree, name: String): Boolean = when (name) {
        "object" -> instance is JsonObjectTree
        "array" -> instance is JsonArrayTree
        "string" -> instance is JsonStringTree
        "integer" -> instance is JsonNumberTree && instance.value is JsonNum.IntValue
        "number" -> instance is JsonNumberTree
        "boolean" -> instance is JsonBoolTree
        "null" -> instance is JsonNullTree
        else -> false
    }

    /** Python `_json_equal`: booleans never equal numbers; numbers compare numerically. */
    private fun jsonEqual(left: JsonTree, right: JsonTree): Boolean {
        if (left is JsonBoolTree || right is JsonBoolTree) {
            return left is JsonBoolTree && right is JsonBoolTree && left.value == right.value
        }
        if (left is JsonNumberTree && right is JsonNumberTree) {
            return numberEquals(left.value, right.value)
        }
        return when {
            left is JsonNullTree && right is JsonNullTree -> true
            left is JsonStringTree && right is JsonStringTree -> left.value == right.value
            left is JsonArrayTree && right is JsonArrayTree ->
                left.items.size == right.items.size &&
                    left.items.indices.all { jsonEqual(left.items[it], right.items[it]) }
            left is JsonObjectTree && right is JsonObjectTree ->
                left.members.keys == right.members.keys &&
                    left.members.all { (name, value) -> jsonEqual(value, right.members.getValue(name)) }
            else -> false
        }
    }

    private fun numberEquals(left: JsonNum, right: JsonNum): Boolean = when {
        left is JsonNum.IntValue && right is JsonNum.IntValue -> left.value == right.value
        left is JsonNum.FloatValue && right is JsonNum.FloatValue -> left.value == right.value
        left is JsonNum.IntValue && right is JsonNum.FloatValue ->
            right.value.isFinite() && BigDecimal(left.value).compareTo(BigDecimal(right.value)) == 0
        left is JsonNum.FloatValue && right is JsonNum.IntValue ->
            left.value.isFinite() && BigDecimal(left.value).compareTo(BigDecimal(right.value)) == 0
        else -> false
    }
}

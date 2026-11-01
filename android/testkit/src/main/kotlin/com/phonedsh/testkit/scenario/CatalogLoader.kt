// :testkit scenario — the strict catalog loader (the Kotlin consumer of catalog.json).
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.scenario

import com.phonedsh.agentcore.HarnessDecodingException
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.io.File
import java.io.IOException

/**
 * A catalog document that violates the schema, a cross-field invariant, or the
 * relative-path policy. Always names the JSON location (`scenarios[3].assertions[2]`).
 */
public class ScenarioCatalogException(
    message: String,
    cause: Throwable? = null,
) : IllegalArgumentException(message, cause)

/**
 * Decodes the normative scenario catalog into [ScenarioCatalog].
 *
 * JSON is parsed with the dependency-free `:core` value parser
 * (`JsonValue.parse`); no `kotlinx.serialization`, no `org.json` and no new
 * external dependency is involved, so the loader runs unchanged on a plain JVM,
 * in an Android unit test and on a device.
 *
 * The open/closed policy is the schemas', not a local preference:
 *
 * * the document, `scenario`, `workspace`, `turn`, `budget` and `fixture`
 *   objects are **open** — unknown members are ignored, so an additive catalog
 *   field never breaks this runner;
 * * an **assertion** object is **closed** — an unknown member is an error,
 *   because a mistyped optional bound would otherwise become a silent no-op;
 * * a missing required member, a wrong JSON type, an out-of-range integer, an
 *   unknown assertion type, an unknown fixture reference and a duplicate id are
 *   errors. Nothing is skipped quietly;
 * * paths (`workspace.files` keys and assertion `path`s) must be relative, with
 *   no `..` segment and no home-relative form, because they are materialized
 *   inside the workspace namespace (`catalog_check.py`'s path policy);
 * * the `budgets` block is **closed** and range-checked, and every
 *   `{{budgets.<name>}}` reference in a title, story, prompt, assertion value
 *   or assertion command is expanded at load time from that same block (the
 *   port of `ScenarioBudgetPlaceholders`). A reference without a declaration,
 *   an unknown name or a leftover malformed reference fails the load.
 *
 * The loaded [ScenarioCatalog] is also the input of the cross-field checks
 * `catalog_check.py` performs for `catalog.json`: duplicate scenario ids and
 * unknown fixture references. `run_plan` is deliberately not decoded: the
 * schema says it is not decoded by a runner (`run_plan` is batch-plan data for
 * `scenario_batch.py`), and its counts and lane coverage are `catalog_check.py`'s
 * invariant. Ignoring it is the document's documented open-object policy, not a
 * silent skip: the loader still hard-fails on everything a runner consumes.
 */
public object CatalogLoader {
    private val SCENARIO_ID = Regex("^[A-Za-z0-9._-]{1,64}$")
    private val WINDOWS_ABSOLUTE_PATH = Regex("""^[A-Za-z]:[\\/]""")
    private val PERTURBATION_AT = Regex("""^(after_turn:[1-9][0-9]*|during_first_tool|minute:[1-9][0-9]*)$""")
    private val PERTURBATION_KINDS = setOf("planned_restart", "park_resume", "worker_kill", "webcontent_kill")
    private val TARGETS = setOf("both", "macos", "sim")

    /** The `{{budgets.<name>}}` reference grammar (exactly `ScenarioBudgetPlaceholders.pattern`). */
    private val BUDGET_REFERENCE = Regex("""\{\{budgets\.([A-Za-z][A-Za-z0-9]*)\}\}""")

    /** Every budget reference name the catalog schema knows, including render-only ones. */
    private val KNOWN_BUDGET_REFERENCES = setOf("singleFileBytes", "singleFileBytesGrouped", "singleFileMiB")

    private const val MEBIBYTE = 1024 * 1024

    /** The eight catalog assertion types, in the assertion schema's order. */
    private val ASSERTION_TYPES = listOf(
        "file_contains",
        "file_exists",
        "file_regex",
        "no_console_error",
        "no_file",
        "restart_recovered",
        "turn_count_lte",
        "workspace_command",
    )

    /** Reads and decodes [file] (UTF-8); the file name is used in diagnostics. */
    public fun load(file: File): ScenarioCatalog {
        val text = try {
            file.readText(Charsets.UTF_8)
        } catch (failure: IOException) {
            throw ScenarioCatalogException("cannot read scenario catalog '${file.name}': ${failure.message}", failure)
        }
        return load(text, file.name)
    }

    /**
     * Decodes one catalog document.
     *
     * [source] is only a diagnostic label (a file name or `"<memory>"`); it is
     * never interpreted as a path and is never joined with anything.
     */
    public fun load(json: String, source: String = "<memory>"): ScenarioCatalog {
        val parsed = try {
            JsonValue.parse(json)
        } catch (failure: HarnessDecodingException) {
            throw ScenarioCatalogException("$source: invalid JSON: ${failure.message}", failure)
        }
        val root = parsed as? JsonObject ?: fail(source, "the catalog document must be a JSON object")

        val version = root.requiredInt("version", source)
        if (version != 1) fail(source, "'version' must be 1; got $version")
        val generatedBy = root.requiredString("generated_by", source, maxLength = 512)

        val fixtureArray = root.required("fixtures", source).asArrayOrFail("$source: fixtures")
        val fixtures = fixtureArray.values.mapIndexed { index, value ->
            parseFixture(value, "$source: fixtures[$index]")
        }
        checkUnique(fixtures.map { it.name }, source, "fixture name")

        val scenarioArray = root.required("scenarios", source).asArrayOrFail("$source: scenarios")
        if (scenarioArray.values.isEmpty()) fail("$source: scenarios", "must have at least one scenario")
        val fixtureNames = fixtures.map { it.name }.toSet()
        val scenarios = scenarioArray.values.mapIndexed { index, value ->
            parseScenario(value, "$source: scenarios[$index]", fixtureNames)
        }
        checkUnique(scenarios.map { it.id }, source, "scenario id")

        return ScenarioCatalog(
            version = version,
            generatedBy = generatedBy,
            scenarios = scenarios,
            fixtures = fixtures,
        )
    }

    // --------------------------------------------------------------- fixtures

    private fun parseFixture(value: JsonValue, where: String): ScenarioFixture {
        val obj = value as? JsonObject ?: fail(where, "a fixture must be a JSON object")
        val name = obj.requiredString("name", where, maxLength = 64)
        if (!SCENARIO_ID.matches(name)) {
            fail(where, "fixture name '$name' does not match ^[A-Za-z0-9._-]{1,64}$")
        }
        val description = obj.optionalString("description", where)
        return ScenarioFixture(name = name, description = description)
    }

    // -------------------------------------------------------------- scenarios

    private fun parseScenario(value: JsonValue, where: String, fixtureNames: Set<String>): Scenario {
        val obj = value as? JsonObject ?: fail(where, "a scenario must be a JSON object")
        val id = obj.requiredString("id", where, maxLength = 64)
        if (!SCENARIO_ID.matches(id)) {
            fail(where, "scenario id '$id' does not match ^[A-Za-z0-9._-]{1,64}$")
        }

        val budgets = parseBudgets(obj.members["budgets"], "$where.budgets")

        val workspace = parseWorkspace(obj.required("workspace", where), where, fixtureNames)
        val turnArray = obj.required("turns", where).asArrayOrFail("$where.turns")
        if (turnArray.values.isEmpty()) fail("$where.turns", "must have at least one turn")
        val turns = turnArray.values.mapIndexed { index, turnValue ->
            val turnWhere = "$where.turns[$index]"
            val turn = turnValue as? JsonObject ?: fail(turnWhere, "a turn must be a JSON object")
            val prompt = turn.requiredString("prompt", turnWhere)
            ScenarioTurn(expandBudgetReferences(prompt, budgets, "$turnWhere.prompt"))
        }

        val assertionArray = obj.required("assertions", where).asArrayOrFail("$where.assertions")
        if (assertionArray.values.isEmpty()) fail("$where.assertions", "must have at least one assertion")
        val assertions = assertionArray.values.mapIndexed { index, assertionValue ->
            val assertionWhere = "$where.assertions[$index]"
            expandAssertion(parseAssertion(assertionValue, assertionWhere), budgets, assertionWhere)
        }

        val budgetObject = obj.required("budget", where) as? JsonObject
            ?: fail("$where.budget", "must be a JSON object")
        val budget = ScenarioBudget(
            maxMinutes = budgetObject.requiredInt("max_minutes", "$where.budget"),
            maxModelRequests = budgetObject.requiredInt("max_model_requests", "$where.budget"),
        )

        val tags = obj.optionalArray("tags", where)?.values?.mapIndexed { index, tagValue ->
            val tag = (tagValue as? JsonString)?.value
                ?: fail("$where.tags[$index]", "a tag must be a string")
            if (tag.isEmpty()) fail("$where.tags[$index]", "a tag must not be empty")
            tag
        } ?: emptyList()

        val target = obj.optionalString("target", where)?.also { value ->
            if (value !in TARGETS) fail(where, "'target' must be one of ${TARGETS.sorted()}; got '$value'")
        }

        val perturbations = obj.optionalArray("perturbations", where)?.values?.mapIndexed { index, perturbationValue ->
            val perturbationWhere = "$where.perturbations[$index]"
            val perturbation = perturbationValue as? JsonObject
                ?: fail(perturbationWhere, "a perturbation must be a JSON object")
            val at = perturbation.requiredString("at", perturbationWhere)
            if (!PERTURBATION_AT.matches(at)) {
                fail(perturbationWhere, "'at' must match after_turn:<n>, during_first_tool or minute:<n>; got '$at'")
            }
            val kind = perturbation.requiredString("kind", perturbationWhere)
            if (kind !in PERTURBATION_KINDS) {
                fail(perturbationWhere, "'kind' must be one of ${PERTURBATION_KINDS.sorted()}; got '$kind'")
            }
            ScenarioPerturbation(at = at, kind = kind)
        } ?: emptyList()

        return Scenario(
            id = id,
            category = obj.requiredString("category", where, maxLength = 64),
            title = expandBudgetReferences(obj.requiredString("title", where), budgets, "$where.title"),
            userStory = expandBudgetReferences(
                obj.requiredString("user_story", where),
                budgets,
                "$where.user_story",
            ),
            workspace = workspace,
            turns = turns,
            assertions = assertions,
            budget = budget,
            budgets = budgets,
            tags = tags,
            target = target,
            perturbations = perturbations,
        )
    }

    private fun parseWorkspace(value: JsonValue, scenarioWhere: String, fixtureNames: Set<String>): ScenarioWorkspace {
        val where = "$scenarioWhere.workspace"
        val obj = value as? JsonObject ?: fail(where, "must be a JSON object")
        val filesObject = obj.required("files", where) as? JsonObject
            ?: fail("$where.files", "must be a JSON object")
        val files = LinkedHashMap<String, String>()
        for ((path, contentValue) in filesObject.members) {
            validateRelativePath(path, "$where.files")
            val content = (contentValue as? JsonString)?.value
                ?: fail("$where.files", "the content of '$path' must be a string")
            files[path] = content
        }
        val fixture = obj.optionalString("fixture", where)?.also { name ->
            if (!SCENARIO_ID.matches(name)) {
                fail(where, "fixture reference '$name' does not match ^[A-Za-z0-9._-]{1,64}$")
            }
            if (name !in fixtureNames) {
                fail(where, "references unknown fixture '$name'; declared fixtures: ${fixtureNames.sorted().joinToString(", ")}")
            }
        }
        return ScenarioWorkspace(files = files, fixture = fixture)
    }

    // ---------------------------------------------------------------- budgets

    /**
     * The scenario's optional `budgets` block. The schema closes it
     * (`additionalProperties: false`), so an unknown key is reported by name; an
     * out-of-range value is rejected rather than clamped, because a clamped
     * premise would silently measure a different machine (G2-FIX-115).
     */
    private fun parseBudgets(value: JsonValue?, where: String): ScenarioBudgets? {
        if (value == null) return null
        val obj = value as? JsonObject ?: fail(where, "must be a JSON object")
        val allowed = setOf("singleFileBytes")
        val unknown = obj.members.keys - allowed
        if (unknown.isNotEmpty()) {
            fail(
                where,
                "unknown budgets key '${unknown.sorted().first()}'; " +
                    "allowed keys: ${allowed.sorted().joinToString(", ")}",
            )
        }
        val bytes = obj.members["singleFileBytes"]?.let { raw ->
            val number = raw as? JsonNumber ?: fail("$where.singleFileBytes", "must be an integer")
            val rawValue = number.asLongOrNull() ?: fail("$where.singleFileBytes", "must be an integer")
            if (rawValue < ScenarioBudgets.MINIMUM_SINGLE_FILE_BYTES.toLong() ||
                rawValue > ScenarioBudgets.MAXIMUM_SINGLE_FILE_BYTES.toLong()
            ) {
                fail(
                    "$where.singleFileBytes",
                    "is $rawValue, outside the supported range " +
                        "${ScenarioBudgets.MINIMUM_SINGLE_FILE_BYTES}..." +
                        "${ScenarioBudgets.MAXIMUM_SINGLE_FILE_BYTES} bytes (16...256 MiB)",
                )
            }
            rawValue.toInt()
        }
        return ScenarioBudgets(singleFileBytes = bytes)
    }

    /**
     * Expands `{{budgets.<name>}}` from [budgets], the port of
     * `ScenarioBudgetPlaceholders.expand`. Only the explicit `budgets.`
     * namespace is touched, so a workspace payload such as `{{CANDIDATE}}`
     * (used by G2-E08) survives untouched. A reference without a declaration,
     * an unknown name and a leftover malformed reference all fail loud.
     */
    private fun expandBudgetReferences(text: String, budgets: ScenarioBudgets?, where: String): String {
        if (!text.contains("{{budgets.")) return text
        val bytes = budgets?.singleFileBytes ?: fail(
            where,
            "references a {{budgets.*}} figure but the scenario has no " +
                "budgets.singleFileBytes declaration",
        )
        val values = budgetValues(bytes)
        val matches = BUDGET_REFERENCE.findAll(text).toList()
        if (matches.isEmpty()) {
            fail(
                where,
                "malformed budget reference; expected {{budgets.<name>}}; known references: " +
                    knownBudgetReferences(),
            )
        }
        var expanded = text
        for (match in matches.asReversed()) {
            val name = match.groupValues[1]
            if (name !in KNOWN_BUDGET_REFERENCES) {
                fail(
                    where,
                    "unknown budget reference \"{{budgets.$name}}\"; known references: " +
                        knownBudgetReferences(),
                )
            }
            val replacement = values[name] ?: fail(
                where,
                "{{budgets.$name}} is unavailable: singleFileBytes=$bytes is not a whole " +
                    "number of MiB",
            )
            expanded = expanded.substring(0, match.range.first) + replacement +
                expanded.substring(match.range.last + 1)
        }
        if (expanded.contains("{{budgets.")) {
            fail(
                where,
                "unresolved budget reference; expected {{budgets.<name>}}; known references: " +
                    knownBudgetReferences(),
            )
        }
        return expanded
    }

    /** The figures one `singleFileBytes` declaration exposes, exactly as Swift renders them. */
    private fun budgetValues(bytes: Int): Map<String, String> {
        val values = LinkedHashMap<String, String>()
        values["singleFileBytes"] = bytes.toString()
        values["singleFileBytesGrouped"] = groupDigits(bytes)
        if (bytes % MEBIBYTE == 0) values["singleFileMiB"] = (bytes / MEBIBYTE).toString()
        return values
    }

    /** `16777216` -> `16,777,216`, independent of the process locale. */
    private fun groupDigits(value: Int): String {
        val digits = value.toString()
        val out = StringBuilder(digits.length + digits.length / 3)
        for ((offset, digit) in digits.withIndex()) {
            if (offset > 0 && (digits.length - offset) % 3 == 0) out.append(',')
            out.append(digit)
        }
        return out.toString()
    }

    private fun knownBudgetReferences(): String = KNOWN_BUDGET_REFERENCES.sorted().joinToString(", ")

    /** Rebuilds an assertion with its `value`/`command` budget references resolved. */
    private fun expandAssertion(
        assertion: ScenarioAssertion,
        budgets: ScenarioBudgets?,
        where: String,
    ): ScenarioAssertion = when (assertion) {
        is ScenarioAssertion.FileContains -> assertion.copy(
            value = expandBudgetReferences(assertion.value, budgets, "$where.value"),
        )
        is ScenarioAssertion.FileRegex -> assertion.copy(
            value = expandBudgetReferences(assertion.value, budgets, "$where.value"),
        )
        is ScenarioAssertion.WorkspaceCommand -> assertion.copy(
            command = expandBudgetReferences(assertion.command, budgets, "$where.command"),
        )
        else -> assertion
    }

    // ------------------------------------------------------------- assertions

    private fun parseAssertion(value: JsonValue, where: String): ScenarioAssertion {
        val obj = value as? JsonObject ?: fail(where, "an assertion must be a JSON object")
        val type = obj.requiredString("type", where, maxLength = 64)
        return when (type) {
            "file_exists" -> {
                obj.rejectUnknownMembers(where, setOf("type", "path"))
                ScenarioAssertion.FileExists(obj.assertionPath(where))
            }
            "no_file" -> {
                obj.rejectUnknownMembers(where, setOf("type", "path"))
                ScenarioAssertion.NoFile(obj.assertionPath(where))
            }
            "file_contains" -> {
                obj.rejectUnknownMembers(where, setOf("type", "path", "value"))
                ScenarioAssertion.FileContains(obj.assertionPath(where), obj.assertionValue(where))
            }
            "file_regex" -> {
                obj.rejectUnknownMembers(where, setOf("type", "path", "value"))
                ScenarioAssertion.FileRegex(obj.assertionPath(where), obj.assertionValue(where))
            }
            "no_console_error" -> {
                obj.rejectUnknownMembers(where, setOf("type"))
                ScenarioAssertion.NoConsoleError
            }
            "restart_recovered" -> {
                obj.rejectUnknownMembers(where, setOf("type"))
                ScenarioAssertion.RestartRecovered
            }
            "turn_count_lte" -> {
                obj.rejectUnknownMembers(where, setOf("type", "max"))
                ScenarioAssertion.TurnCountLte(obj.requiredInt("max", where, min = 0))
            }
            "workspace_command" -> {
                obj.rejectUnknownMembers(where, setOf("type", "command"))
                ScenarioAssertion.WorkspaceCommand(obj.requiredString("command", where))
            }
            else -> fail(
                where,
                "unknown assertion type '$type'; allowed: ${ASSERTION_TYPES.joinToString(", ")}",
            )
        }
    }

    private fun JsonObject.assertionPath(where: String): String =
        validateRelativePath(requiredString("path", where), where, maxLength = 1024)

    private fun JsonObject.assertionValue(where: String): String = requiredString("value", where)

    /**
     * The relative-path policy shared by `workspace.files` keys and assertion
     * paths: no absolute POSIX/Windows path, no `~`, no `..` segment. The
     * assertion schema's own `^(?!/).+$` pattern is a subset of this check.
     */
    private fun validateRelativePath(path: String, where: String, maxLength: Int? = null): String {
        if (path.isEmpty()) fail(where, "path must not be empty")
        if (maxLength != null && path.length > maxLength) {
            fail(where, "path is longer than $maxLength characters")
        }
        if (path.startsWith("/")) fail(where, "absolute path '$path' is not allowed")
        if (WINDOWS_ABSOLUTE_PATH.containsMatchIn(path)) fail(where, "absolute path '$path' is not allowed")
        if (path == "~" || path.startsWith("~/")) fail(where, "home-relative path '$path' is not allowed")
        if (path.split('/').contains("..")) fail(where, "path '$path' must not contain '..'")
        return path
    }

    // ----------------------------------------------------------------- helpers

    private fun JsonObject.required(name: String, where: String): JsonValue =
        members[name] ?: fail(where, "missing required member '$name'")

    private fun JsonObject.requiredString(
        name: String,
        where: String,
        minLength: Int = 1,
        maxLength: Int = Int.MAX_VALUE,
    ): String {
        val value = required(name, where) as? JsonString ?: fail(where, "'$name' must be a string")
        if (value.value.length < minLength) fail(where, "'$name' must not be empty")
        if (value.value.length > maxLength) fail(where, "'$name' is longer than $maxLength characters")
        return value.value
    }

    private fun JsonObject.optionalString(name: String, where: String): String? {
        val value = members[name] ?: return null
        val text = value as? JsonString ?: fail(where, "'$name' must be a string")
        if (text.value.isEmpty()) fail(where, "'$name' must not be empty")
        return text.value
    }

    private fun JsonObject.optionalArray(name: String, where: String): JsonArray? {
        val value = members[name] ?: return null
        return value as? JsonArray ?: fail(where, "'$name' must be an array")
    }

    private fun JsonObject.requiredInt(name: String, where: String, min: Int = 0): Int {
        val value = required(name, where) as? JsonNumber ?: fail(where, "'$name' must be an integer")
        val number = value.asLongOrNull() ?: fail(where, "'$name' must be an integer")
        if (number < min) fail(where, "'$name' must be >= $min")
        if (number > Int.MAX_VALUE) fail(where, "'$name' is out of range")
        return number.toInt()
    }

    /**
     * Assertion objects are closed. The message names every offending member so
     * a generator typo (`maxium`, `command _`) is fixed in one pass instead of
     * silently disappearing.
     */
    private fun JsonObject.rejectUnknownMembers(where: String, allowed: Set<String>) {
        val unknown = members.keys - allowed
        if (unknown.isNotEmpty()) {
            fail(
                where,
                "unknown assertion member(s) ${unknown.sorted().joinToString { "'$it'" }}; " +
                    "assertion objects are closed (allowed: ${allowed.sorted().joinToString(", ")})",
            )
        }
    }

    private fun JsonValue.asArrayOrFail(where: String): JsonArray =
        this as? JsonArray ?: fail(where, "must be a JSON array")

    private fun checkUnique(names: List<String>, where: String, label: String) {
        val seen = HashSet<String>()
        for (name in names) {
            if (!seen.add(name)) fail(where, "duplicate $label '$name'")
        }
    }

    private fun fail(where: String, detail: String): Nothing =
        throw ScenarioCatalogException("$where: $detail")
}

// :testkit scenario — the decoded catalog document and its scenario records.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.scenario

/**
 * The seeded workspace of one scenario
 * (`scenario-catalog.schema.json` `properties.scenarios.items.workspace`).
 *
 * [files] is `path -> content`; the keys are relative paths, because the
 * namespace is materialized inside the Worker VFS. A fixture payload (if
 * [fixture] is set) is copied first and these files override or add to it.
 * Unknown members of the `workspace` object are ignored, as the schema's
 * `additionalProperties: true` requires.
 */
public data class ScenarioWorkspace(
    public val files: Map<String, String>,
    public val fixture: String?,
)

/**
 * One user turn of a scenario. Only `prompt` is normative; the catalog's turn
 * objects are open, so any other member is ignored by [CatalogLoader].
 */
public data class ScenarioTurn(public val prompt: String)

/**
 * The declared per-scenario caps (`budget.max_minutes` and
 * `budget.max_model_requests`). They are upper bounds, not measurements, and
 * the third runner does not enforce wall/model budgets itself: it is a pure
 * harness that the caller drives.
 */
public data class ScenarioBudget(
    public val maxMinutes: Int,
    public val maxModelRequests: Int,
)

/**
 * One declared perturbation point (`perturbations[$i]`).
 *
 * [at] is `after_turn:<n>`, `during_first_tool` or `minute:<n>`; [kind] is one
 * of `planned_restart`, `park_resume`, `worker_kill`, `webcontent_kill`. The
 * runner does not inject faults: the caller's [ScenarioExecution] reports
 * whether the declared points recovered through [PerturbationCoverage].
 */
public data class ScenarioPerturbation(
    public val at: String,
    public val kind: String,
)

/**
 * One scenario's optional catalog `budgets` block: the resource premise the
 * scenario assumes (`"budgets": {"singleFileBytes": 16777216}`).
 *
 * This is deliberately **not** [ScenarioBudget] (the wall-clock/model caps): a
 * scenario may declare a machine with a non-default single-file limit, and that
 * figure is also the single source for every `{{budgets.<name>}}` reference in
 * its title, story, prompts and assertions. [CatalogLoader] expands those
 * references at load time (the same rule as `ScenarioBudgetPlaceholders` in
 * `Sources/PhoneDSHScenario/ScenarioBudgets.swift`), so every consumer sees the
 * same concrete number. The block is closed in the schema, so an unknown key is
 * a load error, not an ignored misspelling.
 */
public data class ScenarioBudgets(
    /** Declared single-file cap in bytes; `null` keeps the host tier default. */
    public val singleFileBytes: Int?,
) {
    public companion object {
        /** The `singleFileBytes` range the catalog schema accepts (16 MiB ... 256 MiB). */
        public const val MINIMUM_SINGLE_FILE_BYTES: Int = 16 * 1024 * 1024

        /** The `singleFileBytes` range the catalog schema accepts (16 MiB ... 256 MiB). */
        public const val MAXIMUM_SINGLE_FILE_BYTES: Int = 256 * 1024 * 1024
    }
}

/**
 * One catalog scenario, decoded with the schema's required members validated.
 *
 * Unknown scenario members (for example `rubric`, `network`, `mock`,
 * `assertions_extra`) are intentionally not carried: the scenario object is open
 * in the schema, and the third runner only needs the fields below. Assertion
 * objects are the closed exception and are validated per type by [CatalogLoader].
 */
public data class Scenario(
    public val id: String,
    public val category: String,
    public val title: String,
    public val userStory: String,
    public val workspace: ScenarioWorkspace,
    public val turns: List<ScenarioTurn>,
    public val assertions: List<ScenarioAssertion>,
    public val budget: ScenarioBudget,
    public val budgets: ScenarioBudgets? = null,
    public val tags: List<String> = emptyList(),
    public val target: String? = null,
    public val perturbations: List<ScenarioPerturbation> = emptyList(),
)

/** One named fixture payload (`fixtures[$i]`); the bytes live under `scripts/ci/scenarios/fixtures/<name>/files/`. */
public data class ScenarioFixture(
    public val name: String,
    public val description: String?,
)

/**
 * A fully validated catalog document.
 *
 * Every member a scenario runner consumes is decoded and checked:
 * [scenarios] (with their assertions, paths and budget references) and
 * [fixtures]. The document's `run_plan` is deliberately not carried: the
 * catalog schema says the runner does not decode it, `scenario_batch.py` owns
 * the lane plan and `catalog_check.py` owns its cross-field invariants.
 */
public data class ScenarioCatalog(
    public val version: Int,
    public val generatedBy: String,
    public val scenarios: List<Scenario>,
    public val fixtures: List<ScenarioFixture>,
) {
    /** Returns the scenario named [id], or throws with the ids that do exist. */
    public fun scenario(id: String): Scenario = scenarios.firstOrNull { it.id == id }
        ?: throw NoSuchElementException(
            "catalog has no scenario '$id'; known ids: ${scenarios.joinToString { it.id }}",
        )
}

// phone-dsh — :testkit scenario tests: shared JVM fixture, catalog pins and helpers.
// SPDX-License-Identifier: MIT
//
// The catalog under test is the checked-in scripts/ci/scenarios/catalog.json —
// the same document the macOS runner and the iOS Simulator runner consume. Its
// location comes from the `pdsh.repo.root` system property that
// :testkit/build.gradle.kts derives from the Gradle project root; no test
// carries a machine-local path and no test guesses the working directory.

package com.phonedsh.testkit.scenario

import com.phonedsh.testkit.scenario.memory.MemoryScenarioExecution
import java.io.File

internal object ShippedCatalog {
    val repoRoot: File = File(
        System.getProperty("pdsh.repo.root")
            ?: throw IllegalStateException(
                "pdsh.repo.root is not set; :testkit/build.gradle.kts must provide it",
            ),
    )
    val file: File get() = repoRoot.resolve("scripts/ci/scenarios/catalog.json")

    fun load(): ScenarioCatalog = CatalogLoader.load(file)
}

internal fun scenarioOf(
    assertions: List<ScenarioAssertion>,
    files: Map<String, String> = emptyMap(),
    turns: List<String> = listOf("do the task"),
    fixture: String? = null,
    id: String = "G2-TEST",
): Scenario = Scenario(
    id = id,
    category = "test",
    title = "test scenario",
    userStory = "a deterministic scenario owned by the runner tests",
    workspace = ScenarioWorkspace(files = files, fixture = fixture),
    turns = turns.map { ScenarioTurn(it) },
    assertions = assertions,
    budget = ScenarioBudget(maxMinutes = 1, maxModelRequests = 1),
)

internal fun runScenario(
    assertions: List<ScenarioAssertion>,
    files: Map<String, String> = emptyMap(),
    turns: List<String> = listOf("do the task"),
    fixtureRoot: File? = null,
    configure: MemoryScenarioExecution.() -> Unit = {},
): ScenarioReport {
    val execution = MemoryScenarioExecution().apply(configure)
    return ScenarioRunner(execution, fixtureRoot).run(scenarioOf(assertions, files, turns))
}

internal fun onlyResult(report: ScenarioReport): AssertionResult {
    if (report.assertions.size != 1) {
        throw AssertionError("expected exactly one assertion, got ${report.assertions.size}")
    }
    return report.assertions.single()
}

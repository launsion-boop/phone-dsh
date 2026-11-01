// :testkit scenario — the eight catalog assertion types as a closed Kotlin model.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.scenario

/**
 * One assertion of the normative scenario vocabulary
 * (`spec/v1/schema/scenario-assertion.schema.json`).
 *
 * The eight variants are exactly the schema's eight `oneOf` arms, in schema
 * declaration order. Each arm is closed (`additionalProperties: false`), which
 * is why [CatalogLoader] rejects an unknown member instead of ignoring it: a
 * misspelled optional bound (a mistyped `max`, say) would otherwise decode to
 * the default and turn the check into a silent no-op.
 *
 * Runner self-test-only types from `scripts/ci/scenarios/selftest.json`
 * (`model_requests_lte`, `worker_command`, `session_error`) are deliberately
 * outside this vocabulary, exactly as they are outside the catalog schema. A
 * document that carries one of them is rejected by [CatalogLoader], not
 * silently skipped.
 *
 * The evaluation rule for every variant is stated on [ScenarioRunner], which
 * mirrors `ScenarioAssertionEvaluator.evaluate` in
 * `Sources/PhoneDSHScenario/ScenarioAssertionGate.swift` case by case.
 */
public sealed interface ScenarioAssertion {
    /** The schema's `type` label; this is what [AssertionResult.type] carries. */
    public val type: String

    /**
     * `{"type":"file_exists","path":...}` — the path names a file in the
     * materialized workspace. Swift counterpart: `case "file_exists"`.
     */
    public data class FileExists(public val path: String) : ScenarioAssertion {
        override val type: String get() = "file_exists"
    }

    /**
     * `{"type":"no_file","path":...}` — the path names nothing in the
     * materialized workspace. Swift counterpart: `case "no_file"`.
     */
    public data class NoFile(public val path: String) : ScenarioAssertion {
        override val type: String get() = "no_file"
    }

    /**
     * `{"type":"file_contains","path":...,"value":...}` — a literal substring
     * check on a materialized file, no pattern syntax and no trimming. Swift
     * counterpart: `case "file_contains"` via `ScenarioFileContent.contains`.
     */
    public data class FileContains(public val path: String, public val value: String) : ScenarioAssertion {
        override val type: String get() = "file_contains"
    }

    /**
     * `{"type":"file_regex","path":...,"value":...}` — a regular expression
     * evaluated grep-style over a materialized file. Swift counterpart:
     * `case "file_regex"` via `ScenarioFileContent.matches`, which compiles the
     * pattern with `.anchorsMatchLines` so `^`/`$` anchor at every line.
     */
    public data class FileRegex(public val path: String, public val value: String) : ScenarioAssertion {
        override val type: String get() = "file_regex"
    }

    /**
     * `{"type":"no_console_error"}` — no error-level Worker console line or
     * host error event was recorded. Swift counterpart:
     * `case "no_console_error"`, evaluated against the one
     * `console_errors` source of truth.
     */
    public data object NoConsoleError : ScenarioAssertion {
        override val type: String get() = "no_console_error"
    }

    /**
     * `{"type":"turn_count_lte","max":...}` — the delivered scenario-turn count
     * must not exceed `max`. Swift counterpart: `case "turn_count_lte"` via
     * `ScenarioCountBound.verdict`.
     */
    public data class TurnCountLte(public val max: Int) : ScenarioAssertion {
        override val type: String get() = "turn_count_lte"
    }

    /**
     * `{"type":"workspace_command","command":...}` — a command run against the
     * materialized workspace must exit 0. Swift counterpart:
     * `case "workspace_command"` via `ScenarioWorkspaceCommand.evaluateOrDefer`.
     */
    public data class WorkspaceCommand(public val command: String) : ScenarioAssertion {
        override val type: String get() = "workspace_command"
    }

    /**
     * `{"type":"restart_recovered"}` — every declared perturbation point
     * returned the host to Running with the acked materialized files unchanged.
     * Swift counterpart: `case "restart_recovered"`, whose verdict is owned by
     * `ScenarioPerturbationCoverage` and must be finalized before evaluation.
     */
    public data object RestartRecovered : ScenarioAssertion {
        override val type: String get() = "restart_recovered"
    }
}

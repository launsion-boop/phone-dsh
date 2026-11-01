// :testkit scenario — the runner's verdict document: one row per catalog assertion.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.scenario

/**
 * Why an assertion row is not a plain pass.
 *
 * Mirrors the stable machine values of `ScenarioAssertionFailure.Kind` in
 * `Sources/PhoneDSHScenario/ScenarioRun.swift`, so a judge can tell "the file is
 * missing" from "the content is wrong" without parsing English. [NOT_EXECUTED]
 * and [PENDING_HOST] are gate verdicts, not product failures.
 */
public enum class FailureKind {
    /** `file_exists` did not find the path. */
    MISSING,

    /** `no_file` found the path. */
    UNEXPECTED_FILE,

    /** `file_contains` did not find the literal substring (or the file is absent). */
    NOT_CONTAINS,

    /** `file_regex` did not match (or the pattern is not a valid regex). */
    NOT_MATCH,

    /** `workspace_command` exited non-zero or timed out. */
    COMMAND_FAILED,

    /** `turn_count_lte` exceeded its bound. */
    COUNT_EXCEEDED,

    /** The run did not complete, so a progress-dependent assertion was not executed. */
    NOT_EXECUTED,

    /** `workspace_command` was deferred to a host phase. */
    PENDING_HOST,

    /** `restart_recovered` has no finalized coverage, or an evaluation error. */
    ERROR,
}

/**
 * Whether a row was evaluated by the runner, suppressed by the run-completion
 * gate, or deferred to a host phase.
 */
public enum class AssertionStatus {
    /** The runner evaluated the assertion against the run's facts. */
    EVALUATED,

    /**
     * The run did not complete, so a progress-dependent assertion was **not**
     * evaluated (`ScenarioAssertionStatus.notExecuted`). Never a pass.
     */
    NOT_EXECUTED,

    /**
     * A `workspace_command` the execution deferred to a host phase
     * (`ScenarioAssertionStatus.pendingHost`). Provisional; never a pass.
     */
    PENDING_HOST,
}

/**
 * One row of a [ScenarioReport].
 *
 * [type], [passed] and [detail] are the contract every caller relies on;
 * [status] and [failureKind] are the diagnostic additions the Swift report
 * calls `status` and `failure.kind`. [detail] always explains a failure: it is
 * the same sentence the macOS/iOS runner writes (`missing: a.txt`,
 * `does not contain hello`, `exit 3`, ...), never a bare `false`.
 */
public data class AssertionResult(
    public val type: String,
    public val passed: Boolean,
    public val detail: String,
    public val status: AssertionStatus = AssertionStatus.EVALUATED,
    public val failureKind: FailureKind? = null,
)

/**
 * The verdict for one scenario.
 *
 * [passed] is `true` only when the run completed and **every** assertion row
 * passed. [AssertionStatus.NOT_EXECUTED] and [AssertionStatus.PENDING_HOST]
 * rows can never make it true, the same rule as
 * `ScenarioAssertionGate.passes` and `ScenarioAssertionSummary.allPassed`.
 * [assertions] keeps the catalog order.
 */
public data class ScenarioReport(
    public val scenarioId: String,
    public val passed: Boolean,
    public val assertions: List<AssertionResult>,
    /** `true` when every planned turn was delivered and ended `completed`. */
    public val runCompleted: Boolean = true,
    /** Scenario turns the execution actually delivered. */
    public val deliveredTurns: Int = 0,
    /** Scenario turns the catalog declares. */
    public val plannedTurns: Int = 0,
) {
    /** Every row that is not a pass, in catalog order. */
    public val failedAssertions: List<AssertionResult>
        get() = assertions.filter { !it.passed }
}

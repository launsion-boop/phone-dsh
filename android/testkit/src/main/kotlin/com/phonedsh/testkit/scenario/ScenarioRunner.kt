// :testkit scenario — the Android third runner: catalog assertions over an execution seam.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.scenario

import java.io.File
import java.io.IOException
import java.util.regex.Pattern
import java.util.regex.PatternSyntaxException

/** The runner cannot materialize a declared fixture or read its payload. */
public class ScenarioRunException(
    message: String,
    cause: Throwable? = null,
) : IllegalStateException(message, cause)

/**
 * The pure-JVM scenario runner: `setupWorkspace -> turns -> assertions -> report`.
 *
 * It owns no Worker, no `Process`, no device and no model; everything it can
 * observe comes from the caller's [ScenarioExecution]. That is what makes
 * Android the third runner of the conformance triangle: the *same*
 * `scripts/ci/scenarios/catalog.json` the macOS and iOS Simulator runners
 * consume is decoded and evaluated here on plain JVM, without an engine, a
 * network, a device or a new dependency.
 *
 * ## Assertion semantics (one-to-one with `ScenarioAssertionGate.swift`)
 *
 * Every rule below is the `ScenarioAssertionEvaluator.evaluate(_:)` case of the
 * same name in `Sources/PhoneDSHScenario/ScenarioAssertionGate.swift`. The
 * detail strings are the same sentences so evidence from the three runners is
 * comparable.
 *
 * * `file_exists` -> `case "file_exists"` (`FileManager.fileExists`): the path
 *   names a file in the materialized workspace (`fileExists` is true for a
 *   directory too; here a path present in [ScenarioExecution.workspaceFiles] or
 *   readable through [ScenarioExecution.readFile] counts as existing).
 * * `no_file` -> `case "no_file"`: the exact negation of `file_exists`.
 * * `file_contains` -> `case "file_contains"` via `ScenarioFileContent.contains`:
 *   a literal substring of the file's UTF-8 text, with no pattern syntax, no
 *   line anchoring and no trimming.
 * * `file_regex` -> `case "file_regex"` via `ScenarioFileContent.matches`:
 *   `NSRegularExpression` with `.anchorsMatchLines`; the port is
 *   `Pattern.MULTILINE or Pattern.UNICODE_CHARACTER_CLASS`, so `^`/`$` anchor at
 *   every line, `.` does not cross lines and `\w`/`\b`/`\d` are Unicode-aware as
 *   ICU's are. An invalid pattern fails the assertion with the compile error,
 *   exactly as the Swift `throw` does.
 * * `no_console_error` -> `case "no_console_error"`: the
 *   [ScenarioExecution.consoleErrors] stream must be empty. Runner lifecycle
 *   diagnostics are deliberately not part of that stream (G2-FIX-4).
 * * `turn_count_lte` -> `case "turn_count_lte"` via `ScenarioCountBound.verdict`:
 *   the delivered scenario-turn count must be `<= max`. A delivered turn that
 *   ends `failed`/`cancelled`/`budget_exhausted` still counts, as on macOS; only
 *   an undelivered planned turn does not.
 * * `workspace_command` -> `case "workspace_command"` via
 *   `ScenarioWorkspaceCommand.evaluateOrDefer`: exit 0 passes, a non-zero exit
 *   or a timeout fails, and a [CommandStatus.PENDING_HOST] deferral is reported
 *   as pending (never as a pass), the iOS-Simulator two-phase rule. Unlike the
 *   Swift runner this runner never spawns the command itself: the execution
 *   does, so the verdict is honest about which environment ran it.
 * * `restart_recovered` -> `case "restart_recovered"`: the verdict comes from
 *   the finalized `ScenarioPerturbationCoverage`; an execution that reports
 *   `null` (coverage never finalized) fails loud, never vacuously passes.
 *
 * ## The run-completion gate
 *
 * `ScenarioAssertionGate` suppresses the progress-dependent types on an
 * incomplete run (`ScenarioRunCompletion.evaluate` on macOS). The same gate is
 * applied here with the same five applicable types: `file_exists`, `no_file`,
 * `file_contains`, `file_regex`, `workspace_command`. Their row becomes
 * [AssertionStatus.NOT_EXECUTED] with the `not executed: the scenario run did
 * not complete (...)` detail, which can never be a pass. `no_console_error`,
 * `turn_count_lte` and `restart_recovered` keep their own evaluation, exactly as
 * the Swift gate specifies.
 *
 * @param execution the seam that materializes, runs turns and observes facts.
 * @param fixtureRoot the `scripts/ci/scenarios/fixtures` directory, when a
 *   scenario declares `workspace.fixture`. The runner never guesses a path: with
 *   no fixture root a fixture scenario fails loud instead of running against a
 *   workspace that silently misses its payload.
 */
public class ScenarioRunner(
    private val execution: ScenarioExecution,
    private val fixtureRoot: File? = null,
) {
    /**
     * Runs one decoded [scenario] and reports every assertion in catalog order.
     *
     * The workspace is seeded first, then each turn prompt is delivered in
     * order, and only then are the assertions evaluated against the final
     * materialized state. An exception from [ScenarioExecution.setupWorkspace]
     * or [ScenarioExecution.runTurn] propagates: an execution failure is not a
     * product verdict and must not be reported as one.
     */
    public fun run(scenario: Scenario): ScenarioReport {
        execution.setupWorkspace(seedFiles(scenario))

        val plannedTurns = scenario.turns.size
        var deliveredTurns = 0
        val terminalReasons = mutableListOf<String>()
        for (turn in scenario.turns) {
            val outcome = execution.runTurn(turn.prompt)
            if (!outcome.delivered) continue
            deliveredTurns++
            if (outcome.terminalReason != TurnOutcome.COMPLETED) {
                terminalReasons += outcome.terminalReason
            }
        }

        val problems = mutableListOf<String>()
        if (deliveredTurns != plannedTurns) {
            problems += "${plannedTurns - deliveredTurns} of $plannedTurns scenario turn(s) were not delivered"
        }
        if (terminalReasons.isNotEmpty()) {
            problems += "${terminalReasons.size} delivered turn(s) ended with terminal reason(s): " +
                terminalReasons.distinct().sorted().joinToString(", ")
        }
        val runCompleted = problems.isEmpty()

        val assertions = scenario.assertions.map { assertion ->
            if (!runCompleted && assertion.type in PROGRESS_DEPENDENT_TYPES) {
                notExecuted(assertion, problems)
            } else {
                evaluate(assertion, deliveredTurns)
            }
        }
        return ScenarioReport(
            scenarioId = scenario.id,
            passed = assertions.isNotEmpty() && assertions.all { it.passed },
            assertions = assertions,
            runCompleted = runCompleted,
            deliveredTurns = deliveredTurns,
            plannedTurns = plannedTurns,
        )
    }

    // -------------------------------------------------------------- workspace

    /**
     * The fixture payload (copied byte for byte) overlaid with
     * `workspace.files` (UTF-8), which is the catalog's documented precedence.
     * The Swift runner also builds deterministic fixture git history inside the
     * test process; the Kotlin runner does not, so a fixture's `.git/` is used
     * only when the fixture payload on disk already contains it (the simulator
     * host driver stages it that way).
     */
    private fun seedFiles(scenario: Scenario): Map<String, ByteArray> {
        val seed = LinkedHashMap<String, ByteArray>()
        val fixtureName = scenario.workspace.fixture
        if (fixtureName != null) {
            val root = fixtureRoot ?: throw ScenarioRunException(
                "scenario '${scenario.id}' declares fixture '$fixtureName' but ScenarioRunner " +
                    "was constructed without a fixture root",
            )
            val filesDirectory = File(root, "$fixtureName/files")
            if (!filesDirectory.isDirectory) {
                throw ScenarioRunException(
                    "scenario '${scenario.id}' declares fixture '$fixtureName' but " +
                        "'${fixtureName}/files' is not a directory under the given fixture root",
                )
            }
            copyFixtureTree(filesDirectory, filesDirectory, seed)
        }
        for ((path, content) in scenario.workspace.files) {
            seed[path] = content.toByteArray(Charsets.UTF_8)
        }
        return seed
    }

    private fun copyFixtureTree(root: File, directory: File, out: MutableMap<String, ByteArray>) {
        val entries = directory.listFiles() ?: throw ScenarioRunException(
            "cannot list fixture directory '${directory.name}'",
        )
        for (entry in entries.sortedBy { it.name }) {
            if (entry.isDirectory) {
                copyFixtureTree(root, entry, out)
            } else if (entry.isFile) {
                val relative = entry.relativeTo(root).invariantSeparatorsPath
                out[relative] = try {
                    entry.readBytes()
                } catch (failure: IOException) {
                    throw ScenarioRunException("cannot read fixture file '$relative': ${failure.message}", failure)
                }
            }
        }
    }

    // ------------------------------------------------------------- assertions

    private fun evaluate(assertion: ScenarioAssertion, deliveredTurns: Int): AssertionResult =
        when (assertion) {
            is ScenarioAssertion.FileExists -> {
                if (exists(assertion.path)) {
                    pass(assertion.type, "exists: ${assertion.path}")
                } else {
                    fail(assertion.type, "missing: ${assertion.path}", FailureKind.MISSING)
                }
            }
            is ScenarioAssertion.NoFile -> {
                if (exists(assertion.path)) {
                    fail(assertion.type, "unexpected file: ${assertion.path}", FailureKind.UNEXPECTED_FILE)
                } else {
                    pass(assertion.type, "absent: ${assertion.path}")
                }
            }
            is ScenarioAssertion.FileContains -> {
                val text = readText(assertion.path)
                when {
                    text == null -> fail(
                        assertion.type,
                        "file does not exist: ${assertion.path}",
                        FailureKind.MISSING,
                    )
                    text.contains(assertion.value) -> pass(assertion.type, "contains ${short(assertion.value)}")
                    else -> fail(
                        assertion.type,
                        "does not contain ${short(assertion.value)}",
                        FailureKind.NOT_CONTAINS,
                    )
                }
            }
            is ScenarioAssertion.FileRegex -> {
                val text = readText(assertion.path)
                if (text == null) {
                    fail(assertion.type, "file does not exist: ${assertion.path}", FailureKind.MISSING)
                } else {
                    val matched = try {
                        Pattern.compile(assertion.value, REGEX_FLAGS).matcher(text).find()
                    } catch (failure: PatternSyntaxException) {
                        return fail(
                            assertion.type,
                            "invalid regular expression ${short(assertion.value)}: " +
                                (failure.message ?: failure.description),
                            FailureKind.ERROR,
                        )
                    }
                    if (matched) {
                        pass(assertion.type, "matches ${short(assertion.value)}")
                    } else {
                        fail(assertion.type, "does not match ${short(assertion.value)}", FailureKind.NOT_MATCH)
                    }
                }
            }
            is ScenarioAssertion.NoConsoleError -> {
                val errors = execution.consoleErrors()
                if (errors.isEmpty()) {
                    pass(assertion.type, "no console errors")
                } else {
                    fail(
                        assertion.type,
                        "${errors.size} console error(s) in console_errors: ${errors.first().take(200)}",
                        FailureKind.ERROR,
                    )
                }
            }
            is ScenarioAssertion.TurnCountLte -> {
                val detail = "$deliveredTurns delivered scenario turn(s), max ${assertion.max}"
                if (deliveredTurns <= assertion.max) {
                    pass(assertion.type, detail)
                } else {
                    fail(assertion.type, detail, FailureKind.COUNT_EXCEEDED)
                }
            }
            is ScenarioAssertion.WorkspaceCommand -> evaluateWorkspaceCommand(assertion)
            is ScenarioAssertion.RestartRecovered -> {
                val coverage = execution.perturbationCoverage()
                when {
                    coverage == null -> fail(
                        assertion.type,
                        "perturbation coverage was not finalized before the restart_recovered assertion",
                        FailureKind.ERROR,
                    )
                    coverage.ok -> pass(assertion.type, coverage.detail)
                    else -> fail(assertion.type, coverage.detail, FailureKind.ERROR)
                }
            }
        }

    private fun evaluateWorkspaceCommand(assertion: ScenarioAssertion.WorkspaceCommand): AssertionResult {
        val outcome = execution.runWorkspaceCommand(assertion.command)
        if (outcome.status == CommandStatus.PENDING_HOST) {
            return AssertionResult(
                type = assertion.type,
                passed = false,
                detail = outcome.detail
                    ?: "pending_host: the execution deferred the command to a host phase",
                status = AssertionStatus.PENDING_HOST,
                failureKind = FailureKind.PENDING_HOST,
            )
        }
        if (outcome.exitCode == 0) {
            return pass(assertion.type, outcome.detail ?: "exit 0")
        }
        val detail = outcome.detail ?: buildString {
            append("exit ${outcome.exitCode}")
            if (outcome.timedOut) append(" (timed out)")
            val tail = outcome.stdout.trim()
            if (tail.isNotEmpty()) append(": ${tail.take(400)}")
        }
        return fail(assertion.type, detail, FailureKind.COMMAND_FAILED)
    }

    /**
     * The row for a progress-dependent assertion on an incomplete run
     * (`ScenarioAssertionGate.suppresses` + `notExecutedDetail`). The boolean is
     * always `false`; [AssertionStatus.NOT_EXECUTED] keeps it from being read as
     * a failed *product* verdict, and [ScenarioReport.passed] stays false.
     */
    private fun notExecuted(assertion: ScenarioAssertion, problems: List<String>): AssertionResult =
        AssertionResult(
            type = assertion.type,
            passed = false,
            detail = "not executed: the scenario run did not complete (${problems.joinToString("; ")})",
            status = AssertionStatus.NOT_EXECUTED,
            failureKind = FailureKind.NOT_EXECUTED,
        )

    // ----------------------------------------------------------------- helpers

    /**
     * The materialized-existence fact shared by `file_exists` and `no_file`.
     * A path listed by [ScenarioExecution.workspaceFiles] exists even if the
     * execution chooses not to return its bytes, and a readable path exists even
     * when the file list is incomplete; either observation is evidence.
     */
    private fun exists(path: String): Boolean =
        path in execution.workspaceFiles() || execution.readFile(path) != null

    private fun readText(path: String): String? = execution.readFile(path)?.toString(Charsets.UTF_8)

    private fun short(value: String): String = value.take(80)

    private fun pass(type: String, detail: String): AssertionResult =
        AssertionResult(type = type, passed = true, detail = detail)

    private fun fail(type: String, detail: String, kind: FailureKind): AssertionResult =
        AssertionResult(type = type, passed = false, detail = detail, failureKind = kind)

    private companion object {
        /**
         * `MULTILINE` mirrors Swift's `.anchorsMatchLines`; `UNICODE_CHARACTER_CLASS`
         * mirrors ICU's Unicode-aware `\w`, `\d` and `\b` (Java's default is ASCII).
         * Kotlin's `Regex` has no option for the latter, so the match uses
         * `java.util.regex.Pattern` directly.
         */
        val REGEX_FLAGS: Int = Pattern.MULTILINE or Pattern.UNICODE_CHARACTER_CLASS

        /**
         * The five progress-dependent types this vocabulary has; the Swift set
         * additionally names `file_json_path` and `worker_command`, which are not
         * catalog assertion types and therefore not decoded here.
         */
        val PROGRESS_DEPENDENT_TYPES = setOf(
            "file_exists",
            "no_file",
            "file_contains",
            "file_regex",
            "workspace_command",
        )
    }
}

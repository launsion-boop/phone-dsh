// phone-dsh — :testkit scenario runner tests: a passing and a failing case per assertion type.
// SPDX-License-Identifier: MIT
//
// Each failing case also pins the `detail` sentence, not just the boolean: a
// verdict only explains itself when the reason is in the evidence. The
// sentences are the same ones `ScenarioAssertionGate.swift` writes, so the
// macOS, iOS Simulator and Android evidence read alike.

package com.phonedsh.testkit.scenario

import com.phonedsh.testkit.scenario.memory.MemoryScenarioExecution
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScenarioRunnerAssertionTest {

    // ------------------------------------------------------------- file_exists

    @Test
    fun fileExistsPassesWhenThePathIsMaterialized() {
        val report = runScenario(
            listOf(ScenarioAssertion.FileExists("notes.md")),
            files = mapOf("notes.md" to "hello"),
        )
        val result = onlyResult(report)

        assertTrue(report.passed)
        assertTrue(result.passed)
        assertEquals("exists: notes.md", result.detail)
        assertEquals(AssertionStatus.EVALUATED, result.status)
    }

    @Test
    fun fileExistsFailsAndNamesTheMissingPath() {
        val report = runScenario(listOf(ScenarioAssertion.FileExists("notes.md")))
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertFalse(result.passed)
        assertEquals("missing: notes.md", result.detail)
        assertEquals(FailureKind.MISSING, result.failureKind)
    }

    // ----------------------------------------------------------------- no_file

    @Test
    fun noFilePassesWhenThePathIsAbsent() {
        val report = runScenario(
            listOf(ScenarioAssertion.NoFile("old.txt")),
            files = mapOf("notes.md" to "hello"),
        )
        val result = onlyResult(report)

        assertTrue(report.passed)
        assertEquals("absent: old.txt", result.detail)
    }

    @Test
    fun noFileFailsAndNamesTheUnexpectedFile() {
        val report = runScenario(
            listOf(ScenarioAssertion.NoFile("old.txt")),
            files = mapOf("old.txt" to "stale"),
        )
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertEquals("unexpected file: old.txt", result.detail)
        assertEquals(FailureKind.UNEXPECTED_FILE, result.failureKind)
    }

    // ----------------------------------------------------------- file_contains

    @Test
    fun fileContainsPassesOnALiteralSubstring() {
        val report = runScenario(
            listOf(ScenarioAssertion.FileContains("notes.md", "hello")),
            files = mapOf("notes.md" to "hello world"),
        )
        val result = onlyResult(report)

        assertTrue(report.passed)
        assertEquals("contains hello", result.detail)
    }

    @Test
    fun fileContainsFailsWithTheMissingSubstring() {
        val report = runScenario(
            listOf(ScenarioAssertion.FileContains("notes.md", "goodbye")),
            files = mapOf("notes.md" to "hello world"),
        )
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertEquals("does not contain goodbye", result.detail)
        assertEquals(FailureKind.NOT_CONTAINS, result.failureKind)
    }

    @Test
    fun fileContainsFailsWhenTheFileDoesNotExist() {
        val report = runScenario(listOf(ScenarioAssertion.FileContains("notes.md", "hello")))
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertEquals("file does not exist: notes.md", result.detail)
        assertEquals(FailureKind.MISSING, result.failureKind)
    }

    // -------------------------------------------------------------- file_regex

    @Test
    fun fileRegexAnchorsAtEveryLine() {
        // `^`/`$` match at line boundaries because the pattern is compiled
        // grep-style (Swift's `.anchorsMatchLines`, Kotlin's MULTILINE), not
        // only at the start and end of the whole file.
        val report = runScenario(
            listOf(ScenarioAssertion.FileRegex("report.md", "^## Summary$")),
            files = mapOf("report.md" to "# Title\n## Summary\nsome text\n"),
        )
        val result = onlyResult(report)

        assertTrue(report.passed)
        assertEquals("matches ^## Summary$", result.detail)
    }

    @Test
    fun fileRegexFailsWhenThePatternDoesNotMatch() {
        val report = runScenario(
            listOf(ScenarioAssertion.FileRegex("report.md", "^## Missing$")),
            files = mapOf("report.md" to "# Title\n## Summary\nsome text\n"),
        )
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertEquals("does not match ^## Missing$", result.detail)
        assertEquals(FailureKind.NOT_MATCH, result.failureKind)
    }

    @Test
    fun fileRegexFailsLoudOnAnInvalidPattern() {
        val report = runScenario(
            listOf(ScenarioAssertion.FileRegex("report.md", "(")),
            files = mapOf("report.md" to "anything"),
        )
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertTrue(result.detail, result.detail.contains("invalid regular expression"))
        assertEquals(FailureKind.ERROR, result.failureKind)
    }

    // -------------------------------------------------------- no_console_error

    @Test
    fun noConsoleErrorPassesOnAnEmptyErrorStream() {
        val report = runScenario(listOf(ScenarioAssertion.NoConsoleError))
        val result = onlyResult(report)

        assertTrue(report.passed)
        assertEquals("no console errors", result.detail)
    }

    @Test
    fun noConsoleErrorFailsAndNamesTheFirstError() {
        val report = runScenario(listOf(ScenarioAssertion.NoConsoleError)) {
            addConsoleError("worker: uncaught TypeError: cannot read property 'x'")
        }
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertTrue(result.detail, result.detail.contains("1 console error(s)"))
        assertTrue(result.detail, result.detail.contains("worker: uncaught TypeError"))
        assertEquals(FailureKind.ERROR, result.failureKind)
    }

    // ----------------------------------------------------------- turn_count_lte

    @Test
    fun turnCountLtePassesAtTheBound() {
        val report = runScenario(
            listOf(ScenarioAssertion.TurnCountLte(2)),
            turns = listOf("first", "second"),
        )
        val result = onlyResult(report)

        assertTrue(report.passed)
        assertEquals("2 delivered scenario turn(s), max 2", result.detail)
    }

    @Test
    fun turnCountLteFailsAboveTheBound() {
        val report = runScenario(
            listOf(ScenarioAssertion.TurnCountLte(1)),
            turns = listOf("first", "second"),
        )
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertEquals("2 delivered scenario turn(s), max 1", result.detail)
        assertEquals(FailureKind.COUNT_EXCEEDED, result.failureKind)
    }

    // ------------------------------------------------------- workspace_command

    @Test
    fun workspaceCommandPassesOnExitZero() {
        val report = runScenario(listOf(ScenarioAssertion.WorkspaceCommand("python3 -m unittest")))
        val result = onlyResult(report)

        assertTrue(report.passed)
        assertEquals("exit 0", result.detail)
    }

    @Test
    fun workspaceCommandFailsOnANonZeroExitAndKeepsTheOutputTail() {
        val report = runScenario(
            listOf(ScenarioAssertion.WorkspaceCommand("python3 -m unittest")),
        ) {
            onCommand(
                "python3 -m unittest",
                CommandOutcome(exitCode = 3, stdout = "FAILED (failures=1)\n"),
            )
        }
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertTrue(result.detail, result.detail.contains("exit 3"))
        assertTrue(result.detail, result.detail.contains("FAILED (failures=1)"))
        assertEquals(FailureKind.COMMAND_FAILED, result.failureKind)
    }

    @Test
    fun workspaceCommandReportsAPendingHostDeferralAsNotPassed() {
        val report = runScenario(
            listOf(ScenarioAssertion.WorkspaceCommand("bash -n script.sh")),
        ) {
            onCommand(
                "bash -n script.sh",
                CommandOutcome.pendingHost("pending_host: the execution has no shell"),
            )
        }
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertEquals(AssertionStatus.PENDING_HOST, result.status)
        assertEquals(FailureKind.PENDING_HOST, result.failureKind)
        assertEquals("pending_host: the execution has no shell", result.detail)
    }

    // ------------------------------------------------------- restart_recovered

    @Test
    fun restartRecoveredPassesWithFinalizedCoverage() {
        val report = runScenario(listOf(ScenarioAssertion.RestartRecovered)) {
            coverage = PerturbationCoverage(true, "1/1 perturbation point(s) recovered")
        }
        val result = onlyResult(report)

        assertTrue(report.passed)
        assertEquals("1/1 perturbation point(s) recovered", result.detail)
    }

    @Test
    fun restartRecoveredFailsWhenCoverageWasNotFinalized() {
        val report = runScenario(listOf(ScenarioAssertion.RestartRecovered))
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertTrue(
            result.detail,
            result.detail.contains("perturbation coverage was not finalized"),
        )
        assertEquals(FailureKind.ERROR, result.failureKind)
    }

    @Test
    fun restartRecoveredFailsWhenAPointDidNotRecover() {
        val report = runScenario(listOf(ScenarioAssertion.RestartRecovered)) {
            coverage = PerturbationCoverage(
                false,
                "G2-A03 after_turn:1 planned_restart: the host did not return to Running",
            )
        }
        val result = onlyResult(report)

        assertFalse(report.passed)
        assertEquals(
            "G2-A03 after_turn:1 planned_restart: the host did not return to Running",
            result.detail,
        )
        assertEquals(FailureKind.ERROR, result.failureKind)
    }

    // ------------------------------------------------------------ mixed report

    @Test
    fun aReportIsAPassOnlyWhenEveryRowPasses() {
        val report = runScenario(
            assertions = listOf(
                ScenarioAssertion.FileExists("notes.md"),
                ScenarioAssertion.FileContains("notes.md", "hello"),
                ScenarioAssertion.FileExists("missing.md"),
            ),
            files = mapOf("notes.md" to "hello"),
        )

        assertFalse(report.passed)
        assertEquals(3, report.assertions.size)
        assertEquals(1, report.failedAssertions.size)
        assertEquals("file_exists", report.failedAssertions.single().type)
        assertEquals("missing: missing.md", report.failedAssertions.single().detail)
        assertTrue(report.assertions[0].passed)
        assertTrue(report.assertions[1].passed)
        assertFalse(report.assertions[2].passed)
    }

    @Test
    fun memoryExecutionDefaultsToOneCleanTurn() {
        val execution = MemoryScenarioExecution()
        val report = ScenarioRunner(execution).run(
            scenarioOf(listOf(ScenarioAssertion.TurnCountLte(1))),
        )

        assertTrue(report.passed)
        assertEquals(1, report.plannedTurns)
        assertEquals(1, report.deliveredTurns)
        assertEquals(listOf("do the task"), execution.prompts)
    }
}

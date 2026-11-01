// :testkit harness tests — real catalog scenarios through the third runner's host.
// SPDX-License-Identifier: MIT
//
// ---- what these tests prove, and what they refuse to pretend --------------
// Every scenario below is a *real* decoded entry of
// `scripts/ci/scenarios/catalog.json` (G2-C04, the one memory-satisfiable
// scenario, is deliberately not repeated here). The workspace is seeded through
// the real `VFS_MUT -> VfsSink -> WorkspaceLog -> materialized copy` path and the
// assertions are the catalog's own.
//
// **No scenario in this catalog can pass without a model.** G2-C04 is the only
// entry whose assertions the seeded tree already satisfies; the other 55 assert
// files and states a real turn has to produce. This runner has no model
// (`ScriptedTurnDriver` replays pre-set outcomes and never writes), so these
// tests do not assert "passed". They assert the *honest verdict shape*:
//
//   * `G2-B06` is the one scenario where every non-command assertion holds on
//     the seed: it passes the `file_regex` and `turn_count_lte` rows, runs the
//     one POSIX-sh command for real, and defers the four `git` commands as
//     `PENDING_HOST` — a pass + pending mix with no fabricated row.
//   * `G2-A10`, `G2-A06`, `G2-C01`, `G2-E03` are the four scenarios whose every
//     `workspace_command` is within the toybox subset: their commands really
//     execute on the host, and the missing model work really fails. The command
//     failures carry the process's own exit code and stderr.
//   * `G2-E08` stages the binary `office-files` fixture and proves the bytes
//     survived `VFS_MUT` -> codec -> WAL -> materialization unchanged, while its
//     `python3` commands are deferred.
//   * `G2-C06` pins the fail-loud `restart_recovered`: no restart driver means
//     `perturbationCoverage()` is `null`, never a vacuous pass.
//   * the no-model driver test pins the run-completion gate: with turns
//     undelivered, every progress-dependent row is `NOT_EXECUTED`.
//
// A change that fakes a pass (a command returning 0 without a process, a
// materialized file written behind the WAL's back, a pending row counted as
// passed) breaks one of these tests.

package com.phonedsh.testkit.harness

import com.phonedsh.testkit.scenario.AssertionStatus
import com.phonedsh.testkit.scenario.FailureKind
import com.phonedsh.testkit.scenario.ScenarioReport
import com.phonedsh.testkit.scenario.ScenarioRunner
import com.phonedsh.testkit.scenario.TurnOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class CatalogOnHostTest {
    @Before
    fun stageTheRustCodec() {
        HostHarness.stageNativeCodec()
    }

    // ---------------------------------------------------------------- helpers

    private fun runScenario(
        id: String,
        turns: ScenarioTurnDriver = ScriptedTurnDriver.completed(),
        verify: (HostScenarioExecution, ScenarioReport) -> Unit,
    ) {
        HostScenarioExecution(turns = turns).use { execution ->
            val report = ScenarioRunner(execution, HostHarness.fixtureRoot)
                .run(HostHarness.catalog.scenario(id))
            dump(execution, report)
            verify(execution, report)
        }
    }

    private fun dump(execution: HostScenarioExecution, report: ScenarioReport) {
        println(
            "REPORT ${report.scenarioId} passed=${report.passed} runCompleted=${report.runCompleted} " +
                "turns=${report.deliveredTurns}/${report.plannedTurns} " +
                "acks=${execution.acknowledgements} caps=${execution.helloCaps}",
        )
        for (row in report.assertions) {
            println("  ${row.type} passed=${row.passed} status=${row.status} kind=${row.failureKind} :: ${row.detail}")
        }
        for (run in execution.commandRuns) {
            println("  RUN status=${run.outcome.status} exit=${run.outcome.exitCode} :: ${run.command.take(120)}")
        }
    }

    private fun ScenarioReport.passedRows(): Int = assertions.count { it.passed }

    private fun ScenarioReport.pendingRows(): Int =
        assertions.count { it.status == AssertionStatus.PENDING_HOST }

    private fun ScenarioReport.notExecutedRows(): Int =
        assertions.count { it.status == AssertionStatus.NOT_EXECUTED }

    private fun ScenarioReport.failedRows(): Int = assertions.count {
        !it.passed && it.status == AssertionStatus.EVALUATED
    }

    private fun ScenarioReport.rowsOf(type: String) = assertions.filter { it.type == type }

    private fun assertEmittedRowsAreHonest(execution: HostScenarioExecution) {
        // Every evaluated command outcome must name the process that produced it.
        for (run in execution.commandRuns) {
            if (run.outcome.status == com.phonedsh.testkit.scenario.CommandStatus.EVALUATED) {
                assertNotNull("an evaluated command must carry a detail", run.outcome.detail)
                assertTrue(
                    run.outcome.detail!!,
                    run.outcome.detail!!.contains("host-sh"),
                )
            } else {
                assertTrue(
                    "a deferred command must say so: ${run.outcome.detail}",
                    run.outcome.detail!!.startsWith("pending_host:"),
                )
            }
        }
        // The HELLO really advertised the real host's three capabilities.
        assertTrue(
            "wal/1 must be on: ${execution.helloCaps}",
            execution.helloCaps.contains("wal/1"),
        )
        assertTrue("channel/1 must be on: ${execution.helloCaps}", execution.helloCaps.contains("channel/1"))
        assertTrue("exec/1 must be on: ${execution.helloCaps}", execution.helloCaps.contains("exec/1"))
        assertTrue(
            "the phone accelerator must be advertised: ${execution.helloCaps}",
            execution.helloCaps.contains("accelerator:phone"),
        )
    }

    // -------------------------------------------- the four toybox-runnable picks

    /**
     * G2-A10 — three coreutils commands that a real `sh` can run.
     *
     * The seed is empty and the model never ran, so `numbers.txt` does not
     * exist: the file assertion fails and all three commands fail **with a real
     * non-zero exit code**. Zero deferrals is the point — this is the
     * "never fabricate exit 0" test.
     */
    @Test
    fun g2A10RunsCoreutilsCommandsForRealAndFailsHonestly() {
        runScenario("G2-A10") { execution, report ->
            assertEmittedRowsAreHonest(execution)
            assertTrue("the run itself completed", report.runCompleted)
            assertFalse(report.passed)
            assertEquals("one file_exists row", 1, report.rowsOf("file_exists").size)
            assertEquals("no command may be deferred here", 0, report.pendingRows())
            assertEquals(0, report.notExecutedRows())
            assertEquals("1 missing file + 3 real command failures", 4, report.failedRows())

            assertEquals(3, execution.commandRuns.size)
            for (run in execution.commandRuns) {
                val outcome = run.outcome
                assertEquals(
                    "the command must have run: ${run.command}",
                    com.phonedsh.testkit.scenario.CommandStatus.EVALUATED,
                    outcome.status,
                )
                assertFalse("a missing fixture cannot exit 0: ${run.command}", outcome.exitCode == 0)
                assertTrue(outcome.detail!!, outcome.detail!!.startsWith("exit "))
            }
            val missing = report.rowsOf("file_exists").single()
            assertEquals(FailureKind.MISSING, missing.failureKind)
            assertEquals("missing: numbers.txt", missing.detail)
        }
    }

    /** G2-A06 — POSIX `for`/`||` control flow, still really executed. */
    @Test
    fun g2A06RunsShellControlFlowForReal() {
        runScenario("G2-A06") { execution, report ->
            assertEmittedRowsAreHonest(execution)
            assertEquals(2, report.assertions.size)
            assertEquals(0, report.pendingRows())
            assertEquals(2, report.failedRows())

            // The seeded log files survived the VFS path...
            assertEquals(
                setOf("logs/app.log", "logs/app.log.1", "logs/app.log.2"),
                execution.workspaceFiles(),
            )
            // ...but the model's rotation script never existed, so the command failed.
            val failed = execution.commandRuns.single()
            assertEquals(com.phonedsh.testkit.scenario.CommandStatus.EVALUATED, failed.outcome.status)
            assertFalse(failed.outcome.exitCode == 0)
            assertEquals(FailureKind.COMMAND_FAILED, report.rowsOf("workspace_command").single().failureKind)
        }
    }

    /**
     * G2-C01 — one real pass and one real failure on the same executor.
     *
     * The seeded notes have no README.md, so the six content assertions fail;
     * `grep -q … README.md` exits 2 (missing file), while the two
     * `if grep …; then exit 1; fi` guards exit 0 because grep found nothing.
     * Both verdicts are the processes' own.
     */
    @Test
    fun g2C01ShowsRealCommandPassAndFailFromTheSameExecutor() {
        runScenario("G2-C01") { execution, report ->
            assertEmittedRowsAreHonest(execution)
            assertEquals("no command may be deferred here", 0, report.pendingRows())
            assertEquals("7 failed rows (6 file assertions + 1 grep)", 7, report.failedRows())
            assertEquals("2 commands really exited 0 + turn_count_lte", 3, report.passedRows())
            assertEquals(3, execution.commandRuns.size)
            assertTrue(
                "at least one command really exited 0",
                execution.commandRuns.any { it.outcome.exitCode == 0 },
            )
            assertTrue(
                "at least one command really exited non-zero",
                execution.commandRuns.any { it.outcome.exitCode != 0 },
            )
            // Every seed file is present in the materialized tree the commands saw.
            assertEquals(setOf("notes.md", "todo.txt", "bugs.md"), execution.workspaceFiles())
        }
    }

    /** G2-E03 — `tail | while read` and `for` loops run as real POSIX shell. */
    @Test
    fun g2E03RunsWhileReadLoops() {
        runScenario("G2-E03") { execution, report ->
            assertEmittedRowsAreHonest(execution)
            assertEquals(setOf("letter-template.md", "recipients.csv"), execution.workspaceFiles())
            assertEquals(4, execution.commandRuns.size)
            assertTrue(
                "all four commands were attempted for real",
                execution.commandRuns.all {
                    it.outcome.status == com.phonedsh.testkit.scenario.CommandStatus.EVALUATED
                },
            )
            // The letters directory does not exist: three commands fail, the
            // `if grep … letters/` guard exits 0.
            assertEquals(1, execution.commandRuns.count { it.outcome.exitCode == 0 })
            assertEquals(3, execution.commandRuns.count { it.outcome.exitCode != 0 })
            assertEquals(0, report.pendingRows())
        }
    }

    // -------------------------------------------------- deliberate host deferral

    /**
     * G2-B06 — the pass + pending shape.
     *
     * Four `git` commands cannot run on an Android-style host, so they are
     * deferred (`PENDING_HOST`, never a pass); the one POSIX-sh guard really
     * runs and exits 0; the seed already satisfies `file_regex` and
     * `turn_count_lte`. The report therefore has **zero failures** and is still
     * not `passed`, because a pending row is never a pass.
     */
    @Test
    fun g2B06DefersGitCommandsAndPassesTheFileHalf() {
        runScenario("G2-B06") { execution, report ->
            assertEmittedRowsAreHonest(execution)
            assertTrue("both scripted turns were delivered", report.runCompleted)
            assertEquals(7, report.assertions.size)
            assertEquals(4, report.pendingRows())
            assertEquals(3, report.passedRows())
            assertEquals("no row may be a fabricated failure", 0, report.failedRows())
            assertFalse("a pending row is not a pass", report.passed)

            for (row in report.rowsOf("workspace_command").filter { it.status == AssertionStatus.PENDING_HOST }) {
                assertTrue(row.detail, row.detail.startsWith("pending_host:"))
                assertTrue("the reason must name git: ${row.detail}", row.detail.contains("git"))
            }
            val evaluated = report.rowsOf("workspace_command")
                .single { it.status == AssertionStatus.EVALUATED }
            assertTrue("the sh guard really ran: ${evaluated.detail}", evaluated.passed)

            // Three seeded files -> three level-1 ACKs and one level-2 close.
            assertEquals(
                listOf(VfsAck(1, 1), VfsAck(1, 2), VfsAck(1, 3), VfsAck(2, 3)),
                execution.acknowledgements,
            )
            assertEquals(
                "the seed must be readable byte for byte",
                HostHarness.catalog.scenario("G2-B06").workspace.files.getValue("notes.md"),
                execution.readFile("notes.md")?.toString(Charsets.UTF_8),
            )
        }
    }

    /**
     * G2-E08 — the binary `office-files` fixture through `VFS_MUT`.
     *
     * The six OOXML payloads are copied byte for byte by the runner and
     * materialized by the WAL; comparing them back proves the seed did not go
     * through a direct disk write. The two `python3` commands are honestly
     * deferred.
     */
    @Test
    fun g2E08MaterializesTheBinaryOfficeFixtureThroughTheWal() {
        runScenario("G2-E08") { execution, report ->
            assertEmittedRowsAreHonest(execution)
            val fixtureFiles = listOf(
                "budget-2026Q1.xlsx",
                "kickoff.pptx",
                "offer-template.docx",
                "quarterly-report.docx",
                "team-memo.docx",
                "vendor-invoices.xlsx",
            )
            assertEquals(fixtureFiles.toSet(), execution.workspaceFiles())
            for (name in fixtureFiles) {
                val actual = execution.readFile(name)
                assertNotNull("the fixture file '$name' is not materialized", actual)
                assertTrue(
                    "the materialized '$name' differs from the fixture payload",
                    actual!!.contentEquals(HostHarness.fixtureBytes("office-files", name)),
                )
            }
            assertEquals(
                (1..6).map { VfsAck(1, it.toLong()) } + VfsAck(2, 6),
                execution.acknowledgements,
            )
            assertEquals(2, report.pendingRows())
            assertTrue(
                "python3 must be the deferral reason",
                report.rowsOf("workspace_command").all { it.detail.contains("python3") },
            )
            assertEquals(
                "no_console_error reads the host log, which is empty",
                0,
                execution.hostErrors.size,
            )
        }
    }

    // ------------------------------------------------------- fail-loud gates

    /**
     * G2-C06 — `restart_recovered` without a restart driver must fail loud.
     *
     * The scenario has one command the host *can* run (`ls notes | awk …`,
     * which really passes against the five seeded notes) and seven file
     * assertions the absent model never satisfied. The perturbation verdict is
     * the one this test exists for: `null` coverage is an error row, not a pass.
     */
    @Test
    fun g2C06FailsLoudWithoutARestartDriver() {
        runScenario("G2-C06") { execution, report ->
            assertEmittedRowsAreHonest(execution)
            val restart = report.rowsOf("restart_recovered").single()
            assertFalse(restart.passed)
            assertEquals(AssertionStatus.EVALUATED, restart.status)
            assertEquals(FailureKind.ERROR, restart.failureKind)
            assertTrue(
                restart.detail,
                restart.detail.contains("perturbation coverage was not finalized"),
            )
            val notesCommand = execution.commandRuns.first { it.outcome.exitCode == 0 }
            assertTrue(notesCommand.command, notesCommand.command.contains("ls notes"))
            assertTrue(notesCommand.outcome.detail!!, notesCommand.outcome.detail!!.contains("host-sh"))
            // The seeded design note already contains the reviewed sentence.
            val design = report.assertions.first { it.type == "file_regex" && it.passed }
            assertTrue(design.detail, design.detail.contains("方案 B"))
        }
    }

    /**
     * The no-model default: every planned turn is undelivered.
     *
     * That is not a product failure; it is the run-completion gate. The
     * progress-dependent rows must be `NOT_EXECUTED` (never passed), while
     * `turn_count_lte` still evaluates. The workspace is still real, so the
     * VFS half is proven even when no turn is delivered.
     */
    @Test
    fun noModelDriverLeavesProgressDependentRowsNotExecuted() {
        runScenario("G2-B06", turns = NoModelTurnDriver) { execution, report ->
            assertEmittedRowsAreHonest(execution)
            assertFalse(report.runCompleted)
            assertEquals(0, report.deliveredTurns)
            assertEquals(2, report.plannedTurns)
            assertEquals(6, report.notExecutedRows()) // 5 commands + file_regex
            assertEquals(0, report.failedRows())
            assertEquals(1, report.passedRows()) // turn_count_lte only
            assertEquals(0, execution.commandRuns.size) // the gate suppressed them
            val row = report.rowsOf("workspace_command").first()
            assertEquals(AssertionStatus.NOT_EXECUTED, row.status)
            assertEquals(FailureKind.NOT_EXECUTED, row.failureKind)
            assertTrue(
                row.detail,
                row.detail.contains("2 of 2 scenario turn(s) were not delivered"),
            )
            assertEquals(
                "the workspace is materialized even without a model turn",
                3,
                execution.workspaceFiles().size,
            )
        }
    }
}

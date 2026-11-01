// :testkit harness — catalog scenarios on a real device (mksh + toybox), not on the host sh.
// SPDX-License-Identifier: MIT
//
// ---- why this file exists --------------------------------------------------
// `CatalogOnHostTest` runs this runner on the JVM. There
// `ToyboxWorkspaceCommandRunner` resolves the *host's* `/bin/sh`: on the
// recording machine GNU bash 3.2 acting as sh, with the host's coreutils on
// PATH. An Android app process has neither. The same runner class resolves
// `/system/bin/sh` (MirBSD mksh) and the toybox applets instead, and a
// `workspace_command` is only portable evidence once both shells have been
// measured against it: the same command string is not the same program.
//
// So this test runs three real catalog scenarios ON THE DEVICE through the same
// `HostScenarioExecution` the JVM lane uses (a real `WorkspaceLog`, a real
// `VfsSink`, a real `HostChannel`; the seed travels VFS_MUT -> WAL ->
// materialization), prints every verdict, and prints one line per fact next to
// the JVM lane's recorded verdict (`JVM_LANE` below). A difference is the
// output of this lane, not a defect to smooth over.
//
// ---- the three picks (the same K6 rule) ------------------------------------
// Only `file_exists`, `file_regex`, `file_contains`, `turn_count_lte` and
// `workspace_command` are asserted, and every command is inside the toybox
// subset (no git, no python3, no bash syntax). `restart_recovered` never
// appears (neither lane has a perturbation driver), and none of the three
// declares a fixture, so no fixture payload is packaged.
//
//   * `G2-C04` — the catalog's only zero-command scenario: the VFS/assertion
//     path with no shell in it, so it still runs when no process can be
//     spawned.
//   * `G2-A10` — three coreutils commands against an empty workspace. The JVM
//     lane exits 2, 1, 1; the device is asked the same three questions.
//   * `G2-C01` — a real `grep` failure (exit 2, README.md absent) and two real
//     `if grep` guards that exit 0, from the same executor, plus six file
//     assertions the seeded tree cannot satisfy.
//
// ---- what this lane still does not prove -----------------------------------
// * **No model.** `ScriptedTurnDriver.completed()` replays two `completed`
//   outcomes and writes no file, exactly as the JVM lane does. A scenario that
//   needs model work still fails here, honestly, against the seeded tree.
// * **No Worker console.** `consoleErrors()` is the host facade's error log;
//   none of the three picks asserts `no_console_error`, so no row depends on
//   that weaker meaning.
// * **No perturbation driver**, so `restart_recovered` is not exercised.
// * **No tool outside toybox.** A git/python3 command would still be deferred
//   `PENDING_HOST` (the classifier is host-independent), never upgraded to a
//   pass.
//
// ---- the process probe -----------------------------------------------------
// Requirement: establish whether `ProcessBuilder("sh", "-c", "echo hi")` can
// spawn inside an instrumented app sandbox. `theDeviceSandboxCanSpawnTheToyboxShellForReal`
// probes the bare name, the absolute `/system/bin/sh`, and the mksh/toybox
// identity, prints all three, and then drives `ToyboxWorkspaceCommandRunner`
// itself. If the absolute shell cannot be spawned, every command-dependent
// scenario is reported BLOCKED (JUnit `assume`) instead of failing: the device
// cannot answer the question, which is different from answering it wrong.
//
// ---- device facts are measured, never assumed ------------------------------
// The numbers in `JVM_LANE` are recorded observations of the host lane, not a
// spec. The probe's numbers are recorded observations of the device. Neither
// is copied from the other, and this file states which scripted/recorded part
// produced every row it prints.

package com.phonedsh.testkit.harness

import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.testkit.scenario.AssertionStatus
import com.phonedsh.testkit.scenario.CatalogLoader
import com.phonedsh.testkit.scenario.CommandStatus
import com.phonedsh.testkit.scenario.FailureKind
import com.phonedsh.testkit.scenario.ScenarioCatalog
import com.phonedsh.testkit.scenario.ScenarioReport
import com.phonedsh.testkit.scenario.ScenarioRunner
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Logcat tag for every line of this lane; the UTP run keeps it per test. */
private const val DEVICE_TAG = "PDSHDevice"

/** The catalog asset `:testkit/build.gradle.kts` generates from the checked-in document. */
private const val CATALOG_ASSET = "scenario-catalog/catalog.json"

/** The report file, written under the app's files directory; logcat keeps a copy too. */
private const val REPORT_FILE = "catalog-on-device-report.txt"

/** The workspace-log root this lane owns; a caller-supplied platform root is not auto-deleted. */
private const val WORKSPACE_DIR = "catalog-device-workspace"

/**
 * One `ProcessBuilder` probe, including a spawn that never started.
 *
 * A failed spawn is kept as data (`started = false` plus `failure`) because on
 * the device it is a fact about the sandbox, not a test bug.
 */
private class ShellSpawn(
    val argv: List<String>,
    val started: Boolean,
    val exitCode: Int,
    val output: String,
    val failure: String?,
) {
    val ok: Boolean get() = started && exitCode == 0

    fun describe(): String {
        val line = "${argv.joinToString(" ", prefix = "[", postfix = "]")} -> " +
            "started=$started exit=$exitCode output='${output.take(160)}'"
        return if (failure == null) line else "$line failure=$failure"
    }
}

/**
 * The device shell this runner resolves, measured once per test process.
 *
 * `/system/bin/sh` is the path `ToyboxWorkspaceCommandRunner` picks when it
 * exists; the bare `sh` probe is a separate question (does PATH resolution work
 * inside the app sandbox?), and mksh and toybox identify themselves so the
 * evidence names the actual programs.
 */
private object DeviceShell {
    const val ABSOLUTE: String = "/system/bin/sh"

    private const val PROBE_TIMEOUT_MILLIS = 20_000L

    val bare: ShellSpawn by lazy { spawn(listOf("sh", "-c", "echo hi")) }

    val absolute: ShellSpawn by lazy { spawn(listOf(ABSOLUTE, "-c", "echo hi")) }

    val identity: ShellSpawn by lazy {
        spawn(listOf(ABSOLUTE, "-c", "echo \"KSH=\$KSH_VERSION\"; toybox --version 2>&1"))
    }

    /** Whether the runner can spawn its shell at all on this device. */
    val available: Boolean get() = absolute.ok

    /** Every measured device fact, one printable line each. */
    fun facts(): List<String> {
        val shell = File(ABSOLUTE)
        return listOf(
            "device: sdk=${Build.VERSION.SDK_INT} release=${Build.VERSION.RELEASE} " +
                "abi=${Build.SUPPORTED_ABIS.firstOrNull() ?: "<unknown>"}",
            "device shell: $ABSOLUTE exists=${shell.isFile} canExecute=${shell.canExecute()}",
            "device PATH: ${System.getenv("PATH") ?: "<unset>"}",
            "process java.io.tmpdir: ${System.getProperty("java.io.tmpdir") ?: "<unset>"}",
            "probe ${bare.describe()}",
            "probe ${absolute.describe()}",
            "probe ${identity.describe()}",
        )
    }

    private fun spawn(argv: List<String>): ShellSpawn {
        val process = try {
            ProcessBuilder(argv).redirectErrorStream(true).start()
        } catch (failure: IOException) {
            return ShellSpawn(argv, started = false, exitCode = -1, output = "", failure = failure.toString())
        }
        val finished = try {
            process.waitFor(PROBE_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
            process.destroyForcibly()
            return ShellSpawn(argv, started = true, exitCode = -1, output = "", failure = "interrupted")
        }
        if (!finished) {
            process.destroyForcibly()
            return ShellSpawn(
                argv,
                started = true,
                exitCode = -1,
                output = "",
                failure = "timed out after $PROBE_TIMEOUT_MILLIS ms",
            )
        }
        val output = try {
            process.inputStream.use { it.readBytes().toString(Charsets.UTF_8).trim() }
        } catch (_: IOException) {
            ""
        }
        return ShellSpawn(argv, started = true, exitCode = process.exitValue(), output = output, failure = null)
    }
}

/**
 * One command's verdict from the JVM lane, recorded on the host.
 *
 * [diagnostics] is the command's stderr text after the runner's own whitespace
 * normalisation, i.e. the part of `CommandOutcome.detail` after the executor
 * banner.
 */
private class JvmCommand(val exitCode: Int, val diagnostics: String)

/**
 * The JVM lane's verdict for one scenario, recorded from a `CatalogOnHostTest`
 * run of the same scenario, catalog and `HostScenarioExecution`.
 *
 * These are recorded observations, not a specification. The row counts are the
 * same counts `CatalogOnHostTest` itself asserts, so the host lane fails first
 * if they change; the device test then prints, per command, whether it agrees.
 */
private class JvmBaseline(
    val commands: List<JvmCommand>,
    val passed: Int,
    val pending: Int,
    val failed: Int,
)

private val JVM_LANE: Map<String, JvmBaseline> = mapOf(
    "G2-A10" to JvmBaseline(
        commands = listOf(
            JvmCommand(
                exitCode = 2,
                diagnostics = "/bin/sh: numbers.txt: No such file or directory " +
                    "/bin/sh: line 0: test: : integer expression expected",
            ),
            JvmCommand(exitCode = 1, diagnostics = "awk: can't open file numbers.txt source line number 1"),
            JvmCommand(exitCode = 1, diagnostics = "sed: numbers.txt: No such file or directory"),
        ),
        passed = 1,
        pending = 0,
        failed = 4,
    ),
    "G2-C01" to JvmBaseline(
        commands = listOf(
            JvmCommand(exitCode = 2, diagnostics = "grep: README.md: No such file or directory"),
            JvmCommand(exitCode = 0, diagnostics = ""),
            JvmCommand(exitCode = 0, diagnostics = ""),
        ),
        passed = 3,
        pending = 0,
        failed = 7,
    ),
)

/** The probe's BLOCKED sentence, shared by the scenario tests that need a shell. */
private const val BLOCKED_NO_SHELL: String =
    "BLOCKED: the app sandbox could not spawn the device shell " +
        "(see theDeviceSandboxCanSpawnTheToyboxShellForReal); the only catalog scenario this " +
        "device can evaluate is G2-C04, so every workspace_command assertion on this device is " +
        "unverifiable"

/**
 * Writes one report line to logcat, stdout and the app's report file.
 *
 * The file is truncated once per test process, so a run's report is exactly
 * the lines that run produced. A file-system failure is not a scenario
 * failure: logcat already holds the same line.
 */
private object DeviceReport {
    private var file: File? = null

    @Synchronized
    fun append(message: String) {
        Log.i(DEVICE_TAG, message)
        println(message)
        val target = file ?: createFile()
        try {
            target.appendText(message + "\n")
        } catch (_: IOException) {
            // Logcat is the durable copy; a report-file failure must not fail a scenario.
        }
    }

    @Synchronized
    fun path(): String? = file?.absolutePath

    private fun createFile(): File {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val target = File(context.filesDir, REPORT_FILE)
        target.parentFile?.mkdirs()
        target.delete()
        file = target
        return target
    }
}

/** One scenario row summary, so both the dump and the diff agree on the numbers. */
private fun ScenarioReport.passedRows(): Int = assertions.count { it.passed }

private fun ScenarioReport.pendingRows(): Int =
    assertions.count { it.status == AssertionStatus.PENDING_HOST }

private fun ScenarioReport.notExecutedRows(): Int =
    assertions.count { it.status == AssertionStatus.NOT_EXECUTED }

private fun ScenarioReport.failedRows(): Int = assertions.count {
    !it.passed && it.status == AssertionStatus.EVALUATED
}

/**
 * The stderr text a `workspace_command` verdict carries.
 *
 * `ToyboxWorkspaceCommandRunner` puts it after the executor banner, whose shape
 * is `exit N (host-sh <shell>; toybox-subset command; K file(s) copied from the
 * materialized tree): <stderr>`. An empty string means the command produced no
 * diagnostics.
 */
private fun diagnosticsOf(detail: String?): String = detail.orEmpty()
    .substringAfter("materialized tree)", "")
    .trim()
    .removePrefix(":")
    .trim()
    .replace(Regex("\\s+"), " ")

/**
 * The catalog on a device: three real scenarios through the real host VFS/WAL
 * path, with the JVM lane's verdict printed next to the device's.
 *
 * Run it with `:testkit:connectedDebugAndroidTest`; the report lands in
 * `context.filesDir/catalog-on-device-report.txt` and in the run's logcat, and
 * the test names say which scenario they cover.
 */
@RunWith(AndroidJUnit4::class)
class CatalogOnDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    private val context get() = instrumentation.targetContext

    /** The execution's scratch root: under the app's cache dir, not the process temp dir. */
    private val workspaceRoot: File by lazy {
        File(context.cacheDir, WORKSPACE_DIR).also { it.deleteRecursively() }
    }

    /** The checked-in catalog, decoded from the asset the APK carries. */
    private val catalog: ScenarioCatalog by lazy {
        CatalogLoader.load(readAsset(CATALOG_ASSET), CATALOG_ASSET)
    }

    // ------------------------------------------------------------- the probe

    /**
     * Establishes, on the device, that a process can be spawned and that
     * `ToyboxWorkspaceCommandRunner` runs real commands through it.
     *
     * The bare-name probe is the question the lane description asks; the
     * absolute-path probe is the one the runner actually uses. The test skips
     * (`assume`) only when the absolute shell cannot be spawned; then a command
     * assertion is unanswerable, not failed.
     */
    @Test
    fun theDeviceSandboxCanSpawnTheToyboxShellForReal() {
        reportLine("=== CatalogOnDeviceTest: device facts ===")
        for (line in DeviceShell.facts()) reportLine(line)
        reportLine("device report file: ${DeviceReport.path() ?: "<not written>"}")

        if (!DeviceShell.available) {
            reportLine(BLOCKED_NO_SHELL)
        }
        assumeTrue(BLOCKED_NO_SHELL, DeviceShell.available)

        if (DeviceShell.bare.ok) {
            assertEquals("the bare-name probe must echo hi", "hi", DeviceShell.bare.output)
            reportLine(
                "FINDING: ProcessBuilder(\"sh\", \"-c\", \"echo hi\") runs inside the instrumented " +
                    "app sandbox, so the sandbox does not block fork/exec of the system shell",
            )
        } else {
            reportLine(
                "FINDING: ProcessBuilder(\"sh\", \"-c\", \"echo hi\") did not run " +
                    "(${DeviceShell.bare.failure ?: "exit ${DeviceShell.bare.exitCode}"}); " +
                    "the runner spawns the absolute ${DeviceShell.ABSOLUTE}, which is what the " +
                    "absolute probe above measured",
            )
        }
        assertTrue(
            "the absolute device shell must echo hi: ${DeviceShell.absolute.describe()}",
            DeviceShell.absolute.ok,
        )
        assertEquals("the absolute probe must echo hi", "hi", DeviceShell.absolute.output)
        assertTrue(
            "the shell must identify itself (mksh) and the applets (toybox): " +
                DeviceShell.identity.describe(),
            DeviceShell.identity.output.contains("toybox"),
        )

        // The runner itself, end to end, against a throwaway tree under the app's cache.
        val root = File(context.cacheDir, "runner-probe")
        root.deleteRecursively()
        val workspace = File(root, "workspace").apply { mkdirs() }
        val home = File(root, "home").apply { mkdirs() }
        File(workspace, "data.txt").writeText("one\ntwo\n")
        try {
            val runner = ToyboxWorkspaceCommandRunner()
            val trees = WorkspaceTrees(workspace.toPath(), home.toPath())
            val pass = runner.run("test -f data.txt && grep -q two data.txt", trees)
            val fail = runner.run("test -e missing.txt", trees)
            val deferred = runner.run("git status", trees)
            reportLine("runner pass: status=${pass.status} exit=${pass.exitCode} detail=${pass.detail}")
            reportLine("runner fail: status=${fail.status} exit=${fail.exitCode} detail=${fail.detail}")
            reportLine("runner defer: status=${deferred.status} detail=${deferred.detail}")

            assertEquals("a command the device supports must really run", CommandStatus.EVALUATED, pass.status)
            assertEquals(0, pass.exitCode)
            assertTrue(
                "the evidence must name the device executor: ${pass.detail}",
                pass.detail!!.contains("host-sh ${DeviceShell.ABSOLUTE}"),
            )
            assertEquals("a non-zero exit must be returned unchanged", CommandStatus.EVALUATED, fail.status)
            assertEquals(1, fail.exitCode)
            assertEquals(
                "a git command must be deferred on the device too",
                CommandStatus.PENDING_HOST,
                deferred.status,
            )
            assertTrue(
                "a deferral must say so: ${deferred.detail}",
                deferred.detail!!.startsWith("pending_host:"),
            )
            assertTrue(
                "the deferral must name git: ${deferred.detail}",
                deferred.detail!!.contains("`git`"),
            )
            assertEquals(
                "the command ran in a throwaway copy, not in the tree it was given",
                "one\ntwo\n",
                File(workspace, "data.txt").readText(),
            )
            reportLine(
                "FINDING: the device executes commands for real (exit 0 from a real process, " +
                    "exit 1 from a real process, git deferred as pending_host)",
            )
        } finally {
            root.deleteRecursively()
        }
    }

    // ------------------------------------------------------------- scenarios

    /**
     * `G2-C04` — the catalog's only zero-command scenario.
     *
     * Runs with no shell at all: every fact comes from the real
     * VFS_MUT -> WAL -> materialization path and the runner's own assertion
     * code. The seed cannot satisfy the six `expenses-check.md` rows (no model
     * wrote the file), so the verdict is six honest `MISSING` rows plus the one
     * `turn_count_lte` row that is true on the seed.
     */
    @Test
    fun g2C04RunsTheZeroCommandScenario() {
        runScenario("G2-C04") { execution, report, differences ->
            assertTrue("the two scripted turns were delivered", report.runCompleted)
            assertEquals(2, report.deliveredTurns)
            assertEquals(7, report.assertions.size)
            assertEquals(0, report.pendingRows())
            assertEquals(0, report.notExecutedRows())
            assertEquals("only turn_count_lte is true on the seed", 1, report.passedRows())
            assertEquals("six file assertions miss expenses-check.md", 6, report.failedRows())
            assertFalse(report.passed)
            assertTrue("G2-C04 has no workspace_command", execution.commandRuns.isEmpty())
            assertEquals(setOf("expenses.csv", "说明.txt"), execution.workspaceFiles())
            assertEquals(
                "one level-1 ACK per seeded file, then the epoch close",
                listOf(VfsAck(level = 1, uptoMseq = 1), VfsAck(level = 1, uptoMseq = 2), VfsAck(level = 2, uptoMseq = 2)),
                execution.acknowledgements,
            )
            val missing = report.assertions.first { it.type == "file_exists" }
            assertEquals(FailureKind.MISSING, missing.failureKind)
            assertEquals("missing: expenses-check.md", missing.detail)
            assertTrue(
                "every file row must be MISSING, never a content mismatch: " +
                    report.assertions.filter { it.type != "turn_count_lte" }.map { it.failureKind },
                report.assertions.filter { it.type != "turn_count_lte" }
                    .all { it.failureKind == FailureKind.MISSING },
            )
            assertEquals("the host facade logged no error on the device", emptyList<String>(), execution.hostErrors)
            for (cap in listOf("channel/1", "wal/1", "exec/1", "accelerator:phone")) {
                assertTrue(
                    "the device host HELLO is missing $cap: ${execution.helloCaps}",
                    cap in execution.helloCaps,
                )
            }
            assertTrue(
                "there is no JVM baseline for this scenario and no command row that could differ: " +
                    differences,
                differences.isEmpty(),
            )
        }
    }

    /**
     * `G2-A10` — three coreutils commands against an empty workspace.
     *
     * All three really run. The point is not that they fail (a missing fixture
     * must fail everywhere) but that the *device* answers the same question
     * differently on the first one: mksh's `test` treats the empty command
     * substitution as 0 and exits 1, while the host's bash reports an invalid
     * integer expression and exits 2. The row distribution happens to be
     * identical, which is exactly why the per-command diff exists.
     */
    @Test
    fun g2A10RunsCoreutilsCommandsOnTheDeviceShell() {
        assumeTrue(BLOCKED_NO_SHELL, DeviceShell.available)
        runScenario("G2-A10") { execution, report, differences ->
            assertTrue("the two scripted turns were delivered", report.runCompleted)
            assertEquals(5, report.assertions.size)
            assertEquals(0, report.pendingRows())
            assertEquals(0, report.notExecutedRows())
            assertEquals(1, report.passedRows())
            assertEquals("one missing file + three real command failures", 4, report.failedRows())
            assertEquals(3, execution.commandRuns.size)
            assertEquals("the seed is empty", emptySet<String>(), execution.workspaceFiles())
            assertEquals(
                "an empty seed still closes the epoch",
                listOf(VfsAck(level = 2, uptoMseq = 0)),
                execution.acknowledgements,
            )
            for (run in execution.commandRuns) {
                assertEquals(
                    "the command must have run on the device: ${run.command}",
                    CommandStatus.EVALUATED,
                    run.outcome.status,
                )
                assertTrue(
                    "a missing fixture cannot exit 0 on the device either: ${run.command}",
                    run.outcome.exitCode != 0,
                )
                assertTrue(
                    "the verdict must be the process's own: ${run.outcome.detail}",
                    run.outcome.detail!!.startsWith("exit "),
                )
                assertTrue(
                    "the device executor must be named in the evidence: ${run.outcome.detail}",
                    run.outcome.detail!!.contains("host-sh ${DeviceShell.ABSOLUTE}"),
                )
            }
            assertTrue(
                "the JVM lane exits 2 on command[0] (bash's test rejects the empty operand) while " +
                    "the device's mksh test compares the empty string as 0; a failure here means " +
                    "the lanes converged and JVM_LANE is stale: $differences",
                differences.any { it.contains("DIFF exit JVM=2 device=") },
            )
            assertTrue(
                "the shell diagnostics must differ on that command too: $differences",
                differences.any { it.contains("command[0]") && it.contains("DIFF stderr") },
            )
            assertTrue(
                "commands 1 and 2 matched the JVM lane and must not be reported as differences: " +
                    differences,
                differences.none {
                    it.startsWith("command[1]:") || it.startsWith("command[2]:")
                },
            )
        }
    }

    /**
     * `G2-C01` — the same executor producing a real pass and a real failure.
     *
     * The seeded notes contain no README.md, so the six content rows fail;
     * `grep -q` on the missing file exits 2 with grep's own diagnostic, while
     * the two `if grep` guards exit 0 because nothing matched. The JVM lane's
     * exit codes and stderr are reproduced exactly by toybox grep here, so the
     * device diff must be empty: a platform does not have to differ just
     * because its shell is a different program.
     */
    @Test
    fun g2C01RunsRealGrepPassAndFailOnTheDevice() {
        assumeTrue(BLOCKED_NO_SHELL, DeviceShell.available)
        runScenario("G2-C01") { execution, report, differences ->
            assertTrue("the two scripted turns were delivered", report.runCompleted)
            assertEquals(10, report.assertions.size)
            assertEquals(0, report.pendingRows())
            assertEquals(0, report.notExecutedRows())
            assertEquals("two guards exited 0, turn_count_lte passes", 3, report.passedRows())
            assertEquals("six missing-file rows + the grep failure", 7, report.failedRows())
            assertEquals(setOf("bugs.md", "notes.md", "todo.txt"), execution.workspaceFiles())
            assertEquals(3, execution.commandRuns.size)
            assertEquals(
                "grep on the missing README exits 2, the two guards exit 0",
                listOf(2, 0, 0),
                execution.commandRuns.map { it.outcome.exitCode },
            )
            assertTrue(
                "the missing-file diagnostic must be the process's own: " +
                    execution.commandRuns[0].outcome.detail,
                execution.commandRuns[0].outcome.detail!!.contains("README.md"),
            )
            assertTrue(
                "the JVM lane recorded the same exits and the same grep diagnostic, so toybox's " +
                    "evidence must not differ here; a difference belongs in JVM_LANE: $differences",
                differences.isEmpty(),
            )
        }
    }

    // --------------------------------------------------------------- running

    /**
     * Runs one catalog scenario and prints the verdict plus the JVM diff.
     *
     * The workspace log lives under [workspaceRoot], which this class owns; the
     * platform the execution gets only points at it (`HostScenarioExecution`
     * does not delete a caller-supplied root).
     */
    private fun runScenario(
        id: String,
        turns: ScenarioTurnDriver = ScriptedTurnDriver.completed(),
        verify: (HostScenarioExecution, ScenarioReport, List<String>) -> Unit,
    ) {
        val platform = FakePlatform(root = workspaceRoot.toPath())
        val execution = HostScenarioExecution(turns = turns, platform = platform)
        try {
            val scenario = catalog.scenarios.firstOrNull { it.id == id }
                ?: throw AssertionError(
                    "the packaged catalog has no scenario '$id'; it carries " +
                        catalog.scenarios.map { it.id }.take(5) + " ...",
                )
            val report = ScenarioRunner(execution, fixtureRoot = null).run(scenario)
            reportLine("=== CatalogOnDeviceTest: $id on the device ===")
            dump(execution, report)
            val differences = reportDifference(id, execution, report)
            verify(execution, report, differences)
        } finally {
            execution.close()
            workspaceRoot.deleteRecursively()
        }
    }

    /** Prints the report in the JVM lane's shape, so the two dumps are comparable line by line. */
    private fun dump(execution: HostScenarioExecution, report: ScenarioReport) {
        reportLine(
            "REPORT ${report.scenarioId} passed=${report.passed} runCompleted=${report.runCompleted} " +
                "turns=${report.deliveredTurns}/${report.plannedTurns} " +
                "acks=${execution.acknowledgements} caps=${execution.helloCaps}",
        )
        for (row in report.assertions) {
            reportLine(
                "  ${row.type} passed=${row.passed} status=${row.status} kind=${row.failureKind} " +
                    ":: ${row.detail}",
            )
        }
        for (run in execution.commandRuns) {
            reportLine("  RUN status=${run.outcome.status} exit=${run.outcome.exitCode} :: ${run.command.take(120)}")
        }
        reportLine(
            "  rows passed=${report.passedRows()} pending=${report.pendingRows()} " +
                "failed=${report.failedRows()} notExecuted=${report.notExecutedRows()} " +
                "hostErrors=${execution.hostErrors.size}",
        )
    }

    /**
     * Prints the device verdict against the JVM lane's recorded one and returns
     * the behavioural differences, one line per fact.
     *
     * The executor line is context, not a difference: the shell paths differ by
     * construction and naming them is what makes a command comparison
     * attributable. Differences are exit codes, stderr text and row counts.
     */
    private fun reportDifference(
        id: String,
        execution: HostScenarioExecution,
        report: ScenarioReport,
    ): List<String> {
        val differences = mutableListOf<String>()
        val deviceShell = execution.commandRuns.firstNotNullOfOrNull { run ->
            run.outcome.detail?.substringAfter("host-sh ", "")?.substringBefore(';')?.trim()
                ?.takeIf { it.isNotEmpty() }
        }
        reportLine("COMPARE $id: the device verdict next to the JVM lane")
        reportLine(
            "  executor: JVM lane /bin/sh; device " +
                (deviceShell ?: "none (no workspace_command ran in this scenario)"),
        )
        val baseline = JVM_LANE[id]
        val deviceCounts =
            "passed=${report.passedRows()} pending=${report.pendingRows()} failed=${report.failedRows()}"
        if (baseline == null) {
            reportLine("  baseline: none - CatalogOnHostTest does not run $id")
            reportLine(
                "  rows: device $deviceCounts; the same runner code, catalog and WAL path produce " +
                    "them, and no shell is involved",
            )
            return differences
        }
        reportLine(
            "  baseline: JVM lane (CatalogOnHostTest; recorded /bin/sh run) " +
                "passed=${baseline.passed} pending=${baseline.pending} failed=${baseline.failed}",
        )
        if (report.passedRows() == baseline.passed &&
            report.pendingRows() == baseline.pending &&
            report.failedRows() == baseline.failed
        ) {
            reportLine("  rows: SAME $deviceCounts")
        } else {
            val line = "row distribution: JVM passed=${baseline.passed} pending=${baseline.pending} " +
                "failed=${baseline.failed}, device $deviceCounts"
            differences += line
            reportLine("  rows: DIFF $line")
        }
        if (baseline.commands.size != execution.commandRuns.size) {
            val line = "command count: JVM ${baseline.commands.size}, device ${execution.commandRuns.size}"
            differences += line
            reportLine("  DIFF $line")
        }
        for ((index, run) in execution.commandRuns.withIndex()) {
            val host = baseline.commands.getOrNull(index) ?: continue
            val label = "command[$index] ${run.command.take(90)}"
            val outcome = run.outcome
            if (outcome.status != CommandStatus.EVALUATED) {
                val line = "command[$index]: DIFF status JVM=EVALUATED device=${outcome.status}"
                differences += line
                reportLine("  $label")
                reportLine("    $line")
                continue
            }
            val exitLine = if (outcome.exitCode == host.exitCode) {
                "SAME exit ${host.exitCode}"
            } else {
                "DIFF exit JVM=${host.exitCode} device=${outcome.exitCode}"
            }
            if (exitLine.startsWith("DIFF")) differences += "command[$index]: $exitLine"
            reportLine("  $label")
            reportLine("    $exitLine")
            val diagnostics = diagnosticsOf(outcome.detail)
            if (diagnostics == host.diagnostics) {
                reportLine("    SAME stderr after whitespace normalisation '${diagnostics}'")
            } else {
                val line = "command[$index]: DIFF stderr JVM='${host.diagnostics}' device='$diagnostics'"
                differences += line
                reportLine("    DIFF stderr JVM='${host.diagnostics}' device='$diagnostics'")
            }
        }
        return differences
    }

    // ---------------------------------------------------------------- assets

    /** Reads a test-APK asset, naming the build task when it is absent. */
    private fun readAsset(name: String): String {
        for (candidate in listOf(instrumentation.context, context)) {
            try {
                return candidate.assets.open(name).use { it.readBytes().toString(Charsets.UTF_8) }
            } catch (_: IOException) {
                // The library test APK is self-instrumenting; either context can hold it.
            }
        }
        throw AssertionError(
            "the androidTest APK has no asset '$name'; :testkit/build.gradle.kts must run " +
                "packageScenarioCatalogForTests before the device can evaluate the catalog",
        )
    }

    private fun reportLine(message: String) = DeviceReport.append(message)
}

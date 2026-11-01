// phone-dsh — :testkit scenario tests: a real catalog scenario, end to end, in memory.
// SPDX-License-Identifier: MIT
//
// G2-C04 is the one shipped scenario whose assertions are all memory-satisfiable
// without a shell: file_exists, file_regex, file_contains and turn_count_lte.
// The test materializes a plausible 报销核对报告 the way the model would, runs
// the real decoded scenario, then destroys exactly one condition and checks that
// exactly that assertion fails with the reason.

package com.phonedsh.testkit.scenario

import com.phonedsh.testkit.scenario.memory.MemoryScenarioExecution
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ScenarioRunnerEndToEndTest {

    @Test
    fun runsTheRealG2C04ScenarioToAPass() {
        val catalog = ShippedCatalog.load()
        val scenario = catalog.scenario("G2-C04")
        val execution = MemoryScenarioExecution()
        installReportTurns(execution, REPORT_MD)

        val report = ScenarioRunner(execution).run(scenario)

        assertTrue(
            report.assertions.joinToString { "${it.type}: ${it.detail}" },
            report.passed,
        )
        assertEquals(7, report.assertions.size)
        assertEquals(7, report.assertions.count { it.passed })
        assertEquals(2, report.deliveredTurns)
        assertEquals(2, report.plannedTurns)
        assertTrue(report.runCompleted)
        // The catalog's own seed reached the execution unchanged (UTF-8 bytes),
        // and the report the second turn wrote is the one that was asserted on.
        assertEquals(
            scenario.workspace.files.getValue("expenses.csv"),
            execution.readFile("expenses.csv")?.toString(Charsets.UTF_8),
        )
        assertEquals(
            scenario.workspace.files.getValue("说明.txt"),
            execution.readFile("说明.txt")?.toString(Charsets.UTF_8),
        )
        assertEquals(REPORT_MD, execution.readFile("expenses-check.md")?.toString(Charsets.UTF_8))
    }

    @Test
    fun breakingOneConditionFailsExactlyThatAssertion() {
        val catalog = ShippedCatalog.load()
        val scenario = catalog.scenario("G2-C04")
        val execution = MemoryScenarioExecution()
        // Same report, but the corrected 660 line lost its hand-filled 880:
        // every other assertion stays satisfied.
        installReportTurns(execution, REPORT_MD.replace("880", "881"))

        val report = ScenarioRunner(execution).run(scenario)

        assertFalse(report.passed)
        assertEquals(1, report.failedAssertions.size)
        val failed = report.failedAssertions.single()
        assertEquals("file_contains", failed.type)
        assertEquals(3, report.assertions.indexOf(failed))
        assertEquals("does not contain 880", failed.detail)
        assertEquals(FailureKind.NOT_CONTAINS, failed.failureKind)
        assertTrue(
            "the other six assertions still pass",
            report.assertions.filterIndexed { index, _ -> index != 3 }.all { it.passed },
        )
    }

    @Test
    fun anUndeliveredTurnSuppressesTheProgressDependentAssertions() {
        val execution = MemoryScenarioExecution()
        execution.scriptTurns(TurnOutcome(delivered = false))
        val scenario = scenarioOf(
            assertions = listOf(
                ScenarioAssertion.FileExists("out.md"),
                ScenarioAssertion.NoConsoleError,
                ScenarioAssertion.TurnCountLte(2),
            ),
            files = mapOf("out.md" to "content"),
        )

        val report = ScenarioRunner(execution).run(scenario)

        assertFalse(report.runCompleted)
        assertFalse(report.passed)
        assertEquals(0, report.deliveredTurns)
        val fileExists = report.assertions[0]
        assertEquals(AssertionStatus.NOT_EXECUTED, fileExists.status)
        assertEquals(FailureKind.NOT_EXECUTED, fileExists.failureKind)
        assertFalse(fileExists.passed)
        assertTrue(
            fileExists.detail,
            fileExists.detail.startsWith("not executed: the scenario run did not complete"),
        )
        assertTrue(
            fileExists.detail,
            fileExists.detail.contains("1 of 1 scenario turn(s) were not delivered"),
        )
        assertTrue("no_console_error keeps its own evaluation", report.assertions[1].passed)
        assertTrue("turn_count_lte keeps its own evaluation", report.assertions[2].passed)
    }

    @Test
    fun aDeliveredTurnThatFailedStillGatesTheRun() {
        val execution = MemoryScenarioExecution()
        execution.scriptTurns(TurnOutcome(terminalReason = "failed"))
        val scenario = scenarioOf(
            assertions = listOf(
                ScenarioAssertion.FileExists("out.md"),
                ScenarioAssertion.TurnCountLte(1),
            ),
            files = mapOf("out.md" to "content"),
        )

        val report = ScenarioRunner(execution).run(scenario)

        assertEquals(1, report.deliveredTurns)
        assertFalse(report.runCompleted)
        assertFalse(report.passed)
        assertEquals(AssertionStatus.NOT_EXECUTED, report.assertions[0].status)
        assertTrue(
            report.assertions[0].detail,
            report.assertions[0].detail.contains("terminal reason(s): failed"),
        )
        assertTrue("a delivered turn still counts", report.assertions[1].passed)
    }

    @Test
    fun aFixturePayloadIsMaterializedBeforeTheWorkspaceOverrides() {
        val fixtureRoot = Files.createTempDirectory("pdsh-scenario-fixture").toFile()
        try {
            writeFixtureFile(fixtureRoot, "notes", "notes.md", "from fixture")
            writeFixtureFile(fixtureRoot, "notes", "sub/keep.txt", "nested")
            val scenario = scenarioOf(
                assertions = listOf(
                    ScenarioAssertion.FileExists("notes.md"),
                    ScenarioAssertion.FileContains("notes.md", "overridden"),
                    ScenarioAssertion.FileExists("sub/keep.txt"),
                ),
                files = mapOf("notes.md" to "overridden content"),
                fixture = "notes",
            )
            val execution = MemoryScenarioExecution()

            val report = ScenarioRunner(execution, fixtureRoot).run(scenario)

            assertTrue(report.assertions.joinToString { it.detail }, report.passed)
            assertEquals(
                "overridden content",
                execution.seededFiles.getValue("notes.md").toString(Charsets.UTF_8),
            )
            assertEquals(
                "nested",
                execution.seededFiles.getValue("sub/keep.txt").toString(Charsets.UTF_8),
            )
        } finally {
            fixtureRoot.deleteRecursively()
        }
    }

    @Test
    fun aFixtureScenarioWithoutAFixtureRootFailsLoud() {
        val scenario = scenarioOf(
            assertions = listOf(ScenarioAssertion.FileExists("notes.md")),
            fixture = "notes",
        )

        val failure = assertThrows(ScenarioRunException::class.java) {
            ScenarioRunner(MemoryScenarioExecution()).run(scenario)
        }

        assertTrue(failure.message!!.contains("fixture 'notes'"))
        assertTrue(failure.message!!.contains("without a fixture root"))
    }

    @Test
    fun aMissingFixturePayloadDirectoryFailsLoud() {
        val fixtureRoot = Files.createTempDirectory("pdsh-scenario-fixture").toFile()
        try {
            val failure = assertThrows(ScenarioRunException::class.java) {
                ScenarioRunner(MemoryScenarioExecution(), fixtureRoot).run(
                    scenarioOf(
                        assertions = listOf(ScenarioAssertion.FileExists("notes.md")),
                        fixture = "absent",
                    ),
                )
            }
            assertTrue(failure.message!!.contains("'absent/files' is not a directory"))
        } finally {
            fixtureRoot.deleteRecursively()
        }
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Models the two G2-C04 turns: the first turn leaves a draft report (with
     * the wrong 8,837 total), the second replaces it with [finalReport].
     */
    private fun installReportTurns(execution: MemoryScenarioExecution, finalReport: String) {
        execution.onTurn = { prompt, turnExecution ->
            when {
                prompt.startsWith("帮我核一遍这个月的团队报销") ->
                    turnExecution.putFile("expenses-check.md", DRAFT_MD)
                prompt.startsWith("财务那边对不上") ->
                    turnExecution.putFile("expenses-check.md", finalReport)
            }
        }
    }

    private fun writeFixtureFile(root: File, fixture: String, relative: String, text: String) {
        val target = File(File(root, "$fixture/files"), relative)
        requireNotNull(target.parentFile) { "fixture file '$relative' has no parent directory" }.mkdirs()
        target.writeText(text, Charsets.UTF_8)
    }

    private companion object {
        val DRAFT_MD: String = """
            # 10 月团队报销核对报告

            - 笔数：17 笔
            - 总金额：8,837 元（按 amount 直加）
        """.trimIndent()

        val REPORT_MD: String = """
            # 10 月团队报销核对报告（修正版）

            - 笔数：17 笔
            - 修正后总额：8,617 元（按 unit_price × qty 逐行核算）
            - 原报告总额：8,837 元（按手填 amount 直加，多出 220 元）

            ## 类别小计

            - 交通：出租车、高铁票、地铁、停车费，合计 1,873 元
            - 餐饮：团队午餐、咖啡、外卖、项目餐，合计 2,214 元
            - 办公：打印纸、快递费、白板笔、打印耗材、会议室租用、办公椅，合计 4,530 元

            ## 发现的问题

            第 17 行「办公椅」：220 × 3 = 660 元，手填 amount 为 880 元，多报 220 元。

            修正说明：原报告按手填 amount 直加得到 8,837 元；财务按 unit_price × qty
            复核，第 17 行应为 660 元，修正后总额 8,617 元。后续汇总以修正后的数字为准，
            原始 expenses.csv 未改动。
        """.trimIndent()
    }
}

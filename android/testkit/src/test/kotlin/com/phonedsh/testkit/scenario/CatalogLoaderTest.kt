// phone-dsh — :testkit scenario loader tests: the 56-scenario catalog and strict rejection.
// SPDX-License-Identifier: MIT
//
// Two jobs:
//  1. the shipped scripts/ci/scenarios/catalog.json decodes to 56 scenarios and
//     475 assertions, with the eight assertion types in the expected counts;
//  2. a document the schema does not allow is an error, never a silent skip.

package com.phonedsh.testkit.scenario

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CatalogLoaderTest {

    @Test
    fun loadsTheShippedCatalogWithFiftySixScenarios() {
        val catalog = ShippedCatalog.load()

        assertEquals(1, catalog.version)
        assertEquals(56, catalog.scenarios.size)
        assertEquals(10, catalog.fixtures.size)
        assertEquals(
            "catalog ids are unique",
            56,
            catalog.scenarios.map { it.id }.toSet().size,
        )
        assertTrue("every scenario declares at least one turn", catalog.scenarios.all { it.turns.isNotEmpty() })
        assertTrue(
            "every scenario declares at least one assertion",
            catalog.scenarios.all { it.assertions.isNotEmpty() },
        )
    }

    @Test
    fun decodesTheEightAssertionTypesWithTheCatalogCounts() {
        val catalog = ShippedCatalog.load()
        val assertions = catalog.scenarios.flatMap { it.assertions }
        val counts = assertions.groupingBy { it.type }.eachCount()

        assertEquals(
            mapOf(
                "file_contains" to 47,
                "file_exists" to 111,
                "file_regex" to 98,
                "no_console_error" to 28,
                "no_file" to 2,
                "restart_recovered" to 16,
                "turn_count_lte" to 43,
                "workspace_command" to 130,
            ),
            counts,
        )
        assertEquals(475, assertions.size)
    }

    @Test
    fun resolvesEveryBudgetReferenceInTheShippedCatalog() {
        val catalog = ShippedCatalog.load()
        for (scenario in catalog.scenarios) {
            assertFalse(
                "scenario ${scenario.id} title still holds a budget reference",
                scenario.title.contains("{{budgets."),
            )
            assertFalse(
                "scenario ${scenario.id} user_story still holds a budget reference",
                scenario.userStory.contains("{{budgets."),
            )
            scenario.turns.forEachIndexed { index, turn ->
                assertFalse(
                    "scenario ${scenario.id} turn[$index] still holds a budget reference",
                    turn.prompt.contains("{{budgets."),
                )
            }
            scenario.assertions.forEachIndexed { index, assertion ->
                assertFalse(
                    "scenario ${scenario.id} assertion[$index] still holds a budget reference",
                    budgetText(assertion).contains("{{budgets."),
                )
            }
        }

        val a09 = catalog.scenario("G2-A09")
        assertEquals(16777216, a09.budgets?.singleFileBytes)
        assertTrue(a09.turns[1].prompt.contains("16777216"))
        assertTrue(a09.turns[1].prompt.contains("16 MiB"))
        val groupedRegex = a09.assertions
            .filterIsInstance<ScenarioAssertion.FileRegex>()
            .single { it.value.contains("M(i)") }
        assertEquals("16 ?M(i)?B|16777216|16,777,216", groupedRegex.value)
        assertTrue(
            a09.assertions.filterIsInstance<ScenarioAssertion.WorkspaceCommand>()
                .single().command.contains("<=16777216"),
        )
        // A non-budget placeholder is payload, not a reference: G2-E08's docx
        // check greps for the literal `{{CANDIDATE}}` and must stay untouched.
        assertTrue(
            catalog.scenario("G2-E08").assertions
                .filterIsInstance<ScenarioAssertion.WorkspaceCommand>()
                .any { it.command.contains("{{CANDIDATE}}") },
        )
    }

    @Test
    fun decodesScenarioFieldsAndFixtureReferences() {
        val catalog = ShippedCatalog.load()
        val fixtureNames = catalog.fixtures.map { it.name }.toSet()

        val a01 = catalog.scenario("G2-A01")
        assertEquals("files", a01.category)
        assertEquals(2, a01.turns.size)
        assertEquals(10, a01.workspace.files.size)
        assertEquals(10, a01.budget.maxMinutes)
        assertEquals(25, a01.budget.maxModelRequests)
        assertNull(a01.workspace.fixture)
        assertTrue(a01.assertions.any { it is ScenarioAssertion.WorkspaceCommand })
        assertTrue(a01.assertions.any { it is ScenarioAssertion.NoFile })

        val withFixture = catalog.scenarios.first { it.workspace.fixture != null }
        val fixtureName = requireNotNull(withFixture.workspace.fixture)
        assertTrue(
            "fixture '$fixtureName' is declared in fixtures[]",
            fixtureName in fixtureNames,
        )
        assertTrue(catalog.fixtures.all { it.description != null })
    }

    @Test
    fun expandsBudgetReferencesAtLoadTime() {
        val document = catalogDocument(
            scenarios = "[${
                scenarioJson(
                    budgets = """{"singleFileBytes":16777216}""",
                    turns = """[{"prompt":"limit {{budgets.singleFileBytes}} bytes = {{budgets.singleFileMiB}} MiB"}]""",
                    assertions = """[{"type":"file_contains","path":"a.txt","value":"{{budgets.singleFileBytesGrouped}}"}]""",
                )
            }]",
        )

        val scenario = CatalogLoader.load(document, "test-catalog.json").scenarios.single()

        assertEquals(16777216, scenario.budgets?.singleFileBytes)
        assertEquals("limit 16777216 bytes = 16 MiB", scenario.turns.single().prompt)
        assertEquals(
            "16,777,216",
            (scenario.assertions.single() as ScenarioAssertion.FileContains).value,
        )
    }

    @Test
    fun ignoresUnknownDocumentAndScenarioMembers() {
        // The document and scenario objects are open in the schema: an additive
        // field must never break the third runner.
        val document = catalogDocument(
            scenarios = "[${
                scenarioJson(
                    extraMembers = ",\"rubric\":[\"a qualitative criterion\"]," +
                        "\"network\":\"none\",\"mock\":{\"tool_call_rounds\":1}",
                )
            }]",
            extraTopLevel = "\"notes\":{\"future\":true}",
        )

        val catalog = CatalogLoader.load(document, "test-catalog.json")

        assertEquals(1, catalog.scenarios.size)
        assertEquals(1, catalog.scenarios.single().assertions.size)
    }

    @Test
    fun rejectsInvalidJson() {
        assertRejected("{\"version\":1,", "invalid JSON")
    }

    @Test
    fun rejectsAnUnsupportedVersion() {
        assertRejected(catalogDocument(version = 2), "'version' must be 1")
    }

    @Test
    fun rejectsAnUnknownAssertionType() {
        assertRejected(
            catalogDocument(scenarios = "[${scenarioJson(assertions = """[{"type":"session_error"}]""")}]"),
            "unknown assertion type 'session_error'",
        )
    }

    @Test
    fun rejectsAnUnknownAssertionMember() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(assertions = """[{"type":"file_exists","path":"a.txt","optional":true}]""")
                }]",
            ),
            "unknown assertion member",
        )
    }

    @Test
    fun rejectsAMissingAssertionMember() {
        assertRejected(
            catalogDocument(
                scenarios = "[${scenarioJson(assertions = """[{"type":"file_contains","path":"a.txt"}]""")}]",
            ),
            "missing required member 'value'",
        )
    }

    @Test
    fun rejectsAnAssertionPathThatIsAbsolute() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(assertions = """[{"type":"file_exists","path":"$absolutePath"}]""")
                }]",
            ),
            "absolute path",
        )
    }

    @Test
    fun rejectsAnAssertionPathWithParentTraversal() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(assertions = """[{"type":"file_exists","path":"../escape.txt"}]""")
                }]",
            ),
            "must not contain '..'",
        )
    }

    @Test
    fun rejectsATurnCountBoundThatIsNegative() {
        assertRejected(
            catalogDocument(
                scenarios = "[${scenarioJson(assertions = """[{"type":"turn_count_lte","max":-1}]""")}]",
            ),
            "'max' must be >= 0",
        )
    }

    @Test
    fun rejectsATurnCountBoundThatIsNotAnInteger() {
        assertRejected(
            catalogDocument(
                scenarios = "[${scenarioJson(assertions = """[{"type":"turn_count_lte","max":1.5}]""")}]",
            ),
            "'max' must be an integer",
        )
    }

    @Test
    fun rejectsAScenarioWithoutTurns() {
        assertRejected(
            catalogDocument(scenarios = "[${scenarioJson(turns = "[]")}]"),
            "must have at least one turn",
        )
    }

    @Test
    fun rejectsAScenarioWithoutAssertions() {
        assertRejected(
            catalogDocument(scenarios = "[${scenarioJson(assertions = "[]")}]"),
            "must have at least one assertion",
        )
    }

    @Test
    fun rejectsAnUnknownFixtureReference() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(workspace = """{"files":{},"fixture":"nope"}""")
                }]",
            ),
            "references unknown fixture 'nope'",
        )
    }

    @Test
    fun rejectsADuplicateScenarioId() {
        assertRejected(
            catalogDocument(scenarios = "[${scenarioJson()},${scenarioJson()}]"),
            "duplicate scenario id 'G2-T1'",
        )
    }

    @Test
    fun rejectsAWorkspacePathThatIsAbsolute() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(workspace = """{"files":{"$absolutePath":"content"}}""")
                }]",
            ),
            "absolute path",
        )
    }

    @Test
    fun rejectsAnUnknownBudgetsKey() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(budgets = """{"singleFileBytes":16777216,"other":1}""")
                }]",
            ),
            "unknown budgets key 'other'",
        )
    }

    @Test
    fun rejectsABudgetsValueOutsideTheSchemaRange() {
        assertRejected(
            catalogDocument(scenarios = "[${scenarioJson(budgets = """{"singleFileBytes":1024}""")}]"),
            "outside the supported range",
        )
    }

    @Test
    fun rejectsABudgetReferenceWithoutADeclaration() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(turns = """[{"prompt":"limit {{budgets.singleFileBytes}}"}]""")
                }]",
            ),
            "no budgets.singleFileBytes declaration",
        )
    }

    @Test
    fun rejectsAnUnknownBudgetReference() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(
                        budgets = """{"singleFileBytes":16777216}""",
                        assertions = """[{"type":"file_contains","path":"a.txt","value":"{{budgets.totalBytes}}"}]""",
                    )
                }]",
            ),
            "unknown budget reference",
        )
    }

    @Test
    fun rejectsAMalformedBudgetReference() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(
                        budgets = """{"singleFileBytes":16777216}""",
                        assertions = """[{"type":"file_contains","path":"a.txt","value":"{{budgets.}}"}]""",
                    )
                }]",
            ),
            "malformed budget reference",
        )
    }

    @Test
    fun rejectsSingleFileMiBForANonWholeMiB() {
        assertRejected(
            catalogDocument(
                scenarios = "[${
                    scenarioJson(
                        budgets = """{"singleFileBytes":16777217}""",
                        assertions = """[{"type":"file_contains","path":"a.txt","value":"{{budgets.singleFileMiB}}"}]""",
                    )
                }]",
            ),
            "is not a whole number of MiB",
        )
    }

    @Test
    fun scenarioLookupNamesTheKnownIds() {
        val catalog = ShippedCatalog.load()

        val failure = assertThrows(NoSuchElementException::class.java) { catalog.scenario("G2-NOPE") }
        assertTrue(failure.message!!.contains("G2-NOPE"))
        assertTrue(failure.message!!.contains("G2-A01"))
    }

    // ---------------------------------------------------------------- helpers

    /**
     * An absolute path only a rejection test needs. Split so this test source
     * never contains a machine path; the loader must reject the joined form.
     */
    private val absolutePath: String = "/" + "tmp/notes.md"

    private fun assertRejected(document: String, fragment: String) {
        val failure = assertThrows(ScenarioCatalogException::class.java) {
            CatalogLoader.load(document, "test-catalog.json")
        }
        val message = failure.message ?: ""
        assertTrue("expected the diagnostic to contain '$fragment', got '$message'", message.contains(fragment))
        assertTrue("a rejection must name a JSON location, got '$message'", message.startsWith("test-catalog.json"))
    }

    private fun catalogDocument(
        scenarios: String = "[${scenarioJson()}]",
        fixtures: String = "[]",
        version: Int = 1,
        extraTopLevel: String = "",
    ): String {
        val members = mutableListOf(
            "\"version\":$version",
            "\"generated_by\":\"unit-test\"",
            "\"fixtures\":$fixtures",
            "\"scenarios\":$scenarios",
        )
        if (extraTopLevel.isNotEmpty()) members += extraTopLevel
        return members.joinToString(prefix = "{", postfix = "}", separator = ",")
    }

    private fun scenarioJson(
        id: String = "G2-T1",
        workspace: String = """{"files":{"a.txt":"hello"}}""",
        turns: String = """[{"prompt":"go"}]""",
        assertions: String = """[{"type":"file_exists","path":"a.txt"}]""",
        budget: String = """{"max_minutes":1,"max_model_requests":1}""",
        budgets: String? = null,
        extraMembers: String = "",
    ): String = "{" +
        "\"id\":\"$id\"," +
        "\"category\":\"test\"," +
        "\"title\":\"test scenario\"," +
        "\"user_story\":\"a loader test scenario\"," +
        "\"workspace\":$workspace," +
        "\"turns\":$turns," +
        "\"assertions\":$assertions," +
        "\"budget\":$budget" +
        (if (budgets != null) ",\"budgets\":$budgets" else "") +
        extraMembers +
        "}"

    /** The text of one assertion that can carry a `{{budgets.*}}` reference. */
    private fun budgetText(assertion: ScenarioAssertion): String = when (assertion) {
        is ScenarioAssertion.FileContains -> assertion.value
        is ScenarioAssertion.FileRegex -> assertion.value
        is ScenarioAssertion.WorkspaceCommand -> assertion.command
        else -> ""
    }
}

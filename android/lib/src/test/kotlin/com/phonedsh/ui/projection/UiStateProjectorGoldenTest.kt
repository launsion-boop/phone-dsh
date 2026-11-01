// Acceptance: the five golden trajectories project to the pinned UiState
// SPDX-License-Identifier: MIT
// sequences.
//
// This is the strongest check the lane has. For every case under
// `spec/v1/golden/trajectory/` the test reads the *normalized* expected rows
// (the trajectory oracle's own output, already free of platform noise), rebuilds
// the host events they project from, and asserts the projected `ui-state/1`
// sequence byte-for-byte against a pinned expectation in
// `src/test/resources/ui-state/`.
//
// The same test also asserts the properties the schema cannot express:
//  * every node validates against the real `ui-state-sequence.schema.json`;
//  * every `parentID` names an existing node exactly one grammar level above;
//  * the sequence is pre-order (a parent is emitted before its children);
//  * `nodeID`s are globally unique;
//  * a stream that arrives out of order within the `W = 16` window projects to
//    the same sequence (the shared stage-2 rule);
//  * the one `real-difference` case projects *different* sequences on the two
//    platforms, proving the projector never washes a semantic difference away.
package com.phonedsh.ui.projection

import com.phonedsh.agentcore.JsonValue
import com.phonedsh.ui.JsonSchemaLite
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.text
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class UiStateProjectorGoldenTest {
    @Test
    fun `five golden cases project to their pinned sequences`() {
        val cases = SpecFixtures.trajectoryCases()
        assertEquals("the golden corpus is five cases", 5, cases.size)
        cases.forEach { case ->
            val nodes = SpecFixtures.projectCase(case)
            assertEquals("$case: pinned UiState sequence", SpecFixtures.pinnedUiState("$case.jsonl"), nodes.encodeCanonical())
            assertSchemaValid(case, nodes)
            assertTreeInvariants(case, nodes)
        }
    }

    @Test
    fun `the real-difference case keeps its difference`() {
        val notes = SpecFixtures.notes(TURN_ERROR)
        assertEquals("real-difference", notes.text("kind"))
        val ios = SpecFixtures.projectCase(TURN_ERROR)
        val android = SpecFixtures.projectCase(TURN_ERROR, "android.expected.jsonl")
        assertEquals(SpecFixtures.pinnedUiState("$TURN_ERROR.jsonl"), ios.encodeCanonical())
        assertEquals(SpecFixtures.pinnedUiState("$TURN_ERROR.android.jsonl"), android.encodeCanonical())
        assertNotEquals("the failed turn and the completed turn must not normalize together", ios, android)

        val iosSurfaces = ios.map { it.surface }.toSet()
        val androidSurfaces = android.map { it.surface }.toSet()
        assertTrue("ios carries the fail-loud banner", UiStateSurface.FAIL_LOUD_BANNER in iosSurfaces)
        assertTrue("android completed, so it has no banner", UiStateSurface.FAIL_LOUD_BANNER !in androidSurfaces)
        assertEquals("both platforms project exactly one turn-end row", 1, ios.count { it.kind == UiStateKind.STATUS })
        assertEquals("both platforms project exactly one turn-end row", 1, android.count { it.kind == UiStateKind.STATUS })
        assertEquals("error", ios.single { it.kind == UiStateKind.STATUS }.text)
        assertEquals("completed", android.single { it.kind == UiStateKind.STATUS }.text)
    }

    @Test
    fun `arrival order inside the window does not change the sequence`() {
        SpecFixtures.trajectoryCases().forEach { case ->
            val events = SpecFixtures.eventsFor(SpecFixtures.trajectoryRows(case))
            val expected = UiStateProjector.project(events).encodeCanonical()
            // A best-effort row has no `seq`: its position is only known from
            // arrival, so the permutations stay inside each run of durable rows.
            // The window rule then has to restore the same total order.
            runs(events).forEachIndexed { index, run ->
                if (run.size < 2) return@forEachIndexed
                listOf(run.reversed(), run.sortedBy { it.seq }, run.sortedByDescending { it.seq })
                    .forEach { permuted ->
                        val shuffled = events.toMutableList()
                        run.forEachIndexed { offset, original ->
                            shuffled[events.indexOf(original)] = permuted[offset]
                        }
                        assertEquals(
                            "$case: run $index permutation must project identically",
                            expected,
                            UiStateProjector.project(shuffled).encodeCanonical(),
                        )
                    }
            }
        }
    }

    /** Maximal runs of durable events; a best-effort row ends a run. */
    private fun runs(events: List<com.phonedsh.agentcore.HarnessEvent>): List<List<com.phonedsh.agentcore.HarnessEvent>> {
        val result = mutableListOf<List<com.phonedsh.agentcore.HarnessEvent>>()
        var current = mutableListOf<com.phonedsh.agentcore.HarnessEvent>()
        events.forEach { event ->
            if (event.seq == null) {
                if (current.isNotEmpty()) result.add(current)
                current = mutableListOf()
            } else {
                current.add(event)
            }
        }
        if (current.isNotEmpty()) result.add(current)
        return result
    }

    @Test
    fun `empty input projects to an empty sequence`() {
        assertEquals(emptyList<UiStateNode>(), UiStateProjector.project(emptyList()))
        assertEquals("", emptyList<UiStateNode>().encodeCanonical())
    }

    private fun assertSchemaValid(case: String, nodes: List<UiStateNode>) {
        nodes.forEachIndexed { index, node ->
            val value: JsonValue = node.toJsonObject()
            val problems = JsonSchemaLite.validate(SpecFixtures.uiStateSchema, value, "$case[$index]")
            assertTrue("$case node $index violates the schema: $problems", problems.isEmpty())
        }
    }

    private fun assertTreeInvariants(case: String, nodes: List<UiStateNode>) {
        assertEquals("$case: nodeID must be unique", nodes.size, nodes.map { it.nodeID }.toSet().size)
        val seen = LinkedHashSet<String>()
        nodes.forEach { node ->
            if (node.nodeID != ROOT) {
                assertTrue(
                    "$case: ${node.nodeID} names parent ${node.parentID}, which must be emitted first (pre-order)",
                    node.parentID in seen,
                )
            }
            assertEquals(
                "$case: ${node.nodeID} must be exactly one grammar level below its parent",
                expectedParent(node.nodeID),
                node.parentID,
            )
            if (node.kind.structural()) {
                assertEquals("$case: structural node ${node.nodeID} uses seq 0", 0, node.seq)
                assertEquals(
                    "$case: structural node ${node.nodeID} is not a pixel surface",
                    UiStateSurface.NONE,
                    node.surface,
                )
            }
            if (node.kind == UiStateKind.TURN_EVENT) {
                assertEquals(
                    "$case: event node ${node.nodeID} carries its ordinal",
                    node.nodeID.substringAfterLast('/'),
                    node.seq.toString(),
                )
                assertEquals(
                    "$case: event node ${node.nodeID} hangs directly under its turn",
                    node.nodeID.substringBefore("/event/"),
                    node.parentID,
                )
                assertEquals("$case: event node ${node.nodeID} is not a pixel surface", UiStateSurface.NONE, node.surface)
            }
            seen.add(node.nodeID)
        }
    }

    private fun UiStateKind.structural(): Boolean =
        this == UiStateKind.ROOT || this == UiStateKind.SESSION || this == UiStateKind.TURN

    /**
     * The parent id the `§7` grammar implies for [nodeID]: `session` -> `root`,
     * `turn` -> its session, `turn-event` -> its turn, slot -> the event node
     * (`nodeID` minus the slot segment). `root` is its own parent because the
     * schema requires `parentID` on every row.
     */
    private fun expectedParent(nodeID: String): String {
        val segments = nodeID.split('/')
        return when {
            segments.size <= 2 -> ROOT
            segments.size == 4 -> segments.take(2).joinToString("/")
            segments.size == 6 -> segments.take(4).joinToString("/")
            segments.size == 7 -> segments.take(6).joinToString("/")
            else -> throw AssertionError("not a §7 grammar level: $nodeID")
        }
    }

    private companion object {
        const val TURN_ERROR: String = "turn-error-vs-complete"
        const val ROOT: String = "root"
    }
}

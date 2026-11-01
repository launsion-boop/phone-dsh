// phone-dsh — :testkit trajectory: UiState sequence grammar, pre-order, ordering and stages 3/4.
// SPDX-License-Identifier: MIT
//
// `ui-state-sequence.schema.json` fixes the shape; this file proves the structural rules the
// schema cannot express: a nodeID is exactly `session/<sid>/turn/<tid>/event/<seq>[/<slot>]`,
// every parent precedes its child, a slot is a semantic role (never a path or random hex), and
// text/props go through the same noise and numeric stages as trajectory `data`.

package com.phonedsh.testkit.trajectory

import java.util.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class UiStateNormalizerTest {
    private val session = "sess-001"
    private val turn = "turn-0001"
    private val turnNode = "session/$session/turn/$turn"

    @Test
    fun `a pre-order ui-state sequence normalizes deterministically and is idempotent`() {
        val rows = sequenceRows()
        val first = TrajectoryNormalizer.normalize(rows)
        val second = TrajectoryNormalizer.normalize(rows)
        assertArrayEquals(
            "UiState normalization is not deterministic",
            TrajectoryNormalizer.encodeLines(first.lines),
            TrajectoryNormalizer.encodeLines(second.lines),
        )
        assertEquals(RowKind.UI_STATE, first.kind)
        assertEquals(9, first.lines.size)

        assertEquals(
            listOf(
                "root",
                "session/$session",
                turnNode,
                "$turnNode/event/1",
                "$turnNode/event/1/assistant-block-0",
                "$turnNode/event/2",
                "$turnNode/event/2/tool-call",
                "$turnNode/event/3",
                "$turnNode/event/3/turn-end",
            ),
            first.lines.map { nodeIdOf(it) },
        )

        // Stage 1 already canonicalized paths; stage 3 applies below text and props.
        val event1 = first.lines[3]
        assertTrue(event1, event1.contains("\"text\":\"hello\\n at <timestamp> pid=<removed>\""))
        assertTrue(event1, event1.contains("\"props\":{}"))
        val bubble = first.lines[4]
        assertTrue(
            bubble,
            bubble.contains(
                "\"props\":{\"bytes\":1536,\"durationMs\":10,\"percent\":50.041," +
                    "\"uuid\":\"<uuid>\"}",
            ),
        )
        val event2 = first.lines[5]
        assertTrue(event2, event2.contains("\"text\":\"thread=<worker>\""))
        assertFalse("platform is never an output member", event2.contains("\"platform\""))
        val toolRow = first.lines[6]
        assertTrue(
            toolRow,
            toolRow.contains("\"props\":{\"path\":\"/dsh/workspace/a.md\",\"sizeBytes\":1024}"),
        )

        // Canonical output is a fixed point: normalize(normalize(x)) == normalize(x).
        assertArrayEquals(
            "UiState output is not a fixed point",
            TrajectoryNormalizer.encodeLines(first.lines),
            TrajectoryNormalizer.encodeLines(TrajectoryNormalizer.normalize(first.lines).lines),
        )
    }

    @Test
    fun `shuffling a ui-state sequence inside the window keeps the same pre-order`() {
        val rows = sequenceRows()
        val expected = TrajectoryNormalizer.encodeLines(TrajectoryNormalizer.normalize(rows).lines)
        val random = Random(20261031L)
        repeat(50) {
            val shuffled = rows.shuffled(random)
            assertArrayEquals(
                "a shuffled UiState sequence changed the output",
                expected,
                TrajectoryNormalizer.encodeLines(TrajectoryNormalizer.normalize(shuffled).lines),
            )
        }
        assertArrayEquals(
            "a reversed UiState sequence changed the output",
            expected,
            TrajectoryNormalizer.encodeLines(TrajectoryNormalizer.normalize(rows.reversed()).lines),
        )
    }

    @Test
    fun `a random hex slot is rejected as an unstable node id`() {
        val row = TrajectoryTestSupport.uiStateRow(
            sessionID = session,
            seq = 1,
            nodeID = "$turnNode/event/1/abcdef12",
            parentID = "$turnNode/event/1",
            kind = "status",
            props = "{}",
        )
        val failure = assertThrows(NormError::class.java) { TrajectoryNormalizer.normalize(listOf(row)) }
        assertEquals("UNSTABLE_NODE_ID", failure.code)
    }

    @Test
    fun `an absolute or traversing path is not a node id`() {
        for (nodeId in listOf("/data/user/0/dev.dsh.probe/files/workspace", "session/../../etc/passwd")) {
            val row = TrajectoryTestSupport.uiStateRow(
                sessionID = session,
                turnID = "-",
                seq = 0,
                nodeID = nodeId,
                parentID = "root",
                kind = "session",
                props = "{}",
            )
            val tree = JsonTreeCodec.parseDocument(row, "test") as JsonObjectTree
            val failure = assertThrows(NormError::class.java) { UiStateGrammar.check(tree, "test") }
            assertEquals("nodeID $nodeId", "UNSTABLE_NODE_ID", failure.code)
        }
        // Through the public pipeline the schema gate rejects both before the grammar runs.
        val row = TrajectoryTestSupport.uiStateRow(
            nodeID = "/data/user/0/dev.dsh.probe/files/workspace",
            parentID = "root",
            kind = "session",
        )
        assertThrows(NormError::class.java) { TrajectoryNormalizer.normalize(listOf(row)) }
    }

    @Test
    fun `a missing parent fails pre-order`() {
        val rows = listOf(
            rootRow(),
            sessionRow(),
            turnRow(),
            TrajectoryTestSupport.uiStateRow(
                sessionID = session,
                seq = 1,
                nodeID = "$turnNode/event/1/assistant-block-0",
                parentID = "$turnNode/event/1",
                kind = "bubble",
                surface = "bubble",
            ),
        )
        val failure = assertThrows(NormError::class.java) { TrajectoryNormalizer.normalize(rows) }
        assertEquals("UNSTABLE_NODE_ID", failure.code)
    }

    @Test
    fun `a parent that is not exactly one grammar level up is rejected`() {
        val row = TrajectoryTestSupport.uiStateRow(
            sessionID = session,
            seq = 1,
            nodeID = "$turnNode/event/1",
            parentID = "session/$session",
            kind = "turn-event",
        )
        val failure = assertThrows(NormError::class.java) { TrajectoryNormalizer.normalize(listOf(row)) }
        assertEquals("UNSTABLE_NODE_ID", failure.code)
    }

    @Test
    fun `platform noise below text respects the captured platform`() {
        val android = TrajectoryNormalizer.normalize(
            withParents(
                TrajectoryTestSupport.uiStateRow(
                    platform = "android",
                    sessionID = session,
                    seq = 1,
                    nodeID = "$turnNode/event/1",
                    parentID = turnNode,
                    kind = "turn-event",
                    text = "mach_absolute_time=123 thread=main",
                ),
            ),
        ).lines.last()
        assertTrue(android, android.contains("\"text\":\"mach_absolute_time=123 thread=<worker>\""))
        assertFalse(android, android.contains("mach_absolute_time=<removed>"))

        val ios = TrajectoryNormalizer.normalize(
            withParents(
                TrajectoryTestSupport.uiStateRow(
                    platform = "ios",
                    sessionID = session,
                    seq = 1,
                    nodeID = "$turnNode/event/1",
                    parentID = turnNode,
                    kind = "turn-event",
                    text = "mach_absolute_time=123 thread=main",
                ),
            ),
        ).lines.last()
        assertTrue(ios, ios.contains("\"text\":\"mach_absolute_time=<removed> thread=main\""))
        assertFalse(ios, ios.contains("thread=<worker>"))
    }

    @Test
    fun `platform noise follows each ui-state row after reordering`() {
        // The incoming order is event 2 (iOS) then event 1 (Android); stage 2 sorts them back.
        // Each row must still be normalized with its own captured platform: pairing platforms
        // by prepared position would swap the Android and iOS rule sets here.
        val rows = withParents(
            TrajectoryTestSupport.uiStateRow(
                platform = "ios",
                sessionID = session,
                seq = 2,
                nodeID = "$turnNode/event/2",
                parentID = turnNode,
                kind = "turn-event",
                text = "mach_absolute_time=99 thread=main",
            ),
        ) + TrajectoryTestSupport.uiStateRow(
            platform = "android",
            sessionID = session,
            seq = 1,
            nodeID = "$turnNode/event/1",
            parentID = turnNode,
            kind = "turn-event",
            text = "mach_absolute_time=99 thread=RenderThread",
        )
        val lines = TrajectoryNormalizer.normalize(rows).lines
        assertEquals(5, lines.size)
        assertTrue(
            lines[3],
            lines[3].contains("\"text\":\"mach_absolute_time=99 thread=<worker>\""),
        )
        assertTrue(
            lines[4],
            lines[4].contains("\"text\":\"mach_absolute_time=<removed> thread=main\""),
        )
    }

    private fun sequenceRows(): List<String> = listOf(
        rootRow(),
        sessionRow(),
        turnRow(),
        TrajectoryTestSupport.uiStateRow(
            platform = "android",
            sessionID = session,
            seq = 1,
            nodeID = "$turnNode/event/1",
            parentID = turnNode,
            kind = "turn-event",
            text = "hello\r\n at 2026-10-31T06:00:00Z pid=99",
        ),
        TrajectoryTestSupport.uiStateRow(
            platform = "android",
            sessionID = session,
            seq = 1,
            nodeID = "$turnNode/event/1/assistant-block-0",
            parentID = "$turnNode/event/1",
            kind = "bubble",
            surface = "bubble",
            props = "{\"durationMs\":10.1,\"bytes\":\"1.5 KiB\",\"percent\":50.0412," +
                "\"uuid\":\"123e4567-e89b-12d3-a456-426614174000\"}",
        ),
        TrajectoryTestSupport.uiStateRow(
            platform = "android",
            sessionID = session,
            seq = 2,
            nodeID = "$turnNode/event/2",
            parentID = turnNode,
            kind = "turn-event",
            text = "thread=main",
        ),
        TrajectoryTestSupport.uiStateRow(
            platform = "android",
            sessionID = session,
            seq = 2,
            nodeID = "$turnNode/event/2/tool-call",
            parentID = "$turnNode/event/2",
            kind = "tool-row",
            surface = "tool-row",
            props = "{\"path\":\"/dsh/workspace/a.md\",\"sizeBytes\":1024}",
        ),
        TrajectoryTestSupport.uiStateRow(
            platform = "android",
            sessionID = session,
            seq = 3,
            nodeID = "$turnNode/event/3",
            parentID = turnNode,
            kind = "turn-event",
        ),
        TrajectoryTestSupport.uiStateRow(
            platform = "android",
            sessionID = session,
            seq = 3,
            nodeID = "$turnNode/event/3/turn-end",
            parentID = "$turnNode/event/3",
            kind = "status",
            props = "{\"completed\":true}",
        ),
    )

    private fun rootRow(): String = TrajectoryTestSupport.uiStateRow(
        platform = "android",
        sessionID = session,
        turnID = "-",
        seq = 0,
        nodeID = "root",
        parentID = "root",
        kind = "root",
    )

    private fun sessionRow(): String = TrajectoryTestSupport.uiStateRow(
        platform = "android",
        sessionID = session,
        turnID = "-",
        seq = 0,
        nodeID = "session/$session",
        parentID = "root",
        kind = "session",
    )

    private fun withParents(last: String): List<String> = listOf(rootRow(), sessionRow(), turnRow(), last)

    private fun turnRow(): String = TrajectoryTestSupport.uiStateRow(
        platform = "android",
        sessionID = session,
        seq = 0,
        nodeID = turnNode,
        parentID = "session/$session",
        kind = "turn",
    )

    /** Reads the `nodeID` member back out of a canonical line without a JSON dependency. */
    private fun nodeIdOf(line: String): String {
        val marker = "\"nodeID\":\""
        val start = line.indexOf(marker) + marker.length
        return line.substring(start, line.indexOf('"', start))
    }
}

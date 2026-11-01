// Machine check: the pinned UiState expectations obey the §7 nodeID grammar.
// SPDX-License-Identifier: MIT
//
// This test reads the pinned JSONL as plain JSON, with no Python and no
// projector call. That is deliberate: `spec/v1/tools/trajectory_norm.py`
// enforces the same grammar, and the drift this test exists for was invisible
// because `:lib` never ran the Python oracle. Seven assertions per node keep
// the two languages in agreement without a cross-language call:
//
//  1. `kind` is one of the twelve contract kinds, so its depth is defined;
//  2. `nodeID`'s segment count matches that kind's depth (root 1, session 2,
//     turn 4, turn-event 6, slot 7);
//  3. the fixed grammar words are `session`, `turn`, `event` (`root` is the
//     whole id of a root row);
//  4. `parentID` is the parent the grammar puts at that depth (`session` and
//     `root` -> `root`; `turn` -> its session; `turn-event` -> its turn; slot
//     -> `nodeID` minus its slot segment);
//  5. the parent appears earlier in the file (the sequence is pre-order);
//  6. a slot's parent is a `turn-event` node whose path ends at `event/<seq>`
//     — the rule that a slot hangs under the event node, never the turn;
//  7. `nodeID` is unique and its session/turn/seq segments equal the row's
//     `sessionID`/`turnID`/`seq`.
package com.phonedsh.ui.projection

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UiStateNodeIDGrammarTest {
    @Test
    fun `every pinned node matches the section 7 nodeID grammar`() {
        PINNED.forEach { file ->
            val nodes = readPinned(file)
            assertTrue("$file: pinned sequence is empty", nodes.isNotEmpty())
            val seen = HashSet<String>()
            val kindByID = HashMap<String, String>()
            nodes.forEachIndexed { index, node ->
                val where = "$file[$index]"
                val nodeID = node.string("nodeID") ?: failAt(where, "nodeID is not a string")
                val parentID = node.string("parentID") ?: failAt(where, "parentID is not a string")
                val kind = node.string("kind") ?: failAt(where, "kind is not a string")
                val parts = nodeID.split('/')

                // 1. The kind is one of the twelve, so the depth it occupies is known.
                val depth = KIND_SEGMENTS[kind]
                assertNotNull("$where: '$kind' is not a ui-state/1 kind", depth)

                // 2. The segment count is the depth of that kind (§7 grammar).
                assertEquals(
                    "$where: $nodeID has ${parts.size} segments, kind '$kind' needs ${depth ?: -1}",
                    depth,
                    parts.size,
                )

                // 3. The fixed segment words are the grammar's words.
                if (kind == ROOT) {
                    assertEquals("$where: a root nodeID is the word root", ROOT, nodeID)
                } else {
                    assertEquals("$where: first segment", "session", parts[0])
                    if (parts.size >= 4) assertEquals("$where: third segment", "turn", parts[2])
                    if (parts.size >= 6) assertEquals("$where: fifth segment", "event", parts[4])
                }

                // 4. parentID is the parent the §7 grammar puts at this depth: the
                // session/turn/event prefix of the nodeID, and for a slot exactly
                // the nodeID minus the slot segment.
                val expectedParent = when (depth) {
                    1, 2 -> ROOT
                    4 -> parts.take(2).joinToString("/")
                    6 -> parts.take(4).joinToString("/")
                    7 -> nodeID.substringBeforeLast('/')
                    else -> failAt(where, "kind '$kind' has no grammar depth")
                }
                assertEquals(
                    "$where: parentID must be exactly one grammar level above $nodeID",
                    expectedParent,
                    parentID,
                )

                // 5. The parent was emitted earlier: the sequence is pre-order.
                if (kind != ROOT) {
                    assertTrue("$where: parent $parentID must precede $nodeID", parentID in seen)
                }

                // 6. A slot's parent is the event node, not the turn node: the
                // parent is nodeID minus the slot segment, sits at event/<seq>,
                // and is a turn-event row.
                if (depth == 7) {
                    val parentParts = parentID.split('/')
                    assertEquals(
                        "$where: a slot's parent must be nodeID minus its slot segment",
                        nodeID.substringBeforeLast('/'),
                        parentID,
                    )
                    assertEquals(
                        "$where: a slot's parent must be an event path, not $parentID",
                        "event",
                        parentParts.getOrNull(4),
                    )
                    assertEquals(
                        "$where: a slot's parent must be the turn-event node for seq ${parts[5]}",
                        TURN_EVENT,
                        kindByID[parentID],
                    )
                }

                // 7. nodeIDs are unique and their id segments agree with the row.
                assertTrue("$where: duplicate nodeID $nodeID", seen.add(nodeID))
                if (kind != ROOT) {
                    assertEquals("$where: session segment", parts[1], node.string("sessionID"))
                }
                if (parts.size >= 4) {
                    assertEquals("$where: turn segment", parts[3], node.string("turnID"))
                }
                if (parts.size >= 6) {
                    val seq = (node[KEY_SEQ] as? JsonNumber)?.asLongOrNull()
                    assertEquals("$where: seq segment", parts[5].toLongOrNull(), seq)
                }
                kindByID[nodeID] = kind
            }
        }
    }

    /** Reads one pinned expectation as JSON objects, in file order. */
    private fun readPinned(file: String): List<JsonObject> {
        val stream = requireNotNull(javaClass.getResourceAsStream("/ui-state/$file")) {
            "missing pinned resource /ui-state/$file; the pinned sequence is the acceptance data"
        }
        return stream.bufferedReader(Charsets.UTF_8).use { reader ->
            reader.readLines()
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .map { line ->
                    JsonValue.parse(line) as? JsonObject
                        ?: throw AssertionError("$file: a pinned line is not a JSON object")
                }
        }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonString)?.value

    private fun failAt(where: String, message: String): Nothing = throw AssertionError("$where: $message")

    private companion object {
        const val ROOT: String = "root"
        const val TURN_EVENT: String = "turn-event"
        const val KEY_SEQ: String = "seq"

        /** `§7` + `KIND_DEPTH` in `spec/v1/tools/trajectory_norm.py`: kind to segment count. */
        val KIND_SEGMENTS: Map<String, Int> = mapOf(
            "root" to 1,
            "session" to 2,
            "turn" to 4,
            TURN_EVENT to 6,
            "bubble" to 7,
            "context" to 7,
            "tool-row" to 7,
            "thinking-pill" to 7,
            "approval-card" to 7,
            "composer" to 7,
            "fail-loud-banner" to 7,
            "status" to 7,
        )

        /** The five golden cases, the one platform-specific expected file, and the context case. */
        val PINNED: List<String> = listOf(
            "chat-basic.jsonl",
            "permission-flow.jsonl",
            "reorder-window.jsonl",
            "tool-exec-noise.jsonl",
            "turn-error-vs-complete.jsonl",
            "turn-error-vs-complete.android.jsonl",
            "context-blocks.jsonl",
        )
    }
}

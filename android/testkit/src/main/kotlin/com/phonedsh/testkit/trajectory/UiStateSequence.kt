// :testkit trajectory — §7 UiState sequence: stable node ids, pre-order and stage-2 ordering.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.trajectory

import java.util.regex.Pattern

/**
 * The `ui-state/1` node-id grammar of `spec/v1/trajectory.md` §7.
 *
 * ```text
 * root
 * session/<sessionID>
 * session/<sessionID>/turn/<turnID>
 * session/<sessionID>/turn/<turnID>/event/<seq>
 * session/<sessionID>/turn/<turnID>/event/<seq>/<slot>
 * ```
 *
 * A `parentID` must be exactly one grammar level above its node, `kind` must match that
 * level, the session/turn/seq segments must agree with the row, and a slot must be a semantic
 * role — a UUID, a lone hex run or a random-looking suffix is rejected (`UNSTABLE_NODE_ID`).
 */
internal object UiStateGrammar {
    private val SURFACES = setOf(
        "bubble",
        "tool-row",
        "thinking-pill",
        "approval-card",
        "composer",
        "fail-loud-banner",
    )

    /** `kind` to the node-id depth it is allowed to occupy. */
    private val KIND_DEPTH = mapOf(
        "root" to "root",
        "session" to "session",
        "turn" to "turn",
        "turn-event" to "event",
        "bubble" to "slot",
        "tool-row" to "slot",
        "thinking-pill" to "slot",
        "approval-card" to "slot",
        "composer" to "slot",
        "fail-loud-banner" to "slot",
        "status" to "slot",
    )

    private val SLOT = Pattern.compile("[a-z][a-z0-9-]{0,63}")
    private val UUID = Pattern.compile(
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    )
    private val HEX_ONLY = Pattern.compile("[0-9a-fA-F]{8,64}")
    private val RANDOM_SLOT = Pattern.compile("(?:^|[-_])[0-9a-f]{8,}$")

    fun check(row: JsonObjectTree, where: String) {
        val nodeId = row.string("nodeID")
            ?: throw NormError("UNSTABLE_NODE_ID", where, "nodeID is missing or not a string")
        val parentId = row.string("parentID")
            ?: throw NormError("UNSTABLE_NODE_ID", where, "parentID is missing or not a string")
        val parsed = parseNodeId(nodeId, where)
        val expectedParent = expectedParent(parsed)
        if (parentId != expectedParent) {
            throw NormError(
                "UNSTABLE_NODE_ID",
                where,
                "parentID '$parentId' is not '$expectedParent' for node '$nodeId'",
            )
        }
        val kind = row.string("kind")
            ?: throw NormError("UNSTABLE_NODE_ID", where, "kind is missing or not a string")
        if (KIND_DEPTH[kind] != parsed.depth) {
            throw NormError(
                "UNSTABLE_NODE_ID",
                where,
                "kind '$kind' does not match node depth '${parsed.depth}'",
            )
        }
        if (parsed.depth != "root" && parsed.session != row.string("sessionID")) {
            throw NormError("UNSTABLE_NODE_ID", where, "node id disagrees with sessionID")
        }
        if (parsed.depth == "turn" || parsed.depth == "event" || parsed.depth == "slot") {
            if (parsed.turn != row.string("turnID")) {
                throw NormError("UNSTABLE_NODE_ID", where, "node id disagrees with turnID")
            }
        }
        if (parsed.depth == "event" || parsed.depth == "slot") {
            val seq = row.integer("seq")?.toLong()
                ?: throw NormError("UNSTABLE_NODE_ID", where, "seq is missing or not an integer")
            if (parsed.seq != seq) {
                throw NormError("UNSTABLE_NODE_ID", where, "node id disagrees with seq")
            }
        }
        val surface = row.string("surface")
            ?: throw NormError("UNSTABLE_NODE_ID", where, "surface is missing or not a string")
        if (surface != "none" && surface !in SURFACES) {
            throw NormError("SURFACE", where, "unknown signature surface '$surface'")
        }
    }

    private fun parseNodeId(nodeId: String, where: String): ParsedNode {
        if (nodeId == "root") return ParsedNode("root")
        val parts = nodeId.split("/")
        if (parts.size < 2 || parts[0] != "session") {
            throw NormError("UNSTABLE_NODE_ID", where, "node id is not a session path")
        }
        val session = parts[1]
        if (parts.size == 2) return ParsedNode("session", session = session)
        if (parts.size < 4 || parts[2] != "turn") {
            throw NormError("UNSTABLE_NODE_ID", where, "node id is not a turn path")
        }
        val turn = parts[3]
        if (parts.size == 4) return ParsedNode("turn", session = session, turn = turn)
        if (parts.size < 6 || parts[4] != "event") {
            throw NormError("UNSTABLE_NODE_ID", where, "node id is not an event path")
        }
        val seq = parts[5].toLongOrNull()
            ?: throw NormError("UNSTABLE_NODE_ID", where, "event segment is not an integer")
        if (parts.size == 6) return ParsedNode("event", session = session, turn = turn, seq = seq)
        if (parts.size == 7) {
            val slot = parts[6]
            if (!SLOT.matcher(slot).matches()) {
                throw NormError("UNSTABLE_NODE_ID", where, "slot is not a semantic role")
            }
            if (UUID.matcher(slot).matches() ||
                HEX_ONLY.matcher(slot).matches() ||
                RANDOM_SLOT.matcher(slot).find()
            ) {
                throw NormError("UNSTABLE_NODE_ID", where, "slot looks like a random identifier")
            }
            return ParsedNode("slot", session = session, turn = turn, seq = seq, slot = slot)
        }
        throw NormError("UNSTABLE_NODE_ID", where, "node id is deeper than the grammar")
    }

    private fun expectedParent(parsed: ParsedNode): String = when (parsed.depth) {
        "root", "session" -> "root"
        "turn" -> "session/${parsed.session}"
        "event" -> "session/${parsed.session}/turn/${parsed.turn}"
        "slot" -> "session/${parsed.session}/turn/${parsed.turn}/event/${parsed.seq}"
        else -> throw NormError("UNSTABLE_NODE_ID", "node", "unknown node depth")
    }

    private class ParsedNode(
        val depth: String,
        val session: String? = null,
        val turn: String? = null,
        val seq: Long? = null,
        val slot: String? = null,
    )
}

/**
 * The UiState half of stage 2: same `W = 16` window, same `(sessionID, turnID)` groups, but the
 * total key is `(seq, nodeID)` — `seq` may repeat across siblings and `nodeID` breaks the tie.
 * Afterwards every parent must exist and precede its child, because the sequence is a flat
 * pre-order projection of the tree.
 */
internal fun orderUiState(prepared: List<PreparedRow>, stats: NormalizationStats): List<PreparedRow> {
    val seenIds = HashSet<String>()
    for ((index, row) in prepared.withIndex()) {
        val where = "row ${index + 1}"
        UiStateGrammar.check(row.tree, where)
        val nodeId = row.tree.string("nodeID")!!
        if (!seenIds.add(nodeId)) {
            throw NormError("UNSTABLE_NODE_ID", where, "duplicate nodeID '$nodeId'")
        }
    }

    val rows = prepared.mapIndexed { arrival, row ->
        val session = row.tree.string("sessionID")
            ?: throw NormError("ORDER", "row ${arrival + 1}", "missing 'sessionID'")
        val turn = row.tree.string("turnID")
            ?: throw NormError("ORDER", "row ${arrival + 1}", "missing 'turnID'")
        val seq = row.tree.integer("seq")?.toLong()
            ?: throw NormError("ORDER", "row ${arrival + 1}", "missing 'seq'")
        val nodeId = row.tree.string("nodeID")
            ?: throw NormError("UNSTABLE_NODE_ID", "row ${arrival + 1}", "missing nodeID")
        UiStateRow(row, arrival, session, turn, seq, nodeId)
    }

    val groups = LinkedHashMap<Pair<String, String>, MutableList<UiStateRow>>()
    for (row in rows) {
        groups.getOrPut(row.session to row.turn) { ArrayList() } += row
    }
    val ordered = ArrayList<UiStateRow>(rows.size)
    val keys = groups.keys.sortedWith(Comparator { left, right ->
        val bySession = PythonSemantics.compareCodePoints(left.first, right.first)
        if (bySession != 0) bySession else PythonSemantics.compareCodePoints(left.second, right.second)
    })
    for (key in keys) {
        val group = groups.getValue(key)
        val label = "${key.first}/${key.second}"
        checkWindow(group.map { it.seq }, label)
        group.sortWith(Comparator { left, right ->
            val bySeq = left.seq.compareTo(right.seq)
            if (bySeq != 0) {
                bySeq
            } else {
                val byNode = PythonSemantics.compareCodePoints(left.nodeId, right.nodeId)
                if (byNode != 0) byNode else left.arrival.compareTo(right.arrival)
            }
        })
        ordered += group
    }

    val positions = HashMap<String, Int>(ordered.size)
    for ((index, row) in ordered.withIndex()) positions[row.nodeId] = index
    for ((index, row) in ordered.withIndex()) {
        if (row.nodeId == "root") continue
        val parent = row.row.tree.string("parentID")
            ?: throw NormError("UNSTABLE_NODE_ID", "row ${index + 1}", "missing parentID")
        val position = positions[parent]
            ?: throw NormError(
                "UNSTABLE_NODE_ID",
                "row ${index + 1}",
                "parent '$parent' is not in the sequence",
            )
        if (position >= index) {
            throw NormError(
                "UNSTABLE_NODE_ID",
                "row ${index + 1}",
                "parent '$parent' does not precede its child",
            )
        }
    }
    stats.groups = groups.size
    return ordered.map { it.row }
}

private class UiStateRow(
    val row: PreparedRow,
    val arrival: Int,
    val session: String,
    val turn: String,
    val seq: Long,
    val nodeId: String,
)

// The UiState projector: Harness events -> `ui-state/1` nodes.
// SPDX-License-Identifier: MIT
//
// Normative inputs, in authority order:
//   * `spec/host/v1/event-kinds.md` — the only event vocabulary. This file never
//     invents a kind: it switches on the closed `HarnessKind` set and the
//     fifteen host kinds.
//   * `spec/v1/trajectory.md` §7 — nodeID grammar, uniqueness, parentage and the
//     semantic-vs-pixel boundary.
//   * `spec/v1/schema/ui-state-sequence.schema.json` — shape (kind/surface
//     enums, patterns, `text` bound).
//   * `spec/ui/v1/README.md` §2/§3 — which rows appear, fold and disappear. A
//     row is only projected where the event stream can decide its truth; the
//     interactive fold ("continuous tool rows merge into one row") belongs to
//     the screen state, because a node is event-anchored by the nodeID grammar.
//
// Every projected node is checked against the grammar before it is emitted: an
// unrepresentable row fails loud (`UiStateProjectionException`) instead of being
// silently dropped or renamed.
package com.phonedsh.ui.projection

import com.phonedsh.agentcore.HarnessEvent
import com.phonedsh.agentcore.HarnessKind
import com.phonedsh.agentcore.HarnessTurnEnd
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.math.BigDecimal
import java.math.RoundingMode

/**
 * Projects one session stream into a flat pre-order `ui-state/1` sequence.
 *
 * Every event that projects at least one row yields exactly one `turn-event`
 * node (`.../event/<seq>`); the event's rows are slots below it
 * (`.../event/<seq>/<slot>`). `trajectory.md` §7 lists those as two grammar
 * levels and requires every `parentID` to name the level exactly above its
 * child, so a slot's parent is the event node, never the turn.
 *
 * The function is total over valid input: it either returns a sequence that
 * satisfies the schema or throws [UiStateProjectionException] with the broken
 * invariant's code. It is pure and deterministic — the same events produce the
 * same bytes.
 */
public object UiStateProjector {
    /** The ordering tolerance window of `spec/v1/trajectory.md` §3. */
    public const val WINDOW: Int = 16

    /** The schema's `text.maxLength`. */
    public const val TEXT_LIMIT: Int = 20_000

    /** The nodeID root word. */
    public const val ROOT_NODE_ID: String = "root"

    /** The session-scope `turnID` (`spec/host/v1/event-kinds.md` §1). */
    public const val SESSION_SCOPE_TURN: String = "-"

    /**
     * Projects [events].
     *
     * @throws UiStateProjectionException with code `DUPLICATE_SEQ`,
     *   `OUT_OF_WINDOW`, `UNSTABLE_NODE_ID` or `SHAPE`.
     */
    public fun project(events: List<HarnessEvent>): List<UiStateNode> {
        if (events.isEmpty()) return emptyList()
        events.forEach { requireSessionId(it.sessionId) }
        val ordered = order(events)
        val walk = Walk()
        walk.start(ordered.first().sessionId)
        ordered.forEach { walk.accept(it) }
        return walk.nodes
    }

    /**
     * Stage 2 of the shared pipeline: one deterministic total order.
     *
     * Durable rows order by `seq`; a best-effort row has no `seq`
     * (`HarnessKindName.durable == false`) and keeps its arrival position right
     * after the durable row it followed. The `W = 16` window and the duplicate
     * rule are enforced on arrival order, exactly as `trajectory.md` §3 states:
     * a stream that is too far out of order fails instead of being silently
     * reordered.
     */
    private fun order(events: List<HarnessEvent>): List<HarnessEvent> {
        val lastDurableSeen = HashMap<String, Long>()
        val arrivalBySession = LinkedHashMap<String, MutableList<Int>>()
        val anchorOf = HashMap<Int, Pair<Long, Boolean>>()

        events.forEachIndexed { index, event ->
            val claimed: Long? = event.seq
            val anchor = claimed ?: lastDurableSeen[event.sessionId] ?: 0L
            if (claimed != null) lastDurableSeen[event.sessionId] = claimed
            anchorOf[index] = anchor to (claimed != null)
            arrivalBySession.getOrPut(event.sessionId) { mutableListOf() }.add(index)
        }

        arrivalBySession.forEach { (sessionId, indices) ->
            val seen = ArrayList<Long>()
            indices.forEach { index ->
                val seq = events[index].seq ?: return@forEach
                if (seen.contains(seq)) {
                    throw UiStateProjectionException(
                        "DUPLICATE_SEQ",
                        "session $sessionId carries seq $seq twice",
                    )
                }
                val lateBy = seen.count { it > seq }
                if (lateBy > WINDOW) {
                    throw UiStateProjectionException(
                        "OUT_OF_WINDOW",
                        "session $sessionId row seq $seq arrived $lateBy behind, window is $WINDOW",
                    )
                }
                seen.add(seq)
            }
        }

        return arrivalBySession.keys.sortedWith(compareBy { it })
            .flatMap { sessionId ->
                arrivalBySession.getValue(sessionId)
                    .sortedWith(
                        compareBy<Int> { anchorOf.getValue(it).first }
                            .thenBy { if (anchorOf.getValue(it).second) 0 else 1 }
                            .thenBy { it },
                    )
                    .map { events[it] }
            }
    }

    private fun requireSessionId(sessionId: String) {
        if (!SESSION_ID.matches(sessionId)) {
            throw UiStateProjectionException(
                "UNSTABLE_NODE_ID",
                "session id '$sessionId' is outside [A-Za-z0-9._-]{1,64}",
            )
        }
    }

    /** `turn-%04d` for an integer turn, `-` for session scope, else unrepresentable (no guessing). */
    internal fun turnKey(raw: String): String {
        if (raw == SESSION_SCOPE_TURN) return SESSION_SCOPE_TURN
        if (TURN_ID.matches(raw)) return raw
        val number = raw.toIntOrNull()
            ?: throw UiStateProjectionException("UNSTABLE_NODE_ID", "turn id '$raw' has no integer turn")
        return "turn-%04d".format(number)
    }

    private val SESSION_ID = Regex("[A-Za-z0-9._-]{1,64}")
    private val TURN_ID = Regex("turn-[0-9]{4}")
    private val SLOT = Regex("[a-z][a-z0-9-]{0,63}")

    /**
     * The incremental walk. Holds the only mutable bookkeeping (current turn,
     * last ordinal, the reasoning buffer, running tool rows); the emitted list is
     * append-only except for the "stopped" rewrite the state machine requires.
     */
    private class Walk {
        val nodes: MutableList<UiStateNode> = mutableListOf()
        private val known = HashSet<String>()
        private val sessionNodes = HashMap<String, String>()
        private val turnNodes = HashMap<String, String>()
        private val currentTurn = HashMap<String, String>()
        private val lastOrdinal = HashMap<String, Int>()
        private val reasoning = HashMap<String, StringBuilder>()
        private val callNames = HashMap<String, String>()
        private var primarySession: String = ""
        /** The ordinal of the event being accepted; cleared for each event. */
        private var eventOrdinal: Int? = null

        /** The `turn-event` node of the event being accepted, once its first row is emitted. */
        private var eventRootID: String? = null

        fun start(sessionId: String) {
            primarySession = sessionId
            emit(
                UiStateNode(
                    kind = UiStateKind.ROOT,
                    nodeID = ROOT_NODE_ID,
                    parentID = ROOT_NODE_ID,
                    sessionID = sessionId,
                    turnID = SESSION_SCOPE_TURN,
                    seq = 0,
                )
            )
        }

        fun accept(event: HarnessEvent) {
            // Two rows of one event share its ordinal and differ by slot
            // (`§7` event/<seq>/<slot>); the ordinal and the event node are
            // allocated once per event, on its first row.
            eventOrdinal = null
            eventRootID = null
            val sessionId = event.sessionId
            session(sessionId)
            when (val kind = event.kind) {
                // Best-effort streaming text is never a row of its own: the durable
                // assistant message already carries the final text.
                is HarnessKind.AssistantDelta -> Unit
                is HarnessKind.ReasoningDelta -> reasoning.getOrPut(sessionId) { StringBuilder() }.append(kind.text)
                is HarnessKind.AssistantMessage -> assistantMessage(event, kind)
                is HarnessKind.ToolCall -> toolCall(event, kind)
                is HarnessKind.ToolResult -> toolResult(event, kind)
                is HarnessKind.PermissionRequested -> permissionRequest(event, kind)
                is HarnessKind.QuestionRequested -> questionRequest(event, kind)
                is HarnessKind.UserMessage -> userMessage(event, kind)
                // `inbox_spliced` has no projection type (event-kinds.md §1 "—").
                is HarnessKind.InboxSpliced -> Unit
                is HarnessKind.TurnStarted -> turn(event, kind.turnId)
                is HarnessKind.TurnEnded -> turnEnded(event, kind)
                is HarnessKind.Progress -> progress(event, kind)
                is HarnessKind.SessionStatus -> sessionStatus(event, kind)
                // `usage` has no row of its own (event-kinds.md §1 "folded").
                is HarnessKind.Usage -> Unit
                is HarnessKind.Exited -> exited(event, kind)
            }
        }

        // ---- structural nodes ------------------------------------------------

        private fun session(sessionId: String): String =
            sessionNodes.getOrPut(sessionId) {
                val id = "session/$sessionId"
                emit(
                    UiStateNode(
                        kind = UiStateKind.SESSION,
                        nodeID = id,
                        parentID = ROOT_NODE_ID,
                        sessionID = sessionId,
                        turnID = SESSION_SCOPE_TURN,
                        seq = 0,
                    )
                )
                id
            }

        private fun turn(event: HarnessEvent, rawTurnId: String): String {
            val sessionId = event.sessionId
            val turnId = turnKey(rawTurnId)
            currentTurn[sessionId] = turnId
            return turnNode(sessionId, turnId)
        }

        private fun turnNode(sessionId: String, turnId: String): String =
            turnNodes.getOrPut("$sessionId|$turnId") {
                val id = "session/$sessionId/turn/$turnId"
                emit(
                    UiStateNode(
                        kind = UiStateKind.TURN,
                        nodeID = id,
                        parentID = session(sessionId),
                        sessionID = sessionId,
                        turnID = turnId,
                        seq = 0,
                    )
                )
                id
            }

        /** The enclosing turn: the open one, or session scope when the stream never started a turn. */
        private fun enclosingTurn(sessionId: String): String =
            turnNode(sessionId, currentTurn[sessionId] ?: SESSION_SCOPE_TURN)

        // ---- event rows ------------------------------------------------------

        /**
         * One user-role message: a bubble, or an injected context block.
         *
         * `spec/host/v1/schema/harness-event.schema.json` requires `source` on
         * every `user_message`, and DSH writes the producer-declared kind there:
         * `user` for what the person typed, an injected kind (`user-approval`,
         * `file`, `command`, …) for context the model was shown. This is the
         * same classifier the iOS baseline applies to the journal
         * (`DSHMessageSourceClassifier` → `NativeTranscriptProjector`), and it
         * reads only the source, never the message text: content is untrusted
         * and must not decide whether a row presents as user input.
         *
         * `unknown` means "the event carried no source" — a fixture or
         * adapter-fallback marker, never a producer's declaration. Production
         * always carries `source` (it is required in `spec/host/v1`'s
         * `user_message`), so treating `unknown` as an injected block would turn
         * every legacy fixture's main prompt into context.
         *
         * The context row is a slot node with no pixel surface: the grouped
         * rendering (`NativeContextSourceGroup`) is screen state, and the host
         * source name travels in `props.source` for the screen to translate.
         */
        private fun userMessage(event: HarnessEvent, kind: HarnessKind.UserMessage) {
            val (text, truncated) = bounded(kind.text)
            val context = kind.source != USER_SOURCE && kind.source != UNKNOWN_SOURCE
            eventRow(
                event = event,
                slot = if (context) "context" else "user-message",
                kind = if (context) UiStateKind.CONTEXT else UiStateKind.BUBBLE,
                surface = if (context) UiStateSurface.NONE else UiStateSurface.BUBBLE,
                text = text,
                props = if (context) {
                    props(
                        "source" to JsonString(kind.source),
                        "truncated" to JsonBool(truncated),
                    )
                } else {
                    props(
                        "role" to JsonString("user"),
                        "source" to JsonString(kind.source),
                        "truncated" to JsonBool(truncated),
                    )
                },
            )
        }

        private fun assistantMessage(event: HarnessEvent, kind: HarnessKind.AssistantMessage) {
            val sessionId = event.sessionId
            val buffered = reasoning[sessionId]?.toString().orEmpty()
            if (buffered.isNotBlank()) {
                val summary = ReasoningSummary.summarize(buffered)
                val (fullReasoning, fullReasoningTruncated) = bounded(buffered)
                if (summary.isNotEmpty()) {
                    eventRow(
                        event = event,
                        slot = "thinking",
                        kind = UiStateKind.THINKING_PILL,
                        surface = UiStateSurface.THINKING_PILL,
                        text = bounded(summary).first,
                        props = props(
                            "streaming" to JsonBool(false),
                            "collapsed" to JsonBool(true),
                            // The collapsed row text is only the preview. Preserve
                            // the existing text budget for expanded content and
                            // expose truncation instead of claiming the prefix is
                            // the complete source reasoning.
                            "fullReasoning" to JsonString(fullReasoning),
                            "fullReasoningTruncated" to JsonBool(fullReasoningTruncated),
                        ),
                    )
                }
                reasoning[sessionId] = StringBuilder()
            }
            val (text, truncated) = bounded(kind.text)
            eventRow(
                event = event,
                slot = "assistant-message",
                kind = UiStateKind.BUBBLE,
                // The assistant answer has no bubble chrome (tokens.json
                // signatureSurfaces.bubble.note): semantic row, not pixel surface.
                surface = UiStateSurface.NONE,
                text = text,
                props = props(
                    "role" to JsonString("assistant"),
                    "truncated" to JsonBool(truncated),
                ),
            )
        }

        private fun toolCall(event: HarnessEvent, kind: HarnessKind.ToolCall) {
            callNames[kind.callId] = kind.name
            eventRow(
                event = event,
                slot = "tool-call",
                kind = UiStateKind.TOOL_ROW,
                surface = UiStateSurface.TOOL_ROW,
                text = bounded(kind.name).first,
                props = props(
                    "arguments" to canonical(kind.arguments),
                    "callId" to JsonString(kind.callId),
                    "name" to JsonString(kind.name),
                    "phase" to JsonString("call"),
                    "state" to JsonString("running"),
                ),
            )
        }

        private fun toolResult(event: HarnessEvent, kind: HarnessKind.ToolResult) {
            val state = if (kind.isError) "error" else "ok"
            val firstLine = kind.summary.lineSequence().firstOrNull()?.trim().orEmpty()
            val name = callNames[kind.callId]
            val base = props(
                "callId" to JsonString(kind.callId),
                "isError" to JsonBool(kind.isError),
                "phase" to JsonString("result"),
                "state" to JsonString(state),
            )
            eventRow(
                event = event,
                slot = "tool-result",
                kind = UiStateKind.TOOL_ROW,
                surface = UiStateSurface.TOOL_ROW,
                text = bounded(firstLine).first,
                props = name?.let { JsonObject(base.members + ("name" to JsonString(it))) } ?: base,
            )
        }

        private fun permissionRequest(event: HarnessEvent, kind: HarnessKind.PermissionRequested) {
            val request = kind.request
            val (text, truncated) = bounded(request.summary)
            eventRow(
                event = event,
                slot = "permission-request",
                kind = UiStateKind.APPROVAL_CARD,
                surface = UiStateSurface.APPROVAL_CARD,
                text = text.ifEmpty { null },
                props = props(
                    "kind" to JsonString("permission"),
                    "requestId" to JsonString(request.requestId),
                    // `risk` is a policy input, not a rendered field: it stays out of the
                    // node so a UI row never depends on a value the card cannot show.
                    "tool" to JsonString(request.tool),
                    "truncated" to JsonBool(truncated),
                ),
            )
        }

        private fun questionRequest(event: HarnessEvent, kind: HarnessKind.QuestionRequested) {
            val request = kind.request
            val items = request.questions
            val prompt = items?.firstOrNull()?.prompt ?: request.prompt
            val (text, truncated) = bounded(prompt)
            val options = items?.firstOrNull()?.options ?: request.options
            eventRow(
                event = event,
                slot = "question-request",
                kind = UiStateKind.APPROVAL_CARD,
                surface = UiStateSurface.APPROVAL_CARD,
                text = text.ifEmpty { null },
                props = props(
                    "count" to JsonNumber((items?.size ?: 1).toString()),
                    "kind" to JsonString("question"),
                    "multiple" to JsonBool(items?.firstOrNull()?.multiple ?: false),
                    "options" to JsonArray(options.map { JsonString(it) }),
                    // Preserve every field the host actually supplied. Header,
                    // detail, descriptions and intent are not in HarnessQuestionItem.
                    "questionItems" to JsonArray(
                        (items ?: listOf(
                            com.phonedsh.agentcore.HarnessQuestionItem(
                                id = "answer",
                                prompt = request.prompt,
                                options = request.options,
                            ),
                        )).map { item ->
                            JsonObject(
                                mapOf(
                                    "id" to JsonString(item.id),
                                    "prompt" to JsonString(bounded(item.prompt).first),
                                    "options" to JsonArray(item.options.map(::JsonString)),
                                    "multiple" to JsonBool(item.multiple),
                                ),
                            )
                        },
                    ),
                    "requestId" to JsonString(request.requestId),
                    "truncated" to JsonBool(truncated),
                ),
            )
        }

        /**
         * One node per turn end, whatever the reason.
         *
         * A completed turn is a node but not a visible row: visibility is a
         * ScreenState decision (`spec/ui/v1/README.md` §6). Keeping the node is
         * what lets the screen decide whether the turn is still open — the row
         * itself is the fact, the render is the policy.
         */
        private fun turnEnded(event: HarnessEvent, kind: HarnessKind.TurnEnded) {
            val sessionId = event.sessionId
            val turnId = turn(event, kind.turnId)
            val reason = event.rawTurnEndKind ?: kind.reason.kind
            if (reason == "cancelled" || reason == "aborted" || reason == "interrupted") {
                markRunningToolsStopped(turnId)
            }
            val message = turnEndMessage(kind.reason, event.rawTurnEndCause)
            eventRow(
                event = event,
                slot = "turn-end",
                kind = UiStateKind.STATUS,
                surface = UiStateSurface.NONE,
                text = bounded(reason).first,
                props = props(
                    "reason" to JsonString(reason),
                    "turnId" to JsonString(turnId.substringAfterLast('/')),
                ),
            )
            if (reason == "error" || reason == "failed") {
                // Fail-loud: the banner is a row, never a log line (ui README §2).
                eventRow(
                    event = event,
                    slot = "turn-failure",
                    kind = UiStateKind.FAIL_LOUD_BANNER,
                    surface = UiStateSurface.FAIL_LOUD_BANNER,
                    text = message?.let { bounded(it).first },
                    props = props(
                        "dismissible" to JsonBool(true),
                        "reason" to JsonString(reason),
                        "retryable" to JsonBool(true),
                    ),
                )
            }
        }

        private fun progress(event: HarnessEvent, kind: HarnessKind.Progress) {
            val phase = kind.phase
            val slot = when {
                phase == "llm/retry" || phase.startsWith("llm/retry/") -> "llm-retry"
                phase == "compaction" || phase.startsWith("compaction/") -> "compaction-start"
                else -> return
            }
            val base = props(
                "phase" to JsonString(phase),
                "step" to JsonNumber(kind.step.toString()),
            )
            val withOf = kind.of?.let { JsonObject(base.members + ("of" to JsonNumber(it.toString()))) } ?: base
            eventRow(
                event = event,
                slot = slot,
                kind = UiStateKind.STATUS,
                surface = UiStateSurface.NONE,
                text = null,
                props = withOf,
            )
        }

        private fun sessionStatus(event: HarnessEvent, kind: HarnessKind.SessionStatus) {
            if (!kind.status.startsWith("error")) return
            eventRow(
                event = event,
                slot = "session-status",
                kind = UiStateKind.STATUS,
                surface = UiStateSurface.NONE,
                text = bounded(kind.status).first,
                props = props("status" to JsonString(kind.status)),
            )
        }

        private fun exited(event: HarnessEvent, kind: HarnessKind.Exited) {
            eventRow(
                event = event,
                slot = "exited",
                kind = UiStateKind.STATUS,
                surface = UiStateSurface.NONE,
                text = bounded(kind.reason).first.ifEmpty { null },
                props = props("exited" to JsonBool(true)),
            )
        }

        // ---- row mechanics ---------------------------------------------------

        /**
         * Emits the event's `turn-event` node (once) and one slot node below it.
         *
         * `trajectory.md` §7 lists `.../event/<seq>` and `.../event/<seq>/<slot>`
         * as two grammar levels and requires every `parentID` to name the level
         * exactly above its child. So the slot's parent is the event node, never
         * the turn. [slot] names the semantic role; when a single event projects
         * two rows they are two slots under one event node and share its ordinal.
         */
        private fun eventRow(
            event: HarnessEvent,
            slot: String,
            kind: UiStateKind,
            surface: UiStateSurface,
            text: String?,
            props: JsonObject,
        ) {
            val sessionId = event.sessionId
            val parent = enclosingTurn(sessionId)
            val turnId = currentTurn[sessionId] ?: SESSION_SCOPE_TURN
            val ordinal = eventOrdinal ?: ordinal(sessionId, event.seq).also { eventOrdinal = it }
            if (!SLOT.matches(slot)) {
                throw UiStateProjectionException("UNSTABLE_NODE_ID", "slot '$slot' is outside the grammar")
            }
            val eventID = eventRootID
                ?: turnEventNode(sessionId, turnId, parent, ordinal).also { eventRootID = it }
            emit(
                UiStateNode(
                    kind = kind,
                    nodeID = "$eventID/$slot",
                    parentID = eventID,
                    sessionID = sessionId,
                    turnID = turnId,
                    seq = ordinal,
                    surface = surface,
                    text = text,
                    props = props,
                )
            )
        }

        /**
         * The `.../event/<seq>` node of the event being accepted.
         *
         * It is an anchor, not a row: no text, no surface, and the screen ignores
         * it (`ChatScreenState`). It exists because §7 gives a slot no other
         * valid parent, and a row that cannot name its parent must fail loud.
         */
        private fun turnEventNode(sessionId: String, turnId: String, turnNodeID: String, ordinal: Int): String {
            val id = "$turnNodeID/event/$ordinal"
            emit(
                UiStateNode(
                    kind = UiStateKind.TURN_EVENT,
                    nodeID = id,
                    parentID = turnNodeID,
                    sessionID = sessionId,
                    turnID = turnId,
                    seq = ordinal,
                )
            )
            return id
        }

        /**
         * The row ordinal: the harness `seq` for a durable event; for a
         * best-effort event (no `seq`) the writer's own next ordinal, the same
         * rule `event-kinds.md` §2 uses for `permission/result`.
         *
         * A later durable row whose `seq` is already taken is bumped to the next
         * free ordinal, so nodeIDs stay unique and the pre-order stays
         * chronological even when a client row slots a number in between.
         */
        private fun ordinal(sessionId: String, claimed: Long?): Int {
            val last = lastOrdinal[sessionId] ?: 0
            val requested = claimed?.toInt() ?: (last + 1)
            val ordinal = maxOf(requested, last + 1)
            if (ordinal < 0 || ordinal > 1_000_000) {
                throw UiStateProjectionException("UNSTABLE_NODE_ID", "seq $ordinal is outside 0..1000000")
            }
            lastOrdinal[sessionId] = ordinal
            return ordinal
        }

        private fun markRunningToolsStopped(turnId: String) {
            for (index in nodes.indices) {
                val node = nodes[index]
                if (node.kind != UiStateKind.TOOL_ROW) continue
                // Tool rows are slots below one of this turn's event nodes.
                if (!node.parentID.startsWith("$turnId/event/")) continue
                val state = node.props["state"] as? JsonString ?: continue
                if (state.value != "running") continue
                nodes[index] = node.copy(
                    props = JsonObject(node.props.members + ("state" to JsonString("stopped"))),
                )
            }
        }

        private fun emit(node: UiStateNode) {
            requireGrammar(node)
            if (!known.add(node.nodeID)) {
                throw UiStateProjectionException("UNSTABLE_NODE_ID", "duplicate nodeID ${node.nodeID}")
            }
            nodes.add(node)
        }

        private fun requireGrammar(node: UiStateNode) {
            if (!NODE_ID.matches(node.nodeID) || !NODE_ID.matches(node.parentID)) {
                throw UiStateProjectionException("UNSTABLE_NODE_ID", "nodeID ${node.nodeID} is outside the grammar")
            }
            // §7: "every parentID names an existing node and is exactly one grammar
            // level above its child". This is the check that a slot hanging under
            // a turn would have failed.
            if (node.parentID != parentOf(node.nodeID)) {
                throw UiStateProjectionException(
                    "UNSTABLE_NODE_ID",
                    "parent ${node.parentID} is not exactly one grammar level above ${node.nodeID}",
                )
            }
            if (node.parentID != ROOT_NODE_ID && !known.contains(node.parentID)) {
                throw UiStateProjectionException("UNSTABLE_NODE_ID", "parent ${node.parentID} was never projected")
            }
            if (node.sessionID in setOf("", " ")) {
                throw UiStateProjectionException("UNSTABLE_NODE_ID", "empty sessionID on ${node.nodeID}")
            }
        }

        /**
         * The parent the `§7` grammar implies at each depth: `session` hangs under
         * `root`, `turn` under its session, `turn-event` under its turn, and a
         * slot under its event node (`nodeID` minus the slot segment). `root` is
         * its own parent because the schema requires `parentID` on every row.
         */
        private fun parentOf(nodeID: String): String {
            val parts = nodeID.split("/")
            return when {
                parts.size <= 2 -> ROOT_NODE_ID
                parts.size == 4 -> parts.subList(0, 2).joinToString("/")
                parts.size == 6 -> parts.subList(0, 4).joinToString("/")
                parts.size == 7 -> parts.subList(0, 6).joinToString("/")
                else -> throw UiStateProjectionException(
                    "UNSTABLE_NODE_ID",
                    "nodeID $nodeID is not a grammar level",
                )
            }
        }
    }

    private val NODE_ID = Regex(
        "root|session/[A-Za-z0-9._-]{1,64}(/turn/(?:-|turn-[0-9]{4})(/event/[1-9][0-9]{0,5}(/[a-z][a-z0-9-]{0,63})?)?)?",
    )

    private fun props(vararg pairs: Pair<String, JsonValue>): JsonObject =
        JsonObject(pairs.toMap().toSortedMap())

    /** Bounds `text` to the schema limit with an explicit marker, never a silent cut. */
    private fun bounded(text: String): Pair<String, Boolean> {
        if (text.length <= TEXT_LIMIT) return text to false
        val kept = text.take(TEXT_LIMIT - TRUNCATION_MARKER.length) + TRUNCATION_MARKER
        return kept to true
    }

    private const val TRUNCATION_MARKER: String = "…[truncated]"

    /** The one `user_message.source` that means the person wrote the message. */
    private const val USER_SOURCE: String = "user"

    /**
     * The adapter's marker for "the row carried no source" (`SpecFixtures.UNKNOWN_SOURCE`),
     * not a producer-declared context kind; it stays a bubble.
     */
    private const val UNKNOWN_SOURCE: String = "unknown"

    private fun turnEndMessage(reason: HarnessTurnEnd, rawCause: String?): String? = when (reason) {
        is HarnessTurnEnd.Failed -> reason.message.ifEmpty { rawCause }
        else -> rawCause
    }

    /** Stage 4 (generic float) for a value carried in `props`: half-even, 6 dp, integral -> integer. */
    internal fun canonical(value: JsonValue): JsonValue = when (value) {
        is JsonNumber -> JsonNumber(canonicalNumber(value.raw))
        is JsonArray -> JsonArray(value.values.map { canonical(it) })
        is JsonObject -> JsonObject(value.members.mapValues { canonical(it.value) })
        else -> value
    }

    internal fun canonicalNumber(raw: String): String {
        val decimal = BigDecimal(raw)
        val trimmed = decimal.stripTrailingZeros()
        if (trimmed.scale() <= 0) return trimmed.toBigInteger().toString()
        val rounded = decimal.setScale(6, RoundingMode.HALF_EVEN).stripTrailingZeros()
        return if (rounded.scale() <= 0) rounded.toBigInteger().toString() else rounded.toPlainString()
    }
}

/**
 * The collapsed summary of a reasoning block (`spec/ui/v1/README.md` §2):
 * the first line of the last double-newline segment, with `**` removed.
 */
public object ReasoningSummary {
    /** Returns the summary line, or an empty string when [reasoning] carries no text. */
    public fun summarize(reasoning: String): String {
        val last = reasoning.split("\n\n")
            .map { it.trim() }
            .lastOrNull { it.isNotEmpty() }
            ?: return ""
        return last.lineSequence().first().replace("**", "").trim()
    }
}

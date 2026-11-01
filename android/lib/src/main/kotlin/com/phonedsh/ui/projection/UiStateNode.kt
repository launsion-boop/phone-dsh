// One node of the flat `ui-state/1` pre-order sequence.
// SPDX-License-Identifier: MIT
//
// Shape is fixed by `spec/v1/schema/ui-state-sequence.schema.json`: geometry,
// colours, frames and screenshots are deliberately not members, because pixel
// comparison uses a separate screenshot artifact
// (`spec/v1/trajectory.md` §7 "Semantic vs pixel").
package com.phonedsh.ui.projection

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString

/** The twelve `kind` values of `ui-state/1`. */
public enum class UiStateKind(public val wire: String) {
    ROOT("root"),
    SESSION("session"),
    TURN("turn"),
    TURN_EVENT("turn-event"),
    BUBBLE("bubble"),

    /**
     * One injected context block (a `user_message` whose producer-declared
     * `source` is not `user`): a slot node like [BUBBLE], never a pixel surface.
     */
    CONTEXT("context"),
    TOOL_ROW("tool-row"),
    THINKING_PILL("thinking-pill"),
    APPROVAL_CARD("approval-card"),
    COMPOSER("composer"),
    FAIL_LOUD_BANNER("fail-loud-banner"),
    STATUS("status"),
    ;

    public companion object {
        /** Returns the kind for a wire label, or `null` for a label this contract version does not know. */
        public fun fromWire(wire: String): UiStateKind? = entries.firstOrNull { it.wire == wire }
    }
}

/** The six signature surfaces plus `none`; `surface` says which pixels a screenshot may compare. */
public enum class UiStateSurface(public val wire: String) {
    NONE("none"),
    BUBBLE("bubble"),
    TOOL_ROW("tool-row"),
    THINKING_PILL("thinking-pill"),
    APPROVAL_CARD("approval-card"),
    COMPOSER("composer"),
    FAIL_LOUD_BANNER("fail-loud-banner"),
    ;

    public companion object {
        /** Returns the surface for a wire label, or `null` when unknown. */
        public fun fromWire(wire: String): UiStateSurface? = entries.firstOrNull { it.wire == wire }
    }
}

/**
 * One projected node.
 *
 * [seq] is the row ordinal: the harness `seq` for a durable event, `0` for a
 * structural node (`root`, `session`, `turn`), and the writer's own ordinal for
 * a row projected from a best-effort event (`spec/host/v1/event-kinds.md` §2).
 *
 * [parentID] names an existing node exactly one grammar level above [nodeID];
 * the root node is its own parent because the schema requires a `parentID` on
 * every node and `root` is the only grammar word above a session.
 */
public data class UiStateNode(
    public val kind: UiStateKind,
    public val nodeID: String,
    public val parentID: String,
    public val sessionID: String,
    public val turnID: String,
    public val seq: Int,
    public val surface: UiStateSurface = UiStateSurface.NONE,
    public val text: String? = null,
    public val props: JsonObject = EMPTY_PROPS,
    public val platform: String = ANDROID,
) {
    /** The canonical JSON object of this node, members sorted by code point. */
    public fun toJsonObject(): JsonObject = JsonObject(
        sortedMapOf<String, JsonValue>(
            KEY_KIND to JsonString(kind.wire),
            KEY_NODE_ID to JsonString(nodeID),
            KEY_PARENT_ID to JsonString(parentID),
            KEY_PLATFORM to JsonString(platform),
            KEY_PROPS to props,
            KEY_SCHEMA_VERSION to JsonString(SCHEMA_VERSION),
            KEY_SEQ to JsonNumber(seq.toString()),
            KEY_SESSION_ID to JsonString(sessionID),
            KEY_SURFACE to JsonString(surface.wire),
            KEY_TURN_ID to JsonString(turnID),
        ) + (text?.let { sortedMapOf<String, JsonValue>(KEY_TEXT to JsonString(it)) } ?: emptyMap()),
    )

    /** The canonical JSONL line for this node (no trailing newline). */
    public fun toCanonicalJson(): String = CanonicalJson.write(toJsonObject())

    public companion object {
        /** `ui-state/1`; the only schema version this projector writes. */
        public const val SCHEMA_VERSION: String = "ui-state/1"

        /** The platform label this projector writes. */
        public const val ANDROID: String = "android"

        public const val KEY_SCHEMA_VERSION: String = "schemaVersion"
        public const val KEY_PLATFORM: String = "platform"
        public const val KEY_SESSION_ID: String = "sessionID"
        public const val KEY_TURN_ID: String = "turnID"
        public const val KEY_SEQ: String = "seq"
        public const val KEY_NODE_ID: String = "nodeID"
        public const val KEY_PARENT_ID: String = "parentID"
        public const val KEY_KIND: String = "kind"
        public const val KEY_SURFACE: String = "surface"
        public const val KEY_TEXT: String = "text"
        public const val KEY_PROPS: String = "props"

        /** An empty `props` object. */
        public val EMPTY_PROPS: JsonObject = JsonObject(emptyMap())

        /** Builds a node from its canonical JSON object, rejecting a shape this contract does not define. */
        public fun fromJsonObject(value: JsonObject): UiStateNode {
            fun member(key: String): JsonValue = value[key]
                ?: throw UiStateProjectionException("SHAPE", "missing member '$key' in $value")

            val schemaVersion = member(KEY_SCHEMA_VERSION) as? JsonString
            if (schemaVersion?.value != SCHEMA_VERSION) {
                throw UiStateProjectionException(
                    "SHAPE",
                    "unsupported schemaVersion '${schemaVersion?.value}'; expected $SCHEMA_VERSION",
                )
            }
            val kind = (member(KEY_KIND) as? JsonString)?.let { UiStateKind.fromWire(it.value) }
                ?: throw UiStateProjectionException("SHAPE", "unknown kind in $value")
            val surface = (member(KEY_SURFACE) as? JsonString)?.let { UiStateSurface.fromWire(it.value) }
                ?: throw UiStateProjectionException("SHAPE", "unknown surface in $value")
            val seq = (member(KEY_SEQ) as? JsonNumber)?.asLongOrNull()
                ?: throw UiStateProjectionException("SHAPE", "seq is not an integer in $value")
            return UiStateNode(
                kind = kind,
                nodeID = (member(KEY_NODE_ID) as JsonString).value,
                parentID = (member(KEY_PARENT_ID) as JsonString).value,
                sessionID = (member(KEY_SESSION_ID) as JsonString).value,
                turnID = (member(KEY_TURN_ID) as JsonString).value,
                seq = seq.toInt(),
                surface = surface,
                text = (value[KEY_TEXT] as? JsonString)?.value,
                props = value[KEY_PROPS] as? JsonObject ?: EMPTY_PROPS,
                platform = (value[KEY_PLATFORM] as? JsonString)?.value ?: ANDROID,
            )
        }
    }
}

/** Renders a node sequence as canonical JSONL: one object per line, `\n` after the last line. */
public fun List<UiStateNode>.encodeCanonical(): String =
    joinToString(separator = "") { it.toCanonicalJson() + "\n" }

/** Parses canonical JSONL back into nodes; empty input is an empty sequence. */
public fun decodeCanonicalUiState(jsonl: String): List<UiStateNode> = jsonl
    .lineSequence()
    .map { it.trim() }
    .filter { it.isNotEmpty() }
    .map { line ->
        val parsed = JsonValue.parse(line)
        if (parsed !is JsonObject) throw UiStateProjectionException("SHAPE", "a node must be a JSON object")
        UiStateNode.fromJsonObject(parsed)
    }
    .toList()

/** A fail-loud projection error; the code names the invariant that broke. */
public class UiStateProjectionException(
    public val code: String,
    message: String,
) : IllegalArgumentException("$code: $message")

/**
 * The canonical JSON form of `spec/v1/trajectory.md` §6: member names sorted, no
 * insignificant whitespace, `/` unescaped, non-ASCII literal.
 *
 * Sorting is the only thing this object owns. Escaping and value formatting come
 * from `:core`'s [toJsonString], which is byte-identical to the reference writers
 * (`json.dumps(..., sort_keys=True, separators=(",", ":"), ensure_ascii=False)`
 * in `spec/v1/tools/trajectory_norm.py`): `\b`/`\f` as short escapes, every other
 * control character as `\u00XX`. A second escaper here would only be a place for
 * the Kotlin, Python and Rust forms to drift apart.
 *
 * Numbers are already canonicalised by the projector, so the writer never
 * reformats a numeric lexeme.
 */
internal object CanonicalJson {
    fun write(value: JsonValue): String = canonical(value).toJsonString()

    private fun canonical(value: JsonValue): JsonValue = when (value) {
        is JsonObject -> JsonObject(
            value.members.keys.sortedWith(CODE_POINT_ORDER)
                .associateWith { canonical(value.members.getValue(it)) },
        )

        is JsonArray -> JsonArray(value.values.map { canonical(it) })
        else -> value
    }

    /**
     * Member names sort by **Unicode code point**, not by UTF-16 code unit.
     *
     * Kotlin's natural `String` order compares UTF-16 code units, which disagrees
     * with Python's `sorted()` and Rust's `str` order (both code point, equivalent
     * to UTF-8 byte order) for exactly one case: a name starting with an astral
     * character (encoded as a surrogate, U+D800–U+DFFF) sorts *before* a name
     * starting with a BMP character in U+E000–U+FFFF under code-unit order, and
     * *after* it under code-point order. `trajectory.md` §6 says code point, so the
     * canonical bytes of a tool argument with an emoji key would otherwise differ
     * between hosts while every ASCII test stayed green.
     */
    private val CODE_POINT_ORDER: Comparator<String> = Comparator { a, b ->
        var i = 0
        var j = 0
        while (i < a.length && j < b.length) {
            val ca = a.codePointAt(i)
            val cb = b.codePointAt(j)
            if (ca != cb) return@Comparator ca.compareTo(cb)
            i += Character.charCount(ca)
            j += Character.charCount(cb)
        }
        (a.length - i).compareTo(b.length - j)
    }
}

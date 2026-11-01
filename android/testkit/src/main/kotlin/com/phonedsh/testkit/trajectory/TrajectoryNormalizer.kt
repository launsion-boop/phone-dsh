// :testkit trajectory — stages 1, 2, 3 and 5 of the normative normalization pipeline.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.trajectory

import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.TreeMap
import java.util.regex.Pattern

/** A normalization rule was violated; the input is never silently repaired. */
public class NormError(
    public val code: String,
    public val where: String,
    public val detail: String,
    cause: Throwable? = null,
) : RuntimeException("$code at $where: $detail", cause)

/** The two artifacts that share the five stages. */
public enum class RowKind(public val schemaVersion: String, public val statsName: String) {
    TRAJECTORY("trajectory/1", "trajectory"),
    UI_STATE("ui-state/1", "ui-state"),
    ;

    public companion object {
        /** The kind declared by a row's `schemaVersion`, or `null` when it is unknown. */
        public fun fromSchemaVersion(version: String?): RowKind? =
            values().firstOrNull { it.schemaVersion == version }
    }
}

/**
 * The oracle's `_Stats` counters, kept because a golden report that only says "pass" hides how
 * much of an equivalence came from replacement and how much was already canonical.
 */
public class NormalizationStats {
    public var inputLines: Int = 0
        internal set
    public var blankLines: Int = 0
        internal set
    public var outputLines: Int = 0
        internal set
    public var droppedLines: Int = 0
        internal set
    public var pathRewrites: Int = 0
        internal set
    public var requestIdRewrites: Int = 0
        internal set
    public var numberRewrites: Int = 0
        internal set
    public var window: Int = PlatformNoiseRules.WINDOW
        internal set
    public var ruleCount: Int = 0
        internal set
    public var ruleCap: Int = PlatformNoiseRules.RULE_CAP
        internal set
    public var ruleGrowthLimit: Int = PlatformNoiseRules.RULE_GROWTH_LIMIT
        internal set
    public var groups: Int = 0
        internal set
    public var kind: RowKind = RowKind.TRAJECTORY
        internal set

    internal val removedMemberCounts: TreeMap<String, Int> = TreeMap()
    internal val ruleHitCounts: TreeMap<String, Int> = TreeMap()

    public val removedMembers: Map<String, Int> get() = removedMemberCounts
    public val ruleHits: Map<String, Int> get() = ruleHitCounts

    internal fun memberRemoved(name: String) {
        removedMemberCounts[name] = (removedMemberCounts[name] ?: 0) + 1
    }

    internal fun ruleHit(ruleId: String) {
        ruleHitCounts[ruleId] = (ruleHitCounts[ruleId] ?: 0) + 1
    }

    /** The oracle's `--stats` document shape, with its two maps sorted by member name. */
    public fun export(): Map<String, Any> = linkedMapOf(
        "blankLines" to blankLines,
        "droppedLines" to droppedLines,
        "groups" to groups,
        "inputLines" to inputLines,
        "kind" to kind.statsName,
        "numberRewrites" to numberRewrites,
        "outputLines" to outputLines,
        "pathRewrites" to pathRewrites,
        "removedMembers" to removedMemberCounts.toMap(),
        "requestIdRewrites" to requestIdRewrites,
        "ruleCap" to ruleCap,
        "ruleCount" to ruleCount,
        "ruleGrowthLimit" to ruleGrowthLimit,
        "ruleHits" to ruleHitCounts.toMap(),
        "window" to window,
    )
}

/** The canonical rows and the counters of one normalization run. */
public data class NormalizationResult(
    public val kind: RowKind,
    public val lines: List<String>,
    public val stats: NormalizationStats,
)

/**
 * The Kotlin port of `normalize()` from `spec/v1/tools/trajectory_norm.py`.
 *
 * Five stages, once each, in this order: strip domain, ordering window, platform-noise
 * whitelist, numeric normalization, canonical output. The function is a pure function of
 * `(rows, rule table, platform)` apart from loading the two schemas when [schemas] is `null`.
 * It never compares two platform files and never guesses a missing event.
 */
public object TrajectoryNormalizer {
    private val STRIP_MEMBERS: Set<String> = setOf(
        "time",
        "timestamp",
        "wallClock",
        "wallMs",
        "occurredAt",
        "mono",
        "monotonic",
        "monotonicMs",
        "machAbsolute",
        "mach_absolute_time",
        "uptimeMs",
        "pid",
        "processID",
        "processId",
        "port",
        "socketPort",
        "localPort",
        "remotePort",
        "memory",
        "memoryBytes",
        "memoryMB",
        "rssBytes",
        "cpu",
        "cpuPercent",
        "cpuTimeMs",
    )
    private val DROP_TYPES: Set<String> = setOf(
        "metric/sample",
        "perf/sample",
        "debug/clock",
        "host/heartbeat",
    )
    private val REQUEST_ID_MEMBERS: Set<String> = setOf("requestId", "request_id", "reqId")
    private val PATH_MEMBERS: Set<String> = setOf("path", "cwd", "workspace", "root", "filePath", "target")
    private val PLATFORMS: Set<String> = setOf("ios", "android", "both")
    private val DSH_ROOTS: Set<String> = setOf("home", "workspace", "tmp")

    private val UUID_PATTERN = Pattern.compile(
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    )
    private val HEX_ONLY_PATTERN = Pattern.compile("[0-9a-fA-F]{8,64}")
    private val REQUEST_SUFFIX_PATTERN = Pattern.compile(
        "(?i)(?:[-_:])(?:[0-9a-f]{6,32}|[0-9]{6,20})$",
        Pattern.UNICODE_CHARACTER_CLASS,
    )

    /**
     * Normalizes JSONL lines (without their line terminators) and returns canonical lines.
     *
     * [rules] defaults to the normative table; [kind] is auto-detected from the first row's
     * `schemaVersion`; [platform] is the oracle's `--platform` override and may only be used
     * for rows that do not carry a `platform` member. [stats] receives the counters.
     */
    public fun normalize(
        lines: List<String>,
        rules: List<PlatformRule> = PlatformNoiseRules.NORMATIVE,
        kind: RowKind? = null,
        platform: String? = null,
        stats: NormalizationStats = NormalizationStats(),
        schemas: TrajectorySchemas? = null,
    ): NormalizationResult {
        val compiledRules = PlatformNoiseRules.validate(rules)
        stats.ruleCount = compiledRules.size

        val parsedRows = ArrayList<JsonTree>()
        for ((index, raw) in lines.withIndex()) {
            var line = raw
            if (index == 0 && line.startsWith("\uFEFF")) line = line.substring(1)
            line = line.trimEnd('\n')
            if (line.endsWith('\r')) line = line.dropLast(1)
            if (PythonSemantics.strip(line).isEmpty()) {
                stats.blankLines++
                continue
            }
            parsedRows += JsonTreeCodec.parseDocument(line, "line ${index + 1}")
            stats.inputLines++
        }
        if (parsedRows.isEmpty()) {
            stats.outputLines = 0
            stats.kind = kind ?: RowKind.TRAJECTORY
            return NormalizationResult(stats.kind, emptyList(), stats)
        }

        val detected = detectKind(parsedRows[0])
        if (kind != null && kind != detected) {
            throw NormError(
                "UNKNOWN_KIND",
                "input",
                "declared kind '${kind.schemaVersion}' does not match ${detected.schemaVersion}",
            )
        }
        stats.kind = detected
        val loadedSchemas = schemas ?: TrajectorySchemas.loadDefault()
        val schema = loadedSchemas.schemaFor(detected)
        for ((index, row) in parsedRows.withIndex()) {
            TrajectorySchemaValidator.validateRow(row, schema, detected, "row ${index + 1}")
        }

        val prepared = ArrayList<PreparedRow>(parsedRows.size)
        for ((index, row) in parsedRows.withIndex()) {
            val where = "row ${index + 1}"
            val tree = row as? JsonObjectTree ?: throw NormError("SCHEMA", where, "row is not an object")
            val rowPlatform = capturePlatform(tree, platform, where)
            val type = tree.string("type")
            if (detected == RowKind.TRAJECTORY && type != null && type in DROP_TYPES) {
                stats.droppedLines++
                continue
            }
            stripValue(tree, stats, where)
            prepared += PreparedRow(tree, rowPlatform)
        }

        val orderedRows: List<PreparedRow>
        if (detected == RowKind.TRAJECTORY) {
            orderedRows = orderTrajectory(prepared, stats)
            for (row in orderedRows) {
                // Stage 3 follows the platform captured from this row. Stage 2 may reorder
                // rows, so pairing platforms by prepared position would apply a neighbour's
                // platform to a mixed-platform file; trajectory.md §4 scopes a rule to the
                // row's declared platform, not to an arrival slot.
                val data = row.tree["data"] ?: JsonObjectTree(LinkedHashMap())
                applyRulesTo(data, compiledRules, row.platform, stats, "data")
                NumericNormalizer.normalizeNumbers(data, stats, "data")
            }
        } else {
            orderedRows = orderUiState(prepared, stats)
            for (row in orderedRows) {
                val text = row.tree["text"]
                if (text != null) {
                    row.tree.members["text"] = applyRulesTo(text, compiledRules, row.platform, stats, "text")
                }
                val props = row.tree["props"]
                if (props != null) {
                    applyRulesTo(props, compiledRules, row.platform, stats, "props")
                    NumericNormalizer.normalizeNumbers(props, stats, "props")
                }
            }
        }

        val output = ArrayList<String>(orderedRows.size)
        for ((index, row) in orderedRows.withIndex()) {
            output += JsonTreeCodec.canonicalLine(row.tree, "row ${index + 1}")
        }
        stats.outputLines = output.size
        stats.kind = detected
        return NormalizationResult(detected, output, stats)
    }

    /** Convenience: decode JSONL text with Python's `splitlines()` and return canonical bytes. */
    public fun normalizeJsonl(
        text: String,
        rules: List<PlatformRule> = PlatformNoiseRules.NORMATIVE,
        kind: RowKind? = null,
        platform: String? = null,
        stats: NormalizationStats = NormalizationStats(),
        schemas: TrajectorySchemas? = null,
    ): ByteArray = encodeLines(
        normalize(
            lines = PythonSemantics.splitlines(text),
            rules = rules,
            kind = kind,
            platform = platform,
            stats = stats,
            schemas = schemas,
        ).lines,
    )

    /** `encode_lines`: one `\n` after every line, zero bytes for zero lines, strict UTF-8. */
    public fun encodeLines(lines: List<String>): ByteArray {
        if (lines.isEmpty()) return ByteArray(0)
        val text = lines.joinToString("\n") + "\n"
        val encoder = Charsets.UTF_8.newEncoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            val buffer = encoder.encode(CharBuffer.wrap(text))
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            bytes
        } catch (failure: CharacterCodingException) {
            throw NormError("OUTPUT", "output", "UTF-8 encoding failed: ${failure.message}", failure)
        }
    }

    private fun detectKind(row: JsonTree): RowKind {
        val version = (row as? JsonObjectTree)?.string("schemaVersion")
        return RowKind.fromSchemaVersion(version)
            ?: throw NormError("UNKNOWN_KIND", "line 1", "unknown schemaVersion '$version'")
    }

    // ------------------------------------------------------------ stage 1: strip domain

    private fun capturePlatform(tree: JsonObjectTree, override: String?, where: String): String {
        val captured = tree.remove("platform")
        val value: String? = when (captured) {
            null, is JsonNullTree -> null
            is JsonStringTree -> captured.value
            else -> throw NormError("PLATFORM", where, "unsupported platform value")
        }
        var platform = value
        if (platform == null) {
            platform = override
        } else if (override != null && platform != override) {
            throw NormError(
                "PLATFORM_CONFLICT",
                where,
                "row platform '$platform' conflicts with override '$override'",
            )
        }
        if (platform == null) platform = "both"
        if (platform !in PLATFORMS) throw NormError("PLATFORM", where, "unsupported platform '$platform'")
        return platform
    }

    private fun stripValue(value: JsonTree, stats: NormalizationStats, where: String, key: String? = null): JsonTree {
        when (value) {
            is JsonObjectTree -> {
                for (name in value.members.keys.toList()) {
                    val childWhere = "$where.$name"
                    when {
                        name in STRIP_MEMBERS -> {
                            value.remove(name)
                            stats.memberRemoved(name)
                        }
                        name in REQUEST_ID_MEMBERS -> {
                            val original = value.members.getValue(name)
                            val normalized = normalizeRequestId(original, childWhere)
                            if (normalized == null) {
                                value.remove(name)
                            } else {
                                value.members[name] = JsonStringTree(normalized)
                            }
                            val unchanged = (original is JsonNullTree) ||
                                (original is JsonStringTree && original.value == normalized)
                            if (!unchanged) stats.requestIdRewrites++
                        }
                        name in PATH_MEMBERS && value.members[name] is JsonStringTree -> {
                            val original = (value.members.getValue(name) as JsonStringTree).value
                            val canonical = canonicalPath(original, childWhere)
                            value.members[name] = JsonStringTree(canonical)
                            if (canonical != original) stats.pathRewrites++
                        }
                        else -> value.members[name] = stripValue(value.members.getValue(name), stats, childWhere, name)
                    }
                }
            }
            is JsonArrayTree -> {
                for (index in value.items.indices) {
                    value.items[index] = stripValue(value.items[index], stats, "$where[$index]", key)
                }
            }
            is JsonStringTree -> {
                val replaced = replaceHostPrefixes(value.value)
                if (replaced != value.value) stats.pathRewrites++
                return JsonStringTree(replaced)
            }
            is JsonNumberTree, is JsonBoolTree, is JsonNullTree -> Unit
        }
        return value
    }

    private fun normalizeRequestId(value: JsonTree, where: String): String? {
        val text = (value as? JsonStringTree)?.value
            ?: throw NormError("BAD_REQUEST_ID", where, "request id is not a string")
        val stripped = PythonSemantics.strip(text)
        if (stripped.isEmpty()) return null
        // trajectory.md §2: a UUID or a bare hex run is removed. Classification runs on the
        // value before suffix reduction, otherwise a standard UUID loses its last group and
        // survives as a truncated stem.
        if (UUID_PATTERN.matcher(stripped).matches() || HEX_ONLY_PATTERN.matcher(stripped).matches()) {
            return null
        }
        val stem = REQUEST_SUFFIX_PATTERN.matcher(stripped).replaceAll("")
        if (stem.isEmpty()) return null
        return stem
    }

    private fun canonicalPath(value: String, where: String): String {
        val replaced = replaceHostPrefixes(value)
        if (replaced.isEmpty()) return replaced
        if (replaced.startsWith("/dsh/")) {
            val parts = replaced.split("/")
            if (parts.size < 3 || parts[2] !in DSH_ROOTS) {
                throw NormError("UNPORTABLE_PATH", where, "unknown /dsh root in '$replaced'")
            }
            for (part in parts.drop(3)) {
                if (part.isEmpty() || part == "." || part == ".." || part.contains('\u0000')) {
                    throw NormError("UNPORTABLE_PATH", where, "invalid segment in '$replaced'")
                }
            }
            if (PythonSemantics.codePointLength(replaced) > 512) {
                throw NormError("UNPORTABLE_PATH", where, "path is longer than 512 characters")
            }
            return replaced
        }
        if (replaced.startsWith("/")) {
            throw NormError("UNPORTABLE_PATH", where, "absolute host path cannot be normalized")
        }
        val normalized = posixNormpath(replaced)
        if (normalized == ".." || normalized.startsWith("../")) {
            throw NormError("UNPORTABLE_PATH", where, "relative path escapes its root")
        }
        return normalized
    }

    /** `posixpath.normpath` restricted to the relative paths stage 1 still accepts. */
    private fun posixNormpath(value: String): String {
        val components = ArrayList<String>()
        for (component in value.split('/')) {
            when {
                component.isEmpty() || component == "." -> Unit
                component == ".." -> {
                    if (components.isNotEmpty() && components.last() != "..") {
                        components.removeAt(components.size - 1)
                    } else {
                        components += component
                    }
                }
                else -> components += component
            }
        }
        return if (components.isEmpty()) "." else components.joinToString("/")
    }

    private fun replaceHostPrefixes(text: String): String {
        val android = PlatformNoiseRules.ANDROID_FILES_PREFIX.matcher(text).replaceAll("/dsh/\$1")
        return PlatformNoiseRules.ISO_CONTAINER_PREFIX.matcher(android).replaceAll("/dsh/\$1")
    }

    // ------------------------------------------------------- stage 3: platform whitelist

    internal fun applyRulesTo(
        value: JsonTree,
        rules: List<CompiledRule>,
        platform: String,
        stats: NormalizationStats,
        where: String,
    ): JsonTree = when (value) {
        is JsonObjectTree -> {
            for (name in value.members.keys.toList()) {
                value.members[name] = applyRulesTo(
                    value.members.getValue(name),
                    rules,
                    platform,
                    stats,
                    "$where.$name",
                )
            }
            value
        }
        is JsonArrayTree -> {
            for (index in value.items.indices) {
                value.items[index] = applyRulesTo(value.items[index], rules, platform, stats, "$where[$index]")
            }
            value
        }
        is JsonStringTree -> {
            var text = value.value
            for (rule in rules) {
                if (!rule.appliesTo(platform)) continue
                if (!rule.matches(text)) continue
                stats.ruleHit(rule.id)
                text = rule.apply(text)
            }
            if (text == value.value) value else JsonStringTree(text)
        }
        is JsonNumberTree, is JsonBoolTree, is JsonNullTree -> value
    }

    // --------------------------------------------------------- stage 2: ordering window

    private fun orderTrajectory(prepared: List<PreparedRow>, stats: NormalizationStats): List<PreparedRow> {
        val rowMeta = prepared.mapIndexed { arrival, row ->
            val session = row.tree.string("sessionID")
                ?: throw NormError("ORDER", "row ${arrival + 1}", "missing 'sessionID'")
            val turn = row.tree.string("turnID")
                ?: throw NormError("ORDER", "row ${arrival + 1}", "missing 'turnID'")
            val seq = row.tree.integer("seq")?.toLong()
                ?: throw NormError("ORDER", "row ${arrival + 1}", "missing 'seq'")
            TrajectoryRow(row, arrival, session, turn, seq)
        }
        val groups = LinkedHashMap<Pair<String, String>, MutableList<TrajectoryRow>>()
        for (row in rowMeta) {
            groups.getOrPut(row.session to row.turn) { ArrayList() } += row
        }
        val ordered = ArrayList<PreparedRow>(prepared.size)
        val keys = groups.keys.sortedWith(Comparator { left, right ->
            val bySession = PythonSemantics.compareCodePoints(left.first, right.first)
            if (bySession != 0) bySession else PythonSemantics.compareCodePoints(left.second, right.second)
        })
        for (key in keys) {
            val group = groups.getValue(key)
            val label = "${key.first}/${key.second}"
            checkWindow(group.map { it.seq }, label)
            val seqs = group.map { it.seq }
            if (seqs.toSet().size != seqs.size) {
                throw NormError("DUPLICATE_SEQ", label, "a seq appears twice")
            }
            group.sortWith(Comparator { left, right ->
                val bySeq = left.seq.compareTo(right.seq)
                if (bySeq != 0) bySeq else left.arrival.compareTo(right.arrival)
            })
            ordered += group.map { it.row }
        }
        stats.groups = groups.size
        return ordered
    }

    private class TrajectoryRow(
        val row: PreparedRow,
        val arrival: Int,
        val session: String,
        val turn: String,
        val seq: Long,
    )
}

/** One row between stage 1 and stage 3: its tree and the platform captured from it. */
internal class PreparedRow(
    val tree: JsonObjectTree,
    val platform: String,
)

/**
 * The stage-2 tolerance check shared by trajectory and UiState rows: for each row in arrival
 * order, `lateBy` is the number of already-seen rows with a strictly greater `seq`; more than
 * [PlatformNoiseRules.WINDOW] fails instead of reordering an untrustworthy stream.
 */
internal fun checkWindow(seqsInArrivalOrder: List<Long>, group: String) {
    var seen = 0
    val counts = TreeMap<Long, Int>()
    for (seq in seqsInArrivalOrder) {
        var notGreater = 0
        for (count in counts.headMap(seq, true).values) notGreater += count
        val lateBy = seen - notGreater
        if (lateBy > PlatformNoiseRules.WINDOW) {
            throw NormError(
                "OUT_OF_WINDOW",
                group,
                "seq $seq arrived after $lateBy higher seq rows (window ${PlatformNoiseRules.WINDOW})",
            )
        }
        counts[seq] = (counts[seq] ?: 0) + 1
        seen++
    }
}

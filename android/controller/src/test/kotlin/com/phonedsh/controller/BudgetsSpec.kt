// phone-dsh Android — :controller reader for the budgets.md §4 table.
// SPDX-License-Identifier: MIT
//
// The normative table is the oracle: this file parses it in place and compares
// every cell with `ControllerBudgets`. There is no second copy of the numbers.
// A structurally different table (missing heading, changed header, added or
// renamed row, unparseable cell) is an error, never a silently skipped check —
// otherwise the spec could change and the test would stay green.

package com.phonedsh.controller

import com.phonedsh.controller.ControllerBudgets.Companion.GIB
import com.phonedsh.controller.ControllerBudgets.Companion.MIB
import java.io.File
import java.math.BigDecimal

internal class BudgetsTable private constructor(
    private val header: List<String>,
    private val rows: LinkedHashMap<String, List<String>>,
    private val source: File,
    private val rowLineIndices: Map<String, Int>,
    private val headroomMiB: List<Long>,
    private val minimumSingleFileMiB: Long,
) {
    /** The five tier labels, in table order. */
    val tiers: List<String> get() = header.drop(1)

    /** The resource labels, in table order. */
    val resources: List<String> get() = rows.keys.toList()

    fun cell(resource: String, tierIndex: Int): String {
        val row = rows[resource]
            ?: throw AssertionError("$source §4 table has no '$resource' row")
        return row.getOrNull(tierIndex)
            ?: throw AssertionError(
                "$source §4 row '$resource' has no cell for tier '${tiers.getOrNull(tierIndex)}'",
            )
    }

    /** Every disagreement between the §4 table/prose and [ControllerBudgets]; empty when they agree. */
    fun mismatches(): List<String> {
        val problems = mutableListOf<String>()
        fun compare(what: String, tierIndex: Int, spec: Long, code: Long) {
            if (spec != code) {
                problems += "$what / ${tiers[tierIndex]}: spec=$spec, code=$code"
            }
        }

        val planned = cell("Planned WebContent restart", 0)
        if (!planned.contains("tool-call boundary")) {
            problems += "Planned WebContent restart: first tier no longer names the tool-call boundary ('$planned')"
        }
        for (index in 1 until tiers.size) {
            if (cell("Planned WebContent restart", index) != "same") {
                problems += "Planned WebContent restart / ${tiers[index]}: expected 'same', was '${cell("Planned WebContent restart", index)}'"
            }
        }

        val recoveryBaseMillis = recoveryBaseMillis()
        val recoveryPerMbMillis = recoveryPerMbMillis()
        for (index in 1 until tiers.size) {
            if (cell("Recovery time target", index) != "same") {
                problems += "Recovery time target / ${tiers[index]}: expected 'same', was '${cell("Recovery time target", index)}'"
            }
        }

        if (minimumSingleFileMiB * MIB != ControllerBudgets.MIN_SINGLE_FILE_BYTES) {
            problems += "single_file_limit floor: spec=$minimumSingleFileMiB MiB, " +
                "code=${ControllerBudgets.MIN_SINGLE_FILE_BYTES / MIB} MiB"
        }

        TIER_ORDER.forEachIndexed { index, tier ->
            val budgets = ControllerBudgets.forTier(tier)
            val ceiling = headerCeilingBytes(index)
            compare("nominal ceiling", index, ceiling, budgets.nominalCeilingBytes)
            compare("Engine heap", index, mib("Engine heap", index), budgets.engineHeapBytes)
            compare("VFS logical bytes", index, mib("VFS logical bytes", index), budgets.vfsLogicalBytes)
            val split = splitMiB("VFS split: workspace / sessions / tmp", index)
            compare("workspace", index, split[0], budgets.workspaceBytes)
            compare("sessions", index, split[1], budgets.sessionsBytes)
            compare("tmp", index, split[2], budgets.tmpBytes)
            compare("Single file", index, mib("Single file", index), budgets.singleFileBytes)
            compare(
                "Single file, host maximum",
                index,
                mib("Single file, host maximum", index),
                budgets.singleFileHostMaxBytes,
            )
            compare("WASI hot instance", index, mib("WASI hot instance", index), budgets.wasiHotInstanceBytes)
            compare("App process", index, mib("App process", index), budgets.appProcessBytes)
            compare(
                "headroom",
                index,
                headroomMiB.getOrNull(index)?.let { it * MIB }
                    ?: throw AssertionError("$source §4 states ${headroomMiB.size} headroom values, expected 5"),
                budgets.workspaceHeadroomBytes,
            )
            compare(
                "Peak (percent of ceiling)",
                index,
                ceiling * percent("Peak", index) / 100,
                budgets.peakBytes,
            )
            compare("Peak (printed GiB)", index, gibInParentheses("Peak", index), budgets.peakBytes)
            compare(
                "Sub-agents",
                index,
                integer("Sub-agents", index, "≤\\s*(\\d+)"),
                budgets.maxSubAgents.toLong(),
            )
            compare("Sub-agents when thermal fair", index, 1L, budgets.maxSubAgentsThermalFair.toLong())
            compare("Loopback p95", index, integer("Loopback round trip", index, "p95\\s*<\\s*(\\d+)\\s*ms"), budgets.loopbackP95Millis.toLong())
            compare("Recovery base a", index, recoveryBaseMillis, budgets.recoveryBaseMaxMillis)
            compare("Recovery k per MiB", index, recoveryPerMbMillis, budgets.recoveryMillisPerMb)
        }
        return problems
    }

    /**
     * Returns [markdown] with one §4 cell replaced.
     *
     * Only the in-memory mutation self-check uses this; the real file is read
     * once and never written.
     */
    fun replaceCell(markdown: String, resource: String, tierIndex: Int, newCell: String): String {
        val lineIndex = rowLineIndices[resource]
            ?: throw AssertionError("$source §4 table has no '$resource' row")
        val lines = markdown.lines().toMutableList()
        val cells = splitRow(lines[lineIndex]).toMutableList()
        if (cells.size != header.size) {
            throw AssertionError("$source §4 row '$resource' has ${cells.size} cells, expected ${header.size}")
        }
        cells[tierIndex + 1] = newCell
        lines[lineIndex] = renderRow(cells)
        return lines.joinToString("\n")
    }

    /** The ceiling of column [tierIndex], parsed from its header label. */
    fun headerCeilingGiB(tierIndex: Int): Long =
        integerIn("header", tiers[tierIndex], "(\\d+)\\s*GiB")

    private fun headerCeilingBytes(tierIndex: Int): Long = headerCeilingGiB(tierIndex) * GIB

    private fun mib(resource: String, tierIndex: Int): Long =
        integer(resource, tierIndex, "(\\d+)\\s*(?:MiB|MB)") * MIB

    private fun splitMiB(resource: String, tierIndex: Int): List<Long> {
        val text = cell(resource, tierIndex)
        val match = Regex("(\\d+)\\s*/\\s*(\\d+)\\s*/\\s*(\\d+)").find(text)
            ?: throw AssertionError("$source §4 '$resource' / ${tiers[tierIndex]} is not 'n / n / n': '$text'")
        return match.groupValues.drop(1).map { it.toLong() * MIB }
    }

    private fun percent(resource: String, tierIndex: Int): Long =
        integer(resource, tierIndex, "≤\\s*(\\d+)\\s*%")

    private fun gibInParentheses(resource: String, tierIndex: Int): Long {
        val text = cell(resource, tierIndex)
        val match = Regex("\\(\\s*([\\d.]+)\\s*GiB\\s*\\)").find(text)
            ?: throw AssertionError("$source §4 '$resource' / ${tiers[tierIndex]} has no '(n GiB)': '$text'")
        return BigDecimal(match.groupValues[1]).multiply(BigDecimal(GIB)).longValueExact()
    }

    private fun integer(resource: String, tierIndex: Int, pattern: String): Long =
        integerIn("$resource / ${tiers[tierIndex]}", cell(resource, tierIndex), pattern)

    private fun integerIn(what: String, text: String, pattern: String): Long {
        val match = Regex(pattern).find(text)
            ?: throw AssertionError("$source §4 $what does not match /$pattern/: '$text'")
        return match.groupValues[1].toLong()
    }

    private fun recoveryBaseMillis(): Long =
        integerIn("Recovery time target", cell("Recovery time target", 0), "a\\s*≤\\s*(\\d+)\\s*s") * 1_000L

    private fun recoveryPerMbMillis(): Long {
        val text = cell("Recovery time target", 0)
        val match = Regex("k\\s*≤\\s*([\\d.]+)\\s*s/MB").find(text)
            ?: throw AssertionError("$source §4 'Recovery time target' has no 'k ≤ n s/MB': '$text'")
        return BigDecimal(match.groupValues[1]).multiply(BigDecimal(1_000)).longValueExact()
    }

    companion object {
        const val SECTION_HEADING: String = "## 4. Budgets"

        /** The exact §4 header; a different table must fail loudly. */
        val EXPECTED_HEADER: List<String> =
            listOf("Resource", "12 GiB", "8 GiB (default)", "6 GiB", "4 GiB", "≤ 3 GiB")

        /** The exact §4 resource rows; a row added or renamed must fail loudly. */
        val EXPECTED_RESOURCES: List<String> = listOf(
            "Engine heap",
            "VFS logical bytes",
            "VFS split: workspace / sessions / tmp",
            "Single file",
            "Single file, host maximum",
            "WASI hot instance",
            "App process",
            "Peak",
            "Sub-agents",
            "Loopback round trip",
            "Planned WebContent restart",
            "Recovery time target",
        )

        private val TIER_ORDER: List<MemoryTier> = listOf(
            MemoryTier.GIB_12,
            MemoryTier.GIB_8,
            MemoryTier.GIB_6,
            MemoryTier.GIB_4,
            MemoryTier.AT_MOST_3,
        )

        fun parse(markdown: String, source: File): BudgetsTable {
            val lines = markdown.lines()
            val heading = lines.indexOfFirst { it.trim() == SECTION_HEADING }
            if (heading < 0) {
                throw AssertionError(
                    "$source has no '$SECTION_HEADING' heading; the §4 cross-check cannot run",
                )
            }
            val sectionEnd = lines.withIndex()
                .drop(heading + 1)
                .firstOrNull { it.value.startsWith("## ") }
                ?.index
                ?: lines.size

            val headerIndex = (heading + 1 until sectionEnd)
                .firstOrNull { lines[it].trimStart().startsWith("|") }
                ?: throw AssertionError("$source §4 has no markdown table")
            val header = splitRow(lines[headerIndex])
            if (header != EXPECTED_HEADER) {
                throw AssertionError(
                    "$source §4 header changed: was $header, expected $EXPECTED_HEADER. " +
                        "Update BudgetsTable before trusting this check.",
                )
            }

            val separator = splitRow(lines[headerIndex + 1])
            if (separator.size != header.size || separator.any { !SEPARATOR.matches(it) }) {
                throw AssertionError(
                    "$source §4 line ${headerIndex + 2} is not the table separator: '${
                        lines[headerIndex + 1]
                    }'",
                )
            }

            val rows = LinkedHashMap<String, List<String>>()
            val rowLines = LinkedHashMap<String, Int>()
            var index = headerIndex + 2
            while (index < sectionEnd && lines[index].trimStart().startsWith("|")) {
                val cells = splitRow(lines[index])
                if (cells.size != header.size) {
                    throw AssertionError(
                        "$source §4 row ${index + 1} has ${cells.size} cells, expected ${header.size}: " +
                            lines[index],
                    )
                }
                val label = cells.first()
                if (label.isEmpty()) {
                    throw AssertionError("$source §4 row ${index + 1} has an empty resource label")
                }
                if (rows.put(label, cells.drop(1)) != null) {
                    throw AssertionError("$source §4 has a duplicate '$label' row")
                }
                rowLines[label] = index
                index++
            }
            if (rows.keys.toList() != EXPECTED_RESOURCES) {
                val added = rows.keys - EXPECTED_RESOURCES.toSet()
                val missing = EXPECTED_RESOURCES - rows.keys
                throw AssertionError(
                    "$source §4 rows changed (added=$added, missing=$missing); " +
                        "extend BudgetsTable and ControllerBudgets before this check can pass.",
                )
            }

            val sectionText = lines.subList(heading, sectionEnd).joinToString("\n")
            val headroomMatch = HEADROOM.find(sectionText)
                ?: throw AssertionError(
                    "$source §4 no longer states the five headroom values " +
                        "('… MiB of headroom for the five rows'); the cross-check cannot run",
                )
            val headroomMiB = headroomMatch.groupValues[1]
                .split("/")
                .map { it.trim().toLong() }
            if (headroomMiB.size != header.size - 1) {
                throw AssertionError(
                    "$source §4 lists ${headroomMiB.size} headroom values for ${header.size - 1} tiers",
                )
            }
            val floorMatch = SINGLE_FILE_FLOOR.find(sectionText)
                ?: throw AssertionError(
                    "$source §4 no longer states the 'single_file_limit in 16 MiB ...' floor",
                )

            return BudgetsTable(
                header = header,
                rows = rows,
                source = source,
                rowLineIndices = rowLines,
                headroomMiB = headroomMiB,
                minimumSingleFileMiB = floorMatch.groupValues[1].toLong(),
            )
        }

        private val SEPARATOR = Regex(":?-{3,}:?")
        private val HEADROOM = Regex("with\\s+(\\d+(?:\\s*/\\s*\\d+){4})\\s*MiB\\s+of\\s+headroom")
        private val SINGLE_FILE_FLOOR = Regex("`single_file_limit`\\s+in\\s+(\\d+)\\s*MiB")

        private fun splitRow(line: String): List<String> {
            val trimmed = line.trim()
            if (!trimmed.startsWith("|") || !trimmed.endsWith("|")) {
                throw AssertionError("not a markdown table row: '$line'")
            }
            return trimmed.substring(1, trimmed.length - 1)
                .split("|")
                .map { it.trim() }
        }

        private fun renderRow(cells: List<String>): String =
            cells.joinToString(separator = " | ", prefix = "| ", postfix = " |")
    }
}

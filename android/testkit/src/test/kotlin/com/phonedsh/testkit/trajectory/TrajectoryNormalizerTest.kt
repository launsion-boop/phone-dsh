// phone-dsh — :testkit trajectory: determinism, ordering window, stage 1/4 and whitelist scope.
// SPDX-License-Identifier: MIT
//
// The golden cases prove the whole pipeline against the checked-in bytes; these tests prove
// the properties the lane is allowed to rely on when the fixtures are not enough:
// normalization is a pure deterministic function, a shuffle inside the W=16 window cannot
// change a byte, and a rule declared for one platform never fires for the other.

package com.phonedsh.testkit.trajectory

import java.util.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TrajectoryNormalizerTest {

    @Test
    fun `normalizing the same input twice produces identical bytes`() {
        for (case in listOf("reorder-window", "tool-exec-noise", "permission-flow", "chat-basic")) {
            val text = TrajectoryTestSupport.readUtf8(
                TrajectoryTestSupport.goldenDirectory(case).resolve("android.jsonl"),
            )
            val first = TrajectoryNormalizer.normalizeJsonl(text)
            val second = TrajectoryNormalizer.normalizeJsonl(text)
            assertArrayEquals("$case is not deterministic", first, second)
            assertArrayEquals("$case does not match the golden bytes", TrajectoryTestSupport.goldenBytes(case, "expected.jsonl"), first)
        }
    }

    @Test
    fun `normalized output is a fixed point of normalization`() {
        for (case in listOf("chat-basic", "permission-flow", "reorder-window", "tool-exec-noise", "turn-error-vs-complete")) {
            val expected = TrajectoryTestSupport.goldenBytes(case, "expected.jsonl")
            assertEquals(
                "$case expected file is not canonical",
                expected.toList(),
                TrajectoryNormalizer.normalizeJsonl(String(expected, Charsets.UTF_8)).toList(),
            )
            val android = TrajectoryTestSupport.goldenDirectory(case).resolve("android.expected.jsonl")
            if (java.nio.file.Files.isRegularFile(android)) {
                val androidExpected = java.nio.file.Files.readAllBytes(android)
                assertEquals(
                    "$case android expected file is not canonical",
                    androidExpected.toList(),
                    TrajectoryNormalizer.normalizeJsonl(String(androidExpected, Charsets.UTF_8)).toList(),
                )
            }
        }
    }

    @Test
    fun `shuffling rows inside the ordering window cannot change one byte`() {
        val case = "reorder-window"
        val lines = TrajectoryTestSupport.goldenLines(case, "android.jsonl")
        val expected = TrajectoryTestSupport.goldenBytes(case, "expected.jsonl")
        assertEquals(7, lines.size)
        val permutations = ArrayList<List<String>>()
        permutations += lines.reversed()
        for (rotation in 1 until lines.size) {
            permutations += lines.drop(rotation) + lines.take(rotation)
        }
        val random = Random(20261031L)
        repeat(100) {
            permutations += lines.shuffled(random)
        }
        for ((index, permutation) in permutations.withIndex()) {
            val text = permutation.joinToString("\n") + "\n"
            assertArrayEquals(
                "permutation $index changed the normalized bytes",
                expected,
                TrajectoryNormalizer.normalizeJsonl(text),
            )
        }
    }

    @Test
    fun `a whitelist rule only fires for its declared platform`() {
        val rules = listOf(
            PlatformRule(
                id = "android-only",
                platforms = listOf("android"),
                pattern = "\\bsecret\\b",
                replacement = "<android>",
                reason = "test fixture: android declares this token",
            ),
            PlatformRule(
                id = "both-common",
                platforms = listOf("both"),
                pattern = "\\bcommon\\b",
                replacement = "<common>",
                reason = "test fixture: both declares this token",
            ),
            PlatformRule(
                id = "ios-only",
                platforms = listOf("ios"),
                pattern = "\\bsecret\\b",
                replacement = "<ios>",
                reason = "test fixture: ios declares this token",
            ),
        )
        val androidStats = NormalizationStats()
        val android = TrajectoryNormalizer.normalize(
            lines = listOf(TrajectoryTestSupport.trajectoryRow(platform = "android", text = "secret common")),
            rules = rules,
            stats = androidStats,
        ).lines.single()
        assertTrue(android, android.contains("\"text\":\"<android> <common>\""))
        assertFalse("an ios-only rule fired for an android row", android.contains("<ios>"))
        assertFalse("the ios rule was counted for android", androidStats.ruleHits.containsKey("ios-only"))
        assertEquals(setOf("android-only", "both-common"), androidStats.ruleHits.keys)

        val iosStats = NormalizationStats()
        val ios = TrajectoryNormalizer.normalize(
            lines = listOf(TrajectoryTestSupport.trajectoryRow(platform = "ios", text = "secret common")),
            rules = rules,
            stats = iosStats,
        ).lines.single()
        assertTrue(ios, ios.contains("\"text\":\"<ios> <common>\""))
        assertFalse("an android-only rule fired for an ios row", ios.contains("<android>"))
        assertFalse("the android rule was counted for ios", iosStats.ruleHits.containsKey("android-only"))
        assertEquals(setOf("both-common", "ios-only"), iosStats.ruleHits.keys)

        // Reordering must not change the platform each row is judged under: every row here is
        // Android, so an ios-only rule must never fire on any of them.
        val orderedStats = NormalizationStats()
        val orderedLines = TrajectoryNormalizer.normalize(
            lines = listOf(
                TrajectoryTestSupport.trajectoryRow(platform = "android", seq = 2, text = "secret"),
                TrajectoryTestSupport.trajectoryRow(platform = "android", seq = 1, text = "secret"),
            ),
            rules = rules,
            stats = orderedStats,
        ).lines
        assertEquals(2, orderedLines.size)
        assertTrue(orderedLines[0], orderedLines[0].contains("\"seq\":1"))
        assertTrue(orderedLines.all { it.contains("\"text\":\"<android>\"") })
        assertFalse("an ios-only rule fired on an android group", orderedStats.ruleHits.containsKey("ios-only"))
    }

    @Test
    fun `a whitelist rule follows the row's own platform after reordering`() {
        // Permanent byte fixture for the per-row platform association. Stage 2 may reorder
        // rows, but stage 3 must keep each row's captured platform; pairing platforms by
        // prepared position would apply the Android rule to the iOS row (and vice versa) in
        // this mixed-platform group. trajectory.md §4 scopes a rule to the row's platform.
        // The expected lines are the fixed Python oracle's output for these two rows.
        val androidRowArrivingSecond = TrajectoryTestSupport.trajectoryRow(
            platform = "android",
            sessionID = "sess-105",
            seq = 2,
            text = "thread=main mach_absolute_time=7",
        )
        val iosRowArrivingFirst = TrajectoryTestSupport.trajectoryRow(
            platform = "ios",
            sessionID = "sess-105",
            seq = 1,
            text = "thread=RenderThread mach_absolute_time=7",
        )
        val lines = TrajectoryNormalizer.normalize(
            listOf(androidRowArrivingSecond, iosRowArrivingFirst),
        ).lines
        assertEquals(
            listOf(
                "{\"data\":{\"text\":\"thread=RenderThread mach_absolute_time=<removed>\"}," +
                    "\"schemaVersion\":\"trajectory/1\",\"seq\":1,\"sessionID\":\"sess-105\"," +
                    "\"turnID\":\"turn-0001\",\"type\":\"assistant/message\"}",
                "{\"data\":{\"text\":\"thread=<worker> mach_absolute_time=7\"}," +
                    "\"schemaVersion\":\"trajectory/1\",\"seq\":2,\"sessionID\":\"sess-105\"," +
                    "\"turnID\":\"turn-0001\",\"type\":\"assistant/message\"}",
            ),
            lines,
        )
    }

    @Test
    fun `stage one strips clocks pids ports and reduces a request id to its stem`() {
        val row = "{\"schemaVersion\":\"trajectory/1\",\"sessionID\":\"sess-001\",\"turnID\":\"turn-0001\"," +
            "\"seq\":1,\"type\":\"assistant/message\",\"time\":1761800000000,\"pid\":42,\"port\":5000," +
            "\"requestId\":\"req-42-abcdef12\",\"data\":{\"path\":\"/data/user/0/dev.dsh.probe/files/workspace/a.txt\"," +
            "\"text\":\"hello\"}}"
        val line = TrajectoryNormalizer.normalize(listOf(row)).lines.single()
        assertEquals(
            "{\"data\":{\"path\":\"/dsh/workspace/a.txt\",\"text\":\"hello\"},\"requestId\":\"req-42\"," +
                "\"schemaVersion\":\"trajectory/1\",\"seq\":1,\"sessionID\":\"sess-001\"," +
                "\"turnID\":\"turn-0001\",\"type\":\"assistant/message\"}",
            line,
        )
    }

    @Test
    fun `a uuid or bare hex request id is removed before suffix reduction`() {
        // trajectory.md §2: a UUID is removed. The UUID/hex classification runs on the value
        // before the trailing [-_:]<hex|digits> group is removed; otherwise a standard UUID
        // would lose its last group first and survive as a truncated stem.
        val uuidRow = "{\"schemaVersion\":\"trajectory/1\",\"sessionID\":\"sess-001\",\"turnID\":\"turn-0001\"," +
            "\"seq\":1,\"type\":\"assistant/message\",\"requestId\":\"123e4567-e89b-12d3-a456-426614174000\"," +
            "\"data\":{\"text\":\"uuid\"}}"
        val hexRow = "{\"schemaVersion\":\"trajectory/1\",\"sessionID\":\"sess-001\",\"turnID\":\"turn-0001\"," +
            "\"seq\":2,\"type\":\"assistant/message\",\"requestId\":\"deadbeefcafe\",\"data\":{\"text\":\"hex\"}}"
        val stemRow = "{\"schemaVersion\":\"trajectory/1\",\"sessionID\":\"sess-001\",\"turnID\":\"turn-0001\"," +
            "\"seq\":3,\"type\":\"assistant/message\",\"requestId\":\"req-0007-3f2a9c\",\"data\":{\"text\":\"stem\"}}"
        val lines = TrajectoryNormalizer.normalize(listOf(uuidRow, hexRow, stemRow)).lines
        assertEquals(3, lines.size)
        assertFalse(lines[0], lines[0].contains("requestId"))
        assertFalse(lines[1], lines[1].contains("requestId"))
        assertTrue(lines[2], lines[2].contains("\"requestId\":\"req-0007\""))
    }

    @Test
    fun `phase four normalizes durations byte counts ratios and generic floats`() {
        val row = TrajectoryTestSupport.trajectoryRow(
            extraData = "\"durationMs\":13.9,\"bytes\":\"1.5 KiB\",\"percent\":50.0414," +
                "\"ratio\":2.5,\"score\":0.1234561",
        )
        val line = TrajectoryNormalizer.normalize(listOf(row)).lines.single()
        assertTrue(
            line,
            line.contains("\"data\":{\"bytes\":1536,\"durationMs\":10,\"percent\":50.041,\"ratio\":2.5,\"score\":0.123456}"),
        )
    }

    @Test
    fun `a duplicate seq in one group fails`() {
        val lines = listOf(
            TrajectoryTestSupport.trajectoryRow(seq = 1, text = "first"),
            TrajectoryTestSupport.trajectoryRow(seq = 1, text = "second"),
        )
        val failure = assertThrows(NormError::class.java) { TrajectoryNormalizer.normalize(lines) }
        assertEquals("DUPLICATE_SEQ", failure.code)
    }

    @Test
    fun `more than sixteen late rows fail instead of being reordered`() {
        val lines = (18 downTo 1).map { seq ->
            TrajectoryTestSupport.trajectoryRow(seq = seq, text = "row $seq")
        }
        val failure = assertThrows(NormError::class.java) { TrajectoryNormalizer.normalize(lines) }
        assertEquals("OUT_OF_WINDOW", failure.code)
    }

    @Test
    fun `empty input produces zero bytes and no rows`() {
        val result = TrajectoryNormalizer.normalize(emptyList())
        assertTrue(result.lines.isEmpty())
        assertEquals(0, TrajectoryNormalizer.encodeLines(result.lines).size)
        assertEquals(RowKind.TRAJECTORY, result.kind)
    }
}

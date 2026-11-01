// phone-dsh — :testkit trajectory: one JUnit case per spec/v1 golden trajectory case.
// SPDX-License-Identifier: MIT
//
// The assertions are the oracle's `--check-golden` assertions, made per case:
// normalize(ios) == normalize(android) == expected bytes for the four equivalence cases; for
// `turn-error-vs-complete`, ios and android normalize to different bytes and neither may be
// equal to the other platform's expected file. A case that stops distinguishing the two
// platforms fails here, not in a human review.

package com.phonedsh.testkit.trajectory

import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TrajectoryGoldenTest {
    private val report: GoldenReport by lazy { TrajectoryGolden.check(TrajectoryTestSupport.repoRoot) }

    @Test
    fun `chat-basic normalizes ios and android to the same expected bytes`() {
        assertEquivalent("chat-basic")
    }

    @Test
    fun `permission-flow normalizes ios and android to the same expected bytes`() {
        assertEquivalent("permission-flow")
    }

    @Test
    fun `reorder-window normalizes ios and android to the same expected bytes`() {
        assertEquivalent("reorder-window")
    }

    @Test
    fun `tool-exec-noise normalizes ios and android to the same expected bytes`() {
        assertEquivalent("tool-exec-noise")
    }

    @Test
    fun `turn-error-vs-complete preserves the real difference`() {
        val case = requireNotNull(report.case("turn-error-vs-complete")) {
            "trajectory golden case turn-error-vs-complete is missing"
        }
        assertTrue("golden case failed: ${case.detail}", case.passed)
        assertEquals(GoldenCaseKind.REAL_DIFFERENCE, case.kind)

        // The whole point of the case: the platforms did not observe the same semantic outcome.
        assertNotEquals(
            "real difference was washed away: ios and android normalized identically",
            case.iosLines,
            case.androidLines,
        )
        val iosBytes = TrajectoryNormalizer.encodeLines(case.iosLines)
        val androidBytes = TrajectoryNormalizer.encodeLines(case.androidLines)
        assertFalse("real difference was washed away at the byte level", iosBytes.contentEquals(androidBytes))

        // Each platform matched its own expected file, and those files differ.
        val expectedIos = TrajectoryTestSupport.goldenBytes("turn-error-vs-complete", "expected.jsonl")
        val expectedAndroid = TrajectoryTestSupport.goldenBytes("turn-error-vs-complete", "android.expected.jsonl")
        assertArrayEquals(expectedIos, iosBytes)
        assertArrayEquals(expectedAndroid, androidBytes)
        assertFalse("the two expected files must differ", expectedIos.contentEquals(expectedAndroid))
    }

    @Test
    fun `all five golden cases pass`() {
        assertTrue(report.messages.joinToString("\n"), report.ok)
        assertEquals("golden case count", 5, report.total)
        assertEquals(5, report.passed)
        assertEquals(
            listOf(
                "chat-basic",
                "permission-flow",
                "reorder-window",
                "tool-exec-noise",
                "turn-error-vs-complete",
            ),
            report.cases.map { it.name },
        )
        assertEquals(9, report.rules)
        assertEquals(12, report.ruleCap)
        assertEquals(16, report.window)
    }

    private fun assertEquivalent(name: String) {
        val case = requireNotNull(report.case(name)) { "trajectory golden case $name is missing" }
        assertTrue("golden case $name failed: ${case.detail}", case.passed)
        assertEquals(GoldenCaseKind.EQUIVALENT, case.kind)
        assertNotNull(case.detail)

        // Stage 5 asserts bytes, not shapes: compare the exact checked-in files.
        val expected = TrajectoryTestSupport.goldenBytes(name, "expected.jsonl")
        assertArrayEquals("$name ios bytes", expected, TrajectoryNormalizer.encodeLines(case.iosLines))
        assertArrayEquals("$name android bytes", expected, TrajectoryNormalizer.encodeLines(case.androidLines))
        assertEquals("$name ios normalized lines", case.expectedIosLines, case.iosLines)
        assertEquals("$name android normalized lines", case.expectedAndroidLines, case.androidLines)
        assertEquals("$name platforms must agree", case.iosLines, case.androidLines)

        // The case directory must keep the three input files it declares.
        val directory = TrajectoryTestSupport.goldenDirectory(name)
        assertTrue(Files.isRegularFile(directory.resolve("ios.jsonl")))
        assertTrue(Files.isRegularFile(directory.resolve("android.jsonl")))
        assertTrue(Files.isRegularFile(directory.resolve("notes.json")))
    }
}

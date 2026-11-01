// phone-dsh — :testkit trajectory: opt-in differential check against the Python oracle.
// SPDX-License-Identifier: MIT
//
// The only honest way to claim "byte-identical to spec/v1/tools/trajectory_norm.py" is to run
// both implementations over the same inputs and compare the whole output byte sequence. The
// oracle needs python3, which is not a build dependency, so this test is skipped unless
// PDSH_TRAJECTORY_PARITY_DIR points at a corpus directory.
//
// Corpus layout (the directory is outside the repository; no fixture and no absolute machine
// path is committed by this test):
//
//   <corpus>/<case>.input.jsonl      input rows, one JSON object per line
//   <corpus>/<case>.expected.jsonl   the oracle's output for that exact input, produced by
//
//       python3 spec/v1/tools/trajectory_norm.py --root . \
//           --input <corpus>/<case>.input.jsonl \
//           --output <corpus>/<case>.expected.jsonl
//
// Regenerate every expected file after changing the input (never hand-write expected bytes):
//
//   for f in <corpus>/*.input.jsonl; do
//       python3 spec/v1/tools/trajectory_norm.py --root . \
//           --input "$f" --output "${f%.input.jsonl}.expected.jsonl"
//   done
//
// Then run only this test against the corpus:
//
//   cd android
//   PDSH_TRAJECTORY_PARITY_DIR=<corpus> ./gradlew :testkit:testDebugUnitTest --rerun
//
// The corpus committed to review should at least cover: a mixed-platform group whose arrival
// order is reverted by stage 2 (the per-row platform association), standard UUID / hex-only /
// suffixed request ids, a raw number-lexeme case, a float/decimal grid, and a UiState sequence.
// `TrajectoryNormalizerTest`/`UiStateNormalizerTest` carry the permanent, python-free guards for
// the same two rules; this test is the wider differential net.

package com.phonedsh.testkit.trajectory

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class TrajectoryPythonParityTest {
    @Test
    fun `kotlin normalization matches the python oracle byte for byte`() {
        val directory = System.getenv("PDSH_TRAJECTORY_PARITY_DIR")
        assumeTrue(
            "PDSH_TRAJECTORY_PARITY_DIR is not set; the Python oracle differential was skipped",
            directory != null,
        )
        val root = Paths.get(requireNotNull(directory))
        assertTrue("parity directory $root does not exist", Files.isDirectory(root))
        val inputs = collectInputs(root)
        assertTrue("no *.input.jsonl cases in $root", inputs.isNotEmpty())

        for (input in inputs) {
            val name = input.fileName.toString().removeSuffix(".input.jsonl")
            val expectedPath = root.resolve("$name.expected.jsonl")
            assertTrue("missing oracle output $expectedPath", Files.isRegularFile(expectedPath))
            val actual = TrajectoryNormalizer.normalizeJsonl(
                String(Files.readAllBytes(input), Charsets.UTF_8),
            )
            assertArrayEquals(
                "$name: Kotlin and python3 trajectory_norm.py disagree",
                Files.readAllBytes(expectedPath),
                actual,
            )
        }
        assertTrue("parity corpus must contain at least five cases", inputs.size >= 5)
    }

    private fun collectInputs(root: Path): List<Path> {
        val inputs = ArrayList<Path>()
        Files.newDirectoryStream(root, "*.input.jsonl").use { stream ->
            for (path in stream) inputs.add(path)
        }
        inputs.sortWith(Comparator { left, right -> left.fileName.toString().compareTo(right.fileName.toString()) })
        return inputs
    }
}

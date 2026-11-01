// :testkit trajectory — the `--check-golden` equivalent for the five spec/v1 golden cases.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.trajectory

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path

/** `notes.json.kind`: an equivalence case or a declared real semantic difference. */
public enum class GoldenCaseKind(public val notesName: String) {
    EQUIVALENT("equivalent"),
    REAL_DIFFERENCE("real-difference"),
}

/** One golden case, including the bytes it normalized to so a test can assert them itself. */
public data class GoldenCaseReport(
    public val name: String,
    public val kind: GoldenCaseKind?,
    public val passed: Boolean,
    public val detail: String,
    public val iosLines: List<String>,
    public val androidLines: List<String>,
    public val expectedIosLines: List<String>,
    public val expectedAndroidLines: List<String>,
)

/** The result of [TrajectoryGolden.check]; `ok` is the pass/fail gate. */
public data class GoldenReport(
    public val repoRoot: Path,
    public val cases: List<GoldenCaseReport>,
    public val messages: List<String>,
    public val rules: Int,
    public val ruleCap: Int,
    public val window: Int,
) {
    public val passed: Int get() = cases.count { it.passed }
    public val total: Int get() = cases.size
    public val ok: Boolean get() = cases.isNotEmpty() && cases.all { it.passed }

    public fun case(name: String): GoldenCaseReport? = cases.firstOrNull { it.name == name }
}

/**
 * The Kotlin equivalent of
 * `python3 spec/v1/tools/trajectory_norm.py --check-golden --root <repoRoot>`.
 *
 * It asserts, per case, exactly what `check_golden` asserts:
 *
 * * every input row and every expected row validates against `trajectory.schema.json`;
 * * each input normalizes identically twice (determinism self-check);
 * * each expected file is already canonical;
 * * `normalize(ios) == normalize(android) == expected` bytes for `equivalent` cases;
 * * `normalize(ios) == expected` and `normalize(android) == android.expected` bytes, and the
 *   two differ, for the `real-difference` case — a semantic difference is never washed away.
 *
 * The fixtures are read from `<repoRoot>/spec/v1/golden/trajectory`; no absolute path is
 * embedded and the spec tree is never written.
 */
public object TrajectoryGolden {
    public fun check(repoRoot: Path): GoldenReport {
        val base = repoRoot.toAbsolutePath().normalize()
        val golden = base.resolve("spec/v1/golden/trajectory")
        if (!Files.isDirectory(golden)) {
            return report(base, emptyList(), listOf("GOLDEN $golden: directory is missing"))
        }
        val caseDirectories = try {
            listCaseDirectories(golden)
        } catch (failure: IOException) {
            return report(base, emptyList(), listOf("GOLDEN $golden: ${failure.message}"))
        }
        if (caseDirectories.isEmpty()) {
            return report(base, emptyList(), listOf("GOLDEN $golden: no cases"))
        }
        val schemas = try {
            TrajectorySchemas.load(base)
        } catch (failure: NormError) {
            return report(base, emptyList(), listOf("GOLDEN schema: ${failure.message}"))
        }

        val cases = ArrayList<GoldenCaseReport>()
        val messages = ArrayList<String>()
        for (caseDirectory in caseDirectories) {
            val name = caseDirectory.fileName.toString()
            try {
                cases += checkCase(caseDirectory, name, schemas, messages)
            } catch (failure: NormError) {
                val detail = "FAIL golden/trajectory/$name: ${failure.message}"
                cases += GoldenCaseReport(
                    name = name,
                    kind = null,
                    passed = false,
                    detail = detail,
                    iosLines = emptyList(),
                    androidLines = emptyList(),
                    expectedIosLines = emptyList(),
                    expectedAndroidLines = emptyList(),
                )
                messages += detail
            }
        }
        messages += "SUMMARY ${cases.count { it.passed }}/${caseDirectories.size} cases passed; " +
            "rules=${PlatformNoiseRules.NORMATIVE.size}/${PlatformNoiseRules.RULE_CAP}; " +
            "window=${PlatformNoiseRules.WINDOW}"
        return GoldenReport(
            repoRoot = base,
            cases = cases,
            messages = messages,
            rules = PlatformNoiseRules.NORMATIVE.size,
            ruleCap = PlatformNoiseRules.RULE_CAP,
            window = PlatformNoiseRules.WINDOW,
        )
    }

    private fun report(repoRoot: Path, cases: List<GoldenCaseReport>, messages: List<String>): GoldenReport =
        GoldenReport(
            repoRoot = repoRoot,
            cases = cases,
            messages = messages,
            rules = PlatformNoiseRules.NORMATIVE.size,
            ruleCap = PlatformNoiseRules.RULE_CAP,
            window = PlatformNoiseRules.WINDOW,
        )

    private fun checkCase(
        caseDirectory: Path,
        name: String,
        schemas: TrajectorySchemas,
        messages: MutableList<String>,
    ): GoldenCaseReport {
        val notesPath = caseDirectory.resolve("notes.json")
        val notes = loadNotes(notesPath)
        val iosLines = readCaseLines(caseDirectory, "ios")
        val androidLines = readCaseLines(caseDirectory, "android")

        val iosOnce = normalize(iosLines, schemas, NormalizationStats())
        val androidOnce = normalize(androidLines, schemas, NormalizationStats())
        val iosTwice = normalize(iosLines, schemas, NormalizationStats())
        val androidTwice = normalize(androidLines, schemas, NormalizationStats())
        if (iosOnce != iosTwice || androidOnce != androidTwice) {
            throw NormError("DETERMINISM", name, "two runs differ")
        }

        val expectedIosPath = caseDirectory.resolve(notes.iosFile)
        val expectedAndroidPath = caseDirectory.resolve(notes.androidFile)
        val expectedIosLines = PythonSemantics.splitlines(readText(expectedIosPath))
        val expectedAndroidLines = PythonSemantics.splitlines(readText(expectedAndroidPath))

        // The expected files must themselves be canonical and schema-valid.
        if (normalize(expectedIosLines, schemas, NormalizationStats()) != expectedIosLines) {
            throw NormError("GOLDEN", name, "ios expected file is not canonical")
        }
        if (normalize(expectedAndroidLines, schemas, NormalizationStats()) != expectedAndroidLines) {
            throw NormError("GOLDEN", name, "android expected file is not canonical")
        }

        val iosBytes = TrajectoryNormalizer.encodeLines(iosOnce)
        val androidBytes = TrajectoryNormalizer.encodeLines(androidOnce)
        val expectedIosBytes = readBytes(expectedIosPath)
        val expectedAndroidBytes = readBytes(expectedAndroidPath)
        if (!iosBytes.contentEquals(expectedIosBytes)) {
            throw NormError("GOLDEN", name, "normalize(ios) != ios expected bytes")
        }
        if (!androidBytes.contentEquals(expectedAndroidBytes)) {
            throw NormError("GOLDEN", name, "normalize(android) != android expected bytes")
        }

        val detail = if (notes.kind == GoldenCaseKind.EQUIVALENT) {
            if (!iosBytes.contentEquals(androidBytes)) {
                throw NormError("GOLDEN", name, "equivalent case normalized differently")
            }
            "equivalent shared expected=${expectedIosLines.size}"
        } else {
            if (iosBytes.contentEquals(androidBytes)) {
                throw NormError("GOLDEN", name, "real difference was washed away by normalization")
            }
            "real-difference preserved ios=${expectedIosLines.size} android=${expectedAndroidLines.size}"
        }
        messages += "PASS golden/trajectory/$name: $detail " +
            "(input ios=${iosLines.size} android=${androidLines.size})"
        return GoldenCaseReport(
            name = name,
            kind = notes.kind,
            passed = true,
            detail = detail,
            iosLines = iosOnce,
            androidLines = androidOnce,
            expectedIosLines = expectedIosLines,
            expectedAndroidLines = expectedAndroidLines,
        )
    }

    private fun normalize(
        lines: List<String>,
        schemas: TrajectorySchemas,
        stats: NormalizationStats,
    ): List<String> = TrajectoryNormalizer.normalize(
        lines = lines,
        rules = PlatformNoiseRules.NORMATIVE,
        kind = RowKind.TRAJECTORY,
        stats = stats,
        schemas = schemas,
    ).lines

    private class Notes(
        val kind: GoldenCaseKind,
        val iosFile: String,
        val androidFile: String,
    )

    private fun loadNotes(path: Path): Notes {
        val root = try {
            JsonTreeCodec.parseDocument(readText(path), path.toString())
        } catch (failure: NormError) {
            throw NormError("GOLDEN", path.toString(), failure.detail, failure)
        }
        val objectRoot = root as? JsonObjectTree
            ?: throw NormError("GOLDEN", path.toString(), "notes.json is not an object")
        val kindName = objectRoot.string("kind")
        val kind = when (kindName) {
            "equivalent" -> GoldenCaseKind.EQUIVALENT
            "real-difference" -> GoldenCaseKind.REAL_DIFFERENCE
            else -> throw NormError("GOLDEN", path.toString(), "kind must be equivalent or real-difference")
        }
        val expected = objectRoot["expected"] as? JsonObjectTree
            ?: throw NormError("GOLDEN", path.toString(), "expected must map ios and android")
        if (expected.members.keys != setOf("ios", "android")) {
            throw NormError("GOLDEN", path.toString(), "expected must map ios and android")
        }
        val iosFile = expected.string("ios")
            ?: throw NormError("GOLDEN", path.toString(), "bad expected file for ios")
        val androidFile = expected.string("android")
            ?: throw NormError("GOLDEN", path.toString(), "bad expected file for android")
        for ((platform, file) in listOf("ios" to iosFile, "android" to androidFile)) {
            if (file.isEmpty() || file.contains('/') || !file.endsWith(".jsonl")) {
                throw NormError("GOLDEN", path.toString(), "bad expected file for $platform")
            }
        }
        if (kind == GoldenCaseKind.EQUIVALENT) {
            if (iosFile != androidFile) {
                throw NormError("GOLDEN", path.toString(), "equivalent case must use one expected file")
            }
        } else {
            if (iosFile == androidFile) {
                throw NormError("GOLDEN", path.toString(), "real difference must use two expected files")
            }
            val difference = objectRoot["semanticDifference"] as? JsonArrayTree
            if (difference == null || difference.items.isEmpty()) {
                throw NormError("GOLDEN", path.toString(), "real difference must name the semantic difference")
            }
            val whyNotNoise = objectRoot.string("whyNotNoise")
            if (whyNotNoise == null || PythonSemantics.strip(whyNotNoise).isEmpty()) {
                throw NormError("GOLDEN", path.toString(), "real difference must explain whyNotNoise")
            }
        }
        return Notes(kind, iosFile, androidFile)
    }

    private fun readCaseLines(caseDirectory: Path, platform: String): List<String> =
        PythonSemantics.splitlines(readText(caseDirectory.resolve("$platform.jsonl")))

    private fun readText(path: Path): String = try {
        String(Files.readAllBytes(path), Charsets.UTF_8)
    } catch (failure: IOException) {
        throw NormError("IO", path.toString(), failure.message ?: "cannot read", failure)
    }

    private fun readBytes(path: Path): ByteArray = try {
        Files.readAllBytes(path)
    } catch (failure: IOException) {
        throw NormError("IO", path.toString(), failure.message ?: "cannot read", failure)
    }

    private fun listCaseDirectories(golden: Path): List<Path> {
        val directories = ArrayList<Path>()
        Files.newDirectoryStream(golden).use { stream ->
            for (path in stream) {
                if (Files.isDirectory(path)) directories.add(path)
            }
        }
        directories.sortWith(Comparator { left, right ->
            PythonSemantics.compareCodePoints(left.fileName.toString(), right.fileName.toString())
        })
        return directories
    }
}

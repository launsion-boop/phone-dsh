// phone-dsh — :testkit trajectory tests: repository root, JSON row builders, golden readers.
// SPDX-License-Identifier: MIT
//
// The fixtures are the checked-in `spec/v1/golden/trajectory` cases. Their location comes from
// the `pdsh.repo.root` system property that :testkit/build.gradle.kts derives from the Gradle
// project root, exactly as the F10 scenario tests do; no test carries a machine-local path and
// no test guesses the working directory.

package com.phonedsh.testkit.trajectory

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

internal object TrajectoryTestSupport {
    val repoRoot: Path = Paths.get(
        System.getProperty("pdsh.repo.root")
            ?: throw IllegalStateException(
                "pdsh.repo.root is not set; :testkit/build.gradle.kts must provide it",
            ),
    )

    fun goldenDirectory(case: String): Path =
        repoRoot.resolve("spec/v1/golden/trajectory").resolve(case)

    fun readUtf8(path: Path): String = String(Files.readAllBytes(path), Charsets.UTF_8)

    fun goldenLines(case: String, file: String): List<String> =
        PythonSemantics.splitlines(readUtf8(goldenDirectory(case).resolve(file)))

    fun goldenBytes(case: String, file: String): ByteArray =
        Files.readAllBytes(goldenDirectory(case).resolve(file))

    /** A JSON string literal; the tests build rows from text without a serializer dependency. */
    fun quote(value: String): String = buildString {
        append('"')
        for (char in value) {
            when (char) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (char < ' ') {
                    append("\\u")
                    append(char.code.toString(16).padStart(4, '0'))
                } else {
                    append(char)
                }
            }
        }
        append('"')
    }

    fun trajectoryRow(
        platform: String? = null,
        sessionID: String = "sess-001",
        turnID: String = "turn-0001",
        seq: Int = 1,
        type: String = "assistant/message",
        text: String? = null,
        extraData: String? = null,
    ): String = buildString {
        append("{\"schemaVersion\":\"trajectory/1\",\"sessionID\":")
        append(quote(sessionID))
        append(",\"turnID\":")
        append(quote(turnID))
        append(",\"seq\":")
        append(seq)
        append(",\"type\":")
        append(quote(type))
        if (platform != null) {
            append(",\"platform\":")
            append(quote(platform))
        }
        append(",\"data\":{")
        var first = true
        if (text != null) {
            append("\"text\":")
            append(quote(text))
            first = false
        }
        if (extraData != null) {
            if (!first) append(',')
            append(extraData)
        }
        append("}}")
    }

    fun uiStateRow(
        platform: String? = null,
        sessionID: String = "sess-001",
        turnID: String = "turn-0001",
        seq: Int = 0,
        nodeID: String,
        parentID: String,
        kind: String,
        surface: String = "none",
        text: String? = null,
        props: String = "{}",
    ): String = buildString {
        append("{\"schemaVersion\":\"ui-state/1\",\"sessionID\":")
        append(quote(sessionID))
        append(",\"turnID\":")
        append(quote(turnID))
        append(",\"seq\":")
        append(seq)
        append(",\"nodeID\":")
        append(quote(nodeID))
        append(",\"parentID\":")
        append(quote(parentID))
        append(",\"kind\":")
        append(quote(kind))
        append(",\"surface\":")
        append(quote(surface))
        if (platform != null) {
            append(",\"platform\":")
            append(quote(platform))
        }
        if (text != null) {
            append(",\"text\":")
            append(quote(text))
        }
        append(",\"props\":")
        append(props)
        append('}')
    }
}

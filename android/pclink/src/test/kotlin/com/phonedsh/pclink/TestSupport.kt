// SPDX-License-Identifier: MIT
// Shared test support: repository root, the shared golden documents read from
// disk, and deterministic test identities. No vector value is copied into Kotlin.
package com.phonedsh.pclink

import java.nio.file.Files
import java.nio.file.Path

object TestSupport {
    val repoRoot: Path = System.getProperty("pdsh.repo.root")?.let(Path::of)
        ?: generateSequence(Path.of("").toAbsolutePath()) { it.parent }
            .first { Files.isDirectory(it.resolve("spec/pclink/v1/golden")) }

    fun data(relativePath: String): ByteArray =
        Files.readAllBytes(repoRoot.resolve(relativePath))

    fun json(relativePath: String): PclinkJson =
        PclinkJsonParser.parseDocumentObject(data(relativePath))

    fun vectors(): PclinkJson = json("spec/pclink/v1/golden/pclink-v1-vectors.json")

    fun schemaSamples(): PclinkJson = json("spec/pclink/v1/golden/schema-samples.json")

    fun endpointsDocument(): PclinkJson = json("spec/pclink/v1/endpoints.json")

    fun hex(value: String?): ByteArray =
        PclinkHex.decode(value ?: throw AssertionError("missing hex value"))

    fun seed(label: String): ByteArray = PclinkCrypto.sha256(label.toByteArray(Charsets.UTF_8))

    fun identity(label: String): PclinkIdentity = PclinkIdentity(seed(label))

    /** Navigates an object path; `null` when any member is absent. */
    fun at(value: PclinkJson?, vararg path: String): PclinkJson? {
        var current = value
        for (key in path) current = current?.get(key)
        return current
    }

    fun string(value: PclinkJson?, vararg path: String): String? = at(value, *path)?.stringValue

    fun long(value: PclinkJson?, vararg path: String): Long? = at(value, *path)?.longValue

    fun boolean(value: PclinkJson?, vararg path: String): Boolean? = at(value, *path)?.boolValue

    fun array(value: PclinkJson?, vararg path: String): List<PclinkJson>? =
        at(value, *path)?.arrayValue

    fun objects(value: PclinkJson?, vararg path: String): List<PclinkJson> =
        array(value, *path) ?: emptyList()

    fun b64(value: PclinkJson?, vararg path: String): ByteArray? =
        string(value, *path)?.let { PclinkBase64Url.decode(it) }

    fun requireString(value: PclinkJson?, vararg path: String): String =
        string(value, *path) ?: throw AssertionError("missing ${path.joinToString(".")}")

    fun requireInt(value: PclinkJson?, vararg path: String): Long =
        long(value, *path) ?: throw AssertionError("missing ${path.joinToString(".")}")

    fun requireBool(value: PclinkJson?, vararg path: String): Boolean =
        boolean(value, *path) ?: throw AssertionError("missing ${path.joinToString(".")}")
}

/** Asserts that [block] throws a [PclinkError] with the exact §9.1 [code]. */
fun assertPclinkCode(code: String, message: String? = null, block: () -> Unit): PclinkError {
    val label = if (message == null) "" else "$message: "
    val error = try {
        block()
        throw AssertionError("${label}expected PclinkError($code) but nothing was thrown")
    } catch (error: PclinkError) {
        error
    }
    if (error.code != code) {
        throw AssertionError("${label}expected PclinkError($code), got ${error.code}: ${error.message}")
    }
    return error
}

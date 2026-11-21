// Test-only reader for the three WAL golden vectors and a minimal JSON tree.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

import java.io.File
import org.junit.Assert.assertEquals

/**
 * The subset of JSON the WAL goldens and the bridge output use: objects,
 * arrays, strings, non-negative integers, booleans and `null`.
 *
 * The codec itself never runs this parser — `pdsh-wal` owns JSON — so this is a
 * test-side mirror only, deliberately independent of the Rust reader.
 */
sealed interface WalJson {
    data class Obj(val members: Map<String, WalJson>) : WalJson

    data class Arr(val items: List<WalJson>) : WalJson

    data class Str(val value: String) : WalJson

    data class Num(val value: Long) : WalJson

    data class Bool(val value: Boolean) : WalJson

    data object Null : WalJson
}

internal fun WalJson.objectMembers(): Map<String, WalJson> =
    (this as? WalJson.Obj)?.members ?: error("not a JSON object: $this")

internal fun WalJson.arrayItems(): List<WalJson> =
    (this as? WalJson.Arr)?.items ?: error("not a JSON array: $this")

internal fun WalJson.stringValue(): String =
    (this as? WalJson.Str)?.value ?: error("not a JSON string: $this")

internal fun WalJson.numberValue(): Long =
    (this as? WalJson.Num)?.value ?: error("not a JSON integer: $this")

internal fun WalJson.booleanValue(): Boolean =
    (this as? WalJson.Bool)?.value ?: error("not a JSON boolean: $this")

internal fun WalJson.member(name: String): WalJson =
    objectMembers()[name] ?: error("object has no member $name: $this")

/** One golden WAL vector from `spec/v1/golden/wal/`. */
class WalGoldenVector(
    val name: String,
    val document: WalJson,
    val fileHex: String,
) {
    val header: Map<String, WalJson> = document.member("header").objectMembers()

    val firstMseq: Long = header.getValue("first_mseq").numberValue()

    val headerHex: String = header.getValue("header_hex").stringValue()

    val records: List<WalJson> = document.member("records").arrayItems()

    override fun toString(): String = name
}

/**
 * The fixed three-vector WAL corpus.
 *
 * The file list is pinned so a removed, renamed or extra vector fails instead
 * of silently shrinking the suite; the golden directory is read from the
 * `pdsh.repo.root` system property Gradle injects.
 */
internal object WalGoldenCorpus {
    val NAMES: List<String> = listOf(
        "segment-1.json",
        "segment-blob-write.json",
        "segment-epoch-only.json",
    )

    fun load(): List<WalGoldenVector> {
        val directory = File(repoRoot(), "spec/v1/golden/wal")
        check(directory.isDirectory) { "missing golden directory: ${directory.path}" }
        val onDisk = directory
            .listFiles { file -> file.isFile && file.name.endsWith(".json") }
            ?.map { it.name }
            ?.sorted()
            ?: error("cannot list ${directory.path}")
        assertEquals("golden WAL file set", NAMES, onDisk)
        return NAMES.map { name ->
            val document = WalJsonParser.parse(File(directory, name).readText())
            val fileHex = document.member("file_hex").stringValue()
            WalGoldenVector(name, document, fileHex)
        }
    }

    private fun repoRoot(): File = File(
        System.getProperty("pdsh.repo.root")
            ?: error("pdsh.repo.root is not set; run the WAL suite through Gradle"),
    )
}

/** Recursive-descent reader for [WalJson]; throws [IllegalStateException]. */
internal object WalJsonParser {
    fun parse(text: String): WalJson = Parser(text).parseDocument()

    private class Parser(private val text: String) {
        private var index: Int = 0

        fun parseDocument(): WalJson {
            val value = parseValue()
            skipWhitespace()
            check(index == text.length) { "trailing JSON text at $index" }
            return value
        }

        private fun parseValue(): WalJson {
            skipWhitespace()
            check(index < text.length) { "missing JSON value" }
            return when (text[index]) {
                '{' -> parseObject()
                '[' -> parseArray()
                '"' -> WalJson.Str(parseString())
                't' -> literal("true", WalJson.Bool(true))
                'f' -> literal("false", WalJson.Bool(false))
                'n' -> literal("null", WalJson.Null)
                else -> parseNumber()
            }
        }

        private fun parseObject(): WalJson.Obj {
            index++ // '{'
            val members = LinkedHashMap<String, WalJson>()
            skipWhitespace()
            if (index < text.length && text[index] == '}') {
                index++
                return WalJson.Obj(members)
            }
            while (true) {
                skipWhitespace()
                val key = parseString()
                skipWhitespace()
                check(index < text.length && text[index] == ':') { "expected ':' at $index" }
                index++
                check(members.put(key, parseValue()) == null) { "duplicate JSON member $key" }
                skipWhitespace()
                check(index < text.length) { "unterminated JSON object" }
                when (text[index]) {
                    ',' -> index++
                    '}' -> {
                        index++
                        return WalJson.Obj(members)
                    }
                    else -> error("unexpected ${text[index]} at $index")
                }
            }
        }

        private fun parseArray(): WalJson.Arr {
            index++ // '['
            val items = ArrayList<WalJson>()
            skipWhitespace()
            if (index < text.length && text[index] == ']') {
                index++
                return WalJson.Arr(items)
            }
            while (true) {
                items.add(parseValue())
                skipWhitespace()
                check(index < text.length) { "unterminated JSON array" }
                when (text[index]) {
                    ',' -> index++
                    ']' -> {
                        index++
                        return WalJson.Arr(items)
                    }
                    else -> error("unexpected ${text[index]} at $index")
                }
            }
        }

        private fun parseString(): String {
            check(index < text.length && text[index] == '"') { "expected a JSON string at $index" }
            index++
            val out = StringBuilder()
            while (index < text.length) {
                when (val char = text[index++]) {
                    '"' -> return out.toString()
                    '\\' -> {
                        check(index < text.length) { "unterminated JSON escape" }
                        when (val escape = text[index++]) {
                            '"' -> out.append('"')
                            '\\' -> out.append('\\')
                            '/' -> out.append('/')
                            'b' -> out.append('\b')
                            'f' -> out.append('\u000C')
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                check(index + 4 <= text.length) { "short \\u escape" }
                                out.append(text.substring(index, index + 4).toInt(16).toChar())
                                index += 4
                            }
                            else -> error("unsupported JSON escape \\$escape")
                        }
                    }
                    else -> out.append(char)
                }
            }
            error("unterminated JSON string")
        }

        private fun parseNumber(): WalJson.Num {
            val start = index
            if (index < text.length && text[index] == '-') {
                index++
            }
            while (index < text.length && text[index].isDigit()) {
                index++
            }
            check(index > start) { "expected a JSON integer at $start" }
            return WalJson.Num(text.substring(start, index).toLong())
        }

        private fun literal(word: String, value: WalJson): WalJson {
            check(text.startsWith(word, index)) { "expected $word at $index" }
            index += word.length
            return value
        }

        private fun skipWhitespace() {
            while (index < text.length && text[index].isWhitespace()) {
                index++
            }
        }
    }
}

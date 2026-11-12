// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import java.text.Normalizer
import java.util.Locale

internal data class BotMemoryTokenAnalysis(
    val counts: LinkedHashMap<String, Double> = LinkedHashMap(),
    val order: MutableList<String> = ArrayList(),
) {
    fun add(term: String, weight: Double = 1.0) {
        if (!counts.containsKey(term)) order += term
        counts[term] = (counts[term] ?: 0.0) + weight
    }

    fun setQueryTerm(term: String, weight: Double) {
        if (!counts.containsKey(term)) order += term
        counts[term] = weight
    }
}

internal data class BotMemoryQueryAnalysis(
    val normalizedQuery: String,
    val tokens: BotMemoryTokenAnalysis,
    val cjkCharacters: Int,
    val latinWords: Int,
)

/**
 * BM25 tokenizer (v2 §1.2): NFKC + lowercase, ASCII latin/digit words with
 * `- _ '` extenders, and CJK unigrams/bigrams/trigrams. Mirrors the Swift
 * reference; only the normalized form decides token boundaries.
 */
internal object BotMemoryTokenizer {
    private enum class RunKind { CJK, LATIN }

    private data class Run(val kind: RunKind, val text: String)

    fun normalize(value: String): String =
        Normalizer.normalize(value, Normalizer.Form.NFKC).lowercase(Locale.ROOT)

    private fun isCjk(codePoint: Int): Boolean =
        codePoint in 0x3400..0x4DBF ||
            codePoint in 0x4E00..0x9FFF ||
            codePoint in 0xF900..0xFAFF ||
            codePoint in 0x3040..0x30FF ||
            codePoint in 0xAC00..0xD7AF

    private fun isLatinOrDigit(codePoint: Int): Boolean =
        codePoint in 'a'.code..'z'.code || codePoint in '0'.code..'9'.code

    private fun isLatinExtender(codePoint: Int): Boolean =
        codePoint == '-'.code || codePoint == '_'.code || codePoint == '\''.code

    private fun runs(value: String): List<Run> {
        val result = ArrayList<Run>()
        var currentKind: RunKind? = null
        val current = StringBuilder()
        fun flush() {
            if (currentKind != null && current.isNotEmpty()) {
                result += Run(currentKind!!, current.toString())
            }
            currentKind = null
            current.setLength(0)
        }
        val normalized = normalize(value)
        var index = 0
        while (index < normalized.length) {
            val cp = normalized.codePointAt(index)
            index += Character.charCount(cp)
            val kind = when {
                isCjk(cp) -> RunKind.CJK
                isLatinOrDigit(cp) -> RunKind.LATIN
                else -> null
            }
            if (kind == null) {
                if (currentKind == RunKind.LATIN && isLatinExtender(cp)) {
                    current.appendCodePoint(cp)
                } else {
                    flush()
                }
                continue
            }
            if (currentKind != kind) {
                flush()
                currentKind = kind
            }
            current.appendCodePoint(cp)
        }
        flush()
        return result
    }

    fun analyzeText(value: String): BotMemoryTokenAnalysis {
        val analysis = BotMemoryTokenAnalysis()
        for (run in runs(value)) {
            when (run.kind) {
                RunKind.LATIN -> {
                    analysis.add("w:${run.text}")
                    if (run.text.any { it == '-' || it == '_' || it == '\'' }) {
                        for (part in run.text.split('-', '_', '\'')) {
                            if (part.isNotEmpty()) analysis.add("w:$part")
                        }
                    }
                }
                RunKind.CJK -> {
                    val characters = ArrayList<String>()
                    var index = 0
                    while (index < run.text.length) {
                        val cp = run.text.codePointAt(index)
                        characters += String(Character.toChars(cp))
                        index += Character.charCount(cp)
                    }
                    for (character in characters) analysis.add("u:$character")
                    if (characters.size >= 2) {
                        for (i in 0..characters.size - 2) {
                            analysis.add("b:${characters[i]}${characters[i + 1]}")
                        }
                    }
                    if (characters.size >= 3) {
                        for (i in 0..characters.size - 3) {
                            analysis.add(
                                "t:${characters[i]}${characters[i + 1]}${characters[i + 2]}",
                            )
                        }
                    }
                }
            }
        }
        return analysis
    }

    fun analyzeQuery(value: String): BotMemoryQueryAnalysis {
        val normalizedQuery = BotMemoryText.trimWhitespace(normalize(value))
        val analysis = BotMemoryTokenAnalysis()
        var cjkCharacters = 0
        var latinWords = 0
        for (run in runs(value)) {
            when (run.kind) {
                RunKind.LATIN -> {
                    latinWords += 1
                    analysis.setQueryTerm("w:${run.text}", 1.0)
                }
                RunKind.CJK -> {
                    val characters = ArrayList<String>()
                    var index = 0
                    while (index < run.text.length) {
                        val cp = run.text.codePointAt(index)
                        characters += String(Character.toChars(cp))
                        index += Character.charCount(cp)
                    }
                    cjkCharacters += characters.size
                    when {
                        characters.size == 1 -> analysis.setQueryTerm("u:${characters[0]}", 1.0)
                        characters.size == 2 ->
                            analysis.setQueryTerm("b:${characters[0]}${characters[1]}", 1.0)
                        else -> {
                            for (i in 0..characters.size - 2) {
                                analysis.setQueryTerm(
                                    "b:${characters[i]}${characters[i + 1]}", 1.0,
                                )
                            }
                            for (i in 0..characters.size - 3) {
                                analysis.setQueryTerm(
                                    "t:${characters[i]}${characters[i + 1]}${characters[i + 2]}",
                                    1.3,
                                )
                            }
                        }
                    }
                }
            }
        }
        return BotMemoryQueryAnalysis(normalizedQuery, analysis, cjkCharacters, latinWords)
    }
}

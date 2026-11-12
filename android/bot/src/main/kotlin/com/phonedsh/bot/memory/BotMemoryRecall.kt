// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJsonException
import java.text.Normalizer
import java.util.Locale
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.pow

/** One `RecallMemory` document hit (`memory-recall.schema.json`). */
public data class BotMemoryRecallHit(
    public val path: String,
    public val scope: BotMemoryScope,
    public val snippet: String,
    public val score: Double,
    public val relevance: Double,
    public val recency: Double,
    public val matched: Boolean,
    public val updatedAtMs: Long,
    public val version: Int,
    public val evidence: List<String> = emptyList(),
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["path"] = JsonString(path)
        members["scope"] = JsonString(scope.wire)
        members["snippet"] = JsonString(snippet)
        members["score"] = JsonNumber(score.toString())
        members["relevance"] = JsonNumber(relevance.toString())
        members["recency"] = JsonNumber(recency.toString())
        members["matched"] = JsonBool(matched)
        members["updated_at_ms"] = JsonNumber(updatedAtMs.toString())
        members["version"] = JsonNumber(version.toString())
        members["evidence"] = JsonArray(evidence.map(::JsonString))
        return JsonObject(members)
    }

    public companion object {
        private val allowedKeys = setOf(
            "path", "scope", "snippet", "score", "relevance", "recency", "matched",
            "updated_at_ms", "version", "evidence",
        )

        public fun fromJson(value: JsonValue?): BotMemoryRecallHit {
            val members = BotMemoryJson.objectMembers(value, "recallHit")
            BotMemoryJson.rejectUnknown(members, "recallHit", allowedKeys)
            val path = BotMemoryJson.string(members["path"], "recallHit.path")
            if (BotMemoryText.scalarCount(path) !in 3..200) {
                throw BotJsonException("recallHit.path has an invalid length")
            }
            val scope = BotMemoryScope.parse(BotMemoryJson.string(members["scope"], "recallHit.scope"))
                ?: throw BotJsonException("recallHit.scope must be agent or user")
            val snippet = BotMemoryJson.string(members["snippet"], "recallHit.snippet")
            if (snippet.isEmpty() || BotMemoryText.scalarCount(snippet) > 500) {
                throw BotJsonException("recallHit.snippet must be 1..500 scalars")
            }
            fun unit(name: String): Double {
                val number = (members[name] as? JsonNumber)?.raw?.toDoubleOrNull()
                    ?: throw BotJsonException("recallHit.$name must be a number")
                if (number < 0.0 || number > 1.0) {
                    throw BotJsonException("recallHit.$name must be within 0..1")
                }
                return number
            }
            val version = BotMemoryJson.integer(members["version"], "recallHit.version")
            if (version < 1) throw BotJsonException("recallHit.version must be at least 1")
            val updated = BotMemoryJson.integer64(members["updated_at_ms"], "recallHit.updated_at_ms")
            if (updated < 0) throw BotJsonException("recallHit.updated_at_ms must not be negative")
            val evidence = BotMemoryJson.evidenceArray(members["evidence"], "recallHit.evidence")
            evidence.forEach(BotMemoryEvidence::validateStoredReference)
            return BotMemoryRecallHit(
                path = path,
                scope = scope,
                snippet = snippet,
                score = unit("score"),
                relevance = unit("relevance"),
                recency = unit("recency"),
                matched = BotMemoryJson.optionalBoolean(members["matched"], "recallHit.matched") ?: false,
                updatedAtMs = updated,
                version = version,
                evidence = evidence,
            )
        }
    }
}

public data class BotMemoryRecallPage(
    public val hits: List<BotMemoryRecallHit>,
    public val total: Int,
) {
    public val truncated: Boolean get() = hits.size < total
}

/**
 * BM25 + CJK tokenization over live document bodies. `importance` is gone;
 * `score = 0.85 * relevance + 0.15 * recency` with a 180-day recency half
 * life. The two root `INDEX.md` documents never enter this index.
 */
public class BotMemoryDocumentRecallIndex(initialDocuments: List<BotMemoryDocument> = emptyList()) {
    private data class IndexedDocument(
        val path: String,
        val scope: BotMemoryScope,
        val content: String,
        val normalizedContent: String,
        val tokens: BotMemoryTokenAnalysis,
        val length: Double,
        val updatedAtMs: Long,
        val version: Int,
        var evidence: List<String>,
    )

    private data class QueryTerm(val key: String, val weight: Double, val idf: Double)

    private data class Candidate(val document: IndexedDocument, var bm25: Double = 0.0)

    private val documents = LinkedHashMap<String, IndexedDocument>()
    private val documentOrder = ArrayList<String>()
    private val postings = LinkedHashMap<String, LinkedHashMap<String, Double>>()
    private val termOrder = ArrayList<String>()
    private var totalLength = 0.0

    init {
        sync(initialDocuments)
    }

    public val count: Int get() = documents.size

    public fun sync(values: List<BotMemoryDocument>) {
        val live = values.map { it.path }.toHashSet()
        for (path in ArrayList(documentOrder)) {
            if (path !in live) remove(path)
        }
        for (value in values) {
            val existing = documents[value.path]
            if (existing != null &&
                existing.content == value.content &&
                existing.version == value.version &&
                existing.updatedAtMs == value.updatedAtMs
            ) {
                existing.evidence = value.evidence
                continue
            }
            add(value)
        }
    }

    public fun add(value: BotMemoryDocument): Boolean {
        if (value.path.isEmpty()) return false
        if (documents.containsKey(value.path)) remove(value.path)
        val tokens = BotMemoryTokenizer.analyzeText(value.content)
        val length = tokens.counts.values.sum()
        val document = IndexedDocument(
            path = value.path,
            scope = value.scope,
            content = value.content,
            normalizedContent = BotMemoryTokenizer.normalize(value.content),
            tokens = tokens,
            length = length,
            updatedAtMs = value.updatedAtMs,
            version = value.version,
            evidence = value.evidence,
        )
        documents[value.path] = document
        documentOrder += value.path
        totalLength += length
        for (term in tokens.order) {
            if (!postings.containsKey(term)) termOrder += term
            postings.getOrPut(term) { LinkedHashMap() }[value.path] = tokens.counts[term] ?: 0.0
        }
        return true
    }

    public fun remove(path: String): Boolean {
        val document = documents.remove(path) ?: return false
        for (term in document.tokens.order) {
            val posting = postings[term] ?: continue
            posting.remove(path)
            if (posting.isEmpty()) postings.remove(term)
        }
        documentOrder.removeAll { it == path }
        totalLength -= document.length
        return true
    }

    public fun search(
        query: String = "",
        limit: Int = 40,
        now: Long? = null,
        includeScope: BotMemoryScope? = null,
    ): List<BotMemoryRecallHit> =
        searchPage(query, limit = limit, now = now, includeScope = includeScope).hits

    public fun searchPage(
        query: String = "",
        limit: Int = 40,
        now: Long? = null,
        includeScope: BotMemoryScope? = null,
    ): BotMemoryRecallPage {
        val totalDocuments = documents.size
        if (totalDocuments == 0) return BotMemoryRecallPage(emptyList(), 0)
        val nowMs = now ?: System.currentTimeMillis()
        val analysis = BotMemoryTokenizer.analyzeQuery(query)
        val blank = analysis.normalizedQuery.isEmpty()
        val queryTerms = ArrayList<QueryTerm>()
        val seen = HashSet<String>()

        fun idf(df: Int): Double =
            ln(1.0 + (totalDocuments - df + 0.5) / (df + 0.5))

        fun addQueryTerm(key: String, weight: Double) {
            if (seen.contains(key) || queryTerms.size >= 512) return
            val posting = postings[key]
            if (posting == null || posting.isEmpty()) return
            seen += key
            queryTerms += QueryTerm(key, weight, idf(posting.size))
        }

        fun prefixTerms(key: String): List<Pair<String, Double>> {
            val colon = key.indexOf(':')
            val type = if (colon >= 0) key.substring(0, colon) else ""
            val payload = if (colon >= 0) key.substring(colon + 1) else key
            val output = ArrayList<Pair<String, Double>>()
            if (type == "w" && BotMemoryText.utf16Count(payload) <= 2) {
                for (term in termOrder) {
                    if (!term.startsWith(key)) continue
                    val posting = postings[term] ?: continue
                    output += term to idf(posting.size)
                    if (output.size >= MAXIMUM_PREFIX_TERMS) break
                }
                return output
            }
            if (type == "u") {
                for (prefix in listOf("b:$payload", "t:$payload")) {
                    for (term in termOrder) {
                        if (!term.startsWith(prefix)) continue
                        val posting = postings[term] ?: continue
                        output += term to idf(posting.size)
                        if (output.size >= MAXIMUM_PREFIX_TERMS) return output
                    }
                }
            }
            return output
        }

        for (key in analysis.tokens.order) {
            val weight = analysis.tokens.counts[key] ?: 1.0
            if (key.startsWith("w:") && BotMemoryText.utf16Count(key.substring(2)) <= 2) {
                addQueryTerm(key, weight)
                for ((expanded, _) in prefixTerms(key)) addQueryTerm(expanded, weight * 0.7)
            } else if (postings.containsKey(key)) {
                addQueryTerm(key, weight)
            } else {
                for ((expanded, _) in prefixTerms(key)) addQueryTerm(expanded, weight * 0.7)
            }
        }
        if (!blank && queryTerms.isEmpty()) return BotMemoryRecallPage(emptyList(), 0)

        val averageLength = totalLength / totalDocuments.toDouble()
        val average = if (averageLength == 0.0) 1.0 else averageLength
        val candidates = LinkedHashMap<String, Candidate>()
        for (queryTerm in queryTerms) {
            val posting = postings[queryTerm.key] ?: continue
            for ((path, termFrequency) in posting) {
                val document = documents[path] ?: continue
                val candidate = candidates.getOrPut(path) { Candidate(document) }
                val denominator = termFrequency +
                    BM25_K1 * (1 - BM25_B + BM25_B * (document.length / average))
                candidate.bm25 += queryTerm.weight * queryTerm.idf *
                    ((termFrequency * (BM25_K1 + 1)) / denominator)
            }
        }

        val ranked = ArrayList<BotMemoryRecallHit>()
        fun consider(document: IndexedDocument, candidate: Candidate) {
            if (includeScope != null && document.scope != includeScope) return
            val exact = !blank &&
                document.normalizedContent.contains(analysis.normalizedQuery)
            if (!blank && !exact && candidate.bm25 <= 0.0) return
            val rawRelevance = if (candidate.bm25 > 0.0) {
                candidate.bm25 / (candidate.bm25 + BM25_SATURATION)
            } else {
                0.0
            }
            val relevance = if (exact) max(0.95, rawRelevance) else rawRelevance
            val recency = if (document.updatedAtMs > 0) {
                0.5.pow(
                    maxOf(0L, nowMs - document.updatedAtMs).toDouble() /
                        DAY_MS / RECENCY_HALF_LIFE_DAYS,
                )
            } else {
                0.0
            }
            val score = RELEVANCE_WEIGHT * relevance + RECENCY_WEIGHT * recency
            ranked += BotMemoryRecallHit(
                path = document.path,
                scope = document.scope,
                snippet = snippet(
                    document.content, query, analysis.normalizedQuery,
                ),
                score = round(score),
                relevance = round(relevance),
                recency = round(recency),
                matched = if (blank) false else (candidate.bm25 > 0.0 || exact),
                updatedAtMs = document.updatedAtMs,
                version = document.version,
                evidence = document.evidence,
            )
        }

        if (blank) {
            for (path in documentOrder) {
                val document = documents[path] ?: continue
                consider(document, Candidate(document))
            }
        } else {
            for (path in documentOrder) {
                val candidate = candidates[path] ?: continue
                consider(candidate.document, candidate)
            }
        }
        ranked.sortWith(
            compareByDescending<BotMemoryRecallHit> { it.score }
                .thenByDescending { it.updatedAtMs }
                .thenBy { it.path },
        )
        val maximum = max(0, limit)
        return BotMemoryRecallPage(ranked.take(maximum), ranked.size)
    }

    public companion object {
        public val RELEVANCE_WEIGHT: Double = 0.85
        public val RECENCY_WEIGHT: Double = 0.15
        public val RECENCY_HALF_LIFE_DAYS: Double = 180.0
        public const val MAXIMUM_SNIPPET_SCALARS: Int = 500
        private const val BM25_K1 = 1.2
        private const val BM25_B = 0.75
        private const val BM25_SATURATION = 3.0
        private const val MAXIMUM_PREFIX_TERMS = 64
        private const val DAY_MS = 24.0 * 60.0 * 60.0 * 1_000.0

        private fun round(value: Double): Double =
            if (value.isFinite()) Math.round(value * 1_000_000.0) / 1_000_000.0 else 0.0

        private fun splitWhitespace(value: String): List<String> {
            val pieces = ArrayList<String>()
            val current = StringBuilder()
            var index = 0
            while (index < value.length) {
                val cp = value.codePointAt(index)
                index += Character.charCount(cp)
                if (BotMemoryText.isWhitespace(cp)) {
                    if (current.isNotEmpty()) {
                        pieces += current.toString()
                        current.setLength(0)
                    }
                } else {
                    current.appendCodePoint(cp)
                }
            }
            if (current.isNotEmpty()) pieces += current.toString()
            return pieces
        }

        private fun diacriticInsensitiveIndex(haystack: String, piece: String): Int? {
            fun fold(value: String): String {
                val decomposed = Normalizer.normalize(value, Normalizer.Form.NFD)
                val out = StringBuilder(decomposed.length)
                var index = 0
                while (index < decomposed.length) {
                    val cp = decomposed.codePointAt(index)
                    index += Character.charCount(cp)
                    val type = Character.getType(cp)
                    if (type == Character.NON_SPACING_MARK.toInt() ||
                        type == Character.COMBINING_SPACING_MARK.toInt() ||
                        type == Character.ENCLOSING_MARK.toInt()
                    ) {
                        continue
                    }
                    out.appendCodePoint(cp)
                }
                return out.toString().lowercase(Locale.ROOT)
            }
            val index = fold(haystack).indexOf(fold(piece))
            if (index < 0) return null
            return index
        }

        internal fun snippet(content: String, query: String, normalizedQuery: String): String {
            val trimmed = BotMemoryText.trimWhitespace(content)
            if (trimmed.isEmpty()) return "（空）"
            var matchOffset: Int? = null
            for (piece in splitWhitespace(query)) {
                if (piece.isEmpty()) continue
                val index = trimmed.indexOf(piece, ignoreCase = true)
                if (index >= 0) {
                    matchOffset = BotMemoryText.scalarCount(trimmed.substring(0, index))
                    break
                }
            }
            if (matchOffset == null && normalizedQuery.isNotEmpty()) {
                val normalized = BotMemoryTokenizer.normalize(trimmed)
                val index = normalized.indexOf(normalizedQuery)
                if (index >= 0) {
                    matchOffset = BotMemoryText.scalarCount(normalized.substring(0, index))
                } else {
                    matchOffset = diacriticInsensitiveIndex(trimmed, normalizedQuery)
                }
            }
            val total = BotMemoryText.scalarCount(trimmed)
            val offset = matchOffset?.coerceIn(0, total) ?: 0
            var start = max(0, offset - 120)
            var end = minOf(total, start + MAXIMUM_SNIPPET_SCALARS - 40)
            if (start > 0) {
                val boundary = BotMemoryText.graphemeBoundaryAtOrAfter(trimmed, start)
                if (boundary <= end) start = boundary
            }
            if (end < total) {
                val boundary = BotMemoryText.graphemeBoundaryAtOrAfter(trimmed, end)
                if (boundary > start) end = boundary
            }
            var body = BotMemoryText.scalarSlice(trimmed, start, end)
            if (start > 0) body = "…$body"
            if (end < total) body += "…"
            if (BotMemoryText.scalarCount(body) > MAXIMUM_SNIPPET_SCALARS) {
                val withoutTrailing = if (end < total) body.dropLast(1) else body
                body = BotMemoryText.cappedAtGrapheme(withoutTrailing, MAXIMUM_SNIPPET_SCALARS - 1) + "…"
            }
            return body
        }
    }
}

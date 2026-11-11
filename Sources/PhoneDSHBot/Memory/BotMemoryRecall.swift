// SPDX-License-Identifier: MIT

import Foundation

public struct BotMemoryRecallHit: Codable, Sendable, Equatable {
    public let path: String
    public let scope: BotMemoryScope
    public let snippet: String
    public let score: Double
    public let relevance: Double
    public let recency: Double
    public let matched: Bool
    public let updatedAtMS: Int64
    public let version: Int
    public let evidence: [String]

    public init(
        path: String,
        scope: BotMemoryScope,
        snippet: String,
        score: Double,
        relevance: Double,
        recency: Double,
        matched: Bool,
        updatedAtMS: Int64,
        version: Int,
        evidence: [String]
    ) {
        self.path = path
        self.scope = scope
        self.snippet = snippet
        self.score = score
        self.relevance = relevance
        self.recency = recency
        self.matched = matched
        self.updatedAtMS = updatedAtMS
        self.version = version
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case path
        case scope
        case snippet
        case score
        case relevance
        case recency
        case matched
        case updatedAtMS = "updated_at_ms"
        case version
        case evidence
    }
}

/// BM25 + CJK tokenization over document bodies. `importance` is gone; the
/// score is `0.85 * relevance + 0.15 * recency`.
public struct BotMemoryDocumentRecallIndex {
    public static let relevanceWeight = 0.85
    public static let recencyWeight = 0.15
    public static let recencyHalfLifeDays = 180.0
    public static let maximumSnippetScalars = 500

    private static let bm25K1 = 1.2
    private static let bm25B = 0.75
    private static let bm25Saturation = 3.0
    private static let maximumPrefixTerms = 64
    private static let dayMS = 24.0 * 60 * 60 * 1_000

    private struct Document {
        var path: String
        var scope: BotMemoryScope
        var content: String
        var normalizedContent: String
        var tokens: BotMemoryTokenAnalysis
        var length: Double
        var updatedAtMS: Int64
        var version: Int
        var evidence: [String]
    }

    private struct QueryTerm {
        var key: String
        var weight: Double
        var idf: Double
    }

    private struct Candidate {
        var document: Document
        var bm25: Double = 0
        var termHits: Int = 0
    }

    private var documents: [String: Document] = [:]
    private var documentOrder: [String] = []
    private var postings: [String: [String: Double]] = [:]
    private var termOrder: [String] = []
    private var totalLength = 0.0

    public init(documents: [BotMemoryDocument] = []) {
        sync(documents)
    }

    public var count: Int { documents.count }

    public mutating func sync(_ values: [BotMemoryDocument]) {
        let live = Set(values.map(\.path))
        for path in documentOrder where !live.contains(path) {
            remove(path)
        }
        for value in values {
            if let existing = documents[value.path],
               existing.content == value.content,
               existing.version == value.version,
               existing.updatedAtMS == value.updatedAtMS {
                documents[value.path]?.evidence = value.evidence
                continue
            }
            add(value)
        }
    }

    @discardableResult
    public mutating func add(_ value: BotMemoryDocument) -> Bool {
        let path = value.path
        guard !path.isEmpty else { return false }
        if documents[path] != nil { remove(path) }
        let tokens = BotMemoryTokenizer.analyzeText(value.content)
        let length = tokens.counts.values.reduce(0, +)
        let document = Document(
            path: path,
            scope: value.scope,
            content: value.content,
            normalizedContent: BotMemoryTokenizer.normalize(value.content),
            tokens: tokens,
            length: length,
            updatedAtMS: value.updatedAtMS,
            version: value.version,
            evidence: value.evidence)
        documents[path] = document
        documentOrder.append(path)
        totalLength += length
        for term in tokens.order {
            if postings[term] == nil { termOrder.append(term) }
            postings[term, default: [:]][path] = tokens.counts[term]
        }
        return true
    }

    @discardableResult
    public mutating func remove(_ path: String) -> Bool {
        guard let document = documents.removeValue(forKey: path) else { return false }
        for term in document.tokens.order {
            postings[term]?.removeValue(forKey: path)
            if postings[term]?.isEmpty == true { postings.removeValue(forKey: term) }
        }
        documentOrder.removeAll { $0 == path }
        totalLength -= document.length
        return true
    }

    public func search(
        _ query: String = "",
        limit: Int = 40,
        now: Int64? = nil,
        includeScope: BotMemoryScope? = nil
    ) -> [BotMemoryRecallHit] {
        searchPage(query, limit: limit, now: now, includeScope: includeScope).hits
    }

    public func searchPage(
        _ query: String = "",
        limit: Int = 40,
        now: Int64? = nil,
        includeScope: BotMemoryScope? = nil
    ) -> (hits: [BotMemoryRecallHit], total: Int) {
        let totalDocuments = documents.count
        if totalDocuments == 0 { return ([], 0) }
        let nowMS = now ?? Int64(Date().timeIntervalSince1970 * 1_000)
        let analysis = BotMemoryTokenizer.analyzeQuery(query)
        let blank = analysis.normalizedQuery.isEmpty
        var queryTerms: [QueryTerm] = []
        var seen: Set<String> = []

        func idf(_ df: Int) -> Double {
            log(1 + (Double(totalDocuments - df) + 0.5) / (Double(df) + 0.5))
        }

        func addQueryTerm(_ key: String, weight: Double) {
            if seen.contains(key) || queryTerms.count >= 512 { return }
            guard let posting = postings[key], !posting.isEmpty else { return }
            seen.insert(key)
            queryTerms.append(QueryTerm(key: key, weight: weight, idf: idf(posting.count)))
        }

        func prefixTerms(_ key: String) -> [(key: String, idf: Double)] {
            let pieces = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let type = pieces.count == 2 ? String(pieces[0]) : ""
            let payload = pieces.count == 2 ? String(pieces[1]) : key
            var output: [(key: String, idf: Double)] = []
            if type == "w" && payload.utf16.count <= 2 {
                for term in termOrder where term.hasPrefix(key) {
                    guard let posting = postings[term] else { continue }
                    output.append((term, idf(posting.count)))
                    if output.count >= Self.maximumPrefixTerms { break }
                }
                return output
            }
            if type == "u" {
                for prefix in ["b:\(payload)", "t:\(payload)"] {
                    for term in termOrder where term.hasPrefix(prefix) {
                        guard let posting = postings[term] else { continue }
                        output.append((term, idf(posting.count)))
                        if output.count >= Self.maximumPrefixTerms { return output }
                    }
                }
            }
            return output
        }

        for key in analysis.tokens.order {
            let weight = analysis.tokens.counts[key] ?? 1
            if key.hasPrefix("w:") && String(key.dropFirst(2)).utf16.count <= 2 {
                addQueryTerm(key, weight: weight)
                for expanded in prefixTerms(key) { addQueryTerm(expanded.key, weight: weight * 0.7) }
            } else if postings[key] != nil {
                addQueryTerm(key, weight: weight)
            } else {
                for expanded in prefixTerms(key) { addQueryTerm(expanded.key, weight: weight * 0.7) }
            }
        }
        if !blank && queryTerms.isEmpty { return ([], 0) }

        let averageLength = totalLength / Double(totalDocuments)
        let average = averageLength == 0 ? 1 : averageLength
        var candidates: [String: Candidate] = [:]
        for queryTerm in queryTerms {
            guard let posting = postings[queryTerm.key] else { continue }
            for (path, termFrequency) in posting {
                guard let document = documents[path] else { continue }
                var candidate = candidates[path] ?? Candidate(document: document)
                let denominator = termFrequency + Self.bm25K1
                    * (1 - Self.bm25B + Self.bm25B * (document.length / average))
                candidate.bm25 += queryTerm.weight * queryTerm.idf
                    * ((termFrequency * (Self.bm25K1 + 1)) / denominator)
                candidate.termHits += 1
                candidates[path] = candidate
            }
        }

        var ranked: [BotMemoryRecallHit] = []
        func consider(_ document: Document, _ candidate: Candidate) {
            if let includeScope, document.scope != includeScope { return }
            let exact = !blank && document.normalizedContent.contains(analysis.normalizedQuery)
            if !blank && !exact && candidate.bm25 <= 0 { return }
            let rawRelevance = candidate.bm25 > 0
                ? candidate.bm25 / (candidate.bm25 + Self.bm25Saturation)
                : 0
            let relevance = exact ? max(0.95, rawRelevance) : rawRelevance
            let recency = document.updatedAtMS > 0
                ? pow(0.5, max(0, Double(nowMS) - Double(document.updatedAtMS))
                    / Self.dayMS / Self.recencyHalfLifeDays)
                : 0
            let score = Self.relevanceWeight * relevance + Self.recencyWeight * recency
            ranked.append(BotMemoryRecallHit(
                path: document.path,
                scope: document.scope,
                snippet: Self.snippet(document.content, query: query, normalizedQuery: analysis.normalizedQuery),
                score: Self.round(score),
                relevance: Self.round(relevance),
                recency: Self.round(recency),
                matched: blank ? false : (candidate.bm25 > 0 || exact),
                updatedAtMS: document.updatedAtMS,
                version: document.version,
                evidence: document.evidence))
        }

        if blank {
            for path in documentOrder {
                guard let document = documents[path] else { continue }
                consider(document, Candidate(document: document))
            }
        } else {
            for path in documentOrder {
                guard let candidate = candidates[path] else { continue }
                consider(candidate.document, candidate)
            }
        }
        ranked.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.updatedAtMS != right.updatedAtMS { return left.updatedAtMS > right.updatedAtMS }
            return left.path < right.path
        }
        let maximum = max(0, limit)
        return (Array(ranked.prefix(maximum)), ranked.count)
    }

    private static func round(_ value: Double) -> Double {
        value.isFinite ? (value * 1_000_000).rounded() / 1_000_000 : 0
    }

    static func snippet(_ content: String, query: String, normalizedQuery: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "（空）" }
        let haystack = trimmed
        var match: String.Index?
        let pieces = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for piece in pieces where !piece.isEmpty {
            if let range = haystack.range(of: piece, options: [.caseInsensitive, .diacriticInsensitive]) {
                match = range.lowerBound
                break
            }
        }
        if match == nil, !normalizedQuery.isEmpty {
            let normalized = BotMemoryTokenizer.normalize(haystack)
            if let range = normalized.range(of: normalizedQuery) {
                let offset = normalized[..<range.lowerBound].unicodeScalars.count
                match = haystack.index(
                    haystack.startIndex,
                    offsetBy: min(offset, haystack.count))
            }
        }
        let scalars = Array(trimmed.unicodeScalars)
        let matchOffset: Int
        if let match {
            matchOffset = trimmed[..<match].unicodeScalars.count
        } else {
            matchOffset = 0
        }
        let start = max(0, min(scalars.count, matchOffset - 120))
        let end = min(scalars.count, start + maximumSnippetScalars - 40)
        var body = String(String.UnicodeScalarView(scalars[start..<end]))
        if start > 0 { body = "…" + body }
        if end < scalars.count { body += "…" }
        return body
    }
}

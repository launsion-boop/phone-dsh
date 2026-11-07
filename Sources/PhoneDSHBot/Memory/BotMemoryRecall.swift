// SPDX-License-Identifier: MIT

import Foundation

public struct BotMemoryRankedFact: Sendable, Equatable {
    public let fact: BotMemoryFact
    public let score: Double
    public let relevance: Double
    public let recency: Double
    public let importance: Double
    public let matched: Bool

    public init(
        fact: BotMemoryFact,
        score: Double,
        relevance: Double,
        recency: Double,
        importance: Double,
        matched: Bool
    ) {
        self.fact = fact
        self.score = score
        self.relevance = relevance
        self.recency = recency
        self.importance = importance
        self.matched = matched
    }
}

public struct BotMemoryRecallHit: Codable, Sendable, Equatable {
    public let source: String
    public let text: String
    public let factID: String
    public let learnedAtMS: Int64
    public let tier: BotMemoryTier
    public let scope: BotMemoryScope
    public let key: String?
    public let score: Double
    public let relevance: Double
    public let recency: Double
    public let importance: Double
    public let lastUsedMS: Int64
    public let applicableWhen: String?
    public let notApplicableWhen: String?
    public let archived: Bool?
    public let archivedAtMS: Int64?

    enum CodingKeys: String, CodingKey {
        case source
        case text
        case factID = "fact_id"
        case learnedAtMS = "learned_at_ms"
        case tier
        case scope
        case key
        case score
        case relevance
        case recency
        case importance
        case lastUsedMS = "last_used_ms"
        case applicableWhen
        case notApplicableWhen
        case archived
        case archivedAtMS = "archived_at_ms"
    }

    init(ranked: BotMemoryRankedFact, sourcePrefix: String, now: Int64, lastUsedMS: Int64? = nil) {
        let fact = ranked.fact
        let base: String
        switch fact.tier {
        case .profile:
            base = "profile"
        case .note:
            base = "notes"
        case .log:
            base = "log/\(Self.dayString(fact.learnedAtMS, fallback: now))"
        }
        source = "\(sourcePrefix)/\(base)"
        text = fact.text
        factID = fact.factID
        learnedAtMS = fact.learnedAtMS
        tier = fact.tier
        scope = fact.scope
        key = fact.key
        score = Self.round(ranked.score)
        relevance = Self.round(ranked.relevance)
        recency = Self.round(ranked.recency)
        importance = Self.round(ranked.importance)
        self.lastUsedMS = lastUsedMS ?? fact.lastUsedMS
        applicableWhen = fact.applicableWhen
        notApplicableWhen = fact.notApplicableWhen
        archived = fact.archived == true ? true : nil
        archivedAtMS = fact.archived == true ? fact.archivedAtMS ?? 0 : nil
    }

    private static func round(_ value: Double) -> Double {
        value.isFinite ? (value * 1_000_000).rounded() / 1_000_000 : 0
    }

    private static func dayString(_ learnedAtMS: Int64, fallback: Int64) -> String {
        let timestamp = learnedAtMS == 0 ? fallback : learnedAtMS
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1_000))
    }
}

public struct BotMemoryRecallIndex {
    public static let relevanceWeight = 0.72
    public static let recencyWeight = 0.18
    public static let importanceWeight = 0.10
    public static let recencyHalfLifeDays = 180.0

    private static let bm25K1 = 1.2
    private static let bm25B = 0.75
    private static let bm25Saturation = 3.0
    private static let minimumMatchedIDF = 0.85
    private static let smallCorpusSize = 8
    private static let maximumPrefixTerms = 64
    private static let dayMS = 24.0 * 60 * 60 * 1_000

    private struct Document {
        var fact: BotMemoryFact
        var text: String
        var normalizedText: String
        var tokens: BotMemoryTokenAnalysis
        var length: Double
        var learnedAtMS: Int64
    }

    private struct QueryTerm {
        var key: String
        var weight: Double
        var idf: Double
    }

    private struct Candidate {
        var document: Document
        var bm25: Double = 0
        var matchedIDF: Double = 0
        var termHits: Int = 0
    }

    private var documents: [String: Document] = [:]
    private var documentOrder: [String] = []
    private var postings: [String: [String: Double]] = [:]
    private var termOrder: [String] = []
    private var totalLength = 0.0

    public init(facts: [BotMemoryFact] = []) {
        for fact in facts {
            _ = add(fact)
        }
    }

    public var count: Int { documents.count }

    @discardableResult
    public mutating func add(_ fact: BotMemoryFact) -> Bool {
        let id = fact.factID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return false }
        if documents[id] != nil {
            _ = remove(id)
        }
        let tokens = BotMemoryTokenizer.analyzeText(fact.text)
        let length = tokens.counts.values.reduce(0, +)
        var storedFact = fact
        storedFact.factID = id
        let document = Document(
            fact: storedFact,
            text: fact.text,
            normalizedText: BotMemoryTokenizer.normalize(fact.text),
            tokens: tokens,
            length: length,
            learnedAtMS: fact.learnedAtMS
        )
        documents[id] = document
        documentOrder.append(id)
        totalLength += length
        for term in tokens.order {
            if postings[term] == nil {
                termOrder.append(term)
            }
            postings[term, default: [:]][id] = tokens.counts[term]
        }
        return true
    }

    @discardableResult
    public mutating func remove(_ factID: String) -> Bool {
        let id = factID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = documents.removeValue(forKey: id) else { return false }
        for term in document.tokens.order {
            postings[term]?.removeValue(forKey: id)
            if postings[term]?.isEmpty == true {
                postings.removeValue(forKey: term)
            }
        }
        documentOrder.removeAll { $0 == id }
        totalLength -= document.length
        return true
    }

    public mutating func sync(_ facts: [BotMemoryFact]) {
        let live = Set(facts.map { $0.factID.trimmingCharacters(in: .whitespacesAndNewlines) })
        for id in documentOrder where !live.contains(id) {
            _ = remove(id)
        }
        for fact in facts {
            let id = fact.factID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if documents[id]?.text != fact.text {
                _ = add(fact)
            } else {
                documents[id]?.fact = fact
                documents[id]?.learnedAtMS = fact.learnedAtMS
            }
        }
    }

    public static func normalizeImportance(_ value: Double) -> Double {
        if !value.isFinite { return 0.5 }
        if value <= 1 { return min(1, max(0, value)) }
        if value <= 5 { return min(1, max(0, value / 5)) }
        return 1
    }

    public func search(
        _ query: String = "",
        limit: Int = 40,
        now: Int64? = nil,
        includeArchived: Bool = false
    ) -> [BotMemoryRankedFact] {
        let total = documents.count
        if total == 0 { return [] }
        let nowMS = now ?? Int64(Date().timeIntervalSince1970 * 1_000)
        let analysis = BotMemoryTokenizer.analyzeQuery(query)
        let blank = analysis.normalizedQuery.isEmpty
        let latinOnly = analysis.cjkCharacters == 0 && analysis.latinWords >= 2
        var queryTerms: [QueryTerm] = []
        var seen: Set<String> = []

        func idf(_ df: Int) -> Double {
            log(1 + (Double(total - df) + 0.5) / (Double(df) + 0.5))
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
                for expanded in prefixTerms(key) {
                    addQueryTerm(expanded.key, weight: weight * 0.7)
                }
            } else if postings[key] != nil {
                addQueryTerm(key, weight: weight)
            } else {
                for expanded in prefixTerms(key) {
                    addQueryTerm(expanded.key, weight: weight * 0.7)
                }
            }
        }
        if !blank && queryTerms.isEmpty { return [] }

        let averageDocumentLength = totalLength / Double(total)
        let average = averageDocumentLength == 0 ? 1 : averageDocumentLength
        let exactQuery = !blank
            && analysis.normalizedQuery.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && analysis.normalizedQuery.utf16.count >= 2
            ? analysis.normalizedQuery
            : ""
        var candidates: [String: Candidate] = [:]
        for queryTerm in queryTerms {
            guard let posting = postings[queryTerm.key] else { continue }
            for (id, termFrequency) in posting {
                guard let document = documents[id] else { continue }
                var candidate = candidates[id] ?? Candidate(document: document)
                let denominator = termFrequency + Self.bm25K1
                    * (1 - Self.bm25B + Self.bm25B * (document.length / average))
                candidate.bm25 += queryTerm.weight * queryTerm.idf
                    * ((termFrequency * (Self.bm25K1 + 1)) / denominator)
                candidate.matchedIDF += queryTerm.weight * (queryTerm.idf + 0.1)
                candidate.termHits += 1
                candidates[id] = candidate
            }
        }

        var ranked: [BotMemoryRankedFact] = []
        func consider(_ document: Document, _ candidate: Candidate) {
            guard BotMemoryVisibility.isActive(document.fact, now: nowMS) else { return }
            let exact = !exactQuery.isEmpty && document.normalizedText.contains(exactQuery)
            if !blank && !exact && total >= Self.smallCorpusSize && candidate.matchedIDF < Self.minimumMatchedIDF {
                return
            }
            if !blank && !exact && latinOnly
                && Double(candidate.termHits) / Double(queryTerms.count) < 0.5 {
                return
            }
            let rawRelevance = candidate.bm25 > 0
                ? candidate.bm25 / (candidate.bm25 + Self.bm25Saturation)
                : 0
            let relevance = exact ? max(0.95, rawRelevance) : rawRelevance
            let recency = document.learnedAtMS > 0
                ? pow(0.5, max(0, Double(nowMS) - Double(document.learnedAtMS)) / Self.dayMS / Self.recencyHalfLifeDays)
                : 0
            let importance = Self.normalizeImportance(document.fact.importance)
            let score = Self.relevanceWeight * relevance
                + Self.recencyWeight * recency
                + Self.importanceWeight * importance
            ranked.append(BotMemoryRankedFact(
                fact: document.fact,
                score: score,
                relevance: relevance,
                recency: recency,
                importance: importance,
                matched: candidate.bm25 > 0 || exact
            ))
        }

        if blank {
            for id in documentOrder {
                guard let document = documents[id] else { continue }
                consider(document, Candidate(document: document))
            }
        } else {
            for id in documentOrder {
                guard let candidate = candidates[id] else { continue }
                consider(candidate.document, candidate)
            }
        }
        ranked.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.fact.learnedAtMS != right.fact.learnedAtMS {
                return left.fact.learnedAtMS > right.fact.learnedAtMS
            }
            return left.fact.factID < right.fact.factID
        }
        let maximum = max(0, limit)
        if includeArchived {
            return Array(ranked.prefix(maximum))
        }
        let archivedCount = documents.values.reduce(0) { $0 + ($1.fact.archived == true ? 1 : 0) }
        return Array(ranked.prefix(maximum + archivedCount))
            .filter { $0.fact.archived != true }
            .prefix(maximum)
            .map { $0 }
    }
}

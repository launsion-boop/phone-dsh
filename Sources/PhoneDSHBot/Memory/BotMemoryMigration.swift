// SPDX-License-Identifier: MIT

import Foundation

/// One-time, replayable migration from the legacy fact events to the document
/// tree. It only adds missing documents and missing fact lines, so an agent's
/// later edits are never overwritten and a second run writes no event.
enum BotMemoryMigrator {
    static func migrate(
        facts: [BotMemoryFact],
        store: any BotMemoryDocumentStore,
        botID: String,
        now: Int64
    ) async throws {
        let ordered = facts.sorted {
            if $0.learnedAtMS != $1.learnedAtMS { return $0.learnedAtMS < $1.learnedAtMS }
            return $0.factID < $1.factID
        }
        var grouped: [String: [BotMemoryFact]] = [:]
        for fact in ordered {
            grouped[targetPath(for: fact), default: []].append(fact)
        }
        for path in grouped.keys.sorted() {
            try await merge(
                facts: grouped[path] ?? [],
                path: path,
                store: store,
                botID: botID,
                now: now)
        }

        let documents = try await store.documents(scope: nil)
        for scope in BotMemoryScope.allCases {
            let indexPath = "\(scope.rawValue)/INDEX.md"
            guard try await store.document(path: indexPath) == nil else { continue }
            let content = indexContent(scope: scope, documents: documents)
            _ = try await writeWithRetry(
                path: indexPath,
                content: content,
                evidence: [],
                expectedVersion: 0,
                store: store,
                botID: botID,
                now: now)
        }
    }

    static func targetPath(for fact: BotMemoryFact) -> String {
        let root = fact.scope.rawValue
        switch fact.tier {
        case .profile:
            return "\(root)/profile.md"
        case .note:
            return "\(root)/notes/\(slug(fact.key)).md"
        case .log:
            return "\(root)/log/\(month(fact.learnedAtMS)).md"
        }
    }

    static func slug(_ key: String?) -> String {
        let normalized = (key ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCompatibilityMapping
        var output = ""
        var lastDash = false
        for scalar in normalized.unicodeScalars {
            let value = scalar.value
            let allowed = (0x61...0x7A).contains(value)
                || (0x30...0x39).contains(value)
                || scalar == "." || scalar == "_" || scalar == "-"
            if allowed {
                output.append(contentsOf: String(scalar))
                lastDash = scalar == "-"
            } else if !lastDash {
                output.append("-")
                lastDash = true
            }
        }
        output = output.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return output.isEmpty ? "note" : String(BotMemoryText.prefixCodePoints(output, 64))
    }

    static func month(_ timestampMS: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(
            from: Date(timeIntervalSince1970: Double(max(0, timestampMS)) / 1_000))
    }

    private static func merge(
        facts: [BotMemoryFact],
        path: String,
        store: any BotMemoryDocumentStore,
        botID: String,
        now: Int64
    ) async throws {
        for _ in 0..<3 {
            let existing = try await store.document(path: path)
            let existingContent = existing?.content ?? header(for: facts[0])
            var content = existingContent
            let header = header(for: facts[0])
            for fact in facts {
                if content.contains(fact.text) { continue }
                content += content == header ? "\n\n- \(fact.text)" : "\n- \(fact.text)"
            }
            let evidence = unionEvidence(existing?.evidence ?? [], facts)
            if let existing, existing.content == content, existing.evidence == evidence {
                return
            }
            let outcome = try await writeWithRetry(
                path: path,
                content: content,
                evidence: evidence,
                expectedVersion: existing?.version ?? 0,
                store: store,
                botID: botID,
                now: now)
            switch outcome {
            case .written, .deleted:
                return
            case .conflict:
                continue
            default:
                return
            }
        }
    }

    private static func writeWithRetry(
        path: String,
        content: String,
        evidence: [String],
        expectedVersion: Int,
        store: any BotMemoryDocumentStore,
        botID: String,
        now: Int64
    ) async throws -> BotMemoryStoreWriteOutcome {
        try await store.write(BotMemoryStoreWriteRequest(
            action: .write,
            path: path,
            content: content,
            expectedVersion: expectedVersion,
            author: BotMemoryAuthor(botID: botID, kind: .migration),
            evidence: evidence,
            trust: nil,
            source: nil,
            atMS: now))
    }

    private static func header(for fact: BotMemoryFact) -> String {
        switch fact.tier {
        case .profile:
            return "# Profile"
        case .note:
            return "# \(fact.key ?? "note")"
        case .log:
            return "# \(month(fact.learnedAtMS))"
        }
    }

    private static func unionEvidence(_ existing: [String], _ facts: [BotMemoryFact]) -> [String] {
        var values = Set(existing)
        for fact in facts {
            for reference in fact.evidence ?? [] {
                values.insert(reference)
            }
        }
        return Array(values.sorted().prefix(8))
    }

    static func indexContent(scope: BotMemoryScope, documents: [BotMemoryDocument]) -> String {
        let paths = documents
            .filter { $0.scope == scope && !BotMemoryAuthorizer.isIndex($0.path) }
            .map(\.path)
            .sorted()
        guard !paths.isEmpty else { return "# Index" }
        var lines = ["# Index", ""]
        for path in paths {
            let candidate = lines + ["- \(path)"]
            if BotMemoryText.codePointCount(candidate.joined(separator: "\n"))
                > BotMemoryAuthorizer.indexLimit {
                let note = "- …（更多文档用 ReadMemory 列举）"
                let withNote = lines + [note]
                if BotMemoryText.codePointCount(withNote.joined(separator: "\n"))
                    <= BotMemoryAuthorizer.indexLimit {
                    lines.append(note)
                }
                break
            }
            lines.append("- \(path)")
        }
        return lines.joined(separator: "\n")
    }
}

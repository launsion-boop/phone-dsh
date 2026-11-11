// SPDX-License-Identifier: MIT

import Foundation

/// The only verdicts a verifier may return. The host maps every malformed,
/// missing, out-of-budget or unreadable run to `uncertain`; it never upgrades a
/// model claim to `passed`.
public enum BotVerificationVerdict: String, Codable, Sendable, Equatable, CaseIterable {
    case passed
    case failed
    case uncertain
}

/// The budget envelope recorded with every verification. The limit is derived
/// from the subject's own budget and is not model-negotiable.
public struct BotVerificationBudget: Codable, Sendable, Equatable {
    public var ratio: Double
    public var limitMs: Int
    public var usedMs: Int
    public var exceeded: Bool

    public init(ratio: Double = BotVerificationPolicy.budgetRatio,
                limitMs: Int, usedMs: Int, exceeded: Bool) {
        self.ratio = ratio
        self.limitMs = max(0, limitMs)
        self.usedMs = max(0, usedMs)
        self.exceeded = exceeded || usedMs > limitMs
    }

    public var jsonValue: BotJSONValue {
        .object([
            "ratio": .number(ratio),
            "limitMs": .number(Double(limitMs)),
            "usedMs": .number(Double(usedMs)),
            "exceeded": .bool(exceeded),
        ])
    }
}

/// The durable verification object shared by the task record, `AwaitTask` and
/// the nested `verification` member of `verification.reported`.
public struct BotVerification: Codable, Sendable, Equatable {
    public var verdict: BotVerificationVerdict
    public var summary: String
    public var refs: [String]
    public var unverified: [String]
    public var budget: BotVerificationBudget
    public var output: String

    public init(verdict: BotVerificationVerdict, summary: String, refs: [String],
                unverified: [String], budget: BotVerificationBudget, output: String) {
        self.verdict = verdict
        self.summary = summary
        self.refs = refs
        self.unverified = unverified
        self.budget = budget
        self.output = output
    }

    public var jsonValue: BotJSONValue {
        .object([
            "verdict": .string(verdict.rawValue),
            "summary": .string(summary),
            "refs": .array(refs.map(BotJSONValue.string)),
            "unverified": .array(unverified.map(BotJSONValue.string)),
            "budget": budget.jsonValue,
            "output": .string(output),
        ])
    }
}

/// The exact JSON object contract for a verifier's final assistant message.
public struct BotVerifierOutput: Sendable, Equatable {
    public var verdict: BotVerificationVerdict
    public var summary: String
    public var refs: [String]
    public var unverified: [String]

    public init(verdict: BotVerificationVerdict, summary: String,
                refs: [String], unverified: [String]) {
        self.verdict = verdict
        self.summary = summary
        self.refs = refs
        self.unverified = unverified
    }
}

public enum BotVerifierOutputError: Error, Sendable, Equatable, CustomStringConvertible {
    case notJSON
    case notObject
    case unexpectedMember(String)
    case missingMember(String)
    case invalidVerdict
    case invalidSummary
    case invalidRefs
    case invalidUnverified
    case passedWithUnverified

    public var description: String {
        switch self {
        case .notJSON: return "verifier output is not one JSON object"
        case .notObject: return "verifier output must be a JSON object"
        case .unexpectedMember(let name): return "verifier output has unexpected member \(name)"
        case .missingMember(let name): return "verifier output is missing \(name)"
        case .invalidVerdict: return "verifier verdict must be passed, failed or uncertain"
        case .invalidSummary: return "verifier summary must be 1…2000 characters"
        case .invalidRefs: return "verifier refs must be 1…8 canonical record:// references"
        case .invalidUnverified: return "verifier unverified must be at most 20 non-empty strings of at most 500 characters"
        case .passedWithUnverified: return "a passed verdict requires an empty unverified array"
        }
    }
}

public enum BotVerificationPolicy {
    /// P26 §2.8 freezes this ratio at 0.30. Changing it needs a contract
    /// revision, not a caller argument.
    public static let budgetRatio = 0.30
    public static let maximumRefs = 8
    public static let maximumUnverified = 20
    public static let maximumSummaryCharacters = 2_000
    public static let maximumUnverifiedCharacters = 500
    public static let maximumSubjectTitleCharacters = 4_000

    /// Integer floor, so an odd millisecond budget can never exceed 30%.
    public static func verifierLimitMs(subjectBudgetMs: Int) -> Int {
        max(0, subjectBudgetMs) * 3 / 10
    }

    public static func budget(subjectBudgetMs: Int, usedMs: Int) -> BotVerificationBudget {
        let limit = verifierLimitMs(subjectBudgetMs: subjectBudgetMs)
        return BotVerificationBudget(
            limitMs: limit, usedMs: usedMs, exceeded: usedMs > limit)
    }
}

public enum BotVerifierOutputParser {
    private static let members: Set<String> = ["verdict", "summary", "refs", "unverified"]

    /// Parse the verifier's final text. Surrounding whitespace is tolerated;
    /// code fences, prose and non-canonical references are not.
    public static func parse(_ raw: String) throws -> BotVerifierOutput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            throw BotVerifierOutputError.notJSON
        }
        guard let object = value as? [String: Any] else {
            throw BotVerifierOutputError.notObject
        }
        for key in object.keys where !members.contains(key) {
            throw BotVerifierOutputError.unexpectedMember(key)
        }
        for key in members where object[key] == nil {
            throw BotVerifierOutputError.missingMember(key)
        }
        guard let rawVerdict = object["verdict"] as? String,
              let verdict = BotVerificationVerdict(rawValue: rawVerdict) else {
            throw BotVerifierOutputError.invalidVerdict
        }
        guard let rawSummary = object["summary"] as? String else {
            throw BotVerifierOutputError.invalidSummary
        }
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty,
              summary.count <= BotVerificationPolicy.maximumSummaryCharacters else {
            throw BotVerifierOutputError.invalidSummary
        }
        guard let rawRefs = object["refs"] as? [Any],
              (1...BotVerificationPolicy.maximumRefs).contains(rawRefs.count) else {
            throw BotVerifierOutputError.invalidRefs
        }
        var refs: [String] = []
        for value in rawRefs {
            guard let ref = value as? String,
                  BotRecordReference.parse(ref)?.canonical == ref else {
                throw BotVerifierOutputError.invalidRefs
            }
            refs.append(ref)
        }
        guard let rawUnverified = object["unverified"] as? [Any],
              rawUnverified.count <= BotVerificationPolicy.maximumUnverified else {
            throw BotVerifierOutputError.invalidUnverified
        }
        var unverified: [String] = []
        for value in rawUnverified {
            guard let rawEntry = value as? String else {
                throw BotVerifierOutputError.invalidUnverified
            }
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty,
                  entry.count <= BotVerificationPolicy.maximumUnverifiedCharacters else {
                throw BotVerifierOutputError.invalidUnverified
            }
            unverified.append(entry)
        }
        if verdict == .passed, !unverified.isEmpty {
            throw BotVerifierOutputError.passedWithUnverified
        }
        return BotVerifierOutput(
            verdict: verdict, summary: summary, refs: refs, unverified: unverified)
    }
}

/// What the host tells the verifier. The doer's own final summary is
/// deliberately absent: the verifier must re-read the records and artifacts.
public enum BotVerifierPrompt {
    public static func build(subjectKind: String, subjectId: String,
                             completion: String, purpose: String?,
                             constraints: [String], refs: [String],
                             subjectSessionId: String) -> String {
        var lines: [String] = [
            "<verification_request>",
            "subject_kind: \(escape(subjectKind))",
            "subject_id: \(escape(subjectId))",
            "subject_session: \(escape(subjectSessionId))",
            "completion_condition:",
            escape(completion),
        ]
        if let purpose, !purpose.isEmpty {
            lines.append("purpose:")
            lines.append(escape(purpose))
        }
        if !constraints.isEmpty {
            lines.append("constraints:")
            lines.append(contentsOf: constraints.map { "- \(escape($0))" })
        }
        lines.append("record_refs:")
        lines.append(contentsOf: refs.map { "- \($0)" })
        lines.append(contentsOf: [
            "<verification_rules>",
            "You are a read-only verifier. Inspect the actual workspace artifacts and the referenced records; the doer's final message is not evidence.",
            "You may use read, grep, glob and read-only bash, including `phone record search` and `phone record read`.",
            "You cannot write files, send messages, delegate Tasks, use the network, or read or write memory.",
            "Decide whether every completion condition is now true.",
            "Reply with exactly one JSON object and nothing else. Do not use a code fence or add prose.",
            "{\"verdict\":\"passed|failed|uncertain\",\"summary\":\"...\",\"refs\":[\"record://session/<id>#<seq>\"],\"unverified\":[\"...\"]}",
            "refs accepts both record://session/<id>#<seq> and record://event/<commitSeq>.",
            "summary is required (1…2000 characters). refs contains 1…8 canonical record:// references you actually checked. unverified lists what you could not check (at most 20 entries).",
            "passed requires every completion condition to be verified and unverified to be empty. Use uncertain when evidence is missing, unreadable or out of scope.",
            "</verification_rules>",
            "</verification_request>",
        ])
        return lines.joined(separator: "\n")
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

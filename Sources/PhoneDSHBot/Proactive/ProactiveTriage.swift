// SPDX-License-Identifier: MIT

import Foundation

public struct ProactiveTriageRequest: Sendable, Equatable {
    public var purpose: String
    public var system: String
    public var candidateJSON: String

    public init(purpose: String, system: String, candidateJSON: String) {
        self.purpose = purpose
        self.system = system
        self.candidateJSON = candidateJSON
    }
}

public protocol ProactiveTriageClient: Sendable {
    func complete(_ request: ProactiveTriageRequest) async throws -> String
}

public struct ProactiveTriageGate: ProactiveTriaging {
    public static let purpose = "triage"
    public static let system = "You are the proactivity triage gate for a desktop assistant. Decide whether interrupting the user NOW is worth it. A human-visible notification is expensive; err toward actionable=false for noise, but keep anything a human is explicitly waiting for. Reply with strict JSON only: {\"actionable\": boolean, \"reason\": \"short reason\"}."

    private let client: (any ProactiveTriageClient)?
    private let enabled: Bool

    public init(client: (any ProactiveTriageClient)? = nil, enabled: Bool = false) {
        self.client = client
        self.enabled = enabled
    }

    public func evaluate(_ candidate: ProactiveCandidate) async -> ProactiveTriageResult {
        if candidate.kind == .reminder {
            return ProactiveTriageResult(allow: true, reason: "reminder-skips-triage", source: "policy")
        }
        guard enabled else {
            return ProactiveTriageResult(allow: true, reason: "triage-disabled", source: "config")
        }
        guard let client else {
            return ProactiveTriageResult(allow: true, reason: "triage-unavailable", source: "config")
        }
        let summary: [String: Any] = [
            "kind": candidate.kind.rawValue,
            "botId": candidate.botId,
            "trigger": candidate.trigger.map { $0 as Any } ?? NSNull(),
            "status": candidate.status.map { $0 as Any } ?? NSNull(),
            "text": candidate.body.map { $0 as Any } ?? NSNull(),
            "silentForMs": candidate.silentForMs.map { NSNumber(value: $0) as Any } ?? NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: summary)) ?? Data("{}".utf8)
        do {
            let reply = try await client.complete(ProactiveTriageRequest(
                purpose: Self.purpose, system: Self.system,
                candidateJSON: String(decoding: data, as: UTF8.self)
            ))
            guard let parsed = Self.parse(reply) else {
                return ProactiveTriageResult(allow: true, reason: "triage-unparsed", source: "model")
            }
            if !parsed.actionable {
                return ProactiveTriageResult(allow: false,
                                             reason: parsed.reason.isEmpty ? "triage" : "triage: \(parsed.reason)",
                                             source: "model")
            }
            return ProactiveTriageResult(allow: true, reason: "triage-allowed", source: "model")
        } catch {
            return ProactiveTriageResult(allow: true, reason: "triage-error", source: "model")
        }
    }

    public static func parse(_ reply: String) -> (actionable: Bool, reason: String)? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.range(of: "{"), let end = text.range(of: "}", options: .backwards) else { return nil }
        text = String(text[start.lowerBound...end.upperBound])
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let actionable = object["actionable"] as? Bool else { return nil }
        return (actionable, String((object["reason"] as? String ?? "").prefix(200)))
    }
}

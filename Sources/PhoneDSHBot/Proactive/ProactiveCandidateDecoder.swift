// SPDX-License-Identifier: MIT

import Foundation

/// The contract's candidate input errors (bot v2 §3.0). `connector-update`
/// candidates must carry explicit, non-empty `title` and `body`; there is no
/// default copy, so a missing field is rejected at the decode boundary and the
/// candidate never enters the decision chain.
public struct ProactiveCandidateValidationError: Error, Equatable, Sendable {
    public let code: String
    public let path: String

    public init(code: String, path: String) {
        self.code = code
        self.path = path
    }
}

/// Decodes the proactive candidate shape used by the shared vectors and
/// enforces the connector-update explicit-copy rule. Other fields keep their
/// existing optional semantics; this is the decode/validation boundary, not a
/// second schema.
public enum ProactiveCandidateDecoder {
    public static func decode(_ data: Data) throws -> ProactiveCandidate {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let value = object as? [String: Any] else {
            throw ProactiveCandidateValidationError(
                code: "proactive-candidate-type", path: "$")
        }
        guard let kindText = value["kind"] as? String else {
            throw ProactiveCandidateValidationError(
                code: "proactive-candidate-missing-field", path: "$.kind")
        }
        guard let kind = ProactiveKind(rawValue: kindText) else {
            throw ProactiveCandidateValidationError(
                code: "proactive-candidate-unknown-enum", path: "$.kind")
        }
        guard let botId = value["botId"] as? String,
              !botId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProactiveCandidateValidationError(
                code: "proactive-candidate-missing-field", path: "$.botId")
        }
        guard let createdAt = integer(value["createdAt"]) else {
            throw ProactiveCandidateValidationError(
                code: "proactive-candidate-missing-field", path: "$.createdAt")
        }
        let title = value["title"] as? String
        let body = value["body"] as? String
        if kind == .connectorUpdate {
            guard let title,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProactiveCandidateValidationError(
                    code: "proactive-candidate-missing-field", path: "$.title")
            }
            guard let body,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProactiveCandidateValidationError(
                    code: "proactive-candidate-missing-field", path: "$.body")
            }
        }
        return ProactiveCandidate(
            id: value["id"] as? String,
            kind: kind,
            botId: botId,
            dedupeKey: value["dedupeKey"] as? String,
            trigger: value["trigger"] as? String,
            sourceEventId: value["sourceEventId"] as? String,
            createdAt: createdAt,
            channel: value["channel"] as? String ?? "system-notification",
            title: title,
            body: body,
            taskId: value["taskId"] as? String,
            taskTitle: value["taskTitle"] as? String,
            summary: value["summary"] as? String,
            status: value["status"] as? String,
            routineId: value["routineId"] as? String,
            runId: value["runId"] as? String,
            attempt: (value["attempt"] as? NSNumber)?.intValue,
            delivery: (value["delivery"] as? String).flatMap(RoutineDeliveryMode.init(rawValue:)),
            quiet: value["quiet"] as? Bool ?? false,
            resultExcerpt: value["resultExcerpt"] as? String,
            deliveryKey: value["deliveryKey"] as? String,
            rowId: value["rowId"] as? String,
            reminderId: value["reminderId"] as? String,
            allowDuringDnd: value["allowDuringDnd"] as? Bool ?? false)
    }

    /// Programmatic producers (for example `ProactiveSources`) use the same
    /// rule before handing a candidate to the engine.
    public static func validate(_ candidate: ProactiveCandidate) throws {
        guard candidate.kind == .connectorUpdate else { return }
        guard let title = candidate.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProactiveCandidateValidationError(
                code: "proactive-candidate-missing-field", path: "$.title")
        }
        guard let body = candidate.body,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProactiveCandidateValidationError(
                code: "proactive-candidate-missing-field", path: "$.body")
        }
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }
}

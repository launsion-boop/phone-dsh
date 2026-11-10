// SPDX-License-Identifier: MIT
// Per-message feedback over the DSH Remote `messageFeedback/put` endpoint.
//
// The endpoint's business result is itself a result envelope
// (`{ok:true,value}` or `{ok:false,error}`); the transport only unwraps the
// gateway envelope, so a rejected feedback write is not an RPC error and must
// not be treated as success. The pin reports a compare-and-set conflict with
// `error.current.version` (or `current: null` when no item exists), which is
// the only retry this client performs.

import Foundation
import PhoneDSHAgentCore

public enum MessageFeedbackError: LocalizedError, Equatable, Sendable {
    /// The id is not a derived, append-origin assistant message in this session.
    case targetNotFound
    /// Any other explicit business failure (`note-blank`, `note-too-large`,
    /// `session-not-found`, or a second compare-and-set conflict).
    case rejected(code: String)

    public var errorDescription: String? {
        switch self {
        case .targetNotFound: "这条消息不支持反馈。"
        case .rejected(let code): "反馈没有提交成功（\(code)）。"
        }
    }
}

/// Writes one message rating and resolves the pin's compare-and-set rule.
public struct MessageFeedbackClient: Sendable {
    private let transport: any DSHRemoteTransport

    public init(transport: any DSHRemoteTransport) {
        self.transport = transport
    }

    /// Rates one assistant message. A `version-conflict` is retried exactly
    /// once with the authoritative `error.current.version`; any other rejected
    /// result surfaces as ``MessageFeedbackError``.
    @discardableResult
    public func rate(messageID: String, sessionID: String, positive: Bool) async throws -> JSONValue {
        var ifVersion: JSONValue = .null
        for attempt in 0..<2 {
            let response = try await transport.call("messageFeedback/put", args: .object([
                "request": .object([
                    "sessionId": .string(sessionID),
                    "messageId": .string(messageID),
                    "rating": .string(positive ? "positive" : "negative"),
                    "ifVersion": ifVersion,
                ]),
            ]))
            if response["ok"]?.boolValue == true {
                return response["value"] ?? .null
            }
            let error = response["error"]
            let code = error?["code"]?.stringValue ?? "unknown"
            if code == "version-conflict", attempt == 0 {
                // `current` is null when the conflicting item no longer exists;
                // retrying with null then means "create only".
                ifVersion = error?["current"]?["version"] ?? .null
                continue
            }
            if code == "target-not-found" {
                throw MessageFeedbackError.targetNotFound
            }
            throw MessageFeedbackError.rejected(code: code)
        }
        throw MessageFeedbackError.rejected(code: "version-conflict")
    }
}

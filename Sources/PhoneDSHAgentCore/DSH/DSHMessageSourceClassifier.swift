// SPDX-License-Identifier: MIT
// PhoneDSHAgentCore: durable DSH message source → native conversation role.

import Foundation

/// Mirrors DSH Web's source-based user/context distinction for durable messages.
/// Classification intentionally inspects only `source.kind`; message text is
/// untrusted content and must never decide whether a row is presented as user input.
public enum DSHMessageSourceClassifier {
    public enum Classification: Equatable, Sendable {
        case user
        case context(sourceKind: String)
    }

    public static func classify(_ message: JSONValue) -> Classification {
        guard let sourceKind = message["source"]?["kind"]?.stringValue,
              sourceKind == "user" else {
            return .context(sourceKind: message["source"]?["kind"]?.stringValue ?? "context")
        }
        return .user
    }
}

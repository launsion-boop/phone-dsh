// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSHAgentCore: provider errors and JSON values.
//
// The two value types every provider, harness and executor contract shares.
// They live here so the contracts above stay free of the speech, voice and
// language-model provider code.

import Foundation

/// Errors every provider may throw. Providers wrap transport-specific errors
/// into these cases so the kit can apply one retry policy.
public enum ProviderError: Error, Equatable, Sendable {
    /// The provider does not implement this operation (or no provider is set).
    case unsupported(String)
    /// Credentials are missing, expired or rejected.
    case unauthorized(String)
    /// The service is temporarily unreachable; retry after the hint if given.
    case unavailable(retryAfter: TimeInterval?)
    /// The service throttled the caller.
    case rateLimited(retryAfter: TimeInterval?)
    /// The request is invalid and must not be retried unchanged.
    case invalidRequest(String)
    /// The service answered with something the provider could not interpret.
    case invalidResponse(String)
    /// The operation was cancelled by the caller or the user.
    case cancelled
    /// A conflict with existing state, for example a reused idempotency key
    /// with a different payload.
    case conflict(String)

    /// Whether the kit may retry the same request later.
    public var isRetryable: Bool {
        switch self {
        case .unavailable, .rateLimited: return true
        default: return false
        }
    }
}

/// A JSON value for provider payloads whose schema belongs to the provider
/// (tool arguments, context attributes, opaque results).
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Decodes a JSON document (object, array or scalar).
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Encodes to compact JSON with sorted keys (stable for hashing).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

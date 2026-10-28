// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSHAgentCore: shared HTTP plumbing.
//
// The reconnect policy is public (the DSH Remote harness and the remaining
// harness adapters configure it). The HTTP status mapping and the read-only
// JSON accessors are internal to this module: the harness adapters keep their
// own copies, so neither leaks into another module's overload set.

import Foundation

/// Exponential backoff with 50–100 % jitter.
public struct ReconnectPolicy: Equatable, Sendable {
    public var initialDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Consecutive failed attempts before the stream gives up with
    /// `ProviderError.unavailable` (the caller re-subscribes later).
    public var maxAttempts: Int

    public init(initialDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 30, maxAttempts: Int = 8) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    public func delay(attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter { return min(maxDelay, max(0, retryAfter)) }
        let base = min(maxDelay, initialDelay * pow(2, Double(max(0, attempt - 1))))
        return base * Double.random(in: 0.5...1.0)
    }
}

/// Maps an HTTP failure (status plus optional `{"error":{"code","message"}}`
/// body) to the provider error the kit's retry policy understands.
enum HTTPErrorMapping {
    static func providerError(status: Int, body: Data, headers: [AnyHashable: Any]) -> ProviderError {
        let (code, message) = errorFields(body)
        let retryAfter = (headers["Retry-After"] as? String).flatMap(TimeInterval.init)
            ?? (headers["retry-after"] as? String).flatMap(TimeInterval.init)
        let text = message ?? code ?? "HTTP \(status)"
        switch status {
        case 400, 422: return .invalidRequest(text)
        case 401, 403: return .unauthorized(text)
        case 404: return .invalidRequest(code ?? "not_found")
        case 409: return .conflict(text)
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 501: return .unsupported(text)
        case 500...599: return .unavailable(retryAfter: retryAfter)
        default: return .invalidResponse(text)
        }
    }

    static func errorFields(_ body: Data) -> (code: String?, message: String?) {
        guard case .object(let object)? = try? JSONValue.parse(body) else { return (nil, nil) }
        if case .object(let error)? = object["error"] {
            var code: String?
            var message: String?
            if case .string(let value)? = error["code"] { code = value }
            if case .string(let value)? = error["message"] { message = value }
            return (code, message)
        }
        if case .string(let value)? = object["error"] { return (nil, value) }
        return (nil, nil)
    }

    static func errorDetails(_ body: Data) -> [String: JSONValue] {
        guard case .object(let object)? = try? JSONValue.parse(body),
              case .object(let error)? = object["error"],
              case .object(let details)? = error["details"] else { return [:] }
        return details
    }
}

/// Typed accessors for clients of the public DSH Remote transport.
public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        numberValue.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

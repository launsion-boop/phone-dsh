// SPDX-License-Identifier: MIT
import Foundation

/// A user-facing UI-Venus failure: a stable `code` for callers and a localized message.
public struct VenusFailure: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let requestID: String?
    public init(_ code: String, _ message: String, requestID: String? = nil) {
        self.code = code; self.message = message; self.requestID = requestID
    }
    public var errorDescription: String? { message + (requestID.map { "（请求 \($0)）" } ?? "") }
}

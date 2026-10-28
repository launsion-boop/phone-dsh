// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: bounded response-outcome receipt.
//
// One receipt is emitted when a model response reaches a durable terminal
// disposition: committed to the response log, replayed from it, or resumed
// from it. The payload is deliberately bounded to key/status/bodyBytes/
// disposition: it never carries the response body, request headers, URLs or
// credentials, so a host may publish it on its ordered event stream.

import Foundation

/// How one gateway response reached the caller.
public enum GatewayResponseDisposition: String, Codable, Equatable, Sendable {
    /// The complete upstream response was committed to the response log.
    case committed
    /// The response was served from the response log while the replay window
    /// was open.
    case replayed
    /// The suffix of a committed response was served after a resume request.
    case resumed
}

/// Bounded account of one model response's terminal delivery outcome.
public struct GatewayResponseReceipt: Equatable, Sendable {
    /// Content-addressed request key (`ResponseLog.cacheKey`).
    public var key: String
    /// HTTP status of the recorded response.
    public var status: Int
    /// Size of the complete recorded response body in bytes.
    public var bodyBytes: Int
    /// Which terminal path delivered the response.
    public var disposition: GatewayResponseDisposition

    public init(key: String,
                status: Int,
                bodyBytes: Int,
                disposition: GatewayResponseDisposition) {
        self.key = key
        self.status = status
        self.bodyBytes = bodyBytes
        self.disposition = disposition
    }
}

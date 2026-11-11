// SPDX-License-Identifier: MIT
// spec/bot/v1/mcp-endpoint.md §2: a long native tool call streams `: keepalive` comments
// through the host egress. The credential sanitizer must forward each one as its own event,
// byte for byte, as soon as it is complete, or the Worker's 60 s idle limit still fires.

import Foundation
import XCTest
@testable import PhoneDSHGateway

final class SensitiveSSEKeepaliveTests: XCTestCase {
    private let keepalive = Data(": keepalive\n\n".utf8)

    func testKeepaliveCommentsPassImmediatelyAndUnchanged() {
        let sanitizer = SensitiveSSESanitizer(secrets: ["bot-bearer-secret-123456"])
        XCTAssertEqual(sanitizer.consume(keepalive), [keepalive])
        XCTAssertEqual(sanitizer.consume(keepalive + keepalive), [keepalive, keepalive])
        XCTAssertFalse(sanitizer.overflowed)
    }

    func testMessageAfterKeepalivesStillHasTheSecretRedacted() throws {
        let secret = "bot-bearer-secret-123456"
        let sanitizer = SensitiveSSESanitizer(secrets: [secret])
        let message = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"echo\":\"\(secret)\"}}\n\n".utf8)
        let events = sanitizer.consume(keepalive + message)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0], keepalive)
        let forwarded = String(decoding: events[1], as: UTF8.self)
        XCTAssertFalse(forwarded.contains(secret))
        XCTAssertTrue(forwarded.hasPrefix("event: message\ndata: "))
    }
}

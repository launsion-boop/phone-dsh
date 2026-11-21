// SPDX-License-Identifier: MIT
#if DEBUG
import XCTest
@testable import PhoneDSHLoopback

final class DebugChannelCodecTests: XCTestCase {
    private func parse(_ text: String) -> DebugChannelParse { DebugChannelCodec.parse(Data(text.utf8)) }

    func testParsesRequestQueryHeadersAndBody() {
        let body = #"{"a":1}"#
        guard case .request(let r) = parse("POST /chat?bot=agent-1&wait=30%2B HTTP/1.1\r\nHost: x\r\nX-PDSH-Debug-Token: tok\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)") else { return XCTFail("parse") }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/chat")
        XCTAssertEqual(r.query, ["bot": "agent-1", "wait": "30+"])
        XCTAssertEqual(r.headers["x-pdsh-debug-token"], "tok")
        XCTAssertEqual(String(data: r.body, encoding: .utf8), body)
    }

    func testIncompleteAndMalformedInput() {
        XCTAssertEqual(parse("GET /bots HTTP/1.1\r\nHost: x\r\n"), .needMore)
        XCTAssertEqual(parse("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc"), .needMore)
        guard case .invalid = parse("GARBAGE\r\n\r\n") else { return XCTFail("bad request line") }
        guard case .invalid = parse("GET /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n") else { return XCTFail("negative length") }
        guard case .invalid = parse("GET /x HTTP/1.1\r\nContent-Length: 9999999\r\n\r\n") else { return XCTFail("oversize body") }
        guard case .invalid = parse("GET x HTTP/1.1\r\n\r\n") else { return XCTFail("path must start with /") }
    }

    func testRequestWithoutOrWithWrongTokenIsRejected() {
        XCTAssertEqual(DebugChannelCodec.authorize(headers: [:], token: "secret", remoteHost: "192.168.1.5"), 401)
        XCTAssertEqual(DebugChannelCodec.authorize(headers: [DebugChannelCodec.tokenHeader: "wrong"], token: "secret", remoteHost: "192.168.1.5"), 401)
        XCTAssertEqual(DebugChannelCodec.authorize(headers: [DebugChannelCodec.tokenHeader: "secre"], token: "secret", remoteHost: "192.168.1.5"), 401)
        XCTAssertEqual(DebugChannelCodec.authorize(headers: [DebugChannelCodec.tokenHeader: "secret"], token: "", remoteHost: "192.168.1.5"), 401, "an empty server token never matches")
        XCTAssertEqual(DebugChannelCodec.authorize(headers: [DebugChannelCodec.tokenHeader: "secret"], token: "secret", remoteHost: "192.168.1.5"), 200)
    }

    func testOnlyPrivateAddressesAreAccepted() {
        for ok in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.9", "169.254.1.1", "::1",
                   "fd12:3456::1", "fc00::1", "fe80::1%en0", "::ffff:192.168.1.2", "[fd00::5]"] {
            XCTAssertTrue(DebugChannelCodec.isPrivate(host: ok), ok)
        }
        for bad in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.0.1", "11.0.0.1", "2001:db8::1", "::ffff:8.8.8.8",
                    "example.com", "", "1.2.3", "300.1.1.1", "fb00::1"] {
            XCTAssertFalse(DebugChannelCodec.isPrivate(host: bad), bad)
        }
        XCTAssertEqual(DebugChannelCodec.authorize(headers: [DebugChannelCodec.tokenHeader: "secret"], token: "secret", remoteHost: "8.8.8.8"), 403)
    }

    func testResponseFraming() {
        let data = DebugChannelCodec.response(status: 401, json: Data("{}".utf8))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("content-length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
    }
}
#endif

// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

final class TonoLinkRelayHTTPTests: XCTestCase {
    func testParsesHeadAndBodyOffset() {
        let raw = Data("POST /board/cmd?x=1 HTTP/1.1\r\nHost: phone\r\nContent-Length: 4\r\nAuthorization: Bearer t\r\n\r\ninfo".utf8)
        guard case .complete(let request, let length, let start) = TonoLinkRelayHTTP.parseHead(raw) else { return XCTFail() }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/board/cmd")
        XCTAssertEqual(request.query, "x=1")
        XCTAssertEqual(request.headers["authorization"], "Bearer t")
        XCTAssertEqual(length, 4)
        XCTAssertEqual(raw[start...], Data("info".utf8))
        XCTAssertEqual(request.queryValue("x"), "1")
    }

    func testIncompleteAndInvalidHeads() {
        XCTAssertEqual(TonoLinkRelayHTTP.parseHead(Data("GET / HTTP/1.1\r\nHost: a\r\n".utf8)), .incomplete)
        XCTAssertEqual(TonoLinkRelayHTTP.parseHead(Data("GARBAGE\r\n\r\n".utf8)), .invalid("bad request line"))
        XCTAssertEqual(TonoLinkRelayHTTP.parseHead(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)),
                       .invalid("chunked bodies are not supported; send Content-Length"))
        XCTAssertEqual(TonoLinkRelayHTTP.parseHead(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)), .invalid("bad Content-Length"))
        XCTAssertEqual(TonoLinkRelayHTTP.parseHead(Data(repeating: 65, count: TonoLinkRelayHTTP.maxHead + 1)), .invalid("header too large"))
    }

    func testEncodesResponse() {
        let text = String(decoding: TonoLinkRelayHTTP.encode(TonoLinkRelayResponse(status: 404, contentType: "text/plain", body: Data("no".utf8))), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 "))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nno"))
    }

    func testSecondsKeepWholeSeconds() {
        XCTAssertEqual(TonoLinkRelay.seconds(.milliseconds(77_612)), 77.612)
        XCTAssertEqual(TonoLinkRelay.seconds(.seconds(2)), 2)
    }

}

@MainActor final class RecordingHTTP: TonoLinkHTTP {
    var requests: [(URLRequest, Data?)] = []
    var reply: (Int, Data) = (200, Data("ok\n".utf8))
    func send(_ request: URLRequest, body: Data?, progress: ((Double) -> Void)?) async throws -> (status: Int, body: Data) {
        requests.append((request, body)); return reply
    }
}

@MainActor final class TonoLinkRelayRoutingTests: XCTestCase {
    var http: RecordingHTTP!, board: SimBLEBoard!

    func makeRelay() -> TonoLinkRelay {
        http = RecordingHTTP(); board = SimBLEBoard()
        let board = board!, http = http!
        return TonoLinkRelay(http: http,
                             makeBLE: { TonoLinkBLEDebug(link: board, clock: SimClock(), firstSeq: 1) },
                             makeUSB: { TonoLinkUSBOTA(ctrl: board, network: SimNetwork(SimBoard()), http: http, clock: SimClock()) })
    }

    func request(_ method: String, _ path: String, query: String = "", body: String = "", headers: [String: String] = [:]) -> TonoLinkRelayRequest {
        TonoLinkRelayRequest(method: method, path: path, query: query, headers: headers, body: Data(body.utf8))
    }

    func testServesWithoutCredentials() async throws {
        let relay = makeRelay()
        let response = await relay.handle(TonoLinkRelayRequest(method: "GET", path: "/relay"))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertTrue(http.requests.isEmpty, "status does not touch the board")
    }

    func testProxiesToTheBoardKeepingOnlyBoardHeaders() async throws {
        let relay = makeRelay()
        let response = await relay.handle(request("POST", "/board/cmd", body: "info",
                                                  headers: ["x-crc32": "0000abcd", "cookie": "c", "authorization": "Bearer x"]))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.contentType, "text/plain; charset=utf-8")
        let (forwarded, body) = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(forwarded.url?.absoluteString, "http://192.168.247.1:8767/cmd")
        XCTAssertEqual(forwarded.httpMethod, "POST")
        XCTAssertEqual(body, Data("info".utf8))
        XCTAssertEqual(forwarded.value(forHTTPHeaderField: "X-CRC32"), "0000abcd")
        XCTAssertNil(forwarded.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(forwarded.value(forHTTPHeaderField: "Cookie"))

        http.reply = (200, Data(#"{"ok":true}"#.utf8))
        let logs = await relay.handle(request("GET", "/board/logs", query: "since=12"))
        XCTAssertEqual(logs.contentType, "application/json")
        XCTAssertEqual(http.requests.last?.0.url?.absoluteString, "http://192.168.247.1:8767/logs?since=12")
        XCTAssertNil(http.requests.last?.1)
    }

    func testBLERoutes() async throws {
        let relay = makeRelay()
        let con = await relay.handle(request("POST", "/ble/con", body: "info\n"))
        XCTAssertEqual(con.status, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: con.body) as? [String: [String]], ["output": ["fw 0.1.0-m21", "slot ota_0"]])
        let log = await relay.handle(request("GET", "/ble/log", query: "since=40"))
        let page = try XCTUnwrap(try JSONSerialization.jsonObject(with: log.body) as? [String: Any])
        XCTAssertEqual(page["last"] as? Int, 42)
        XCTAssertEqual(page["lines"] as? [String], ["41 I (1) a", "42 I (2) b"])
        XCTAssertEqual(board.log.filter { $0 == "disconnect" }.count, 2, "each BLE route releases the link")
    }

    func testBLEOTARouteFlashesAndReportsTiming() async throws {
        let relay = makeRelay()
        let image = makeImage(version: "dbg", sha: 0x77, size: 20_000)
        let response = await relay.handle(TonoLinkRelayRequest(method: "POST", path: "/ble/ota", body: image))
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(report["bytes"] as? Int, 20_000)
        XCTAssertNotNil(report["transfer_s"])
        XCTAssertEqual(board.running, image)
        XCTAssertTrue(board.confirmed)
    }

    func testBadImageAndUnknownRoute() async {
        let relay = makeRelay()
        let bad = await relay.handle(request("POST", "/ble/ota", body: "not an image"))
        XCTAssertEqual(bad.status, 502)
        let unknown = await relay.handle(request("GET", "/nope"))
        XCTAssertEqual(unknown.status, 404)
    }
}

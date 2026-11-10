// SPDX-License-Identifier: MIT
// Request timing evidence for boot-timings.log. The lines must stay useful to
// a resume diagnosis while never carrying a query, a header or a body.

import Foundation
import XCTest
@testable import PhoneDSHLoopback

private final class DiagnosticLineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ManualMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(seconds: TimeInterval) {
        lock.lock()
        current += seconds
        lock.unlock()
    }
}

final class LoopbackRequestDiagnosticsTests: XCTestCase {
    func testSlowRequestLineIsQueryFreeAndCarriesNoHeaders() {
        let lines = DiagnosticLineBox()
        let clock = ManualMonotonicClock()
        let diagnostics = LoopbackRequestDiagnostics(
            sink: { lines.append($0) },
            now: { clock.now() },
            slowRequestMilliseconds: 2_000,
            inflightReportMilliseconds: 10_000)
        let observation = diagnostics.begin(
            method: "POST",
            path: "/v1/http?token=secret&api_key=sk-live#fragment")
        clock.advance(seconds: 2.345)
        observation.finish(status: 200)
        XCTAssertEqual(lines.lines,
                       ["slow-request method=POST path=/v1/http status=200 elapsed_ms=2345"])
        XCTAssertFalse(lines.lines.joined().contains("secret"))
        XCTAssertFalse(lines.lines.joined().contains("token"))
        XCTAssertFalse(lines.lines.joined().contains("api_key"))
        XCTAssertFalse(lines.lines.joined().contains("authorization"))
    }

    func testFastRequestIsSilentAndFinishIsIdempotent() {
        let lines = DiagnosticLineBox()
        let clock = ManualMonotonicClock()
        let diagnostics = LoopbackRequestDiagnostics(
            sink: { lines.append($0) },
            now: { clock.now() })
        let observation = diagnostics.begin(method: "GET", path: "/static/index.html")
        clock.advance(seconds: 1.999)
        observation.finish(status: 200)
        observation.finish(status: 200)
        XCTAssertTrue(lines.lines.isEmpty)
    }

    func testInflightLineRepeatsAndStopsAfterFinish() {
        let lines = DiagnosticLineBox()
        let clock = ManualMonotonicClock()
        let diagnostics = LoopbackRequestDiagnostics(
            sink: { lines.append($0) },
            now: { clock.now() },
            slowRequestMilliseconds: 60_000,
            inflightReportMilliseconds: 10_000)
        let observation = diagnostics.begin(method: "GET", path: "/v1/http")
        clock.advance(seconds: 10)
        XCTAssertTrue(observation.reportInflightIfDue())
        clock.advance(seconds: 10)
        XCTAssertTrue(observation.reportInflightIfDue())
        observation.finish(status: 200)
        XCTAssertFalse(observation.reportInflightIfDue())
        XCTAssertEqual(lines.lines, [
            "inflight method=GET path=/v1/http elapsed_ms=10000",
            "inflight method=GET path=/v1/http elapsed_ms=20000",
        ])
    }

    func testTickerReportsAnUntouchedInflightRequest() async throws {
        let lines = DiagnosticLineBox()
        let diagnostics = LoopbackRequestDiagnostics(
            sink: { lines.append($0) },
            slowRequestMilliseconds: 60_000,
            inflightReportMilliseconds: 20)
        let observation = diagnostics.begin(method: "GET", path: "/v1/http")
        defer { observation.finish(status: 0) }
        let deadline = Date().addingTimeInterval(2)
        while lines.lines.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let line = try XCTUnwrap(lines.lines.first)
        XCTAssertTrue(line.hasPrefix("inflight method=GET path=/v1/http elapsed_ms="),
                      "unexpected line: \(line)")
    }

    func testLoopbackServerWritesTheServedPathAndStatus() async throws {
        let lines = DiagnosticLineBox()
        let diagnostics = LoopbackRequestDiagnostics(
            sink: { lines.append($0) },
            now: { ProcessInfo.processInfo.systemUptime },
            slowRequestMilliseconds: 0,
            inflightReportMilliseconds: 10_000)
        let server = LoopbackServer(requestDiagnostics: diagnostics)
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }
        let client = TestHTTPClient(endpoint: endpoint)
        let (http, _) = try await client.send("GET", "/v1/hello")
        XCTAssertEqual(http.statusCode, 200)
        let line = try XCTUnwrap(lines.lines.first)
        XCTAssertTrue(line.hasPrefix("slow-request method=GET path=/v1/hello status=200 elapsed_ms="),
                      "unexpected line: \(line)")
        XCTAssertEqual(lines.lines.count, 1)
        XCTAssertFalse(lines.lines.joined().contains(endpoint.token))
    }
}

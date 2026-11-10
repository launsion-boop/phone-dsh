// SPDX-License-Identifier: MIT
// Upstream timing evidence and resume-time session replacement.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHGateway

private final class GatewayDiagnosticLineBox: @unchecked Sendable {
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

private final class GatewaySessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLSession] = []

    func append(_ session: URLSession) {
        lock.lock()
        storage.append(session)
        lock.unlock()
    }

    var sessions: [URLSession] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class GatewayUpstreamDiagnosticsTests: XCTestCase {
    private let requestPathSecret = "/v1/messages?api_key=sk-never-log"

    private func coordinator(
        lines: GatewayDiagnosticLineBox,
        slowMilliseconds: Double
    ) -> GatewaySessionCoordinator {
        let diagnostics = GatewayUpstreamDiagnostics(
            sink: { lines.append($0) },
            slowRequestMilliseconds: slowMilliseconds)
        return GatewaySessionCoordinator(
            allowedHosts: [GatewayHostRule(rawValue: "127.0.0.1")!],
            diagnostics: diagnostics)
    }

    private static func drain(_ attempt: UpstreamAttempt) async {
        for await event in attempt.events {
            if case .finished = event { return }
        }
    }

    private func waitForFinish(_ attempt: UpstreamAttempt,
                               timeout: TimeInterval = 5) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await Self.drain(attempt) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw GatewayTestError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    func testSlowLineCarriesHostTimingAndStatusOnly() async throws {
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200,
                     headers: ["Content-Type": "text/event-stream"],
                     chunks: [Data("data: ok\n\n".utf8)],
                     delay: 0.15)
        }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let lines = GatewayDiagnosticLineBox()
        let coordinator = self.coordinator(lines: lines, slowMilliseconds: 50)
        _ = coordinator.makeSession(timeout: 5)
        var request = URLRequest(url: URL(
            string: "http://127.0.0.1:\(port)\(requestPathSecret)")!)
        request.httpMethod = "POST"
        let attempt = coordinator.begin(request)
        try await waitForFinish(attempt)
        let text = lines.lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("gateway-upstream host=127.0.0.1"), "unexpected: \(text)")
        XCTAssertTrue(text.contains("elapsed_ms="), "unexpected: \(text)")
        XCTAssertTrue(text.contains("ttfb_ms="), "unexpected: \(text)")
        XCTAssertTrue(text.contains("status=200"), "unexpected: \(text)")
        XCTAssertFalse(text.contains("/v1/messages"), "the path must not be logged: \(text)")
        XCTAssertFalse(text.contains("api_key"), "the query must not be logged: \(text)")
        XCTAssertFalse(text.contains("sk-never-log"), "the query must not be logged: \(text)")
        coordinator.invalidate()
    }

    func testErrorLineCarriesAURLerrorCodeAndNoPath() async throws {
        let server = try MockUpstreamServer { _ in .abort(partial: Data()) }
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let lines = GatewayDiagnosticLineBox()
        let coordinator = self.coordinator(lines: lines, slowMilliseconds: 60_000)
        _ = coordinator.makeSession(timeout: 5)
        let request = URLRequest(url: URL(
            string: "http://127.0.0.1:\(port)\(requestPathSecret)")!)
        let attempt = coordinator.begin(request)
        try await waitForFinish(attempt)
        let text = lines.lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("gateway-upstream host=127.0.0.1"), "unexpected: \(text)")
        XCTAssertTrue(text.contains("ttfb_ms=none"), "unexpected: \(text)")
        XCTAssertTrue(text.contains("status=none"), "unexpected: \(text)")
        XCTAssertTrue(text.contains("error=URLError:"), "unexpected: \(text)")
        XCTAssertFalse(text.contains("/v1/messages"), "the path must not be logged: \(text)")
        XCTAssertFalse(text.contains("api_key"), "the query must not be logged: \(text)")
        coordinator.invalidate()
    }

    func testWaitingForConnectivityLogsOnlyTheHost() throws {
        let lines = GatewayDiagnosticLineBox()
        let coordinator = self.coordinator(lines: lines, slowMilliseconds: 60_000)
        let session = coordinator.makeSession(timeout: 1)
        let task = session.dataTask(with: URL(
            string: "https://api.example.com/v1/models?api_key=secret")!)
        coordinator.urlSession(session, taskIsWaitingForConnectivity: task)
        task.cancel()
        XCTAssertEqual(lines.lines,
                       ["gateway waiting-for-connectivity host=api.example.com"])
        coordinator.invalidate()
    }

    func testFormattingRejectsQueryAndControlCharacters() {
        let slow = GatewayUpstreamDiagnostics.slowLine(
            host: "API.Example.com\n",
            elapsedMilliseconds: 2_100,
            firstByteMilliseconds: 120,
            status: 200)
        XCTAssertEqual(slow,
                       "gateway-upstream host=api.example.com elapsed_ms=2100 ttfb_ms=120 status=200")
        let error = GatewayUpstreamDiagnostics.errorLine(
            host: "api.example.com",
            elapsedMilliseconds: 60_000,
            firstByteMilliseconds: nil,
            status: nil,
            error: URLError(.timedOut))
        XCTAssertEqual(error,
                       "gateway-upstream host=api.example.com elapsed_ms=60000 "
                       + "ttfb_ms=none status=none error=URLError:-1001")
    }

    func testResumeReplacesTheSessionAndInvalidatesTheOldOne() throws {
        let invalidated = GatewaySessionBox()
        let coordinator = GatewaySessionCoordinator(
            allowedHosts: [],
            sessionInvalidator: { invalidated.append($0) })
        let old = coordinator.makeSession(timeout: 1)
        let oldLocal = try XCTUnwrap(coordinator.localSession())
        let replacement = try XCTUnwrap(coordinator.replaceSession(timeout: 2))
        let replacementLocal = try XCTUnwrap(coordinator.localSession())
        XCTAssertFalse(old === replacement)
        XCTAssertFalse(oldLocal === replacementLocal)
        XCTAssertTrue(coordinator.session() === replacement)
        XCTAssertFalse(coordinator.isShutDown)
        // The external and loopback pools are independent: both stale pools
        // are invalidated so neither survives a resume.
        XCTAssertEqual(invalidated.sessions.count, 2)
        XCTAssertTrue(invalidated.sessions.contains { $0 === old })
        XCTAssertTrue(invalidated.sessions.contains { $0 === oldLocal })
        coordinator.invalidate()
        XCTAssertTrue(coordinator.isShutDown)
        XCTAssertNil(coordinator.replaceSession(timeout: 2),
                     "a shut-down gateway must not install another session")
        XCTAssertEqual(invalidated.sessions.count, 4)
        XCTAssertTrue(invalidated.sessions.contains { $0 === replacement })
        XCTAssertTrue(invalidated.sessions.contains { $0 === replacementLocal })
    }

    func testModelGatewaySwapsItsSessionForResume() async throws {
        var configuration = ModelGatewayConfiguration()
        configuration.allowedUpstreamHosts = []
        let gateway = ModelGateway(
            configuration: configuration,
            credentialProvider: StaticCredentialProvider([:]),
            upstreamDiagnostics: GatewayUpstreamDiagnostics(sink: { _ in }))
        let before = try XCTUnwrap(gateway.currentSessionForTesting())
        await gateway.rebuildSessionForResume()
        let after = try XCTUnwrap(gateway.currentSessionForTesting())
        XCTAssertFalse(before === after)
        await gateway.rebuildSessionForResume()
        let second = try XCTUnwrap(gateway.currentSessionForTesting())
        XCTAssertFalse(after === second)
        await gateway.shutdown()
    }
}

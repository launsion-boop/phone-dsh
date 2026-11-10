// SPDX-License-Identifier: MIT
// P05: a closed loopback upstream is a dead endpoint, not "the radio is down".
// The gateway must not wait for connectivity against the App's own listener and
// must fail a refused connection well inside the Worker's boot/resume budget.
// External upstreams keep the existing wait-for-connectivity policy.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHGateway

private final class GatewayFastFailLineBox: @unchecked Sendable {
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

final class GatewayLocalUpstreamFastFailTests: XCTestCase {
    func testLoopbackSessionDoesNotWaitAndUsesShortRequestTimeout() throws {
        let coordinator = GatewaySessionCoordinator(
            allowedHosts: [GatewayHostRule(rawValue: "127.0.0.1")!])
        defer { coordinator.invalidate() }
        _ = coordinator.makeSession(timeout: 60)

        let external = try XCTUnwrap(coordinator.session())
        XCTAssertTrue(external.configuration.waitsForConnectivity)
        XCTAssertEqual(external.configuration.timeoutIntervalForRequest, 60)
        XCTAssertEqual(external.configuration.timeoutIntervalForResource, 600)

        let local = try XCTUnwrap(coordinator.localSession())
        XCTAssertFalse(local.configuration.waitsForConnectivity)
        XCTAssertEqual(local.configuration.timeoutIntervalForRequest, 30)
        // A streaming loopback body may still run long; only the idle bound is
        // shortened.
        XCTAssertEqual(local.configuration.timeoutIntervalForResource, 600)
    }

    func testRefusedLoopbackUpstreamFailsInsideTwoSecondsWithoutWaiting() async throws {
        let lines = GatewayFastFailLineBox()
        let diagnostics = GatewayUpstreamDiagnostics(
            sink: { lines.append($0) },
            slowRequestMilliseconds: 2_000)
        let coordinator = GatewaySessionCoordinator(
            allowedHosts: [GatewayHostRule(rawValue: "127.0.0.1")!],
            diagnostics: diagnostics)
        defer { coordinator.invalidate() }
        _ = coordinator.makeSession(timeout: 60)

        // Port 1 is not a bound loopback service. With the old session this
        // request spent the resource timeout waiting for connectivity.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/v1/http")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"method":"tools/list"}"#.utf8)
        let started = ProcessInfo.processInfo.systemUptime
        let error = try await failure(of: coordinator.begin(request))
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(elapsed, 2, "a refused loopback connection must fail fast")
        XCTAssertTrue(error is URLError)
        let text = lines.lines.joined(separator: "\n")
        XCTAssertFalse(text.contains("waiting-for-connectivity"),
                       "the local pool must never enter waiting-for-connectivity: \(text)")
        XCTAssertTrue(text.contains("host=127.0.0.1"), "unexpected: \(text)")
        XCTAssertTrue(text.contains("error=URLError:"), "unexpected: \(text)")
    }

    func testModelGatewayBuildsTheLocalPoolFromTheSameConfiguration() async throws {
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["127.0.0.1"],
            upstreamRequestTimeout: 60)
        let gateway = ModelGateway(configuration: configuration,
                                  credentialProvider: StaticCredentialProvider([:]))
        XCTAssertNotNil(gateway.currentSessionForTesting())
        let local = try XCTUnwrap(gateway.currentLocalSessionForTesting())
        XCTAssertFalse(local.configuration.waitsForConnectivity)
        XCTAssertEqual(local.configuration.timeoutIntervalForRequest, 30)
        await gateway.shutdown()
    }

    // MARK: - helpers

    private func failure(of attempt: UpstreamAttempt) async throws -> Error {
        try await withThrowingTaskGroup(of: Error.self) { group in
            group.addTask {
                var lastError: Error?
                for await event in attempt.events {
                    switch event {
                    case .finished(let error):
                        lastError = error
                    default:
                        break
                    }
                }
                guard let lastError else {
                    throw GatewayTestError.timedOut
                }
                return lastError
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw GatewayTestError.timedOut
            }
            guard let error = try await group.next() else {
                throw GatewayTestError.timedOut
            }
            group.cancelAll()
            return error
        }
    }
}

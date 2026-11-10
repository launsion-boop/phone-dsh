// SPDX-License-Identifier: MIT
// Bot MCP listener self-healing: iOS can reap the loopback socket while the
// App and the Worker stay alive. ensureListening() must restore the same port
// when possible (URLs already handed out stay valid) and announce a new port
// only when the old one cannot be rebound.

import XCTest
import Network
@testable import PhoneDSHBot

private enum ListenerRecoveryTestError: Error {
    case timedOut
}

final class BotMCPListenerRecoveryTests: XCTestCase {
    func testHealthyListenerIsReportedWithoutRebinding() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime),
                                      token: "healthy-token")
        let url = try await server.start()
        defer { server.stop() }
        XCTAssertTrue(server.isHealthy)

        let result = await server.ensureListening()
        guard case .listening(let probed) = result else {
            return XCTFail("expected listening, got \(result)")
        }
        XCTAssertEqual(probed, url)
        XCTAssertEqual(server.url, url)
        XCTAssertFalse(result.didRebind)
    }

    func testCancelledListenerRebindsTheSamePort() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime),
                                      token: "same-port-token")
        let original = try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(original.port)
        let listener = try XCTUnwrap(server.listenerForTesting)

        // Observe the state callback before cancelling, exactly as a system
        // reap would.
        listener.cancel()
        try await waitUntil { !server.isHealthy }

        let result = await server.ensureListening()
        guard case .rebound(let recovered) = result else {
            return XCTFail("expected rebound, got \(result)")
        }
        XCTAssertEqual(recovered.port, port, "the old port must be preferred")
        XCTAssertEqual(recovered.path, "/mcp")
        XCTAssertEqual(server.url?.port, port)
        XCTAssertTrue(server.isHealthy)

        // The endpoint really serves again: a full MCP round trip over the
        // recovered listener, not just a socket that accepted a connection.
        let status = try await post(server: server, url: recovered)
        XCTAssertEqual(status, 200)
    }

    func testOccupiedOldPortGetsANewPortAndNotifies() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime),
                                      token: "new-port-token")
        let original = try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(original.port)
        let listener = try XCTUnwrap(server.listenerForTesting)

        let notifications = URLBox()
        server.onEndpointChange = { notifications.append($0) }

        listener.cancel()
        try await waitUntil { !server.isHealthy }

        let blocker = try PortBlocker(port: UInt16(clamping: port))
        try await blocker.start()
        defer { blocker.stop() }

        let result = await server.ensureListening()
        guard case .rebound(let recovered) = result else {
            return XCTFail("expected rebound, got \(result)")
        }
        XCTAssertNotEqual(recovered.port, port)
        XCTAssertEqual(server.url, recovered)
        XCTAssertEqual(notifications.values, [recovered])
        let status = try await post(server: server, url: recovered)
        XCTAssertEqual(status, 200)

        // The healed listener is stable: no second rebind, no second notice.
        let again = await server.ensureListening()
        XCTAssertEqual(again, .listening(recovered))
        XCTAssertEqual(notifications.values, [recovered])
    }

    func testStopIsNotTreatedAsAFailureAndEnsureRefuses() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let server = BotMCPHTTPServer(handler: BotMCPHandler(runtime: fixture.runtime),
                                      token: "stop-token")
        _ = try await server.start()
        let notifications = URLBox()
        server.onEndpointChange = { notifications.append($0) }
        server.stop()
        XCTAssertFalse(server.isHealthy)
        let result = await server.ensureListening()
        guard case .unavailable = result else {
            return XCTFail("expected unavailable after stop, got \(result)")
        }
        XCTAssertTrue(notifications.values.isEmpty)
    }

    // MARK: - helpers

    private func post(server: BotMCPHTTPServer, url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try BotJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("ping"),
        ]).encoded()
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw ListenerRecoveryTestError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class PortBlocker: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "phone-dsh.bot.test.port-blocker")

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: BotMCPHTTPError.startFailed("blocker cancelled"))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private extension URL {
    var port: Int? { URLComponents(url: self, resolvingAgainstBaseURL: false)?.port }
}

// SPDX-License-Identifier: MIT
// PhoneDSHHost replay-window wiring and response-receipt regression.
//
// The host, not a test, owns the gateway replay window: it is open exactly
// while the controller is Recovering, so a response committed before a planned
// restart or WebContent termination is replayed after the Worker comes back
// instead of being fetched from the upstream a second time.

import Foundation
import Network
import XCTest
@testable import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHController
import PhoneDSHEngine
import PhoneDSHGateway

final class PhoneDSHHostReplayWindowTests: XCTestCase {
    // MARK: - Fixtures

    private func makeConfiguration(_ fixture: FacadeFixture,
                                   upstream: HostReplayUpstream,
                                   drainDeadline: TimeInterval = 1)
        throws -> PhoneDSHConfiguration {
        PhoneDSHConfiguration(
            workspaceRoot: fixture.workspace,
            token: "replay-window-token",
            origin: try XCTUnwrap(URL(string: "http://127.0.0.1:1")),
            bundle: fixture.bundle,
            egressAllowHosts: ["127.0.0.1:\(upstream.port)"],
            credentialProvider: StaticCredentialProvider([
                CredentialScope(service: "127.0.0.1"):
                    Credential(kind: .bearer, value: "test-credential"),
            ]),
            drainDeadline: drainDeadline)
    }

    private func makeHost(_ fixture: FacadeFixture,
                          engine: MockEngine,
                          upstream: HostReplayUpstream) throws -> PhoneDSHHost {
        PhoneDSHHost(configuration: try makeConfiguration(fixture, upstream: upstream),
                     engineFactory: { _ in engine })
    }

    @discardableResult
    private func sendModelRequest(engine: MockEngine,
                                  target: URL,
                                  body: Data) async throws -> (status: Int?, body: Data) {
        let configuration = try XCTUnwrap(engine.lastConfiguration)
        var request = URLRequest(url: configuration.origin.appendingPathComponent("v1/http"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue(target.absoluteString, forHTTPHeaderField: "X-PDSH-Target-URL")
        request.setValue("POST", forHTTPHeaderField: "X-PDSH-Target-Method")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode, data)
    }

    private func entryMetadata(workspace: URL, key: String) throws -> [String: Any] {
        let url = workspace.appendingPathComponent("response-log")
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("entry.json", isDirectory: false)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: - Recovering window

    func testReplayWindowIsOpenWhileRecoveringAndClosedAfterHello() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let upstream = try HostReplayUpstream()
        _ = try await upstream.start()
        defer { upstream.stop() }
        let engine = MockEngine(worker: MockWorker())
        engine.setBootDelay(0.5)
        let host = try makeHost(fixture, engine: engine, upstream: upstream)

        let start = Task { try await host.start() }
        try await waitUntil { await host.replayWindowIsOpenForTesting() }
        let openDuringRecovery = await host.replayWindowIsOpenForTesting()
        XCTAssertTrue(openDuringRecovery,
                      "a boot is Recovering until the Worker HELLO and lease verify")
        try await start.value

        let state = await host.state
        XCTAssertEqual(state, .running)
        try await waitUntil { !(await host.replayWindowIsOpenForTesting()) }
        let openWhileRunning = await host.replayWindowIsOpenForTesting()
        XCTAssertFalse(openWhileRunning,
                       "Running must not serve a committed response as a replay")
        try await host.stop()
    }

    // MARK: - Planned restart replay

    func testPlannedRestartReopensTheWindowAndReplaysTheCommittedResponse() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let upstream = try HostReplayUpstream(body: Data(#"{"answer":42}"#.utf8))
        _ = try await upstream.start()
        defer { upstream.stop() }
        let engine = MockEngine(worker: MockWorker())
        engine.setBootDelay(0.6)
        let host = try makeHost(fixture, engine: engine, upstream: upstream)
        let events = GatewayEventRecorder(host.eventStream())
        defer { events.stop() }
        try await host.start()
        let openWhileRunning = await host.replayWindowIsOpenForTesting()
        XCTAssertFalse(openWhileRunning)

        let target = URL(string: "http://127.0.0.1:\(upstream.port)/v1/chat/completions")!
        let body = Data(#"{"model":"m","messages":[]}"#.utf8)
        let live = try await sendModelRequest(engine: engine, target: target, body: body)
        XCTAssertEqual(live.status, 200)
        XCTAssertEqual(live.body, upstream.body)
        try await waitUntil { events.receipts.count == 1 }
        let firstDisposition = events.receipts.first?.disposition
        XCTAssertEqual(firstDisposition, GatewayResponseDisposition.committed)
        XCTAssertEqual(upstream.requestCount, 1)

        let restart = Task { try await host.plannedRestart(reason: "replay-window") }
        try await waitUntil { await host.replayWindowIsOpenForTesting() }
        let recovering = await host.diagnostics()
        XCTAssertEqual(recovering.hostState, .recovering)
        let openDuringRecovery = await host.replayWindowIsOpenForTesting()
        XCTAssertTrue(openDuringRecovery)

        // The Worker is still booting (the engine pauses before HELLO), which
        // is exactly the window in which a retried model request must be
        // answered from the durable response log.
        let replayed = try await sendModelRequest(engine: engine, target: target, body: body)
        XCTAssertEqual(replayed.status, 200)
        XCTAssertEqual(replayed.body, upstream.body)
        XCTAssertEqual(upstream.requestCount, 1,
                       "a Recovering replay must never contact the upstream again")

        try await waitUntil { events.receipts.count == 2 }
        let dispositions = events.receipts.map(\.disposition)
        XCTAssertEqual(dispositions, [.committed, .replayed])
        XCTAssertEqual(events.receipts.filter { $0.disposition == .replayed }.count, 1)
        let key = try XCTUnwrap(events.receipts.last?.key)
        let metadata = try entryMetadata(workspace: fixture.workspace, key: key)
        XCTAssertEqual((metadata["deliveryCount"] as? NSNumber)?.intValue, 1,
                       "the single entry directory proves the replayed delivery")

        try await restart.value
        let running = await host.state
        XCTAssertEqual(running, .running)
        try await waitUntil { !(await host.replayWindowIsOpenForTesting()) }
        let openAfterRestart = await host.replayWindowIsOpenForTesting()
        XCTAssertFalse(openAfterRestart)
        XCTAssertEqual(upstream.requestCount, 1)
        try await host.stop()
    }

    // MARK: - Termination recovery

    func testTerminationRecoveryReopensTheWindowBeforeTheWorkerReturns() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let upstream = try HostReplayUpstream()
        _ = try await upstream.start()
        defer { upstream.stop() }
        let engine = MockEngine(worker: MockWorker())
        engine.setBootDelay(0.5)
        let host = try makeHost(fixture, engine: engine, upstream: upstream)
        try await host.start()
        let openBeforeTermination = await host.replayWindowIsOpenForTesting()
        XCTAssertFalse(openBeforeTermination)

        engine.emit(.terminated(1))
        try await waitUntil { await host.replayWindowIsOpenForTesting() }
        let recovering = await host.diagnostics()
        XCTAssertEqual(recovering.hostState, .recovering,
                       "a WebContent termination re-enters Recovering")
        let openDuringRecovery = await host.replayWindowIsOpenForTesting()
        XCTAssertTrue(openDuringRecovery)

        try await waitUntil {
            let state = await host.state
            let replayWindowOpen = await host.replayWindowIsOpenForTesting()
            return state == .running && !replayWindowOpen
        }
        let openAfterRecovery = await host.replayWindowIsOpenForTesting()
        XCTAssertFalse(openAfterRecovery)
        try await host.stop()
    }
}

// MARK: - Host event recorder

/// Collects the bounded `gatewayResponse` receipts the host publishes on its
/// ordered event stream.
private final class GatewayEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GatewayResponseReceipt] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<PhoneDSHEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                guard case .gatewayResponse(let receipt) = event else { continue }
                self.lock.lock()
                self.storage.append(receipt)
                self.lock.unlock()
            }
        }
    }

    var receipts: [GatewayResponseReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Scripted upstream

/// Minimal HTTP/1.1 upstream on 127.0.0.1 for the host replay regression. It
/// answers every request with one full body and counts requests, so the test
/// can prove that a Recovering replay never reaches it.
private final class HostReplayUpstream: @unchecked Sendable {
    let body: Data
    private let queue = DispatchQueue(label: "phone-dsh.host-replay-upstream")
    private let listener: NWListener
    private let stateLock = NSLock()
    private var storedCount = 0
    private(set) var port: UInt16 = 0

    init(body: Data = Data(#"{"ok":true}"#.utf8)) throws {
        self.body = body
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                              port: .any)
        self.listener = try NWListener(using: parameters)
    }

    var requestCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedCount
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let once = UpstreamOnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = self.listener.port?.rawValue ?? 0
                    self.port = port
                    if once.claim() {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if once.claim() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: HostReplayUpstreamError.cancelled)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(on: connection, buffer: Data())
    }

    private func receiveHead(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.parse(connection: connection, buffer: buffer, headerEnd: headerEnd)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveHead(on: connection, buffer: buffer)
            }
        }
    }

    private func parse(connection: NWConnection, buffer: Data,
                       headerEnd: Range<Data.Index>) {
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let text = String(data: headerData, encoding: .utf8) else {
            connection.cancel()
            return
        }
        var contentLength = 0
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            contentLength = Int(line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let received = Data(buffer[headerEnd.upperBound...])
        if received.count >= contentLength {
            deliver(connection: connection, body: received)
        } else {
            receiveBody(connection: connection, body: received,
                        contentLength: contentLength)
        }
    }

    private func receiveBody(connection: NWConnection, body: Data,
                             contentLength: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var body = body
            if let data { body.append(data) }
            if body.count >= contentLength || isComplete || error != nil {
                self.deliver(connection: connection, body: body)
            } else {
                self.receiveBody(connection: connection, body: body,
                                 contentLength: contentLength)
            }
        }
    }

    private func deliver(connection: NWConnection, body: Data) {
        stateLock.lock()
        storedCount += 1
        stateLock.unlock()
        let headers = [
            "connection": "close",
            "content-type": "application/json",
            "content-length": String(self.body.count),
        ]
        var text = "HTTP/1.1 200 OK\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        connection.send(content: Data(text.utf8) + self.body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

private enum HostReplayUpstreamError: Error {
    case cancelled
}

private final class UpstreamOnceFlag: @unchecked Sendable {
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

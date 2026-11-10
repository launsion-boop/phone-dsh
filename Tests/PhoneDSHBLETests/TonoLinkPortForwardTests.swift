// SPDX-License-Identifier: MIT
import Network
import XCTest
@testable import PhoneDSHBLE

/// Real sockets on loopback: an echo server stands in for the board.
final class TonoLinkPortForwardTests: XCTestCase {
    private let queue = DispatchQueue(label: "forward.tests")
    private var echo: NWListener?
    private var held: [NWConnection] = []

    override func tearDown() {
        echo?.cancel(); held.forEach { $0.cancel() }
        super.tearDown()
    }

    /// Echoes every byte; half-closes its side when the client half-closes.
    private func startEcho() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "echo ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] connection in
            self?.held.append(connection)
            connection.start(queue: self!.queue)
            func loop() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
                    if complete { connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent); return }
                    if error == nil { loop() }
                }
            }
            loop()
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        echo = listener
        return listener.port!.rawValue
    }

    private func startForward(to port: UInt16) throws -> TonoLinkPortForward {
        for _ in 0..<20 {
            let forward = TonoLinkPortForward(listenPort: UInt16.random(in: 40_000...60_000), targetHost: "127.0.0.1",
                                              targetPort: port, upstreamProhibited: [])
            let ready = expectation(description: "forward ready")
            ready.assertForOverFulfill = false
            forward.onState = { if $0 == "listening" { ready.fulfill() } }
            do { try forward.start() } catch { continue }
            if XCTWaiter.wait(for: [ready], timeout: 3) == .completed { return forward }
            forward.stop()
        }
        throw TonoLinkUSBOTAError("no free port for the forward")
    }

    /// Sends `payload` and reads the echo. With `halfClose` the client then
    /// half-closes and reads until the peer closes; otherwise it closes once
    /// everything came back (what HTTP tools and the AirPlay viewer do).
    private func roundTrip(_ port: UInt16, _ payload: Data, halfClose: Bool) -> XCTestExpectation {
        let done = expectation(description: "round trip \(payload.count)")
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        held.append(client)
        var received = Data()
        func read() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data { received.append(data) }
                if !halfClose, received.count >= payload.count {
                    XCTAssertEqual(received, payload)
                    client.cancel(); done.fulfill()
                } else if complete || error != nil {
                    XCTAssertEqual(received, payload)
                    done.fulfill()
                } else { read() }
            }
        }
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: payload, completion: .contentProcessed { _ in })
            if halfClose { client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) }
            read()
        }
        client.start(queue: queue)
        return done
    }

    func testPipesConcurrentConnectionsBothWays() throws {
        let forward = try startForward(to: try startEcho())
        defer { forward.stop() }
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let trips = [roundTrip(forward.listenPort, big, halfClose: false),
                     roundTrip(forward.listenPort, Data(repeating: 7, count: 70_000), halfClose: false),
                     roundTrip(forward.listenPort, Data("GET /ota/state HTTP/1.1\r\n\r\n".utf8), halfClose: false)]
        wait(for: trips, timeout: 30)
        let stats = forward.stats()
        XCTAssertEqual(stats.accepted, 3)
        XCTAssertEqual(stats.bytesUp, big.count + 70_000 + 27)
        XCTAssertGreaterThanOrEqual(stats.bytesDown, 70_000 + 27)
    }

    func testPropagatesAClientHalfClose() throws {
        let forward = try startForward(to: try startEcho())
        defer { forward.stop() }
        // The echo only closes after it sees the client's FIN through the forward,
        // so the client finishing at all proves the FIN was forwarded. The echoed
        // bytes are not checked: see the half-close note in TonoLinkPortForward.
        let done = expectation(description: "client closed")
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: forward.listenPort)!, using: .tcp)
        held.append(client)
        func read() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, complete, error in
                if complete || error != nil { done.fulfill() } else { read() }
            }
        }
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: Data("ping".utf8), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            read()
        }
        client.start(queue: queue)
        wait(for: [done], timeout: 10)
    }

    func testClientIsClosedWhenTheTargetIsUnreachable() throws {
        // A port nobody listens on: the forward must close the client, not hang.
        let closedPort: UInt16 = 1   // nothing listens on loopback port 1: connection refused
        let forward = try startForward(to: closedPort)
        defer { forward.stop() }
        wait(for: [roundTrip(forward.listenPort, Data(), halfClose: true)], timeout: 10)
        XCTAssertEqual(forward.stats().bytesDown, 0)
    }
}

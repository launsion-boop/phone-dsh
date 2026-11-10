// SPDX-License-Identifier: MIT
// Relay-client behavior: challenge auth, heartbeat timeout, ping/pong and
// origin mismatch handling.

import Foundation
import XCTest
@testable import PhoneDSHPCLink

private actor ScriptedRelay {
    enum Behavior: Sendable, Equatable {
        case timeoutHeartbeats
        case answerPing
        case wrongOrigin
        /// Sends relay.ready immediately after the challenge, before the
        /// client can install its `awaitReady` continuation.
        case readyBeforeAuth
    }

    let phone: PCLinkIdentity
    let behavior: Behavior
    private(set) var pings = 0
    private(set) var pongs: [String] = []
    private(set) var authReceived = false
    private(set) var closeCode: UInt16?

    init(phone: PCLinkIdentity, behavior: Behavior) {
        self.phone = phone
        self.behavior = behavior
    }

    func run(socket: FakeWebSocket) async {
        let nonce = (try? PCLinkRandom.bytes(32)) ?? Data(repeating: 1, count: 32)
        let origin = behavior == .wrongOrigin ? "https://evil.example" : "https://relay.example"
        await send(socket, .object([
            "v": .int(1), "type": .string("relay.challenge"),
            "nonce": .string(PCLinkBase64URL.encode(nonce)),
            "relay": .string(origin),
        ]))
        if behavior == .readyBeforeAuth {
            // The client must cache a ready that lands before awaitReady.
            await send(socket, .object([
                "v": .int(1), "type": .string("relay.ready"),
                "machineId": .string(phone.machineId), "role": .string("phone"),
            ]))
        }
        while true {
            guard let message = try? await socket.receive() else { return }
            guard case .text(let text) = message else { continue }
            guard let frame = try? PCLinkJSONParser.parseObject(Data(text.utf8)) else { continue }
            switch frame["type"]?.stringValue {
            case "peer.auth":
                guard behavior != .wrongOrigin else { continue }
                authReceived = true
                if behavior != .readyBeforeAuth {
                    await send(socket, .object([
                        "v": .int(1), "type": .string("relay.ready"),
                        "machineId": .string(phone.machineId), "role": .string("phone"),
                    ]))
                }
                if behavior == .answerPing {
                    await send(socket, .object([
                        "v": .int(1), "type": .string("relay.ping"),
                        "nonce": .string(PCLinkBase64URL.encode(try! PCLinkRandom.bytes(16))),
                    ]))
                }
            case "relay.ping":
                pings += 1
                // Deliberately do not answer; the client must close 1001 after
                // two missed ping periods.
            case "relay.pong":
                if let nonce = frame["nonce"]?.stringValue { pongs.append(nonce) }
            default:
                continue
            }
        }
    }

    private func send(_ socket: FakeWebSocket, _ frame: PCLinkJSON) async {
        guard let text = try? PCLinkJSONEncoder.encodeString(frame) else { return }
        try? await socket.send(text: text)
    }
}

private final class ScriptedRelayNetwork: PCLinkWebSocketFactory, @unchecked Sendable {
    let phone: PCLinkIdentity
    let behavior: ScriptedRelay.Behavior
    private let lock = NSLock()
    private var storage: ScriptedRelay?

    var relay: ScriptedRelay? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    init(phone: PCLinkIdentity, behavior: ScriptedRelay.Behavior) {
        self.phone = phone
        self.behavior = behavior
    }

    func connect(to url: URL) async throws -> any PCLinkWebSocket {
        let pair = FakeDuplex.make()
        let relay = ScriptedRelay(phone: phone, behavior: behavior)
        lock.lock(); storage = relay; lock.unlock()
        Task { await relay.run(socket: pair.server) }
        return pair.client
    }
}

final class PCLinkRelayClientTests: XCTestCase {
    private func makeClient(behavior: ScriptedRelay.Behavior,
                            heartbeat: Bool = false) throws -> (PCLinkRelayClient, ScriptedRelayNetwork) {
        let identity = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("relay-client/phone".utf8)))
        let network = ScriptedRelayNetwork(phone: identity, behavior: behavior)
        let client = PCLinkRelayClient(
            configuration: .init(origin: "https://relay.example", identity: identity,
                                 challengeTimeout: 2, readyTimeout: 2,
                                 heartbeatIntervalRange: 0.02...0.02,
                                 heartbeatEnabled: heartbeat),
            factory: network)
        return (client, network)
    }

    func testHeartbeatTimeoutClosesWith1001() async throws {
        let (client, network) = try makeClient(behavior: .timeoutHeartbeats, heartbeat: true)
        let events = client.events
        let closed = expectation(description: "closed")
        var closeCode: UInt16?
        let consumer = Task {
            for await event in events {
                if case .closed(let code, _, _) = event {
                    closeCode = code
                    closed.fulfill()
                }
            }
        }
        try await client.connect()
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertEqual(closeCode, 1001)
        let pings = await network.relay?.pings ?? 0
        XCTAssertGreaterThanOrEqual(pings, 1)
        consumer.cancel()
        await client.close()
    }

    func testClientAnswersRelayPing() async throws {
        let (client, network) = try makeClient(behavior: .answerPing)
        let events = client.events
        let ready = expectation(description: "ready")
        var sawPong = false
        let consumer = Task {
            for await event in events {
                if case .ready = event { ready.fulfill() }
            }
        }
        try await client.connect()
        await fulfillment(of: [ready], timeout: 2)
        try await Task.sleep(nanoseconds: 300_000_000)
        let pongs = await network.relay?.pongs ?? []
        sawPong = !pongs.isEmpty
        XCTAssertTrue(sawPong, "the client must answer relay.ping with the same nonce")
        consumer.cancel()
        await client.close()
    }

    func testChallengeOriginMismatchFailsAuth() async throws {
        let (client, network) = try makeClient(behavior: .wrongOrigin)
        do {
            try await client.connect()
            XCTFail("a challenge from another origin must not be signed")
        } catch let error as PCLinkError {
            XCTAssertEqual(error.code, "auth_failed")
        }
        let authReceived = await network.relay?.authReceived ?? false
        XCTAssertFalse(authReceived)
        await client.close()
    }

    /// relay.ready can be handled by the receive loop before `awaitReady`
    /// installs its continuation; it must be cached, not dropped.
    func testReadyArrivingBeforeWaiterIsCached() async throws {
        let (client, network) = try makeClient(behavior: .readyBeforeAuth)
        let events = client.events
        let ready = expectation(description: "ready event")
        let consumer = Task {
            for await event in events {
                if case .ready = event {
                    ready.fulfill()
                    return
                }
            }
        }
        try await client.connect()
        await fulfillment(of: [ready], timeout: 2)
        let state = await client.currentState
        XCTAssertEqual(state, .ready)
        let authReceived = await network.relay?.authReceived ?? false
        XCTAssertTrue(authReceived, "peer.auth is still sent after the cached ready")
        consumer.cancel()
        await client.close()
    }
}

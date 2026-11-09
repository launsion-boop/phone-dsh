// SPDX-License-Identifier: MIT
// Phone-side pairing end-to-end: QR pin, pair.hello/auth/confirm/final MACs,
// durable record write and the transition to the normal relay/E2E session.

import Foundation
import XCTest
@testable import PhoneDSHPCLink

private final class FakePairingRelayConnection: @unchecked Sendable {
    let phone: PCLinkIdentity
    let pc: PCLinkIdentity
    let origin: String
    let secret: Data
    let pcName: String
    private var challengeNonce: Data?

    init(phone: PCLinkIdentity, pc: PCLinkIdentity, origin: String, secret: Data, pcName: String) {
        self.phone = phone
        self.pc = pc
        self.origin = origin
        self.secret = secret
        self.pcName = pcName
    }

    func run(socket: FakeWebSocket) async {
        let nonce = try? PCLinkRandom.bytes(32)
        challengeNonce = nonce
        guard let nonce else { return }
        await send(socket, .object([
            "v": .int(1), "type": .string("relay.challenge"),
            "nonce": .string(PCLinkBase64URL.encode(nonce)),
            "relay": .string(origin),
        ]))
        var pairKey: Data?
        var hello: PCLinkPairHello?
        while true {
            guard let message = try? await socket.receive() else { return }
            guard case .text(let text) = message else { continue }
            guard let frame = try? PCLinkJSONParser.parseObject(Data(text.utf8)) else { continue }
            switch frame["type"]?.stringValue {
            case "relay.ping":
                if let nonce = frame["nonce"] {
                    await send(socket, .object(["v": .int(1), "type": .string("relay.pong"),
                                                "nonce": nonce]))
                }
            case "peer.auth":
                guard let publicKey = try? PCLinkBase64URL.decode(
                    frame["publicKey"]?.stringValue ?? "", expectedBytes: 32),
                    publicKey == phone.publicKey,
                    frame["machineId"]?.stringValue == phone.machineId,
                    frame["role"]?.stringValue == "phone",
                    let signature = try? PCLinkBase64URL.decode(
                        frame["sig"]?.stringValue ?? "", expectedBytes: 64),
                    PCLinkCrypto.ed25519Verify(
                        publicKey: publicKey,
                        message: PCLinkCrypto.relayAuthTranscript(origin: origin, nonce: nonce),
                        signature: signature) else { return }
                await send(socket, .object([
                    "v": .int(1), "type": .string("relay.ready"),
                    "machineId": .string(phone.machineId), "role": .string("phone"),
                ]))
            case "relay.pair.join":
                guard let rendezvous = frame["rendezvous"]?.stringValue else { return }
                await send(socket, .object([
                    "v": .int(1), "type": .string("relay.pair.joined"),
                    "rendezvous": .string(rendezvous),
                    "role": .string("phone"),
                    "peerMachineId": .string(pc.machineId),
                ]))
                let key = PCLinkCrypto.pairKey(secret: secret)
                pairKey = key
                guard let helloMessage = try? PCLinkPairingMessage.makeHello(
                    machineId: pc.machineId, publicKey: pc.publicKey, name: pcName,
                    relayOrigin: origin, nonce: try! PCLinkRandom.bytes(32), pairKey: key) else { return }
                hello = helloMessage
                await send(socket, .object([
                    "v": .int(1), "type": .string("relay.pair.message"),
                    "rendezvous": .string(rendezvous),
                    "payload": helloMessage.raw,
                ]))
            case "relay.pair.message":
                guard let rendezvous = frame["rendezvous"]?.stringValue,
                      let payload = frame["payload"], let pairKey, let hello else { return }
                guard let decoded = try? PCLinkPairingMessage.decode(payload) else { return }
                switch decoded {
                case .auth(let auth):
                    guard (try? decoded.verifyMAC(pairKey: pairKey)) != nil else { return }
                    let transcript = try? PCLinkCrypto.pairTranscriptHash(
                        hello: PCLinkPairingMessage.hello(hello).canonicalWithoutMAC(),
                        auth: PCLinkPairingMessage.auth(auth).canonicalWithoutMAC())
                    guard let transcript else { return }
                    guard let confirm = try? PCLinkPairingMessage.makeConfirm(
                        helloNonce: hello.nonce, authNonce: auth.nonce,
                        transcriptHash: transcript, pairKey: pairKey) else { return }
                    await send(socket, .object([
                        "v": .int(1), "type": .string("relay.pair.message"),
                        "rendezvous": .string(rendezvous),
                        "payload": confirm.raw,
                    ]))
                case .final:
                    guard (try? decoded.verifyMAC(pairKey: pairKey)) != nil else { return }
                    await send(socket, .object([
                        "v": .int(1), "type": .string("relay.pair.close"),
                        "rendezvous": .string(rendezvous), "reason": .string("paired"),
                    ]))
                    await socket.close(code: 1000, reason: "paired")
                    return
                default:
                    return
                }
            case "relay.pair.close":
                return
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

private final class PairingThenNormalNetwork: PCLinkWebSocketFactory, @unchecked Sendable {
    let phone: PCLinkIdentity
    let pc: PCLinkIdentity
    let origin: String
    let secret: Data
    let pcName: String
    let normalServer: FakePCServer
    private let lock = NSLock()
    private var connections = 0

    init(phone: PCLinkIdentity, pc: PCLinkIdentity, origin: String, secret: Data,
         pcName: String, normalServer: FakePCServer) {
        self.phone = phone
        self.pc = pc
        self.origin = origin
        self.secret = secret
        self.pcName = pcName
        self.normalServer = normalServer
    }

    func connect(to url: URL) async throws -> any PCLinkWebSocket {
        lock.lock()
        connections += 1
        let index = connections
        lock.unlock()
        let pair = FakeDuplex.make()
        if index == 1 {
            let connection = FakePairingRelayConnection(phone: phone, pc: pc, origin: origin,
                                                        secret: secret, pcName: pcName)
            Task { await connection.run(socket: pair.server) }
        } else {
            let connection = FakePCConnection(server: normalServer, phoneIdentity: phone,
                                              origin: origin)
            Task { await connection.run(socket: pair.server) }
        }
        return pair.client
    }
}

final class PCLinkPairingFlowTests: XCTestCase {
    func testFullPairingFlowWritesRecordThenConnects() async throws {
        let phone = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("pair-flow/phone".utf8)))
        let pc = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("pair-flow/pc".utf8)))
        let origin = "https://relay.example"
        let secret = try PCLinkRandom.bytes(16)
        let normalServer = FakePCServer(pcIdentity: pc, phoneMachineId: phone.machineId,
                                        phonePublicKey: phone.publicKey, relayOrigin: origin)
        let network = PairingThenNormalNetwork(phone: phone, pc: pc, origin: origin,
                                               secret: secret, pcName: "My PC",
                                               normalServer: normalServer)
        let pairingStore = InMemoryPairingStore()
        let client = PCLinkClient(
            identityStore: InMemoryIdentityStore(seed: phone.seed),
            pairingStore: pairingStore,
            configuration: PCLinkClientConfiguration(
                websocketFactory: network,
                reconnectPolicy: PCLinkReconnectPolicy(delays: [0.01]),
                connectTimeout: 5,
                handshakeTimeout: 5,
                callRetryDeadline: 5,
                pairingTimeout: 5,
                pairingPromptTimeout: 5,
                heartbeatIntervalRange: 0.05...0.05,
                heartbeatEnabled: false))
        try await client.start()
        let initialStatus = await client.status()
        XCTAssertEqual(initialStatus.state, .unpaired(.noRecord))

        let uri = try PCLinkQRCode.makeURI(relayOrigin: origin, pcMachineId: pc.machineId,
                                           pcPublicKey: pc.publicKey, secret: secret,
                                           pcName: "My PC")
        let prompt = try await client.beginPairing(qrURI: uri)
        XCTAssertEqual(prompt.pcMachineId, pc.machineId)
        XCTAssertEqual(prompt.pcName, "My PC")
        XCTAssertEqual(prompt.ownFingerprint, phone.fingerprint)
        XCTAssertEqual(prompt.warningText, PCLinkPairingPrompt.fullOwnerWarning)

        let result = try await client.confirmPairing(prompt.id)
        XCTAssertEqual(result.record.peerMachineId, pc.machineId)
        XCTAssertEqual(result.record.peerPublicKey, pc.publicKey)
        XCTAssertEqual(result.record.relayOrigin, origin)
        XCTAssertEqual(result.record.connectionMode, .relay)
        XCTAssertNotNil(pairingStore.stored)
        let pairedStatus = await client.status()
        XCTAssertEqual(pairedStatus.record, result.record)

        // `confirmPairing` starts the normal connection; the fake PC answers
        // the E2E handshake and a unary call proves the record is usable.
        let transport = client.makeTransport()
        let value = try await transport.call("session/list", args: .object(["_request": .object([:])]))
        XCTAssertNotNil(value.objectValue)
        let handshakes = await normalServer.handshakes
        let calls = await normalServer.calls
        XCTAssertEqual(handshakes, 1)
        XCTAssertEqual(calls.count, 1)
    }

    /// The durable record must be loaded before the "already paired" check; a
    /// record that exists only on disk must never be overwritten by a new
    /// pairing attempt.
    func testBeginPairingLoadsRecordBeforeAlreadyPairedCheck() async throws {
        let phone = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("pair-guard/phone".utf8)))
        let pc = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("pair-guard/pc".utf8)))
        let origin = "https://relay.example"
        let record = TestSupport.record(peerMachineId: pc.machineId,
                                        peerPublicKey: pc.publicKey,
                                        peerName: "My PC",
                                        relayOrigin: origin)
        let store = InMemoryPairingStore(record: record, phoneMachineId: phone.machineId)
        let client = PCLinkClient(
            identityStore: InMemoryIdentityStore(seed: phone.seed),
            pairingStore: store,
            configuration: PCLinkClientConfiguration(
                websocketFactory: FailingWebSocketFactory(),
                connectTimeout: 1, handshakeTimeout: 1, callRetryDeadline: 1))
        let uri = try PCLinkQRCode.makeURI(relayOrigin: origin, pcMachineId: pc.machineId,
                                           pcPublicKey: pc.publicKey,
                                           secret: try PCLinkRandom.bytes(16),
                                           pcName: "My PC")
        do {
            _ = try await client.beginPairing(qrURI: uri)
            XCTFail("an existing on-disk record must block a new pairing")
        } catch let error as PCLinkError {
            XCTAssertEqual(error.code, "already_paired")
        }
        let status = await client.status()
        XCTAssertEqual(status.record, record, "the existing record must not be replaced")
    }
}

private struct FailingWebSocketFactory: PCLinkWebSocketFactory {
    func connect(to url: URL) async throws -> any PCLinkWebSocket {
        throw PCLinkError.unavailable("not used in this test")
    }
}

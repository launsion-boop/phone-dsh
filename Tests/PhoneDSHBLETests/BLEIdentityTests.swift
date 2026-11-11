// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHBLE

final class BLEIdentityTests: XCTestCase {
    private func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func testRealSignatureBindsNonceAndPublicKey() throws {
        let key = P256.Signing.PrivateKey()
        let otherKey = P256.Signing.PrivateKey()
        let nonce = try BLEIdentity.randomNonce()
        let publicKey = key.publicKey.x963Representation
        var message = Data("phoneDSH BLE identity v1".utf8)
        message.append(0)
        message.append(nonce)
        message.append(0)
        message.append(publicKey)
        let signature = try key.signature(for: SHA256.hash(data: message)).rawRepresentation
        let expectedIdentity = "ble:" + hex(SHA256.hash(data: publicKey))

        XCTAssertEqual(try BLEIdentity.verify(nonce: nonce, publicKeyHex: hex(publicKey),
                                              signatureHex: hex(signature)), expectedIdentity)
        var wrongNonce = nonce
        wrongNonce[wrongNonce.startIndex] ^= 1
        XCTAssertThrowsError(try BLEIdentity.verify(nonce: wrongNonce, publicKeyHex: hex(publicKey),
                                                     signatureHex: hex(signature)))
        XCTAssertThrowsError(try BLEIdentity.verify(nonce: nonce, publicKeyHex: hex(otherKey.publicKey.x963Representation),
                                                     signatureHex: hex(signature)))
        var tampered = signature
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try BLEIdentity.verify(nonce: nonce, publicKeyHex: hex(publicKey),
                                                     signatureHex: hex(tampered)))
    }

    func testRejectsMalformedProofs() throws {
        let key = P256.Signing.PrivateKey()
        let nonce = try BLEIdentity.randomNonce()
        let publicKey = key.publicKey.x963Representation
        var message = Data("phoneDSH BLE identity v1".utf8)
        message.append(0)
        message.append(nonce)
        message.append(0)
        message.append(publicKey)
        let signature = try key.signature(for: SHA256.hash(data: message))
        let keyHex = hex(publicKey), signatureHex = hex(signature.rawRepresentation)

        XCTAssertThrowsError(try BLEIdentity.verify(nonce: nonce.dropLast(), publicKeyHex: keyHex, signatureHex: signatureHex))
        XCTAssertThrowsError(try BLEIdentity.verify(nonce: nonce, publicKeyHex: String(keyHex.dropLast(2)), signatureHex: signatureHex))
        XCTAssertThrowsError(try BLEIdentity.verify(nonce: nonce, publicKeyHex: keyHex, signatureHex: String(signatureHex.dropLast(2))))
        XCTAssertThrowsError(try BLEIdentity.verify(nonce: nonce, publicKeyHex: keyHex, signatureHex: hex(signature.derRepresentation)))
        XCTAssertThrowsError(try BLEIdentity.verify(nonce: nonce, publicKeyHex: "zz" + keyHex.dropFirst(2), signatureHex: signatureHex))
        XCTAssertThrowsError(try BLEIdentity.verify(nonce: nonce, publicKeyHex: keyHex.uppercased(), signatureHex: signatureHex))
    }

    func testConfirmedIdentityPersistsInDefaultsWithoutDuplicates() throws {
        let suite = "BLEIdentityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = "ble:" + String(repeating: "a", count: 64)
        let other = "ble:" + String(repeating: "b", count: 64)

        XCTAssertFalse(BLETrustedIdentities.contains(identity, defaults: defaults))
        BLETrustedIdentities.insert(identity, defaults: defaults)
        BLETrustedIdentities.insert(identity, defaults: defaults)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(BLETrustedIdentities.contains(identity, defaults: reloaded))
        XCTAssertFalse(BLETrustedIdentities.contains(other, defaults: reloaded))
        XCTAssertEqual(reloaded.stringArray(forKey: BLETrustedIdentities.key), [identity])
    }

    #if DEBUG
    @MainActor func testUntrustedIdentityAdvertisementDoesNotInterruptOrdinaryTools() async throws {
        let id = UUID()
        let adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [.init(id: id, name: "peer", rssi: 0)])
        store.connect(id)
        store.testDidConnect(id)
        store.testDiscover(id, profiles: [.battery])
        let owner = try XCTUnwrap(store.testOwner(id))
        let transport = IdentityAdvertisementTransport()
        let client = PDSHLinkClient(transport: transport)
        let peer = try await client.handshake()
        try await store.discoverLinkTools(id, client: client, bootID: peer.bootID) {
            store.testOwner(id) == owner && store.testPhase(id) == "connected"
        }

        let device = try XCTUnwrap(store.devices.first)
        XCTAssertEqual(transport.methods, ["tools/list"])
        XCTAssertEqual(device.linkTools, ["light.get"])
        XCTAssertFalse(device.supportsDeviceTasks)
        XCTAssertTrue(device.pendingIdentity.isEmpty)
        store.grantLinkTool(id, name: "light.get", enabled: true)
        store.grantLinkTool(id, name: "pdsh.identity.prove", enabled: true)
        XCTAssertEqual(store.devices.first?.grantedTools, ["light.get"])
    }
    #endif
}

/// Returns an unsolicited identity tool but fails any request other than tools/list.
/// The test uses the real Link client upload, commit and result-query code.
@MainActor private final class IdentityAdvertisementTransport: PDSHLinkTransport {
    var methods: [String] = []
    private var upload = Data()
    private var result = Data()

    func exchange(opcode: UInt8, body: Data) async throws -> Data {
        let bytes = [UInt8](body)
        switch opcode {
        case 1:
            var ack = Data(repeating: 0, count: 25)
            ack[1] = 2; ack[2] = 1; ack[5] = 0x10; ack[24] = 2
            ack.append(contentsOf: Array("PDSH".utf8) + [1, 0, 0, 16])
            return ack
        case 0x54:
            guard bytes.count >= 24, Int(bytes.u16(18)) == upload.count else { throw BLEFailure("bad upload") }
            upload.append(body.dropFirst(24))
            var response = Data([0]); response.put(UInt16(upload.count)); return response
        case 0x55:
            let request = try JSONValue.parse(upload)
            guard let name = request["name"]?.stringValue,
                  let requestID = request["request_id"]?.stringValue else { throw BLEFailure("bad request") }
            methods.append(name)
            guard name == "tools/list" else { throw BLEFailure("identity proof unavailable") }
            result = try JSONValue.object([
                "request_id": .string(requestID), "status": .string("completed"),
                "result": .object([
                    "device_id": .string("ce6ec956-1111-4222-8333-123456789abc"),
                    "boot_id": .number(0),
                    "tools": .array([.object(["name": .string("light.get")]),
                                     .object(["name": .string("pdsh.identity.prove")])])
                ])
            ]).encoded()
            return Data([0, 1])
        case 0x56:
            let offset = Int(bytes.u16(16))
            guard offset < result.count else { throw BLEFailure("bad result offset") }
            var response = Data([0, 2]); response.put(UInt16(result.count)); response.put(UInt16(offset))
            response.append(result[offset..<min(offset + 499, result.count)])
            return response
        default: throw BLEFailure("unexpected opcode")
        }
    }
}

final class RememberedBoardPresenceTests: XCTestCase {
    /// A known-but-absent remembered board is never connected blind: that connect would time out
    /// and quarantine the board until the app restarts (ble-link.md rule 6, owner closing rules).
    func testRememberedBoardConnectsOnlyWhenPresent() {
        XCTAssertFalse(BLEDeviceStore.rememberedBoardIsPresent(systemConnected: false, advertised: false))
        XCTAssertTrue(BLEDeviceStore.rememberedBoardIsPresent(systemConnected: true, advertised: false))
        XCTAssertTrue(BLEDeviceStore.rememberedBoardIsPresent(systemConnected: false, advertised: true))
    }
}

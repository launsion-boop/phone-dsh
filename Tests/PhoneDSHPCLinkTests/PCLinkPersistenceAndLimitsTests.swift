// SPDX-License-Identifier: MIT
// Persistence, Keychain smoke, session limits/rekey, SemVer and small codec
// boundary tests.

import Foundation
import Security
import XCTest
@testable import PhoneDSHPCLink

final class PCLinkPersistenceTests: XCTestCase {
    func testFilePairingStoreRoundTripModeAndStaleRule() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pclink-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PCLinkFilePairingStore(directory: directory)
        let phone = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("store/phone".utf8)))
        let pc = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("store/pc".utf8)))
        let record = TestSupport.record(peerMachineId: pc.machineId, peerPublicKey: pc.publicKey,
                                        peerName: "My PC")
        XCTAssertEqual(try store.load(phoneMachineId: phone.machineId), .none)
        try store.save(record, phoneMachineId: phone.machineId)
        XCTAssertEqual(try store.load(phoneMachineId: phone.machineId), .usable(record))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let other = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("store/other".utf8)))
        XCTAssertEqual(try store.load(phoneMachineId: other.machineId), .stale(record))

        try store.delete()
        XCTAssertEqual(try store.load(phoneMachineId: phone.machineId), .none)
    }

    func testPhoneStoreRejectsTwoRecordsAndApprovalFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pclink-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("pairs.json")
        let store = PCLinkFilePairingStore(fileURL: fileURL)
        let phone = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("two/phone".utf8)))
        let pc = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("two/pc".utf8)))
        var record = TestSupport.record(peerMachineId: pc.machineId, peerPublicKey: pc.publicKey,
                                        peerName: "My PC")
        record.connectionMode = .relay
        try store.save(record, phoneMachineId: phone.machineId)
        var document = try XCTUnwrap(PCLinkJSONParser.parseDocumentObject(try Data(contentsOf: fileURL)))
        var object = try XCTUnwrap(document.objectValue)
        object["records"] = .array([record.json, record.json])
        document = .object(object)
        try PCLinkJSONEncoder.encode(document).write(to: fileURL)
        XCTAssertThrowsError(try store.load(phoneMachineId: phone.machineId))

        object["records"] = .array([.object([
            "peerMachineId": .string(pc.machineId),
            "peerPublicKey": .string(PCLinkBase64URL.encode(pc.publicKey)),
            "peerName": .string("My PC"),
            "pairedAt": .string("2026-11-09T00:00:00Z"),
            "relayOrigin": .string("https://relay.example"),
            "connection": .object(["mode": .string("relay")]),
            "approvedAt": .string("2026-11-09T00:00:05Z"),
            "approvedVia": .string("cli"),
        ])])
        document = .object(object)
        try PCLinkJSONEncoder.encode(document).write(to: fileURL)
        XCTAssertThrowsError(try store.load(phoneMachineId: phone.machineId))
    }
}

final class PCLinkKeychainSmokeTests: XCTestCase {
    func testRealKeychainRoundTripOrSkip() throws {
        let store = PCLinkKeychainIdentityStore(
            service: "dsh-pclink-test-\(UUID().uuidString.lowercased())",
            account: "identity-v1")
        let seed = try PCLinkRandom.bytes(32)
        do {
            try store.saveSeed(seed)
        } catch let error as PCLinkKeychainError where error.isUnavailableInEnvironment {
            throw XCTSkip("Keychain not available in this host environment: \(error)")
        }
        defer { try? store.deleteSeed() }
        XCTAssertEqual(try store.loadSeed(), seed)
        let replacement = try PCLinkRandom.bytes(32)
        try store.saveSeed(replacement)
        XCTAssertEqual(try store.loadSeed(), replacement)
        try store.deleteSeed()
        XCTAssertNil(try store.loadSeed())
    }
}

final class PCLinkSessionLimitsTests: XCTestCase {
    private func goldenSession(thresholds: PCLinkSessionThresholds) throws -> PCLinkE2ESession {
        let v = try TestSupport.vectors()
        let handshake = try XCTUnwrap(v["handshake"])
        let phone = try TestSupport.identity("pclink-v1/test/identity/phone")
        let pc = try TestSupport.identity("pclink-v1/test/identity/pc")
        let peer = TestSupport.record(peerMachineId: pc.machineId, peerPublicKey: pc.publicKey,
                                      peerName: "My PC")
        let seed = TestSupport.seed("pclink-v1/test/eph/phone")
        let session = try PCLinkE2ESession(
            identity: phone, peer: peer,
            sidBytes: try XCTUnwrap(TestSupport.b64(handshake, "sid")),
            ephemeral: .init(privateKey: seed,
                             publicKey: try PCLinkCrypto.x25519PublicKey(privateKey: seed)),
            phoneNonce: try XCTUnwrap(TestSupport.b64(handshake, "phone_nonce")),
            thresholds: thresholds)
        try session.acceptResp(outer: .object([
            "v": .int(1), "type": .string("e2e.handshake"),
            "sid": handshake["sid"]!,
            "from": .string(pc.machineId), "to": .string(phone.machineId),
            "body": handshake["resp"]!,
        ]))
        _ = try session.confirmFrame()
        return session
    }

    func testSoftThresholdSetsRekeyAndHardCapCloses() throws {
        let thresholds = PCLinkSessionThresholds(softFrames: 2, hardFrames: 4,
                                                 softBytes: 1 << 30, hardBytes: 1 << 31)
        let session = try goldenSession(thresholds: thresholds)
        let hello = try PCLinkPeerHello.make(
            role: "phone", caps: ["workspace/1", PCLinkCrypto.suite],
            dshVersion: "0.2.2-rc.1", dshCommit: nil,
            appName: "phoneDSH", appVersion: "0.1.0", name: "iPhone")
        _ = try session.makePeerHelloFrame(hello: hello)
        XCTAssertFalse(session.needsRekey)
        _ = try session.seal(.object(["type": .string("rpc.call"), "id": .string("a"),
                                      "endpoint": .string("session/list"),
                                      "args": .object(["_request": .object([:])])]))
        XCTAssertTrue(session.needsRekey, "2^19-frame soft line is injected as 2 frames")
        _ = try session.seal(.object(["type": .string("rpc.call"), "id": .string("b"),
                                      "endpoint": .string("session/list"),
                                      "args": .object(["_request": .object([:])])]))
        _ = try session.seal(.object(["type": .string("rpc.call"), "id": .string("c"),
                                      "endpoint": .string("session/list"),
                                      "args": .object(["_request": .object([:])])]))
        XCTAssertEqual(session.sentFrames, 4)
        XCTAssertThrowsError(try session.seal(.object(["type": .string("session.close"),
                                                       "code": .string("unavailable")]))) { error in
            XCTAssertEqual((error as? PCLinkError)?.code, "session_expired")
        }
    }

    func testHardReceiveCapCloses() throws {
        let thresholds = PCLinkSessionThresholds(softFrames: 100, hardFrames: 4,
                                                 softBytes: 1 << 30, hardBytes: 1 << 31)
        let session = try goldenSession(thresholds: thresholds)
        let outer: PCLinkJSON = .object([
            "v": .int(1), "type": .string("e2e"), "sid": .string(session.sid),
            "seq": .int(4),
            "from": .string(session.peer.peerMachineId),
            "to": .string(session.identity.machineId),
            "body": .string(PCLinkBase64URL.encode(Data(repeating: 1, count: 20))),
        ])
        XCTAssertThrowsError(try session.open(outer)) { error in
            XCTAssertEqual((error as? PCLinkError)?.code, "session_expired")
        }
    }

    func testPeerHelloVersionWarningAndSemVer() throws {
        let inRange = try PCLinkPeerHello.make(
            role: "pc", caps: ["workspace/1", PCLinkCrypto.suite],
            dshVersion: "0.2.2-rc.1", dshCommit: "66491b05",
            appName: "dsh-pclink", appVersion: "0.1.0", name: "My PC")
        XCTAssertFalse(inRange.versionWarning)
        XCTAssertTrue(inRange.supportsPCLink)

        let outOfRange = try PCLinkPeerHello.make(
            role: "pc", caps: ["workspace/1", PCLinkCrypto.suite],
            dshVersion: "0.3.0", dshCommit: nil,
            appName: "dsh-pclink", appVersion: "0.1.0", name: "My PC")
        XCTAssertTrue(outOfRange.versionWarning)

        let missingCap = try PCLinkPeerHello.make(
            role: "pc", caps: ["workspace/1"], dshVersion: "0.2.2-rc.1", dshCommit: nil,
            appName: "dsh-pclink", appVersion: "0.1.0", name: "My PC")
        XCTAssertFalse(missingCap.supportsPCLink)

        XCTAssertNil(PCLinkValidation.SemVer.parse("1.0"))
        XCTAssertNil(PCLinkValidation.SemVer.parse("01.0.0"))
        XCTAssertLessThan(PCLinkValidation.SemVer.parse("0.2.2-rc.1")!,
                          PCLinkValidation.SemVer.parse("0.2.2")!)
        XCTAssertLessThan(PCLinkValidation.SemVer.parse("1.0.0-alpha")!,
                          PCLinkValidation.SemVer.parse("1.0.0")!)
    }

    func testReconnectPolicyConstants() {
        let policy = PCLinkReconnectPolicy.v1
        XCTAssertEqual(policy.baseDelay(attempt: 1), 0.5)
        XCTAssertEqual(policy.baseDelay(attempt: 2), 1)
        XCTAssertEqual(policy.baseDelay(attempt: 7), 30)
        XCTAssertEqual(policy.baseDelay(attempt: 99), 30)
        XCTAssertEqual(policy.delay(attempt: 1, jitter: 0), 0.4, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 1, jitter: 1), 0.6, accuracy: 0.001)
        XCTAssertEqual(policy.delay(attempt: 1, jitter: 0.5), 0.5, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(policy.replacedDelay(attempt: 1), 30)
    }

    func testChunkReassemblyTimeoutDiscardsPartialValue() throws {
        var reassembler = PCLinkChunkReassembler()
        let now = Date()
        _ = try reassembler.accept(key: "k", part: 0, last: false,
                                   dataBase64: PCLinkBase64URL.encode(Data("a".utf8)),
                                   now: now)
        XCTAssertThrowsError(try reassembler.accept(
            key: "k", part: 1, last: true,
            dataBase64: PCLinkBase64URL.encode(Data("b".utf8)),
            now: now.addingTimeInterval(PCLinkLimits.chunkReassemblyTimeout + 1)))
        XCTAssertTrue(reassembler.pendingKeys.isEmpty)
    }

    func testBase64URLStrictness() throws {
        XCTAssertEqual(try PCLinkBase64URL.decode("AAECAwQFBgcICQoLDA0ODw", expectedBytes: 16).count, 16)
        XCTAssertThrowsError(try PCLinkBase64URL.decode("AAECAwQFBgcICQoLDA0ODw=="))
        XCTAssertThrowsError(try PCLinkBase64URL.decode("AAECAwQFBgcICQoLDA0ODx"))
        XCTAssertThrowsError(try PCLinkBase64URL.decode("AAECAwQFBgcICQoLDA0OD+"))
        XCTAssertEqual(PCLinkBase64URL.encode(Data([0, 1, 2])), "AAEC")
    }

    func testNameNFCIsByteExact() throws {
        XCTAssertNoThrow(try PCLinkValidation.name("Café"))
        XCTAssertThrowsError(try PCLinkValidation.name("Cafe\u{301}"))
        XCTAssertThrowsError(try PCLinkValidation.name("My\u{202E}PC"))
        XCTAssertThrowsError(try PCLinkValidation.name("My\nPC"))
        XCTAssertThrowsError(try PCLinkValidation.name(String(repeating: "汉", count: 33)))
    }

    // MARK: - §3.1 origin scheme / ws derivation

    func testOriginOnlyAllowsHTTPSOrLoopbackHTTP() throws {
        XCTAssertNoThrow(try PCLinkValidation.origin("https://relay.example"))
        XCTAssertNoThrow(try PCLinkValidation.origin("http://127.0.0.1:3240"))
        XCTAssertNoThrow(try PCLinkValidation.origin("http://localhost:3240"))
        XCTAssertThrowsError(try PCLinkValidation.origin("http://relay.example")) { error in
            XCTAssertEqual((error as? PCLinkError)?.code, "bad_frame")
        }
        XCTAssertThrowsError(try PCLinkValidation.origin("http://192.168.1.10:3240"))
        XCTAssertThrowsError(try PCLinkValidation.origin("http://[::1]:3240"))
    }

    func testQRAndManualOriginsDeriveWSSURLs() throws {
        let pc = try TestSupport.identity("pclink-v1/test/identity/pc")
        let secret = try PCLinkRandom.bytes(16)
        let uri = try PCLinkQRCode.makeURI(relayOrigin: "https://relay.example",
                                           pcMachineId: pc.machineId,
                                           pcPublicKey: pc.publicKey,
                                           secret: secret, pcName: "My PC")
        let qr = try PCLinkQRCode.parse(uri)
        XCTAssertEqual(try qr.websocketURL.absoluteString, "wss://relay.example/")
        let manualSecret = try PCLinkRandom.bytes(10)
        let manual = try PCLinkManualCode.parse(PCLinkManualCode.display(manualSecret),
                                                relayOrigin: "https://relay.example")
        XCTAssertEqual(try manual.websocketURL.absoluteString, "wss://relay.example/")
        let loopback = try PCLinkManualCode.parse(PCLinkManualCode.display(manualSecret),
                                                  relayOrigin: "http://127.0.0.1:3240")
        XCTAssertEqual(try loopback.websocketURL.absoluteString, "ws://127.0.0.1:3240/")
    }
}

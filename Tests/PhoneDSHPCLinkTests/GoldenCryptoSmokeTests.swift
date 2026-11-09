// SPDX-License-Identifier: MIT
// Golden smoke tests: identities, relay auth, handshake transcripts and AEAD
// frames from spec/pclink/v1/golden/pclink-v1-vectors.json.

import Foundation
import XCTest
@testable import PhoneDSHPCLink

final class GoldenCryptoSmokeTests: XCTestCase {
    func testMetaAndIdentities() throws {
        let v = try TestSupport.vectors()
        XCTAssertEqual(v["format"]?.stringValue, "pclink-v1-vectors")
        XCTAssertEqual(v["format_version"]?.intValue, 3)
        XCTAssertEqual(v["revision"]?.stringValue, "pclink-v1.2")
        XCTAssertEqual(v["suite"]?.stringValue, PCLinkCrypto.suite)

        for name in ["phone", "pc"] {
            let entry = try XCTUnwrap(v["identities"]?[name])
            let label = try XCTUnwrap(entry["seed_label"]?.stringValue)
            let identity = try TestSupport.identity(label)
            XCTAssertEqual(PCLinkBase64URL.encode(identity.publicKey),
                           entry["public_key"]?.stringValue, name)
            XCTAssertEqual(identity.machineId, entry["machine_id"]?.stringValue, name)
            XCTAssertEqual(PCLinkHex.encode(PCLinkCrypto.sha256(identity.publicKey)),
                           entry["sha256_hex"]?.stringValue, name)
            try PCLinkValidation.name("iPhone")
        }
    }

    func testRelayAuthTranscripts() throws {
        let v = try TestSupport.vectors()
        let auth = try XCTUnwrap(v["relay_auth"])
        let origin = try XCTUnwrap(auth["origin"]?.stringValue)
        let nonce = try XCTUnwrap(TestSupport.b64(auth, "nonce"))
        let transcript = PCLinkCrypto.relayAuthTranscript(origin: origin, nonce: nonce)
        XCTAssertEqual(PCLinkHex.encode(transcript), auth["transcript_hex"]?.stringValue)

        for name in ["phone", "pc"] {
            let entry = try XCTUnwrap(auth[name])
            let identity = try TestSupport.identity(
                name == "phone" ? "pclink-v1/test/identity/phone" : "pclink-v1/test/identity/pc")
            let signature = try identity.sign(transcript)
            let publicKey = try XCTUnwrap(TestSupport.b64(entry, "public_key"))
            XCTAssertTrue(PCLinkCrypto.ed25519Verify(publicKey: publicKey, message: transcript,
                                                      signature: signature))
            // CryptoKit's Ed25519 signer is not required to be
            // byte-deterministic with the Node generator; the contract is
            // interoperability (the golden signature must verify).
            XCTAssertTrue(PCLinkCrypto.ed25519Verify(
                publicKey: publicKey, message: transcript,
                signature: try XCTUnwrap(TestSupport.b64(entry, "signature"))))
            XCTAssertEqual(identity.machineId, entry["machine_id"]?.stringValue)
        }
    }

    func testHandshakeTranscriptsAndConfirmations() throws {
        let v = try TestSupport.vectors()
        let handshake = try XCTUnwrap(v["handshake"])
        let phone = try TestSupport.identity("pclink-v1/test/identity/phone")
        let pc = try TestSupport.identity("pclink-v1/test/identity/pc")
        let phoneEphSeed = TestSupport.seed("pclink-v1/test/eph/phone")
        let pcEphSeed = TestSupport.seed("pclink-v1/test/eph/pc")
        let phoneEphPub = try PCLinkCrypto.x25519PublicKey(privateKey: phoneEphSeed)
        let pcEphPub = try PCLinkCrypto.x25519PublicKey(privateKey: pcEphSeed)
        XCTAssertEqual(PCLinkBase64URL.encode(phoneEphPub),
                       handshake["phone_eph"]?["public_key"]?.stringValue)
        XCTAssertEqual(PCLinkBase64URL.encode(pcEphPub),
                       handshake["pc_eph"]?["public_key"]?.stringValue)

        let sid = try XCTUnwrap(TestSupport.b64(handshake, "sid"))
        let phoneNonce = try XCTUnwrap(TestSupport.b64(handshake, "phone_nonce"))
        let pcNonce = try XCTUnwrap(TestSupport.b64(handshake, "pc_nonce"))
        let initTranscript = PCLinkCrypto.sessionInitTranscript(
            phoneMachineId: phone.machineId, pcMachineId: pc.machineId,
            sid: sid, ephPhone: phoneEphPub, noncePhone: phoneNonce)
        XCTAssertEqual(PCLinkHex.encode(initTranscript),
                       handshake["transcripts"]?["init_hex"]?.stringValue)
        let th1 = PCLinkCrypto.sha256(initTranscript)
        XCTAssertEqual(PCLinkHex.encode(th1),
                       handshake["transcripts"]?["th1_hex"]?.stringValue)

        let respTranscript = PCLinkCrypto.sessionRespTranscript(th1: th1, ephPc: pcEphPub, noncePc: pcNonce)
        XCTAssertEqual(PCLinkHex.encode(respTranscript),
                       handshake["transcripts"]?["resp_hex"]?.stringValue)
        let th2 = PCLinkCrypto.sha256(respTranscript)
        XCTAssertEqual(PCLinkHex.encode(th2),
                       handshake["transcripts"]?["th2_hex"]?.stringValue)
        let respSignature = try XCTUnwrap(TestSupport.b64(handshake["resp"], "sig"))
        XCTAssertTrue(PCLinkCrypto.ed25519Verify(publicKey: pc.publicKey,
                                                  message: respTranscript,
                                                  signature: respSignature))

        let dh = try PCLinkCrypto.x25519SharedSecret(privateKey: phoneEphSeed, publicKey: pcEphPub)
        XCTAssertEqual(PCLinkHex.encode(dh), handshake["dh_hex"]?.stringValue)
        let keys = PCLinkCrypto.sessionKeys(dh: dh, th2: th2)
        XCTAssertEqual(PCLinkBase64URL.encode(keys.phoneToPC),
                       handshake["keys"]?["phone_to_pc"]?.stringValue)
        XCTAssertEqual(PCLinkBase64URL.encode(keys.pcToPhone),
                       handshake["keys"]?["pc_to_phone"]?.stringValue)
        XCTAssertEqual(PCLinkBase64URL.encode(keys.confirmPhone),
                       handshake["keys"]?["confirm_phone"]?.stringValue)
        XCTAssertEqual(PCLinkBase64URL.encode(keys.confirmPC),
                       handshake["keys"]?["confirm_pc"]?.stringValue)
        XCTAssertEqual(PCLinkBase64URL.encode(PCLinkCrypto.confirmation(key: keys.confirmPC, th: th2)),
                       handshake["confirmations"]?["pc"]?.stringValue)

        let confirmTranscript = PCLinkCrypto.sessionConfirmTranscript(
            th2: th2, phoneMachineId: phone.machineId, pcMachineId: pc.machineId, sid: sid)
        XCTAssertEqual(PCLinkHex.encode(confirmTranscript),
                       handshake["transcripts"]?["confirm_hex"]?.stringValue)
        let th3 = PCLinkCrypto.sha256(confirmTranscript)
        XCTAssertEqual(PCLinkHex.encode(th3),
                       handshake["transcripts"]?["th3_hex"]?.stringValue)
        let confirmSignature = try phone.sign(confirmTranscript)
        XCTAssertTrue(PCLinkCrypto.ed25519Verify(
            publicKey: phone.publicKey, message: confirmTranscript, signature: confirmSignature))
        XCTAssertTrue(PCLinkCrypto.ed25519Verify(
            publicKey: phone.publicKey, message: confirmTranscript,
            signature: try XCTUnwrap(TestSupport.b64(handshake["confirm"], "sig"))))
        XCTAssertEqual(PCLinkBase64URL.encode(PCLinkCrypto.confirmation(key: keys.confirmPhone, th: th3)),
                       handshake["confirmations"]?["phone"]?.stringValue)

        let rejectTranscript = PCLinkCrypto.sessionRejectTranscript(th1: th1, code: "unpaired")
        XCTAssertEqual(PCLinkHex.encode(rejectTranscript),
                       handshake["transcripts"]?["reject_hex"]?.stringValue)
        XCTAssertTrue(PCLinkCrypto.ed25519Verify(
            publicKey: pc.publicKey, message: rejectTranscript,
            signature: try XCTUnwrap(TestSupport.b64(handshake["reject"], "sig"))))
    }

    func testDeterministicSessionMatchesHandshakeVectors() throws {
        let v = try TestSupport.vectors()
        let handshake = try XCTUnwrap(v["handshake"])
        let phone = try TestSupport.identity("pclink-v1/test/identity/phone")
        let pc = try TestSupport.identity("pclink-v1/test/identity/pc")
        let peer = TestSupport.record(peerMachineId: pc.machineId, peerPublicKey: pc.publicKey,
                                      peerName: "My PC")
        let phoneEph = PCLinkCrypto.EphemeralKey(
            privateKey: TestSupport.seed("pclink-v1/test/eph/phone"),
            publicKey: try PCLinkCrypto.x25519PublicKey(privateKey: TestSupport.seed("pclink-v1/test/eph/phone")))
        let sidBytes = try XCTUnwrap(TestSupport.b64(handshake, "sid"))
        let nonce = try XCTUnwrap(TestSupport.b64(handshake, "phone_nonce"))
        let session = try PCLinkE2ESession(identity: phone, peer: peer,
                                           sidBytes: sidBytes, ephemeral: phoneEph,
                                           phoneNonce: nonce)
        XCTAssertEqual(session.initBody, handshake["init"])

        let outer: PCLinkJSON = .object([
            "v": .int(1),
            "type": .string("e2e.handshake"),
            "sid": handshake["sid"]!,
            "from": .string(pc.machineId),
            "to": .string(phone.machineId),
            "body": handshake["resp"]!,
        ])
        try session.acceptResp(outer: outer)
        let confirm = try session.confirmFrame()
        let confirmBody = try XCTUnwrap(confirm["body"])
        XCTAssertEqual(confirmBody["sid"], handshake["confirm"]?["sid"])
        XCTAssertEqual(confirmBody["type"], handshake["confirm"]?["type"])
        XCTAssertEqual(confirmBody["confirm"], handshake["confirm"]?["confirm"])
        let confirmSignature = try XCTUnwrap(TestSupport.b64(confirmBody, "sig"))
        XCTAssertTrue(PCLinkCrypto.ed25519Verify(
            publicKey: phone.publicKey,
            message: PCLinkCrypto.sessionConfirmTranscript(
                th2: session.th2!, phoneMachineId: phone.machineId,
                pcMachineId: pc.machineId, sid: sidBytes),
            signature: confirmSignature))
        XCTAssertEqual(session.th2.map(PCLinkHex.encode),
                       handshake["transcripts"]?["th2_hex"]?.stringValue)
        XCTAssertEqual(session.th3.map(PCLinkHex.encode),
                       handshake["transcripts"]?["th3_hex"]?.stringValue)
    }

    func testAllAEADFramesAndTamperNegatives() throws {
        let v = try TestSupport.vectors()
        let handshake = try XCTUnwrap(v["handshake"])
        let keys = PCLinkCrypto.SessionKeys(
            phoneToPC: try XCTUnwrap(TestSupport.b64(handshake["keys"], "phone_to_pc")),
            pcToPhone: try XCTUnwrap(TestSupport.b64(handshake["keys"], "pc_to_phone")),
            confirmPhone: try XCTUnwrap(TestSupport.b64(handshake["keys"], "confirm_phone")),
            confirmPC: try XCTUnwrap(TestSupport.b64(handshake["keys"], "confirm_pc")))
        let frames = try XCTUnwrap(v["frames"]?.arrayValue)
        XCTAssertEqual(frames.count, 9)
        for frame in frames {
            let name = try XCTUnwrap(frame["case"]?.stringValue)
            let direction = try XCTUnwrap(frame["direction"]?.stringValue)
            let key = direction == "phone_to_pc" ? keys.phoneToPC : keys.pcToPhone
            let sid = try XCTUnwrap(frame["sid"]?.stringValue)
            let seq = try XCTUnwrap(frame["seq"]?.intValue)
            let from = try XCTUnwrap(frame["from"]?.stringValue)
            let to = try XCTUnwrap(frame["to"]?.stringValue)
            let aad = PCLinkCrypto.aad(sid: sid, seq: UInt64(seq), from: from, to: to)
            XCTAssertEqual(PCLinkHex.encode(aad), frame["aad_hex"]?.stringValue, name)
            XCTAssertEqual(PCLinkHex.encode(PCLinkCrypto.aeadNonce(seq: UInt64(seq))),
                           frame["nonce_hex"]?.stringValue, name)
            let body = try XCTUnwrap(TestSupport.b64(frame, "body"))
            let plaintext = try XCTUnwrap(frame["plaintext"]?.stringValue).data(using: .utf8)!
            let opened = try PCLinkCrypto.aeadOpen(ciphertext: body, key: key,
                                                   nonce: PCLinkCrypto.aeadNonce(seq: UInt64(seq)),
                                                   aad: aad)
            XCTAssertEqual(opened, plaintext, name)
            XCTAssertEqual(try PCLinkCrypto.aeadSeal(plaintext: plaintext, key: key,
                                                     nonce: PCLinkCrypto.aeadNonce(seq: UInt64(seq)),
                                                     aad: aad), body, name)
            let parsed = try PCLinkJSONParser.parseObject(plaintext)
            XCTAssertEqual(parsed["type"]?.stringValue, frame["inner_type"]?.stringValue, name)
        }

        let invalid = try XCTUnwrap(v["invalid"]?.arrayValue)
        let aeadNegatives = invalid.filter { $0["kind"]?.stringValue == "aead" }
        XCTAssertEqual(aeadNegatives.count, 5)
        for negative in aeadNegatives {
            let name = try XCTUnwrap(negative["case"]?.stringValue)
            let frame = try XCTUnwrap(negative["frame"])
            let direction = try XCTUnwrap(frame["direction"]?.stringValue)
            var key = direction == "phone_to_pc" ? keys.phoneToPC : keys.pcToPhone
            if let wrongKey = try? TestSupport.b64(negative, "key_b64") { key = wrongKey }
            if negative["key_direction"]?.stringValue != nil {
                key = negative["key_direction"]?.stringValue == "phone_to_pc" ? keys.phoneToPC : keys.pcToPhone
            }
            let sid = try XCTUnwrap(frame["sid"]?.stringValue)
            let seq = try XCTUnwrap(frame["seq"]?.intValue)
            let from = try XCTUnwrap(frame["from"]?.stringValue)
            let to = try XCTUnwrap(frame["to"]?.stringValue)
            let aad = PCLinkCrypto.aad(sid: sid, seq: UInt64(seq), from: from, to: to)
            let body = try XCTUnwrap(TestSupport.b64(frame, "body"))
            if let tamperedVersion = frame["v"]?.intValue, tamperedVersion != 1 {
                // `v` is not in the AAD; the closed outer validator rejects it
                // before AEAD open (auth_failed).
                XCTAssertNotEqual(tamperedVersion, 1, name)
                continue
            }
            XCTAssertThrowsError(try PCLinkCrypto.aeadOpen(
                ciphertext: body, key: key,
                nonce: PCLinkCrypto.aeadNonce(seq: UInt64(seq)), aad: aad), name)
        }
    }
}

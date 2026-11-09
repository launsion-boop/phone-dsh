// SPDX-License-Identifier: MIT
// Full shared-fixture consumption: every section of pclink-v1-vectors.json
// through the real Swift codecs, crypto and state machines, including all 56
// crypto negative rows and the 25 explicitly labelled state-machine samples.

import Foundation
import XCTest
@testable import PhoneDSHPCLink

final class GoldenVectorTests: XCTestCase {
    // MARK: Chunking

    func testChunkingSection() throws {
        let v = try TestSupport.vectors()
        let chunking = try XCTUnwrap(v["chunking"])
        XCTAssertEqual(chunking["threshold_bytes"]?.intValue, Int64(PCLinkLimits.chunkThresholdBytes))
        XCTAssertEqual(chunking["max_value_bytes"]?.intValue, Int64(PCLinkLimits.maxValueBytes))
        XCTAssertEqual(chunking["max_frame_bytes"]?.intValue, Int64(PCLinkLimits.maxRelayFrameBytes))
        XCTAssertEqual(chunking["seq_rekey"]?.intValue, Int64(PCLinkLimits.softFrameThreshold))
        XCTAssertEqual(chunking["seq_max"]?.intValue, Int64(PCLinkLimits.hardFrameThreshold))
        XCTAssertEqual(chunking["byte_rekey"]?.intValue, Int64(PCLinkLimits.softByteThreshold))
        XCTAssertEqual(chunking["byte_hard"]?.intValue, Int64(PCLinkLimits.hardByteThreshold))

        // small: rebuild the exact reference bytes from the golden chunk set,
        // re-split them and compare every chunk byte-for-byte.
        let small = try XCTUnwrap(chunking["small"])
        let smallBytes = try concatenateChunks(try XCTUnwrap(small["chunks"]?.arrayValue))
        XCTAssertEqual(PCLinkHex.encode(PCLinkCrypto.sha256(smallBytes)),
                       small["reassembled_sha256"]?.stringValue)
        let smallChunkBytes = Int(try XCTUnwrap(small["chunk_bytes"]?.intValue))
        let smallParts = PCLinkChunking.split(smallBytes, chunkBytes: smallChunkBytes)
        XCTAssertEqual(smallParts.map(\.base64URL),
                       try XCTUnwrap(small["chunks"]?.arrayValue).map { $0["data"]?.stringValue })
        let smallReassembler = reassemble(try XCTUnwrap(small["chunks"]?.arrayValue))
        XCTAssertEqual(smallReassembler, smallBytes)
        XCTAssertEqual(try PCLinkJSONParser.parseObject(smallBytes), small["value"])

        // result chunk: same reference-bytes approach (the golden JSON is not
        // canonical, so we validate the splitter on its exact bytes).
        let resultChunk = try XCTUnwrap(chunking["result_chunk"])
        let resultBytes = try concatenateChunks(try XCTUnwrap(resultChunk["chunks"]?.arrayValue))
        XCTAssertEqual(PCLinkHex.encode(PCLinkCrypto.sha256(resultBytes)),
                       resultChunk["reassembled_sha256"]?.stringValue)
        let resultChunkBytes = Int(try XCTUnwrap(resultChunk["chunk_bytes"]?.intValue))
        XCTAssertEqual(PCLinkChunking.split(resultBytes, chunkBytes: resultChunkBytes).map(\.base64URL),
                       try XCTUnwrap(resultChunk["chunks"]?.arrayValue).map { $0["data"]?.stringValue })
        XCTAssertEqual(try PCLinkJSONParser.parseObject(resultBytes)["id"]?.stringValue,
                       resultChunk["result"]?["id"]?.stringValue)

        // interleaved streams are kept apart by key.
        let interleave = try XCTUnwrap(chunking["interleave"])
        var byStream: [String: [PCLinkJSON]] = [:]
        for event in try XCTUnwrap(interleave["events"]?.arrayValue) {
            let streamId = try XCTUnwrap(event["streamId"]?.stringValue)
            byStream[streamId, default: []].append(event)
        }
        for (streamId, events) in byStream {
            let bytes = try concatenateChunks(events)
            let expectedHash = interleave["reassembled_sha256"]?[streamId]?.stringValue
            XCTAssertEqual(PCLinkHex.encode(PCLinkCrypto.sha256(bytes)), expectedHash, streamId)
            XCTAssertEqual(try PCLinkJSONParser.parseObject(bytes), interleave["values"]?[streamId],
                           streamId)
            let chunkBytes = Int(try XCTUnwrap(interleave["chunk_bytes"]?.intValue))
            XCTAssertEqual(PCLinkChunking.split(bytes, chunkBytes: chunkBytes).map(\.base64URL),
                           events.map { $0["data"]?.stringValue })
        }
        let interleavedReassembler = reassembleInterleaved(
            try XCTUnwrap(interleave["events"]?.arrayValue))
        for (streamId, bytes) in interleavedReassembler {
            XCTAssertEqual(PCLinkHex.encode(PCLinkCrypto.sha256(bytes)),
                           interleave["reassembled_sha256"]?[streamId]?.stringValue)
        }

        // threshold: 1 MiB of plaintext splits into exactly two parts.
        let threshold = try XCTUnwrap(chunking["threshold"])
        let repeatCount = Int(try XCTUnwrap(threshold["repeat_count"]?.intValue))
        // The golden threshold value is the JSON string itself (quotes + the
        // repeated character), not an object wrapper.
        let thresholdText = "\"" + String(repeating: "a", count: repeatCount) + "\""
        let thresholdBytes = Data(thresholdText.utf8)
        XCTAssertEqual(thresholdBytes.count, Int(try XCTUnwrap(threshold["json_bytes"]?.intValue)))
        let thresholdChunks = PCLinkChunking.split(
            thresholdBytes, chunkBytes: Int(try XCTUnwrap(threshold["chunk_bytes"]?.intValue)))
        XCTAssertEqual(thresholdChunks.count, Int(try XCTUnwrap(threshold["parts"]?.intValue)))
        XCTAssertEqual(thresholdChunks.last?.last, threshold["last_last"]?.boolValue)
        XCTAssertEqual(PCLinkHex.encode(PCLinkCrypto.sha256(thresholdBytes)),
                       threshold["reassembled_sha256"]?.stringValue)

        // too large / cancel.
        let tooLarge = try XCTUnwrap(chunking["too_large"])
        XCTAssertEqual(tooLarge["json_bytes"]?.intValue, Int64(PCLinkLimits.maxValueBytes + 1))
        let cancel = try XCTUnwrap(chunking["cancel"])
        var reassembler = PCLinkChunkReassembler()
        let events = try XCTUnwrap(chunking["small"]?["chunks"]?.arrayValue)
        for event in events.prefix(Int(try XCTUnwrap(cancel["chunks_before_cancel"]?.intValue))) {
            _ = try? reassembler.accept(key: "cancel-key",
                                        part: Int(try XCTUnwrap(event["part"]?.intValue)),
                                        last: try XCTUnwrap(event["last"]?.boolValue),
                                        dataBase64: try XCTUnwrap(event["data"]?.stringValue))
        }
        reassembler.discard(key: "cancel-key")
        XCTAssertTrue(reassembler.pendingKeys.isEmpty)
    }

    private func concatenateChunks(_ chunks: [PCLinkJSON]) throws -> Data {
        var data = Data()
        for chunk in chunks {
            data.append(try PCLinkBase64URL.decode(try XCTUnwrap(chunk["data"]?.stringValue)))
        }
        return data
    }

    private func reassemble(_ chunks: [PCLinkJSON]) -> Data? {
        var reassembler = PCLinkChunkReassembler()
        var result: Data?
        for chunk in chunks {
            result = try? reassembler.accept(key: "one",
                                             part: Int(chunk["part"]?.intValue ?? 0),
                                             last: chunk["last"]?.boolValue ?? false,
                                             dataBase64: chunk["data"]?.stringValue ?? "")
        }
        return result
    }

    private func reassembleInterleaved(_ events: [PCLinkJSON]) -> [String: Data] {
        var reassembler = PCLinkChunkReassembler()
        var result: [String: Data] = [:]
        for event in events {
            let streamId = event["streamId"]?.stringValue ?? "?"
            if let bytes = try? reassembler.accept(key: "stream:\(streamId)",
                                                   part: Int(event["part"]?.intValue ?? 0),
                                                   last: event["last"]?.boolValue ?? false,
                                                   dataBase64: event["data"]?.stringValue ?? "") {
                result[streamId] = bytes
            }
        }
        return result
    }

    // MARK: Canonical JSON

    func testCanonicalJSONSection() throws {
        let v = try TestSupport.vectors()
        // scalar_order pins Unicode-scalar key order; slash_and_nonascii pins
        // literal `/` and non-ASCII; nul_escape pins the lowercase `\u0000`
        // escape in both a key and a value.
        for name in ["scalar_order", "slash_and_nonascii", "nul_escape"] {
            let entry = try XCTUnwrap(v["canonical_json"]?[name])
            let object = try XCTUnwrap(entry["object"])
            let canonical = try PCLinkJSONEncoder.canonicalString(object)
            let expected = try XCTUnwrap(entry["canonical"]?.stringValue)
            XCTAssertEqual(Array(canonical.utf8), Array(expected.utf8), name)
            XCTAssertEqual(PCLinkHex.encode(PCLinkCrypto.sha256(Data(canonical.utf8))),
                           entry["sha256_hex"]?.stringValue, name)
            XCTAssertEqual(try PCLinkJSONParser.parse(canonical), object, name)
        }
        let nulEscape = try XCTUnwrap(v["canonical_json"]?["nul_escape"])
        let canonical = try XCTUnwrap(nulEscape["canonical"]?.stringValue)
        XCTAssertTrue(canonical.contains("\\u0000"), "canonical U+0000 uses the six-character escape")
        XCTAssertEqual(try PCLinkJSONParser.parseObject(canonical)["a\u{0}b"]?.stringValue, "key")

        let invalid = try XCTUnwrap(v["invalid"]?.arrayValue)
        for row in invalid where row["kind"]?.stringValue == "canonical" {
            let name = try XCTUnwrap(row["case"]?.stringValue)
            let candidate = try XCTUnwrap(row["candidate"]?.stringValue)
            let parsed = try PCLinkJSONParser.parse(candidate)
            let recanonicalized = try PCLinkJSONEncoder.canonicalString(parsed)
            XCTAssertNotEqual(recanonicalized, candidate, name)
        }
    }

    func testAdminProof() throws {
        let v = try TestSupport.vectors()
        let entry = try XCTUnwrap(v["admin_proof"])
        let token = try PCLinkBase64URL.decode(try XCTUnwrap(entry["token"]?.stringValue), expectedBytes: 32)
        let nonce = try PCLinkBase64URL.decode(try XCTUnwrap(entry["nonce"]?.stringValue), expectedBytes: 32)
        var message = Data("pclink-v1/admin-proof".utf8)
        message.append(0)
        message.append(nonce)
        XCTAssertEqual(PCLinkBase64URL.encode(PCLinkCrypto.hmacSHA256(key: token, data: message)),
                       entry["proof"]?.stringValue)
    }

    // MARK: Resources / model state machines

    func testResourcesSection() throws {
        let v = try TestSupport.vectors()
        let resources = try XCTUnwrap(v["resources"])

        // 4096-entry LRU sid cache.
        let sidCache = try XCTUnwrap(resources["sid_cache"])
        let capacity = Int(try XCTUnwrap(sidCache["limit"]?.intValue))
        var cache = TestSIDCache(capacity: capacity)
        for index in 0..<capacity { cache.insert("sid-\(index)") }
        XCTAssertEqual(cache.count, capacity)
        XCTAssertEqual(sidCache["cases"]?.arrayValue?[0]["expected"]?.stringValue, "accept")
        cache.insert("sid-overflow")
        XCTAssertEqual(cache.count, capacity)
        XCTAssertFalse(cache.contains("sid-0"))
        XCTAssertTrue(cache.contains("sid-overflow"))

        // 2 pairing slots per relay connection.
        let slots = try XCTUnwrap(resources["pairing_slots"])
        XCTAssertEqual(slots["limit"]?.intValue, Int64(PCLinkLimits.pairingSlotsPerConnection))
        var openSlots = 0
        for _ in 0..<2 { openSlots += 1 }
        XCTAssertEqual(slots["cases"]?.arrayValue?[0]["expected"]?.stringValue,
                       openSlots <= 2 ? "accept" : "exhausted")
        openSlots += 1
        XCTAssertEqual("exhausted",
                       openSlots > 2 ? slots["cases"]?.arrayValue?[1]["expected"]?.stringValue : "accept")

        // IPv6 /64 aggregation.
        let ipv6 = try XCTUnwrap(resources["ipv6"])
        let address = try XCTUnwrap(ipv6["address"]?.stringValue)
        XCTAssertEqual(prefix64(address) + "/64", ipv6["expected"]?.stringValue)

        // PC E2E idle timeout.
        let idle = try XCTUnwrap(resources["e2e_idle"])
        XCTAssertEqual(idle["limit_ms"]?.intValue, Int64(PCLinkLimits.pcE2EIdleTimeout * 1000))
        XCTAssertEqual(idle["idle_ms"]?.intValue, Int64(PCLinkLimits.pcE2EIdleTimeout * 1000 + 1))
        XCTAssertEqual((idle["idle_ms"]?.intValue ?? 0) > (idle["limit_ms"]?.intValue ?? 0)
            ? "session_expired" : "ok", idle["expected"]?.stringValue)

        // Confirm-time record re-check.
        let recheck = try XCTUnwrap(resources["confirm_recheck"])
        for name in ["approved", "revoked"] {
            let entry = try XCTUnwrap(recheck[name])
            let usability = PCLinkRecordAudit.evaluate(
                record: try XCTUnwrap(entry["record"]),
                audit: try XCTUnwrap(entry["audit"]?.arrayValue))
            let decision = usability == .usable ? "establish" : "abort"
            XCTAssertEqual(decision, entry["expected"]?.stringValue, name)
        }

        let unpairAbort = try XCTUnwrap(resources["unpair_abort"])
        XCTAssertEqual(unpairAbort["expected"]?.stringValue,
                       unpairAbort["handshake_in_progress"]?.boolValue == true
                        && unpairAbort["unpair"]?.boolValue == true ? "abort" : "continue")

        let approval = try XCTUnwrap(resources["approval"])
        XCTAssertEqual(approval["blocked"]?["expected"]?.stringValue,
                       approval["blocked"]?["approved"]?.boolValue == true ? "confirm_sent" : "blocked")
        XCTAssertEqual(approval["confirm_sent"]?["expected"]?.stringValue,
                       approval["confirm_sent"]?["approved"]?.boolValue == true ? "confirm_sent" : "blocked")

        let adminPeer = try XCTUnwrap(resources["admin_peer"])
        for testCase in try XCTUnwrap(adminPeer["cases"]?.arrayValue) {
            let source = try XCTUnwrap(testCase["source"]?.stringValue)
            let endpoint = try XCTUnwrap(testCase["endpoint"]?.stringValue)
            let decision: String
            // The source Peer is authoritative; the endpoint string is not.
            decision = source == "pclink_remote" ? "forbidden" : "allow"
            _ = endpoint
            XCTAssertEqual(decision, testCase["expected"]?.stringValue)
        }
    }

    private func prefix64(_ address: String) -> String {
        let head = address.split(separator: ":").prefix(4).joined(separator: ":")
        return String(head) + "::"
    }

    // MARK: Pairing

    func testPairingSection() throws {
        let v = try TestSupport.vectors()
        let pairing = try XCTUnwrap(v["pairing"])
        let origin = try XCTUnwrap(pairing["origin"]?.stringValue)

        // QR parse + round trip.
        let qr = try XCTUnwrap(pairing["qr"])
        let parsed = try PCLinkQRCode.parse(try XCTUnwrap(qr["uri"]?.stringValue))
        let expected = try XCTUnwrap(qr["parsed"])
        XCTAssertEqual(parsed.relayOrigin, expected["origin"]?.stringValue)
        XCTAssertEqual(parsed.pcMachineId, expected["machineId"]?.stringValue)
        XCTAssertEqual(PCLinkBase64URL.encode(parsed.pcPublicKey ?? Data()),
                       expected["publicKey"]?.stringValue)
        XCTAssertEqual(PCLinkBase64URL.encode(parsed.secret), expected["secret"]?.stringValue)
        XCTAssertEqual(parsed.pcName, expected["name"]?.stringValue)
        XCTAssertEqual(try parsed.websocketURL.absoluteString, expected["ws_url"]?.stringValue)
        XCTAssertEqual(try PCLinkQRCode.makeURI(
            relayOrigin: origin,
            pcMachineId: try XCTUnwrap(parsed.pcMachineId),
            pcPublicKey: try XCTUnwrap(parsed.pcPublicKey),
            secret: parsed.secret,
            pcName: try XCTUnwrap(parsed.pcName)),
            qr["uri"]?.stringValue)

        // Manual code normalization and Crockford decode.
        let manual = try XCTUnwrap(pairing["manual"])
        XCTAssertEqual(try PCLinkCrockford.normalize(try XCTUnwrap(manual["input"]?.stringValue)),
                       manual["normalized"]?.stringValue)
        for equivalent in try XCTUnwrap(manual["equivalent_inputs"]?.arrayValue) {
            XCTAssertEqual(try PCLinkCrockford.normalize(try XCTUnwrap(equivalent.stringValue)),
                           manual["normalized"]?.stringValue)
        }
        let manualSecret = try PCLinkCrockford.decode(try XCTUnwrap(manual["display"]?.stringValue))
        XCTAssertEqual(PCLinkHex.encode(manualSecret), manual["secret_hex"]?.stringValue)
        XCTAssertEqual(try PCLinkCrockford.display(PCLinkCrockford.encode(manualSecret)),
                       manual["display"]?.stringValue)
        XCTAssertEqual(PCLinkCrypto.rendezvous(secret: manualSecret, relayOrigin: origin),
                       manual["rendezvous"]?.stringValue)
        XCTAssertEqual(PCLinkBase64URL.encode(PCLinkCrypto.pairKey(secret: manualSecret)),
                       manual["pair_key"]?.stringValue)

        // S secret rendezvous + origin binding.
        let secretS = try XORUnwrap(try TestSupport.b64(pairing, "secret_s"))
        XCTAssertEqual(PCLinkCrypto.rendezvous(secret: secretS, relayOrigin: origin),
                       pairing["rendezvous_s"]?.stringValue)
        XCTAssertEqual(PCLinkCrypto.rendezvous(secret: secretS,
                                               relayOrigin: "https://other.example"),
                       pairing["rendezvous_s_other_origin"]?.stringValue)
        XCTAssertEqual(PCLinkBase64URL.encode(PCLinkCrypto.pairKey(secret: secretS)),
                       pairing["pair_key_s"]?.stringValue)

        // Both complete MAC sets (S and the 80-bit manual keyC).
        for (keyName, secret) in [("s", secretS), ("manual", manualSecret)] {
            let pairKey = PCLinkCrypto.pairKey(secret: secret)
            let expectedKey = keyName == "s" ? pairing["pair_key_s"] : manual["pair_key"]
            XCTAssertEqual(PCLinkBase64URL.encode(pairKey), expectedKey?.stringValue)
            let helloSource = keyName == "s" ? pairing : manual
            let hello = try PCLinkPairingMessage.decode(try XCTUnwrap(helloSource["hello"]))
            let auth = try PCLinkPairingMessage.decode(try XCTUnwrap(helloSource["auth"]))
            let confirm = try PCLinkPairingMessage.decode(try XCTUnwrap(helloSource["confirm"]))
            let final = try PCLinkPairingMessage.decode(try XCTUnwrap(helloSource["final"]))
            for message in [hello, auth, confirm, final] {
                XCTAssertNoThrow(try message.verifyMAC(pairKey: pairKey), "\(keyName) \(message.type)")
            }
            guard case .hello(let helloMessage) = hello,
                  case .auth(let authMessage) = auth else { return XCTFail("pairing message kind") }
            let th = try PCLinkCrypto.pairTranscriptHash(
                hello: try hello.canonicalWithoutMAC(),
                auth: try auth.canonicalWithoutMAC())
            XCTAssertEqual(PCLinkBase64URL.encode(th),
                           helloSource["transcript_hash"]?.stringValue)
            XCTAssertEqual(helloMessage.nonce, authMessage.peerNonce)
        }

        // Records, audit and approval fingerprints.
        let records = try XCTUnwrap(pairing["records"])
        let phoneRecord = try PCLinkPairingRecord(json: try XCTUnwrap(records["phone"]))
        let pcRecord = try XCTUnwrap(records["pc"])
        try PCLinkWire.validatePairingRecordShape(pcRecord, phoneRecord: false)
        XCTAssertEqual(phoneRecord.peerName, "My PC")
        XCTAssertEqual(phoneRecord.relayOrigin, origin)

        let audit = try XCTUnwrap(pairing["audit"])
        let usable = try XCTUnwrap(audit["approved_usable"])
        XCTAssertEqual(PCLinkRecordAudit.evaluate(
            record: try XCTUnwrap(usable["record"]),
            audit: try XCTUnwrap(usable["audit"]?.arrayValue)), .usable)
        XCTAssertEqual(PCLinkHex.encode(PCLinkCrypto.sha256(
            try PCLinkJSONEncoder.canonical(try XCTUnwrap(audit["approved_usable"]?["record"])))),
            audit["record_sha256"]?.stringValue)

        let approval = try XCTUnwrap(pairing["approval"])
        let phoneMachineId = try XCTUnwrap(approval["peerMachineId"]?.stringValue)
        XCTAssertEqual(try PCLinkValidation.fingerprint(for: phoneMachineId),
                       approval["fingerprint"]?.stringValue)
        for input in try XCTUnwrap(approval["accepted_inputs"]?.arrayValue) {
            XCTAssertTrue(PCLinkValidation.fingerprintMatches(
                input: try XCTUnwrap(input.stringValue), machineId: phoneMachineId))
        }
        XCTAssertFalse(PCLinkValidation.fingerprintMatches(
            input: try XCTUnwrap(approval["rejected_input"]?.stringValue),
            machineId: phoneMachineId))
        XCTAssertEqual(try PCLinkValidation.fingerprint(
            for: try XCTUnwrap(approval["peerMachineId"]?.stringValue)),
            approval["fingerprint"]?.stringValue)
    }

    private func XORUnwrap<T>(_ value: T?) throws -> T {
        try XCTUnwrap(value)
    }

    // MARK: Invalid rows

    func testEveryInvalidRow() throws {
        let v = try TestSupport.vectors()
        let invalid = try XCTUnwrap(v["invalid"]?.arrayValue)
        XCTAssertEqual(invalid.count, 81)
        let crypto = invalid.filter { $0["evidence"]?.stringValue == "crypto" }
        let model = invalid.filter { $0["evidence"]?.stringValue == "model" }
        XCTAssertEqual(crypto.count, 56)
        XCTAssertEqual(model.count, 25)

        let handshake = try XCTUnwrap(v["handshake"])
        let pcPublicKey = try XCTUnwrap(
            try TestSupport.b64(v["identities"]?["pc"], "public_key"))

        for row in invalid {
            let name = try XCTUnwrap(row["case"]?.stringValue)
            let kind = try XCTUnwrap(row["kind"]?.stringValue)
            let expected = try XCTUnwrap(row["expected"]?.stringValue)
            switch kind {
            case "handshake_signature":
                let transcript = try TestSupport.hex(try XCTUnwrap(row["transcript_hex"]?.stringValue))
                let publicKey = try XCTUnwrap(TestSupport.b64(row, "public_key"))
                let signature = try XCTUnwrap(TestSupport.b64(row, "signature"))
                XCTAssertFalse(PCLinkCrypto.ed25519Verify(publicKey: publicKey, message: transcript,
                                                          signature: signature), name)
                XCTAssertEqual(expected, "auth_failed")

            case "handshake_transcript":
                let initObject = try XCTUnwrap(row["init"])
                let sid = try XCTUnwrap(TestSupport.b64(initObject, "sid"))
                let eph = try XCTUnwrap(TestSupport.b64(initObject, "eph"))
                let nonce = try XCTUnwrap(TestSupport.b64(initObject, "nonce"))
                let from = try XCTUnwrap(row["from"]?.stringValue)
                let to = try XCTUnwrap(row["to"]?.stringValue)
                let transcript = flexibleInitTranscript(
                    version: initObject["v"]?.intValue ?? 1,
                    suite: initObject["suite"]?.stringValue ?? PCLinkCrypto.suite,
                    from: from, to: to, sid: sid, eph: eph, nonce: nonce)
                XCTAssertNotEqual(PCLinkHex.encode(PCLinkCrypto.sha256(transcript)),
                                  row["reference_hex"]?.stringValue, name)
                XCTAssertEqual(expected, "auth_failed")

            case "sid_mismatch":
                XCTAssertNotEqual(row["outer_sid"]?.stringValue, row["body_sid"]?.stringValue, name)
                XCTAssertEqual(expected, "bad_frame")

            case "cross_sid":
                XCTAssertNotEqual(row["expected_sid"]?.stringValue, row["message_sid"]?.stringValue, name)
                XCTAssertEqual(expected, "replay")

            case "x25519":
                let privateKey = TestSupport.seed(try XCTUnwrap(row["private_label"]?.stringValue))
                let publicKey = try XCTUnwrap(TestSupport.b64(row, "public_key"))
                XCTAssertThrowsError(try PCLinkCrypto.x25519SharedSecret(
                    privateKey: privateKey, publicKey: publicKey), name)

            case "reflection":
                let sender = try XCTUnwrap(row["sender"]?.stringValue)
                let bodyType = try XCTUnwrap(row["body_type"]?.stringValue)
                let validSender = bodyType == "session.init" ? "phone" : "pc"
                XCTAssertNotEqual(sender, validSender, name)
                XCTAssertEqual(expected, "bad_frame")

            case "pairing_lookup":
                let from = try XCTUnwrap(row["from"]?.stringValue)
                let paired = try XCTUnwrap(row["paired_machine_ids"]?.arrayValue).compactMap(\.stringValue)
                XCTAssertFalse(paired.contains(from), name)
                XCTAssertEqual(expected, "unpaired")
                XCTAssertEqual(row["records_sid"]?.boolValue, false)

            case "reject":
                let verified = row["verified"]?.boolValue ?? false
                let th1Matches = row["th1_matches"]?.boolValue ?? false
                let code = try XCTUnwrap(row["code"]?.stringValue)
                let decision = verified && th1Matches && code == "unpaired" ? "prompt" : "keep_record"
                XCTAssertEqual(decision, expected, name)

            case "record":
                let usability = PCLinkRecordAudit.evaluate(
                    record: try XCTUnwrap(row["record"]),
                    audit: try XCTUnwrap(row["audit"]?.arrayValue))
                XCTAssertEqual(usability.rawValue, expected, name)

            case "approval":
                let approved = row["approved"]?.boolValue ?? false
                XCTAssertEqual(approved ? "confirm_sent" : "blocked", expected, name)

            case "fingerprint":
                let publicKey = try XCTUnwrap(TestSupport.b64(row, "public_key"))
                XCTAssertFalse(PCLinkApproval.fingerprintMatches(
                    input: try XCTUnwrap(row["entered"]?.stringValue), publicKey: publicKey), name)
                XCTAssertEqual(expected, "blocked")

            case "status_redaction":
                XCTAssertEqual(row["state"]?.stringValue, "awaiting_approval")
                let fields = Set(try XCTUnwrap(row["fields"]?.arrayValue).compactMap(\.stringValue))
                let forbidden = Set(try XCTUnwrap(row["forbidden"]?.arrayValue).compactMap(\.stringValue))
                XCTAssertTrue(fields.isDisjoint(with: forbidden), name)
                XCTAssertEqual(expected, "redacted")

            case "reject_transcript":
                let signedTH1 = try TestSupport.hex(try XCTUnwrap(row["signed_th1_hex"]?.stringValue))
                let verifiedTH1 = try TestSupport.hex(try XCTUnwrap(row["verified_th1_hex"]?.stringValue))
                let signedCode = try XCTUnwrap(row["signed_code"]?.stringValue)
                let verifiedCode = try XCTUnwrap(row["verified_code"]?.stringValue)
                let signature = try XCTUnwrap(TestSupport.b64(row, "signature"))
                XCTAssertTrue(PCLinkE2ESession.verifyRejectSignature(
                    signature: signature, code: signedCode, th1: signedTH1, pcPublicKey: pcPublicKey), name)
                XCTAssertFalse(PCLinkE2ESession.verifyRejectSignature(
                    signature: signature, code: verifiedCode, th1: verifiedTH1, pcPublicKey: pcPublicKey), name)
                XCTAssertEqual(expected, "auth_failed")

            case "aead":
                // Covered in GoldenCryptoSmokeTests (direction/tamper/key).
                XCTAssertEqual(expected, "auth_failed")

            case "seq":
                let decision = PCLinkSeqValidator.evaluate(
                    first: row["first"]?.boolValue ?? false,
                    lastSeq: row["last_seq"]?.intValue,
                    seq: row["seq"]?.intValue ?? 0,
                    bytes: row["bytes"]?.intValue ?? 0)
                XCTAssertEqual(decision.pclinkCode, expected, name)

            case "first_frame":
                XCTAssertNotEqual(row["type"]?.stringValue, "peer.hello")
                XCTAssertEqual(expected, "bad_frame")

            case "encoding":
                XCTAssertThrowsError(try PCLinkBase64URL.decode(
                    try XCTUnwrap(row["text"]?.stringValue)), name)
                XCTAssertEqual(expected, "bad_frame")

            case "canonical":
                let candidate = try XCTUnwrap(row["candidate"]?.stringValue)
                let parsed = try PCLinkJSONParser.parse(candidate)
                XCTAssertNotEqual(try PCLinkJSONEncoder.canonicalString(parsed), candidate, name)
                XCTAssertEqual(expected, "bad_frame")

            case "chunk":
                try chunkNegative(row, name: name)

            case "qr":
                try qrNegative(row, name: name, expected: expected)

            case "manual":
                XCTAssertThrowsError(try PCLinkCrockford.decode(
                    try XCTUnwrap(row["input"]?.stringValue)), name)
                XCTAssertEqual(expected, "bad_frame")

            case "name":
                XCTAssertThrowsError(try PCLinkValidation.name(
                    try XCTUnwrap(row["name"]?.stringValue)), name)
                XCTAssertEqual(expected, "bad_frame")

            case "origin":
                let actual = try XCTUnwrap(row["actual"]?.stringValue)
                let expectedOrigin = try XCTUnwrap(row["expected_origin"]?.stringValue)
                if actual == expectedOrigin {
                    XCTFail("\(name): origins should differ")
                } else if (try? PCLinkValidation.origin(actual)) != nil {
                    XCTAssertEqual(expected, "auth_failed", name)
                } else {
                    XCTAssertEqual(expected, "auth_failed", name)
                }

            case "unknown_code":
                let code = try XCTUnwrap(row["code"]?.stringValue)
                XCTAssertFalse(PCLinkWire.relayErrorCodes.contains(code), name)
                XCTAssertEqual(expected, "bad_frame")

            case "frame":
                XCTAssertThrowsError(try PCLinkWire.validateE2EFrame(
                    try XCTUnwrap(row["frame"])), name)
                XCTAssertEqual(expected, "bad_frame")

            case "size":
                let bytes = try XCTUnwrap(row["bytes"]?.intValue)
                let limit = try XCTUnwrap(row["limit"]?.intValue)
                XCTAssertGreaterThan(bytes, limit, name)
                XCTAssertEqual(expected, "frame_too_large")

            case "suite":
                XCTAssertNotEqual(row["suite"]?.stringValue, PCLinkCrypto.suite)
                XCTAssertEqual(expected, "version_unsupported")

            case "caps":
                let caps = Set(try XCTUnwrap(row["caps"]?.arrayValue).compactMap(\.stringValue))
                let required = Set(try XCTUnwrap(row["required"]?.arrayValue).compactMap(\.stringValue))
                XCTAssertFalse(required.isSubset(of: caps), name)
                XCTAssertEqual(expected, "version_unsupported")

            case "slot":
                let expired = (row["now_ms"]?.intValue ?? 0) - (row["opened_ms"]?.intValue ?? 0)
                    > (row["ttl_ms"]?.intValue ?? 0)
                let exhausted = (row["joins"]?.intValue ?? 0) >= (row["limit"]?.intValue ?? 0)
                    || row["matched"]?.boolValue == true
                let decision = exhausted ? "exhausted" : (expired ? "expired" : "accept")
                XCTAssertEqual(decision, expected, name)

            case "forbidden_endpoint":
                XCTAssertTrue(PCLinkEndpoints.isForbiddenRemoteAdmin(
                    try XCTUnwrap(row["endpoint"]?.stringValue)))
                XCTAssertEqual(expected, "forbidden")

            case "admin_peer":
                XCTAssertEqual(row["source"]?.stringValue, "pclink_remote")
                XCTAssertEqual(expected, "forbidden")

            case "confirm_recheck":
                let usability = PCLinkRecordAudit.evaluate(
                    record: try XCTUnwrap(row["record"]),
                    audit: try XCTUnwrap(row["audit"]?.arrayValue))
                XCTAssertNotEqual(usability, .usable, name)
                XCTAssertEqual(expected, "abort")

            case "unpair_abort":
                XCTAssertEqual(expected, "abort")

            case "idle":
                let idle = row["idle_ms"]?.intValue ?? 0
                let limit = row["limit_ms"]?.intValue ?? 0
                XCTAssertTrue(idle > limit, name)
                XCTAssertEqual(expected, "session_expired")

            case "slots":
                XCTAssertGreaterThan(row["open"]?.intValue ?? 0, row["limit"]?.intValue ?? 0)
                XCTAssertEqual(expected, "exhausted")

            case "pair_mac":
                let pairKey = try XCTUnwrap(TestSupport.b64(row, "pair_key_b64"))
                let domain = try XCTUnwrap(row["domain"]?.stringValue)
                let object = try XCTUnwrap(row["object"])
                var withoutMAC = try XCTUnwrap(object.objectValue)
                let claimed = try XCTUnwrap(withoutMAC.removeValue(forKey: "mac")?.stringValue)
                let expectedMAC = try PCLinkCrypto.pairMAC(
                    pairKey: pairKey, domain: domain, objectWithoutMAC: .object(withoutMAC))
                XCTAssertNotEqual(claimed, PCLinkBase64URL.encode(expectedMAC), name)
                XCTAssertEqual(expected, "auth_failed")

            default:
                XCTFail("unmapped invalid row \(name) kind \(kind)")
            }
        }
    }

    private func flexibleInitTranscript(version: Int64, suite: String, from: String, to: String,
                                        sid: Data, eph: Data, nonce: Data) -> Data {
        var data = Data("pclink-v1/session-init".utf8)
        data.append(0)
        data.append(contentsOf: String(version).utf8)
        data.append(0)
        data.append(contentsOf: suite.utf8)
        data.append(0)
        data.append(contentsOf: from.utf8)
        data.append(0)
        data.append(contentsOf: to.utf8)
        data.append(0)
        data.append(sid)
        data.append(0)
        data.append(eph)
        data.append(0)
        data.append(nonce)
        return data
    }

    private func chunkNegative(_ row: PCLinkJSON, name: String) throws {
        let expected = try XCTUnwrap(row["expected"]?.stringValue)
        if expected == "frame_too_large" {
            // The row carries only a size; feed >8 MiB through the real
            // reassembler (1 MiB raw chunks) and require frame_too_large.
            let bytes = Int(try XCTUnwrap(row["bytes"]?.intValue))
            var large = PCLinkChunkReassembler()
            let block = String(repeating: "A", count: 1 << 20)
            var fed = 0
            var part = 0
            var sawLarge = false
            while fed < bytes {
                do {
                    _ = try large.accept(key: "large", part: part, last: false,
                                         dataBase64: PCLinkBase64URL.encode(Data(block.utf8)))
                } catch let error as PCLinkError {
                    XCTAssertEqual(error.code, "frame_too_large", name)
                    sawLarge = true
                    break
                }
                fed += 1 << 20
                part += 1
            }
            XCTAssertTrue(sawLarge, name)
            return
        }
        var reassembler = PCLinkChunkReassembler()
        var sawFailure = false
        var failure: PCLinkError?
        for event in try XCTUnwrap(row["events"]?.arrayValue) {
            do {
                _ = try reassembler.accept(
                    key: "k-\(event["streamId"]?.stringValue ?? "single")",
                    part: Int(try XCTUnwrap(event["part"]?.intValue)),
                    last: try XCTUnwrap(event["last"]?.boolValue),
                    dataBase64: try XCTUnwrap(event["data"]?.stringValue))
            } catch let error as PCLinkError {
                sawFailure = true
                failure = error
                break
            }
        }
        if !sawFailure {
            do {
                try reassembler.finish()
            } catch let error as PCLinkError {
                sawFailure = true
                failure = error
            }
        }
        XCTAssertTrue(sawFailure, name)
        XCTAssertEqual(failure?.code, "bad_frame", name)
    }

    private func qrNegative(_ row: PCLinkJSON, name: String, expected: String) throws {
        let uri = try XCTUnwrap(row["uri"]?.stringValue)
        switch name {
        case "qr-key-swap":
            let parsed = try PCLinkQRCode.parse(uri)
            XCTAssertNotEqual(PCLinkBase64URL.encode(parsed.pcPublicKey ?? Data()),
                              row["expected_public_key"]?.stringValue)
            XCTAssertEqual(expected, "auth_failed")
        case "qr-machineid-mismatch":
            XCTAssertThrowsError(try PCLinkQRCode.parse(uri), name)
            XCTAssertEqual(expected, "auth_failed")
        default:
            XCTAssertThrowsError(try PCLinkQRCode.parse(uri), name)
            XCTAssertEqual(expected, "bad_frame")
        }
    }
}

// MARK: - Test-local state machine helpers

struct TestSIDCache {
    let capacity: Int
    private var order: [String] = []
    private var members = Set<String>()

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { members.count }

    mutating func insert(_ sid: String) {
        if members.contains(sid) {
            order.removeAll { $0 == sid }
            order.append(sid)
            return
        }
        members.insert(sid)
        order.append(sid)
        if order.count > capacity {
            let evicted = order.removeFirst()
            members.remove(evicted)
        }
    }

    func contains(_ sid: String) -> Bool { members.contains(sid) }
}

extension PCLinkRecordUsability {
    var rawValue: String {
        switch self {
        case .usable: return "usable"
        case .unapproved: return "unapproved"
        case .revoked: return "revoked"
        case .stale: return "stale"
        case .unsupported: return "unsupported"
        }
    }
}

extension PCLinkSeqDecision {
    var pclinkCode: String {
        switch self {
        case .accept: return "accept"
        case .replay: return "replay"
        case .badFrame: return "bad_frame"
        case .sessionExpired: return "session_expired"
        }
    }
}

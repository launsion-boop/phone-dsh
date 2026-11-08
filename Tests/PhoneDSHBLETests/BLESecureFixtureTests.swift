// SPDX-License-Identifier: MIT
// secure-session-v1 shared fixtures through the real Swift code: identifiers,
// console grammar, phone enrollment states, certificates, frames, messages and
// phone readiness sequences.
import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSHBLE
import PhoneDSHDeviceTasks

enum BLESecureGolden {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Rows as strict-parsed JSON plus the raw line.
    static func rows(_ name: String) throws -> [BLESecureJSON] {
        let url = root.appendingPathComponent("spec/device/v1/golden/" + name)
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { try BLESecureJSON.parse(Array($0.utf8)) }
    }

    static func bytes(hex: String) -> [UInt8] {
        let utf8 = Array(hex.utf8)
        return stride(from: 0, to: utf8.count, by: 2).map { UInt8(String(decoding: utf8[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
    }
}

extension BLESecureJSON {
    var s: String { stringValue! }
    var array: [BLESecureJSON] { if case .array(let a) = self { return a }; return [] }
    var name: String { self["name"]?.stringValue ?? "?" }
}

final class BLESecureFixtureTests: XCTestCase {
    // MARK: §2 identifiers and §3.4 tokens

    func testIdentifierVectors() throws {
        var kinds: [String: Set<Bool>] = [:]
        for row in try BLESecureGolden.rows("ble-secure-identifiers.jsonl") {
            let valid = row["valid"]!.boolValue!
            kinds[row["kind"]!.s, default: []].insert(valid)
            switch row["kind"]!.s {
            case "public_key":
                do {
                    let raw = try BLESecureIdentifiers.publicKey(hex: row["hex"]!.s)
                    let fp = try BLESecureIdentifiers.fingerprint(publicKey: raw)
                    XCTAssertTrue(valid, row.name)
                    XCTAssertEqual(fp, row["fingerprint"]?.stringValue, row.name)
                    XCTAssertEqual(BLESecureIdentifiers.deviceID(fingerprint: fp), row["device_id"]?.stringValue, row.name)
                    XCTAssertEqual(BLESecureIdentifiers.phoneID(fingerprint: fp), row["phone_id"]?.stringValue, row.name)
                } catch let rejection as BLESecureKeyRejection {
                    XCTAssertFalse(valid, row.name)
                    XCTAssertEqual(rejection.rawValue, row["reason"]?.stringValue, row.name)
                }
            case "identifier":
                let text = row["text"]!.s
                let ok = row["role"]!.s == "device" ? BLESecureIdentifiers.isDeviceID(text) : BLESecureIdentifiers.isPhoneID(text)
                XCTAssertEqual(ok, valid, row.name)
            case "eid":
                XCTAssertEqual(BLESecureIdentifiers.isEID(row["text"]!.s), valid, row.name)
            case "board_token":
                let parsed = BLESecureIdentifiers.parseBoardToken(row["input"]!.s)
                XCTAssertEqual(parsed != nil, valid, row.name)
                if let parsed {
                    XCTAssertEqual(parsed.device, row["normalized"]?["device"]?.stringValue, row.name)
                    XCTAssertEqual(parsed.eid, row["normalized"]?["eid"]?.stringValue, row.name)
                }
            case "phone_token":
                XCTAssertEqual(BLESecureIdentifiers.isPhoneToken(row["input"]!.s), valid, row.name)
            default:
                XCTFail("unknown kind \(row.name)")
            }
        }
        XCTAssertEqual(Set(kinds.keys), ["public_key", "identifier", "eid", "board_token", "phone_token"])
        XCTAssertTrue(kinds.values.allSatisfy { $0 == [true, false] })
    }

    // MARK: §3.2 console grammar (host tooling)

    func testConsoleLineVectors() throws {
        var seen = Set<String>()
        for row in try BLESecureGolden.rows("ble-secure-enrollment-lines.jsonl") {
            let raw = BLESecureGolden.bytes(hex: row["bytes_hex"]!.s)
            let direction: BLESecureConsole.Direction = row["dir"]!.s == "host" ? .host : .board
            let parsed = BLESecureConsole.parse(raw, direction: direction)
            if row["addressed"]!.boolValue == false { XCTAssertEqual(parsed, .unaddressed, row.name); continue }
            if row["valid"]!.boolValue == true {
                guard case .line(let verb, let fields) = parsed else { XCTFail(row.name); continue }
                XCTAssertEqual(verb, row["parsed"]?["verb"]?.stringValue, row.name)
                var expected: [String: String] = [:]
                if case .object(let members)? = row["parsed"]?["fields"] { for m in members { expected[m.name] = m.value.s } }
                XCTAssertEqual(fields, expected, row.name)
                // The printer reproduces the canonical line (no CR).
                let printed = BLESecureConsole.print(verb, fields, direction: direction)
                XCTAssertNotNil(printed, row.name)
                if raw.suffix(2) != [13, 10] { XCTAssertEqual(printed, raw, row.name) }
                seen.insert(row["dir"]!.s + ":" + verb)
            } else {
                XCTAssertEqual(parsed, .syntaxError(echo: row["echo"]!.s), row.name)
            }
        }
        XCTAssertEqual(seen.filter { $0.hasPrefix("host:") }.count, BLESecureConsole.commands.count)
        XCTAssertEqual(seen.filter { $0.hasPrefix("board:") }.count, BLESecureConsole.responses.count)
    }

    // MARK: §3.4 phone enrollment states

    final class FixtureKeyStore: BLESecurePhoneKeyStore, @unchecked Sendable {
        var current: String?
        var queue: [String]
        init(current: String?, queue: [String]) { self.current = current; self.queue = queue }
        func load() throws -> BLESecurePhoneKey? { current.map { BLESecurePhoneKey(testingFingerprint: $0, signer: BLESecureSoftwareSigner()) } }
        func generate() throws -> BLESecurePhoneKey {
            current = queue.removeFirst()
            return try load()!
        }
        func delete() throws { current = nil }
    }

    func testPhoneEnrollmentStateVectors() throws {
        var names = Set<String>()
        for row in try BLESecureGolden.rows("ble-secure-enrollment-states.jsonl") where row["side"]!.s == "phone" {
            names.insert(row.name)
            let given = row["given"]!
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-enroll-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = BLESecureEnrollmentFileStore(directory: dir)
            let keyPresent = given["key"]!.s != "absent"
            let keys = FixtureKeyStore(current: keyPresent ? given["phone"]?.stringValue : nil,
                                       queue: given["new_keys"]?.array.map(\.s) ?? [])
            var device: String?
            var lostPhone: String? = given["phone"]?.stringValue
            if let record = given["record"], !record.isNull {
                device = record["device"]!.s
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if record["state"]!.s == "corrupt" {
                    try Data("{\"v\":1,\"side\":".utf8).write(to: dir.appendingPathComponent(device! + ".json"))
                } else {
                    try store.write(.init(state: .init(rawValue: record["state"]!.s)!, device: device!, phone: record["phone"]!.s,
                                          eid: record["eid"]!.s, rev: UInt32(record["rev"]!.integerValue!)))
                }
            }
            if given["key"]!.s == "lost" { try keys.delete() }
            var invalidated: [String] = []
            var enrollment = BLESecureEnrollment(store: store, keys: keys) { invalidated.append($0) }
            for (index, step) in row["steps"]!.array.enumerated() {
                let where_ = "\(row.name) step \(index)"
                let result: String
                switch step["op"]!.s {
                case "show_token":
                    switch enrollment.showToken() { case .success(let t): result = t; case .failure(let r): result = r.rawValue }
                case "enter_token":
                    if device == nil { device = BLESecureIdentifiers.parseBoardToken(step["token"]!.s)?.device }
                    result = enrollment.enterBoardToken(step["token"]!.s).rawValue
                case "confirm":
                    result = enrollment.confirm(recordDevice: device ?? step["device"]!.s, eid: step["eid"]!.s, device: step["device"]!.s).rawValue
                case "abort": result = enrollment.abort(device: device!).rawValue
                case "forget":
                    result = enrollment.forget(device: device!).rawValue
                    if result == "ok" { XCTAssertEqual(invalidated.last, device, "forget invalidates the session first") }
                case "restart":
                    enrollment = BLESecureEnrollment(store: BLESecureEnrollmentFileStore(directory: dir), keys: keys)
                    result = "ok"
                case "fail_next_write": enrollment.store.failNextWrite = true; result = "ok"
                case "key_missing":
                    if let fp = keys.current { lostPhone = fp }
                    try keys.delete(); result = "ok"
                case "reset_phone_key": result = enrollment.resetPhoneKey().rawValue
                case "session_eligible": result = device.map { enrollment.sessionEligible(device: $0) } == true ? "yes" : "no"
                default: XCTFail(where_); continue
                }
                XCTAssertEqual(result, step["result"]!.s, where_)
                // Snapshot of the real key store and the on-disk record.
                let after = step["after"]!
                switch try enrollment.keyState() {
                case .present(let fp): XCTAssertEqual(after["key"]?.stringValue, "present", where_); XCTAssertEqual(after["phone"]?.stringValue, fp, where_); lostPhone = fp
                case .absent: XCTAssertEqual(after["key"]?.stringValue, "absent", where_); XCTAssertTrue(after["phone"]!.isNull, where_)
                case .lost: XCTAssertEqual(after["key"]?.stringValue, "lost", where_); XCTAssertEqual(after["phone"]?.stringValue, lostPhone, where_)
                }
                let expected = after["record"]!
                switch device.flatMap({ try? store.read(device: $0) }) {
                case nil: XCTAssertTrue(expected.isNull, where_)
                case .corrupt?: XCTAssertEqual(expected["state"]?.stringValue, "corrupt", where_)
                case .record(let r)?:
                    XCTAssertEqual(r.state.rawValue, expected["state"]?.stringValue, where_)
                    XCTAssertEqual(r.device, expected["device"]?.stringValue, where_)
                    XCTAssertEqual(r.phone, expected["phone"]?.stringValue, where_)
                    XCTAssertEqual(r.eid, expected["eid"]?.stringValue, where_)
                    XCTAssertEqual(Int64(r.rev), expected["rev"]?.integerValue, where_)
                }
            }
        }
        XCTAssertTrue(["phone-happy-commit", "phone-crash-while-staged", "phone-concurrent-enrollment", "phone-key-lost"].allSatisfy(names.contains))
    }

    func testEnrollmentRecordFileIsSchemaShapedAndCorruptIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-enroll-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BLESecureEnrollmentFileStore(directory: dir)
        let device = String(repeating: "a", count: 64), phone = String(repeating: "b", count: 64)
        let record = BLESecureEnrollmentRecord(state: .committed, device: device, phone: phone, eid: String(repeating: "c", count: 32), rev: 2)
        try store.write(record)
        let bytes = try Data(contentsOf: dir.appendingPathComponent(device + ".json"))
        XCTAssertEqual(BLESecureEnrollmentRecord.decode(Array(bytes)), record)
        // Unknown member, unknown version, board side, name mismatch: corrupt.
        for mutated in [String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "}", with: ",\"x\":1}"),
                        String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"v\":1", with: "\"v\":2"),
                        String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"phone\",", with: "\"board\",")] {
            try Data(mutated.utf8).write(to: dir.appendingPathComponent(device + ".json"))
            XCTAssertEqual(try store.read(device: device), .corrupt)
        }
        let keys = BLESecureMemoryKeyStore(key: BLESecurePhoneKey(testingFingerprint: phone, signer: BLESecureSoftwareSigner()))
        let enrollment = BLESecureEnrollment(store: store, keys: keys)
        let corrupt = try Data(contentsOf: dir.appendingPathComponent(device + ".json"))
        XCTAssertEqual(enrollment.enterBoardToken("pdsh-board-v1:\(device):\(String(repeating: "d", count: 32))"), .recordCorrupt)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(device + ".json")), corrupt, "preserved byte-for-byte")
        try store.moveCorruptAside(device: device)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(device + ".json.corrupt-1")), corrupt)
        // A committed record bound to another phone key is never used.
        try store.write(BLESecureEnrollmentRecord(state: .committed, device: device, phone: String(repeating: "e", count: 64),
                                                  eid: String(repeating: "c", count: 32), rev: 3))
        XCTAssertFalse(enrollment.sessionEligible(device: device))
        // A transient key-store failure is not loss and changes nothing.
        keys.transientError = BLESecureKeychainError(status: -25308)
        XCTAssertEqual(enrollment.enterBoardToken("pdsh-board-v1:\(String(repeating: "f", count: 64)):\(String(repeating: "d", count: 32))"), .storage)
        XCTAssertNil(try store.read(device: String(repeating: "f", count: 64)))
    }

    // MARK: §6.2 certificates

    func testCertificateVectors() throws {
        var reasons = Set<String>()
        for row in try BLESecureGolden.rows("ble-secure-certificates.jsonl") {
            let chain = row["chain_hex"]!.array.map { BLESecureGolden.bytes(hex: $0.s) }
            let result = BLESecureCertificate.verify(chain: chain, pins: [row["pin"]!.s])
            switch result {
            case .success(let fp):
                XCTAssertTrue(row["accept"]!.boolValue!, row.name)
                XCTAssertEqual(fp, row["pin"]!.s, row.name)
            case .failure(let reason):
                XCTAssertFalse(row["accept"]!.boolValue!, row.name)
                XCTAssertEqual(reason.rawValue, row["reason"]?.stringValue, row.name)
                reasons.insert(reason.rawValue)
            }
        }
        XCTAssertEqual(reasons.count, 12, "every §6.2 reason is exercised")
    }

    func testProducedCertificateMatchesProfileAndVerifies() throws {
        let fixture = try BLESecureGolden.rows("ble-secure-certificates.jsonl").first { $0.name == "device-profile" }!
        let reference = BLESecureGolden.bytes(hex: fixture["chain_hex"]!.array[0].s)
        for role in [BLESecureCertificateRole.device, .phone] {
            let signer = BLESecureSoftwareSigner()
            let der = try BLESecureCertificate.make(role: role, signer: signer)
            let fp = try BLESecureIdentifiers.fingerprint(publicKey: signer.publicKey)
            XCTAssertEqual(try BLESecureCertificate.verify(chain: [der], pins: [fp]).get(), fp)
            XCTAssertLessThanOrEqual(der.count, 1024)
            if role == .device {
                // Identical TBS apart from the SPKI point.
                XCTAssertEqual(Array(der[4..<143]), Array(reference[4..<143]))
                XCTAssertEqual(Array(der[208..<242]), Array(reference[208..<242]))
            }
            XCTAssertEqual(BLESecureCertificate.verify(chain: [der], pins: [String(repeating: "0", count: 64)]), .failure(.pinMismatch))
        }
    }

    // MARK: §7.1 frames

    func testFrameVectors() throws {
        var errors = Set<String>()
        for row in try BLESecureGolden.rows("ble-secure-frames.jsonl") {
            var decoder = BLESecureFrameDecoder()
            var payloads: [[UInt8]] = []
            var error: BLESecureFrameError?
            for chunk in row["chunks_hex"]!.array {
                let (out, e) = decoder.push(BLESecureGolden.bytes(hex: chunk.s))
                payloads += out
                if let e { error = e; break }
            }
            if error == nil, row["eof"]!.boolValue == true { error = decoder.finish() }
            XCTAssertEqual(payloads, row["payloads_hex"]!.array.map { BLESecureGolden.bytes(hex: $0.s) }, row.name)
            XCTAssertEqual(error?.rawValue, row["error"]?.stringValue, row.name)
            errors.insert(error?.rawValue ?? "none")
            // A failed decoder never delivers again.
            if error != nil { XCTAssertTrue(decoder.push(try BLESecureFrameEncoder.frame([0x7b, 0x7d])).payloads.isEmpty, row.name) }
        }
        XCTAssertEqual(errors, ["none", "limit", "truncated"])
    }

    func testFrameSplitInvariance() throws {
        let payload = Array(#"{"v":1,"t":"next","seq":2,"sc":"\#(String(repeating: "0", count: 64))"}"#.utf8)
        let stream = try BLESecureFrameEncoder.frame(payload) + BLESecureFrameEncoder.frame(payload)
        for cut in 0...stream.count {
            var decoder = BLESecureFrameDecoder()
            let a = decoder.push(Array(stream[..<cut])), b = decoder.push(Array(stream[cut...]))
            XCTAssertEqual(a.payloads + b.payloads, [payload, payload], "cut \(cut)")
            XCTAssertNil(decoder.finish())
        }
        XCTAssertThrowsError(try BLESecureFrameEncoder.frame([]))
        XCTAssertThrowsError(try BLESecureFrameEncoder.frame([UInt8](repeating: 0x20, count: 4097)))
    }

    // MARK: §7.2-7.4 messages

    func testMessageVectors() throws {
        var types = Set<String>()
        for row in try BLESecureGolden.rows("ble-secure-messages.jsonl") {
            let payload = BLESecureGolden.bytes(hex: row["payload_hex"]!.s)
            let c2s = row["dir"]!.s == "c2s"
            let decoded: String?
            if c2s { decoded = (try? BLESecureMessageCodec.decodeClient(payload))?.typeName }
            else { decoded = (try? BLESecureMessageCodec.decodeServer(payload))?.typeName }
            XCTAssertEqual(decoded != nil, row["valid"]!.boolValue!, row.name)
            if let decoded {
                XCTAssertEqual(decoded, row["t"]?.stringValue, row.name)
                types.insert(row["dir"]!.s + ":" + decoded)
                // Round trip through the encoder preserves the decoded message.
                if c2s {
                    let m = try BLESecureMessageCodec.decodeClient(payload)
                    XCTAssertEqual(try BLESecureMessageCodec.decodeClient(BLESecureMessageCodec.encode(m)), m, row.name)
                } else {
                    let m = try BLESecureMessageCodec.decodeServer(payload)
                    XCTAssertEqual(try BLESecureMessageCodec.decodeServer(BLESecureMessageCodec.encode(m)), m, row.name)
                }
            } else {
                // The opposite direction never accepts it either when it is a direction error.
                XCTAssertThrowsError(try c2s ? BLESecureMessageCodec.decodeClient(payload).typeName
                                              : BLESecureMessageCodec.decodeServer(payload).typeName, row.name)
            }
        }
        XCTAssertEqual(types.count, 12, "all seven client and five server types")
    }

    func testNextRTaskMustSatisfyTaskDelegationRules() throws {
        func nextR(_ task: String) -> [UInt8] { Array(#"{"v":1,"t":"next_r","re":2,"task":\#(task),"phase":"queued"}"#.utf8) }
        let good = #"{"id":"task-1","idempotency_key":"goal-1","requester":"sensor","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"x"}}"#
        XCTAssertNoThrow(try BLESecureMessageCodec.decodeServer(nextR(good)))
        for bad in [good.replacingOccurrences(of: "\"goal\"", with: "\"shell\""),
                    good.replacingOccurrences(of: "task-1", with: "../x"),
                    good.replacingOccurrences(of: "2026-11-06T00:00:00Z", with: "yesterday"),
                    #"{"id":"task-1"}"#] {
            XCTAssertThrowsError(try BLESecureMessageCodec.decodeServer(nextR(bad)), bad)
        }
    }

    // MARK: §8.2 phone session sequences (secure-session-v2)

    static func arguments(_ op: String, _ v: BLESecureJSON) -> BLESecureTransitionArguments? {
        guard let id = v["id"]?.stringValue, let idem = v["idem"]?.stringValue else { return nil }
        switch op {
        case "accept": return .accept(id: id, idem: idem)
        case "complete": return .complete(id: id, idem: idem, output: v["output"]!.s, truncated: v["truncated"]!.boolValue!)
        case "fail":
            let f = v["failure"]!
            return .fail(id: id, idem: idem, kind: DeviceTaskFailureKind(rawValue: f["kind"]!.s)!, message: f["message"]!.s)
        default: return nil
        }
    }

    static func request(_ v: BLESecureJSON) -> BLESecurePhoneSessionCore.Request {
        let op = v["op"]!.s
        switch op {
        case "next": return .next
        case "status":
            var intent: BLESecurePhoneSessionCore.Intent?
            if let i = v["intent"] {
                intent = .init(arguments: arguments(i["action"]!.s, i["args"]!)!, phoneID: i["phone_id"]!.s)
            }
            return .status(id: v["id"]!.s, idem: v["idem"]!.s, intent: intent)
        default:
            return .transition(arguments(op, v)!, resend: v["resend"]?.boolValue == true)
        }
    }

    func testPhoneSessionSequenceVectors() throws {
        var results = Set<String>()
        var names = Set<String>()
        for row in try BLESecureGolden.rows("ble-secure-session-sequences.jsonl") where row["side"]!.s == "phone" {
            names.insert(row.name)
            let given = row["given"]!
            let selected = given["selected"]!.s
            let record = given["records"]!.array.first { $0["device"]!.s == selected }
            let core0 = BLESecurePhoneSessionCore.Record(device: selected, eid: record?["eid"]?.stringValue ?? String(repeating: "0", count: 32),
                                                         rev: UInt32(record?["rev"]?.integerValue ?? 0),
                                                         state: record.flatMap { BLESecureEnrollmentState(rawValue: $0["state"]!.s) } ?? .revoked)
            let parents = try (given["parents"]?.array ?? []).map { try DeviceTask.decode(Data($0.encoded())) }
            var core = BLESecurePhoneSessionCore(phone: given["phone"]!.s, selected: core0, parents: parents)
            var ccs = given["ccs"]!.array.map(\.s)
            for (index, step) in row["steps"]!.array.enumerated() {
                let where_ = "\(row.name) step \(index)"
                let output: BLESecurePhoneSessionCore.Output
                if let recv = step["recv"] {
                    output = core.receive(try? BLESecureMessageCodec.decodeServer(recv.encoded()))
                } else if let req = step["request"] {
                    output = core.request(Self.request(req))
                } else {
                    switch step["event"]!.s {
                    case "handshake":
                        // The TLS client pins only the selected device; the
                        // core re-checks the key the handshake returned.
                        let cc = ccs.first ?? ""
                        output = core.handshake(serverKey: step["server_key"]!.s, cc: cc)
                        if output.result == .sent { ccs.removeFirst() }
                    case "grant": output = core.grantByUser()
                    case "set_last_seq": output = core.setLastSeq(Int(step["seq"]!.integerValue!))
                    case "elapse": output = core.elapse(seconds: Int(step["seconds"]!.integerValue!))
                    case let name: output = core.end(.init(rawValue: name)!)
                    }
                }
                let expect = step["expect"]!
                XCTAssertEqual(output.result.rawValue, expect["result"]!.s, where_)
                XCTAssertEqual(output.close, expect["close"]!.boolValue!, where_)
                XCTAssertEqual(output.state.rawValue, expect["state"]!.s, where_)
                XCTAssertEqual(output.grant.rawValue, expect["grant"]!.s, where_)
                let expectedSend = expect["send"]!.isNull ? nil : try BLESecureMessageCodec.decodeClient(expect["send"]!.encoded())
                XCTAssertEqual(output.send, expectedSend, where_)
                if let send = output.send {
                    // The real encoder produces a payload the real decoder accepts.
                    XCTAssertEqual(try BLESecureMessageCodec.decodeClient(BLESecureMessageCodec.encode(send)), send, where_)
                }
                results.insert(output.result.rawValue)
            }
        }
        XCTAssertTrue(["phone-two-boards-swap-rejected", "phone-response-wrong-re", "phone-response-wrong-type",
                       "phone-r-wrong-phase", "phone-first-send-request-error", "phone-resend-not-next-request",
                       "phone-seq-exhausted", "phone-grant-survives-session-renewal", "phone-unsolicited-response"].allSatisfy(names.contains))
        XCTAssertTrue(["ready", "pin_mismatch", "applied", "unresolved", "malformed", "fatal", "local_conflict", "status_resend",
                       "status_applied", "status_unresolved", "refused_requery", "refused_no_grant", "refused_window",
                       "refused_seq_exhausted", "response_timeout", "lifetime_expired", "record_mismatch", "bad_challenge",
                       "task_offered", "no_task", "accepted_offer", "refused_next_suspended", "refused_busy"].allSatisfy(results.contains),
                      "every phone result exercised: \(results)")
    }
}

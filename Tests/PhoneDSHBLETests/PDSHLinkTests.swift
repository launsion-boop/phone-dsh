// SPDX-License-Identifier: MIT
import XCTest
import PhoneDSHAgentCore
import PDSHLinkWire
@testable import PhoneDSHBLE

final class PDSHLinkTests: XCTestCase {
    func testAllPinnedLegacyVectorsRoundTripAndSegmentAtMinimumMTU() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("spec/device/v1/golden")
        let legacy = fixtures.appendingPathComponent("xiaozhi-ctl.jsonl")
        let extra = fixtures.appendingPathComponent("pdsh-link.jsonl")
        let lines = try (String(contentsOf: legacy, encoding: .utf8) + String(contentsOf: extra, encoding: .utf8)).split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 100)
        for line in lines {
            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let hex = row["hex"] as! String
            let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: i); return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            let message = try PDSHLink.Envelope.decode(Data(bytes))
            XCTAssertEqual(try message.encoded(), Data(bytes), row["name"] as? String ?? "")
            var decoder = PDSHLink.Reassembler(), decoded: PDSHLink.Envelope?
            for segment in try message.segments(writeLimit: 20) { if let result = try decoder.push(segment) { decoded = result } }
            XCTAssertEqual(decoded, message)
        }
    }
    func testSharedInvalidVectorsAreRejected() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("spec/device/v1/golden/invalid-ctl.jsonl")
        for line in try String(contentsOf: path, encoding: .utf8).split(separator: "\n") {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
            let hex = try XCTUnwrap(row["hex"])
            var bytes = [UInt8]()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(try XCTUnwrap(UInt8(hex[index..<next], radix: 16)))
                index = next
            }
            XCTAssertThrowsError(try PDSHLink.Envelope.decode(Data(bytes)), row["name"] ?? "")
        }
    }
    func testBadCRCTruncationAndOrphanSegmentsAreRejected() throws {
        var data = try PDSHLink.Envelope(opcode: 1, requestID: 1, body: PDSHLink.hello).encoded()
        data[data.count - 1] ^= 1
        XCTAssertThrowsError(try PDSHLink.Envelope.decode(data))
        XCTAssertThrowsError(try PDSHLink.Envelope.decode(Data([1])))
        var decoder = PDSHLink.Reassembler()
        XCTAssertThrowsError(try decoder.push(Data([1, 2, 3])))
        XCTAssertThrowsError(try decoder.push(Data([7, 2])))
        let message = PDSHLink.Envelope(opcode: 0x54, requestID: 2, body: Data(repeating: 42, count: 505))
        let parts = try message.segments(writeLimit: 20)
        XCTAssertEqual(parts.count, 27)
        for part in parts.dropLast() { XCTAssertNil(try decoder.push(part)) }
        XCTAssertEqual(try decoder.push(parts.last!), message)
    }
    func testCapabilityBitAloneNeverActivatesExtension() throws {
        var body = Data(repeating: 0, count: 25)
        body[1] = 2; body[2] = 1; body[5] = 0x10; body[24] = 2
        XCTAssertFalse(try PDSHLink.Peer(helloACK: body).supportsTools)
        body.append(contentsOf: Array("PDSH".utf8) + [1, 0, 0, 16])
        XCTAssertTrue(try PDSHLink.Peer(helloACK: body).supportsTools)
        body[29] = 2
        XCTAssertFalse(try PDSHLink.Peer(helloACK: body).supportsTools)
    }
    func testHomePolicyUsesFirmwareRulesAndExactOriginGrant() throws {
        XCTAssertEqual(try HomeHTTPPolicy.origins("http://192.168.1.111:18767"), ["http://192.168.1.111:18767"])
        for invalid in ["http://192.168.1.111:18767/path", "http://192.168.1.111:18767?x=1", "http://192.168.1.111:18767#fragment"] {
            XCTAssertThrowsError(try HomeHTTPPolicy.origins(invalid))
        }
        let allowed = try HomeHTTPPolicy.origins("http://192.168.1.50:8123")
        let args: JSONValue = .object(["method": .string("POST"), "url": .string("http://192.168.1.50:8123/api"), "body": .string("{}")])
        XCTAssertEqual(try HomeHTTPPolicy.validate(args, allowedOrigins: allowed), "http://192.168.1.50:8123")
        for url in ["http://8.8.8.8/", "http://127.0.0.1/", "https://192.168.1.50:8123/", "http://192.168.1.50:8124/", "http://user@192.168.1.50:8123/", "http://home.local/", "http://[::1]/", "http://2130706433/", "http://192.168.1.50:8123/\r\nHost: evil"] {
            XCTAssertThrowsError(try HomeHTTPPolicy.validate(.object(["method": .string("GET"), "url": .string(url)]), allowedOrigins: allowed), url)
        }
        for headers: JSONValue in [.object(["Host": .string("evil")]), .object(["Authorization": .string("token\r\nx: y")]), .object(["Content-Length": .string("1")]), .object(["x": .string("a\0b")])] {
            XCTAssertThrowsError(try HomeHTTPPolicy.validate(.object(["method": .string("GET"), "url": .string("http://192.168.1.50:8123/"), "headers": headers]), allowedOrigins: allowed))
        }
    }
    func testJournalRestartsReuseRequestAndRejectChangedArguments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let device = UUID(), args: JSONValue = .object(["on": .bool(true)])
        let first = try LinkToolJournal(directory: dir).prepare(key: "once", deviceID: device, name: "light.set", arguments: args)
        XCTAssertTrue(first.1)
        let replay = try LinkToolJournal(directory: dir).prepare(key: "once", deviceID: device, name: "light.set", arguments: args)
        XCTAssertFalse(replay.1); XCTAssertEqual(first.0.requestID, replay.0.requestID)
        XCTAssertThrowsError(try LinkToolJournal(directory: dir).prepare(key: "once", deviceID: device, name: "light.set", arguments: .object(["on": .bool(false)])))
        XCTAssertEqual(try LinkToolJournal(directory: dir).find(deviceID: device, requestID: first.0.requestID).name, "light.set")
    }
    func testEventsRejectWrongIdentityBootAndSequence() throws {
        let id = UUID().uuidString.lowercased()
        let fields: [String: JSONValue] = ["device_id": .string(id), "boot_id": .number(123), "seq": .number(1), "event_id": .string("0000007b-00000001"), "type": .string("button.pressed"), "payload": .object([:])]
        let data = try JSONValue.object(fields).encoded()
        XCTAssertEqual(try PDSHLinkEvent(data: data, expectedBootID: 123, expectedDeviceID: id).sequence, 1)
        XCTAssertThrowsError(try PDSHLinkEvent(data: data, expectedBootID: 124, expectedDeviceID: id))
        XCTAssertThrowsError(try PDSHLinkEvent(data: data, expectedBootID: 123, expectedDeviceID: "other"))
        var bad = fields; bad["seq"] = .number(0)
        XCTAssertThrowsError(try PDSHLinkEvent(data: JSONValue.object(bad).encoded(), expectedBootID: 123, expectedDeviceID: id))
    }
    @MainActor func testNoToolRequestBeforeNegotiation() async throws {
        let fake = FakeTransport(), client = PDSHLinkClient(transport: fake)
        do { _ = try await client.invoke(requestID: fake.id, name: "light.set", arguments: .object(["on": .bool(true)]), idempotencyKey: "once"); XCTFail("unnegotiated request") } catch {}
        XCTAssertEqual(fake.uploads, 0); XCTAssertEqual(fake.commits, 0)
        fake.legacy = true
        let peer = try await client.handshake()
        XCTAssertFalse(peer.supportsTools)
        do { _ = try await client.invoke(requestID: fake.id, name: "light.set", arguments: .object(["on": .bool(true)]), idempotencyKey: "once"); XCTFail("legacy extension request") } catch {}
        XCTAssertEqual(fake.uploads, 0); XCTAssertEqual(fake.commits, 0)
    }
    @MainActor func testClientUploadsLargeRequestAndReadsChunkedResult() async throws {
        let fake = FakeTransport(), client = PDSHLinkClient(transport: fake)
        _ = try await client.handshake()
        let result = try await client.invoke(requestID: fake.id, name: "home.http", arguments: .object(["body": .string(String(repeating: "x", count: 1200))]), idempotencyKey: "once")
        XCTAssertEqual(fake.commits, 1); XCTAssertGreaterThan(fake.uploads, 2)
        XCTAssertEqual(fake.upload.count, fake.total)
        XCTAssertEqual(result, fake.result)
        XCTAssertGreaterThan(fake.queries, 1)
    }
    @MainActor func testLostCommitResponseIsNeverRetriedAndMissingResultIsUnknown() async throws {
        let fake = FakeTransport(); fake.dropCommit = true
        let client = PDSHLinkClient(transport: fake)
        _ = try await client.handshake()
        do { _ = try await client.invoke(requestID: fake.id, name: "light.set", arguments: .object(["on": .bool(true)]), idempotencyKey: "once"); XCTFail("expected transport loss") } catch {}
        XCTAssertEqual(fake.commits, 1)
        fake.missing = true
        let result = try await client.query(requestID: fake.id)
        if case .object(let fields) = result { XCTAssertEqual(fields["status"], .string("outcome_unknown")) } else { XCTFail("missing result") }
        XCTAssertEqual(fake.commits, 1)
    }
}
@MainActor private final class FakeTransport: PDSHLinkTransport {
    let id = UUID()
    var total = 0, uploads = 0, commits = 0, queries = 0
    var upload = Data(), dropCommit = false, missing = false, legacy = false
    var result: JSONValue { .object(["request_id": .string(id.uuidString.lowercased()), "status": .string("completed"), "result": .object(["body": .string(String(repeating: "r", count: 1200))])]) }
    func exchange(opcode: UInt8, body: Data) async throws -> Data {
        let bytes = [UInt8](body)
        switch opcode {
        case 1:
            var ack = Data(repeating: 0, count: 25); ack[1] = 2; ack[2] = 1; ack[5] = 0x10; ack[24] = 2
            if !legacy { ack.append(contentsOf: Array("PDSH".utf8) + [1, 0, 0, 16]) }
            return ack
        case 0x54:
            total = Int(bytes.u16(16)); let offset = Int(bytes.u16(18)); XCTAssertEqual(offset, upload.count)
            upload.append(body.dropFirst(24)); uploads += 1
            var ack = Data([0]); ack.put(UInt16(upload.count)); return ack
        case 0x55:
            commits += 1; if dropCommit { throw BLEFailure("connection lost") }; return Data([0, 1])
        case 0x56:
            queries += 1
            if missing { return Data([0, 0, 0, 0, 0, 0]) }
            let payload = try result.encoded(), offset = Int(bytes.u16(16))
            var reply = Data([0, 2]); reply.put(UInt16(payload.count)); reply.put(UInt16(offset))
            reply.append(payload[offset..<min(offset + 499, payload.count)]); return reply
        default: throw BLEFailure("unexpected opcode")
        }
    }
}

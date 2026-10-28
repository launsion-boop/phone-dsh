// SPDX-License-Identifier: MIT
// Frame/header limits, streaming behaviour and structural validation tests for
// PhoneDSHWire.

import Foundation
import XCTest
import PhoneDSHWire

final class FrameCodecTests: XCTestCase {
    private let binaryPayload = Data([0x01, 0x02, 0x03, 0x04])

    private func encodedFrame(type: FrameType = .console, seq: UInt64 = 1,
                              payload: Data? = nil) throws -> Data {
        try FrameEncoder.encode(type: type, seq: seq, payload: payload ?? binaryPayload)
    }

    private func bigEndianUInt64(_ value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8((value >> (UInt64($0) * 8)) & 0xFF) }
    }

    private func bigEndianUInt32(_ value: UInt32) -> [UInt8] {
        (0..<4).reversed().map { UInt8((value >> (UInt32($0) * 8)) & 0xFF) }
    }

    private func header(type: UInt8, flags: UInt8 = 0, seq: UInt64,
                        length: UInt32, magic: UInt16 = 0x5A4C) -> Data {
        Data([UInt8(magic >> 8), UInt8(magic & 0xFF), type, flags]
            + bigEndianUInt64(seq) + bigEndianUInt32(length))
    }

    // MARK: - Header and types

    func testHandComputedHeaderConstant() throws {
        XCTAssertEqual(
            WireTestSupport.hex(try FrameEncoder.header(type: .vfsAck, seq: 1, payloadLength: 9)),
            "5a4c1100000000000000000100000009"
        )
    }

    func testFrameTypeRawValues() {
        XCTAssertEqual(FrameType.hello.rawValue, 0x01)
        XCTAssertEqual(FrameType.vfsMutation.rawValue, 0x10)
        XCTAssertEqual(FrameType.vfsAck.rawValue, 0x11)
        XCTAssertEqual(FrameType.vfsBarrier.rawValue, 0x12)
        XCTAssertEqual(FrameType.vfsResync.rawValue, 0x13)
        XCTAssertEqual(FrameType.execRequest.rawValue, 0x20)
        XCTAssertEqual(FrameType.execEvent.rawValue, 0x21)
        XCTAssertEqual(FrameType.execControl.rawValue, 0x22)
        XCTAssertEqual(FrameType.journal.rawValue, 0x30)
        XCTAssertEqual(FrameType.journalAck.rawValue, 0x31)
        XCTAssertEqual(FrameType.apiRequest.rawValue, 0x40)
        XCTAssertEqual(FrameType.apiResponse.rawValue, 0x41)
        XCTAssertEqual(FrameType.apiEnd.rawValue, 0x42)
        XCTAssertEqual(FrameType.apiAbort.rawValue, 0x43)
        XCTAssertEqual(FrameType.lifecycle.rawValue, 0x50)
        XCTAssertEqual(FrameType.console.rawValue, 0x60)
        XCTAssertEqual(FrameType.fence.rawValue, 0x70)
        XCTAssertEqual(FrameType.error.rawValue, 0x7F)
        XCTAssertEqual(FrameType.allCases.count, 18)
    }

    func testFrameTypeNamesAndJSONClassification() throws {
        for type in FrameType.allCases {
            XCTAssertEqual(FrameType(wireName: type.wireName), type)
        }
        XCTAssertEqual(FrameType(wireName: "VFS_RESYNC"), .vfsResync)
        XCTAssertNil(FrameType(wireName: "NOT_A_FRAME"))
        let jsonTypes = Set(FrameType.allCases.filter(\.carriesJSONPayload))
        XCTAssertEqual(jsonTypes, [.hello, .execRequest, .execEvent, .execControl,
                                   .lifecycle, .console, .fence, .error])
    }

    // MARK: - Encoder limits

    func testFrameEncoderRejectsEmptyPayload() {
        XCTAssertThrowsError(try FrameEncoder.encode(type: .console, seq: 1, payload: Data())) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testFrameEncoderRejectsOversizedPayload() {
        let oversized = Data(count: WireLimits.maxFramePayloadBytes + 1)
        XCTAssertThrowsError(try FrameEncoder.encode(type: .vfsMutation, seq: 1, payload: oversized)) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testFrameEncoderRejectsZeroSequence() {
        XCTAssertThrowsError(try FrameEncoder.encode(type: .console, seq: 0, payload: binaryPayload)) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badSeq)
        }
    }

    // MARK: - Decoder

    func testFrameDecoderRoundTripsOneFrame() throws {
        var decoder = FrameDecoder()
        let frame = try encodedFrame(type: .journal, seq: 7)
        let frames = try decoder.feed(frame)
        XCTAssertEqual(frames, [Frame(type: .journal, seq: 7, payload: binaryPayload)])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testFrameDecoderRejectsBadMagic() throws {
        var bytes = [UInt8](try encodedFrame())
        bytes[0] = 0x00
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.feed(Data(bytes))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badMagic)
        }
    }

    func testFrameDecoderRejectsNonZeroFlags() throws {
        var bytes = [UInt8](try encodedFrame())
        bytes[3] = 0x01
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.feed(Data(bytes))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testFrameDecoderRejectsZeroLength() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.feed(header(type: 0x60, seq: 1, length: 0))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testFrameDecoderRejectsOversizedLength() {
        let length = UInt32(WireLimits.maxFramePayloadBytes + 1)
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.feed(header(type: 0x10, seq: 1, length: length))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testFrameDecoderRejectsUnknownType() {
        var decoder = FrameDecoder()
        let bytes = header(type: 0x02, seq: 1, length: 1) + Data([0x00])
        XCTAssertThrowsError(try decoder.feed(bytes)) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testFrameDecoderEmitsStickyPackets() throws {
        let frames = [
            Frame(type: .console, seq: 1, payload: Data("a".utf8)),
            Frame(type: .console, seq: 2, payload: Data("b".utf8)),
            Frame(type: .console, seq: 3, payload: Data("c".utf8)),
        ]
        var packet = Data()
        for frame in frames {
            packet.append(try FrameEncoder.encode(frame))
        }
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.feed(packet), frames)
    }

    func testFrameDecoderOneByteAtATime() throws {
        let frames = [
            Frame(type: .vfsMutation, seq: 1, payload: Data([0x00, 0x01, 0x02])),
            Frame(type: .vfsAck, seq: 2, payload: Data([0x03, 0x04, 0x05, 0x06])),
        ]
        var packet = Data()
        for frame in frames {
            packet.append(try FrameEncoder.encode(frame))
        }
        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        for byte in packet {
            decoded.append(contentsOf: try decoder.feed(Data([byte])))
        }
        XCTAssertEqual(decoded, frames)
    }

    func testFrameDecoderRandomChunkSizes() throws {
        let frames = (1...20).map {
            Frame(type: .console, seq: UInt64($0), payload: Data(repeating: UInt8($0), count: $0 * 3))
        }
        var packet = Data()
        for frame in frames {
            packet.append(try FrameEncoder.encode(frame))
        }
        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var offset = packet.startIndex
        while offset < packet.endIndex {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let size = Int((state >> 33) % 7) + 1
            let end = min(offset + size, packet.endIndex)
            decoded.append(contentsOf: try decoder.feed(Data(packet[offset..<end])))
            offset = end
        }
        XCTAssertEqual(decoded, frames)
    }

    func testFrameDecoderTruncatedHeaderEmitsNothing() throws {
        let frame = try encodedFrame()
        var decoder = FrameDecoder()
        XCTAssertEqual(try decoder.feed(frame.prefix(15)), [])
        XCTAssertEqual(decoder.bufferedByteCount, 15)
        XCTAssertEqual(try decoder.feed(frame.suffix(from: frame.index(frame.startIndex, offsetBy: 15))),
                       [Frame(type: .console, seq: 1, payload: binaryPayload)])
    }

    func testFrameDecoderTruncatedPayloadEmitsNothing() throws {
        let frame = try encodedFrame()
        var decoder = FrameDecoder()
        let headerBytes = frame.prefix(WireLimits.headerBytes)
        XCTAssertEqual(try decoder.feed(headerBytes), [])
        XCTAssertEqual(try decoder.feed(frame.dropFirst(WireLimits.headerBytes).dropLast()), [])
        XCTAssertEqual(decoder.bufferedByteCount, WireLimits.headerBytes + binaryPayload.count - 1)
        XCTAssertEqual(try decoder.feed(Data([binaryPayload.last!])),
                       [Frame(type: .console, seq: 1, payload: binaryPayload)])
    }

    func testFrameDecoderSequenceEnforcementAcceptsConsecutiveFrames() throws {
        var decoder = FrameDecoder(configuration: .init(enforceMonotonicSequence: true))
        XCTAssertEqual(try decoder.feed(try encodedFrame(seq: 1)).count, 1)
        XCTAssertEqual(try decoder.feed(try encodedFrame(seq: 2)).count, 1)
        XCTAssertEqual(try decoder.feed(try encodedFrame(seq: 3)).count, 1)
    }

    func testFrameDecoderSequenceEnforcementRejectsGap() throws {
        var decoder = FrameDecoder(configuration: .init(enforceMonotonicSequence: true))
        _ = try decoder.feed(try encodedFrame(seq: 1))
        XCTAssertThrowsError(try decoder.feed(try encodedFrame(seq: 3))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badSeq)
        }
    }

    func testFrameDecoderSequenceEnforcementRequiresFirstOne() throws {
        var decoder = FrameDecoder(configuration: .init(enforceMonotonicSequence: true))
        XCTAssertThrowsError(try decoder.feed(try encodedFrame(seq: 2))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badSeq)
        }
    }

    func testFrameDecoderSequenceEnforcementIsOffByDefault() throws {
        var decoder = FrameDecoder()
        let frames = try decoder.feed(try encodedFrame(seq: 42))
        XCTAssertEqual(frames.first?.seq, 42)
    }

    // MARK: - VFS validation

    func testVFSMutationRejectsSinkPathViolation() {
        let body = VfsMutationBody(op: .write, mode: 0o644, mflags: [.entryChanged],
                                   path: "/dsh/tmp/scratch", data: Data("x".utf8))
        XCTAssertThrowsError(try body.encoded()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPath)
        }
    }

    func testVFSMutationRejectsReservedFlags() {
        let body = VfsMutationBody(op: .write, mode: 0o644,
                                   mflags: VfsMutationFlags(rawValue: 0x04),
                                   path: "/dsh/home/x", data: Data())
        XCTAssertThrowsError(try body.encoded()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testVFSMutationRejectsAppendFromOnCompleteWrite() {
        let body = VfsMutationBody(op: .write, mode: 0o644, mflags: [.entryChanged],
                                   appendFrom: 3, path: "/dsh/home/x", data: Data("abc".utf8))
        XCTAssertThrowsError(try body.encoded()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testVFSMutationRejectsOversizedData() {
        let body = VfsMutationBody(op: .write, mode: 0o644, mflags: [.entryChanged],
                                   path: "/dsh/home/big",
                                   data: Data(count: WireLimits.maxMutationDataBytes + 1))
        XCTAssertThrowsError(try body.encoded()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testVFSMutationRejectsTruncatedPayload() throws {
        let fixture = try WireTestSupport.loadFrame("vfs-mut-write-1.json")
        var payload = try WireTestSupport.payloadData(fixture)
        payload.removeLast()
        XCTAssertThrowsError(try VfsMutationBody.decode(Data(payload.dropFirst(8)))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testVFSResyncRejectsNonSinkPath() {
        XCTAssertThrowsError(try VfsResyncBody(path: "/etc/passwd").encoded()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPath)
        }
    }

    // MARK: - Journal, API and JSON validation

    func testJournalRejectsEmptyRecord() {
        let body = JournalBody(jseq: 1, sessionID: "sess_01", record: Data())
        XCTAssertThrowsError(try body.encoded()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testAPIRequestRejectsOversizedBody() {
        let frame = ApiRequestFrame(
            reqID: 1,
            head: ApiRequestHead(method: "POST", path: "/api/x"),
            body: Data(count: WireLimits.maxAPIBodyBytes + 1)
        )
        XCTAssertThrowsError(try frame.encoded()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testAPIResponseRejectsInvalidStatus() {
        let frame = ApiResponseFrame(reqID: 1, head: ApiResponseHead(status: 99))
        XCTAssertThrowsError(try frame.encoded()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testIdentifierSyntax() {
        XCTAssertTrue(WireValidation.isValidIdentifier("xl1-0f1e2d3c_4b5a.6978"))
        XCTAssertFalse(WireValidation.isValidIdentifier(""))
        XCTAssertFalse(WireValidation.isValidIdentifier("has space"))
        XCTAssertFalse(WireValidation.isValidIdentifier(String(repeating: "a", count: 65)))
        XCTAssertTrue(WireValidation.isValidIdemKey(String(repeating: "a", count: 64)))
        XCTAssertFalse(WireValidation.isValidIdemKey(String(repeating: "A", count: 64)))
        XCTAssertFalse(WireValidation.isValidIdemKey(String(repeating: "a", count: 63)))
    }

    func testBootIDAndFenceOwnerSyntax() {
        XCTAssertTrue(WireValidation.isValidBootID("00112233445566778899aabbccddeeff"))
        XCTAssertFalse(WireValidation.isValidBootID("00112233445566778899AABBCCDDEEFF"))
        XCTAssertFalse(WireValidation.isValidBootID("0011"))
        XCTAssertTrue(WireValidation.isValidFenceOwner("phone:owner-1"))
        XCTAssertFalse(WireValidation.isValidFenceOwner("phone owner"))
    }

    func testHelloValidationRejectsWrongProto() throws {
        let hello = HelloPayload(
            proto: 2, role: .host, bootID: "00112233445566778899aabbccddeeff",
            sessionEpoch: 1,
            fence: Fence(owner: "phone", generation: 1, walSeq: 0),
            caps: ["channel/1", "wal/1", "exec/1"],
            nextMseq: 1, ackedMseq: 0, durableMseq: 0)
        XCTAssertThrowsError(try hello.validate()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .protoMismatch)
        }
    }

    func testHelloValidationRejectsWorkerWithHostMembers() throws {
        let hello = HelloPayload(
            role: .worker, bootID: "ffeeddccbbaa99887766554433221100",
            sessionEpoch: 1,
            fence: Fence(owner: "phone", generation: 1, walSeq: 0),
            caps: ["channel/1", "vfs-sink/1", "journal/1", "api/1"],
            nextMseq: 2, ackedMseq: 1, durableMseq: 0, lastMseq: 1)
        XCTAssertThrowsError(try hello.validate()) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testCanonicalJSONRejectsNonIntegerNumber() {
        XCTAssertThrowsError(try CanonicalJSON.canonicalize(Data(#"{"x":1.5}"#.utf8))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testCanonicalJSONRejectsNonObjectRoot() {
        XCTAssertThrowsError(try CanonicalJSON.canonicalize(Data("[1,2,3]".utf8))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testExecRequestReservedMembersAreRejected() throws {
        XCTAssertThrowsError(try ExecRequestPayload(
            body: Data(#"{"exec_id":"e","requires_mseq":1}"#.utf8),
            requiresMseq: 1,
            idemKey: String(repeating: "a", count: 64))) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload)
        }
    }

    func testAPIAbortReasonRoundTrip() throws {
        let frame = ApiAbortFrame(reqID: 7, reason: "connection_closed")
        let decoded = try ApiAbortFrame.decode(frame.encoded())
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(String(decoding: try frame.encoded().dropFirst(4), as: UTF8.self),
                       #"{"reason":"connection_closed"}"#)
    }
}

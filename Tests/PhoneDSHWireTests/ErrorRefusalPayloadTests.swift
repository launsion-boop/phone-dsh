// SPDX-License-Identifier: MIT
// ERROR VFS_REFUSED payload tests: the non-closing resource-refusal form of
// channel.md §4.8/§10 decodes from the golden vector, round-trips canonically,
// and enforces the code-dependent member set on both decode and encode.

import Foundation
import XCTest
import PhoneDSHWire

final class ErrorRefusalPayloadTests: XCTestCase {
    private func refusal(_ overrides: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "code": "VFS_REFUSED",
            "message": "EFBIG",
            "path": "/dsh/workspace/a",
            "limit": 15728640,
            "reason": "file-too-large",
        ]
        for (key, value) in overrides { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertBadPayload(_ body: @autoclosure () throws -> Any,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? PhoneWireError)?.code, .badPayload,
                           "\(error)", file: file, line: line)
        }
    }

    // MARK: - Code table

    func testOnlyVFSRefusedIsADiagnostic() {
        for code in PhoneWireErrorCode.allCases {
            XCTAssertEqual(code.closesConnection, code != .vfsRefused, code.rawValue)
        }
    }

    func testRefusalReasonVocabulary() {
        XCTAssertEqual(PhoneWireRefusalReason.fileTooLarge.rawValue, "file-too-large")
        XCTAssertEqual(PhoneWireRefusalReason.noSpace.rawValue, "no-space")
        XCTAssertEqual(PhoneWireRefusalReason.quotaExceeded.rawValue, "quota-exceeded")
        XCTAssertEqual(PhoneWireRefusalReason.allCases.count, 3)
    }

    // MARK: - Decode and encode

    func testDecodesGoldenRefusalFrame() throws {
        let frameData = try WireTestSupport.data(hex:
            "5a4c7f0000000000000000090000006d7b22636f6465223a225646535f52454655534544222c"
            + "226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468"
            + "223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f"
            + "2d6c61726765227d")
        var decoder = FrameDecoder()
        let frames = try decoder.feed(frameData)
        XCTAssertEqual(frames.count, 1)
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(frame.type, .error)
        XCTAssertEqual(frame.seq, 9)
        let payload = try JSONDecoder().decode(ErrorPayload.self, from: frame.payload)
        XCTAssertTrue(payload.isVFSRefused)
        XCTAssertEqual(payload.path, "/dsh/workspace/a")
        XCTAssertEqual(payload.limit, 15728640)
        XCTAssertEqual(payload.reason, .fileTooLarge)
        XCTAssertEqual(payload.code.closesConnection, false)
    }

    func testRefusalPayloadRoundTripsCanonically() throws {
        let original = try JSONDecoder().decode(ErrorPayload.self, from: try refusal())
        let encoded = try CanonicalJSON.encode(original)
        XCTAssertEqual(try CanonicalJSON.canonicalize(encoded), encoded,
                       "the refusal payload is canonical")
        let decoded = try JSONDecoder().decode(ErrorPayload.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.code, .vfsRefused)
    }

    func testConvenienceInitializerProducesTheSameWireForm() throws {
        let payload = ErrorPayload(path: "/dsh/home/b", limit: 1024,
                                   reason: .noSpace, message: "ENOSPC")
        let decoded = try JSONDecoder().decode(ErrorPayload.self,
                                               from: try CanonicalJSON.encode(payload))
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.limit, 1024)
        XCTAssertEqual(decoded.reason, .noSpace)
    }

    func testZeroLimitIsAccepted() throws {
        let decoded = try JSONDecoder().decode(ErrorPayload.self,
                                               from: try refusal(["limit": 0]))
        XCTAssertEqual(decoded.limit, 0)
    }

    // MARK: - Host refusal form and the shared budget definition

    func testHostRefusalInitializerProducesTheNonClosingWireForm() throws {
        let refusal = VFSResourceRefusal(
            path: "/dsh/workspace/big.bin",
            limitBytes: UInt64(WireLimits.defaultSingleFileLimitBytes),
            projectedBytes: UInt64(WireLimits.defaultSingleFileLimitBytes) + 1,
            message: "VFS_REFUSED: /dsh/workspace/big.bin would grow to 67108865 bytes, above the single-file limit of 67108864 bytes")
        let payload = ErrorPayload(hostRefusal: refusal, mseq: 5,
                                   acceptedBytes: 0, refSeq: 4)
        XCTAssertEqual(payload.code, .vfsRefused)
        XCTAssertEqual(payload.path, refusal.path)
        XCTAssertEqual(payload.limit, refusal.limitBytes)
        XCTAssertEqual(payload.reason, .fileTooLarge)
        XCTAssertEqual(payload.refSeq, 4)
        XCTAssertTrue(payload.message.contains("mseq 5"), payload.message)
        XCTAssertTrue(payload.message.contains("0 accepted bytes"), payload.message)
        XCTAssertFalse(payload.code.closesConnection)
        XCTAssertEqual(refusal.vfsResourceRefusal, refusal)
        // The host reply carries the refused mseq and the accepted prefix as
        // structured members, not only inside `message` (channel.md §4.8).
        XCTAssertEqual(payload.acceptedBytes, 0)
        XCTAssertEqual(payload.mseq, 5)
        let bytes = try CanonicalJSON.encode(payload)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(text.contains("\"accepted_bytes\":0"), text)
        XCTAssertTrue(text.contains("\"mseq\":5"), text)
        let decoded = try JSONDecoder().decode(ErrorPayload.self, from: bytes)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.acceptedBytes, 0)
        XCTAssertEqual(decoded.mseq, 5)
    }

    func testWorkerSinkRefusalOmitsTheHostReplyMembers() throws {
        let decoded = try JSONDecoder().decode(ErrorPayload.self, from: try refusal())
        XCTAssertEqual(decoded.code, .vfsRefused)
        XCTAssertNil(decoded.acceptedBytes)
        XCTAssertNil(decoded.mseq)
    }

    func testHostReplyMembersMustBePresentTogether() {
        assertBadPayload(try JSONDecoder().decode(
            ErrorPayload.self, from: refusal(["accepted_bytes": 0])))
        assertBadPayload(try JSONDecoder().decode(
            ErrorPayload.self, from: refusal(["mseq": 5])))
    }

    func testAcceptedBytesAboveLimitIsBadPayload() {
        assertBadPayload(try JSONDecoder().decode(
            ErrorPayload.self,
            from: refusal(["limit": 10, "accepted_bytes": 11, "mseq": 5])))
    }

    func testHostReplyMseqMustBePositive() {
        assertBadPayload(try JSONDecoder().decode(
            ErrorPayload.self,
            from: refusal(["accepted_bytes": 0, "mseq": 0])))
    }

    func testProtocolCodeWithHostReplyMembersIsBadPayloadOnDecode() {
        assertBadPayload(try JSONDecoder().decode(
            ErrorPayload.self,
            from: refusal(["code": "BAD_SEQ", "accepted_bytes": 0, "mseq": 5])))
    }

    func testWireLimitsDeriveFromOneMebibyteBudget() {
        XCTAssertEqual(WireLimits.mebibyte, 1_048_576)
        XCTAssertEqual(WireLimits.maxFramePayloadBytes, 16 * WireLimits.mebibyte)
        XCTAssertEqual(WireLimits.maxMutationDataBytes, 15 * WireLimits.mebibyte,
                       "the per-frame mutation cap is unchanged")
        XCTAssertEqual(WireLimits.defaultSingleFileLimitBytes,
                       128 * WireLimits.mebibyte,
                       "the 8 GiB tier single-file default (budgets.md §4)")
        XCTAssertGreaterThan(WireLimits.defaultSingleFileLimitBytes,
                             WireLimits.maxMutationDataBytes)
    }

    // MARK: - Code-dependent member set

    func testRefusalWithoutPathIsBadPayload() {
        assertBadPayload(try JSONDecoder().decode(ErrorPayload.self,
                                                  from: refusal(["path": NSNull()])))
    }

    func testRefusalWithoutLimitIsBadPayload() {
        assertBadPayload(try JSONDecoder().decode(ErrorPayload.self,
                                                  from: refusal(["limit": NSNull()])))
    }

    func testRefusalWithoutReasonIsBadPayload() {
        assertBadPayload(try JSONDecoder().decode(ErrorPayload.self,
                                                  from: refusal(["reason": NSNull()])))
    }

    func testRefusalWithUnknownReasonIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            ErrorPayload.self, from: refusal(["reason": "other"])))
    }

    func testRefusalPathMustBeAMutationPath() {
        assertBadPayload(try JSONDecoder().decode(ErrorPayload.self,
                                                  from: refusal(["path": "/etc/passwd"])))
        assertBadPayload(try JSONDecoder().decode(ErrorPayload.self,
                                                  from: refusal(["path": "/dsh/tmp/a"])))
    }

    func testProtocolCodeWithRefusalMembersIsBadPayloadOnDecode() {
        assertBadPayload(try JSONDecoder().decode(
            ErrorPayload.self,
            from: refusal(["code": "BAD_SEQ"])))
    }

    func testProtocolCodeWithRefusalMembersIsBadPayloadOnEncode() {
        let payload = ErrorPayload(code: .badSeq, message: "expected 2",
                                   path: "/dsh/workspace/a", limit: 1,
                                   reason: .fileTooLarge)
        assertBadPayload(try CanonicalJSON.encode(payload))
    }

    func testUInt64LimitBeyondIntPreservesTheWireInteger() throws {
        let payload = ErrorPayload(path: "/dsh/workspace/big", limit: UInt64.max,
                                   reason: .quotaExceeded, message: "EDQUOT")
        let bytes = try CanonicalJSON.encode(payload)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(text.contains("\"limit\":18446744073709551615"), text)
        XCTAssertEqual(try JSONDecoder().decode(ErrorPayload.self, from: bytes), payload)
    }
}

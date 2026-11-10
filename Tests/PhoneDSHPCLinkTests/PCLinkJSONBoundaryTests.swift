// SPDX-License-Identifier: MIT
// PCLink v1.3 JSON wire boundary: strict wire bytes, carried DSH values
// (escaped `\u0000` preserved) and PCLink-owned field rules (§2.3).

import Foundation
import XCTest
@testable import PhoneDSHPCLink

final class PCLinkJSONBoundaryTests: XCTestCase {
    // MARK: Accepted carried NUL

    func testGoldenJSONBoundaryAcceptedRows() throws {
        let vectors = try TestSupport.vectors()
        let boundary = try XCTUnwrap(vectors["json_boundary"])
        let accepted = try XCTUnwrap(boundary["accepted"]?.arrayValue)
        XCTAssertEqual(accepted.count, 6)

        for row in accepted {
            let name = try XCTUnwrap(row["case"]?.stringValue)
            let wire = try XCTUnwrap(row["wire"]?.stringValue)
            let parsed = try PCLinkJSONParser.parseObject(Data(wire.utf8))
            // The same real decoder the session uses for the closed shape.
            XCTAssertNoThrow(try PCLinkWire.validateInnerMessage(parsed), name)
            // Foundation's non-filtering JSON reader is the reference value.
            let reference = try JSONSerialization.jsonObject(with: Data(wire.utf8))

            for path in row["nul_paths"]?.arrayValue ?? [] {
                let components = try XCTUnwrap(path.arrayValue)
                let actual = try XCTUnwrap(pclinkValue(parsed, at: components), name)
                let expected = try XCTUnwrap(referenceValue(reference, at: components), name)
                assertSameScalars(actual, expected, name)
                XCTAssertTrue(actual.stringValue?.unicodeScalars.contains(where: { $0.value == 0 }) == true,
                              "\(name): carried U+0000 was filtered")
            }

            for path in row["chunk_data_nul_paths"]?.arrayValue ?? [] {
                let components = try XCTUnwrap(path.arrayValue)
                let data = try PCLinkBase64URL.decode(try XCTUnwrap(parsed["data"]?.stringValue))
                let referenceChunk = try JSONSerialization.jsonObject(with: data)
                // Drive the real chunk reassembler, not a copied value.
                var reassembler = PCLinkChunkReassembler()
                let completed = try reassembler.accept(
                    key: "boundary-\(name)",
                    part: Int(try XCTUnwrap(parsed["part"]?.intValue)),
                    last: try XCTUnwrap(parsed["last"]?.boolValue),
                    dataBase64: try XCTUnwrap(parsed["data"]?.stringValue))
                let value = try PCLinkJSONParser.parse(try XCTUnwrap(completed))
                let actual = try XCTUnwrap(pclinkValue(value, at: components), name)
                let expected = try XCTUnwrap(referenceValue(referenceChunk, at: components), name)
                assertSameScalars(actual, expected, name)
                XCTAssertTrue(actual.stringValue?.unicodeScalars.contains(where: { $0.value == 0 }) == true,
                              "\(name): decoded chunk U+0000 was filtered")
            }
        }
    }

    // MARK: Rejected wire / field rows

    func testGoldenJSONBoundaryRejectedRows() throws {
        let vectors = try TestSupport.vectors()
        let boundary = try XCTUnwrap(vectors["json_boundary"])
        let rejected = try XCTUnwrap(boundary["rejected"]?.arrayValue)
        XCTAssertEqual(rejected.count, 8)

        for row in rejected {
            let name = try XCTUnwrap(row["case"]?.stringValue)
            let failure = try XCTUnwrap(row["failure"]?.stringValue)
            let data: Data
            if let hex = row["wire_hex"]?.stringValue {
                data = try TestSupport.hex(hex)
            } else {
                data = Data(try XCTUnwrap(row["wire"]?.stringValue).utf8)
            }

            if failure == "wire" {
                // A literal NUL, BOM, duplicate member at any depth, lone
                // surrogate or a non-object root is `bad_frame`.
                XCTAssertThrowsError(try PCLinkJSONParser.parseObject(data), name)
                continue
            }

            XCTAssertEqual(failure, "field", name)
            let parsed = try PCLinkJSONParser.parseObject(data)
            if let type = parsed["type"]?.stringValue, type.hasPrefix("relay.") {
                XCTAssertThrowsError(try PCLinkWire.validateRelayFrame(parsed), name) { error in
                    XCTAssertEqual((error as? PCLinkError)?.code, "bad_frame", name)
                }
            } else {
                XCTAssertThrowsError(try PCLinkWire.validateInnerMessage(parsed), name) { error in
                    XCTAssertEqual((error as? PCLinkError)?.code, "bad_frame", name)
                }
            }
        }
    }

    // MARK: Duplicate member names

    func testDuplicateMembersCompareUnicodeScalarSequences() throws {
        // Same decoded scalar sequence spelled with an escape: duplicate.
        XCTAssertThrowsError(try PCLinkJSONParser.parseObject(#"{"a":1,"\u0061":2}"#)) { error in
            guard case PCLinkJSONError.duplicateMember(let name) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(name, "a")
        }

        // Distinct scalar sequences that happen to be canonically equivalent
        // are two members. A Swift `String` comparison wrongly rejected this.
        let source = "{\"\u{00E9}\":1,\"e\u{0301}\":2}"
        let parsed = try PCLinkJSONParser.parseObject(source)
        XCTAssertEqual(parsed.objectValue?.count, 2)
        XCTAssertEqual(parsed["\u{00E9}"]?.intValue, 1)
        XCTAssertEqual(parsed["e\u{0301}"]?.intValue, 2)
        XCTAssertEqual(try PCLinkJSONEncoder.canonicalString(parsed),
                       "{\"e\u{0301}\":2,\"\u{00E9}\":1}")
    }

    // MARK: PCLink-owned fields vs passthrough

    func testRawDELIsLegalJSONButPCLinkNameRejectsIt() throws {
        // U+007F is not a C0 control; a DSH serializer may emit it literally.
        // It stays legal inside a carried value, while the §2.1 name rule
        // rejects the C1 range in PCLink-owned fields.
        let parsed = try PCLinkJSONParser.parseObject("{\"note\":\"a\u{7F}b\"}")
        XCTAssertEqual(parsed["note"]?.stringValue, "a\u{7F}b")
        XCTAssertThrowsError(try PCLinkValidation.name("a\u{7F}b"))
    }

    func testPCLinkOwnedMessagesRejectNulWhilePassthroughAndDetailsKeepIt() throws {
        let nul = "a\u{0}b"

        XCTAssertThrowsError(try PCLinkWire.validateRelayFrame(.object([
            "v": .int(1), "type": .string("relay.error"), "code": .string("unavailable"),
            "message": .string(nul),
        ])))

        let rejected = try rpcError(message: nul)
        XCTAssertThrowsError(try PCLinkWire.validateInnerMessage(rejected))
        XCTAssertThrowsError(try PCLinkWire.validateInnerMessage(.object([
            "type": .string("rpc.stream.error"), "streamId": .string("stream-nul"),
            "error": .object([
                "code": .string("unavailable"), "message": .string(nul),
            ]),
        ])))
        XCTAssertThrowsError(try PCLinkWire.validateInnerMessage(.object([
            "type": .string("session.close"), "code": .string("unavailable"),
            "message": .string(nul),
        ])))
        XCTAssertThrowsError(try PCLinkWire.validateInnerMessage(.object([
            "type": .string("call.foo.error"), "code": .string("unavailable"),
            "message": .string(nul),
        ])))

        let sid = "ODU-xxharZz-k1yXN2XWRA"
        let machine = String(repeating: "a", count: 26)
        XCTAssertThrowsError(try PCLinkWire.validateE2EHandshake(.object([
            "v": .int(1), "type": .string("e2e.handshake"),
            "sid": .string(sid), "from": .string(machine), "to": .string(machine),
            "body": .object([
                "v": .int(1), "type": .string("session.reject"), "sid": .string(sid),
                "code": .string("unpaired"), "message": .string(nul),
            ]),
        ])))

        // The DSH passthrough values are carried unchanged.
        XCTAssertNoThrow(try PCLinkWire.validateInnerMessage(.object([
            "type": .string("rpc.call"), "id": .string("call-nul"),
            "endpoint": .string("session/list"),
            "args": .object(["_request": .object([:]), "note": .string(nul)]),
        ])))
        XCTAssertNoThrow(try PCLinkWire.validateInnerMessage(.object([
            "type": .string("rpc.result"), "id": .string("call-nul"), "ok": .bool(true),
            "result": .object(["text": .string(nul), "nested": .array([.string(nul)])]),
        ])))
        XCTAssertNoThrow(try PCLinkWire.validateInnerMessage(.object([
            "type": .string("rpc.stream.open"), "streamId": .string("stream-nul"),
            "endpoint": .string("session/follow"),
            "payload": .object(["args": .object(["request": .object(["note": .string(nul)])])]),
        ])))
        XCTAssertNoThrow(try PCLinkWire.validateInnerMessage(.object([
            "type": .string("rpc.stream.item"), "streamId": .string("stream-nul"),
            "value": .object(["text": .string(nul)]),
        ])))

        // `details` is optional error content and follows the error rule, not
        // a PCLink-owned display string: its nested DSH value is preserved.
        XCTAssertNoThrow(try PCLinkWire.validateInnerMessage(try rpcError(
            message: "failed", details: .object(["text": .string(nul)]))))
    }

    // MARK: Helpers

    private func rpcError(message: String, details: PCLinkJSON? = nil) throws -> PCLinkJSON {
        var error: PCLinkJSONObject = [
            "code": .string("unavailable"), "message": .string(message),
        ]
        if let details { error["details"] = details }
        return .object([
            "type": .string("rpc.result"), "id": .string("call-nul"),
            "ok": .bool(false), "error": .object(error),
        ])
    }

    private func pclinkValue(_ root: PCLinkJSON, at path: [PCLinkJSON]) -> PCLinkJSON? {
        var current = root
        for component in path {
            if let key = component.stringValue {
                guard let next = current[key] else { return nil }
                current = next
            } else if let index = component.intValue, let array = current.arrayValue,
                      index >= 0, Int(index) < array.count {
                current = array[Int(index)]
            } else {
                return nil
            }
        }
        return current
    }

    private func referenceValue(_ root: Any, at path: [PCLinkJSON]) -> Any? {
        var current: Any? = root
        for component in path {
            if let key = component.stringValue {
                guard let object = current as? [String: Any] else { return nil }
                current = object[key]
            } else if let index = component.intValue, let array = current as? [Any],
                      index >= 0, Int(index) < array.count {
                current = array[Int(index)]
            } else {
                return nil
            }
        }
        return current
    }

    /// Compare strings by decoded scalar sequence, not Swift `String` canonical
    /// equivalence (which would hide a re-normalized NUL-bearing value).
    private func assertSameScalars(_ actual: PCLinkJSON, _ expected: Any?, _ name: String) {
        guard let actualString = actual.stringValue, let expectedString = expected as? String else {
            return XCTFail("\(name): expected string values")
        }
        XCTAssertEqual(actualString.unicodeScalars.map(\.value),
                       expectedString.unicodeScalars.map(\.value), name)
    }
}

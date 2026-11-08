// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHDeviceTasks

final class UniqueJSONKeysIterativeTests: XCTestCase {
    private struct Vector: Decodable {
        let name: String
        let depth: Int
        let encoding: String
        let mutation: String
        let expected: String
        let check_valid: Bool
    }
    private var golden: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spec/device/v1/golden/legacy-task-inspection-deep.jsonl")
    }
    private func makeText(_ row: Vector) -> String {
        var leaf = "0"
        if row.mutation == "leaf_empty_array" { leaf = "[]" }
        if row.mutation == "leaf_nonempty_array" { leaf = "[0]" }
        var suffix = String(repeating: "]", count: row.depth)
        if row.mutation == "missing_bracket" { suffix.removeLast() }
        var text = "{\"device_id\":\"ble:old\",\"unknown\":" + String(repeating: "[", count: row.depth) + leaf + suffix
        if row.mutation == "duplicate_device" { text += ",\"device\\u005fid\":\"other\"" }
        if row.mutation == "duplicate_unknown" { text += ",\"extra\":{\"x\":1,\"x\":2}" }
        return text + "}"
    }
    private func encoded(_ text: String, _ encoding: String) throws -> Data {
        switch encoding {
        case "utf8": return Data(text.utf8)
        case "utf16le": return Data([0xff, 0xfe]) + (try XCTUnwrap(text.data(using: .utf16LittleEndian)))
        case "utf32be": return Data([0, 0, 0xfe, 0xff]) + (try XCTUnwrap(text.data(using: .utf32BigEndian)))
        default: throw NSError(domain: "unexpected test encoding", code: 1)
        }
    }
    func testDeepSharedVectorsThroughBothRealValidatorModes() throws {
        let rows = try String(contentsOf: golden, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Vector.self, from: Data($0.utf8)) }
        XCTAssertEqual(rows.count, 12)
        for row in rows {
            let text = makeText(row)
            var strict = UniqueJSONKeys(Data(text.utf8))
            XCTAssertEqual(strict.check(), row.check_valid, "strict: \(row.name)")
            var parent = UniqueJSONKeys(try encoded(text, row.encoding))
            let result = parent.rawRootMembers(capturing: ["device_id"], enforcingUnique: ["device_id"])
            XCTAssertEqual(result != nil, row.expected == "observed", "parent: \(row.name)")
            if let result {
                XCTAssertEqual(try XCTUnwrap(result["device_id"]), Data("\"ble:old\"".utf8), row.name)
            }
        }
    }
    func testGrammarAndIndependentObjectKeyDomains() {
        let cases: [(String, Bool)] = [
            ("null", true), ("[1, {\"x\": false}, []]", true),
            ("{\"x\":1,}", false), ("[1,]", false), ("{,}", false),
            ("{\"a\":1 \"b\":2}", false), ("[true false]", false),
            ("{\"a\":1,\"a\":2}", false), ("[{\"a\":1},{\"a\":2}]", true),
            ("{\"é\":1,\"e\\u0301\":2}", true), ("{\"é\":1,\"\\u00e9\":2}", false),
            ("-0.12e+10", true), ("00", false), ("1.", false), ("+1", false), ("truex", false),
        ]
        for (raw, expected) in cases {
            var parser = UniqueJSONKeys(Data(raw.utf8))
            XCTAssertEqual(parser.check(), expected, raw)
        }
    }
    func testNULAndParentDuplicatePolicyRemainDistinct() throws {
        let raw = "{\"known\":1,\"unknown\":{\"x\":1,\"x\":2},\"unknown\":3,\"payload\":\"a\\u0000b\"}"
        var strict = UniqueJSONKeys(Data(raw.utf8))
        XCTAssertFalse(strict.check())
        var parent = UniqueJSONKeys(Data(raw.utf8))
        let values = try XCTUnwrap(parent.rawRootMembers(capturing: ["known", "unknown"], enforcingUnique: ["known"]))
        XCTAssertEqual(values["known"], Data("1".utf8))
        XCTAssertEqual(values["unknown"], Data("3".utf8))
        var allowNUL = UniqueJSONKeys(Data("{\"key\":\"a\\u0000b\"}".utf8))
        XCTAssertTrue(allowNUL.check())
        var denyNUL = UniqueJSONKeys(Data("{\"key\":\"a\\u0000b\"}".utf8))
        XCTAssertFalse(denyNUL.check(rejectNUL: true))
        var denyNULKey = UniqueJSONKeys(Data("{\"a\\u0000b\":1}".utf8))
        XCTAssertFalse(denyNULKey.check(rejectNUL: true))
    }
}

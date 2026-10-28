// SPDX-License-Identifier: MIT
// Shared helpers for the PhoneDSHWire golden-vector and codec tests.
// The repository root is located from #filePath so the test target reads the
// checked-in spec/v1/golden files without a build-time absolute path.

import Foundation
import XCTest
@testable import PhoneDSHWire

enum WireTestSupport {
    struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    /// Walks up from this source file to the repository root that contains
    /// `spec/v1/golden/frames`.
    static func repoRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = candidate.appendingPathComponent("spec/v1/golden/frames")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw FixtureError(description: "cannot locate the repository root from #filePath")
    }

    static func goldenFramesDirectory() throws -> URL {
        try repoRoot().appendingPathComponent("spec/v1/golden/frames")
    }

    static func goldenWALDirectory() throws -> URL {
        try repoRoot().appendingPathComponent("spec/v1/golden/wal")
    }

    static func frameFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: goldenFramesDirectory().path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }

    static func walFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: goldenWALDirectory().path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }

    static func loadFrame(_ name: String) throws -> [String: Any] {
        try loadJSON(goldenFramesDirectory().appendingPathComponent(name))
    }

    static func loadWAL(_ name: String) throws -> [String: Any] {
        try loadJSON(goldenWALDirectory().appendingPathComponent(name))
    }

    static func loadJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError(description: "\(url.lastPathComponent) is not a JSON object")
        }
        return object
    }

    static func fields(_ fixture: [String: Any]) throws -> [String: Any] {
        guard let fields = fixture["fields"] as? [String: Any] else {
            throw FixtureError(description: "fixture has no fields object")
        }
        return fields
    }

    static func string(_ fields: [String: Any], _ key: String) throws -> String {
        guard let value = fields[key] as? String else {
            throw FixtureError(description: "field \(key) is not a string")
        }
        return value
    }

    static func number(_ value: Any?, _ name: String) throws -> NSNumber {
        guard let number = value as? NSNumber else {
            throw FixtureError(description: "\(name) is not a number")
        }
        return number
    }

    static func uint64(_ value: Any?, _ name: String) throws -> UInt64 {
        try number(value, name).uint64Value
    }

    static func uint32(_ value: Any?, _ name: String) throws -> UInt32 {
        try number(value, name).uint32Value
    }

    static func uint16(_ value: Any?, _ name: String) throws -> UInt16 {
        try number(value, name).uint16Value
    }

    static func uint8(_ value: Any?, _ name: String) throws -> UInt8 {
        try number(value, name).uint8Value
    }

    static func int(_ value: Any?, _ name: String) throws -> Int {
        try number(value, name).intValue
    }

    static func frameType(_ fixture: [String: Any]) throws -> FrameType {
        let byte = try uint8(fixture["type_byte"], "type_byte")
        guard let type = FrameType(rawValue: byte) else {
            throw FixtureError(description: "unknown type_byte \(byte)")
        }
        return type
    }

    static func payloadHex(_ fixture: [String: Any]) throws -> String {
        try string(fixture, "payload_hex")
    }

    static func frameHex(_ fixture: [String: Any]) throws -> String {
        try string(fixture, "frame_hex")
    }

    static func payloadData(_ fixture: [String: Any]) throws -> Data {
        try data(hex: payloadHex(fixture))
    }

    static func frameData(_ fixture: [String: Any]) throws -> Data {
        try data(hex: frameHex(fixture))
    }

    static func data(hex: String) throws -> Data {
        guard hex.count % 2 == 0 else {
            throw FixtureError(description: "hex string has an odd number of characters")
        }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw FixtureError(description: "hex string contains a non-hex digit")
            }
            data.append(byte)
            index = next
        }
        return data
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Validates the 16-byte header, decodes one frame and checks that the
    /// encoder reproduces `frame_hex`.
    static func assertFrame(_ fixture: [String: Any], file: StaticString = #filePath,
                            line: UInt = #line) throws {
        let expectedType = try frameType(fixture)
        let expectedSeq = try uint64(fixture["seq"], "seq")
        let expectedPayload = try payloadData(fixture)
        let expectedFrame = try frameData(fixture)

        var decoder = FrameDecoder()
        let frames = try decoder.feed(expectedFrame)
        XCTAssertEqual(frames.count, 1, file: file, line: line)
        let frame = try XCTUnwrap(frames.first, file: file, line: line)
        XCTAssertEqual(frame.type, expectedType, file: file, line: line)
        XCTAssertEqual(frame.seq, expectedSeq, file: file, line: line)
        XCTAssertEqual(frame.payload, expectedPayload, file: file, line: line)
        XCTAssertEqual(try FrameEncoder.encode(frame), expectedFrame, file: file, line: line)
    }

    /// Builds a VFS mutation body from a golden `fields` object.
    static func ackLevel(_ value: Any?, _ name: String) throws -> AckLevel {
        let raw = try uint8(value, name)
        guard let level = AckLevel(rawValue: raw) else {
            throw FixtureError(description: "\(name) is not an ack level")
        }
        return level
    }

    static func mutationBody(_ fields: [String: Any]) throws -> VfsMutationBody {
        VfsMutationBody(
            op: try XCTUnwrap(VfsOp(rawValue: try uint8(fields["op"], "op"))),
            mode: try uint32(fields["mode"], "mode"),
            mflags: VfsMutationFlags(rawValue: try uint8(fields["mflags"], "mflags")),
            appendFrom: try uint64(fields["append_from"], "append_from"),
            path: try string(fields, "path"),
            data: try data(hex: try string(fields, "data_hex"))
        )
    }

    static func apiRequestHead(_ value: Any?) throws -> ApiRequestHead {
        guard let object = value as? [String: Any] else {
            throw FixtureError(description: "API request head is not an object")
        }
        return ApiRequestHead(
            method: try string(object, "method"),
            path: try string(object, "path"),
            headers: try headerMap(object["headers"])
        )
    }

    static func apiResponseHead(_ value: Any?) throws -> ApiResponseHead? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any] else {
            throw FixtureError(description: "API response head is not an object")
        }
        return ApiResponseHead(
            status: try int(object["status"], "status"),
            headers: try headerMap(object["headers"])
        )
    }

    static func headerMap(_ value: Any?) throws -> [String: String] {
        guard let object = value as? [String: Any] else {
            throw FixtureError(description: "headers is not an object")
        }
        var headers: [String: String] = [:]
        for (name, value) in object {
            guard let string = value as? String else {
                throw FixtureError(description: "header \(name) is not a string")
            }
            headers[name] = string
        }
        return headers
    }

    static func headerFields(_ fixture: [String: Any]) throws -> [String: Any] {
        guard let header = fixture["header"] as? [String: Any] else {
            throw FixtureError(description: "WAL fixture has no header object")
        }
        return header
    }

    static func records(_ fixture: [String: Any]) throws -> [[String: Any]] {
        guard let records = fixture["records"] as? [[String: Any]] else {
            throw FixtureError(description: "WAL fixture has no records array")
        }
        return records
    }
}

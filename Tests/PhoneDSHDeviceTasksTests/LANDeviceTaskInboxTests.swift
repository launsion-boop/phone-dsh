// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHDeviceTasks

final class LANDeviceTaskInboxTests: XCTestCase {
    func testSharedTaskFixturesThroughSSEParser() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("spec/device/v1/golden/task-cases.jsonl")
        for line in try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n") {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let body = try JSONSerialization.data(withJSONObject: XCTUnwrap(row["task"]))
            var stream = Data("event: task\ndata: ".utf8)
            stream.append(body); stream.append(contentsOf: "\n\n".utf8)
            var parser = TaskSSEParser(), result: DeviceTask?, didThrow = false
            do { for byte in stream { if let value = try parser.push(byte) { result = value } } }
            catch { didThrow = true }
            let valid = try XCTUnwrap(row["valid"] as? Bool)
            XCTAssertEqual(result != nil && !didThrow, valid, row["name"] as? String ?? "")
        }
    }

    func testBoundedStreamAndMalformedUTF8() throws {
        var parser = TaskSSEParser()
        for _ in 0..<8192 { XCTAssertNil(try parser.push(65)) }
        XCTAssertThrowsError(try parser.push(65))
        parser = TaskSSEParser()
        XCTAssertNil(try parser.push(0xff))
        XCTAssertThrowsError(try parser.push(10))
        parser = TaskSSEParser()
        for byte in Data(("data: " + String(repeating: "x", count: 4097)).utf8) { XCTAssertNil(try parser.push(byte)) }
        XCTAssertThrowsError(try parser.push(10))
    }

    func testTaskEndpointRequiresHTTPSAndSafeCredential() throws {
        let session = URLSession(configuration: .ephemeral)
        XCTAssertThrowsError(try LANDeviceTaskInbox(mcpURL: URL(string: "http://example.test/mcp")!, authorization: "Bearer abc", session: session))
        XCTAssertThrowsError(try LANDeviceTaskInbox(mcpURL: URL(string: "https://example.test/mcp?token=x")!, authorization: "Bearer abc", session: session))
        XCTAssertThrowsError(try LANDeviceTaskInbox(mcpURL: URL(string: "https://example.test/mcp")!, authorization: "Bearer a\r\nb", session: session))
        XCTAssertNoThrow(try LANDeviceTaskInbox(mcpURL: URL(string: "https://example.test/mcp")!, authorization: "Bearer abc", session: session))
    }
}

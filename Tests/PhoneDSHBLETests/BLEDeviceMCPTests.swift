// SPDX-License-Identifier: MIT
import XCTest
import PhoneDSHAgentCore
import PhoneDSHLoopback
@testable import PhoneDSHBLE

final class BLEDeviceMCPTests: XCTestCase {
    @MainActor func testTaskGrantRejectsOptimisticIdentityState() async throws {
        let id = UUID()
        let identity = "ble:" + UUID().uuidString.lowercased()
        let suite = "BLEDeviceMCPTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        BLETrustedIdentities.insert(identity, defaults: defaults)
        XCTAssertTrue(BLETrustedIdentities.contains(identity, defaults: defaults))
        var device = BLEDeviceStore.Device(id: id, name: "test", rssi: 0)
        device.taskIdentity = identity
        device.supportsDeviceTasks = true // Exercise the grant boundary even with stale optimistic state.
        device.allowDeviceTasks = true
        let store = BLEDeviceStore(testDevices: [device])
        XCTAssertThrowsError(try store.grantDeviceTasks(id, enabled: true))
        XCTAssertFalse(try XCTUnwrap(store.devices.first).allowDeviceTasks)
        try store.grantDeviceTasks(id, enabled: false)
        XCTAssertFalse(try XCTUnwrap(store.devices.first).allowDeviceTasks)
        XCTAssertThrowsError(try store.grantDeviceTasks(UUID(), enabled: true))
    }
    private func request(_ method: String, _ params: JSONValue = .object([:]), key: String? = nil) throws -> LoopbackRequest {
        LoopbackRequest(method: "POST", path: "/mcp/native", headers: key.map { ["x-pdsh-idempotency-key": $0] } ?? [:], body: try JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": params]).encoded())
    }
    private func call(_ name: String, _ args: JSONValue, key: String? = nil) throws -> LoopbackRequest {
        try request("tools/call", .object(["name": .string(name), "arguments": args]), key: key)
    }
    func testNativeMCPGolden() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("spec/v1/golden/native-mcp/ble-devices.json")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let requestBody = try JSONSerialization.data(withJSONObject: XCTUnwrap(row["request"]))
        let request = LoopbackRequest(method: "POST", path: "/mcp/native", headers: [:], body: requestBody)
        let response = await DeviceMCPServer().handle(request)
        let actual = try JSONValue.parse(response.body)
        let expected = try JSONValue.parse(JSONSerialization.data(withJSONObject: XCTUnwrap(row["response"])))
        XCTAssertEqual(actual, expected)
    }
    func testToolListKeepsAndroidAndAddsBLE() async throws {
        let response = await DeviceMCPServer().handle(try request("tools/list"))
        let text = String(decoding: response.body, as: UTF8.self)
        for name in ["android_status", "android_tap", "ble_devices", "ble_read", "ble_alert", "ble_link_call", "ble_link_tools", "ble_link_result"] { XCTAssertTrue(text.contains("\"name\":\"\(name)\""), name) }
    }
    func testInitializationDescribesBothDeviceFamilies() async throws {
        let response = await DeviceMCPServer().handle(try request("initialize"))
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("Android")); XCTAssertTrue(text.contains("Bluetooth"))
    }
    func testMalformedArgumentsAndUnknownProfilesAreRejected() async throws {
        let server = DeviceMCPServer()
        let cases: [(String, JSONValue)] = [
            ("ble_devices", .array([])),
            ("ble_devices", .object(["scan": .bool(true)])),
            ("ble_read", .object(["device_id": .string(UUID().uuidString), "profile": .string("alert")])),
            ("ble_read", .object(["device_id": .string("bad"), "profile": .string("battery")])),
            ("ble_alert", .object(["device_id": .string(UUID().uuidString), "level": .number(1.5)])),
            ("ble_alert", .object(["device_id": .string(UUID().uuidString), "level": .number(3)])),
        ]
        for (name, args) in cases {
            let response = await server.handle(try call(name, args))
            XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("\"isError\":true"))
        }
    }
    func testUnselectedDeviceCannotBeRead() async throws {
        let response = await DeviceMCPServer().handle(try call("ble_read", .object(["device_id": .string(UUID().uuidString), "profile": .string("battery")])))
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("Enable device read access"))
    }
    func testAlertRequiresJournalAndPersistsIntentAcrossServerInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let args: JSONValue = .object(["device_id": .string(UUID().uuidString), "level": .number(1)])
        let server = DeviceMCPServer(receiptDirectory: directory)
        let missing = await server.handle(try call("ble_alert", args))
        XCTAssertTrue(String(decoding: missing.body, as: UTF8.self).contains("requires a journal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        // No authorized hardware exists. Recording intent is still conservative on an interrupted attempt.
        let first = await server.handle(try call("ble_alert", args, key: "once"))
        XCTAssertTrue(String(decoding: first.body, as: UTF8.self).contains("Enable Immediate Alert access"))
        let replay = await DeviceMCPServer(receiptDirectory: directory).handle(try call("ble_alert", args, key: "once"))
        XCTAssertTrue(String(decoding: replay.body, as: UTF8.self).contains("outcome_unknown"))
        let changed: JSONValue = .object(["device_id": .string(UUID().uuidString), "level": .number(2)])
        let conflict = await server.handle(try call("ble_alert", changed, key: "once"))
        XCTAssertTrue(String(decoding: conflict.body, as: UTF8.self).contains("Idempotency key conflict"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }
}

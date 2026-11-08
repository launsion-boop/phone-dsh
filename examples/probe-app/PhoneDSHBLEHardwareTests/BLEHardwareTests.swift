// SPDX-License-Identifier: MIT
import XCTest
import Foundation
import PhoneDSHBLE
import PhoneDSHAgentCore
import PhoneDSHLoopback

/// Dedicated hardware-only scheme. Never part of the simulator/default test gate.
final class BLEHardwareTests: XCTestCase {
    @MainActor func testRealESP32S3Lifecycle() async throws {
        guard let authority = ProcessInfo.processInfo.environment["PDSH_BLE_FIXTURE_AUTHORITY"],
              let token = ProcessInfo.processInfo.environment["PDSH_BLE_FIXTURE_TOKEN"] else { throw XCTSkip("Hardware fixture environment not configured") }
        let origin = "http://" + authority
        print("BLE fixture origin raw: \(origin.debugDescription), bytes=\(Array(origin.utf8))")
        let origins = try HomeHTTPPolicy.origins(origin)
        print("BLE fixture normalized origins: \(origins)")
        let store = BLEDeviceStore.shared
        var evidence: [String: JSONValue] = [:]
        let started = Date(), runID = UUID().uuidString.lowercased()
        defer {
            store.stopScan()
            evidence["elapsed_seconds"] = .number(Date().timeIntervalSince(started))
            if let data = try? JSONValue.object(evidence).encoded() {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "ESP32-S3 BLE hardware evidence"; attachment.lifetime = .keepAlways; add(attachment)
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pdsh-reports")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent("ble-hardware-report.json"), options: .atomic)
            }
        }
        store.scan()
        print("BLE hardware scan started: \(store.bluetoothDiagnostics), status=\(store.status), main=\(Thread.isMainThread)")
        let deadline = Date().addingTimeInterval(40)
        while !store.devices.contains(where: { $0.name == "PDSH ESP32 Link" }), Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
        print("BLE discovered \(store.devices.count) devices; Link matches: \(store.devices.filter { $0.name == "PDSH ESP32 Link" }.map(\.id))")
        let device = try XCTUnwrap(store.devices.first(where: { $0.name == "PDSH ESP32 Link" }), "ESP32 advertisement missing: \(store.status); \(store.bluetoothDiagnostics)")
        let id = device.id
        func connect() async throws {
            let until = Date().addingTimeInterval(80)
            while Date() < until {
                if let found = store.devices.first(where: { $0.id == id }), found.linkTools.contains("home.http"), found.linkTools.contains("light.set") {
                    for name in found.linkTools { store.grantLinkTool(id, name: name, enabled: true) }
                    store.setHomeOrigins(id, text: origin); return
                }
                store.connect(id)
                try await Task.sleep(for: .milliseconds(500))
            }
            XCTFail("Link handshake/tools failed: \(store.status), \(store.devices.first(where: { $0.id == id })?.linkState ?? "missing")")
            throw BLEFailure("Hardware connection deadline")
        }
        try await connect()
        evidence["negotiation"] = .string(store.devices.first(where: { $0.id == id })!.linkState)
        evidence["identity"] = .string(store.devices.first(where: { $0.id == id })!.linkIdentity)
        evidence["tool_discovery"] = .bool(true)
        let lightRequest = UUID(), lightKey = UUID().uuidString
        let setArgs: JSONValue = .object(["on": .bool(true)])
        let first = try await store.invokeLink(id, requestID: lightRequest, name: "light.set", arguments: setArgs, key: lightKey)
        XCTAssertEqual(first.fields["status"], .string("completed"))
        XCTAssertEqual(first.fields["result"]?.fields["on"], .bool(true))
        let repeated = try await store.invokeLink(id, requestID: lightRequest, name: "light.set", arguments: setArgs, key: lightKey)
        XCTAssertEqual(first, repeated, "Duplicate commit must return same receipt/revision")
        evidence["duplicate_light_commit"] = repeated
        let read = try await store.invokeLink(id, requestID: UUID(), name: "light.get", arguments: .object([:]), key: UUID().uuidString)
        XCTAssertEqual(read.fields["result"]?.fields["on"], .bool(true))
        XCTAssertEqual(read.fields["result"]?.fields["state_revision"], first.fields["result"]?.fields["state_revision"])
        let httpArgs: JSONValue = .object(["method": .string("POST"), "url": .string(origin + "/actuate?run=" + runID), "headers": .object(["X-PDSH-Fixture": .string(token)]), "body": .string("{\"test\":true}"), "timeout_ms": .number(5000)])
        let journalKey = "hardware-" + runID
        func mcpCall(_ args: JSONValue, key: String) async throws -> JSONValue {
            let request = LoopbackRequest(method: "POST", path: "/mcp/native", headers: ["x-pdsh-idempotency-key": key], body: try JSONValue.object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString), "method": .string("tools/call"), "params": .object(["name": .string("ble_link_call"), "arguments": .object(["device_id": .string(id.uuidString), "name": .string("home.http"), "args": args])])]).encoded())
            let response = await DeviceMCPServer.shared.handle(request)
            let json = try JSONValue.parse(response.body)
            XCTAssertEqual(json.fields["result"]?.fields["isError"], .bool(false), String(decoding: response.body, as: UTF8.self))
            guard case .array(let contents) = json.fields["result"]?.fields["content"], case .string(let text) = contents.first?.fields["text"] else { throw BLEFailure("Bad MCP content") }
            return try JSONValue.parse(Data(text.utf8))
        }
        let home = try await mcpCall(httpArgs, key: journalKey)
        XCTAssertEqual(home.fields["status"], .string("completed"))
        XCTAssertEqual(home.fields["result"]?.fields["http_status"], .number(200))
        let replay = try await mcpCall(httpArgs, key: journalKey)
        XCTAssertEqual(home, replay)
        evidence["home_http"] = home
        evidence["journal_replay_query_only"] = .bool(true)
        // Invalid tool arguments must be rejected by the physical firmware, without GPIO effects.
        do {
            _ = try await store.invokeLink(id, requestID: UUID(), name: "light.set", arguments: .object(["on": .string("invalid")]), key: UUID().uuidString)
            XCTFail("Firmware accepted malformed light arguments")
        } catch { evidence["firmware_argument_rejection"] = .bool(true) }
        store.disconnect(id); try await Task.sleep(for: .seconds(1)); try await connect()
        let afterReconnect = try await store.queryLink(id, requestID: lightRequest, name: "light.set")
        XCTAssertEqual(afterReconnect, first); evidence["reconnect_receipt"] = .bool(true)
        func control(_ path: String, method: String = "GET") async throws -> JSONValue {
            var request = URLRequest(url: URL(string: origin + path)!); request.httpMethod = method; request.timeoutInterval = 30
            request.setValue(token, forHTTPHeaderField: "X-PDSH-Fixture")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try JSONValue.parse(data)
        }
        let counts = try await control("/state?run=" + runID)
        XCTAssertEqual(counts.fields["actuations"], .number(1))
        _ = try await control("/control/reboot", method: "POST")
        store.disconnect(id); try await Task.sleep(for: .seconds(2)); try await connect()
        let persisted = try await store.queryLink(id, requestID: lightRequest, name: "light.set")
        XCTAssertEqual(persisted, first)
        let current = try await store.invokeLink(id, requestID: UUID(), name: "light.get", arguments: .object([:]), key: UUID().uuidString)
        XCTAssertNotEqual(current.fields["result"]?.fields["boot_id"], first.fields["result"]?.fields["boot_id"])
        XCTAssertEqual(current.fields["result"]?.fields["on"], .bool(false))
        XCTAssertEqual(current.fields["result"]?.fields["state_revision"], first.fields["result"]?.fields["state_revision"])
        let afterReboot = try await mcpCall(httpArgs, key: journalKey)
        XCTAssertEqual(home, afterReboot)
        let finalCounts = try await control("/state?run=" + runID)
        XCTAssertEqual(finalCounts.fields["actuations"], .number(1))
        evidence["reboot_persistence"] = .bool(true); evidence["fixture_counts"] = finalCounts
        let large = try await store.invokeLink(id, requestID: UUID(), name: "home.http", arguments: .object(["method": .string("GET"), "url": .string(origin + "/large"), "headers": .object(["X-PDSH-Fixture": .string(token)])]), key: UUID().uuidString)
        XCTAssertEqual(large.fields["status"], .string("completed"))
        XCTAssertEqual(large.fields["result"]?.fields["truncated"], .bool(true))
        guard case .string(let body) = large.fields["result"]?.fields["body"] else { throw BLEFailure("Missing large response") }
        XCTAssertEqual(body.utf8.count, 1024); evidence["multi_chunk_result"] = .bool(true)
        let redirect = try await store.invokeLink(id, requestID: UUID(), name: "home.http", arguments: .object(["method": .string("GET"), "url": .string(origin + "/redirect"), "headers": .object(["X-PDSH-Fixture": .string(token)])]), key: UUID().uuidString)
        XCTAssertEqual(redirect.fields["result"]?.fields["http_status"], .number(302))
        let timeoutArgs: JSONValue = .object(["method": .string("POST"), "url": .string(origin + "/slow"), "headers": .object(["X-PDSH-Fixture": .string(token)]), "timeout_ms": .number(1000)])
        let timeoutKey = "hardware-timeout-" + runID
        let uncertain = try await mcpCall(timeoutArgs, key: timeoutKey)
        XCTAssertEqual(uncertain.fields["status"], .string("outcome_unknown"))
        let timeoutReplay = try await mcpCall(timeoutArgs, key: timeoutKey)
        XCTAssertEqual(timeoutReplay, uncertain)
        let end = try await control("/state?run=" + runID)
        XCTAssertEqual(end.fields["actuations"], .number(1))
        XCTAssertEqual(end.fields["slow_requests"], .number(1))
        XCTAssertEqual(end.fields["redirect_targets"], .number(0))
        evidence["http_timeout_query_only"] = .bool(true); evidence["no_redirect_follow"] = .bool(true)
        evidence["final_fixture_counts"] = end
        evidence["xctest_completed"] = .bool(true)
    }
}
private extension JSONValue {
    var fields: [String: JSONValue] { if case .object(let object) = self { return object }; return [:] }
}

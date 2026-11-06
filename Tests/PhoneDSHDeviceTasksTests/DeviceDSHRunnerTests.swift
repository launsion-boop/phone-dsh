// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHDeviceTasks

private actor GuardInventoryTransport: DSHRemoteTransport {
    let rows: [JSONValue]
    var endpoints: [String] = []
    init(rows: [JSONValue]) { self.rows = rows }
    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        endpoints.append(endpoint)
        if endpoint == "phone/pluginList" {
            return .object(["ok": .bool(true), "value": .object(["entries": .array(rows)])])
        }
        throw DeviceTaskError.invalidTask
    }
    func openMux() async throws -> any DSHMuxConnection { throw DeviceTaskError.invalidTask }
    func calls() -> [String] { endpoints }
}

final class DeviceDSHRunnerTests: XCTestCase {
    func testMissingOrInactiveGuardStopsBeforeSessionCreation() async throws {
        let base: [String: JSONValue] = ["entryId": .string("include:device-task-guard"),
            "moduleName": .string("@phone-dsh/dsh-lifecycle-gate/device-guard"),
            "enabled": .bool(true), "fiberPhase": .string("active")]
        var inactive = base
        inactive["fiberPhase"] = .string("failed")
        for rows: [JSONValue] in [[], [.object(inactive)], [.object(base), .object(base)]] {
            let transport = GuardInventoryTransport(rows: rows)
            let runner = DeviceDSHRunner(transport: transport)
            do {
                _ = try await runner.session(for: "device", existingSession: nil)
                XCTFail("unverified guard must fail closed")
            } catch { XCTAssertEqual(error as? DeviceTaskError, .unauthorized) }
            let calls = await transport.calls()
            XCTAssertEqual(calls, ["phone/pluginList"])
        }
    }
}

private actor ScriptedDeviceMux: DSHMuxConnection {
    private var requestID: String?
    private var index = 0
    func setRequestID(_ id: String) { requestID = id }
    func send(_ frame: JSONValue) async throws {}
    func close() async {}
    func receive() async throws -> JSONValue? {
        while requestID == nil { try await Task.sleep(for: .milliseconds(2)) }
        let id = requestID!
        let events: [JSONValue] = [
            .object(["type": .string("turn/start"), "seq": .number(4), "data": .object(["turn": .number(1)])]),
            .object(["type": .string("user/message"), "seq": .number(8), "data": .object(["source": .object(["kind": .string("user"), "rpcId": .string(id)]), "content": .array([.object(["type": .string("text"), "text": .string("goal")])])])]),
            .object(["type": .string("user/message"), "seq": .number(9), "data": .object(["source": .object(["kind": .string("runtime-context")]), "content": .array([.object(["type": .string("text"), "text": .string("runtime snapshot")])])])]),
            .object(["type": .string("assistant/message"), "seq": .number(10), "data": .object(["message": .object(["content": .array([.object(["type": .string("text"), "text": .string("model answer")])])])])]),
            .object(["type": .string("turn/end"), "seq": .number(11), "data": .object(["turn": .number(1), "reason": .object(["kind": .string("completed")])])]),
        ]
        guard index < events.count else { return nil }
        let event = events[index]; index += 1
        return .object(["type": .string("item"), "streamId": .string("follow"), "value": .object(["type": .string("event"), "event": event])])
    }
}
private actor ScriptedDeviceTransport: DSHRemoteTransport {
    let mux = ScriptedDeviceMux()
    let document: String
    init(document: String) { self.document = document }
    func openMux() async throws -> any DSHMuxConnection { mux }
    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        switch endpoint {
        case "phone/pluginList":
            return .object(["ok": .bool(true), "value": .object(["entries": .array([.object([
                "entryId": .string("include:device-task-guard"), "moduleName": .string("@phone-dsh/dsh-lifecycle-gate/device-guard"),
                "enabled": .bool(true), "fiberPhase": .string("active")])])])])
        case "agentPresets/read": return .object(["content": .string(document)])
        case "session/create": return .object(["sessionId": .string("session-1"), "agentPreset": .string("pdsh-device-task")])
        case "session/projections": return .object(["kind": .string("sequenced"), "asOfSeq": .number(2), "values": .object(["agentPreset": .string("pdsh-device-task")])])
        case "session/prompt":
            guard let id = args["request"]?["requestId"]?.stringValue else { throw DeviceTaskError.invalidTask }
            await mux.setRequestID(id)
            return .object([:])
        default: throw DeviceTaskError.invalidTask
        }
    }
}
private actor RunnerResultInbox: DeviceTaskInbox {
    var outcome: DeviceTaskOutcome?
    func accept(id: String) async throws {}
    func report(id: String, outcome: DeviceTaskOutcome) async throws { self.outcome = outcome }
    func reported() -> DeviceTaskOutcome? { outcome }
}

extension DeviceDSHRunnerTests {
    func testRealHarnessCorrelatesDeviceTurnAndIgnoresRuntimeContext() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try String(contentsOf: root.appendingPathComponent("spec/device/v1/golden/device-task-preset.yaml"), encoding: .utf8)
        let transport = ScriptedDeviceTransport(document: document)
        let runner = DeviceDSHRunner(transport: transport), inbox = RunnerResultInbox()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = try DeviceTask.decode(Data(#"{"id":"task-1","idempotency_key":"key-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"goal"}}"#.utf8))
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner)
        try await executor.process(deviceID: "device-1", task: task, authorized: true, inbox: inbox)
        let result = await inbox.reported()
        XCTAssertEqual(result, .completed(output: "model answer", truncated: false))
    }
}

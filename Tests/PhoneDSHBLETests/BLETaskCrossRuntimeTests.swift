// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHDeviceTasks
@testable import PhoneDSHBLE

@MainActor private final class CTaskBridge: PDSHLinkTransport {
    private let process = Process(), input = Pipe(), output = Pipe()
    private(set) var lastCommitStatus: UInt8?
    init(root: URL, targetCore: Bool = false) throws {
        process.executableURL = root.appendingPathComponent(".build/link-host/task-bridge")
        process.arguments = targetCore ? ["--target-core"] : []
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
    }
    func exchange(opcode: UInt8, body: Data) async throws -> Data {
        let hex = body.map { String(format: "%02x", $0) }.joined()
        try input.fileHandleForWriting.write(contentsOf: Data("\(opcode) \(hex)\n".utf8))
        var line = Data()
        while true {
            let part = output.fileHandleForReading.readData(ofLength: 1)
            guard let byte = part.first else { throw BLEFailure("C task bridge ended") }
            if byte == 10 { break }
            line.append(byte)
            guard line.count <= 2000 else { throw BLEFailure("C task bridge response too large") }
        }
        guard let text = String(data: line, encoding: .utf8), text.count % 2 == 0 else { throw BLEFailure("invalid bridge response") }
        var result = Data(), cursor = text.startIndex
        while cursor < text.endIndex {
            let end = text.index(cursor, offsetBy: 2)
            guard let byte = UInt8(text[cursor..<end], radix: 16) else { throw BLEFailure("invalid bridge hex") }
            result.append(byte); cursor = end
        }
        if opcode == 0x55 { lastCommitStatus = result.first }
        return result
    }
    func resetCommitStatus() { lastCommitStatus = nil }
    func stop() { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
}

@MainActor private final class CrossRuntimeInbox: BLETaskLinkInbox {
    let client: PDSHLinkClient
    var dropAcceptReply = false
    var dropCompleteReply = false
    init(_ client: PDSHLinkClient) { self.client = client }
    func next() async throws -> DeviceTask {
        let reply = try await client.invoke(requestID: UUID(), name: "pdsh.task.next", arguments: .object([:]), idempotencyKey: UUID().uuidString)
        guard let value = reply["result"]?["task"] else { throw BLEFailure("missing task") }
        return try DeviceTask.decode(value.encoded())
    }
    func invokeOrQuery(requestID: UUID, name: String, arguments: JSONValue,
                       idempotencyKey: String, fresh: Bool) async throws -> JSONValue {
        if fresh {
            let value = try await client.invoke(requestID: requestID, name: name, arguments: arguments, idempotencyKey: idempotencyKey)
            if name == "pdsh.task.accept" && dropAcceptReply { dropAcceptReply = false; throw BLEFailure("simulated lost accept reply") }
            if name == "pdsh.task.complete" && dropCompleteReply { dropCompleteReply = false; throw BLEFailure("simulated lost completion reply") }
            return value
        }
        guard let value = try await client.query(requestID: requestID) else { throw BLEFailure("pending") }
        return value
    }
}
private actor CrossRuntimeRunner: DeviceTaskRunner {
    private var count = 0
    func session(for deviceID: String, existingSession: String?) async throws -> String { existingSession ?? "session-1" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome { count += 1; return .completed(output: "answer from phone", truncated: false) }
    func cancel(sessionID: String) async {}
    func runs() -> Int { count }
}

final class BLETaskCrossRuntimeTests: XCTestCase {
    private func buildBridge(root: URL) throws {
        let build = Process(); build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = [root.appendingPathComponent("firmware/tests/run.sh").path]
        build.currentDirectoryURL = root
        build.standardOutput = FileHandle.nullDevice; build.standardError = FileHandle.standardError
        try build.run(); build.waitUntilExit(); XCTAssertEqual(build.terminationStatus, 0)
        guard build.terminationStatus == 0 else { throw BLEFailure("C task bridge build failed") }
    }

    @MainActor func testSwiftExecutorTalksToTargetCoreAndReadsResult() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try buildBridge(root: root)
        let bridge = try CTaskBridge(root: root, targetCore: true)
        defer { bridge.stop() }
        let client = PDSHLinkClient(transport: bridge, allowTaskProfile: true); _ = try await client.handshake()
        let discovery = try await client.invoke(requestID: UUID(), name: "tools/list", arguments: .object([:]), idempotencyKey: UUID().uuidString)
        let deviceID = try XCTUnwrap(discovery["result"]?["device_id"]?.stringValue)
        let inbox = CrossRuntimeInbox(client), task = try await inbox.next()
        inbox.dropAcceptReply = true; inbox.dropCompleteReply = true
        XCTAssertEqual(task.body.text, "Hello from device")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = CrossRuntimeRunner()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner)
        do { try await executor.process(deviceID: "ble:" + deviceID, task: task, authorized: true, inbox: inbox); XCTFail("lost accept reply") } catch {}
        do { try await executor.process(deviceID: "ble:" + deviceID, task: task, authorized: true, inbox: inbox); XCTFail("lost completion reply") } catch {}
        try await executor.process(deviceID: "ble:" + deviceID, task: task, authorized: true, inbox: inbox)
        let runs = await runner.runs()
        XCTAssertEqual(runs, 1)
        let local = try JSONValue.parse(await bridge.exchange(opcode: 254, body: Data()))
        XCTAssertEqual(local["phase"]?.stringValue, "completed")
        XCTAssertEqual(local["outcome"]?["output"]?.stringValue, "answer from phone")
    }

    @MainActor func testProductionDispatcherHidesAndRejectsPlaintextTaskTools() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try buildBridge(root: root)
        let bridge = try CTaskBridge(root: root)
        defer { bridge.stop() }
        let client = PDSHLinkClient(transport: bridge, allowTaskProfile: true)
        _ = try await client.handshake()
        let discovery = try await client.invoke(requestID: UUID(), name: "tools/list", arguments: .object([:]), idempotencyKey: UUID().uuidString)
        let toolsValue = try XCTUnwrap(discovery["result"]?["tools"])
        guard case .array(let tools) = toolsValue else { return XCTFail("missing tools array") }
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("light.get"))
        XCTAssertFalse(names.contains { $0.hasPrefix("pdsh.task.") })

        let taskCalls: [(String, JSONValue)] = [
            ("pdsh.task.next", .object([:])),
            ("pdsh.task.accept", .object(["id": .string("task-1")])),
            ("pdsh.task.complete", .object(["id": .string("task-1"), "output": .string("done"), "truncated": .bool(false)])),
            ("pdsh.task.fail", .object(["id": .string("task-1"), "failure": .object(["kind": .string("failed"), "message": .string("failed")])])),
            ("pdsh.task.future", .object(["id": .string("task-1")])),
        ]
        for (name, args) in taskCalls {
            bridge.resetCommitStatus()
            let requestID = UUID()
            do {
                _ = try await client.invoke(requestID: requestID, name: name, arguments: args, idempotencyKey: UUID().uuidString)
                XCTFail("\(name) unexpectedly succeeded")
            } catch {
                XCTAssertEqual(bridge.lastCommitStatus, 14, "\(name) must reach production COMMIT and be refused")
            }
            // A missing receipt is represented as unknown, never as proof of non-execution
            // or permission to replay an operation after an uncertain delivery.
            let recovered = try await client.query(requestID: requestID)
            XCTAssertEqual(recovered?["request_id"]?.stringValue, requestID.uuidString.lowercased())
            XCTAssertEqual(recovered?["status"]?.stringValue, "outcome_unknown")
        }
        let ordinary = try await client.invoke(requestID: UUID(), name: "light.get", arguments: .object([:]), idempotencyKey: UUID().uuidString)
        XCTAssertEqual(ordinary["status"]?.stringValue, "completed")
        let local = try JSONValue.parse(await bridge.exchange(opcode: 254, body: Data()))
        XCTAssertEqual(local["phase"]?.stringValue, "queued")
    }
}

// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHDeviceTasks
@testable import PhoneDSHBLE

@MainActor private final class CTaskBridge: PDSHLinkTransport {
    private let process = Process(), input = Pipe(), output = Pipe()
    init(root: URL) throws {
        process.executableURL = root.appendingPathComponent(".build/link-host/task-bridge")
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
        return result
    }
    func stop() { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
}

@MainActor private final class CrossRuntimeInbox: BLETaskLinkInbox {
    let client: PDSHLinkClient
    init(_ client: PDSHLinkClient) { self.client = client }
    func next() async throws -> DeviceTask {
        let reply = try await client.invoke(requestID: UUID(), name: "pdsh.task.next", arguments: .object([:]), idempotencyKey: UUID().uuidString)
        guard let value = reply["result"]?["task"] else { throw BLEFailure("missing task") }
        return try DeviceTask.decode(value.encoded())
    }
    func invokeOrQuery(requestID: UUID, name: String, arguments: JSONValue,
                       idempotencyKey: String, fresh: Bool) async throws -> JSONValue {
        if fresh { return try await client.invoke(requestID: requestID, name: name, arguments: arguments, idempotencyKey: idempotencyKey) }
        guard let value = try await client.query(requestID: requestID) else { throw BLEFailure("pending") }
        return value
    }
}
private actor CrossRuntimeRunner: DeviceTaskRunner {
    func session(for deviceID: String, existingSession: String?) async throws -> String { existingSession ?? "session-1" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome { .completed(output: "answer from phone", truncated: false) }
    func cancel(sessionID: String) async {}
}

final class BLETaskCrossRuntimeTests: XCTestCase {
    @MainActor func testSwiftExecutorTalksToRealCFirmwareLinkAndReadsResult() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = Process(); build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = [root.appendingPathComponent("firmware/tests/run.sh").path]
        build.currentDirectoryURL = root
        build.standardOutput = FileHandle.nullDevice; build.standardError = FileHandle.standardError
        try build.run(); build.waitUntilExit(); XCTAssertEqual(build.terminationStatus, 0)
        guard build.terminationStatus == 0 else { return }
        let bridge = try CTaskBridge(root: root)
        defer { bridge.stop() }
        let client = PDSHLinkClient(transport: bridge, allowTaskProfile: true); _ = try await client.handshake()
        let discovery = try await client.invoke(requestID: UUID(), name: "tools/list", arguments: .object([:]), idempotencyKey: UUID().uuidString)
        let deviceID = try XCTUnwrap(discovery["result"]?["device_id"]?.stringValue)
        let inbox = CrossRuntimeInbox(client), task = try await inbox.next()
        XCTAssertEqual(task.body.text, "Hello from device")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let executor = try DeviceTaskExecutor(directory: dir, runner: CrossRuntimeRunner())
        try await executor.process(deviceID: "ble:" + deviceID, task: task, authorized: true, inbox: inbox)
        let local = try JSONValue.parse(await bridge.exchange(opcode: 254, body: Data()))
        XCTAssertEqual(local["phase"]?.stringValue, "completed")
        XCTAssertEqual(local["outcome"]?["output"]?.stringValue, "answer from phone")
    }
}

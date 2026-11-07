// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHDeviceTasks

final class BLETaskIntentTests: XCTestCase {
    func testSharedIntentVectorsAndQueryOnlyRecovery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("spec/device/v1/golden/ble-task-link-ops.jsonl")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let taskJSON = """
        {"id":"task-1","idempotency_key":"goal-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Hello"}}
        """
        let task = try DeviceTask.decode(Data(taskJSON.utf8))
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            let row = try JSONValue.parse(Data(line.utf8))
            let args = try XCTUnwrap(row["args"])
            let expectedJSON = try XCTUnwrap(row["record"])
            let expected = try JSONDecoder().decode(BLETaskIntent.self, from: expectedJSON.encoded())
            let journal = try DeviceTaskJournal(directory: dir.appendingPathComponent(UUID().uuidString))
            var record = try journal.create(deviceID: "ble:ce6ec956-1111-4222-8333-123456789abc", task: task, sessionID: "session-1", now: Date())
            if expected.action == .complete {
                record.phase = .terminal
                record.outcome = .completed(output: "OK", truncated: false)
                try journal.save(record)
            } else if expected.action == .fail {
                record.phase = .terminal
                record.outcome = .failed(kind: .expired, message: "Expired")
                try journal.save(record)
            }
            let made = try BLETaskIntent.make(record: record, action: expected.action, arguments: args)
            XCTAssertEqual(made == expected, row["valid"]?.boolValue, row["name"]?.stringValue ?? "")
            if row["valid"]?.boolValue == true {
                let first = try journal.prepareBLETransition(record: record, action: expected.action, arguments: args)
                XCTAssertTrue(first.fresh)
                XCTAssertEqual(first.intent, expected)
                let second = try journal.prepareBLETransition(record: record, action: expected.action, arguments: args)
                XCTAssertFalse(second.fresh, "a persisted intent is query-only")
                XCTAssertEqual(second.intent, expected)
                if expected.action == .complete {
                    let badArgs: JSONValue = .object(["id": .string("task-1"), "output": .string("changed"), "truncated": .bool(false)])
                    XCTAssertThrowsError(try journal.prepareBLETransition(record: record, action: .complete, arguments: badArgs))
                }
            }
        }
    }

    private struct InventoryVector: Decodable {
        let name: String
        let mutation: String
        let valid: Bool
    }

    /// Snapshot bytes, directory entries and symlink targets without following
    /// symlinks, so a rejected scan cannot silently repair its evidence.
    private func snapshot(_ root: URL) throws -> [String: String] {
        let fm = FileManager.default
        var result: [String: String] = [:]
        func visit(_ url: URL, _ path: String) throws {
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                result[path] = "link:" + (try fm.destinationOfSymbolicLink(atPath: url.path))
            } else if type == .typeDirectory {
                result[path] = "directory"
                for name in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(url.appendingPathComponent(name), path + "/" + name)
                }
            } else {
                result[path] = "file:" + (try Data(contentsOf: url).base64EncodedString())
            }
        }
        try visit(root, ".")
        return result
    }

    func testSharedGlobalInventoryVectorsAndReadOnlyFailure() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("spec/device/v1/golden/ble-task-inventory.jsonl")
        let vectors = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(InventoryVector.self, from: Data($0.utf8))
        }
        XCTAssertEqual(vectors.count, 22)
        for vector in vectors {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base) }
            let dir = base.appendingPathComponent("journal")
            let journal = try DeviceTaskJournal(directory: dir)
            let task = try DeviceTask.decode(Data(#"{"id":"task-1","idempotency_key":"goal-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Hello"}}"#.utf8))
            var record = try journal.create(deviceID: "ble:ce6ec956-1111-4222-8333-123456789abc", task: task, sessionID: "session-1", now: Date())
            let terminalComplete = ["valid_complete", "missing_terminal", "different_terminal", "write_wrong_complete"].contains(vector.mutation)
            let action: BLETaskIntent.Action = terminalComplete ? .complete : (["valid_fail", "write_wrong_fail"].contains(vector.mutation) ? .fail : .accept)
            let args: JSONValue
            switch action {
            case .accept: args = .object(["id": .string(task.id)])
            case .complete:
                record.phase = .terminal; record.outcome = .completed(output: "OK", truncated: false)
                try journal.save(record)
                args = .object(["id": .string(task.id), "output": .string("OK"), "truncated": .bool(false)])
            case .fail:
                record.phase = .terminal; record.outcome = .failed(kind: .expired, message: "Expired")
                try journal.save(record)
                args = .object(["id": .string(task.id), "failure": .object(["kind": .string("expired"), "message": .string("Expired")])])
            }
            let ops = dir.appendingPathComponent("ble-ops")
            let path = ops.appendingPathComponent(record.msgID + "-" + action.rawValue + ".json")
            if vector.mutation.hasPrefix("write_wrong_") {
                let wrong: JSONValue
                switch action {
                case .accept: wrong = .object(["id": .string(task.id), "extra": .bool(true)])
                case .complete: wrong = .object(["id": .string(task.id), "output": .string("changed"), "truncated": .bool(false)])
                case .fail: wrong = .object(["id": .string(task.id), "failure": .object(["kind": .string("failed"), "message": .string("Expired")])])
                }
                let before = try snapshot(base)
                XCTAssertThrowsError(try journal.prepareBLETransition(record: record, action: action, arguments: wrong), vector.name)
                XCTAssertEqual(try snapshot(base), before, "invalid arguments wrote an intent: \(vector.name)")
                XCTAssertEqual(try journal.records(), [record], vector.name)
                continue
            }
            if vector.mutation != "missing_directory" {
                XCTAssertTrue(try journal.prepareBLETransition(record: record, action: action, arguments: args).fresh, vector.name)
            }
            switch vector.mutation {
            case "missing_directory", "valid_accept", "valid_complete", "valid_fail": break
            case "orphan_parent": try FileManager.default.removeItem(at: dir.appendingPathComponent(record.msgID + ".json"))
            case "wrong_filename": try FileManager.default.moveItem(at: path, to: ops.appendingPathComponent("wrong.json"))
            case "wrong_device", "wrong_task", "wrong_derived_key", "wrong_argument_hash", "unknown_version":
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
                switch vector.mutation {
                case "wrong_device": object["device_id"] = "ble:ce6ec956-1111-4222-8333-123456789abd"
                case "wrong_task": object["task_id"] = "task-2"
                case "wrong_derived_key": object["idem_key"] = String(repeating: "0", count: 64)
                case "wrong_argument_hash": object["arguments_sha256"] = String(repeating: "0", count: 64)
                default: object["v"] = 2
                }
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path)
            case "missing_terminal":
                record.phase = .accepted; record.outcome = nil; try journal.save(record)
            case "different_terminal":
                record.outcome = .completed(output: "different", truncated: false); try journal.save(record)
            case "duplicate_key":
                let original = try String(contentsOf: path, encoding: .utf8)
                try Data(("{\"v\":1," + original.dropFirst()).utf8).write(to: path)
            case "malformed_json": try Data("{".utf8).write(to: path)
            case "symlink_intent":
                let target = base.appendingPathComponent("saved-intent")
                try FileManager.default.moveItem(at: path, to: target)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
            case "symlink_directory":
                let target = base.appendingPathComponent("saved-ops")
                try FileManager.default.moveItem(at: ops, to: target)
                try FileManager.default.createSymbolicLink(at: ops, withDestinationURL: target)
            case "extra_file": try Data("extra".utf8).write(to: ops.appendingPathComponent("unrelated"))
            case "oversize": try Data(repeating: 32, count: 65537).write(to: path)
            default: XCTFail("unhandled shared scenario \(vector.name)"); continue
            }
            let before = try snapshot(base)
            if vector.valid {
                XCTAssertEqual(try journal.records(), [record], vector.name)
                if vector.mutation != "missing_directory" {
                    XCTAssertFalse(try journal.prepareBLETransition(record: record, action: action, arguments: args).fresh, vector.name)
                }
            } else {
                XCTAssertThrowsError(try journal.records(), vector.name) { error in
                    XCTAssertEqual(error as? DeviceTaskError, .corruptJournal, vector.name)
                }
            }
            XCTAssertEqual(try snapshot(base), before, "inventory changed evidence: \(vector.name)")
        }
    }

    func testInventorySizeBoundaryAndEscapedDuplicateKeys() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("journal")
        let journal = try DeviceTaskJournal(directory: dir)
        let task = try DeviceTask.decode(Data(#"{"id":"task-1","idempotency_key":"goal-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Hello"}}"#.utf8))
        let record = try journal.create(deviceID: "ble:ce6ec956-1111-4222-8333-123456789abc", task: task, sessionID: "session-1", now: Date())
        let args: JSONValue = .object(["id": .string(task.id)])
        _ = try journal.prepareBLETransition(record: record, action: .accept, arguments: args)
        let path = dir.appendingPathComponent("ble-ops/\(record.msgID)-accept.json")
        let original = try Data(contentsOf: path)
        let boundary = original + Data(repeating: 32, count: 65536 - original.count)
        try boundary.write(to: path)
        XCTAssertEqual(try journal.records(), [record], "65536 bytes is accepted")
        try (boundary + Data([32])).write(to: path)
        let oversized = try snapshot(base)
        XCTAssertThrowsError(try journal.records())
        XCTAssertEqual(try snapshot(base), oversized)
        let duplicate = Data(("{\"\\u0076\":1," + String(decoding: original, as: UTF8.self).dropFirst()).utf8)
        try duplicate.write(to: path)
        let corrupt = try snapshot(base)
        XCTAssertThrowsError(try journal.records(), "escaped and literal keys are the same JSON key")
        XCTAssertEqual(try snapshot(base), corrupt)
    }

    func testCorruptIntentForAnotherDeviceBlocksLookup() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let journal = try DeviceTaskJournal(directory: base)
        func task(_ id: String) throws -> DeviceTask {
            try DeviceTask.decode(Data("{\"id\":\"\(id)\",\"idempotency_key\":\"\(id)\",\"requester\":\"device\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"Hello\"}}".utf8))
        }
        let first = try journal.create(deviceID: "ble:ce6ec956-1111-4222-8333-123456789abc", task: task("first"), sessionID: "s1", now: Date())
        let second = try journal.create(deviceID: "ble:ce6ec956-1111-4222-8333-123456789abd", task: task("second"), sessionID: "s2", now: Date())
        _ = try journal.prepareBLETransition(record: second, action: .accept, arguments: .object(["id": .string(second.task.id)]))
        let path = base.appendingPathComponent("ble-ops/\(second.msgID)-accept.json")
        try Data("broken".utf8).write(to: path)
        let before = try snapshot(base)
        XCTAssertThrowsError(try journal.find(deviceID: first.deviceID, key: first.task.idempotencyKey))
        XCTAssertEqual(try snapshot(base), before)
    }
}

private actor FakeBLETaskLink: BLETaskLinkInbox {
    private var attempts: [(String, UUID, Bool)] = []
    private var dropFirstAccept = true
    func invokeOrQuery(requestID: UUID, name: String, arguments: JSONValue,
                       idempotencyKey: String, fresh: Bool) async throws -> JSONValue {
        attempts.append((name, requestID, fresh))
        if name == "pdsh.task.accept" && dropFirstAccept {
            dropFirstAccept = false
            throw CocoaError(.fileReadUnknown)
        }
        return .object(["request_id": .string(requestID.uuidString.lowercased()), "status": .string("completed"), "result": .object([:])])
    }
    func observed() -> [(String, UUID, Bool)] { attempts }
}

private actor FakeTaskRunner: DeviceTaskRunner {
    private var count = 0
    func session(for deviceID: String, existingSession: String?) async throws -> String { existingSession ?? "session-1" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome { count += 1; return .completed(output: "done", truncated: false) }
    func cancel(sessionID: String) async {}
    func runs() -> Int { count }
}

extension BLETaskIntentTests {
    func testLostAcceptQueriesSameLinkOperationAndNeverRerunsTask() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(#"{"id":"task-1","idempotency_key":"goal-1","requester":"device","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Hello"}}"#.utf8)
        let task = try DeviceTask.decode(bytes)
        let device = "ble:ce6ec956-1111-4222-8333-123456789abc"
        let runner = FakeTaskRunner(), link = FakeBLETaskLink()
        let executor = try DeviceTaskExecutor(directory: dir, runner: runner)
        do { try await executor.process(deviceID: device, task: task, authorized: true, inbox: link); XCTFail("lost accept") } catch {}
        try await executor.process(deviceID: device, task: task, authorized: true, inbox: link)
        try await executor.process(deviceID: device, task: task, authorized: true, inbox: link)
        let attempts = await link.observed(), runs = await runner.runs()
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(attempts.map(\.0), ["pdsh.task.accept", "pdsh.task.accept", "pdsh.task.complete", "pdsh.task.complete"])
        XCTAssertEqual(attempts.map(\.2), [true, false, true, false])
        XCTAssertEqual(attempts[0].1, attempts[1].1)
        XCTAssertEqual(attempts[2].1, attempts[3].1)
    }
}

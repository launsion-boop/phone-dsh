// SPDX-License-Identifier: MIT
// secure-session-v1 §9.2 intents and §9.3 recovery through the real journal
// and decision code, driven by the shared fixtures.
import Foundation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHDeviceTasks

final class BLESecureTaskIntentTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// The identities of the shared intent fixtures (secure-session-v2).
    lazy var accept: [String: Any] = (try! rows("ble-secure-task-intents.jsonl")).first { $0["name"] as? String == "accept" }!["record"] as! [String: Any]
    var device: String { accept["device_id"] as! String }
    var phone: String { accept["phone_id"] as! String }

    func rows(_ name: String) throws -> [[String: Any]] {
        try String(contentsOf: Self.root.appendingPathComponent("spec/device/v1/golden/" + name), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    /// Fixture args → typed arguments; nil when the member set does not match any action.
    func arguments(_ args: [String: Any], action: String) -> BLESecureTransitionArguments? {
        guard let id = args["id"] as? String, let idem = args["idem"] as? String else { return nil }
        switch (action, Set(args.keys)) {
        case ("accept", ["id", "idem"]): return .accept(id: id, idem: idem)
        case ("complete", ["id", "idem", "output", "truncated"]):
            guard let output = args["output"] as? String, let t = args["truncated"] as? Bool else { return nil }
            return .complete(id: id, idem: idem, output: output, truncated: t)
        case ("fail", ["id", "idem", "failure"]):
            guard let f = args["failure"] as? [String: Any], let k = (f["kind"] as? String).flatMap(DeviceTaskFailureKind.init(rawValue:)),
                  let m = f["message"] as? String else { return nil }
            return .fail(id: id, idem: idem, kind: k, message: m)
        default: return nil
        }
    }

    func testIntentVectors() throws {
        for row in try rows("ble-secure-task-intents.jsonl") {
            let name = row["name"] as! String
            let recordData = try JSONSerialization.data(withJSONObject: row["record"]!, options: [.sortedKeys, .withoutEscapingSlashes])
            var ok = false
            if let intent = try? BLESecureTaskIntent.decode(recordData),
               let args = arguments(row["args"] as! [String: Any], action: intent.action.rawValue),
               let expected = try? BLESecureTaskIntent.make(deviceID: intent.deviceID, phoneID: intent.phoneID, arguments: args) {
                ok = expected == intent
            }
            XCTAssertEqual(ok, row["valid"] as! Bool, name)
        }
    }

    func testCanonicalArgumentsAreByteExact() {
        let args = BLESecureTransitionArguments.complete(id: "task-1", idem: "goal-1", output: "a/b\t\"c\"\u{1}é ", truncated: true)
        XCTAssertEqual(String(decoding: args.canonicalJSON, as: UTF8.self),
                       #"{"id":"task-1","idem":"goal-1","output":"a/b\t\"c\"\u0001é ","truncated":true}"#)
        XCTAssertEqual(String(decoding: BLESecureTransitionArguments.fail(id: "t", idem: "k", kind: .unknownOutcome, message: "\u{8}\u{c}\r\n").canonicalJSON, as: UTF8.self),
                       #"{"failure":{"kind":"unknown_outcome","message":"\b\f\r\n"},"id":"t","idem":"k"}"#)
    }

    func testRecoveryVectors() throws {
        var decisions = Set<String>()
        for row in try rows("ble-secure-recovery.jsonl") {
            let name = row["name"] as! String
            let args = try XCTUnwrap(arguments(row["args"] as! [String: Any], action: row["action"] as! String), name)
            let status = row["status"] as! [String: Any]
            let observation: BLESecureStatusObservation
            switch status["t"] as? String {
            case "err": observation = .error(code: status["code"] as! String)
            case "status_r":
                var outcome: DeviceTaskOutcome?
                if let o = status["outcome"] as? [String: Any] {
                    if let f = o["failure"] as? [String: Any] {
                        outcome = .failed(kind: DeviceTaskFailureKind(rawValue: f["kind"] as! String)!, message: f["message"] as! String)
                    } else {
                        outcome = .completed(output: o["output"] as! String, truncated: o["truncated"] as! Bool)
                    }
                }
                observation = .status(phase: status["phase"] as! String, mine: status["mine"] as! Bool, outcome: outcome)
            default: observation = .none
            }
            let intentPhone = row["intent_phone_id"] as! String, currentPhone = row["current_phone_id"] as! String
            let intent = try BLESecureTaskIntent.make(deviceID: device, phoneID: intentPhone, arguments: args)
            let decision = BLESecureRecovery.decide(intent: intent, currentPhoneID: currentPhone, arguments: args, observation: observation)
            XCTAssertEqual(decision.rawValue, row["decision"] as! String, name)
            decisions.insert(decision.rawValue)
            // After a phone key change the same answer is never acted upon.
            let other = "phone:" + String(repeating: "0", count: 64)
            XCTAssertEqual(BLESecureRecovery.decide(intent: intent, currentPhoneID: other, arguments: args, observation: observation), .unresolved, name)
        }
        XCTAssertEqual(decisions, ["applied", "resend", "unresolved", "retry_query"])
    }

    // MARK: journal

    func makeTask() throws -> DeviceTask {
        try DeviceTask.decode(Data(#"{"id":"task-1","idempotency_key":"goal-1","requester":"sensor","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"Summarize the temperature reading."}}"#.utf8))
    }

    func testJournalInstallsOnceAndInventoriesSecureIntents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixtures = try rows("ble-secure-task-intents.jsonl")
        do {
            let journal = try DeviceTaskJournal(directory: dir)
            var record = try journal.create(deviceID: device, task: try makeTask(), sessionID: "s", now: Date())
            let accept = BLESecureTransitionArguments.accept(id: "task-1", idem: "goal-1")
            let first = try journal.prepareBLESecureTransition(record: record, phoneID: phone, arguments: accept)
            XCTAssertTrue(first.fresh)
            let golden = fixtures.first { $0["name"] as? String == "accept" }!["record"] as! [String: Any]
            let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("ble-secure-ops/" + first.intent.msgID + "-accept.json"))) as! NSDictionary
            XCTAssertEqual(onDisk, golden as NSDictionary, "the installed file is the shared fixture record")
            let second = try journal.prepareBLESecureTransition(record: record, phoneID: phone, arguments: accept)
            XCTAssertFalse(second.fresh, "a pre-existing intent is never rewritten; reconcile with status first")
            // After a key reset the old intent is returned unchanged (and is unresolved for recovery).
            let rekeyed = try journal.prepareBLESecureTransition(record: record, phoneID: "phone:" + String(repeating: "1", count: 64), arguments: accept)
            XCTAssertEqual(rekeyed.intent.phoneID, phone)
            XCTAssertFalse(rekeyed.fresh)
            // Complete arguments must equal the persisted terminal outcome.
            record.phase = .terminal
            record.outcome = .completed(output: "21.5°C", truncated: false)
            try journal.save(record)
            XCTAssertThrowsError(try journal.prepareBLESecureTransition(record: record, phoneID: phone,
                arguments: .complete(id: "task-1", idem: "goal-1", output: "changed", truncated: false)))
            let complete = try journal.prepareBLESecureTransition(record: record, phoneID: phone,
                arguments: .complete(id: "task-1", idem: "goal-1", output: "21.5°C", truncated: false))
            XCTAssertTrue(complete.fresh)
            let goldenComplete = fixtures.first { $0["name"] as? String == "complete" }!["record"] as! [String: Any]
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(complete.intent)) as! NSDictionary, goldenComplete as NSDictionary)
            XCTAssertEqual(try journal.records().count, 1, "valid inventory")
        }
        // Every invalid fixture record planted in ble-secure-ops fails the inventory closed.
        for row in fixtures where row["valid"] as? Bool == false {
            let record = row["record"] as! [String: Any]
            let msg = record["msg_id"] as? String ?? "x", action = record["action"] as? String ?? "accept"
            let file = dir.appendingPathComponent("ble-secure-ops/\(msg)-\(action).json")
            let backup = try? Data(contentsOf: file)
            try JSONSerialization.data(withJSONObject: record).write(to: file)
            let journal = try DeviceTaskJournal(directory: dir)
            XCTAssertThrowsError(try journal.records(), row["name"] as! String)
            if let backup { try backup.write(to: file) } else { try FileManager.default.removeItem(at: file) }
        }
        // Orphans and symlinks also fail closed.
        let orphan = dir.appendingPathComponent("ble-secure-ops/" + String(repeating: "e", count: 64) + "-accept.json")
        let installed = dir.appendingPathComponent("ble-secure-ops/\(accept["msg_id"] as! String)-accept.json")
        try FileManager.default.copyItem(at: installed, to: orphan)
        XCTAssertThrowsError(try DeviceTaskJournal(directory: dir).records())
        try FileManager.default.removeItem(at: orphan)
        try FileManager.default.createSymbolicLink(at: orphan, withDestinationURL: installed)
        XCTAssertThrowsError(try DeviceTaskJournal(directory: dir).records())
        try FileManager.default.removeItem(at: orphan)
        XCTAssertEqual(try DeviceTaskJournal(directory: dir).records().count, 1)
    }

    /// v2 §12 phone rollback row: a build that refuses every BLE grant never
    /// dispatches a secure parent record; `authorized: false` fails before the
    /// journal is touched.
    func testRollbackRefusedGrantNeverTouchesSecureParent() async throws {
        struct NoRunner: DeviceTaskRunner {
            func session(for deviceID: String, existingSession: String?) async throws -> String { XCTFail("runner used"); return "s" }
            func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome { XCTFail("dispatched"); return .completed(output: "", truncated: false) }
            func cancel(sessionID: String) async {}
        }
        struct NoInbox: DeviceTaskInbox {
            func accept(id: String) async throws { XCTFail("accept sent") }
            func report(id: String, outcome: DeviceTaskOutcome) async throws { XCTFail("report sent") }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-rollback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let journal = try DeviceTaskJournal(directory: dir)
            _ = try journal.create(deviceID: device, task: try makeTask(), sessionID: "s", now: Date())
            _ = try journal.prepareBLESecureTransition(record: try journal.records()[0], phoneID: phone, arguments: .accept(id: "task-1", idem: "goal-1"))
        }
        func snapshot() throws -> [String: Data] {
            var out: [String: Data] = [:]
            for path in try FileManager.default.subpathsOfDirectory(atPath: dir.path) {
                var isDir: ObjCBool = false
                let full = dir.appendingPathComponent(path).path
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { out[path] = try Data(contentsOf: URL(fileURLWithPath: full)) }
            }
            return out
        }
        let before = try snapshot()
        let executor = try DeviceTaskExecutor(directory: dir, runner: NoRunner())
        do {
            try await executor.process(deviceID: device, task: try makeTask(), authorized: false, inbox: NoInbox())
            XCTFail("an unauthorized secure parent was processed")
        } catch let error as DeviceTaskError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(try snapshot(), before, "journal and ble-secure-ops are byte-identical")
    }

    func testLegacyUUIDParentsNeverGetSecureIntents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try DeviceTaskJournal(directory: dir)
        let legacy = try journal.create(deviceID: "ble:ce6ec956-1111-4222-8333-123456789abc", task: try makeTask(), sessionID: "s", now: Date())
        XCTAssertThrowsError(try journal.prepareBLESecureTransition(record: legacy, phoneID: phone,
                                                                    arguments: .accept(id: "task-1", idem: "goal-1")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ble-secure-ops").path))
    }
}

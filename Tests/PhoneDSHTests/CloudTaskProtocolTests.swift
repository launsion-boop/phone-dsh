// SPDX-License-Identifier: MIT
// spec/v1/cloud-tasks.md (cloud-tasks-v1.5), phone side. The shared cases judge
// the real validators, body encoders, AAD builder, HPKE open and push
// recogniser. Nothing here contacts pdsh.tonoai.cn. The private scalars come
// from the shared vectors and are test-only values.

import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSH

enum CloudTaskCases {
    static func load() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("spec/v1/golden/cloud-tasks/cases.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

final class CloudTaskProtocolTests: XCTestCase {
    private func messages(_ key: String) throws -> [[String: Any]] {
        let messages = try XCTUnwrap(try CloudTaskCases.load()["messages"] as? [String: Any])
        return try XCTUnwrap(messages[key] as? [[String: Any]])
    }

    func testCasesAreTheFrozenRevisionAndConstantsMatch() throws {
        let cases = try CloudTaskCases.load()
        XCTAssertEqual(cases["revision"] as? String, CloudTasks.revision)
        let constants = try XCTUnwrap(cases["constants"] as? [String: Any])
        XCTAssertEqual(constants["suite"] as? String, CloudTasks.suite)
        XCTAssertEqual(constants["info"] as? String, CloudTasks.info)
        XCTAssertEqual((constants["minTtlMs"] as? NSNumber)?.int64Value, CloudTasks.minTtlMs)
        XCTAssertEqual((constants["maxTtlMs"] as? NSNumber)?.int64Value, CloudTasks.maxTtlMs)
        XCTAssertEqual(constants["maxPending"] as? Int, CloudTasks.maxPending)
        XCTAssertEqual(constants["maxTextBytes"] as? Int, CloudTasks.maxTextBytes)
        XCTAssertEqual(constants["maxDevices"] as? Int, CloudTasks.maxDevices)
        XCTAssertEqual(CloudTasks.origin.absoluteString, "https://pdsh.tonoai.cn")
        XCTAssertEqual(CloudTasks.deviceIDPreferenceKey, "phone-dsh.bot.cloud.device-id.v1")
        XCTAssertEqual(CloudTasks.enabledPreferenceKey, "phone-dsh.cloud-tasks.enabled.v1")
        XCTAssertEqual(CloudTasks.keychainService, "dev.phone-dsh.cloud-tasks")
    }

    // MARK: - messages

    func testEveryValidMessagePassesAndDeviceAndAckBodiesAreWhatTheEncodersProduce() throws {
        var schemas = Set<String>()
        var encoded = 0
        for item in try messages("valid") {
            let id = item["id"] as? String ?? ""
            let message = try XCTUnwrap(item["message"] as? [String: Any], id)
            XCTAssertNoThrow(try CloudTaskWire.validateRequest(message), id)
            let schema = try XCTUnwrap(message["schema"] as? String)
            schemas.insert(schema)
            let produced: Data
            switch schema {
            case CloudTaskDeviceRegistration.schema:
                produced = try CloudTaskDeviceRegistration(json: message).encoded()
            case CloudTaskAckBatch.schema:
                produced = try CloudTaskAckBatch(json: message).encoded()
            default:
                continue // phone-task-submit/v1 is the submitter's body; the phone never sends it.
            }
            encoded += 1
            XCTAssertEqual(try JSONSerialization.jsonObject(with: produced) as? NSDictionary,
                           message as NSDictionary, id)
            XCTAssertNoThrow(try CloudTaskWire.validateRequest(data: produced), id)
        }
        XCTAssertEqual(schemas, ["phone-device/v1", "phone-task-submit/v1", "phone-task-ack/v1"])
        XCTAssertEqual(encoded, 3)
    }

    func testEveryInvalidMessageIsRejected() throws {
        let invalid = try messages("invalid")
        XCTAssertGreaterThanOrEqual(invalid.count, 20)
        var device = 0, ack = 0
        for item in invalid {
            let id = item["id"] as? String ?? ""
            let message = try XCTUnwrap(item["message"], id)
            XCTAssertThrowsError(try CloudTaskWire.validateRequest(message), id)
            // The same case as bytes, through the parser the client would use.
            let data = try JSONSerialization.data(withJSONObject: message)
            XCTAssertThrowsError(try CloudTaskWire.validateRequest(data: data), id)
            switch (message as? [String: Any])?["schema"] as? String {
            case CloudTaskDeviceRegistration.schema:
                device += 1
                XCTAssertThrowsError(try CloudTaskDeviceRegistration(json: message), id)
            case CloudTaskAckBatch.schema:
                ack += 1
                XCTAssertThrowsError(try CloudTaskAckBatch(json: message), id)
            default:
                break
            }
        }
        XCTAssertGreaterThanOrEqual(device, 10)
        XCTAssertGreaterThanOrEqual(ack, 10)
    }

    func testEncodersRefuseToProduceABodyTheContractRejects() throws {
        let key = try XCTUnwrap(CloudTaskKey.generate(nowMs: 1).deviceKey)
        let device = "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a"
        XCTAssertThrowsError(try CloudTaskDeviceRegistration(appVersion: "", key: key, push: nil).encoded())
        XCTAssertThrowsError(try CloudTaskDeviceRegistration(
            appVersion: "1.0", key: key,
            push: CloudTaskPush(environment: .production, topic: "com.tono.phonedsh", token: "AB")).encoded())
        XCTAssertThrowsError(try CloudTaskDeviceRegistration(
            platform: .android, appVersion: "1.0", key: key,
            push: CloudTaskPush(environment: .production, topic: "a.b", deviceToken: Data(repeating: 0xAB, count: 32))).encoded())
        XCTAssertThrowsError(try CloudTaskAckBatch(deviceID: device, acks: []).encoded())
        XCTAssertThrowsError(try CloudTaskAckBatch(deviceID: "dev-1", acks: [CloudTaskAck(taskID: "t", state: .expired)]).encoded())
        XCTAssertThrowsError(try CloudTaskAckBatch(
            deviceID: device, acks: [CloudTaskAck(taskID: "t", state: .admitted(admissionID: "5F"))]).encoded())
        XCTAssertThrowsError(try CloudTaskAckBatch(
            deviceID: device, acks: [CloudTaskAck(taskID: "t 1", state: .expired)]).encoded())
        XCTAssertThrowsError(try CloudTaskAckBatch(
            deviceID: device,
            acks: (0..<17).map { CloudTaskAck(taskID: "t-\($0)", state: .expired) }).encoded())
        let push = CloudTaskPush(environment: .development, topic: "com.tono.phonedsh",
                                 deviceToken: Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(push.token, String(repeating: "ab", count: 32))
        XCTAssertNoThrow(try CloudTaskDeviceRegistration(appVersion: "1.4.0", key: key, push: push).encoded())
    }

    // MARK: - aad and sealing

    func testAAD() throws {
        let cases = try XCTUnwrap(try CloudTaskCases.load()["aad"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let target = try CloudTaskTarget(json: item["target"])
            let built = CloudTasks.aad(deviceID: item["device_id"] as! String, keyID: item["key_id"] as! String,
                                       requestID: item["request_id"] as! String, target: target,
                                       expiresAtMs: (item["expires_at_ms"] as! NSNumber).int64Value)
            XCTAssertEqual(String(decoding: built, as: UTF8.self), item["aad"] as? String)
        }
    }

    private func sealing(_ key: String) throws -> [[String: Any]] {
        let sealing = try XCTUnwrap(try CloudTaskCases.load()["sealing"] as? [String: Any])
        return try XCTUnwrap(sealing[key] as? [[String: Any]])
    }

    func testEverySealingVectorOpensToItsPlaintext() throws {
        let valid = try sealing("valid")
        XCTAssertGreaterThanOrEqual(valid.count, 3)
        for item in valid {
            let id = item["id"] as? String ?? ""
            let scalar = CloudTaskCases.hex(item["recipient_private_scalar"] as! String)
            // Key export: the registered public key is the uncompressed point of the stored scalar.
            let key = CloudTaskKey(keyID: "k-1", privateScalar: scalar, createdAtMs: 0)
            XCTAssertEqual(key.publicKey.map(CloudTaskJSON.base64URLEncode), item["recipient_public_key"] as? String, id)
            let sealed = try CloudTaskSealed(json: item["sealed"])
            let opened = try CloudTaskSealing.open(sealed, privateScalar: scalar,
                                                   aad: Data((item["aad"] as! String).utf8))
            XCTAssertEqual(opened, item["plaintext"] as? String, id)
        }
    }

    func testEveryInvalidSealingVectorIsRejected() throws {
        let invalid = try sealing("invalid")
        XCTAssertGreaterThanOrEqual(invalid.count, 4)
        for item in invalid {
            let id = item["id"] as? String ?? ""
            let sealed = try CloudTaskSealed(json: item["sealed"])
            XCTAssertThrowsError(try CloudTaskSealing.open(
                sealed, privateScalar: CloudTaskCases.hex(item["recipient_private_scalar"] as! String),
                aad: Data((item["aad"] as! String).utf8)), id) { error in
                XCTAssertEqual(error as? CloudTaskSealingError, .notOpened, id)
            }
        }
    }

    func testAGeneratedKeyRegistersAndOpensWhatIsSealedToIt() throws {
        let key = CloudTaskKey.generate(nowMs: 7)
        let other = CloudTaskKey.generate(nowMs: 7)
        XCTAssertNotEqual(key.keyID, other.keyID)
        XCTAssertTrue(CloudTaskJSON.isID(key.keyID))
        let point = try XCTUnwrap(key.publicKey)
        XCTAssertEqual(point.count, 65)
        XCTAssertEqual(point.first, 4)
        let body = try CloudTaskDeviceRegistration(appVersion: "1.4.0", key: try XCTUnwrap(key.deviceKey), push: nil).encoded()
        XCTAssertNoThrow(try CloudTaskWire.validateRequest(data: body))

        let aad = Data("pdsh-phone-task/v1\nd\nk\nr\nbot\nb\n1".utf8)
        let sealed = try CloudTaskTestSealer.seal("打开灯", to: point, aad: aad)
        XCTAssertEqual(try CloudTaskSealing.open(sealed, privateScalar: key.privateScalar, aad: aad), "打开灯")
        XCTAssertThrowsError(try CloudTaskSealing.open(sealed, privateScalar: other.privateScalar, aad: aad))
        // Opened bytes that are not UTF-8 text are not a task.
        let binary = try CloudTaskTestSealer.seal(Data([0xFF, 0xFE]), to: point, aad: aad)
        XCTAssertThrowsError(try CloudTaskSealing.open(binary, privateScalar: key.privateScalar, aad: aad)) { error in
            XCTAssertEqual(error as? CloudTaskSealingError, .notText)
        }
        XCTAssertThrowsError(try CloudTaskSealing.open(sealed, privateScalar: Data(repeating: 0, count: 32), aad: aad)) { error in
            XCTAssertEqual(error as? CloudTaskSealingError, .badKey)
        }
    }

    // MARK: - push

    func testPushRecognition() throws {
        let constants = try XCTUnwrap(try CloudTaskCases.load()["constants"] as? [String: Any])
        let push = try XCTUnwrap(constants["push"] as? [String: Any])
        XCTAssertTrue(CloudTasks.isTaskPush(push))
        XCTAssertFalse(CloudTasks.isTaskPush(["aps": ["content-available": 1]]))
        XCTAssertFalse(CloudTasks.isTaskPush(["aps": ["content-available": 1], "pdsh": ["v": 2, "kind": "phone-tasks"]]))
        XCTAssertFalse(CloudTasks.isTaskPush(["aps": ["content-available": 1], "pdsh": ["v": 1, "kind": "bot-wake"]]))
        XCTAssertFalse(CloudTasks.isTaskPush(["pdsh": ["v": "1", "kind": "phone-tasks"]]))
        XCTAssertFalse(CloudTasks.isTaskPush(["pdsh": ["v": 1.5, "kind": "phone-tasks"]]))
        XCTAssertFalse(CloudTasks.isTaskPush(["pdsh": ["v": true, "kind": "phone-tasks"]]))
        XCTAssertFalse(CloudTasks.isTaskPush(["pdsh": ["kind": "phone-tasks"]]))
        XCTAssertFalse(CloudTasks.isTaskPush(["pdsh": "phone-tasks"]))
        XCTAssertFalse(CloudTasks.isTaskPush([:]))
    }

    // MARK: - open answers

    func testEveryPullElementCaseDecodesOrIsClassifiedAsListed() throws {
        let cases = try XCTUnwrap(try CloudTaskCases.load()["pull_elements"] as? [[String: Any]])
        var kinds = Set<String>()
        for item in cases {
            let id = item["id"] as? String ?? ""
            let decoded = CloudTaskPullResponse.decodeElement(item["element"])
            switch decoded {
            case .task(let task):
                kinds.insert("ok")
                XCTAssertEqual(item["decodes"] as? Bool, true, id)
                XCTAssertTrue(item["ack"] is NSNull, id)
                XCTAssertEqual(task.taskID, "t-1", id)
            case .undecodable(let taskID):
                kinds.insert("rejected")
                XCTAssertEqual(item["decodes"] as? Bool, false, id)
                XCTAssertEqual(CloudTaskAck(taskID: taskID, state: .rejected(.invalid)).json as NSDictionary,
                               (item["ack"] as? [String: Any] ?? [:]).merging(["task_id": taskID]) { $1 } as NSDictionary, id)
            case .skipped:
                kinds.insert("skipped")
                XCTAssertEqual(item["decodes"] as? Bool, false, id)
                XCTAssertTrue(item["ack"] is NSNull, id)
            }
        }
        XCTAssertEqual(kinds, ["ok", "rejected", "skipped"])
        XCTAssertEqual(CloudTaskPullResponse.decodeElement("t-1"), .skipped)
        XCTAssertEqual(CloudTaskPullResponse.decodeElement(nil), .skipped)
    }

    func testServerAnswersAreOpenButRequireTheNamedMembers() throws {
        let sealed = try XCTUnwrap((try sealing("valid").first)?["sealed"] as? [String: Any])
        let task: [String: Any] = [
            "task_id": "t-1", "request_id": "req-1", "key_id": "k-1",
            "target": ["kind": "dsh-session", "id": "gb-main", "title": "ignored"],
            "expires_at_ms": 1_794_786_400_000, "created_at_ms": 1_794_700_000_000,
            "sealed": (sealed as [String: Any]).merging(["alg": "ignored"]) { $1 },
            "lease": ["lease_id": "l-1", "attempt": 1, "expires_at_ms": 1_794_700_300_000, "owner": "x"],
            "priority": 3]
        func pull(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var body: [String: Any] = ["schema": "phone-task-pull/v1", "server_time_ms": 1_794_700_000_000,
                                       "tasks": [task, ["task_id": "t-2"], ["request_id": "r"], 7], "next": "ignored"]
            change(&body)
            return try JSONSerialization.data(withJSONObject: body)
        }
        let decoded = try CloudTaskPullResponse.decode(try pull { _ in })
        XCTAssertEqual(decoded.elements.count, 4)
        XCTAssertEqual(decoded.tasks.map(\.taskID), ["t-1"], "unknown members are ignored at every level")
        XCTAssertEqual(decoded.tasks.first?.target, CloudTaskTarget(kind: .dshSession, id: "gb-main"))
        XCTAssertEqual(Array(decoded.elements.dropFirst()), [.undecodable(taskID: "t-2"), .skipped, .skipped])
        XCTAssertEqual(decoded.serverTimeMs, 1_794_700_000_000)
        XCTAssertNil(try CloudTaskPullResponse.decode(try pull { $0["server_time_ms"] = nil }).serverTimeMs)
        XCTAssertNil(try CloudTaskPullResponse.decode(try pull { $0["server_time_ms"] = "now" }).serverTimeMs)
        XCTAssertThrowsError(try CloudTaskPullResponse.decode(try pull { $0["schema"] = "phone-task-pull/v2" }))
        XCTAssertThrowsError(try CloudTaskPullResponse.decode(try pull { $0["tasks"] = nil }))
        XCTAssertThrowsError(try CloudTaskPullResponse.decode(try pull { $0["tasks"] = ["t": 1] }))
        XCTAssertThrowsError(try CloudTaskPullResponse.decode(Data("[]".utf8)))
        // The same members inside a request stay closed.
        XCTAssertThrowsError(try CloudTaskTarget(json: task["target"]))
        XCTAssertThrowsError(try CloudTaskSealed(json: task["sealed"]))

        func ackResult(_ change: (inout [String: Any], inout [String: Any]) -> Void) throws -> Data {
            var entry: [String: Any] = ["task_id": "t-1", "accepted": true, "duplicate": false, "state": "admitted"]
            var body: [String: Any] = ["schema": "phone-task-ack-result/v1", "server_time_ms": 5]
            change(&body, &entry)
            body["results"] = [entry]
            return try JSONSerialization.data(withJSONObject: body)
        }
        XCTAssertEqual(try CloudTaskAckResponse.decode(try ackResult { _, _ in }).results,
                       [CloudTaskAckResult(taskID: "t-1", accepted: true, duplicate: false, state: "admitted")])
        XCTAssertNoThrow(try CloudTaskAckResponse.decode(try ackResult { _, entry in entry["state"] = "not_found" }))
        XCTAssertNoThrow(try CloudTaskAckResponse.decode(try ackResult { body, entry in body["more"] = true; entry["reason"] = "x" }))
        XCTAssertThrowsError(try CloudTaskAckResponse.decode(try ackResult { _, entry in entry["accepted"] = 1 }))
        XCTAssertThrowsError(try CloudTaskAckResponse.decode(try ackResult { _, entry in entry["duplicate"] = nil }))
        XCTAssertThrowsError(try CloudTaskAckResponse.decode(try ackResult { _, entry in entry["state"] = 3 }))
        XCTAssertThrowsError(try CloudTaskAckResponse.decode(try ackResult { body, _ in body["server_time_ms"] = nil }))

        let device = "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a"
        let ack = #"{"schema":"phone-device-ack/v1","device_id":"\#(device)","key_id":"k-1","server_time_ms":9}"#
        XCTAssertEqual(try CloudTaskDeviceAck.decode(Data(ack.utf8)),
                       CloudTaskDeviceAck(deviceID: device, keyID: "k-1", serverTimeMs: 9))
        XCTAssertNoThrow(try CloudTaskDeviceAck.decode(Data(ack.replacingOccurrences(of: "\"key_id\"", with: "\"push\":null,\"key_id\"").utf8)))
        XCTAssertThrowsError(try CloudTaskDeviceAck.decode(Data(ack.replacingOccurrences(of: "\"k-1\"", with: "7").utf8)))

        XCTAssertEqual(CloudTaskErrorBody.decode(Data(#"{"error":{"code":"device_limit","message":"m","hint":1},"server_time_ms":3,"trace":"t"}"#.utf8)),
                       CloudTaskErrorBody(code: "device_limit", message: "m", serverTimeMs: 3))
        XCTAssertNil(CloudTaskErrorBody.decode(Data(#"{"detail":"Not Found"}"#.utf8)))
        XCTAssertNil(CloudTaskErrorBody.decode(Data("<html>".utf8)))
    }

    // MARK: - terminal mapping

    func testEveryTerminalCaseMapsToTheListedAck() throws {
        let cases = try XCTUnwrap(try CloudTaskCases.load()["terminal"] as? [[String: Any]])
        var seen = Set<String>()
        for item in cases {
            let reason = item["reason"] as? String
            let stage: CloudTaskTerminalReport.Stage
            switch item["stage"] as? String {
            case "completed": stage = .completed
            case "unknown": stage = .unknown
            case "expired": stage = .expired
            case "cancelled": stage = .cancelled
            case "failed": stage = .failed(reason: reason)
            default: XCTFail("stage \(item)"); continue
            }
            let report = CloudTaskTerminalReport(taskID: "t-1", admissionID: String(repeating: "5f", count: 32), stage: stage)
            let ack = CloudTaskAck(taskID: "t-1", state: report.ackState)
            var want = try XCTUnwrap(item["ack"] as? [String: Any])
            seen.insert((want["reason"] ?? want["state"]) as! String)
            want["task_id"] = "t-1"
            XCTAssertEqual(ack.json as NSDictionary, want as NSDictionary, "\(item)")
            XCTAssertNoThrow(try CloudTaskAckBatch(deviceID: "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a", acks: [ack]).encoded())
        }
        XCTAssertEqual(seen, ["completed", "unknown", "expired", "cancelled", "target_missing",
                              "not_authorized", "retry_exhausted", "run_failed"])
    }

    // MARK: - identity, switch, key store

    func testDeviceIdentityAndSwitchPreferences() throws {
        let suite = "cloud-task-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CloudTaskPreferences(defaults: defaults)
        XCTAssertFalse(preferences.isEnabled, "absent = off")
        XCTAssertNil(preferences.existingDeviceID())
        let created = try XCTUnwrap(preferences.deviceID())
        XCTAssertTrue(CloudTaskJSON.isDeviceID(created))
        XCTAssertEqual(defaults.string(forKey: "phone-dsh.bot.cloud.device-id.v1"), created)
        XCTAssertEqual(CloudTaskPreferences(defaults: defaults).deviceID(), created, "generated once per install")
        preferences.setEnabled(true)
        XCTAssertEqual(defaults.object(forKey: "phone-dsh.cloud-tasks.enabled.v1") as? Bool, true)
        XCTAssertTrue(preferences.isEnabled)
        preferences.setEnabled(false)
        XCTAssertFalse(preferences.isEnabled)
        // A value this contract does not describe is not ours to replace.
        defaults.set("DEV-1", forKey: "phone-dsh.bot.cloud.device-id.v1")
        XCTAssertNil(preferences.deviceID())
        XCTAssertEqual(defaults.string(forKey: "phone-dsh.bot.cloud.device-id.v1"), "DEV-1")
    }

    func testKeyStoresKeepKeysByIDAndTheNewestIsCurrent() throws {
        let old = CloudTaskKey.generate(nowMs: 10)
        let new = CloudTaskKey.generate(nowMs: 20)
        let store = InMemoryCloudTaskKeyStore([old])
        try store.save(new)
        XCTAssertEqual(try store.key(id: old.keyID), old)
        XCTAssertEqual(try store.currentKey(), new)
        XCTAssertNil(try store.key(id: "k-none"))
        try store.delete(id: new.keyID)
        XCTAssertEqual(try store.currentKey(), old)
        store.setFailure(.keychain(-25308))
        XCTAssertThrowsError(try store.key(id: old.keyID))

        let packed = KeychainCloudTaskKeyStore.pack(new)
        XCTAssertEqual(packed.count, 40)
        XCTAssertEqual(KeychainCloudTaskKeyStore.unpack(packed, keyID: new.keyID), new)
        XCTAssertNil(KeychainCloudTaskKeyStore.unpack(packed.dropLast(), keyID: new.keyID))
    }

    /// The real Keychain item. Off by default (it writes to the login keychain
    /// of the machine running the tests); run with `PDSH_CLOUD_TASK_KEYCHAIN_TEST=1`.
    func testKeychainStoreRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["PDSH_CLOUD_TASK_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("set PDSH_CLOUD_TASK_KEYCHAIN_TEST=1 to exercise the Keychain")
        }
        let store = KeychainCloudTaskKeyStore(service: "dev.phone-dsh.cloud-tasks.test-\(UUID().uuidString)")
        let old = CloudTaskKey.generate(nowMs: 10)
        let new = CloudTaskKey.generate(nowMs: 20)
        defer { try? store.delete(id: old.keyID); try? store.delete(id: new.keyID) }
        XCTAssertEqual(try store.keys(), [])
        try store.save(old)
        try store.save(new)
        try store.save(new)
        XCTAssertEqual(try store.key(id: old.keyID), old)
        XCTAssertEqual(Set(try store.keys().map(\.keyID)), [old.keyID, new.keyID])
        XCTAssertEqual(try store.currentKey(), new)
        try store.delete(id: old.keyID)
        try store.delete(id: old.keyID)
        XCTAssertNil(try store.key(id: old.keyID))
        XCTAssertEqual(try store.keys(), [new])
    }
}

/// The submitter's half, for tests only: the phone never seals.
enum CloudTaskTestSealer {
    static func seal(_ text: String, to publicKey: Data, aad: Data) throws -> CloudTaskSealed {
        try seal(Data(text.utf8), to: publicKey, aad: aad)
    }

    static func seal(_ plaintext: Data, to publicKey: Data, aad: Data) throws -> CloudTaskSealed {
        var sender = try HPKE.Sender(recipientKey: try P256.KeyAgreement.PublicKey(x963Representation: publicKey),
                                     ciphersuite: CloudTaskSealing.ciphersuite, info: Data(CloudTasks.info.utf8))
        let ciphertext = try sender.seal(plaintext, authenticating: aad)
        return CloudTaskSealed(enc: sender.encapsulatedKey, ct: ciphertext)
    }
}

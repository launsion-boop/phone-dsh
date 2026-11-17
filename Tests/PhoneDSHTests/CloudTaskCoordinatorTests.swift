// SPDX-License-Identifier: MIT
// spec/v1/cloud-tasks.md §5–§8 on iOS: the real client and coordinator run
// against an in-memory cloud that keeps the contract's task state machine, a
// fake admission journal and an in-memory key store. The shared `phone` cases
// judge the ack each pulled task produces. Nothing here contacts
// pdsh.tonoai.cn or the Keychain.

import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSH

// MARK: - Fakes

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); defer { lock.unlock() }; value = new }
    func update<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class FakeTokens: TonoAccessTokenSource, @unchecked Sendable {
    let state: Locked<(tokens: [String], index: Int, invalidated: [String], signedIn: Bool)>
    init(_ tokens: [String] = ["tok-1"], signedIn: Bool = true) {
        state = Locked((tokens, 0, [], signedIn))
    }
    func accessToken() async throws -> String? {
        let s = state.get()
        return s.signedIn ? s.tokens[min(s.index, s.tokens.count - 1)] : nil
    }
    func invalidate(accessToken: String) async {
        state.update { $0.invalidated.append(accessToken); $0.index += 1 }
    }
    var hasSession: Bool { state.get().signedIn }
    var invalidated: [String] { state.get().invalidated }
}

/// An in-memory cloud: registration, pull with leases, and the §6 ack state machine.
private final class FakeTaskCloud: CloudTaskTransport, @unchecked Sendable {
    struct Call {
        var route: String
        var method: String
        var url: URL
        var authorization: String?
        var body: Data?
        var json: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    enum Override {
        case answer(Int, String, [String: String] = [:])
        /// No answer, and the cloud did not see the request.
        case lost
        /// The cloud applied the request but the answer never arrived.
        case answerLost
    }

    struct Entry {
        var task: [String: Any]
        var state = "pending"
        var admissionID: String?
        var leased = false
        var attempt = 0
    }

    private let lock = NSLock()
    private var log: [Call] = []
    private var once: [String: [Override]] = [:]
    private var always: [String: Override] = [:]
    private var order: [String] = []
    private var entries: [String: Entry] = [:]
    private(set) var registration: [String: Any]?
    let events: Locked<[String]>
    /// `server_time_ms` of every answer.
    let serverTime = Locked<Int64>(1_794_700_000_000)
    var pullGate: Gate?

    init(events: Locked<[String]>) { self.events = events }

    func calls(_ route: String? = nil) -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return route.map { r in log.filter { $0.route == r } } ?? log
    }

    func failOnce(_ route: String, _ override: Override) {
        lock.lock(); defer { lock.unlock() }
        once[route, default: []].append(override)
    }

    func failAlways(_ route: String, _ override: Override?) {
        lock.lock(); defer { lock.unlock() }
        always[route] = override
    }

    func add(_ task: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let id = task["task_id"] as! String
        order.append(id)
        entries[id] = Entry(task: task)
    }

    /// The elements a pull would return now (leasing them), for a test that serves its own body.
    func pullOnce() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        var tasks: [[String: Any]] = []
        for id in order {
            guard var entry = entries[id], entry.state == "pending", !entry.leased else { continue }
            entry.leased = true
            entry.attempt += 1
            entries[id] = entry
            var task = entry.task
            task["lease"] = ["lease_id": "l-\(id)-\(entry.attempt)", "attempt": entry.attempt, "expires_at_ms": 1_794_700_300_000]
            tasks.append(task)
        }
        return tasks
    }

    func expireLeases() {
        lock.lock(); defer { lock.unlock() }
        for id in order { entries[id]?.leased = false }
    }

    func state(_ taskID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries[taskID]?.state
    }

    func acks() -> [[String: Any]] {
        calls("ack").flatMap { ($0.json?["acks"] as? [[String: Any]]) ?? [] }
    }

    func send(_ request: URLRequest) async throws -> TonoAccountProtocol.Answer {
        let url = request.url!
        let route: String
        switch (request.httpMethod ?? "GET", url.path) {
        case ("PUT", let path) where path.hasPrefix("/v1/phone/devices/"): route = "register"
        case ("DELETE", let path) where path.hasPrefix("/v1/phone/devices/"): route = "unregister"
        case ("GET", "/v1/phone/tasks/pull"): route = "pull"
        case ("POST", "/v1/phone/tasks/ack"): route = "ack"
        default: route = "other"
        }
        events.update { $0.append("request:\(route)") }
        if route == "pull", let pullGate { await pullGate.wait() }
        return try handle(Call(route: route, method: request.httpMethod ?? "GET", url: url,
                               authorization: request.value(forHTTPHeaderField: "Authorization"),
                               body: request.httpBody))
    }

    private func handle(_ call: Call) throws -> TonoAccountProtocol.Answer {
        lock.lock(); defer { lock.unlock() }
        log.append(call)
        var override = always[call.route]
        if var queue = once[call.route], !queue.isEmpty {
            override = queue.removeFirst()
            once[call.route] = queue
        }
        switch override {
        case .answer(let status, let body, let headers):
            return TonoAccountProtocol.Answer(status: status, headers: headers, body: Data(body.utf8))
        case .lost:
            throw URLError(.networkConnectionLost)
        case .answerLost:
            _ = apply(call)
            throw URLError(.networkConnectionLost)
        case nil:
            return apply(call)
        }
    }

    private func json(_ status: Int, _ object: [String: Any]) -> TonoAccountProtocol.Answer {
        var object = object
        object["server_time_ms"] = serverTime.get()
        return TonoAccountProtocol.Answer(status: status, headers: [:],
                                          body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func apply(_ call: Call) -> TonoAccountProtocol.Answer {
        switch call.route {
        case "register":
            guard let body = call.json, (try? CloudTaskWire.validateRequest(body)) != nil else {
                return json(400, ["error": ["code": "invalid_request", "message": "bad body"]])
            }
            registration = body
            return json(200, ["schema": "phone-device-ack/v1", "device_id": call.url.lastPathComponent,
                              "key_id": (body["key"] as! [String: Any])["key_id"]!])
        case "unregister":
            registration = nil
            for id in order where entries[id]?.state == "pending" { entries[id]?.state = "cancelled" }
            return TonoAccountProtocol.Answer(status: 204, headers: [:], body: Data())
        case "pull":
            var tasks: [[String: Any]] = []
            for id in order where tasks.count < 16 {
                guard var entry = entries[id], entry.state == "pending", !entry.leased else { continue }
                entry.leased = true
                entry.attempt += 1
                entries[id] = entry
                var task = entry.task
                task["lease"] = ["lease_id": "l-\(id)-\(entry.attempt)", "attempt": entry.attempt,
                                 "expires_at_ms": 1_794_700_300_000]
                tasks.append(task)
            }
            return json(200, ["schema": "phone-task-pull/v1", "tasks": tasks])
        case "ack":
            guard let body = call.json, (try? CloudTaskWire.validateRequest(body)) != nil else {
                return json(400, ["error": ["code": "invalid_request", "message": "bad body"]])
            }
            let results = (body["acks"] as! [[String: Any]]).map { ack -> [String: Any] in
                let id = ack["task_id"] as! String
                guard var entry = entries[id] else {
                    return ["task_id": id, "accepted": false, "duplicate": false, "state": "not_found"]
                }
                let (accepted, duplicate) = Self.applyAck(&entry, ack)
                entries[id] = entry
                return ["task_id": id, "accepted": accepted, "duplicate": duplicate, "state": entry.state]
            }
            return json(200, ["schema": "phone-task-ack-result/v1", "results": results])
        default:
            return json(404, ["error": ["code": "not_found", "message": "no route"]])
        }
    }

    /// The reference oracle's `apply_ack` (spec/v1/tools/test_cloud_tasks.py).
    private static func applyAck(_ entry: inout Entry, _ ack: [String: Any]) -> (Bool, Bool) {
        let want = ack["state"] as! String
        switch entry.state {
        case "pending":
            guard ["admitted", "rejected", "expired"].contains(want) else { return (false, false) }
            entry.state = want
            entry.admissionID = ack["admission_id"] as? String
            return (true, false)
        case "admitted":
            if want == "admitted" { return (ack["admission_id"] as? String == entry.admissionID, ack["admission_id"] as? String == entry.admissionID) }
            guard ["completed", "failed", "unknown"].contains(want) else { return (false, false) }
            entry.state = want
            return (true, false)
        default:
            return want == entry.state ? (true, true) : (false, false)
        }
    }
}

/// external-admission §1–§2 in miniature: the id law and dedupe by `admissionId`.
private final class FakeJournal: @unchecked Sendable {
    let records = Locked<[String: CloudTaskAdmissionRequest]>([:])
    let requests = Locked<[CloudTaskAdmissionRequest]>([])
    let scripted = Locked<CloudTaskAdmissionResult?>(nil)

    static func admissionID(deviceID: String, taskID: String) -> String {
        let bytes = Data("account:user-1\u{0}cloud-task\u{0}\(deviceID)\u{0}\(taskID)".utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func admit(_ request: CloudTaskAdmissionRequest) -> CloudTaskAdmissionResult {
        requests.update { $0.append(request) }
        if let scripted = scripted.get() { return scripted }
        let id = Self.admissionID(deviceID: request.deviceID, taskID: request.taskID)
        return records.update { records in
            if let existing = records[id] {
                return existing.target == request.target && existing.text == request.text ? .duplicate(admissionID: id) : .conflict
            }
            records[id] = request
            return .admitted(admissionID: id)
        }
    }
}

private final class Rig {
    static let deviceID = "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a"
    static let now: Int64 = 1_794_700_000_000

    let events = Locked<[String]>([])
    let cloud: FakeTaskCloud
    let tokens: FakeTokens
    let keys: InMemoryCloudTaskKeyStore
    let journal = FakeJournal()
    let clock = Locked<Int64>(Rig.now)
    let targetExists = Locked(true)
    let terminal = Locked<[CloudTaskTerminalReport]>([])
    let settled = Locked<[String]>([])
    let sleeps = Locked<[TimeInterval]>([])
    let key: CloudTaskKey
    let suite = "cloud-task-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let coordinator: CloudTaskCoordinator

    init(enabled: Bool = true, tokens: FakeTokens = FakeTokens(), key: CloudTaskKey? = nil, maxRounds: Int = 8) {
        cloud = FakeTaskCloud(events: events)
        self.tokens = tokens
        self.key = key ?? CloudTaskKey(keyID: "k-1", privateScalar: P256.KeyAgreement.PrivateKey().rawRepresentation,
                                       createdAtMs: 1)
        keys = InMemoryCloudTaskKeyStore([self.key])
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(Rig.deviceID, forKey: CloudTasks.deviceIDPreferenceKey)
        if enabled { defaults.set(true, forKey: CloudTasks.enabledPreferenceKey) }
        let journal = self.journal, events = self.events, targetExists = self.targetExists
        let terminal = self.terminal, settled = self.settled, clock = self.clock, sleeps = self.sleeps
        let host = CloudTaskHost(
            targetExists: { _ in targetExists.get() },
            admit: { request in
                // The journal write takes a while; the ack must wait for it.
                for _ in 0..<20 { await Task.yield() }
                let result = journal.admit(request)
                events.update { $0.append("admit-returned:\(request.taskID)") }
                return result
            },
            terminalReports: { _ in terminal.get() },
            terminalSettled: { id in settled.update { $0.append(id) } })
        coordinator = CloudTaskCoordinator(
            configuration: .init(appVersion: "1.4.0", maxRounds: maxRounds, now: { clock.get() }),
            host: host, tokens: tokens, transport: cloud, keyStore: keys, defaults: defaults,
            sleep: { seconds in sleeps.update { $0.append(seconds) } })
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    /// Queues a task on the cloud, sealed the way a submitter would.
    @discardableResult
    func submit(_ taskID: String, request: String? = nil, keyID: String = "k-1",
                target: CloudTaskTarget = CloudTaskTarget(kind: .dshSession, id: "gb-main"),
                expiresAtMs: Int64 = Rig.now + 86_400_000, text: String = "整理今天的会议纪要",
                sealTo: CloudTaskKey? = nil, breakAAD: Bool = false) throws -> String {
        let requestID = request ?? "req-\(taskID)"
        let aad = CloudTasks.aad(deviceID: Rig.deviceID, keyID: keyID, requestID: breakAAD ? requestID + "x" : requestID,
                                 target: target, expiresAtMs: expiresAtMs)
        let sealed = try CloudTaskTestSealer.seal(text, to: (sealTo ?? key).publicKey!, aad: aad)
        cloud.add(["task_id": taskID, "request_id": requestID, "key_id": keyID,
                   "target": ["kind": target.kind.rawValue, "id": target.id],
                   "expires_at_ms": expiresAtMs, "created_at_ms": Rig.now,
                   "sealed": ["enc": CloudTaskJSON.base64URLEncode(sealed.enc), "ct": CloudTaskJSON.base64URLEncode(sealed.ct)]])
        return FakeJournal.admissionID(deviceID: Rig.deviceID, taskID: taskID)
    }
}

private let credentialExpired = #"{"error":{"code":"credential_expired","message":"expired"},"server_time_ms":1}"#

// MARK: - Tests

final class CloudTaskCoordinatorTests: XCTestCase {
    // MARK: shared `phone` cases

    func testEveryPhoneCaseYieldsExactlyTheListedAck() async throws {
        let cases = try XCTUnwrap(try CloudTaskCases.load()["phone"] as? [[String: Any]])
        var outcomes = Set<String>()
        for item in cases {
            let id = item["id"] as? String ?? ""
            let task = try XCTUnwrap(item["task"] as? [String: Any], id)
            let keyID = task["key_id"] as! String
            let held = CloudTaskKey(keyID: item["has_key"] as! Bool ? keyID : "k-other",
                                    privateScalar: P256.KeyAgreement.PrivateKey().rawRepresentation, createdAtMs: 1)
            let rig = Rig(key: held)
            // The pass time is the cloud's clock; the phone's own clock is deliberately wrong.
            rig.cloud.serverTime.set((item["now"] as! NSNumber).int64Value)
            let expectsExpired = (item["ack"] as? [String: Any])?["state"] as? String == "expired"
            rig.clock.set(expectsExpired ? 0 : Rig.now + 31_536_000_000)
            rig.targetExists.set(item["target_exists"] as! Bool)
            let admissionID = item["admission_id"] as! String
            switch item["admission"] as! String {
            case "admitted": rig.journal.scripted.set(.admitted(admissionID: admissionID))
            case "duplicate": rig.journal.scripted.set(.duplicate(admissionID: admissionID))
            case "invalid": rig.journal.scripted.set(.invalid)
            case "conflict": rig.journal.scripted.set(.conflict)
            case "capacity": rig.journal.scripted.set(.capacity)
            case "storage": rig.journal.scripted.set(.storage)
            default: XCTFail("admission \(item["admission"]!)")
            }
            try rig.submit(task["task_id"] as! String, request: task["request_id"] as? String, keyID: keyID,
                           target: try CloudTaskTarget(json: task["target"]),
                           expiresAtMs: (task["expires_at_ms"] as! NSNumber).int64Value,
                           breakAAD: !(item["opens"] as! Bool))

            let report = await rig.coordinator.run()
            XCTAssertEqual(report.status, .ready, id)
            XCTAssertEqual(report.pulled, 1, id)
            let sent = rig.cloud.acks()
            if let expected = item["ack"] as? [String: Any] {
                var want = expected
                want["task_id"] = task["task_id"]
                XCTAssertEqual(sent.count, 1, id)
                XCTAssertEqual(sent.first.map { $0 as NSDictionary }, want as NSDictionary, id)
                outcomes.insert((expected["reason"] ?? expected["state"]) as! String)
                XCTAssertEqual(rig.cloud.calls("ack").first?.json?["device_id"] as? String, Rig.deviceID, id)
            } else {
                XCTAssertTrue(item["ack"] is NSNull, id)
                XCTAssertEqual(rig.cloud.calls("ack").count, 0, "\(id): no ack, the lease redelivers")
                XCTAssertEqual(report.deferred, 1, id)
                XCTAssertEqual(rig.cloud.state(task["task_id"] as! String), "pending", id)
                outcomes.insert("none")
            }
        }
        XCTAssertEqual(outcomes, ["none", "admitted", "expired", "key_unknown", "decrypt_failed",
                                  "target_missing", "invalid", "conflict"])
    }

    // MARK: admission mapping and ordering

    func testAdmissionRequestCarriesTheOpenedTaskAndTheAckFollowsTheJournalWrite() async throws {
        let rig = Rig()
        let pushAccepted = await rig.coordinator.setPush(CloudTaskPush(
            environment: .production, topic: "com.tono.phonedsh", deviceToken: Data(repeating: 0xAB, count: 32)))
        XCTAssertTrue(pushAccepted)
        let pushRefused = await rig.coordinator.setPush(CloudTaskPush(environment: .production, topic: "a b", token: "zz"))
        XCTAssertFalse(pushRefused)
        _ = await rig.coordinator.setPush(CloudTaskPush(
            environment: .production, topic: "com.tono.phonedsh", deviceToken: Data(repeating: 0xAB, count: 32)))
        let admissionID = try rig.submit("t-1", target: CloudTaskTarget(kind: .bot, id: "bot-7f3a"), text: "浇花")
        let report = await rig.coordinator.run()

        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.admitted, [admissionID])
        XCTAssertEqual(rig.journal.requests.get(), [CloudTaskAdmissionRequest(
            deviceID: Rig.deviceID, taskID: "t-1", target: CloudTaskTarget(kind: .bot, id: "bot-7f3a"),
            text: "浇花", expiresAtMs: Rig.now + 86_400_000)])
        XCTAssertEqual(rig.cloud.state("t-1"), "admitted")
        let events = rig.events.get()
        let admitted = try XCTUnwrap(events.firstIndex(of: "admit-returned:t-1"))
        let acked = try XCTUnwrap(events.firstIndex(of: "request:ack"))
        XCTAssertLessThan(admitted, acked, "the ack is sent only after the journal write returned")

        // Every request: the cloud origin, the bearer token, the contract's routes and bodies.
        let calls = rig.cloud.calls()
        XCTAssertEqual(calls.map(\.route), ["register", "pull", "ack", "pull"])
        for call in calls {
            XCTAssertEqual(call.url.scheme, "https")
            XCTAssertEqual(call.url.host, "pdsh.tonoai.cn")
            XCTAssertNil(call.url.port)
            XCTAssertEqual(call.authorization, "Bearer tok-1")
            if let body = call.json { XCTAssertNoThrow(try CloudTaskWire.validateRequest(body)) }
        }
        XCTAssertEqual(calls[0].url.path, "/v1/phone/devices/\(Rig.deviceID)")
        XCTAssertEqual(calls[1].url.query, "device_id=\(Rig.deviceID)&limit=16&lease_s=300&wait_s=0")
        let registration = try XCTUnwrap(rig.cloud.registration)
        XCTAssertEqual(registration["platform"] as? String, "ios")
        XCTAssertEqual((registration["key"] as? [String: Any])?["key_id"] as? String, "k-1")
        XCTAssertEqual((registration["key"] as? [String: Any])?["public_key"] as? String,
                       CloudTaskJSON.base64URLEncode(rig.key.publicKey!))
        XCTAssertEqual((registration["push"] as? [String: Any])?["token"] as? String, String(repeating: "ab", count: 32))

        // The same process does not register twice; an idle pass is one empty pull.
        let idle = await rig.coordinator.run()
        XCTAssertEqual(idle, CloudTaskPassReport(status: .ready))
        XCTAssertEqual(rig.cloud.calls().map(\.route), ["register", "pull", "ack", "pull", "pull"])
    }

    func testALostAckIsRepairedByRedeliveryAsADuplicateAdmissionWithTheSameAdmissionID() async throws {
        let rig = Rig()
        let admissionID = try rig.submit("t-1")
        rig.cloud.failOnce("ack", .lost)
        let first = await rig.coordinator.run()
        XCTAssertEqual(first.status, .failed(.transport))
        XCTAssertEqual(first.admitted, [], "nothing is reported as acknowledged")
        XCTAssertEqual(rig.cloud.state("t-1"), "pending")
        XCTAssertEqual(rig.journal.records.get().count, 1)

        // Still leased: the next pass gets nothing and sends no ack on its own.
        _ = await rig.coordinator.run()
        XCTAssertEqual(rig.cloud.calls("ack").count, 1)

        rig.cloud.expireLeases()
        let second = await rig.coordinator.run()
        XCTAssertEqual(second.status, .ready)
        XCTAssertEqual(second.admitted, [admissionID])
        XCTAssertEqual(rig.journal.requests.get().count, 2, "redelivered, admitted again")
        XCTAssertEqual(rig.journal.records.get().count, 1, "…as a duplicate: one record")
        let acks = rig.cloud.acks()
        XCTAssertEqual(acks.count, 2)
        XCTAssertEqual(acks[0] as NSDictionary, acks[1] as NSDictionary)
        XCTAssertEqual(acks[1]["admission_id"] as? String, admissionID)
        XCTAssertEqual(rig.cloud.state("t-1"), "admitted")
    }

    func testAnAckWhoseAnswerWasLostNeedsNoRepair() async throws {
        let rig = Rig()
        try rig.submit("t-1")
        rig.cloud.failOnce("ack", .answerLost)
        let first = await rig.coordinator.run()
        XCTAssertEqual(first.status, .failed(.transport))
        XCTAssertEqual(rig.cloud.state("t-1"), "admitted")
        rig.cloud.expireLeases()
        let second = await rig.coordinator.run()
        XCTAssertEqual(second, CloudTaskPassReport(status: .ready))
        XCTAssertEqual(rig.cloud.calls("ack").count, 1)
    }

    func testAPassDrainsTheQueueInBoundedRoundsAndStopsWhenTheJournalIsFull() async throws {
        let rig = Rig(maxRounds: 2)
        for index in 0..<40 { try rig.submit("t-\(index)") }
        let report = await rig.coordinator.run()
        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.pulled, 32, "two rounds of 16")
        XCTAssertEqual(report.admitted.count, 32)
        XCTAssertEqual(rig.cloud.calls("pull").count, 2)
        XCTAssertTrue(rig.cloud.calls("ack").allSatisfy { ($0.json?["acks"] as? [Any])?.count == 16 })

        rig.journal.scripted.set(.capacity)
        let full = await rig.coordinator.run()
        XCTAssertEqual(full.deferred, 8)
        XCTAssertEqual(full.admitted, [])
        XCTAssertEqual(rig.cloud.calls("pull").count, 3, "no further pull while the journal is full")
        XCTAssertEqual(rig.cloud.calls("ack").count, 2)
    }

    // MARK: open answers and the cloud's clock

    func testEveryPullElementCaseGetsItsAckAndNeverBlocksItsNeighbours() async throws {
        let cases = try XCTUnwrap(try CloudTaskCases.load()["pull_elements"] as? [[String: Any]])
        let sealing = try XCTUnwrap(try CloudTaskCases.load()["sealing"] as? [String: Any])
        let vector = try XCTUnwrap((sealing["valid"] as? [[String: Any]])?.first)
        // The well-formed element is the shared `short-cjk` vector: hold its (test-only) key as k-1.
        let key = CloudTaskKey(keyID: "k-1", privateScalar: CloudTaskCases.hex(vector["recipient_private_scalar"] as! String),
                               createdAtMs: 1)
        var kinds = Set<String>()
        for item in cases {
            let id = item["id"] as? String ?? ""
            let rig = Rig(key: key)
            let neighbour = try rig.submit("t-ok")
            let good = try XCTUnwrap(rig.cloud.pullOnce().first, id)
            let body: [String: Any] = ["schema": "phone-task-pull/v1", "server_time_ms": Rig.now,
                                       "tasks": [item["element"]!, good], "cursor": "ignored"]
            rig.cloud.failOnce("pull", .answer(200, String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)))

            let report = await rig.coordinator.run()
            XCTAssertEqual(report.status, .ready, id)
            XCTAssertEqual(report.pulled, 2, id)
            var want: [[String: Any]] = []
            if item["decodes"] as! Bool {
                kinds.insert("ok")
                want.append(["task_id": "t-1", "state": "admitted",
                             "admission_id": FakeJournal.admissionID(deviceID: Rig.deviceID, taskID: "t-1")])
                XCTAssertEqual(rig.journal.requests.get().first?.text, vector["plaintext"] as? String, id)
            } else if let ack = item["ack"] as? [String: Any] {
                kinds.insert("rejected")
                want.append(ack.merging(["task_id": "t-1"]) { $1 })
            } else {
                kinds.insert("skipped")
                XCTAssertEqual(report.deferred, 1, id)
            }
            want.append(["task_id": "t-ok", "state": "admitted", "admission_id": neighbour])
            XCTAssertEqual(rig.cloud.acks() as NSArray, want as NSArray, id)
            XCTAssertEqual(rig.cloud.state("t-ok"), "admitted", id)
        }
        XCTAssertEqual(kinds, ["ok", "rejected", "skipped"])
    }

    func testTheCloudClockJudgesExpiryAndThePhoneClockIsOnlyTheFallback() async throws {
        // The phone's clock is a year ahead: the cloud's time still admits the task.
        let ahead = Rig()
        ahead.clock.set(Rig.now + 31_536_000_000)
        try ahead.submit("t-1")
        let admitted = await ahead.coordinator.run()
        XCTAssertEqual(admitted.admitted.count, 1)

        // The phone's clock is behind: the cloud's time expires the task.
        let behind = Rig()
        behind.clock.set(0)
        behind.cloud.serverTime.set(Rig.now + 86_400_000 - 999)
        try behind.submit("t-1")
        _ = await behind.coordinator.run()
        XCTAssertEqual(behind.cloud.acks() as NSArray, [["task_id": "t-1", "state": "expired"]] as NSArray)

        // An answer without a usable `server_time_ms` falls back to the phone's clock.
        let fallback = Rig()
        fallback.clock.set(Rig.now + 86_400_000)
        try fallback.submit("t-1")
        let good = try XCTUnwrap(fallback.cloud.pullOnce().first)
        let body: [String: Any] = ["schema": "phone-task-pull/v1", "tasks": [good]]
        fallback.cloud.failOnce("pull", .answer(200, String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)))
        _ = await fallback.coordinator.run()
        XCTAssertEqual(fallback.cloud.acks() as NSArray, [["task_id": "t-1", "state": "expired"]] as NSArray)
    }

    // MARK: service and credential answers

    func testA404MeansUnavailableAndIsNotRetried() async throws {
        let rig = Rig()
        try rig.submit("t-1")
        rig.cloud.failAlways("register", .answer(404, #"{"detail":"Not Found"}"#))
        let report = await rig.coordinator.run()
        XCTAssertEqual(report.status, .unavailable)
        XCTAssertEqual(rig.cloud.calls().map(\.route), ["register"], "one request, no retry, no pull")
        XCTAssertEqual(rig.sleeps.get(), [])
        let status = await rig.coordinator.lastReport?.status
        XCTAssertEqual(status, .unavailable)
        // The next trigger asks once more, and only once.
        _ = await rig.coordinator.run(.push)
        XCTAssertEqual(rig.cloud.calls().map(\.route), ["register", "register"])

        // A cloud that forgot the device: unavailable now, registered again on the next trigger.
        rig.cloud.failAlways("register", nil)
        rig.cloud.failOnce("pull", .answer(404, #"{"error":{"code":"not_found","message":"device"},"server_time_ms":1}"#))
        let forgotten = await rig.coordinator.run()
        XCTAssertEqual(forgotten.status, .unavailable)
        XCTAssertEqual(rig.cloud.calls().map(\.route), ["register", "register", "register", "pull"])
        let recovered = await rig.coordinator.run()
        XCTAssertEqual(recovered.status, .ready)
        XCTAssertEqual(recovered.admitted.count, 1)
        XCTAssertEqual(rig.cloud.calls("register").count, 4)
    }

    func testCredentialExpiredIsResentOnceWithTheNewToken() async throws {
        let rig = Rig(tokens: FakeTokens(["tok-1", "tok-2"]))
        rig.cloud.failOnce("register", .answer(401, credentialExpired))
        let report = await rig.coordinator.run()
        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(rig.tokens.invalidated, ["tok-1"])
        let registers = rig.cloud.calls("register")
        XCTAssertEqual(registers.map(\.authorization), ["Bearer tok-1", "Bearer tok-2"])
        XCTAssertEqual(registers[0].body, registers[1].body, "the same method, URL and body")
        XCTAssertEqual(registers[0].url, registers[1].url)

        // A second 401 on the same request is forwarded: at most one re-send.
        let again = Rig(tokens: FakeTokens(["tok-1", "tok-2", "tok-3"]))
        again.cloud.failAlways("register", .answer(401, credentialExpired))
        let failed = await again.coordinator.run()
        XCTAssertEqual(failed.status, .failed(.http(status: 401, code: "credential_expired")))
        XCTAssertEqual(again.cloud.calls().count, 2)

        // An unchanged token is not re-sent; another 401 code is never re-sent.
        let same = Rig(tokens: FakeTokens(["tok-1"]))
        same.cloud.failAlways("register", .answer(401, credentialExpired))
        _ = await same.coordinator.run()
        XCTAssertEqual(same.cloud.calls().count, 1)
        let revoked = Rig(tokens: FakeTokens(["tok-1", "tok-2"]))
        revoked.cloud.failAlways("register", .answer(401, #"{"error":{"code":"credential_revoked","message":"m"},"server_time_ms":1}"#))
        let refused = await revoked.coordinator.run()
        XCTAssertEqual(refused.status, .failed(.http(status: 401, code: "credential_revoked")))
        XCTAssertEqual(revoked.cloud.calls().count, 1)
        XCTAssertEqual(revoked.tokens.invalidated, [])
    }

    func testIdentityUnavailableWaitsRetryAfterAndResendsAtMostTwice() async throws {
        let body = #"{"error":{"code":"identity_unavailable","message":"m"},"server_time_ms":1}"#
        let rig = Rig()
        rig.cloud.failOnce("register", .answer(503, body, ["Retry-After": "3"]))
        let report = await rig.coordinator.run()
        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(rig.sleeps.get(), [3])
        XCTAssertEqual(rig.tokens.invalidated, [])

        let down = Rig()
        down.cloud.failAlways("register", .answer(503, body))
        let failed = await down.coordinator.run()
        XCTAssertEqual(failed.status, .failed(.http(status: 503, code: "identity_unavailable")))
        XCTAssertEqual(down.cloud.calls().count, 3)
        XCTAssertEqual(down.sleeps.get(), [1, 1])
    }

    func testDeviceLimitApiKeyRefusalAndMalformedAnswersAreSurfaced() async throws {
        let limit = Rig()
        limit.cloud.failAlways("register", .answer(409, #"{"error":{"code":"device_limit","message":"m"},"server_time_ms":1}"#))
        let limited = await limit.coordinator.run()
        XCTAssertEqual(limited.status, .deviceLimit)
        XCTAssertEqual(limit.cloud.calls().count, 1)

        let malformed = Rig()
        try malformed.submit("t-1")
        malformed.cloud.failOnce("pull", .answer(200, #"{"schema":"phone-task-pull/v1","server_time_ms":1}"#))
        let closed = await malformed.coordinator.run()
        XCTAssertEqual(closed.status, .failed(.malformedResponse), "`tasks` is a named member")
        XCTAssertEqual(malformed.cloud.calls("ack").count, 0)
        XCTAssertEqual(malformed.journal.requests.get().count, 0)
    }

    // MARK: switch, sign-in state, registration lifetime

    func testWhileOffOrSignedOutNothingIsSent() async throws {
        let off = Rig(enabled: false)
        try off.submit("t-1")
        let disabled = await off.coordinator.run()
        XCTAssertEqual(disabled.status, .disabled)
        let pushed = await off.coordinator.handleRemoteNotification(["pdsh": ["v": 1, "kind": "phone-tasks"]])
        XCTAssertEqual(pushed?.status, .disabled)
        let never = await off.coordinator.setEnabled(false)
        XCTAssertEqual(never.status, .disabled)
        XCTAssertEqual(off.cloud.calls().count, 0, "off: no registration, no pull, nothing to delete")
        XCTAssertFalse(off.coordinator.isEnabled)

        let signedOut = Rig(tokens: FakeTokens(signedIn: false))
        let report = await signedOut.coordinator.run(.signedIn)
        XCTAssertEqual(report.status, .signedOut)
        XCTAssertEqual(signedOut.cloud.calls().count, 0)
    }

    func testTurningOnRegistersAndTurningOffDeletesTheRegistrationAndTheKeys() async throws {
        let rig = Rig(enabled: false)
        try rig.submit("t-1")
        let on = await rig.coordinator.setEnabled(true)
        XCTAssertEqual(on.status, .ready)
        XCTAssertEqual(on.admitted.count, 1)
        XCTAssertTrue(rig.coordinator.isEnabled)
        XCTAssertEqual(rig.defaults.object(forKey: "phone-dsh.cloud-tasks.enabled.v1") as? Bool, true)
        XCTAssertNotNil(rig.cloud.registration)

        let off = await rig.coordinator.setEnabled(false)
        XCTAssertEqual(off.status, .disabled)
        XCTAssertFalse(rig.coordinator.isEnabled)
        let last = try XCTUnwrap(rig.cloud.calls().last)
        XCTAssertEqual(last.method, "DELETE")
        XCTAssertEqual(last.url.path, "/v1/phone/devices/\(Rig.deviceID)")
        XCTAssertNil(rig.cloud.registration)
        XCTAssertEqual(try rig.keys.keys(), [], "no pending task can name the key any more")
        let before = rig.cloud.calls().count
        _ = await rig.coordinator.run()
        _ = await rig.coordinator.run(.push)
        XCTAssertEqual(rig.cloud.calls().count, before, "off again: silent")
    }

    func testAFailedDeleteIsRepeatedOnTheNextTriggerAndKeepsTheKeysUntilConfirmed() async throws {
        let rig = Rig()
        _ = await rig.coordinator.run()
        rig.cloud.failOnce("unregister", .lost)
        let off = await rig.coordinator.setEnabled(false)
        XCTAssertEqual(off.status, .failed(.transport))
        XCTAssertFalse(rig.coordinator.isEnabled)
        XCTAssertEqual(try rig.keys.keys().count, 1)
        let retry = await rig.coordinator.run()
        XCTAssertEqual(retry.status, .disabled)
        XCTAssertEqual(rig.cloud.calls("unregister").count, 2)
        XCTAssertNil(rig.cloud.registration)
        XCTAssertEqual(try rig.keys.keys(), [])
        _ = await rig.coordinator.run()
        XCTAssertEqual(rig.cloud.calls("unregister").count, 2)
        XCTAssertEqual(rig.cloud.calls("pull").count, 1, "only the pass before the switch pulled")
    }

    func testSignOutDeletesTheRegistrationAndTheNextSignInRegistersAFreshKey() async throws {
        let rig = Rig()
        _ = await rig.coordinator.run()
        let confirmed = await rig.coordinator.accountWillSignOut()
        XCTAssertTrue(confirmed)
        XCTAssertEqual(rig.cloud.calls().last?.method, "DELETE")
        XCTAssertTrue(rig.coordinator.isEnabled, "the switch is the user's, not the account's")
        rig.tokens.state.update { $0.signedIn = false }
        let out = await rig.coordinator.run()
        XCTAssertEqual(out.status, .signedOut)
        rig.tokens.state.update { $0.signedIn = true }
        let back = await rig.coordinator.run(.signedIn)
        XCTAssertEqual(back.status, .ready)
        XCTAssertEqual(rig.cloud.calls("register").count, 2)
        let keyID = (rig.cloud.registration?["key"] as? [String: Any])?["key_id"] as? String
        XCTAssertNotEqual(keyID, "k-1")
        XCTAssertEqual(try rig.keys.keys().map(\.keyID), [try XCTUnwrap(keyID)])
    }

    func testARotatedKeyIsRegisteredAndThePreviousKeyGoesOnceTheCloudAcknowledgedIt() async throws {
        let rig = Rig()
        _ = await rig.coordinator.run()
        rig.clock.set(Rig.now + 5)
        try await rig.coordinator.rotateKey()
        XCTAssertEqual(try rig.keys.keys().count, 2, "the previous key is kept until the new one is registered")
        rig.cloud.failOnce("register", .lost)
        _ = await rig.coordinator.run()
        XCTAssertEqual(try rig.keys.keys().count, 2)
        let report = await rig.coordinator.run()
        XCTAssertEqual(report.status, .ready)
        let current = try XCTUnwrap(try rig.keys.currentKey())
        XCTAssertEqual(try rig.keys.keys(), [current])
        XCTAssertNotEqual(current.keyID, "k-1")
        XCTAssertEqual((rig.cloud.registration?["key"] as? [String: Any])?["key_id"] as? String, current.keyID)
    }

    func testALockedKeyStoreAcknowledgesNothing() async throws {
        let rig = Rig()
        try rig.submit("t-1")
        rig.keys.setFailure(.keychain(-25308))
        let locked = await rig.coordinator.run()
        XCTAssertEqual(locked.status, .storeUnavailable)
        XCTAssertEqual(rig.cloud.calls().count, 0)
        rig.keys.setFailure(nil)
        let report = await rig.coordinator.run()
        XCTAssertEqual(report.admitted.count, 1)
    }

    // MARK: triggers

    func testConcurrentTriggersShareOnePass() async throws {
        let rig = Rig()
        try rig.submit("t-1")
        let gate = Gate()
        rig.cloud.pullGate = gate
        let coordinator = rig.coordinator
        let passes = (0..<6).map { index in
            Task { () -> CloudTaskPassReport? in
                if index == 5 { return await coordinator.handleRemoteNotification(["pdsh": ["v": 1, "kind": "phone-tasks"]]) }
                return await coordinator.run(index.isMultiple(of: 2) ? .appActive : .push)
            }
        }
        var waited = 0
        while !rig.events.get().contains("request:pull"), waited < 5_000 {
            try await Task.sleep(nanoseconds: 1_000_000)
            waited += 1
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.release()
        var reports: [CloudTaskPassReport?] = []
        for pass in passes { reports.append(await pass.value) }
        XCTAssertEqual(Set(reports.map { $0?.admitted.count }), [1], "every caller gets the one pass's report")
        XCTAssertEqual(rig.cloud.calls().map(\.route), ["register", "pull", "ack", "pull"])
        XCTAssertEqual(rig.journal.requests.get().count, 1)

        // Afterwards a new trigger is a new pass.
        _ = await coordinator.run()
        XCTAssertEqual(rig.cloud.calls("pull").count, 3)
    }

    func testOnlyATaskPushStartsAPass() async throws {
        let rig = Rig()
        let other = await rig.coordinator.handleRemoteNotification(["aps": ["content-available": 1], "pdsh": ["v": 2, "kind": "phone-tasks"]])
        XCTAssertNil(other)
        let unknownKind = await rig.coordinator.handleRemoteNotification(["pdsh": ["v": 1, "kind": "bot-wake"]])
        XCTAssertNil(unknownKind)
        XCTAssertEqual(rig.cloud.calls().count, 0)
        let constants = try XCTUnwrap(try CloudTaskCases.load()["constants"] as? [String: Any])
        let ours = await rig.coordinator.handleRemoteNotification(try XCTUnwrap(constants["push"] as? [String: Any]))
        XCTAssertEqual(ours?.status, .ready)
        XCTAssertEqual(rig.cloud.calls().map(\.route), ["register", "pull"])
    }

    // MARK: terminal acks

    func testTerminalAcksComeFromRecordStagesAndAreResentUntilTheCloudSettlesThem() async throws {
        let rig = Rig()
        var ids: [String: String] = [:]
        for task in ["t-done", "t-failed", "t-unknown", "t-expired", "t-cancelled", "t-odd"] { ids[task] = try rig.submit(task) }
        let admitted = await rig.coordinator.run()
        XCTAssertEqual(admitted.admitted.count, 6)

        rig.terminal.set([
            CloudTaskTerminalReport(taskID: "t-done", admissionID: ids["t-done"]!, stage: .completed),
            CloudTaskTerminalReport(taskID: "t-failed", admissionID: ids["t-failed"]!, stage: .failed(reason: "retry_exhausted")),
            CloudTaskTerminalReport(taskID: "t-unknown", admissionID: ids["t-unknown"]!, stage: .unknown),
            CloudTaskTerminalReport(taskID: "t-expired", admissionID: ids["t-expired"]!, stage: .expired),
            CloudTaskTerminalReport(taskID: "t-cancelled", admissionID: ids["t-cancelled"]!, stage: .cancelled),
            // §7: any other reason of a `failed` record is `run_failed`.
            CloudTaskTerminalReport(taskID: "t-odd", admissionID: ids["t-odd"]!, stage: .failed(reason: "turn_cancelled")),
        ])
        rig.cloud.failOnce("ack", .lost)
        let lost = await rig.coordinator.run()
        XCTAssertEqual(lost.status, .failed(.transport))
        XCTAssertEqual(lost.terminalSettled, 0)
        XCTAssertEqual(rig.settled.get(), [])

        let before = rig.cloud.calls("ack").count
        let report = await rig.coordinator.run()
        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.terminalSettled, 6)
        XCTAssertEqual(rig.settled.get(), ["t-done", "t-failed", "t-unknown", "t-expired", "t-cancelled", "t-odd"])
        let sent = try XCTUnwrap(rig.cloud.calls("ack").last?.json?["acks"] as? [[String: Any]])
        XCTAssertEqual(sent as NSArray, [
            ["task_id": "t-done", "state": "completed"],
            ["task_id": "t-failed", "state": "failed", "reason": "retry_exhausted"],
            ["task_id": "t-unknown", "state": "unknown"],
            ["task_id": "t-expired", "state": "failed", "reason": "expired"],
            ["task_id": "t-cancelled", "state": "failed", "reason": "cancelled"],
            ["task_id": "t-odd", "state": "failed", "reason": "run_failed"],
        ] as NSArray)
        XCTAssertEqual(rig.cloud.calls("ack").count, before + 1)
        XCTAssertEqual(rig.cloud.state("t-done"), "completed")
        XCTAssertEqual(rig.cloud.state("t-failed"), "failed")
        XCTAssertEqual(rig.cloud.state("t-unknown"), "unknown")
        XCTAssertEqual(rig.cloud.state("t-odd"), "failed")

        // Settled: the journal still lists the records, but nothing is sent again.
        _ = await rig.coordinator.run()
        XCTAssertEqual(rig.cloud.calls("ack").count, before + 1)
    }

    func testATerminalAckForATaskTheCloudStillHoldsPendingRepeatsAdmittedFirst() async throws {
        let rig = Rig()
        let admissionID = try rig.submit("t-1")
        rig.cloud.failOnce("ack", .lost)
        _ = await rig.coordinator.run()
        XCTAssertEqual(rig.cloud.state("t-1"), "pending", "the admitted ack never arrived; the lease still holds")
        // The work finished before any redelivery.
        rig.terminal.set([CloudTaskTerminalReport(taskID: "t-1", admissionID: admissionID, stage: .completed),
                          CloudTaskTerminalReport(taskID: "t-gone", admissionID: admissionID, stage: .completed)])
        let report = await rig.coordinator.run()
        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.terminalSettled, 2, "t-1 completed; t-gone is not_found and final")
        XCTAssertEqual(rig.cloud.state("t-1"), "completed")
        let batches = rig.cloud.calls("ack").suffix(2).compactMap { $0.json?["acks"] as? [[String: Any]] }
        XCTAssertEqual(batches[0] as NSArray, [["task_id": "t-1", "state": "completed"],
                                               ["task_id": "t-gone", "state": "completed"]] as NSArray)
        XCTAssertEqual(batches[1] as NSArray, [["task_id": "t-1", "state": "admitted", "admission_id": admissionID],
                                               ["task_id": "t-1", "state": "completed"]] as NSArray)
        XCTAssertEqual(rig.journal.requests.get().count, 1, "no second admission")
    }
}

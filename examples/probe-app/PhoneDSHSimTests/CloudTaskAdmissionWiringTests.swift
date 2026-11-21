// SPDX-License-Identifier: MIT
// Phone task queue → external admission journal (spec/v1/cloud-tasks.md §7,
// spec/host/v1/external-admission.md). The REAL `CloudTaskCoordinator` and the
// REAL on-disk `ExternalAdmissionJournal` run through the app's own
// `CloudTaskAdmissionBridge` against an in-memory cloud. The tasks it serves
// are the shared sealing vectors (spec/v1/golden/cloud-tasks/cases.json),
// opened with the vectors' test-only key. Nothing here contacts
// pdsh.tonoai.cn, the Keychain or an engine.

import Foundation
import PhoneDSH
import ProbeKit
import XCTest

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Value) { lock.lock(); defer { lock.unlock() }; value = new }
    func update<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

private final class FakeAccount: TonoAccessTokenSource, @unchecked Sendable {
    let userID = Box<String?>("user-1")
    func accessToken() async throws -> String? { userID.get() == nil ? nil : "tok-1" }
    func invalidate(accessToken: String) async {}
    var hasSession: Bool { userID.get() != nil }
}

/// Registration, pull with leases and the §6 ack state machine, in memory.
private final class FakeCloud: CloudTaskTransport, @unchecked Sendable {
    struct Entry {
        var task: [String: Any]
        var state = "pending"
        var admissionID: String?
        var leased = false
    }

    static let now: Int64 = 1_794_700_000_000
    private let lock = NSLock()
    private var order: [String] = []
    private var entries: [String: Entry] = [:]
    private(set) var registered = false
    private(set) var routes: [String] = []
    private(set) var ackBodies: [[String: Any]] = []

    func add(_ task: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let id = task["task_id"] as! String
        order.append(id)
        entries[id] = Entry(task: task)
    }

    func expireLeases() {
        lock.lock(); defer { lock.unlock() }
        for id in order { entries[id]?.leased = false }
    }

    func state(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return entries[id]?.state }
    func admissionID(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return entries[id]?.admissionID }
    func isRegistered() -> Bool { lock.lock(); defer { lock.unlock() }; return registered }
    func calls() -> [String] { lock.lock(); defer { lock.unlock() }; return routes }
    func acks() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return ackBodies }

    private func json(_ status: Int, _ object: [String: Any]) -> TonoAccountProtocol.Answer {
        var object = object
        object["server_time_ms"] = Self.now
        return TonoAccountProtocol.Answer(status: status, headers: [:],
                                          body: try! JSONSerialization.data(withJSONObject: object))
    }

    func send(_ request: URLRequest) async throws -> TonoAccountProtocol.Answer {
        lock.lock(); defer { lock.unlock() }
        let url = request.url!
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        switch (request.httpMethod ?? "GET", url.path) {
        case ("PUT", let path) where path.hasPrefix("/v1/phone/devices/"):
            routes.append("register")
            registered = true
            return json(200, ["schema": "phone-device-ack/v1", "device_id": url.lastPathComponent,
                              "key_id": ((body?["key"] as? [String: Any])?["key_id"] as? String) ?? ""])
        case ("DELETE", let path) where path.hasPrefix("/v1/phone/devices/"):
            routes.append("unregister")
            registered = false
            for id in order where entries[id]?.state == "pending" { entries[id]?.state = "cancelled" }
            return TonoAccountProtocol.Answer(status: 204, headers: [:], body: Data())
        case ("GET", "/v1/phone/tasks/pull"):
            routes.append("pull")
            var tasks: [[String: Any]] = []
            for id in order where tasks.count < 16 {
                guard var entry = entries[id], entry.state == "pending", !entry.leased else { continue }
                entry.leased = true
                entries[id] = entry
                var task = entry.task
                task["lease"] = ["lease_id": "l-\(id)", "attempt": 1, "expires_at_ms": Self.now + 300_000]
                tasks.append(task)
            }
            return json(200, ["schema": "phone-task-pull/v1", "tasks": tasks])
        case ("POST", "/v1/phone/tasks/ack"):
            routes.append("ack")
            let acks = (body?["acks"] as? [[String: Any]]) ?? []
            ackBodies.append(contentsOf: acks)
            let results = acks.map { ack -> [String: Any] in
                let id = ack["task_id"] as? String ?? ""
                guard var entry = entries[id], registered else {
                    return ["task_id": id, "accepted": false, "duplicate": false, "state": "not_found"]
                }
                let (accepted, duplicate) = Self.apply(&entry, ack)
                entries[id] = entry
                return ["task_id": id, "accepted": accepted, "duplicate": duplicate, "state": entry.state]
            }
            return json(200, ["schema": "phone-task-ack-result/v1", "results": results])
        default:
            routes.append("other")
            return json(404, ["error": ["code": "not_found", "message": "no route"]])
        }
    }

    /// The reference oracle's `apply_ack` (spec/v1/tools/test_cloud_tasks.py).
    private static func apply(_ entry: inout Entry, _ ack: [String: Any]) -> (Bool, Bool) {
        let want = ack["state"] as? String ?? ""
        switch entry.state {
        case "pending":
            guard ["admitted", "rejected", "expired"].contains(want) else { return (false, false) }
            entry.state = want
            entry.admissionID = ack["admission_id"] as? String
            return (true, false)
        case "admitted":
            if want == "admitted" {
                let same = ack["admission_id"] as? String == entry.admissionID
                return (same, same)
            }
            guard ["completed", "failed", "unknown"].contains(want) else { return (false, false) }
            entry.state = want
            return (true, false)
        default:
            return want == entry.state ? (true, true) : (false, false)
        }
    }
}

final class CloudTaskAdmissionWiringTests: XCTestCase {
    private static let deviceID = "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a"
    private static let now = FakeCloud.now

    private var root: URL!
    private var suite = ""
    private var defaults: UserDefaults!
    private var cloud: FakeCloud!
    private var account: FakeAccount!
    private var keys: InMemoryCloudTaskKeyStore!
    private var journal: ExternalAdmissionJournal!
    private var bridge: CloudTaskAdmissionBridge!
    private var coordinator: CloudTaskCoordinator!
    private let presence = Box<[String: CloudTaskTargetPresence]>([:])
    /// `sealing.valid` vectors by id.
    private var vectors: [String: [String: Any]] = [:]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-cloud-task-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "cloud-task-wiring-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.set(Self.deviceID, forKey: CloudTasks.deviceIDPreferenceKey)
        defaults.set(true, forKey: CloudTasks.enabledPreferenceKey)

        let casesURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/v1/golden/cloud-tasks/cases.json")
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as? [String: Any])
        XCTAssertEqual(cases["revision"] as? String, CloudTasks.revision)
        let valid = try XCTUnwrap((cases["sealing"] as? [String: Any])?["valid"] as? [[String: Any]])
        for vector in valid { vectors[vector["id"] as! String] = vector }
        // The first two vectors share one (test-only) recipient key: hold it as `k-1`.
        let scalar = Self.hex(try XCTUnwrap(vectors["short-cjk"]?["recipient_private_scalar"] as? String))
        XCTAssertEqual(vectors["one-byte"]?["recipient_private_scalar"] as? String,
                       vectors["short-cjk"]?["recipient_private_scalar"] as? String)

        cloud = FakeCloud()
        account = FakeAccount()
        keys = InMemoryCloudTaskKeyStore([CloudTaskKey(keyID: "k-1", privateScalar: scalar, createdAtMs: 1)])
        presence.set(["s:gb-main": .present, "b:bot-7f3a": .present])
        makeStack()
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suite)
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A new journal actor and coordinator on the same directory and preferences: a relaunch.
    private func makeStack() {
        let account = self.account!, presence = self.presence
        journal = ExternalAdmissionJournal(directory: root.appendingPathComponent("admissions", isDirectory: true))
        bridge = CloudTaskAdmissionBridge(
            journal: journal,
            signedInUserID: { account.userID.get() },
            presence: { target in
                switch target {
                case .dshSession(let id): return presence.get()["s:" + id] ?? .absent
                case .bot(let id): return presence.get()["b:" + id] ?? .absent
                }
            },
            now: { Self.now })
        coordinator = CloudTaskCoordinator(
            configuration: .init(appVersion: "1.4.0", now: { Self.now }),
            host: bridge.host(), tokens: account, transport: cloud, keyStore: keys,
            defaults: defaults, sleep: { _ in })
    }

    /// Queues the shared vector `id` under `taskID`. The task id is not part of
    /// the §3 AAD, so one vector can be served as several tasks.
    private func submit(_ taskID: String, vector id: String = "short-cjk") throws {
        let vector = try XCTUnwrap(vectors[id])
        let aad = (vector["aad"] as! String).components(separatedBy: "\n")
        XCTAssertEqual(aad[1], Self.deviceID)
        cloud.add(["task_id": taskID, "request_id": aad[3], "key_id": aad[2],
                   "target": ["kind": aad[4], "id": aad[5]],
                   "expires_at_ms": try XCTUnwrap(Int64(aad[6])), "created_at_ms": Self.now,
                   "sealed": vector["sealed"]!])
    }

    private func expectedAdmissionID(_ taskID: String, user: String = "user-1") -> String {
        ExternalAdmissionPolicy.admissionId(
            principal: "account:" + user,
            source: ExternalAdmissionSource(kind: .cloudTask, id: Self.deviceID),
            sourceRequestId: taskID)
    }

    private func records() async -> [ExternalAdmissionRecord] {
        await journal.allRecords(nowMs: Self.now)
    }

    // MARK: - Admission

    func testAPulledTaskIsAdmittedWithTheContractIdentityAndAckedWithTheJournalsAdmissionID() async throws {
        try submit("t-1")
        try submit("t-bot", vector: "one-byte")
        let report = await coordinator.run(.appActive)

        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.pulled, 2)
        let stored = await records()
        XCTAssertEqual(stored.count, 2)
        let session = try XCTUnwrap(stored.first { $0.sourceRequestId == "t-1" })
        XCTAssertEqual(session.principal, "account:user-1")
        XCTAssertEqual(session.source, ExternalAdmissionSource(kind: .cloudTask, id: Self.deviceID))
        XCTAssertEqual(session.target, .dshSession(sessionId: "gb-main"))
        XCTAssertEqual(session.text, vectors["short-cjk"]?["plaintext"] as? String)
        XCTAssertEqual(session.expiresAtMs, 1_794_786_400_000)
        XCTAssertEqual(session.stage, .admitted)
        XCTAssertEqual(session.admissionId, expectedAdmissionID("t-1"))
        XCTAssertNil(session.validationProblem(), "the downstream id is a lowercase UUIDv4")
        let bot = try XCTUnwrap(stored.first { $0.sourceRequestId == "t-bot" })
        XCTAssertEqual(bot.target, .bot(botId: "bot-7f3a"))
        XCTAssertEqual(bot.text, "a")
        XCTAssertNotEqual(bot.downstreamId, session.downstreamId, "a fresh downstream id per admission")

        // The ack carries the journal's own admission id, and the app's dispatch entry is told.
        XCTAssertEqual(report.admitted, [session.admissionId, bot.admissionId])
        XCTAssertEqual(cloud.acks() as NSArray, [
            ["task_id": "t-1", "state": "admitted", "admission_id": session.admissionId],
            ["task_id": "t-bot", "state": "admitted", "admission_id": bot.admissionId],
        ] as NSArray)
        XCTAssertEqual(cloud.state("t-1"), "admitted")

        // A record survives a relaunch: it is in the journal's files, not in memory.
        makeStack()
        let reopened = await records()
        XCTAssertEqual(reopened.map(\.admissionId).sorted(), stored.map(\.admissionId).sorted())
    }

    func testARedeliveredTaskIsADuplicateWithTheSameAdmissionIDAndOneRecord() async throws {
        try submit("t-1")
        _ = await coordinator.run(.appActive)
        let before = await records()
        let first = try XCTUnwrap(before.first)

        // The cloud never saw the ack (modelled by the task still pending) and redelivers.
        let again = FakeCloud()
        cloud = again
        try submit("t-1")
        makeStack()
        let report = await coordinator.run(.push)

        XCTAssertEqual(report.admitted, [first.admissionId])
        let stored = await records()
        XCTAssertEqual(stored.count, 1, "a duplicate writes nothing")
        XCTAssertEqual(stored.first?.downstreamId, first.downstreamId, "the first downstream id is kept")
        XCTAssertEqual(again.acks() as NSArray,
                       [["task_id": "t-1", "state": "admitted", "admission_id": first.admissionId]] as NSArray)
        XCTAssertEqual(again.admissionID("t-1"), first.admissionId)
    }

    func testAFullJournalAcknowledgesNothingAndTheTaskStaysWithTheCloud() async throws {
        // 256 pending records of the local principal fill the journal.
        for index in 0..<ExternalAdmissionLimits.maxPending {
            let outcome = await journal.admit(
                .tonoLinkVoice(boardName: "board", requestID: UUID().uuidString.lowercased(),
                               target: .dshSession(sessionId: "gb-main"), text: "t\(index)", nowMs: Self.now),
                nowMs: Self.now)
            XCTAssertEqual(outcome.result, .admitted)
        }
        try submit("t-1")
        let report = await coordinator.run(.appActive)

        XCTAssertEqual(report.status, .ready)
        XCTAssertEqual(report.deferred, 1)
        XCTAssertEqual(report.admitted, [])
        XCTAssertFalse(cloud.calls().contains("ack"), "capacity is not acknowledged")
        XCTAssertEqual(cloud.state("t-1"), "pending")
        let stored = await records()
        XCTAssertFalse(stored.contains { $0.source.kind == .cloudTask })
    }

    func testAnUnknownTargetIsRejectedAsTargetMissingAndNeverReachesTheJournal() async throws {
        presence.set(["b:bot-7f3a": .present])
        try submit("t-1")
        let report = await coordinator.run(.appActive)

        XCTAssertEqual(report.refused, 1)
        XCTAssertEqual(cloud.acks() as NSArray,
                       [["task_id": "t-1", "state": "rejected", "reason": "target_missing"]] as NSArray)
        let stored = await records()
        XCTAssertTrue(stored.isEmpty)
    }

    func testATargetThatCannotBeJudgedNowIsNeitherAdmittedNorAcknowledged() async throws {
        presence.set(["s:gb-main": .unknown])
        try submit("t-1")
        let report = await coordinator.run(.appActive)

        XCTAssertEqual(report.deferred, 1)
        XCTAssertFalse(cloud.calls().contains("ack"), "\"cannot tell\" is not \"missing\"")
        XCTAssertEqual(cloud.state("t-1"), "pending")
        let none = await records()
        XCTAssertTrue(none.isEmpty)

        // Once the app can answer, the redelivered task is admitted.
        presence.set(["s:gb-main": .present])
        cloud.expireLeases()
        let later = await coordinator.run(.appActive)
        XCTAssertEqual(later.admitted, [expectedAdmissionID("t-1")])
    }

    func testWithoutASignedInUserIDNothingIsAdmittedAndNothingIsAcknowledged() async throws {
        // A session exists but its record carries no user id: there is no principal.
        let tokens = TokensWithoutUserID()
        bridge = CloudTaskAdmissionBridge(journal: journal, signedInUserID: { nil },
                                          presence: { _ in .absent }, now: { Self.now })
        coordinator = CloudTaskCoordinator(
            configuration: .init(appVersion: "1.4.0", now: { Self.now }),
            host: bridge.host(), tokens: tokens, transport: cloud, keyStore: keys,
            defaults: defaults, sleep: { _ in })
        try submit("t-1")
        let report = await coordinator.run(.appActive)

        XCTAssertEqual(report.deferred, 1)
        XCTAssertFalse(cloud.calls().contains("ack"))
        let stored = await records()
        XCTAssertTrue(stored.isEmpty)
        // A user id that cannot be a principal is no principal either.
        XCTAssertNil(ExternalAdmissionRequest.accountPrincipal(userID: "a b"))
        XCTAssertNil(ExternalAdmissionRequest.accountPrincipal(userID: ""))
        XCTAssertEqual(ExternalAdmissionRequest.accountPrincipal(userID: "user-1"), "account:user-1")
    }

    // MARK: - Terminal acks

    func testATerminalRecordProducesTheRightTerminalAckAndStaysTheJournalsTombstone() async throws {
        try submit("t-done")
        try submit("t-failed")
        try submit("t-expired")
        _ = await coordinator.run(.appActive)
        let done = expectedAdmissionID("t-done"), failed = expectedAdmissionID("t-failed")

        // The downstream owner's outcomes, written through the journal's own transitions.
        _ = try await journal.beginDispatch(done, nowMs: Self.now)
        try await journal.markLinked(done, nowMs: Self.now)
        try await journal.complete(done, nowMs: Self.now)
        try await journal.fail(failed, reason: "target_missing", nowMs: Self.now)
        try await journal.transition(expectedAdmissionID("t-expired"), to: .expired, nowMs: Self.now)
        // A voice record that failed is not a cloud task and is never reported.
        let voice = await journal.admit(
            .tonoLinkVoice(boardName: "board", requestID: UUID().uuidString.lowercased(),
                           target: .dshSession(sessionId: "gb-main"), text: "hi", nowMs: Self.now),
            nowMs: Self.now)
        try await journal.fail(try XCTUnwrap(voice.receipt).admissionId, reason: "target_missing", nowMs: Self.now)

        let report = await coordinator.run(.appActive)
        XCTAssertEqual(report.terminalSettled, 3)
        XCTAssertEqual(cloud.state("t-done"), "completed")
        XCTAssertEqual(cloud.state("t-failed"), "failed")
        XCTAssertEqual(cloud.state("t-expired"), "failed")
        let terminal = cloud.acks().filter { ($0["state"] as? String) != "admitted" }
        XCTAssertEqual(Set(terminal.map { $0 as NSDictionary }), Set([
            ["task_id": "t-done", "state": "completed"],
            ["task_id": "t-failed", "state": "failed", "reason": "target_missing"],
            ["task_id": "t-expired", "state": "failed", "reason": "expired"],
        ] as [NSDictionary]))

        // Settled in this process: not sent again.
        let count = cloud.acks().count
        _ = await coordinator.run(.appActive)
        XCTAssertEqual(cloud.acks().count, count)

        // No "settled" marker is persisted: after a relaunch the journal's
        // tombstones are offered once more and the cloud answers `duplicate`.
        makeStack()
        let relaunched = await coordinator.run(.appActive)
        XCTAssertEqual(relaunched.terminalSettled, 3)
        XCTAssertEqual(cloud.acks().count, count + 3)
        XCTAssertEqual(cloud.state("t-done"), "completed")

        // Another account never sees these task ids.
        account.userID.set("user-2")
        let other = await bridge.terminalReports(deviceID: Self.deviceID)
        XCTAssertTrue(other.isEmpty)
    }

    // MARK: - Sign-out

    func testSignOutDeletesTheRegistrationAndCancelsThatAccountsAdmittedRecords() async throws {
        try submit("t-1")
        try submit("t-linked", vector: "one-byte")
        _ = await coordinator.run(.appActive)
        XCTAssertTrue(cloud.isRegistered())
        let linked = expectedAdmissionID("t-linked")
        _ = try await journal.beginDispatch(linked, nowMs: Self.now)
        try await journal.markLinked(linked, nowMs: Self.now)
        let voice = await journal.admit(
            .tonoLinkVoice(boardName: "board", requestID: UUID().uuidString.lowercased(),
                           target: .dshSession(sessionId: "gb-main"), text: "hi", nowMs: Self.now),
            nowMs: Self.now)

        // The app's order: the cloud forgets the phone while the token works, then the
        // session is cleared, then that account's admitted records are cancelled.
        let confirmed = await coordinator.accountWillSignOut()
        XCTAssertTrue(confirmed)
        XCTAssertEqual(cloud.calls().last, "unregister")
        XCTAssertFalse(cloud.isRegistered())
        account.userID.set(nil)
        let cancelled = await bridge.cancelAdmissionsOfSignedOutAccounts()

        XCTAssertEqual(cancelled.map(\.sourceRequestId), ["t-1"])
        let stored = await records()
        let record = try XCTUnwrap(stored.first { $0.sourceRequestId == "t-1" })
        XCTAssertEqual(record.stage, .cancelled)
        XCTAssertEqual(record.reason, "account_signed_out")
        XCTAssertNil(record.text, "the text leaves with the pending stage")
        XCTAssertEqual(stored.first { $0.sourceRequestId == "t-linked" }?.stage, .linked,
                       "a handed-over record belongs to its downstream owner")
        XCTAssertEqual(stored.first { $0.admissionId == voice.receipt?.admissionId }?.stage, .admitted,
                       "the local principal is not an account")

        // Signed out: nothing is sent, nothing is offered.
        let calls = cloud.calls().count
        let out = await coordinator.run(.appActive)
        XCTAssertEqual(out.status, .signedOut)
        XCTAssertEqual(cloud.calls().count, calls)

        // The same account signs in again: the cancelled record is reported `failed` / `cancelled`.
        account.userID.set("user-1")
        let back = await coordinator.run(.signedIn)
        XCTAssertEqual(back.status, .ready)
        XCTAssertTrue(cloud.isRegistered())
        XCTAssertTrue(cloud.acks().contains {
            ($0 as NSDictionary) == ["task_id": "t-1", "state": "failed", "reason": "cancelled"] as NSDictionary
        })
        XCTAssertEqual(cloud.state("t-1"), "failed")
    }

    func testAnAccountRecordIsDispatchableOnlyWhileItsAccountIsSignedIn() async throws {
        try submit("t-1")
        _ = await coordinator.run(.appActive)
        let pending = await journal.sweptPendingRecords(nowMs: Self.now)
        let record = try XCTUnwrap(pending.first)

        XCTAssertFalse(ExternalAdmissionPolicy.isWaitingForAccount(record, signedInPrincipal: "account:user-1"))
        XCTAssertTrue(ExternalAdmissionPolicy.isWaitingForAccount(record, signedInPrincipal: "account:user-2"))
        XCTAssertTrue(ExternalAdmissionPolicy.isWaitingForAccount(record, signedInPrincipal: nil))
        func order(_ principal: String?) -> [String] {
            ExternalAdmissionPolicy.dispatchOrder(pending, nowMs: Self.now) {
                ExternalAdmissionPolicy.isWaitingForAccount($0, signedInPrincipal: principal)
            }.map(\.admissionId)
        }
        XCTAssertEqual(order("account:user-1"), [record.admissionId])
        XCTAssertEqual(order(nil), [], "a waiting record is skipped, and changes nothing in the record")

        // Another account signing in cancels it; the same account keeps it.
        let kept = await journal.cancelAccountAdmissions(exceptPrincipal: "account:user-1", nowMs: Self.now)
        XCTAssertTrue(kept.isEmpty)
        let gone = await journal.cancelAccountAdmissions(exceptPrincipal: "account:user-2", nowMs: Self.now)
        XCTAssertEqual(gone.map(\.stage), [.cancelled])
    }

    // MARK: - Status words

    func testTheStatusLineSaysWhatIsHappeningInPlainWords() {
        XCTAssertEqual(CloudTaskStatusText.describe(enabled: false, signedIn: true, status: .ready), "未开启")
        XCTAssertTrue(CloudTaskStatusText.describe(enabled: true, signedIn: false, status: nil).hasPrefix("未登录"))
        XCTAssertEqual(CloudTaskStatusText.describe(enabled: true, signedIn: true, status: .ready), "已开启")
        XCTAssertTrue(CloudTaskStatusText.describe(enabled: true, signedIn: true, status: .unavailable).hasPrefix("暂不可用"))
        XCTAssertTrue(CloudTaskStatusText.describe(enabled: true, signedIn: true, status: .deviceLimit).hasPrefix("设备数已满"))
        XCTAssertTrue(CloudTaskStatusText.describe(enabled: true, signedIn: true, status: .signedOut).hasPrefix("未登录"))
    }

    private static func hex(_ text: String) -> Data {
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

/// Signed in (a token is available) while the session record names no user.
private final class TokensWithoutUserID: TonoAccessTokenSource, @unchecked Sendable {
    func accessToken() async throws -> String? { "tok-1" }
    func invalidate(accessToken: String) async {}
    var hasSession: Bool { true }
}

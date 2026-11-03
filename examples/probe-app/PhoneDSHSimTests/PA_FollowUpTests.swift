// SPDX-License-Identifier: MIT

import ProbeKit
import XCTest

final class PA_FollowUpTests: XCTestCase {
    func testCrossOpenOnlyNewChangesNotifyAndVerificationTimeIsDistinct() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-FollowUp-\(UUID().uuidString)/domain.sqlite")
        let checker = PA_FollowUpChecker()
        let sender = PA_NotificationSender()
        let router = NotificationRouter(sender: sender)
        let id = UUID()
        let firstVerified = Date(timeIntervalSince1970: 1_000)
        let secondVerified = Date(timeIntervalSince1970: 2_000)
        checker.results = [
            FollowUpCheckResult(changed: true, summary: "PR 出现新阻塞", cursor: "c1",
                                needsAttention: true, lastVerifiedAt: firstVerified),
            FollowUpCheckResult(changed: false, cursor: "c1", lastVerifiedAt: secondVerified),
            FollowUpCheckResult(changed: true, summary: "重复游标", cursor: "c1",
                                needsAttention: true, lastVerifiedAt: secondVerified),
        ]
        do {
            let domain = try SQLiteDomainStore(fileURL: url)
            let store = FollowUpStore(domain: domain)
            try await store.prepare()
            _ = try await store.create(followUp(id: id))
            let coordinator = FollowUpCoordinator(store: store, checkers: [checker], notifier: router)
            let first = try await coordinator.checkAll(now: Date(timeIntervalSince1970: 1_100))
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(first[0].notification?.verifiedAt, firstVerified)
        }

        let store = FollowUpStore(domain: try SQLiteDomainStore(fileURL: url))
        let persisted = try await store.record(id)
        XCTAssertEqual(persisted?.cursor, "c1")
        let coordinator = FollowUpCoordinator(store: store, checkers: [checker], notifier: router)
        let second = try await coordinator.checkAll(now: Date(timeIntervalSince1970: 2_100))
        XCTAssertNil(second[0].notification)
        XCTAssertEqual(second[0].record.followUp.lastVerifiedAt, secondVerified)
        XCTAssertEqual(second[0].record.lastNotificationAt, Date(timeIntervalSince1970: 1_100))
        let repeated = try await coordinator.checkAll(now: Date(timeIntervalSince1970: 2_200))
        XCTAssertNil(repeated[0].notification)
        let sent = sender.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(NotificationRouter.route(forDeepLink: sent[0].deepLink), .chat(focus: .followUp(id)))
    }

    func testPauseUntilFridaySkipsForegroundChecksAndEndPersists() async throws {
        let domain = try SQLiteDomainStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-FollowUpPause-\(UUID().uuidString)/domain.sqlite"))
        let store = FollowUpStore(domain: domain)
        try await store.prepare()
        let checker = PA_FollowUpChecker()
        checker.results = [FollowUpCheckResult(changed: false)]
        let router = NotificationRouter(sender: PA_NotificationSender())
        let record = try await store.create(followUp())
        let now = Date(timeIntervalSince1970: 10_000)
        let paused = try await store.pause(record.id, until: now.addingTimeInterval(3_600), now: now)
        XCTAssertEqual(paused.followUp.pausedUntil, now.addingTimeInterval(3_600))
        let coordinator = FollowUpCoordinator(store: store, checkers: [checker], notifier: router)
        let skipped = try await coordinator.checkAll(now: now)
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertEqual(checker.callCount, 0)
        _ = try await coordinator.checkAll(now: now.addingTimeInterval(3_601))
        XCTAssertEqual(checker.callCount, 1)
        try await store.end(record.id)
        let active = try await store.records()
        let all = try await store.records(includeEnded: true)
        XCTAssertTrue(active.isEmpty)
        XCTAssertNotNil(all.first?.endedAt)
    }

    private func followUp(id: UUID = UUID()) -> FollowUp {
        FollowUp(id: id, goal: "跟进这个 PR，有新阻塞再告诉我",
                 target: FollowUpTarget(kind: .githubPR, repository: "example/repo", number: 42),
                 waitingReason: "等待新 review", nextCheckCondition: CheckCondition(expression: "new blockers"),
                 stopCondition: StopCondition(expression: "merged"), notificationPolicy: .changesOnly)
    }
}

private final class PA_FollowUpChecker: FollowUpChecker, @unchecked Sendable {
    let targetKind: FollowUpTarget.Kind = .githubPR
    private let lock = NSLock()
    private var index = 0
    private var calls = 0
    var results: [FollowUpCheckResult] = []
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func check(_ followUp: FollowUp, since cursor: String?) async -> FollowUpCheckResult {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        let result = results[min(index, max(0, results.count - 1))]
        index += 1
        return result
    }
}

private final class PA_NotificationSender: LocalNotificationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LocalNotificationRequest] = []
    var requests: [LocalNotificationRequest] { lock.lock(); defer { lock.unlock() }; return storage }
    func send(_ request: LocalNotificationRequest) async throws {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

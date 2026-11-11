// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private actor FakeApprovalNotificationScheduling: BotApprovalNotificationScheduling {
    private var pending: [String: BotApprovalScheduledNotification] = [:]
    private(set) var cancelled: [String] = []
    private(set) var scheduleCalls = 0

    func schedule(_ notification: BotApprovalScheduledNotification) async throws {
        scheduleCalls += 1
        pending[notification.identifier] = notification
    }

    func pendingIdentifiers(prefix: String) async -> [String] {
        pending.keys.filter { $0.hasPrefix(prefix) }
    }

    func cancel(identifiers: [String]) async {
        cancelled.append(contentsOf: identifiers)
        for id in identifiers { pending.removeValue(forKey: id) }
    }

    func pendingSnapshot() -> [String: BotApprovalScheduledNotification] { pending }
}

final class BotApprovalNotificationTests: XCTestCase {
    private func record(_ id: String, requestedAt: Int64 = 1_000) -> BotApprovalNotificationRecord {
        BotApprovalNotificationRecord(
            approvalID: id, botID: "main", action: "Forget a memory",
            detail: "remove a fact", command: "rm -f /tmp/x",
            requestedAt: requestedAt, expiresAt: requestedAt + 86_400_000)
    }

    func testPlannerUsesStableIdentifierAndTheApprovalRowDeepLink() {
        let notification = BotApprovalNotificationPlanner.notification(
            for: record("approval-1"), now: 5_000, delayMs: 60_000)
        XCTAssertEqual(notification.identifier, "approval-pending:main:approval-1")
        XCTAssertEqual(notification.fireAt, 65_000)
        XCTAssertEqual(BotApprovalScheduledNotification.rowID(
            botID: "main", approvalID: "approval-1"),
            "e-main-approval-approval-1")
        XCTAssertEqual(notification.deepLink,
                       "phonedsh://bot/main/row/e-main-approval-approval-1")
        XCTAssertTrue(notification.body.contains("Forget a memory"))
    }

    func testReconcilerSchedulesOnceAndCancelsADecidedApproval() async {
        let fake = FakeApprovalNotificationScheduling()
        let reconciler = BotApprovalNotificationReconciler(
            scheduling: fake, now: { 5_000 }, delayMs: 60_000)
        let first = await reconciler.sync([record("a1"), record("a2")])
        XCTAssertEqual(first, 2)
        let second = await reconciler.sync([record("a1"), record("a2")])
        XCTAssertEqual(second, 0)
        let pending = await fake.pendingSnapshot()
        XCTAssertEqual(Set(pending.keys), [
            "approval-pending:main:a1", "approval-pending:main:a2",
        ])

        let third = await reconciler.sync([record("a2")])
        XCTAssertEqual(third, 0)
        let cancelled = await fake.cancelled
        XCTAssertEqual(cancelled, ["approval-pending:main:a1"])
        let remaining = await fake.pendingSnapshot()
        XCTAssertEqual(Set(remaining.keys), ["approval-pending:main:a2"])
    }

    func testReconcilerReRegistersAfterASystemPurgeOrRestart() async {
        let fake = FakeApprovalNotificationScheduling()
        let firstRun = BotApprovalNotificationReconciler(
            scheduling: fake, now: { 5_000 }, delayMs: 0)
        _ = await firstRun.sync([record("restored")])
        // Simulate the process disappearing: a fresh reconciler has no local
        // cache, but the system still holds the identifier and must not be
        // duplicated.
        let secondRun = BotApprovalNotificationReconciler(
            scheduling: fake, now: { 5_000 }, delayMs: 0)
        let registered = await secondRun.sync([record("restored")])
        XCTAssertEqual(registered, 0)
        let pending = await fake.pendingSnapshot()
        XCTAssertEqual(pending.count, 1)

        // After a system purge the same durable todo is re-registered.
        await fake.cancel(identifiers: Array(pending.keys))
        let thirdRun = BotApprovalNotificationReconciler(
            scheduling: fake, now: { 5_000 }, delayMs: 0)
        let again = await thirdRun.sync([record("restored")])
        XCTAssertEqual(again, 1)
    }

    func testPlannerCapsTheSystemQueue() {
        let records = (0..<80).map { record("approval-\($0)") }
        let desired = BotApprovalNotificationPlanner.desired(
            records: records, now: 5_000, delayMs: 0)
        XCTAssertEqual(desired.count,
                       BotApprovalNotificationPlanner.maximumPendingNotifications)
        XCTAssertEqual(desired.first?.identifier, "approval-pending:main:approval-0")
    }
}

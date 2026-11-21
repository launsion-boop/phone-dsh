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

private actor FakeAuthorizingScheduling: BotApprovalNotificationScheduling, BotApprovalNotificationAuthorizing {
    private var pending: [String: BotApprovalScheduledNotification] = [:]
    private var state: BotNotificationAuthorizationState
    private(set) var requestCalls = 0

    init(state: BotNotificationAuthorizationState = .notDetermined) { self.state = state }

    func schedule(_ notification: BotApprovalScheduledNotification) async throws {
        pending[notification.identifier] = notification
    }
    func pendingIdentifiers(prefix: String) async -> [String] {
        pending.keys.filter { $0.hasPrefix(prefix) }
    }
    func cancel(identifiers: [String]) async {
        for id in identifiers { pending.removeValue(forKey: id) }
    }
    func authorizationState() async -> BotNotificationAuthorizationState { state }
    func requestAuthorization() async { requestCalls += 1; state = .denied }
}

final class BotApprovalNotificationTests: XCTestCase {
    private func installRecord(_ id: String = "install-1", requestedAt: Int64 = 1_000)
        -> BotApprovalNotificationRecord {
        BotApprovalNotificationRecord(
            approvalID: id, botID: "main", action: "DeviceAppInstall",
            detail: "设备：ble:1\n应用：专注计时（focus_timer，版本 1）\n文件：\n权限：无",
            command: "", requestedAt: requestedAt, expiresAt: requestedAt + 300_000)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "approval-notif-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDeviceAppInstallReminderFiresAfterTenSecondsNamingTheApp() {
        let notification = BotApprovalNotificationPlanner.notification(
            for: installRecord(), now: 5_000)
        XCTAssertEqual(notification.fireAt, 15_000)
        XCTAssertEqual(notification.body, "「专注计时」在等你点「允许」，才会装到设备上")
        // Every other approval keeps the 60 s generic reminder.
        let other = BotApprovalNotificationPlanner.notification(
            for: record("generic"), now: 5_000)
        XCTAssertEqual(other.fireAt, 65_000)
        XCTAssertTrue(other.body.contains("批准或拒绝"))
    }

    func testReconcilerUsesPerApprovalDelayAndRequestsPermissionOnlyOnce() async {
        let fake = FakeAuthorizingScheduling()
        let defaults = freshDefaults()
        let reconciler = BotApprovalNotificationReconciler(
            scheduling: fake, now: { 5_000 }, askedDefaults: defaults)
        // Routine approvals never trigger the permission request.
        let none = await reconciler.requestPermissionIfNeeded(for: [record("generic")])
        XCTAssertFalse(none)
        let asked = await reconciler.requestPermissionIfNeeded(for: [installRecord()])
        XCTAssertTrue(asked)
        let again = await reconciler.requestPermissionIfNeeded(for: [installRecord("install-2")])
        XCTAssertFalse(again)
        // A new process (fresh reconciler) still does not ask again.
        let relaunched = BotApprovalNotificationReconciler(
            scheduling: FakeAuthorizingScheduling(), now: { 5_000 }, askedDefaults: defaults)
        let afterRelaunch = await relaunched.requestPermissionIfNeeded(for: [installRecord()])
        XCTAssertFalse(afterRelaunch)
        let calls = await fake.requestCalls
        XCTAssertEqual(calls, 1)

        // Refusal never blocks scheduling the reminder.
        let registered = await reconciler.sync([installRecord()])
        XCTAssertEqual(registered, 1)
        let snapshot = await reconciler.pendingSnapshot()
        XCTAssertEqual(snapshot.first?.fireAt, 15_000)
    }

    func testPermissionIsNotRequestedWhenAlreadyDecided() async {
        let fake = FakeAuthorizingScheduling(state: .authorized)
        let reconciler = BotApprovalNotificationReconciler(
            scheduling: fake, now: { 5_000 }, askedDefaults: freshDefaults())
        let asked = await reconciler.requestPermissionIfNeeded(for: [installRecord()])
        XCTAssertFalse(asked)
        let calls = await fake.requestCalls
        XCTAssertEqual(calls, 0)
    }

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

    func testCoordinatorReportsALiveInteractiveDeviceAppInstallCardOnly() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let issued = try await fixture.runtime.issueSessionToken(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let arguments = BotJSONValue.object(["command": .string("echo install")])
        let attribution = try await fixture.runtime.registerIdentity(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
            callId: "install-card", name: "bash", arguments: arguments,
            sessionToken: issued.token)
        let lookedUp = await fixture.runtime.gateway.tokens.lookupSession("gb-main")
        let principal = try XCTUnwrap(lookedUp)
        let call = try XCTUnwrap(BotResolvedToolCall(
            sessionId: "gb-main", callId: "install-card", agentId: "main",
            principal: principal, attribution: attribution))
        let grants = await fixture.runtime.grants
        let eventWriter = await fixture.runtime.eventWriter
        let coordinator = BotApprovalCoordinator(
            grants: grants, eventWriter: eventWriter, approvalTimeoutMs: 120_000)
        let effect = BotToolEffect(
            tool: "DeviceAppInstall", operation: "device-app.install",
            resource: "device-app:install", mutability: .destructive, policy: .ask,
            label: "在设备上安装应用", detail: "应用：专注计时（focus_timer，版本 1）",
            known: true, isMcp: true)
        let other = BotToolEffect(
            tool: "UpdateRoutine", operation: "routine.authorize",
            resource: "routine=create", mutability: .write, policy: .ask,
            label: "确认更新例行工作", known: false, isMcp: true)
        let install = Task {
            await coordinator.request(
                call: call, effects: [effect], action: "DeviceAppInstall",
                detail: effect.detail, command: "", alwaysScope: "none")
        }
        let routine = Task {
            await coordinator.request(
                call: call, effects: [other], action: "UpdateRoutine",
                detail: "", command: "", alwaysScope: "none")
        }
        var ids: [String] = []
        for _ in 0..<200 {
            ids = await coordinator.pendingIDs
            if ids.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(ids.count, 2)
        let records = await coordinator.pendingNotificationRecords()
        XCTAssertEqual(records.map(\.action), ["DeviceAppInstall"])
        let reminder = try XCTUnwrap(records.first)
        XCTAssertEqual(reminder.expiresAt - reminder.requestedAt, 120_000)
        let notification = BotApprovalNotificationPlanner.notification(
            for: reminder, now: reminder.requestedAt)
        XCTAssertEqual(notification.fireAt - reminder.requestedAt, 10_000)
        XCTAssertEqual(notification.body, "「专注计时」在等你点「允许」，才会装到设备上")

        for id in ids { _ = await coordinator.cancel(approvalId: id) }
        _ = await install.value
        _ = await routine.value
        let after = await coordinator.pendingNotificationRecords()
        XCTAssertTrue(after.isEmpty)
    }
}

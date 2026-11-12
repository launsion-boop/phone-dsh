// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

actor WP6RoutineNotificationSpy: RoutineNotificationScheduling {
    private(set) var scheduled: [String: RoutineScheduledNotification] = [:]
    private(set) var cancelled: [String] = []
    private(set) var scheduleCalls = 0
    var failNextSchedule = false

    func schedule(_ notification: RoutineScheduledNotification) async throws {
        scheduleCalls += 1
        if failNextSchedule {
            failNextSchedule = false
            throw RoutineError.invalidRoutine("notification scheduling failed")
        }
        scheduled[notification.identifier] = notification
    }

    func pendingIdentifiers(prefix: String) async -> [String] {
        scheduled.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func cancel(identifiers: [String]) async {
        for identifier in identifiers {
            cancelled.append(identifier)
            scheduled.removeValue(forKey: identifier)
        }
    }

    func pending() -> [RoutineScheduledNotification] {
        scheduled.values.sorted { ($0.fireAt, $0.identifier) < ($1.fireAt, $1.identifier) }
    }

    func cancelCount() -> Int { cancelled.count }
}

final class RoutineNotificationTests: XCTestCase {
    private func makeScheduler(root: URL, clock: WP6Clock,
                               settings: @escaping @Sendable () -> ProactiveSettings,
                               spy: WP6RoutineNotificationSpy,
                               runner: @escaping RoutineScheduler.Runner = { _ in .success("done") })
        throws -> (RoutineScheduler, RoutineMachine) {
        let machine = try wp6Machine(root: root)
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: try wp6Inbox(root: root),
            sink: WP6RoutineSink(), notifications: spy,
            runner: runner, available: { _ in true },
            settings: settings, now: { clock.now })
        return (scheduler, machine)
    }

    func testGoldenVectorDecodesThroughTheRealType() throws {
        let vector = try wp6Golden("routine-notification")
        let valid = try XCTUnwrap(vector["valid"] as? [String: Any])
        let expected = try XCTUnwrap(valid["normal"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: expected)
        let decoded = try JSONDecoder().decode(RoutineScheduledNotification.self, from: data)
        XCTAssertEqual(decoded.botId, "bot-a")
        XCTAssertEqual(decoded.routineId, "routine-1")
        XCTAssertEqual(decoded.title, "例行任务到期")
        XCTAssertEqual(decoded.deepLink, "phonedsh://bot/bot-a/routine/routine-1")
        XCTAssertEqual(BotRoutineDeepLink.parse(decoded.deepLink)?.routineId, "routine-1")
        XCTAssertEqual(decoded.identifier,
                       RoutineScheduledNotification.identifier(botId: "bot-a",
                                                               routineId: "routine-1",
                                                               fireAt: 1_760_056_200_000))
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
        XCTAssertEqual(reencoded as? NSDictionary, expected as NSDictionary)
    }

    func testSyncSchedulesEarliestDueRoutineAndReschedules() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let spy = WP6RoutineNotificationSpy()
        let (scheduler, machine) = try makeScheduler(
            root: root, clock: clock, settings: { wp6Settings() }, spy: spy)
        let routine = try await machine.create(
            botId: "bot-a", title: "晨间简报", prompt: "digest",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"), now: now, id: "routine-1")
        try await scheduler.syncNotifications()
        let expectedFireAt = try XCTUnwrap(routine.nextRunAt)
        let pending = await spy.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].fireAt, expectedFireAt)
        XCTAssertEqual(pending[0].body, "「晨间简报」到点，点开运行。")
        XCTAssertEqual(pending[0].deepLink, "phonedsh://bot/bot-a/routine/routine-1")

        let changedAt = expectedFireAt + 60_000
        _ = try await machine.update(
            botId: "bot-a", routineId: "routine-1",
            patch: RoutinePatch(schedule: .interval(everyMinutes: 45, timezone: "UTC")),
            now: changedAt)
        try await scheduler.syncNotifications()
        let rescheduled = await spy.pending()
        XCTAssertEqual(rescheduled.count, 1)
        XCTAssertNotEqual(rescheduled[0].identifier, pending[0].identifier)
        let cancelled = await spy.cancelled
        XCTAssertTrue(cancelled.contains(pending[0].identifier))
    }

    func testPresenceSnapshotReportsRegisteredCountAndEarliestTime() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let spy = WP6RoutineNotificationSpy()
        let (scheduler, machine) = try makeScheduler(
            root: root, clock: clock, settings: { wp6Settings() }, spy: spy)
        let empty = await scheduler.presenceSnapshot(appActive: true, keepingAlive: false)
        XCTAssertEqual(empty.scheduledNotificationCount, 0)
        XCTAssertNil(empty.nextNotificationAt)

        let first = try await machine.create(
            botId: "bot-a", title: "较早", prompt: "one",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"), now: now, id: "routine-early")
        _ = try await machine.create(
            botId: "bot-a", title: "较晚", prompt: "two",
            schedule: .interval(everyMinutes: 45, timezone: "UTC"), now: now, id: "routine-late")
        try await scheduler.syncNotifications()
        let presence = await scheduler.presenceSnapshot(appActive: true, keepingAlive: false)
        XCTAssertEqual(presence.scheduledNotificationCount, 2)
        XCTAssertEqual(presence.nextNotificationAt, first.nextRunAt)
        XCTAssertEqual(presence.level, .foreground)
        let pending = await spy.pending()
        XCTAssertEqual(presence.nextNotificationAt, pending.first?.fireAt)
    }

    func testQuietHoursDeferReminderAndUrgentBypasses() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 22, timeZone: "Asia/Taipei")
        let clock = WP6Clock(now)
        let spy = WP6RoutineNotificationSpy()
        let settings = wp6Settings(quietStart: "23:00", quietEnd: "08:00", timeZone: "Asia/Taipei")
        let (scheduler, machine) = try makeScheduler(
            root: root, clock: clock, settings: { settings }, spy: spy)
        _ = try await machine.create(
            botId: "bot-a", title: "夜间摘要", prompt: "digest",
            schedule: .daily(time: "23:00", timezone: "Asia/Taipei"), now: now, id: "quiet")
        _ = try await machine.create(
            botId: "bot-a", title: "发布窗口检查", prompt: "check",
            schedule: .daily(time: "23:00", timezone: "Asia/Taipei"),
            urgent: true, urgentReason: "发布截止", now: now, id: "urgent")
        try await scheduler.syncNotifications()
        let pending = await spy.pending()
        XCTAssertEqual(pending.count, 2)
        let quiet = try XCTUnwrap(pending.first { $0.routineId == "quiet" })
        let urgent = try XCTUnwrap(pending.first { $0.routineId == "urgent" })
        XCTAssertEqual(quiet.fireAt, wp6Date(2026, 5, 13, 8, timeZone: "Asia/Taipei"))
        XCTAssertEqual(urgent.fireAt, wp6Date(2026, 5, 12, 23, timeZone: "Asia/Taipei"))
    }

    func testDNDCancelsEverythingAndSettingChangeAppliesImmediately() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let spy = WP6RoutineNotificationSpy()
        let store = InMemoryProactiveSettings(wp6Settings())
        let (scheduler, machine) = try makeScheduler(
            root: root, clock: clock, settings: { store.value }, spy: spy)
        _ = try await machine.create(
            botId: "bot-a", title: "任务", prompt: "work",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"), now: now, id: "routine-1")
        try await scheduler.syncNotifications()
        let beforeDND = await spy.pending()
        XCTAssertEqual(beforeDND.count, 1)

        store.value = wp6Settings(dnd: true)
        try await scheduler.applySettingsChange()
        let afterDND = await spy.pending()
        let cancelledAfterDND = await spy.cancelled
        XCTAssertEqual(afterDND.count, 0)
        XCTAssertEqual(cancelledAfterDND.count, 1)
    }

    func testRunCancelsDueReminderThenSchedulesNextOccurrence() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let spy = WP6RoutineNotificationSpy()
        let (scheduler, machine) = try makeScheduler(
            root: root, clock: clock, settings: { wp6Settings() }, spy: spy)
        let routine = try await machine.create(
            botId: "bot-a", title: "任务", prompt: "work",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"),
            now: now, id: "routine-1")
        try await scheduler.syncNotifications()
        let pendingBeforeRun = await spy.pending()
        let first = try XCTUnwrap(pendingBeforeRun.first)
        XCTAssertEqual(first.fireAt, try XCTUnwrap(routine.nextRunAt))

        clock.set(try XCTUnwrap(routine.nextRunAt))
        try await scheduler.tick()
        let ids = await spy.cancelled
        XCTAssertTrue(ids.contains(first.identifier))
        let afterRun = await spy.pending()
        XCTAssertEqual(afterRun.count, 1, "the next interval should be scheduled after the run")
        XCTAssertGreaterThan(afterRun[0].fireAt, clock.now)
    }

    func testDisabledRoutineCancelsAndCapKeepsEarliestSixty() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let spy = WP6RoutineNotificationSpy()
        let (scheduler, machine) = try makeScheduler(
            root: root, clock: clock, settings: { wp6Settings() }, spy: spy)
        for index in 0..<65 {
            _ = try await machine.create(
                botId: "bot-a", title: "任务 \(index)", prompt: "work",
                schedule: .interval(everyMinutes: 120, phaseMinutes: index, timezone: "UTC"),
                now: now + Int64(index) * 1_000, id: "routine-\(index)")
        }
        try await scheduler.syncNotifications()
        let pending = await spy.pending()
        XCTAssertEqual(pending.count, RoutineScheduler.maxScheduledNotifications)
        XCTAssertEqual(pending.map(\.fireAt), pending.map(\.fireAt).sorted())

        _ = try await machine.update(
            botId: "bot-a", routineId: "routine-0",
            patch: RoutinePatch(enabled: false), now: now + 120_000)
        try await scheduler.syncNotifications()
        let afterPause = await spy.pending()
        XCTAssertLessThanOrEqual(afterPause.count, RoutineScheduler.maxScheduledNotifications)
        XCTAssertFalse(afterPause.contains { $0.routineId == "routine-0" })
    }

    func testSchedulingFailureDoesNotBlockRoutineOrRegistrationRetry() async throws {
        let root = try wp6TempDirectory(self)
        let now = wp6Date(2026, 5, 12, 12)
        let clock = WP6Clock(now)
        let spy = WP6RoutineNotificationSpy()
        await spy.setFailNext(true)
        let (scheduler, machine) = try makeScheduler(
            root: root, clock: clock, settings: { wp6Settings() }, spy: spy)
        _ = try await machine.create(
            botId: "bot-a", title: "任务", prompt: "work",
            schedule: .interval(everyMinutes: 30, timezone: "UTC"), now: now, id: "routine-1")
        try await scheduler.syncNotifications()
        let failed = await spy.pending()
        XCTAssertEqual(failed.count, 0)
        let routines = try await machine.list(botId: "bot-a")
        XCTAssertEqual(routines.count, 1)
        try await scheduler.syncNotifications()
        let retried = await spy.pending()
        XCTAssertEqual(retried.count, 1)
    }
}

final class InMemoryProactiveSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProactiveSettings

    init(_ value: ProactiveSettings) { stored = value }

    var value: ProactiveSettings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private extension WP6RoutineNotificationSpy {
    func setFailNext(_ value: Bool) { failNextSchedule = value }
}

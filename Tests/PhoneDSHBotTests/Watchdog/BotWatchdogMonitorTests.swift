// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotWatchdogMonitorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-watchdog-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testFiveBaseChecksEmitOnlyOncePerUnitAndNeverEndUnit() async throws {
        let store = try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 100 })
        let config = BotWatchdogConfig(
            heartbeatTimeoutMs: 10, turnDeadlineMs: 10,
            repeatedToolCalls: 2, repeatedToolErrors: 2,
            maxUnitTokens: 10, maxUnitCostUsd: 1, tickMs: 0)
        let monitor = BotWatchdogMonitor(eventLog: store, config: config, now: { 100 })
        await assertEqualAsync(await monitor.startUnit(kind: .turn, id: "turn-1", botId: "main", at: 100), [])

        var flags = await monitor.observeToolCall(kind: .turn, id: "turn-1", name: "read", argumentsDigest: "digest", callId: "call-1")
        XCTAssertEqual(flags.map(\.check), [])
        flags = await monitor.observeToolCall(kind: .turn, id: "turn-1", name: "read", argumentsDigest: "digest", callId: "call-2")
        XCTAssertEqual(flags.map(\.check), [.repeatedToolSignature])
        await assertEqualAsync(await monitor.observeToolCall(kind: .turn, id: "turn-1", name: "read", argumentsDigest: "digest"), [])

        _ = await monitor.observeToolResult(kind: .turn, id: "turn-1", status: "error", error: "same", callId: "call-1")
        flags = await monitor.observeToolResult(kind: .turn, id: "turn-1", status: "error", error: "same", callId: "call-2")
        XCTAssertEqual(flags.map(\.check), [.repeatedToolError])
        await assertEqualAsync(await monitor.observeToolResult(kind: .turn, id: "turn-1", status: "error", error: "same"), [])

        flags = await monitor.observeUsage(kind: .turn, id: "turn-1", tokens: 11, costUsd: 2)
        XCTAssertEqual(flags.map(\.check), [.quota])
        await assertEqualAsync(await monitor.observeUsage(kind: .turn, id: "turn-1", tokens: 100, costUsd: 100), [])

        flags = await monitor.tick(at: 111)
        XCTAssertEqual(Set(flags.map(\.check)), [.deadline, .heartbeat])
        await assertEqualAsync(await monitor.tick(at: 112), [])
        let observedUnit = await monitor.unit(kind: .turn, id: "turn-1")
        let unit = try XCTUnwrap(observedUnit)
        XCTAssertEqual(unit.tokens, 111)
        XCTAssertEqual(unit.costUsd, 102)
        let events = try await store.events(after: 0, limit: 20)
        XCTAssertEqual(events.count, 5)
        XCTAssertTrue(events.allSatisfy { $0.type == "watchdog.flagged" && $0.origin == .local(source: "watchdog") })
        XCTAssertEqual(Set(events.map(\.eventId)).count, 5)
        try await store.close()
    }

    func testThreeMobileEventsEmitOnceAndStayDurableAcrossReopen() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1 })
        let config = BotWatchdogConfig(heartbeatTimeoutMs: 0, turnDeadlineMs: 0, tickMs: 0)
        let monitor = BotWatchdogMonitor(eventLog: store, config: config, now: { 1 })
        for event in BotMobileWatchdogEvent.allCases {
            var flags = await monitor.observeMobile(event, kind: .turn, id: "turn-mobile", at: 1)
            XCTAssertEqual(flags.map(\.check), [event.check])
            flags = await monitor.observeMobile(event, kind: .turn, id: "turn-mobile", at: 2)
            XCTAssertEqual(flags, [])
        }
        await assertEqualAsync(try await store.headCommitSeq(), 3)
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2 })
        let reopenedMonitor = BotWatchdogMonitor(eventLog: reopened, config: config, now: { 2 })
        _ = await reopenedMonitor.observeMobile(.thermalPressure, kind: .turn, id: "turn-mobile", at: 2)
        await assertEqualAsync(try await reopened.headCommitSeq(), 3)
        let events = try await reopened.events(after: 0, limit: 10)
        XCTAssertEqual(events.map(\.type), Array(repeating: "watchdog.flagged", count: 3))
        let checks = events.map { $0.data.objectValue?["check"] }
        XCTAssertEqual(checks, [.string("webcontent_terminated"), .string("thermal_pressure"), .string("battery_pressure")])
        let replayFlags = await reopenedMonitor.observeMobile(
            .thermalPressure, kind: .turn, id: "turn-mobile", at: 3)
        XCTAssertEqual(replayFlags, [])
        await assertEqualAsync(await reopenedMonitor.flags(), [])
        try await reopened.close()
    }

    func testAppendFailureReleasesPendingForTickRetryWithoutBlockingOtherChecks() async throws {
        let deadlineEventId = "watchdog.flagged:turn:unit-failure:deadline"
        let heartbeatEventId = "watchdog.flagged:turn:unit-failure:heartbeat"
        let eventLog = WatchdogTestEventLog(failures: [deadlineEventId: 1])
        let config = BotWatchdogConfig(
            heartbeatTimeoutMs: 1, turnDeadlineMs: 1,
            repeatedToolCalls: 5, repeatedToolErrors: 3,
            maxUnitTokens: 0, maxUnitCostUsd: 0, tickMs: 0)
        let monitor = BotWatchdogMonitor(eventLog: eventLog, config: config, now: { 0 })
        await assertEqualAsync(await monitor.startUnit(kind: .turn, id: "unit-failure", at: 0), [])

        let first = await monitor.tick(at: 2)
        XCTAssertEqual(first.map(\.check), [.heartbeat])
        let deadlineSeenAfterFailure = await monitor.hasFlagged(
            kind: .turn, id: "unit-failure", check: .deadline)
        XCTAssertFalse(deadlineSeenAfterFailure)
        let heartbeatSeen = await monitor.hasFlagged(kind: .turn, id: "unit-failure", check: .heartbeat)
        XCTAssertTrue(heartbeatSeen)
        await assertEqualAsync(await eventLog.attempts(for: deadlineEventId), 1)
        await assertEqualAsync(await eventLog.attempts(for: heartbeatEventId), 1)

        let retry = await monitor.tick(at: 3)
        XCTAssertEqual(retry.map(\.check), [.deadline])
        await assertEqualAsync(await eventLog.attempts(for: deadlineEventId), 2)
        await assertEqualAsync(await eventLog.attempts(for: heartbeatEventId), 1)
        await assertEqualAsync(await monitor.tick(at: 4), [])
        let events = try await eventLog.events(after: 0, limit: 10)
        XCTAssertEqual(events.map(\.eventId), [heartbeatEventId, deadlineEventId])
    }

    func testConcurrentSameCheckIsSingleFlight() async throws {
        let eventId = "watchdog.flagged:turn:unit-concurrent:thermal_pressure"
        let eventLog = WatchdogTestEventLog(appendDelayNs: 20_000_000)
        let monitor = BotWatchdogMonitor(eventLog: eventLog, now: { 1 })
        let results = await withTaskGroup(
            of: [BotWatchdogFlag].self,
            returning: [[BotWatchdogFlag]].self
        ) { group in
            for _ in 0..<16 {
                group.addTask {
                    await monitor.observeMobile(
                        .thermalPressure, kind: .turn, id: "unit-concurrent", at: 1)
                }
            }
            var values: [[BotWatchdogFlag]] = []
            for await value in group { values.append(value) }
            return values
        }
        let emitted = results.flatMap { $0 }
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.eventId, eventId)
        await assertEqualAsync(await eventLog.attempts(for: eventId), 1)
        let events = try await eventLog.events(after: 0, limit: 10)
        XCTAssertEqual(events.count, 1)
        await assertEqualAsync(await monitor.flags().count, 1)
        await assertEqualAsync(await monitor.observeMobile(
            .thermalPressure, kind: .turn, id: "unit-concurrent", at: 2), [])
    }

    func testSecondMonitorSuppressesDurableReplayButAllowsDifferentCheck() async throws {
        let eventLog = WatchdogTestEventLog()
        let firstMonitor = BotWatchdogMonitor(eventLog: eventLog, now: { 1 })
        let secondMonitor = BotWatchdogMonitor(eventLog: eventLog, now: { 2 })
        let first = await firstMonitor.observeMobile(
            .webcontentTerminated, kind: .turn, id: "unit-shared", at: 1)
        XCTAssertEqual(first.count, 1)

        let replay = await secondMonitor.observeMobile(
            .webcontentTerminated, kind: .turn, id: "unit-shared", at: 2)
        XCTAssertEqual(replay, [])
        await assertEqualAsync(await secondMonitor.flags(), [])
        let replaySeen = await secondMonitor.hasFlagged(
            kind: .turn, id: "unit-shared", check: .webcontentTerminated)
        XCTAssertTrue(replaySeen)
        await assertEqualAsync(await eventLog.attempts(
            for: "watchdog.flagged:turn:unit-shared:webcontent_terminated"), 1)

        let different = await secondMonitor.observeMobile(
            .batteryPressure, kind: .turn, id: "unit-shared", at: 3)
        XCTAssertEqual(different.map(\.check), [.batteryPressure])
        let events = try await eventLog.events(after: 0, limit: 10)
        XCTAssertEqual(events.count, 2)
    }
}

private enum WatchdogTestError: Error {
    case injectedAppendFailure
}

private actor WatchdogTestEventLog: BotEventLog {
    private var failures: [String: Int]
    private let appendDelayNs: UInt64
    private var stored: [BotEvent] = []
    private var appendAttempts: [String: Int] = [:]

    init(failures: [String: Int] = [:], appendDelayNs: UInt64 = 0) {
        self.failures = failures
        self.appendDelayNs = appendDelayNs
    }

    func append(_ event: BotEvent) async throws -> Int {
        appendAttempts[event.eventId, default: 0] += 1
        if appendDelayNs > 0 { try await Task.sleep(nanoseconds: appendDelayNs) }
        if let remaining = failures[event.eventId], remaining > 0 {
            failures[event.eventId] = remaining - 1
            throw WatchdogTestError.injectedAppendFailure
        }
        if let existing = stored.first(where: { $0.eventId == event.eventId }) {
            return existing.commitSeq ?? 0
        }
        let commitSeq = stored.count + 1
        stored.append(event.assigningCommitSeq(commitSeq))
        return commitSeq
    }

    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        guard commitSeq >= 0, commitSeq <= stored.count, limit > 0 else {
            throw SQLiteDomainStoreError.invalidCursor("invalid test cursor")
        }
        return Array(stored.dropFirst(commitSeq).prefix(limit))
    }

    func attempts(for eventId: String) -> Int {
        appendAttempts[eventId] ?? 0
    }
}

private extension BotJSONValue {
    var objectValue: [String: BotJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

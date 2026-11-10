// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

func wp6RepoRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("spec/bot/v1/golden").path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw XCTSkip("cannot locate spec/bot/v1/golden from #filePath")
}

func wp6Golden(_ name: String) throws -> [String: Any] {
    try BotGoldenFixture.mergedObject(name)
}

func wp6Encode<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
}

func wp6TempDirectory(_ test: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wp6-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

func wp6Date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
             second: Int = 0, timeZone: String = "UTC") -> Int64 {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone)!
    let date = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    return Int64(date.timeIntervalSince1970 * 1000)
}

final class WP6Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ value: Int64) { self.value = value }

    var now: Int64 {
        lock.withLock { value }
    }

    func set(_ value: Int64) {
        lock.withLock { self.value = value }
    }

    func advance(_ milliseconds: Int64) {
        lock.withLock { value += milliseconds }
    }
}

final class WP6Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    var current: Bool { lock.withLock { value } }

    func set(_ value: Bool) { lock.withLock { self.value = value } }
}

final class WP6RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RoutineRunRequest] = []

    var all: [RoutineRunRequest] { lock.withLock { requests } }
    var count: Int { lock.withLock { requests.count } }

    func append(_ request: RoutineRunRequest) {
        lock.withLock { requests.append(request) }
    }
}

actor WP6RoutineSink: RoutineResultSink {
    private(set) var rows: [RoutineAutomation] = []
    private(set) var duplicateCalls = 0
    private(set) var unreadCount = 0

    func deliver(_ automation: RoutineAutomation) async throws -> Bool {
        if rows.contains(where: { $0.id == automation.id && $0.botId == automation.botId }) {
            duplicateCalls += 1
            return true
        }
        rows.append(automation)
        if !automation.quiet { unreadCount += 1 }
        return false
    }
}

actor WP6Proactive: ProactiveConsidering {
    private(set) var candidates: [ProactiveCandidate] = []
    var mode: ProactiveMode
    var decision: ProactiveDecisionKind
    var reason: String

    init(mode: ProactiveMode = .on, decision: ProactiveDecisionKind = .did, reason: String = "delivered") {
        self.mode = mode
        self.decision = decision
        self.reason = reason
    }

    func consider(_ candidate: ProactiveCandidate) async -> ProactiveDecision {
        candidates.append(candidate)
        let notification = ProactiveNotification(title: candidate.title ?? "routine", body: candidate.body ?? "",
                                                 kind: candidate.kind, botId: candidate.botId,
                                                 dedupeKey: candidate.dedupeKey ?? candidate.id ?? "",
                                                 rowId: candidate.rowId)
        return ProactiveDecision(id: "fake-\(candidates.count)", at: candidate.createdAt,
                                 decision: decision, reason: reason, kind: candidate.kind,
                                 botId: candidate.botId, dedupeKey: candidate.dedupeKey,
                                 mode: mode, notification: notification)
    }

    func restoreAccounting() async -> Int { 0 }
}

final class WP6NotificationDeliverer: ProactiveDelivering, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProactiveNotification] = []
    var result = ProactiveDeliveryResult(delivered: true)

    var notifications: [ProactiveNotification] { lock.withLock { values } }

    func deliver(_ notification: ProactiveNotification) async throws -> ProactiveDeliveryResult {
        lock.withLock { values.append(notification) }
        return result
    }
}

actor WP6EventLog: BotEventLog {
    private var stored: [BotEvent] = []

    init(events: [BotEvent] = []) {
        stored = events
    }

    func append(_ event: BotEvent) async throws -> Int {
        let commitSeq = (stored.compactMap(\.commitSeq).max() ?? 0) + 1
        stored.append(BotEvent(schemaVersion: event.schemaVersion, type: event.type,
                               eventId: event.eventId, commitSeq: commitSeq, time: event.time,
                               origin: event.origin, traceId: event.traceId, principal: event.principal,
                               causationId: event.causationId, correlationId: event.correlationId,
                               turnId: event.turnId, runId: event.runId, attempt: event.attempt,
                               batch: event.batch, ignorable: event.ignorable, data: event.data))
        return commitSeq
    }

    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        Array(stored.filter { ($0.commitSeq ?? 0) > commitSeq }
            .sorted { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }.prefix(limit))
    }
}

func wp6Consideration(at: Int64, commitSeq: Int, dedupeKey: String,
                      botId: String = "bot-1", kind: String = "task-done",
                      decision: String = "would", mode: String = "would",
                      cost: Int = 1, spendBudget: Bool = true,
                      fuseRecorded: Bool = true) -> BotEvent {
    BotEvent(type: "proactive.considered", eventId: "proactive:\(commitSeq)", commitSeq: commitSeq,
             time: at, origin: .local(source: "runtime"), traceId: "trace-\(commitSeq)",
             principal: BotPrincipal(botId: botId, sessionId: nil, kind: "proactive"),
             causationId: nil, correlationId: dedupeKey,
             data: .object([
                "decision": .string(decision), "reason": .string("test"),
                "kind": .string(kind), "botId": .string(botId), "dedupeKey": .string(dedupeKey),
                "mode": .string(mode), "channel": .string("system-notification"),
                "cost": .number(Double(cost)), "spendBudget": .bool(spendBudget),
                "fuseRecorded": .bool(fuseRecorded),
             ]))
}

func WP6AssertEqual<T: Equatable>(_ actual: @autoclosure () async throws -> T,
                                  _ expected: @autoclosure () -> T,
                                  file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let value = try await actual()
    XCTAssertEqual(value, expected(), file: file, line: line)
}

func WP6AssertNil<T>(_ actual: @autoclosure () async throws -> T?,
                     file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let value = try await actual()
    XCTAssertNil(value, file: file, line: line)
}

func WP6AssertGreaterThanOrEqual<T: Comparable>(_ actual: @autoclosure () async throws -> T,
                                                _ expected: @autoclosure () -> T,
                                                file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let value = try await actual()
    XCTAssertGreaterThanOrEqual(value, expected(), file: file, line: line)
}

func wp6Machine(root: URL) throws -> RoutineMachine {
    let domainStore = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    return RoutineMachine(store: SQLiteRoutineStore(domainStore: domainStore))
}

func wp6Inbox(root: URL) throws -> WakeInbox {
    let domainStore = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    return WakeInbox(store: SQLiteWakeInboxStore(domainStore: domainStore, botId: "bot-a"))
}

func wp6Settings(mode: ProactiveMode = .on, dnd: Bool = false, quietStart: String = "00:00",
                 quietEnd: String = "00:00", weekends: Bool = false,
                 timeZone: String = "UTC") -> ProactiveSettings {
    ProactiveSettings(mode: mode, dnd: dnd, quietStart: quietStart, quietEnd: quietEnd,
                      routineQuietWeekends: weekends, timeZone: timeZone)
}

// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import ProbeKit
import XCTest

/// Hostless simulator evidence for the Bot half of ReadySweep: the real
/// `BotReadySweepRunner` + the frozen `ReadySweepPolicy` gate + the real
/// routine scheduler and connector scanner, in one app-target test bundle.
final class BotReadySweepHostlessTests: XCTestCase {
    func testTheFrozenLeaseGateSkipsWholeSteps() async {
        let log = HostlessStepLog()
        let report = await BotReadySweepRunner(
            budget: budget(remaining: 0),
            action: { step in log.append(step) }).run()
        XCTAssertEqual(log.all, [])
        XCTAssertEqual(report.steps.map(\.outcome),
                       Array(repeating: .skipped(reason: "lease"),
                             count: BotReadySweepStep.allCases.count))
    }

    func testOnlyTheStepWhoseBudgetFitsStarts() async {
        let log = HostlessStepLog()
        let minimal = EngineLaunchThresholds.parkMarginMs
            + ReadySweepPolicy.stepBudgetMs(for: .botHeldInbox)
        let report = await BotReadySweepRunner(
            budget: budget(remaining: minimal),
            action: { step in log.append(step) }).run()
        XCTAssertEqual(log.all, [.botHeldInbox])
        XCTAssertEqual(report.outcome(for: .botHeldInbox), .ran)
        XCTAssertEqual(report.outcome(for: .missedRoutines), .skipped(reason: "lease"))
        XCTAssertEqual(report.outcome(for: .connectorScan), .skipped(reason: "lease"))
        XCTAssertEqual(report.outcome(for: .approvalReminderSync), .skipped(reason: "lease"))
    }

    func testResidentLeaseRunsAllFourStepsAgainstRealStores() async throws {
        let root = tempDirectory()
        let store = try SQLiteDomainStore(fileURL: root.appendingPathComponent("domain.sqlite"))
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: store, botId: "bot-a"))
        _ = try await inbox.enqueue(try WakeInboxItem(
            id: "held-1", kind: "routine-result", title: "Digest", text: "done",
            requestId: "routine:1", createdAt: 1_000))

        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        _ = try await machine.create(botId: "bot-a", title: "Catch up", prompt: "work",
                                     schedule: .interval(everyMinutes: 5, timezone: "UTC"),
                                     now: 1_000, id: "catch-up")
        let runs = HostlessRunLog()
        let scheduler = RoutineScheduler(
            botId: "bot-a", machine: machine, inbox: inbox, sink: HostlessSink(),
            runner: { request in runs.append(request.routine.id); return .success("ok") },
            available: { _ in true }, settings: { ProactiveSettings() },
            now: { 1_000_000 })

        let cursorStore = HostlessCursorStore()
        let client = HostlessConnectorClient()
        let sink = HostlessUpdateSink()
        let scanner = ConnectorDeltaScanner(clients: [client], cursors: cursorStore,
                                            sink: sink, now: { 2_000 })

        let heldWakes = HostlessCounter()
        let report = await BotReadySweepRunner(
            budget: budget(remaining: .max),
            action: { step in
                switch step {
                case .botHeldInbox:
                    let staged = try await inbox.stage(now: 2_000, key: "wake-1")
                    XCTAssertEqual(staged.items.count, 1)
                    try await inbox.commit(staged.key)
                    heldWakes.increment()
                case .missedRoutines:
                    try await scheduler.tick()
                case .connectorScan:
                    _ = await scanner.scanBatch()
                case .approvalReminderSync:
                    break
                }
            }).run()

        XCTAssertEqual(report.ranSteps, BotReadySweepStep.allCases)
        XCTAssertEqual(heldWakes.value, 1)
        let remainingItems = try await inbox.items()
        XCTAssertEqual(remainingItems, [])
        let routine = try await machine.get(botId: "bot-a", routineId: "catch-up")
        XCTAssertEqual(runs.all, ["catch-up"])
        XCTAssertGreaterThan(routine?.nextRunAt ?? 0, 1_000_000)
        let records = await sink.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.requestID, "gmail:1000:1010")
        let savedCursor = await cursorStore.cursor(for: .gmail)
        XCTAssertEqual(savedCursor?.cursor, "1010")
    }

    // MARK: - Budget mapping

    /// The production composition maps the Bot enum to the shared contract
    /// enum in one place; this test uses the same mapping so the simulator
    /// drives the frozen budget constants, never a local copy.
    private func budget(remaining: Int64) -> BotReadySweepBudget {
        BotReadySweepBudget(
            remainingMs: { remaining },
            shouldRun: { step, value in
                ReadySweepPolicy.shouldRun(Self.sharedStep(step), remainingMs: value)
            })
    }

    static func sharedStep(_ step: BotReadySweepStep) -> ReadySweepStep {
        switch step {
        case .botHeldInbox: return .botHeldInbox
        case .missedRoutines: return .missedRoutines
        case .connectorScan: return .connectorScan
        case .approvalReminderSync: return .approvalReminderSync
        }
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-ready-sweep-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

// MARK: - Test doubles

private final class HostlessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class HostlessStepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [BotReadySweepStep] = []

    var all: [BotReadySweepStep] { lock.withLock { steps } }
    func append(_ step: BotReadySweepStep) { lock.withLock { steps.append(step) } }
}

private final class HostlessRunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    var all: [String] { lock.withLock { ids } }
    func append(_ id: String) { lock.withLock { ids.append(id) } }
}

private actor HostlessSink: RoutineResultSink {
    func deliver(_ automation: RoutineAutomation) async throws -> Bool { false }
}

private actor HostlessCursorStore: ConnectorCursorStoring {
    private var cursors: [ConnectorKind: ConnectorCursorState] = [:]

    func load(_ connector: ConnectorKind) async throws -> ConnectorCursorLoad {
        if let state = cursors[connector] { return .stored(state) }
        return .absent
    }

    func save(_ state: ConnectorCursorState) async throws { cursors[state.connector] = state }
    func clear(_ connector: ConnectorKind) async throws { cursors.removeValue(forKey: connector) }

    func cursor(for connector: ConnectorKind) -> ConnectorCursorState? { cursors[connector] }
}

private actor HostlessUpdateSink: ConnectorUpdateEnqueuing {
    private(set) var records: [ConnectorUpdateRecord] = []

    func enqueue(_ update: ConnectorUpdateRecord) async throws -> Bool {
        guard !records.contains(where: { $0.requestID == update.requestID }) else { return false }
        records.append(update)
        return true
    }
}

private actor HostlessConnectorClient: ConnectorDeltaClient {
    nonisolated let connector: ConnectorKind = .gmail
    private var scans = 0

    func fetchDelta(cursor: ConnectorCursorState?) async throws -> ConnectorDeltaPage {
        scans += 1
        if cursor == nil { return ConnectorDeltaPage(head: .gmail(historyId: "1000")) }
        return ConnectorDeltaPage(
            head: .gmail(historyId: "1010"),
            items: [ConnectorMetadataItem(id: "m1", at: 2_000,
                                          from: "QA <qa@example.com>", subject: "One")])
    }
}

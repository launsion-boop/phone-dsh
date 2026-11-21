// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import XCTest
@testable import PhoneDSHBot

/// Durable-before-dispatch outbox: the pending row is written before the
/// remote turn can start, survives a throw/kill, is replayed once and cleared
/// only after a non-throwing outcome.
final class PendingActionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-pending-actions-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Store API

    func testEveryActionKindRoundTripsThroughThePendingRow() async throws {
        let store = try makeStore(now: 1_000)
        let actions = [
            BotUserAction(nonce: "chat-1", botID: "main", kind: .chat, text: "继续",
                          attachments: [
                            BotAttachment(name: "a.pdf", path: "/imports/a.pdf", size: 12,
                                          mimeType: "application/pdf", kind: "document"),
                          ]),
            BotUserAction(nonce: "answer-1", botID: "main", kind: .cardAnswer,
                          cardID: "card-1", optionID: "opt-1"),
            BotUserAction(nonce: "dismiss-1", botID: "main", kind: .cardDismiss,
                          cardID: "card-2"),
            BotUserAction(nonce: "approval-1", botID: "main", kind: .approval,
                          approvalID: "approval-1", decision: .allowOnce, digest: "digest-1"),
            BotUserAction(nonce: "stop-1", botID: "main", kind: .stopTask, threadID: "thread-1"),
        ]
        for (index, action) in actions.enumerated() {
            try await store.recordPendingAction(action, now: Int64(1_000 + index))
        }
        await assertEqualAsync(try await store.pendingActions(botID: "main"), actions)
        await assertEqualAsync(try await store.pendingActions(botID: "other"), [])
        await assertEqualAsync(try await store.clearPendingAction(botID: "main", nonce: "dismiss-1"),
                               true)
        await assertEqualAsync(try await store.clearPendingAction(botID: "main", nonce: "dismiss-1"),
                               false)
        await assertEqualAsync(try await store.pendingActions(botID: "main").map(\.nonce),
                               ["chat-1", "answer-1", "approval-1", "stop-1"])
        try await store.close()
    }

    func testDuplicateRecordKeepsTheOriginalRowAndAttemptCount() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let action = Self.chatAction()
        try await store.recordPendingAction(action, now: 100)
        await assertEqualAsync(try await store.bumpPendingActionAttempt(
            botID: "main", nonce: "nonce-1"), 2)
        await assertEqualAsync(try await store.bumpPendingActionAttempt(
            botID: "main", nonce: "nonce-1"), 3)
        // A retry of the same nonce must not reset the row: replay ordering and
        // the attempt counter stay anchored to the first write.
        try await store.recordPendingAction(action, now: 500)
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [action])
        try await store.close()

        XCTAssertEqual(try RawStore.scalar(
            "SELECT created_at_ms FROM bot_pending_actions WHERE bot_id = 'main' AND nonce = 'nonce-1'",
            at: file), "100")
        XCTAssertEqual(try RawStore.scalar(
            "SELECT attempts FROM bot_pending_actions WHERE bot_id = 'main' AND nonce = 'nonce-1'",
            at: file), "3")

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.pendingActions(botID: "main"), [action])
        await assertEqualAsync(try await reopened.bumpPendingActionAttempt(
            botID: "main", nonce: "nonce-1"), 4)
        try await reopened.close()
    }

    // MARK: - Dispatcher durability

    func testPendingActionSurvivesPlannerThrowAndReopen() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let planner = ThrowingPlanner()
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        let action = Self.chatAction()
        do {
            _ = try await dispatcher.dispatch(action)
            XCTFail("a throwing planner must fail the dispatch")
        } catch {
            XCTAssertEqual(error as? PlannerFailure, .offline)
        }
        await assertEqualAsync(await planner.calls, 1)
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [action])
        await assertEqualAsync(try await store.eventID(botID: "main", nonce: action.nonce), nil)
        try await store.close()

        // The attempted count is diagnostic and durable; the row itself must
        // still be there after a full reopen.
        XCTAssertEqual(try RawStore.scalar(
            "SELECT attempts FROM bot_pending_actions WHERE bot_id = 'main' AND nonce = 'nonce-1'",
            at: file), "2")
        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.pendingActions(botID: "main"), [action])
        await assertEqualAsync(try await reopened.headCommitSeq(), 0)
        try await reopened.close()
    }

    func testSimulatedKillBetweenRecordAndClearLeavesTheRowForReplay() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let planner = RowActionPlannerDouble()
        await planner.setEventID("action:nonce-1", for: "nonce-1")
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        let action = Self.chatAction()
        // The crash hook fires after the plan and before the commit; the
        // pending row was committed by its own transaction, so it survives the
        // closed database exactly like a process kill mid-turn.
        await store.armCrashPoint("abort-after-plan")
        do {
            _ = try await dispatcher.dispatch(action)
            XCTFail("the injected kill must abort the dispatch")
        } catch {
            XCTAssertEqual(error as? SQLiteDomainStoreError,
                           .simulatedCrash("abort-after-plan"))
        }
        // The crash hook closed the connection; reopening is the process
        // restart. The pending row was committed before it and survives.
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.pendingActions(botID: "main"), [action])
        await assertEqualAsync(try await reopened.headCommitSeq(), 0)
        let replay = BotUserActionDispatcher(store: reopened, planner: planner)
        let pending = try await reopened.pendingActions(botID: "main")
        var results: [BotActionResult] = []
        for action in pending { results.append(try await replay.dispatch(action)) }
        XCTAssertEqual(results, [.accepted(eventID: "action:nonce-1")])
        await assertEqualAsync(try await reopened.pendingActions(botID: "main"), [])
        await assertEqualAsync(try await reopened.events(after: 0, limit: 10).count, 1)
        await assertEqualAsync(try await reopened.eventID(botID: "main", nonce: "nonce-1"),
                               "action:nonce-1")
        // A second replay is a duplicate and never re-plans the action.
        await assertEqualAsync(try await replay.dispatch(action),
                               .duplicate(eventID: "action:nonce-1"))
        await assertEqualAsync(await planner.actions.count, 2)
        await assertEqualAsync(try await reopened.pendingActions(botID: "main"), [])
        try await reopened.verifyIntegrity()
        try await reopened.close()
    }

    func testCommittedActionWithLeftoverPendingRowIsDuplicateAndClearsIt() async throws {
        let store = try makeStore(now: 1_000)
        let planner = RowActionPlannerDouble()
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        let action = Self.chatAction()
        // The nonce is already committed by another path (the crash window
        // between COMMIT and the outbox cleanup). Replay must not start a
        // second turn.
        try await store.recordPendingAction(action)
        _ = try await store.performAndRecord(
            action: action, plan: Self.plan(eventID: "action:nonce-1"))
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [action])

        let result = try await dispatcher.dispatch(action)
        XCTAssertEqual(result, .duplicate(eventID: "action:nonce-1"))
        await assertEqualAsync(await planner.actions.count, 0)
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [])
        await assertEqualAsync(try await store.headCommitSeq(), 1)
        try await store.close()
    }

    func testQueuedDuplicateDispatchRecordsOnePendingRowAndRunsOnce() async throws {
        let store = try makeStore(now: 1_000)
        let planner = GatedPlanner()
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        let action = Self.chatAction()
        let first = Task { try await dispatcher.dispatch(action) }
        await planner.waitUntilEntered()
        // The row exists before the planner is released: this is the durable
        // point a kill would leave behind.
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [action])

        let second = Task { try await dispatcher.dispatch(action) }
        await Task.yield()
        await planner.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, .accepted(eventID: "action:nonce-1"))
        XCTAssertEqual(secondResult, .duplicate(eventID: "action:nonce-1"))
        await assertEqualAsync(await planner.calls, 1)
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [])
        await assertEqualAsync(try await store.headCommitSeq(), 1)
        try await store.close()
    }

    func testTerminalNonThrowingOutcomesClearThePendingRow() async throws {
        let store = try makeStore(now: 1_000)
        let planner = RowActionPlannerDouble()
        await planner.setOutcome(.stale(reason: "already_answered"), for: "nonce-1")
        await planner.setOutcome(.rejected(reason: "invalid_card_answer"), for: "nonce-2")
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        await assertEqualAsync(try await dispatcher.dispatch(Self.chatAction()),
                               .stale(reason: "already_answered"))
        await assertEqualAsync(try await dispatcher.dispatch(Self.chatAction(nonce: "nonce-2")),
                               .rejected(reason: "invalid_card_answer"))
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [])
        // Invalid actions were validated before the outbox write, so they leave
        // no row either.
        await assertEqualAsync(
            try await dispatcher.dispatch(Self.chatAction(nonce: "nonce-3", text: "   ")),
            .rejected(reason: "missing_text"))
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [])
        try await store.close()
    }

    func testRetryableRejectionKeepsThePendingRowForTheNextReplay() async throws {
        let store = try makeStore(now: 1_000)
        let planner = RowActionPlannerDouble()
        // A rebind reports this as a non-throwing .rejected, not a throw.
        await planner.setOutcome(.rejected(reason: "transport_replaced"), for: "nonce-1")
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        let action = Self.chatAction()
        await assertEqualAsync(try await dispatcher.dispatch(action),
                               .rejected(reason: "transport_replaced"))
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [action])
        await assertEqualAsync(
            try await store.pendingActionRecords(botID: "main").first?.attempts, 2)
        // The next replay runs the same action and only a terminal outcome
        // clears it.
        await planner.clearOutcome(for: "nonce-1")
        let replay = BotUserActionDispatcher(store: store, planner: planner)
        let pending = try await store.pendingActions(botID: "main")
        var results: [BotActionResult] = []
        for action in pending { results.append(try await replay.dispatch(action)) }
        XCTAssertEqual(results, [.accepted(eventID: "evt-2")])
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [])
        await assertEqualAsync(await planner.actions.count, 2)
        try await store.close()
    }

    func testUnknownRejectionIsRetainedFailSafe() async throws {
        let store = try makeStore(now: 1_000)
        let planner = RowActionPlannerDouble()
        await planner.setOutcome(.rejected(reason: "some_future_reason"), for: "nonce-1")
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        await assertEqualAsync(try await dispatcher.dispatch(Self.chatAction()),
                               .rejected(reason: "some_future_reason"))
        await assertEqualAsync(try await store.pendingActions(botID: "main").count, 1)
        try await store.close()
    }

    func testClassifierPinsTerminalAndRetryableReasons() {
        XCTAssertTrue(BotPendingActionOutcome.isTerminal(.accepted(eventID: "e")))
        XCTAssertTrue(BotPendingActionOutcome.isTerminal(.duplicate(eventID: "e")))
        for reason in ["card_expired", "already_answered", "card_dismissed",
                       "missing_text", "untrusted_action", "invalid_attachment",
                       "digest_mismatch", "cancelled"] {
            XCTAssertTrue(BotPendingActionOutcome.isTerminal(.rejected(reason: reason)),
                          reason)
        }
        for reason in ["transport_replaced", "turn_not_completed", "collect_idle_timeout",
                       "snapshot_timeout", "transport_timeout", "unavailable",
                       "unit_detached", "unknown_future_reason"] {
            XCTAssertFalse(BotPendingActionOutcome.isTerminal(.rejected(reason: reason)),
                           reason)
            XCTAssertFalse(BotPendingActionOutcome.isTerminal(.stale(reason: reason)),
                           reason)
        }
    }

    func testCommittedCardAnswerKeepsRowAndResumesPromptOnlyOnce() async throws {
        let store = try makeStore(now: 1_000)
        let action = BotUserAction(nonce: "nonce-1", botID: "main", kind: .cardAnswer,
                                   cardID: "card-1", optionID: "opt-1")
        try await store.recordPendingAction(action)
        // The planner pre-commits card.answered before the prompt is sent; the
        // process died before the prompt, so the nonce exists and the row stays.
        _ = try await store.performAndRecord(
            action: action, plan: Self.cardAnswerPlan(eventID: "action:nonce-1"))
        let noResumer = BotUserActionDispatcher(store: store, planner: RowActionPlannerDouble())
        await assertEqualAsync(try await noResumer.dispatch(action),
                               .duplicate(eventID: "action:nonce-1"))
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [action])

        let resumer = ResumerDouble()
        let dispatcher = BotUserActionDispatcher(store: store,
                                                 planner: RowActionPlannerDouble(),
                                                 cardAnswerPromptResumer: resumer)
        await assertEqualAsync(try await dispatcher.dispatch(action),
                               .duplicate(eventID: "action:nonce-1"))
        await assertEqualAsync(await resumer.prompts.count, 1)
        await assertEqualAsync(await resumer.prompts.first?.0, "继续")
        await assertEqualAsync(await resumer.prompts.first?.1, "nonce-1")
        await assertEqualAsync(try await store.pendingActions(botID: "main"), [])
        // The prompt is never resumed twice: no pending row, no resumer call.
        await assertEqualAsync(try await dispatcher.dispatch(action),
                               .duplicate(eventID: "action:nonce-1"))
        await assertEqualAsync(await resumer.prompts.count, 1)
        try await store.close()
    }

    // MARK: - Schema

    func testV3ToV4MigrationPreservesRowsAndAddsPendingActions() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let action = Self.chatAction(nonce: "nonce-v3")
        _ = try await store.performAndRecord(
            action: action, plan: Self.plan(eventID: "evt-v3"))
        let events = try await store.events(after: 0, limit: 10)
        try await store.close()

        // A true v3 file: no pending table, version 3.
        try RawStore.execute(
            "DROP TABLE bot_pending_actions; PRAGMA user_version=3;", at: file)
        XCTAssertEqual(try RawStore.scalar("PRAGMA user_version", at: file), "3")

        let migrated = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await migrated.events(after: 0, limit: 10), events)
        await assertEqualAsync(try await migrated.eventID(botID: "main", nonce: "nonce-v3"),
                               "evt-v3")
        await assertEqualAsync(try await migrated.pendingActions(botID: "main"), [])
        try await migrated.verifyIntegrity()
        try await migrated.close()

        XCTAssertEqual(try RawStore.scalar("PRAGMA user_version", at: file), "4")
        let columns = try RawStore.query("PRAGMA table_info('bot_pending_actions')", at: file)
        XCTAssertEqual(columns.map { $0["name"] }, ["bot_id", "nonce", "payload",
                                                   "created_at_ms", "attempts"])
        XCTAssertEqual(columns.map { $0["pk"] }, ["1", "2", "0", "0", "0"])
        XCTAssertEqual(columns.map { $0["notnull"] }, ["1", "1", "1", "1", "1"])
        XCTAssertEqual(columns.map { $0["dflt_value"] }, [nil, nil, nil, nil, "1"])

        // The v4 open is idempotent and the outbox is usable afterwards.
        let reopened = try SQLiteDomainStore(fileURL: file, now: { 3_000 })
        let pending = Self.chatAction(nonce: "nonce-after-v4")
        try await reopened.recordPendingAction(pending, now: 42)
        try await reopened.close()
        let final = try SQLiteDomainStore(fileURL: file, now: { 4_000 })
        await assertEqualAsync(try await final.pendingActions(botID: "main"), [pending])
        await assertEqualAsync(try await final.eventID(botID: "main", nonce: "nonce-v3"),
                               "evt-v3")
        try await final.close()
        XCTAssertEqual(try RawStore.scalar("PRAGMA user_version", at: file), "4")
    }

    func testCorruptPendingPayloadIsRejectedSafelyAndCanBeCleared() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        try await store.recordPendingAction(Self.chatAction(nonce: "nonce-good"), now: 1)
        try await store.recordPendingAction(Self.chatAction(nonce: "nonce-bad"), now: 2)
        try await store.close()

        try RawStore.execute(
            "UPDATE bot_pending_actions SET payload = CAST('not json' AS BLOB) WHERE nonce = 'nonce-bad'",
            at: file)
        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        do {
            _ = try await reopened.pendingActions(botID: "main")
            XCTFail("a corrupt payload must not decode")
        } catch let error as SQLiteDomainStoreError {
            guard case .corrupted(let detail) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("nonce-bad"))
            XCTAssertFalse(detail.contains("not json"))
        }
        // Rejecting the payload is not data loss: the row stays addressable,
        // the remaining rows are untouched, and the store still works.
        await assertEqualAsync(try await reopened.clearPendingAction(
            botID: "main", nonce: "nonce-bad"), true)
        await assertEqualAsync(try await reopened.pendingActions(botID: "main").map(\.nonce),
                               ["nonce-good"])
        await assertEqualAsync(try await reopened.clearPendingAction(
            botID: "main", nonce: "nonce-good"), true)
        await assertEqualAsync(try await reopened.pendingActions(botID: "main"), [])
        try await reopened.close()
    }

    // MARK: - Helpers

    private func makeStore(now: Int64 = 1_000) throws -> SQLiteDomainStore {
        try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"),
                              now: { now })
    }

    private static func chatAction(nonce: String = "nonce-1", botID: String = "main",
                                   text: String = "继续") -> BotUserAction {
        BotUserAction(nonce: nonce, botID: botID, kind: .chat, text: text)
    }

    private static func cardAnswerPlan(eventID: String) -> BotUserActionPlan {
        let event = BotEvent(
            type: "card.answered", eventId: eventID, time: 1_000,
            origin: .local(source: "card-bridge"), traceId: "trace-\(eventID)",
            principal: BotPrincipal(botId: "main", sessionId: "main", kind: "chat"),
            causationId: nil, correlationId: "nonce-1",
            data: .object([
                "cardID": .string("card-1"), "optionID": .string("opt-1"),
                "value": .string("继续"), "label": .string("继续"),
            ]))
        return BotUserActionPlan(event: event)
    }

    private static func plan(botID: String = "main", eventID: String,
                             nonce: String = "nonce-1") -> BotUserActionPlan {
        let event = BotEvent(
            type: "conversation.user_message", eventId: eventID, time: 1_000,
            origin: .local(source: "user"), traceId: "trace-\(eventID)",
            principal: BotPrincipal(botId: botID, sessionId: "main", kind: "chat"),
            causationId: nil, correlationId: nonce,
            data: .object(["text": .string("继续")]))
        return BotUserActionPlan(event: event)
    }
}

// MARK: - Planner doubles

private enum PlannerFailure: Error, Equatable {
    case offline
}

private actor ResumerDouble: BotCardAnswerPromptResuming {
    private(set) var prompts: [(String, String)] = []

    func resumeCardAnswerPrompt(text: String, nonce: String) async throws {
        prompts.append((text, nonce))
    }
}

private actor ThrowingPlanner: BotUserActionPlanning {
    private(set) var calls = 0

    func plan(_ action: BotUserAction,
              trust: BotUserActionTrust) async throws -> BotUserActionPlanOutcome {
        calls += 1
        throw PlannerFailure.offline
    }
}

/// Plans successfully once released. `waitUntilEntered` lets a test observe
/// the pending row while the turn is in flight.
private actor GatedPlanner: BotUserActionPlanning {
    private(set) var calls = 0
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func plan(_ action: BotUserAction,
              trust: BotUserActionTrust) async throws -> BotUserActionPlanOutcome {
        calls += 1
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        let event = BotEvent(
            type: "conversation.user_message", eventId: "action:\(action.nonce)", time: 1_000,
            origin: .local(source: "user"), traceId: "action:\(action.nonce)",
            principal: BotPrincipal(botId: action.botID, sessionId: "main", kind: "chat"),
            causationId: nil, correlationId: action.nonce,
            data: .object(["text": .string(action.text ?? "")]))
        return .commit(BotUserActionPlan(event: event))
    }
}

// MARK: - Raw SQLite probe

private struct RawStoreError: Error {
    let message: String
}

private enum RawStore {
    static func execute(_ sql: String, at file: URL) throws {
        let database = try open(file)
        defer { sqlite3_close(database) }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite \(result)"
            sqlite3_free(error)
            throw RawStoreError(message: message)
        }
    }

    static func scalar(_ sql: String, at file: URL) throws -> String? {
        try query(sql, at: file).first?.values.first
    }

    static func query(_ sql: String, at file: URL) throws -> [[String: String]] {
        let database = try open(file)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RawStoreError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw RawStoreError(message: String(cString: sqlite3_errmsg(database)))
            }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column\(index)"
                if sqlite3_column_type(statement, index) != SQLITE_NULL {
                    row[name] = sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
                }
            }
            rows.append(row)
        }
    }

    private static func open(_ file: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "SQLite open failed"
            if let database { sqlite3_close(database) }
            throw RawStoreError(message: message)
        }
        sqlite3_busy_timeout(database, 5_000)
        return database
    }
}

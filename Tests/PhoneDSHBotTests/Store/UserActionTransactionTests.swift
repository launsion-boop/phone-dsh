// SPDX-License-Identifier: MIT

import SQLite3
import XCTest
@testable import PhoneDSHBot

final class UserActionTransactionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-transactions-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSchemaV1MigratesInPlacePreservingEventsEffectsAndSequence() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        _ = try await store.append(Self.event(id: "evt-v1-first"))
        _ = try await store.enqueue(Self.effect(key: "fx-v1"))
        _ = try await store.append(Self.event(id: "evt-v1-last"))
        let originalEvents = try await store.events(after: 0, limit: 10)
        let originalEffect = try await store.effect("fx-v1")
        XCTAssertEqual(originalEvents.map(\.commitSeq), [1, 2, 3])
        XCTAssertEqual(originalEffect?.enqueuedCommitSeq, 2)
        try await store.close()

        try SQLiteProbe.execute(
            "DROP TABLE bot_user_action_nonces; PRAGMA user_version=1;", at: file)
        XCTAssertEqual(try SQLiteProbe.scalar("PRAGMA user_version", at: file), "1")
        let v1Tables = try SQLiteProbe.query(
            """
            SELECT name, sql FROM sqlite_master
            WHERE name IN ('bot_events', 'bot_effects', 'bot_effect_inbox') ORDER BY name
            """, at: file)

        let migrated = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await migrated.events(after: 0, limit: 10), originalEvents)
        await assertEqualAsync(try await migrated.effect("fx-v1"), originalEffect)
        await assertEqualAsync(try await migrated.headCommitSeq(), 3)
        try await migrated.verifyIntegrity()

        let action = Self.action()
        let result = try await migrated.performAndRecord(
            action: action, plan: Self.plan(eventID: "evt-after-migration"))
        XCTAssertEqual(result, .accepted(eventID: "evt-after-migration"))
        await assertEqualAsync(try await migrated.headCommitSeq(), 4)
        await assertEqualAsync(
            try await migrated.eventID(botID: action.botID, nonce: action.nonce), "evt-after-migration")
        try await migrated.close()

        XCTAssertEqual(try SQLiteProbe.scalar("PRAGMA user_version", at: file), "2")
        let migratedTables = try SQLiteProbe.query(
            """
            SELECT name, sql FROM sqlite_master
            WHERE name IN ('bot_events', 'bot_effects', 'bot_effect_inbox') ORDER BY name
            """, at: file)
        XCTAssertEqual(migratedTables, v1Tables)
        let columns = try SQLiteProbe.query("PRAGMA table_info('bot_user_action_nonces')", at: file)
        XCTAssertEqual(columns.map { $0["name"] }, ["bot_id", "nonce", "event_id", "created_commit_seq"])
        XCTAssertEqual(columns.map { $0["pk"] }, ["1", "2", "0", "0"])
        let indexes = try SQLiteProbe.query("PRAGMA index_list('bot_user_action_nonces')", at: file)
        XCTAssertEqual(indexes.filter { $0["unique"] == "1" }.count, 2)
        let foreignKeys = try SQLiteProbe.query("PRAGMA foreign_key_list('bot_user_action_nonces')", at: file)
        XCTAssertEqual(foreignKeys.count, 1)
        XCTAssertEqual(foreignKeys[0]["table"], "bot_events")
        XCTAssertEqual(foreignKeys[0]["from"], "event_id")
        XCTAssertEqual(foreignKeys[0]["to"], "event_id")
        XCTAssertEqual(try SQLiteProbe.scalar(
            "SELECT created_commit_seq FROM bot_user_action_nonces WHERE bot_id = 'main' AND nonce = 'nonce-1'",
            at: file), "4")
    }

    func testFutureSchemaVersionIsRejectedWithoutChangingData() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        _ = try await store.append(Self.event(id: "evt-future"))
        try await store.close()
        try SQLiteProbe.execute("PRAGMA user_version=3", at: file)

        XCTAssertThrowsError(try SQLiteDomainStore(fileURL: file)) { error in
            XCTAssertEqual(error as? SQLiteDomainStoreError, .schemaTooNew(3))
        }
        XCTAssertEqual(try SQLiteProbe.scalar("PRAGMA user_version", at: file), "3")
        XCTAssertEqual(try SQLiteProbe.scalar("SELECT COUNT(*) FROM bot_events", at: file), "1")
    }

    func testEventEffectsAndNonceCommitAtomicallyAndReplayOriginalEventID() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let action = Self.action()
        let effects = [Self.effect(key: "fx-action-1"), Self.effect(key: "fx-action-2")]
        let plan = Self.plan(eventID: "evt-action", effects: effects)
        await assertEqualAsync(try await store.performAndRecord(action: action, plan: plan),
                       .accepted(eventID: "evt-action"))

        let events = try await store.events(after: 0, limit: 10)
        XCTAssertEqual(events.map(\.eventId), ["evt-action", events[1].eventId, events[2].eventId])
        XCTAssertEqual(events.map(\.commitSeq), [1, 2, 3])
        XCTAssertEqual(events.map(\.type), ["conversation.user_message", "effect.enqueued", "effect.enqueued"])
        let records = try await store.effects()
        XCTAssertEqual(records.map(\.effectKey), ["fx-action-1", "fx-action-2"])
        XCTAssertEqual(records.map(\.state), [.pending, .pending])
        XCTAssertEqual(records.map(\.enqueuedCommitSeq), [2, 3])
        await assertEqualAsync(try await store.eventID(botID: "main", nonce: "nonce-1"), "evt-action")

        let changedPlan = Self.plan(eventID: "evt-must-not-win", effects: [Self.effect(key: "fx-must-not-run")])
        await assertEqualAsync(try await store.performAndRecord(action: action, plan: changedPlan),
                       .duplicate(eventID: "evt-action"))
        await assertNilAsync(try await store.event(withId: "evt-must-not-win"))
        await assertNilAsync(try await store.effect("fx-must-not-run"))
        await assertEqualAsync(try await store.headCommitSeq(), 3)
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.performAndRecord(action: action, plan: changedPlan),
                       .duplicate(eventID: "evt-action"))
        await assertEqualAsync(try await reopened.headCommitSeq(), 3)
        await assertEqualAsync(try await reopened.effects().map(\.effectKey), ["fx-action-1", "fx-action-2"])
        try await reopened.verifyIntegrity()
        try await reopened.close()
        XCTAssertEqual(try SQLiteProbe.scalar(
            "SELECT created_commit_seq FROM bot_user_action_nonces WHERE bot_id = 'main' AND nonce = 'nonce-1'",
            at: file), "1")
    }

    func testBeforeCommitCrashRollsBackEventEffectsAndNonceThenAllowsRetry() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        _ = try await store.append(Self.event(id: "evt-seed"))
        await store.armCrashPoint("abort-before-commit")
        let action = Self.action()
        let plan = Self.plan(eventID: "evt-interrupted", effects: [Self.effect(key: "fx-interrupted")])
        do {
            _ = try await store.performAndRecord(action: action, plan: plan)
            XCTFail("injected crash must fail the action transaction")
        } catch {
            XCTAssertEqual(error as? SQLiteDomainStoreError, .simulatedCrash("abort-before-commit"))
        }
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.headCommitSeq(), 1)
        await assertNilAsync(try await reopened.event(withId: "evt-interrupted"))
        await assertNilAsync(try await reopened.effect("fx-interrupted"))
        await assertNilAsync(try await reopened.eventID(botID: action.botID, nonce: action.nonce))

        await assertEqualAsync(try await reopened.performAndRecord(action: action, plan: plan),
                       .accepted(eventID: "evt-interrupted"))
        await assertEqualAsync(try await reopened.event(withId: "evt-interrupted")?.commitSeq, 2)
        await assertEqualAsync(try await reopened.effect("fx-interrupted")?.enqueuedCommitSeq, 3)
        await assertEqualAsync(try await reopened.performAndRecord(action: action, plan: plan),
                       .duplicate(eventID: "evt-interrupted"))
        try await reopened.verifyIntegrity()
        try await reopened.close()
    }

    func testAfterCommitCrashReplaysAsDuplicateWithoutSecondEffect() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let action = Self.action()
        let plan = Self.plan(eventID: "evt-after-commit", effects: [Self.effect(key: "fx-after-commit")])
        await store.armCrashPoint("abort-after-commit")
        do {
            _ = try await store.performAndRecord(action: action, plan: plan)
            XCTFail("injected crash must fail after the durable commit")
        } catch {
            XCTAssertEqual(error as? SQLiteDomainStoreError, .simulatedCrash("abort-after-commit"))
        }
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.headCommitSeq(), 2)
        await assertEqualAsync(try await reopened.event(withId: "evt-after-commit")?.commitSeq, 1)
        await assertEqualAsync(try await reopened.effect("fx-after-commit")?.enqueuedCommitSeq, 2)
        await assertEqualAsync(
            try await reopened.eventID(botID: action.botID, nonce: action.nonce), "evt-after-commit")
        await assertEqualAsync(try await reopened.performAndRecord(action: action, plan: plan),
                               .duplicate(eventID: "evt-after-commit"))
        await assertEqualAsync(try await reopened.headCommitSeq(), 2)
        await assertEqualAsync(try await reopened.effects().count, 1)
        try await reopened.verifyIntegrity()
        try await reopened.close()
    }

    func testDispatcherCrashAfterPlanReopensWithoutConsumingAction() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let planner = RowActionPlannerDouble()
        await planner.setEventID("evt-after-plan", for: "nonce-1")
        let dispatcher = BotUserActionDispatcher(store: store, planner: planner)
        let action = Self.action()
        await store.armCrashPoint("abort-after-plan")
        do {
            _ = try await dispatcher.dispatch(action)
            XCTFail("injected crash must fail after planning")
        } catch {
            XCTAssertEqual(error as? SQLiteDomainStoreError, .simulatedCrash("abort-after-plan"))
        }
        await assertEqualAsync(await planner.actions.count, 1)
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.headCommitSeq(), 0)
        await assertNilAsync(try await reopened.event(withId: "evt-after-plan"))
        await assertNilAsync(try await reopened.eventID(botID: action.botID, nonce: action.nonce))
        let retryDispatcher = BotUserActionDispatcher(store: reopened, planner: planner)
        await assertEqualAsync(try await retryDispatcher.dispatch(action), .accepted(eventID: "evt-after-plan"))
        await assertEqualAsync(try await retryDispatcher.dispatch(action), .duplicate(eventID: "evt-after-plan"))
        await assertEqualAsync(await planner.actions.count, 2)
        try await reopened.close()
    }

    func testConcurrentConnectionsSerializeToOneCommitAndPersistentDuplicates() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let first = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let second = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let action = Self.action()
        let plan = Self.plan(eventID: "evt-concurrent", effects: [Self.effect(key: "fx-concurrent")])
        let results = try await withThrowingTaskGroup(of: BotActionResult.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let store = index.isMultiple(of: 2) ? first : second
                    return try await store.performAndRecord(action: action, plan: plan)
                }
            }
            var results: [BotActionResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.filter { $0 == .accepted(eventID: "evt-concurrent") }.count, 1)
        XCTAssertEqual(results.filter { $0 == .duplicate(eventID: "evt-concurrent") }.count, 39)
        await assertEqualAsync(try await first.headCommitSeq(), 2)
        await assertEqualAsync(try await first.effects().map(\.effectKey), ["fx-concurrent"])
        await assertEqualAsync(try await second.eventID(botID: "main", nonce: "nonce-1"), "evt-concurrent")
        try await first.close()
        try await second.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let events = try await reopened.events(after: 0, limit: 10)
        XCTAssertEqual(events.map(\.commitSeq), [1, 2])
        XCTAssertEqual(events.first?.eventId, "evt-concurrent")
        await assertEqualAsync(try await reopened.performAndRecord(action: action, plan: plan),
                       .duplicate(eventID: "evt-concurrent"))
        try await reopened.close()
    }

    func testEventIDConflictFailsClosedWithoutConsumingSecondNonce() async throws {
        let store = try makeStore()
        let firstAction = Self.action(nonce: "first")
        await assertEqualAsync(try await store.performAndRecord(
            action: firstAction,
            plan: Self.plan(eventID: "evt-shared", effects: [Self.effect(key: "fx-first")])),
            .accepted(eventID: "evt-shared"))
        let secondAction = Self.action(nonce: "second")
        do {
            _ = try await store.performAndRecord(
                action: secondAction,
                plan: Self.plan(eventID: "evt-shared", effects: [Self.effect(key: "fx-second")]))
            XCTFail("an existing eventID must not be rebound to another nonce")
        } catch {
            guard case .invalidTransition = error as? SQLiteDomainStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        await assertEqualAsync(try await store.headCommitSeq(), 2)
        await assertNilAsync(try await store.effect("fx-second"))
        await assertNilAsync(try await store.eventID(botID: "main", nonce: "second"))
        await assertEqualAsync(try await store.eventID(botID: "main", nonce: "first"), "evt-shared")
        await assertEqualAsync(try await store.performAndRecord(
            action: firstAction, plan: Self.plan(eventID: "evt-different")),
            .duplicate(eventID: "evt-shared"))
        try await store.close()
    }

    func testSameNonceIsIsolatedByBotAcrossReopen() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let first = Self.action(botID: "bot-a")
        let second = Self.action(botID: "bot-b")
        await assertEqualAsync(try await store.performAndRecord(
            action: first, plan: Self.plan(botID: "bot-a", eventID: "evt-bot-a")),
            .accepted(eventID: "evt-bot-a"))
        await assertEqualAsync(try await store.performAndRecord(
            action: second, plan: Self.plan(botID: "bot-b", eventID: "evt-bot-b")),
            .accepted(eventID: "evt-bot-b"))
        await assertEqualAsync(try await store.eventID(botID: "bot-a", nonce: "nonce-1"), "evt-bot-a")
        await assertEqualAsync(try await store.eventID(botID: "bot-b", nonce: "nonce-1"), "evt-bot-b")
        await assertNilAsync(try await store.eventID(botID: "bot-c", nonce: "nonce-1"))
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.performAndRecord(
            action: first, plan: Self.plan(botID: "bot-a", eventID: "evt-replacement-a")),
            .duplicate(eventID: "evt-bot-a"))
        await assertEqualAsync(try await reopened.performAndRecord(
            action: second, plan: Self.plan(botID: "bot-b", eventID: "evt-replacement-b")),
            .duplicate(eventID: "evt-bot-b"))
        await assertEqualAsync(try await reopened.headCommitSeq(), 2)
        try await reopened.close()
    }

    private func makeStore() throws -> SQLiteDomainStore {
        try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    }

    private static func action(botID: String = "main", nonce: String = "nonce-1") -> BotUserAction {
        BotUserAction(nonce: nonce, botID: botID, kind: .chat, text: "继续")
    }

    private static func plan(
        botID: String = "main",
        eventID: String,
        effects: [BotEffect] = []
    ) -> BotUserActionPlan {
        let event = BotEvent(
            type: "conversation.user_message", eventId: eventID, time: 1_000,
            origin: .local(source: "user"), traceId: "trace-\(eventID)",
            principal: BotPrincipal(botId: botID, sessionId: "main", kind: "chat"),
            causationId: nil, correlationId: "nonce-1",
            data: .object(["text": .string("继续")]))
        return BotUserActionPlan(event: event, effects: effects)
    }

    private static func event(id: String) -> BotEvent {
        BotEvent(
            type: "ui.notice", eventId: id, time: 1_000, origin: .local(source: "user"),
            traceId: "trace-\(id)", principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
            causationId: nil, correlationId: nil, data: .object(["text": .string(id)]))
    }

    private static func effect(key: String) -> BotEffect {
        BotEffect(
            effectKey: key, kind: "test", operation: "notify", target: "row-1",
            canonicalResource: "row-1", argsDigest: "args-\(key)", logicalKey: key,
            idempotent: true)
    }
}

private struct SQLiteProbeError: Error {
    let message: String
}

private enum SQLiteProbe {
    static func execute(_ sql: String, at file: URL) throws {
        let database = try open(file)
        defer { sqlite3_close(database) }
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite \(result)"
            sqlite3_free(error)
            throw SQLiteProbeError(message: message)
        }
    }

    static func scalar(_ sql: String, at file: URL) throws -> String? {
        try query(sql, at: file).first?.values.first
    }

    static func query(_ sql: String, at file: URL) throws -> [[String: String]] {
        let database = try open(file)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw SQLiteProbeError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw SQLiteProbeError(message: String(cString: sqlite3_errmsg(database)))
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
            throw SQLiteProbeError(message: message)
        }
        sqlite3_busy_timeout(database, 5_000)
        return database
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class SQLiteDomainStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testAppendDeduplicatesAndContinuesWithoutGapsAfterReopen() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        for index in 1...250 {
            let event = Self.makeEvent(id: "evt-\(index)")
            await assertEqualAsync(try await store.append(event), index)
            await assertEqualAsync(try await store.append(event), index)
        }
        await assertEqualAsync(try await store.headCommitSeq(), 250)
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let events = try await reopened.events(after: 0, limit: 300)
        XCTAssertEqual(events.count, 250)
        XCTAssertEqual(events.map(\.commitSeq), (1...250).map(Optional.some))
        XCTAssertEqual(events.map(\.eventId), (1...250).map { "evt-\($0)" })
        await assertEqualAsync(try await reopened.append(Self.makeEvent(id: "evt-1")), 1)
        await assertEqualAsync(try await reopened.append(Self.makeEvent(id: "evt-251")), 251)
        try await reopened.verifyIntegrity()
        try await reopened.close()
    }

    func testAtomicBatchAssignsContiguousSequenceAndBatchReferences() async throws {
        let store = try makeStore()
        let sequences = try await store.appendBatch([
            Self.makeEvent(id: "evt-batch-1"), Self.makeEvent(id: "evt-batch-2"),
        ])
        XCTAssertEqual(sequences, [1, 2])
        let events = try await store.events(after: 0, limit: 2)
        XCTAssertEqual(events[0].batch?.index, 0)
        XCTAssertEqual(events[1].batch?.index, 1)
        XCTAssertEqual(events[0].batch?.total, 2)
        XCTAssertEqual(events[0].batch?.id, events[1].batch?.id)
        try await store.close()
    }

    func testCrashBeforeCommitRollsBackWithoutGapOrDuplicate() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        await assertEqualAsync(try await store.append(Self.makeEvent(id: "evt-committed")), 1)
        await store.armCrashPoint("abort-before-commit")
        do {
            _ = try await store.append(Self.makeEvent(id: "evt-interrupted"))
            XCTFail("injected crash must fail the append")
        } catch {
            XCTAssertEqual(error as? SQLiteDomainStoreError, .simulatedCrash("abort-before-commit"))
        }
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.headCommitSeq(), 1)
        await assertNilAsync(try await reopened.event(withId: "evt-interrupted"))
        await assertEqualAsync(try await reopened.append(Self.makeEvent(id: "evt-interrupted")), 2)
        await assertEqualAsync(try await reopened.append(Self.makeEvent(id: "evt-committed")), 1)
        let events = try await reopened.events(after: 0, limit: 10)
        XCTAssertEqual(events.map(\.commitSeq), [1, 2])
        XCTAssertEqual(Set(events.map(\.eventId)).count, 2)
        try await reopened.close()
    }

    func testIndependentConnectionsSerializeSequenceAllocation() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let first = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let second = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let sequences = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 1...60 {
                group.addTask {
                    let store = index.isMultiple(of: 2) ? first : second
                    return try await store.append(Self.makeEvent(id: "evt-concurrent-\(index)"))
                }
            }
            var values: [Int] = []
            for try await sequence in group { values.append(sequence) }
            return values.sorted()
        }
        XCTAssertEqual(sequences, Array(1...60))
        try await first.close()
        try await second.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let events = try await reopened.events(after: 0, limit: 100)
        XCTAssertEqual(events.count, 60)
        XCTAssertEqual(Set(events.map(\.eventId)).count, 60)
        try await reopened.close()
    }

    func testEphemeralEventsStayBoundedAndNeverConsumeDurableSequence() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 }, ephemeralCapacity: 2)
        for index in 1...3 {
            await assertEqualAsync(try await store.append(Self.makeEvent(id: "delta-\(index)", type: "model.delta")), 0)
        }
        await assertEqualAsync(try await store.headCommitSeq(), 0)
        await assertEqualAsync(try await store.droppedEphemeralCount(), 1)
        await assertEqualAsync(try await store.ephemeralEvents().map(\.eventId), ["delta-2", "delta-3"])
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        await assertEqualAsync(try await reopened.events(after: 0, limit: 10), [])
        await assertEqualAsync(try await reopened.ephemeralEvents(), [])
        try await reopened.close()
    }

    func testDatabaseAndWALFilesHavePrivatePermissions() async throws {
        let store = try makeStore()
        _ = try await store.append(Self.makeEvent(id: "evt-permissions"))
        let manager = FileManager.default
        let directoryMode = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let databaseMode = try manager.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode.map { $0.intValue & 0o777 }, 0o700)
        XCTAssertEqual(databaseMode.map { $0.intValue & 0o777 }, 0o600)
        let walURL = URL(fileURLWithPath: store.fileURL.path + "-wal")
        if manager.fileExists(atPath: walURL.path) {
            let mode = try manager.attributesOfItem(atPath: walURL.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode.map { $0.intValue & 0o777 }, 0o600)
        }
        try await store.close()
    }

    func testOpenVerifiesOnlyRowsAboveThePersistedWatermark() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let store = try SQLiteDomainStore(fileURL: file, now: { 1_000 },
                                          startsBackgroundIntegrityCheck: false)
        let firstQuickChecks = await store.quickCheckCountForTesting()
        XCTAssertEqual(firstQuickChecks, 1)
        for index in 1...3 {
            _ = try await store.append(Self.makeEvent(id: "evt-\(index)"))
        }
        // Appends are verified by the next open or the background pass, not by
        // every commit.
        let initialWatermark = try await store.integrityWatermarkForTesting()
        XCTAssertEqual(initialWatermark, 0)
        try await store.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 },
                                             startsBackgroundIntegrityCheck: false)
        let reopenedWatermark = try await reopened.integrityWatermarkForTesting()
        XCTAssertEqual(reopenedWatermark, 3)
        let reopenedQuickChecks = await reopened.quickCheckCountForTesting()
        XCTAssertEqual(reopenedQuickChecks, 1)
        _ = try await reopened.append(Self.makeEvent(id: "evt-4"))
        _ = try await reopened.append(Self.makeEvent(id: "evt-5"))
        let afterAppends = try await reopened.integrityWatermarkForTesting()
        XCTAssertEqual(afterAppends, 3,
                       "the watermark advances only when a verification pass runs")
        try await reopened.close()

        let incremental = try SQLiteDomainStore(fileURL: file, now: { 3_000 },
                                                startsBackgroundIntegrityCheck: false)
        let incrementalWatermark = try await incremental.integrityWatermarkForTesting()
        XCTAssertEqual(incrementalWatermark, 5)
        try await incremental.verifyIntegrity()
        let verifiedWatermark = try await incremental.integrityWatermarkForTesting()
        XCTAssertEqual(verifiedWatermark, 5)
        try await incremental.close()
    }

    func testPreparedStatementsAreCachedAcrossCommits() async throws {
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"),
            now: { 1_000 }, startsBackgroundIntegrityCheck: false)
        for index in 1...40 {
            _ = try await store.append(Self.makeEvent(id: "evt-\(index)"))
        }
        let first = await store.preparedStatementStatsForTesting()
        XCTAssertGreaterThan(first.hits, 30)
        XCTAssertLessThan(first.prepares, 20,
                          "one prepare per distinct statement, not per call")
        for index in 41...80 {
            _ = try await store.append(Self.makeEvent(id: "evt-\(index)"))
        }
        let second = await store.preparedStatementStatsForTesting()
        XCTAssertEqual(second.prepares, first.prepares)
        XCTAssertGreaterThan(second.hits, first.hits)
        try await store.close()
    }

    func testFileAttributesAreAppliedOncePerPathNotOnEveryCommit() async throws {
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"),
            now: { 1_000 }, startsBackgroundIntegrityCheck: false)
        for index in 1...20 {
            _ = try await store.append(Self.makeEvent(id: "evt-\(index)"))
        }
        let first = await store.fileAttributeApplyCountForTesting()
        XCTAssertLessThanOrEqual(first, 3,
                                 "database, WAL and SHM are each attributed once")
        for index in 21...40 {
            _ = try await store.append(Self.makeEvent(id: "evt-\(index)"))
        }
        let second = await store.fileAttributeApplyCountForTesting()
        XCTAssertEqual(second, first)
        try await store.close()
    }

    func testDeferredFullVerificationCompletesTheWatermark() async throws {
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"),
            now: { 1_000 }, startsBackgroundIntegrityCheck: false)
        _ = try await store.append(Self.makeEvent(id: "evt-full-1"))
        _ = try await store.append(Self.makeEvent(id: "evt-full-2"))
        let beforeFull = try await store.integrityWatermarkForTesting()
        XCTAssertEqual(beforeFull, 0)
        try await store.runFullIntegrityVerificationForTesting()
        let afterFull = try await store.integrityWatermarkForTesting()
        XCTAssertEqual(afterFull, 2)
        try await store.close()
    }

    func testMigrationGapRollsBackLeavesV2AndNamesTheFirstGap() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("domain.sqlite")
        try VectorSQLite.exec(
            """
            CREATE TABLE bot_events (
                commit_seq INTEGER PRIMARY KEY CHECK (commit_seq > 0),
                event_id TEXT NOT NULL UNIQUE,
                event_type TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE TABLE bot_user_action_nonces (
                bot_id TEXT NOT NULL,
                nonce TEXT NOT NULL,
                event_id TEXT NOT NULL UNIQUE REFERENCES bot_events(event_id),
                created_commit_seq INTEGER NOT NULL CHECK (created_commit_seq > 0),
                PRIMARY KEY(bot_id, nonce)
            );
            INSERT INTO bot_events VALUES (1, 'gap-1', 'ui.notice', X'7B7D');
            INSERT INTO bot_events VALUES (3, 'gap-3', 'ui.notice', X'7B7D');
            PRAGMA user_version=2;
            """,
            at: file)
        do {
            _ = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
            XCTFail("a gapped v2 file must not open")
        } catch let error as SQLiteDomainStoreError {
            guard case let .corrupted(detail) = error else {
                return XCTFail("expected corrupted, got \(error)")
            }
            XCTAssertTrue(detail.contains("expected 2"), detail)
            XCTAssertTrue(detail.contains("found 3"), detail)
        }
        XCTAssertEqual(try VectorSQLite.query("PRAGMA user_version", at: file).first?.first as? String, "2")
        XCTAssertEqual(
            try VectorSQLite.query("SELECT type FROM sqlite_master WHERE name = 'bot_events'", at: file)
                .first?.first as? String,
            "table")
        XCTAssertEqual(try VectorSQLite.query("SELECT COUNT(*) FROM bot_events", at: file).first?.first as? String, "2")
    }

    func testReleaseUsesTheSameRetryDelayAsFailAndReturnsToPending() async throws {
        let store = try makeStore()
        for key in ["fx-a", "fx-b"] {
            _ = try await store.enqueue(BotEffect(
                effectKey: key, kind: "routine-delivery", operation: "routine.deliver",
                canonicalResource: key, argsDigest: "args-digest", logicalKey: key,
                idempotent: true, retryPolicy: "network-idempotent", maxAttempts: 5))
        }
        let firstLease = try await store.lease(owner: "owner", now: 1_000)
        let secondLease = try await store.lease(owner: "owner", now: 1_000)
        let failedLease = try XCTUnwrap(firstLease)
        let releasedLease = try XCTUnwrap(secondLease)
        XCTAssertEqual(failedLease.effectKey, "fx-a")
        XCTAssertEqual(releasedLease.effectKey, "fx-b")

        let headBeforeRelease = try await store.headCommitSeq()
        try await store.fail(failedLease, errorClass: "transient", reason: "503")
        _ = try await store.release(releasedLease)
        let failedRecord = try await store.effect("fx-a")
        let releasedRecord = try await store.effect("fx-b")
        let failed = try XCTUnwrap(failedRecord)
        let released = try XCTUnwrap(releasedRecord)
        XCTAssertEqual(released.state, .pending)
        XCTAssertEqual(released.attempt, 1)
        XCTAssertEqual(released.attempts, 1)
        XCTAssertEqual(released.lastError, "no registered executor")
        XCTAssertNil(released.leaseOwner)
        XCTAssertEqual(released.effect.notBefore, 2_000)
        XCTAssertEqual(released.effect.notBefore, failed.effect.notBefore)
        let headAfterRelease = try await store.headCommitSeq()
        XCTAssertEqual(headAfterRelease, headBeforeRelease + 1)

        // Attempt 2 doubles the network-idempotent delay in both paths.
        let firstLease2 = try await store.lease(owner: "owner", now: 2_000)
        let secondLease2 = try await store.lease(owner: "owner", now: 2_000)
        let failedLease2 = try XCTUnwrap(firstLease2)
        let releasedLease2 = try XCTUnwrap(secondLease2)
        try await store.fail(failedLease2, errorClass: "transient", reason: "503")
        _ = try await store.release(releasedLease2)
        let failedRecord2 = try await store.effect("fx-a")
        let releasedRecord2 = try await store.effect("fx-b")
        let failed2 = try XCTUnwrap(failedRecord2)
        let released2 = try XCTUnwrap(releasedRecord2)
        XCTAssertEqual(released2.state, .pending)
        XCTAssertEqual(released2.attempt, 2)
        XCTAssertEqual(released2.attempts, 2)
        XCTAssertEqual(released2.effect.notBefore, 3_000)
        XCTAssertEqual(released2.effect.notBefore, failed2.effect.notBefore)
        try await store.close()
    }

    private func makeStore() throws -> SQLiteDomainStore {
        try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    }

    private static func makeEvent(id: String, type: String = "ui.notice") -> BotEvent {
        BotEvent(
            type: type, eventId: id, time: 1_000, origin: .local(source: "user"), traceId: "trace-\(id)",
            principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
            causationId: nil, correlationId: nil,
            data: .object(["entryId": .string("entry-\(id)"), "text": .string(id)]))
    }
}

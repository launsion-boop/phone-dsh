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

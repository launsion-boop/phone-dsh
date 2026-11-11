// SPDX-License-Identifier: MIT
// JournalLog and LogQuota: two ack levels, persistence and fail-loud quotas.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class JournalAndQuotaTests: XCTestCase {
    private func journalBody(_ jseq: UInt64, session: String,
                             record: String = "record") -> JournalBody {
        JournalBody(jseq: jseq, sessionID: session, record: Data(record.utf8))
    }

    func testJournalAppendsPersistsAndEmitsTwoAckLevels() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let bootID = LogTestSupport.bootID()
        let journal = try JournalLog(configuration: configuration, bootID: bootID)
        let collector = AckCollector(journal.acks())

        let first = try await journal.append(journalBody(1, session: "session-a"))
        let second = try await journal.append(journalBody(1, session: "session-b"))
        XCTAssertEqual([first, second], [1, 1])
        let levelOne = await collector.waitForCount(2)
        XCTAssertEqual(levelOne.map(\.level), [.write, .write])

        let close = try await journal.closeEpoch()
        XCTAssertEqual(close.count, 2)
        XCTAssertTrue(close.allSatisfy { $0.level == .epochFsync })
        let all = await collector.waitForCount(4)
        XCTAssertEqual(all.filter { $0.level == .epochFsync }.count, 2)

        // A new journal instance rebuilds the per-session high-water marks.
        let reopened = try JournalLog(configuration: configuration, bootID: bootID)
        let lastA = await reopened.lastJseq(sessionID: "session-a")
        let lastB = await reopened.lastJseq(sessionID: "session-b")
        XCTAssertEqual(lastA, 1)
        XCTAssertEqual(lastB, 1)
        let size = await reopened.sizeInBytes()
        XCTAssertGreaterThan(size, 0)
    }

    func testJournalDeduplicatesBySessionAndJseq() async throws {
        let root = LogTestSupport.root(for: self)
        let journal = try JournalLog(configuration: LogTestSupport.configuration(root: root),
                                     bootID: LogTestSupport.bootID())
        _ = try await journal.append(journalBody(2, session: "s"))
        let before = await journal.sizeInBytes()
        let replay = try await journal.append(journalBody(2, session: "s"))
        XCTAssertEqual(replay, 2)
        let after = await journal.sizeInBytes()
        XCTAssertEqual(before, after, "a duplicate (session_id, jseq) is not appended twice")
        let reopened = try JournalLog(configuration: LogTestSupport.configuration(root: root),
                                      bootID: LogTestSupport.bootID())
        let last = await reopened.lastJseq(sessionID: "s")
        XCTAssertEqual(last, 2)
    }

    func testValidatedRecoveredSnapshotRetainsBodiesForProjectionReplay() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let journal = try JournalLog(configuration: configuration,
                                     bootID: LogTestSupport.bootID())
        let dispatched = journalBody(1, session: "s",
                                      record: "{\"type\":\"dispatched\",\"key\":\"xl1-11111111111111111111111111111111\"}")
        _ = try await journal.append(dispatched)
        let reopened = try JournalLog(configuration: configuration,
                                      bootID: LogTestSupport.bootID())
        let recovered = await reopened.recoveredSnapshot()
        XCTAssertEqual(recovered, [dispatched])
    }

    func testJournalQuotaExceededFailsLoud() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root, journalQuotaBytes: 200)
        let journal = try JournalLog(configuration: configuration, bootID: LogTestSupport.bootID())
        _ = try await journal.append(journalBody(1, session: "s",
                                                 record: String(repeating: "x", count: 100)))
        do {
            _ = try await journal.append(journalBody(2, session: "s",
                                                     record: String(repeating: "y", count: 100)))
            XCTFail("expected quotaExceeded")
        } catch let error as LogError {
            guard case .quotaExceeded(let resource, let limit, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(resource, .journal)
            XCTAssertEqual(limit, 200)
        }
    }

    private func stepRecord(_ type: String, key: String) -> Data {
        Data(("{\"v\":1,\"type\":\"\(type)\",\"key\":\"\(key)\",\"call_id\":\"call-\(key)\"," +
              "\"tool\":\"bash\"}")
            .utf8)
    }

    private let keyA = "xl1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let keyB = "xl1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    func testCompletedDurableJournalEntriesArePrunedAfterEpochClose() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let journal = try JournalLog(configuration: configuration,
                                     bootID: LogTestSupport.bootID())
        _ = try await journal.append(JournalBody(
            jseq: 1, sessionID: "s", record: stepRecord("dispatched", key: keyA)))
        _ = try await journal.append(JournalBody(
            jseq: 2, sessionID: "s", record: stepRecord("dispatched", key: keyB)))
        _ = try await journal.append(JournalBody(
            jseq: 3, sessionID: "s", record: stepRecord("completed", key: keyA)))

        // Level 2 has not run: a completed record is not yet discardable.
        let pending = await journal.recoveredSnapshot()
        XCTAssertEqual(pending.map(\.jseq), [1, 2, 3])

        _ = try await journal.closeEpoch()
        let pruned = await journal.recoveredSnapshot()
        XCTAssertEqual(pruned.map(\.jseq), [2, 3],
                       "the open step and one high-water entry per session survive")
        XCTAssertEqual(pruned.map(\.sessionID), ["s"])
        let highWater = await journal.lastJseq(sessionID: "s")
        XCTAssertEqual(highWater, 3, "jseq is never reused or rewound")

        // The atomic rewrite leaves no temporary file and a reopen reads the
        // pruned file.
        let temporary = WorkspacePaths(root: root).journalURL.path + ".tmp"
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary))
        let reopened = try JournalLog(configuration: configuration,
                                      bootID: LogTestSupport.bootID())
        let reopenedBodies = await reopened.recoveredSnapshot()
        XCTAssertEqual(reopenedBodies.map(\.jseq), [2, 3])

        // A later append continues at the high-water mark.
        _ = try await reopened.append(JournalBody(
            jseq: 4, sessionID: "s", record: stepRecord("dispatched", key: keyB)))
        let afterAppend = await reopened.recoveredSnapshot()
        XCTAssertEqual(afterAppend.map(\.jseq), [2, 3, 4])
    }

    func testJournalPruneKeepsStepsWithoutCompletedRecordAndTornTail() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let journal = try JournalLog(configuration: configuration,
                                     bootID: LogTestSupport.bootID())
        _ = try await journal.append(JournalBody(
            jseq: 1, sessionID: "s", record: stepRecord("dispatched", key: keyA)))
        _ = try await journal.append(JournalBody(
            jseq: 2, sessionID: "s", record: stepRecord("completed", key: keyA)))
        _ = try await journal.append(JournalBody(
            jseq: 3, sessionID: "s", record: stepRecord("dispatched", key: keyB)))
        _ = try await journal.closeEpoch()
        let firstSnapshot = await journal.recoveredSnapshot()
        XCTAssertEqual(firstSnapshot.map(\.jseq), [3])

        // A second close with an already-pruned set is a no-op.
        _ = try await journal.closeEpoch()
        let secondSnapshot = await journal.recoveredSnapshot()
        XCTAssertEqual(secondSnapshot.map(\.jseq), [3])
        let reopened = try JournalLog(configuration: configuration,
                                      bootID: LogTestSupport.bootID())
        let reopenedSnapshot = await reopened.recoveredSnapshot()
        XCTAssertEqual(reopenedSnapshot.map(\.jseq), [3])
    }

    func testJournalSpaceIsReclaimedAfterADurableClose() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root, journalQuotaBytes: 300)
        let journal = try JournalLog(configuration: configuration,
                                     bootID: LogTestSupport.bootID())
        _ = try await journal.append(JournalBody(
            jseq: 1, sessionID: "s", record: stepRecord("dispatched", key: keyA)))
        _ = try await journal.append(JournalBody(
            jseq: 2, sessionID: "s", record: stepRecord("completed", key: keyA)))
        _ = try await journal.closeEpoch()
        let afterPrune = await journal.sizeInBytes()
        XCTAssertLessThan(afterPrune, 180,
                          "the step entries are gone; only one high-water entry remains")
        // The quota is unchanged, but the space is reusable: a record that
        // would not have fit before the close now appends.
        let big = String(repeating: "z", count: 100)
        _ = try await journal.append(JournalBody(jseq: 3, sessionID: "s",
                                                 record: Data(big.utf8)))
        let afterAppend = await journal.sizeInBytes()
        XCTAssertGreaterThan(afterAppend, afterPrune)
    }

    func testJournalQuotaOverflowDoesNotPruneUndurableCompletedEntries() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root, journalQuotaBytes: 300)
        let journal = try JournalLog(configuration: configuration,
                                     bootID: LogTestSupport.bootID())
        _ = try await journal.append(JournalBody(
            jseq: 1, sessionID: "s", record: stepRecord("dispatched", key: keyA)))
        _ = try await journal.append(JournalBody(
            jseq: 2, sessionID: "s", record: stepRecord("completed", key: keyA)))
        do {
            _ = try await journal.append(JournalBody(
                jseq: 3, sessionID: "s",
                record: Data(String(repeating: "x", count: 400).utf8)))
            XCTFail("expected quotaExceeded before any level-2 durability")
        } catch let error as LogError {
            guard case .quotaExceeded(let resource, _, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(resource, .journal)
        }
        let remaining = await journal.recoveredSnapshot()
        XCTAssertEqual(remaining.map(\.jseq), [1, 2],
                       "nothing may be dropped before the epoch fsync")
    }

    func testJournalAcksAreCumulativePerSession() async throws {
        let root = LogTestSupport.root(for: self)
        let journal = try JournalLog(configuration: LogTestSupport.configuration(root: root),
                                     bootID: LogTestSupport.bootID())
        let collector = AckCollector(journal.acks())
        _ = try await journal.append(journalBody(1, session: "s"))
        _ = try await journal.append(journalBody(2, session: "s"))
        let acks = await collector.waitForCount(2)
        XCTAssertEqual(acks.map(\.uptoJseq), [1, 2])
        XCTAssertEqual(acks.map(\.sessionID), ["s", "s"])
    }

    func testLogQuotaConstantsMatchThePlan() {
        XCTAssertEqual(LogQuota.defaultWALBytes, 512 * 1024 * 1024)
        XCTAssertEqual(LogQuota.defaultJournalBytes, 64 * 1024 * 1024)
        let configuration = WorkspaceLogConfiguration(
            root: FileManager.default.temporaryDirectory)
        let quota = LogQuota(configuration: configuration)
        XCTAssertEqual(quota.walBytes, configuration.walQuotaBytes)
        XCTAssertEqual(quota.journalBytes, configuration.journalQuotaBytes)
        XCTAssertTrue(quota.isWALExceeded(quota.walBytes + 1))
        XCTAssertFalse(quota.isWALExceeded(quota.walBytes))
        XCTAssertFalse(try quota.requireWALSpace(used: quota.walBytes - 10,
                                                 additionalBytes: 5,
                                                 reclaimableBytes: 0))
        XCTAssertThrowsError(try quota.requireWALSpace(used: quota.walBytes - 10,
                                                       additionalBytes: 50,
                                                       reclaimableBytes: 0))
        XCTAssertTrue(try quota.requireWALSpace(used: quota.walBytes - 10,
                                                additionalBytes: 50,
                                                reclaimableBytes: 100))
        XCTAssertThrowsError(try quota.requireJournalSpace(used: quota.journalBytes,
                                                           additionalBytes: 1))
    }
}

// SPDX-License-Identifier: MIT
// Per-turn persistence counters (spec/v1/budgets.md §7). The tests drive the
// real file helpers and the real WorkspaceLog / journal / manifest paths, then
// assert the counters increase and that settlement resets the window. The
// persisted bytes are re-read so the instrumentation is also checked for not
// changing the existing formats.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class LogIOCountersTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WorkspaceLogIOCounters.reset()
    }

    override func tearDown() {
        WorkspaceLogIOCounters.reset()
        super.tearDown()
    }

    /// `ManifestStore.write` is the wal.md §7.1 atomic rewrite: one `write()`
    /// and exactly two fsyncs (file, directory).
    func testManifestWriteCountsBytesAndBothFsyncs() throws {
        let root = LogTestSupport.root(for: self)
        let manifest = Manifest(bootID: LogTestSupport.hex(LogTestSupport.bootID()),
                                materializedUptoMseq: 0,
                                lastMseq: 0,
                                lastDurableEpoch: 0,
                                segments: [])
        let encoded = try manifest.encoded()
        XCTAssertTrue(WorkspaceLogIOCounters.current().isEmpty)

        try ManifestStore(root: root).write(manifest)

        let counted = WorkspaceLogIOCounters.current()
        XCTAssertEqual(counted.fsyncCalls, 2,
                       "atomicWrite fsyncs the temporary file and the directory")
        XCTAssertEqual(counted.bytesWritten, encoded.count)
        XCTAssertEqual(try ManifestStore(root: root).read(), manifest)

        let settled = WorkspaceLogIOCounters.settle()
        XCTAssertEqual(settled, counted)
        XCTAssertTrue(WorkspaceLogIOCounters.current().isEmpty,
                      "settlement resets the per-turn window")
    }

    /// A level-1 journal append is one `write()` and no fsync; the epoch close
    /// is the single journal `F_FULLFSYNC`. Counting must not add a sync point.
    func testJournalAppendCountsBytesWithoutAnExtraFsync() async throws {
        let root = LogTestSupport.root(for: self)
        let journal = try JournalLog(
            configuration: LogTestSupport.configuration(root: root),
            bootID: LogTestSupport.bootID())
        let body = JournalBody(jseq: 1, sessionID: "session",
                               record: Data("journal-record".utf8))

        let beforeAppend = WorkspaceLogIOCounters.current()
        _ = try await journal.append(body)
        let afterAppend = WorkspaceLogIOCounters.current()
        XCTAssertEqual(afterAppend.fsyncCalls, beforeAppend.fsyncCalls,
                       "the level-1 journal append must not fsync")
        XCTAssertGreaterThan(afterAppend.bytesWritten, beforeAppend.bytesWritten)

        _ = try await journal.closeEpoch()
        let afterClose = WorkspaceLogIOCounters.current()
        XCTAssertEqual(afterClose.fsyncCalls, afterAppend.fsyncCalls + 1,
                       "the epoch close adds exactly the journal F_FULLFSYNC")
        XCTAssertEqual(afterClose.bytesWritten, afterAppend.bytesWritten,
                       "the close does not rewrite this journal")
    }

    /// One ordinary turn over the real facade: VFS appends plus a journal
    /// append, settled after the epoch close. This is also the host-side probe
    /// `scripts/perf/read_io_counters.py` parses; the printed lines are the
    /// machine-readable form of the two budgets.md §7 metrics.
    func testRealTurnSettlementCountsFsyncAndBytesAndResets() async throws {
        let root = LogTestSupport.root(for: self)
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        // The initializer creates a new workspace (including its first
        // manifest); the turn window starts after it, like the host's reset.
        WorkspaceLogIOCounters.reset()

        let first = LogTestSupport.write("/dsh/workspace/turn-a.txt", data: "alpha")
        let second = LogTestSupport.write("/dsh/workspace/turn-b.txt", data: "bravo")
        _ = try await log.append(first)
        _ = try await log.append(second)
        _ = try await log.journalAppend(JournalBody(jseq: 1, sessionID: "session",
                                                    record: Data("turn".utf8)))
        let ack = try await log.closeEpoch()
        XCTAssertEqual(ack.level, .epochFsync)

        let settled = WorkspaceLogIOCounters.settle()
        XCTAssertGreaterThan(settled.fsyncCalls, 0,
                             "the D18 close fsyncs the segment, wal/, manifest and journal")
        XCTAssertGreaterThanOrEqual(settled.bytesWritten,
                                    first.data.count + second.data.count,
                                    "WAL and materialized writes are both counted")
        XCTAssertTrue(WorkspaceLogIOCounters.current().isEmpty,
                      "a settled turn resets the window")
        XCTAssertTrue(WorkspaceLogIOCounters.settle().isEmpty,
                      "settling an empty window reports zero")

        // Existing durable state is unchanged by the observation.
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.materializedUptoMseq, 2)
        XCTAssertEqual(manifest.lastMseq, 2)
        XCTAssertEqual(manifest.lastDurableEpoch, 1)
        let materialized = WorkspacePaths(root: root).materializedDirectory
            .appendingPathComponent("workspace/turn-a.txt")
        XCTAssertEqual(try String(contentsOf: materialized, encoding: .utf8), "alpha")

        // A later append starts a fresh window.
        _ = try await log.append(LogTestSupport.write("/dsh/workspace/turn-c.txt",
                                                     data: "charlie"))
        let next = WorkspaceLogIOCounters.current()
        XCTAssertGreaterThan(next.bytesWritten, 0)

        print("PDSH_IO_FSYNC_CALLS=\(settled.fsyncCalls)")
        print("PDSH_IO_BYTES_WRITTEN=\(settled.bytesWritten)")
    }
}

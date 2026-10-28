// SPDX-License-Identifier: MIT
// Tool-call boundary persistence cadence (G2-FIX-83).
//
// A tool call boundary is a sequence of durable operations, not a timer:
//
//   local journal append (0x10 VFS_MUT) -> 0x30 JOURNAL (dispatched)
//   -> zero-work command -> local journal append (0x10) -> 0x30 JOURNAL (completed)
//
// `tool_dispatched -> journaled` in the host step record covers that sequence.
// The regression is that after a multi-MiB sink write the host paid a fixed
// multi-second cost per follow-up call: every accepted VFS mutation
// re-materialized by re-reading and re-verifying the *whole* WAL from disk, so
// the ordered channel's next JOURNAL frame waited behind seconds of rescan
// instead of being acked as soon as its write() returned (PLAN §2.3 D8).
//
// The test keeps the latency gate from the task: a >= 1 MiB sink write followed
// by N zero-work calls; the p95 of one call's boundary persistence chain must
// stay under one second. No prompt, scenario or file name is special-cased: any
// mutation stream on the workspace log runs through the same path.
//
// Baseline reproduction on the merged tree, with only the in-place
// `materializeAppended` path reverted to the old full-WAL `drainMaterialization`
// (20 calls after 72 MiB, this host):
//
//   boundary-cadence: large write 4.258 s, 20 calls p50=1.812 s
//                     p95=1.877 s max=1.909 s
//   XCTAssertLessThan failed: ("1.87732225") is not less than ("1.0")
//
// With the landed in-place path: large write 0.970 s, p50=0.008 s,
// p95=0.015 s, max=0.016 s.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class BoundaryAckCadenceTests: XCTestCase {
    /// Large enough that a full WAL rescan per mutation is unmistakably slow,
    /// still small enough for a fast, deterministic unit test after the fix.
    /// One mutation carries at most 15 MiB (channel.md §3.1), so the sink write
    /// is split across several files the way a large Worker write is published.
    private static let largeFileBytes = 12 * 1024 * 1024
    private static let largeFileCount = 6
    /// Zero-work calls measured after the large write.
    private static let measuredCalls = 20
    /// Gate from the work package: p95 of one call < 1 s.
    private static let perCallBudgetSeconds: Double = 1.0

    private func elapsed(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Publishes a multi-MiB sink write within the per-frame mutation budget.
    private func publishLargeSinkWrite(_ log: WorkspaceLog,
                                       files: Int = largeFileCount) async throws {
        let chunk = Data(repeating: 0xA5, count: Self.largeFileBytes)
        for index in 0..<files {
            _ = try await log.append(LogTestSupport.write(
                "/dsh/workspace/sink/large-\(index).bin", bytes: chunk))
        }
    }

    private static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = min(sorted.count - 1,
                       max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))
        return sorted[rank]
    }

    /// One zero-work tool call: the local journal record write and its 0x30
    /// record for dispatch, then the same pair for completion. The command in
    /// between does no work, so the elapsed time is persistence overhead only.
    private func zeroWorkCall(_ log: WorkspaceLog,
                              call: Int,
                              journalPath: String,
                              jseq: UInt64) async throws -> Double {
        let start = DispatchTime.now()
        let sessionID = "boundary-session"
        // Tool-journal start: local NDJSON append (a VFS_MUT) + JOURNAL record.
        _ = try await log.append(LogTestSupport.write(
            journalPath, data: "{\"t\":\"start\",\"n\":\(call)}\n"))
        _ = try await log.journalAppend(JournalBody(
            jseq: jseq, sessionID: sessionID,
            record: Data("{\"type\":\"dispatched\",\"n\":\(call)}".utf8)))
        // Zero-work command. Its completion boundary persists the same two
        // records again; the second journal append is the `journaled` state.
        _ = try await log.append(LogTestSupport.write(
            journalPath, data: "{\"t\":\"done\",\"n\":\(call)}\n"))
        _ = try await log.journalAppend(JournalBody(
            jseq: jseq + 1, sessionID: sessionID,
            record: Data("{\"type\":\"completed\",\"n\":\(call)}".utf8)))
        return elapsed(start)
    }

    /// G2-FIX-83 regression: a large sink write must not turn the following
    /// tool-call boundaries into a fixed multi-second cadence.
    func testLargeSinkWriteDoesNotDegradeToolCallBoundaryLatency() async throws {
        let root = LogTestSupport.root(for: self, name: "boundary-cadence")
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let writeStart = DispatchTime.now()
        try await publishLargeSinkWrite(log)
        let largeWriteSeconds = elapsed(writeStart)

        var samples: [Double] = []
        for call in 1...Self.measuredCalls {
            samples.append(try await zeroWorkCall(
                log, call: call,
                journalPath: "/dsh/home/sessions/boundary/session.journal.ndjson",
                jseq: UInt64(call * 2 - 1)))
        }
        let p50 = Self.percentile(samples, 0.50)
        let p95 = Self.percentile(samples, 0.95)
        let maximum = samples.max() ?? 0
        print(String(format: "boundary-cadence: large write %.3f s, %d calls p50=%.3f s p95=%.3f s max=%.3f s",
                     largeWriteSeconds, samples.count, p50, p95, maximum))
        XCTAssertLessThan(largeWriteSeconds, 30,
                          "the large sink write itself must complete")
        XCTAssertLessThan(p95, Self.perCallBudgetSeconds,
                          "tool-call boundary persistence p95 \(p95) s exceeds the \(Self.perCallBudgetSeconds) s gate after a \(Self.largeFileCount * Self.largeFileBytes / (1024 * 1024)) MiB write (samples: \(samples.map { String(format: "%.3f", $0) }))")
    }

    /// The level-1 VFS ack is due right after the group-commit write returns
    /// (D8); it must never wait for the materialized copy to catch up. This
    /// locks the event-driven emission the cadence fix relies on: the ack of a
    /// large mutation arrives while the append that carries it is still being
    /// materialized.
    func testLevelOneAckIsIndependentOfMaterialization() async throws {
        let root = LogTestSupport.root(for: self, name: "ack-event-driven")
        let log = try WorkspaceLog(configuration: LogTestSupport.configuration(root: root),
                                   bootID: LogTestSupport.bootID())
        let collector = AckCollector(log.acks())
        let append = Task { try await self.publishLargeSinkWrite(log, files: 1) }
        let ackStart = DispatchTime.now()
        let ack = try await collector.waitForCount(1)
        let ackSeconds = elapsed(ackStart)
        _ = try await append.value
        XCTAssertEqual(ack.first?.level, .write)
        XCTAssertEqual(ack.first?.uptoMseq, 1)
        XCTAssertLessThan(ackSeconds, 5.0,
                          "the level-1 ack waited for materialization instead of the WAL write()")
        // The ack is emitted by the writer before the manifest rewrite; after
        // the append returns the materialized copy and manifest agree.
        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        XCTAssertEqual(manifest.materializedUptoMseq, 1)
    }
}

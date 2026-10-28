// SPDX-License-Identifier: MIT
// G2-FIX-83: per-hop acknowledgement timing on the ordered channel.
//
// The tool-call boundary chain is `0x10/0x30` out, the host's group-commit
// write + journal write, then `0x11/0x31` back. The step records only carry the
// boundary `at_ms`; the channel metrics now retain each ack's log-to-frame hop
// so an artifact can tell an event-driven ack (~2 ms coalescing window) from a
// timer cadence. These tests pin the sample shape and the event-driven send:
// the ack is emitted as soon as the log reports the cumulative watermark, and
// no epoch close or materialization timer is involved.

import Foundation
import XCTest
import PhoneDSHWire
import PhoneDSHLoopback

final class ChannelServerAckTimingTests: XCTestCase {
    /// Upper bound for one log-ack → frame hop. The 2 ms coalescing window is
    /// the design cadence; 250 ms keeps CI scheduling noise out while failing
    /// any timer/settlement cadence by two orders of magnitude.
    private static let ackHopBudgetMilliseconds: Double = 250

    private struct Harness {
        let server: ChannelServer
        let socket: MockChannelSocket
        let log: RecordingWorkspaceLog
    }

    private func start() async throws -> Harness {
        let socket = MockChannelSocket()
        let log = RecordingWorkspaceLog(nextMseq: 1)
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: RecordingChannelHandler(workspaceLog: log),
                                   workspaceLog: log,
                                   ackCoalescingInterval: 0.002)
        Task { await server.run() }
        addTeardownBlock { await server.close() }
        _ = try await socket.waitForFrames(count: 1)
        let hello = try CanonicalJSON.encode(workerHelloPayload(state: ChannelHostState(),
                                                                lastMseq: 0))
        socket.push(try encodedFrame(.hello, seq: 1, payload: hello))
        return Harness(server: server, socket: socket, log: log)
    }

    func testAckTimingsRecordTheLogToFrameHop() async throws {
        let harness = try await start()
        // VFS_MUT -> level-1 0x11.
        let mutation = VfsMutationBody(op: .write, mode: 0o644,
                                       mflags: [.entryChanged],
                                       path: "/dsh/workspace/a.txt",
                                       data: Data("a".utf8))
        harness.socket.push(try encodedFrame(
            .vfsMutation, seq: 2,
            payload: try VfsMutationPayload.encode(mseq: 1, body: mutation)))
        // 0x30 -> 0x31.
        let journal = try JournalBody(jseq: 1, sessionID: "session-1",
                                      record: Data("{\"t\":\"start\"}".utf8)).encoded()
        harness.socket.push(try encodedFrame(.journal, seq: 3, payload: journal))
        // 0x12 barrier level 1 is satisfied by the observed level-1 watermark.
        let barrier = try VfsBarrierBody(wantLevel: .write, uptoMseq: 1).encoded()
        harness.socket.push(try encodedFrame(.vfsBarrier, seq: 4, payload: barrier))

        let frames = try await harness.socket.waitForFrames(count: 4)
        XCTAssertEqual(frames[0].type, .hello)
        // The three ack kinds are cumulative and independently timed, so their
        // frame order is not a contract; each one must appear and carry a hop.
        let ackFrames = frames.dropFirst().map(\.type)
        XCTAssertEqual(ackFrames.filter { $0 == .vfsAck }.count, 2,
                       "one VFS ack for the mutation and one for the barrier: \(ackFrames)")
        XCTAssertEqual(ackFrames.filter { $0 == .journalAck }.count, 1,
                       "one journal ack: \(ackFrames)")

        let metrics = await harness.server.currentMetrics()
        print("ack-timings: " + metrics.ackTimings.map {
            "\($0.kind.rawValue)/l\($0.level)/\($0.upto) queued=\($0.queuedAtMilliseconds) sent=\($0.sentAtMilliseconds) hop=\($0.queueMilliseconds) ms"
        }.joined(separator: ", "))
        XCTAssertEqual(Set(metrics.ackTimings.map(\.kind)), [.vfs, .journal, .barrier])
        let vfsTiming = try XCTUnwrap(metrics.ackTimings.first { $0.kind == .vfs && $0.upto == 1 })
        XCTAssertEqual(vfsTiming.level, 1)
        XCTAssertNil(vfsTiming.sessionID)
        let journalTiming = try XCTUnwrap(metrics.ackTimings.first { $0.kind == .journal })
        XCTAssertEqual(journalTiming.sessionID, "session-1")
        XCTAssertEqual(journalTiming.upto, 1)
        for timing in metrics.ackTimings {
            XCTAssertGreaterThan(timing.queuedAtMilliseconds, 0)
            XCTAssertGreaterThanOrEqual(timing.sentAtMilliseconds,
                                        timing.queuedAtMilliseconds)
            // Event-driven: the hop is the 2 ms coalescing window, never an
            // epoch/settlement timer. The measured hop on this host is 2-3 ms;
            // 250 ms leaves two orders of magnitude of CI scheduling headroom
            // and is still two orders below the 20-30 s cadence the defect
            // produced (G2-FIX-83).
            XCTAssertLessThan(timing.queueMilliseconds, Self.ackHopBudgetMilliseconds,
                              "ack hop \(timing) waited for a timer")
        }
        let p95 = try XCTUnwrap(metrics.ackQueueP95Milliseconds)
        XCTAssertLessThan(p95, Self.ackHopBudgetMilliseconds)
    }
}

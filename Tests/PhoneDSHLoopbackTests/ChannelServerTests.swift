// SPDX-License-Identifier: MIT
// PhoneDSHLoopback ordered channel tests: HELLO/mseq/seq rules,
// journal acks, VFS acks and barriers, host → worker API requests, exec
// idempotency replay and channel metrics. No @MainActor.

import Foundation
import XCTest
import PhoneDSHWire
import PhoneDSHLoopback
import PhoneDSHAgentCore

final class ChannelServerTests: XCTestCase {
    private struct Harness {
        var server: ChannelServer
        var socket: MockChannelSocket
        var recorder: RecordingChannelHandler
    }

    private func start(
        state: ChannelHostState = ChannelHostState(),
        workspaceLog: (any LoopbackWorkspaceLog)? = nil,
        journalLog: (any LoopbackJournalLog)? = nil,
        execProvider: (any ExecProvider)? = nil,
        accelerators: [String] = [],
        admission: @escaping @Sendable () async -> Admission = { .open },
        ackCoalescingInterval: TimeInterval = 0.002,
        defaultHandler: Bool = false
    ) async throws -> Harness {
        let socket = MockChannelSocket()
        let recorder = RecordingChannelHandler(workspaceLog: workspaceLog)
        let server: ChannelServer
        if defaultHandler {
            server = ChannelServer(socket: socket, state: state, handler: nil,
                                   workspaceLog: workspaceLog,
                                   journalLog: journalLog,
                                   admission: admission,
                                   ackCoalescingInterval: ackCoalescingInterval)
            let handler = DefaultChannelHandling(outbound: server,
                                                 workspaceLog: workspaceLog,
                                                 journalLog: journalLog,
                                                 execProvider: execProvider,
                                                 accelerators: accelerators,
                                                 admission: admission)
            try await server.installHandler(handler)
        } else {
            server = ChannelServer(socket: socket, state: state, handler: recorder,
                                   workspaceLog: workspaceLog,
                                   journalLog: journalLog,
                                   admission: admission,
                                   ackCoalescingInterval: ackCoalescingInterval)
        }
        Task { await server.run() }
        addTeardownBlock { await server.close() }
        return Harness(server: server, socket: socket, recorder: recorder)
    }

    @discardableResult
    private func sendHello(_ harness: Harness, _ state: ChannelHostState = ChannelHostState(),
                           lastMseq: UInt64 = 0) async throws -> Frame {
        let payload = try CanonicalJSON.encode(workerHelloPayload(state: state, lastMseq: lastMseq))
        harness.socket.push(try encodedFrame(.hello, seq: 1, payload: payload))
        return try await harness.socket.nextFrame(after: 0)
    }

    private func push(_ harness: Harness, _ type: FrameType, seq: UInt64,
                      payload: Data) {
        harness.socket.push(try! encodedFrame(type, seq: seq, payload: payload))
    }

    // MARK: - HELLO

    func testHostHelloCarriesNextAckedAndDurableMseq() async throws {
        let state = ChannelHostState(
            sessionEpoch: 7,
            fence: Fence(owner: "phone", generation: 9, walSeq: 3),
            caps: ["channel/1", "wal/1", "exec/1", "accelerator:rg"],
            ackedMseq: 41, durableMseq: 40)
        let harness = try await start(state: state)
        let firstFrames = try await harness.socket.waitForFrames(count: 1)
        let frame = firstFrames[0]
        XCTAssertEqual(frame.type, .hello)
        XCTAssertEqual(frame.seq, 1)
        let hello = try JSONDecoder().decode(HelloPayload.self, from: frame.payload)
        XCTAssertEqual(hello.role, .host)
        XCTAssertEqual(hello.sessionEpoch, 7)
        XCTAssertEqual(hello.fence, state.fence)
        XCTAssertEqual(hello.nextMseq, 42)
        XCTAssertEqual(hello.ackedMseq, 41)
        XCTAssertEqual(hello.durableMseq, 40)
        XCTAssertTrue(hello.caps.contains("accelerator:rg"))
    }

    func testWorkerRoleHostIsRejected() async throws {
        let state = ChannelHostState()
        let harness = try await start(state: state)
        _ = try await harness.socket.waitForFrames(count: 1)
        let hostRoleHello = HelloPayload(role: .host,
                                         bootID: "00112233445566778899aabbccddeeff",
                                         sessionEpoch: 1,
                                         fence: state.fence,
                                         caps: ["channel/1", "wal/1", "exec/1"],
                                         nextMseq: 1, ackedMseq: 0, durableMseq: 0)
        harness.socket.push(try encodedFrame(.hello, seq: 1,
                                             payload: CanonicalJSON.encode(hostRoleHello)))
        let error = try await errorPayload(harness.socket.nextFrame(after: 1))
        XCTAssertEqual(error.code, .protoMismatch)
    }

    // MARK: - VFS

    func testMutationIsAppendedThroughWorkspaceLogAndAcked() async throws {
        let log = RecordingWorkspaceLog(nextMseq: 5)
        let state = ChannelHostState(ackedMseq: 4, durableMseq: 4)
        let harness = try await start(state: state, workspaceLog: log, defaultHandler: true)
        _ = try await sendHello(harness, state, lastMseq: 4)
        let mutation = VfsMutationBody(op: .write, mode: 0o644,
                                       mflags: [.entryChanged],
                                       path: "/dsh/workspace/a.txt",
                                       data: Data("a".utf8))
        push(harness, .vfsMutation, seq: 2,
             payload: try VfsMutationPayload.encode(mseq: 5, body: mutation))
        let ackFrame = try await harness.socket.nextFrame(after: 1)
        XCTAssertEqual(ackFrame.type, .vfsAck)
        let ack = try VfsAckBody.decode(ackFrame.payload)
        XCTAssertEqual(ack.level, .write)
        XCTAssertEqual(ack.uptoMseq, 5)
        let count = await waitUntil { (await log.mutationCount()) == 1 }
        XCTAssertTrue(count)
    }

    func testMutationMseqIsDispatchedToTheHandler() async throws {
        let log = RecordingWorkspaceLog(nextMseq: 1)
        let harness = try await start(workspaceLog: log)
        _ = try await sendHello(harness, ChannelHostState())
        let mutation = VfsMutationBody(op: .write, mode: 0o644,
                                       mflags: [.entryChanged],
                                       path: "/dsh/workspace/notes.txt",
                                       data: Data("hello\n".utf8))
        push(harness, .vfsMutation, seq: 2,
             payload: try VfsMutationPayload.encode(mseq: 1, body: mutation))
        let delivered = await waitUntil { (await harness.recorder.mutations).count == 1 }
        XCTAssertTrue(delivered)
        let recorded = await harness.recorder.mutations
        XCTAssertEqual(recorded.first?.mseq, 1)
        let ack = try VfsAckBody.decode(try await harness.socket.nextFrame(after: 1).payload)
        XCTAssertEqual(ack.uptoMseq, 1)
    }

    func testMutationWithoutWorkspaceLogFailsLoud() async throws {
        // No workspace log: a level-1 ack would claim durability the host does
        // not have, so the channel must fail instead of acknowledging.
        let harness = try await start(workspaceLog: nil)
        _ = try await sendHello(harness, ChannelHostState())
        let mutation = VfsMutationBody(op: .write, mode: 0o644,
                                       mflags: [.entryChanged],
                                       path: "/dsh/workspace/notes.txt",
                                       data: Data("lost\n".utf8))
        push(harness, .vfsMutation, seq: 2,
             payload: try VfsMutationPayload.encode(mseq: 1, body: mutation))
        let code = try await harness.socket.closedCode()
        XCTAssertEqual(code, 1011)
        let frames = harness.socket.sentFrames()
        XCTAssertFalse(frames.contains { $0.type == .vfsAck },
                       "an unpersisted mutation must never be acknowledged")
        XCTAssertFalse(frames.contains { $0.type == .error },
                       "a host misconfiguration is not a worker protocol error")
        let count = await harness.recorder.mutations.count
        XCTAssertEqual(count, 0)
    }

    func testMaterializerBaseMismatchEmitsVFSResync() async throws {
        // The materializer (W1-LOG) owns base-mismatch detection; this fake
        // reports it through the log seam exactly like the W2 adapter will.
        let log = RecordingWorkspaceLog(
            nextMseq: 7, mismatchPaths: ["/dsh/workspace/append.txt"])
        let state = ChannelHostState(ackedMseq: 6, durableMseq: 6)
        let harness = try await start(state: state, workspaceLog: log, defaultHandler: true)
        _ = try await sendHello(harness, state, lastMseq: 6)
        let mutation = VfsMutationBody(op: .write, mode: 0o644,
                                       mflags: [.entryChanged, .appended],
                                       appendFrom: 3,
                                       path: "/dsh/workspace/append.txt",
                                       data: Data("tail".utf8))
        push(harness, .vfsMutation, seq: 2,
             payload: try VfsMutationPayload.encode(mseq: 7, body: mutation))
        let sawResync = await waitUntil {
            harness.socket.sentFrames().contains { $0.type == .vfsResync }
        }
        XCTAssertTrue(sawResync)
        let frames = harness.socket.sentFrames()
        let resyncFrame = try XCTUnwrap(frames.first { $0.type == .vfsResync })
        let resync = try VfsResyncBody.decode(resyncFrame.payload)
        XCTAssertEqual(resync.path, "/dsh/workspace/append.txt")
        let ackFrame = try XCTUnwrap(frames.first { $0.type == .vfsAck })
        let ack = try VfsAckBody.decode(ackFrame.payload)
        XCTAssertEqual(ack.level, .write)
        XCTAssertEqual(ack.uptoMseq, 7)
    }

    func testLifecycleAndFenceHaveDedicatedSendAPIs() async throws {
        let harness = try await start()
        _ = try await sendHello(harness, ChannelHostState())
        let outbound: any ChannelOutbound = harness.server
        let lifecycle = LifecyclePayload(state: .pause, budget: 2500,
                                         admission: .closed, reason: "background")
        try await outbound.sendLifecycle(lifecycle)
        let lifecycleFrame = try await harness.socket.nextFrame(after: 1)
        XCTAssertEqual(lifecycleFrame.type, .lifecycle)
        XCTAssertEqual(lifecycleFrame.seq, 2)
        XCTAssertEqual(try JSONDecoder().decode(LifecyclePayload.self,
                                                from: lifecycleFrame.payload), lifecycle)

        let fence = Fence(owner: "phone", generation: 4, walSeq: 12)
        let payload = FencePayload(fence: fence, admission: .open)
        try await outbound.sendFence(payload)
        let fenceFrame = try await harness.socket.nextFrame(after: 2)
        XCTAssertEqual(fenceFrame.type, .fence)
        XCTAssertEqual(fenceFrame.seq, 3)
        XCTAssertEqual(try JSONDecoder().decode(FencePayload.self, from: fenceFrame.payload),
                       payload)
    }

    func testWorkspaceLogEpochAckIsForwardedAsLevelTwo() async throws {
        let log = RecordingWorkspaceLog(nextMseq: 10)
        let harness = try await start(workspaceLog: log, defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        let subscribed = await waitUntil { (await log.subscriberCount) > 0 }
        XCTAssertTrue(subscribed)
        await log.emit(level: .epochFsync, uptoMseq: 9)
        let ack = try VfsAckBody.decode(try await harness.socket.nextFrame(after: 1).payload)
        XCTAssertEqual(ack.level, .epochFsync)
        XCTAssertEqual(ack.uptoMseq, 9)
    }

    func testAcksInsideOneCoalescingWindowMergeIntoOneFrame() async throws {
        // Non-default window, long enough that the three acks are guaranteed to
        // arrive while the flush task is still sleeping. The highest upto_mseq
        // wins and exactly one 0x11 leaves the channel.
        let log = RecordingWorkspaceLog(nextMseq: 4)
        let harness = try await start(workspaceLog: log,
                                      ackCoalescingInterval: 1.0,
                                      defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        let subscribed = await waitUntil { (await log.subscriberCount) > 0 }
        XCTAssertTrue(subscribed)

        await log.emit(level: .write, uptoMseq: 1)
        await log.emit(level: .write, uptoMseq: 2)
        await log.emit(level: .write, uptoMseq: 3)

        _ = try await harness.socket.waitForFrames(count: 2)
        // Give a mistakenly per-ack flush implementation time to emit extras.
        try await Task.sleep(nanoseconds: 100_000_000)
        let ackFrames = harness.socket.sentFrames().filter { $0.type == .vfsAck }
        XCTAssertEqual(ackFrames.count, 1)
        let ack = try VfsAckBody.decode(ackFrames[0].payload)
        XCTAssertEqual(ack.level, .write)
        XCTAssertEqual(ack.uptoMseq, 3)
    }

    func testZeroCoalescingIntervalForwardsEveryAck() async throws {
        // A non-default zero interval disables the timer: each ack flushes on
        // its own without merging later acks into the same window.
        let log = RecordingWorkspaceLog(nextMseq: 3)
        let harness = try await start(workspaceLog: log,
                                      ackCoalescingInterval: 0,
                                      defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        let subscribed = await waitUntil { (await log.subscriberCount) > 0 }
        XCTAssertTrue(subscribed)

        await log.emit(level: .write, uptoMseq: 1)
        let first = try VfsAckBody.decode(try await harness.socket.nextFrame(after: 1).payload)
        XCTAssertEqual(first.level, .write)
        XCTAssertEqual(first.uptoMseq, 1)

        await log.emit(level: .write, uptoMseq: 2)
        let second = try VfsAckBody.decode(try await harness.socket.nextFrame(after: 2).payload)
        XCTAssertEqual(second.level, .write)
        XCTAssertEqual(second.uptoMseq, 2)
    }

    func testBarrierIsAnsweredAtRequestedLevel() async throws {
        let harness = try await start()
        let state = ChannelHostState()
        _ = try await sendHello(harness, state)
        let barrier = VfsBarrierBody(wantLevel: .write, uptoMseq: 0)
        push(harness, .vfsBarrier, seq: 2, payload: barrier.encoded())
        let frame = try await harness.socket.nextFrame(after: 1)
        XCTAssertEqual(frame.type, .vfsAck)
        let ack = try VfsAckBody.decode(frame.payload)
        XCTAssertEqual(ack.level, .write)
        XCTAssertEqual(ack.uptoMseq, 0)
        let barriers = await harness.recorder.barriers
        XCTAssertEqual(barriers.count, 1)
    }

    func testNotifyVFSResyncSendsResyncFrame() async throws {
        let harness = try await start()
        _ = try await sendHello(harness, ChannelHostState())
        let outbound: any ChannelOutbound = harness.server
        await outbound.notifyVFSResync(path: "/dsh/workspace/a.txt")
        let frame = try await harness.socket.nextFrame(after: 1)
        XCTAssertEqual(frame.type, .vfsResync)
        let body = try VfsResyncBody.decode(frame.payload)
        XCTAssertEqual(body.path, "/dsh/workspace/a.txt")
    }

    // MARK: - Journal

    func testJournalAckAndDuplicateDedupe() async throws {
        let journal = InMemoryJournalLog()
        let harness = try await start(journalLog: journal, defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        let body = JournalBody(jseq: 1, sessionID: "session-1",
                               record: Data("{\"step\":1}".utf8))
        push(harness, .journal, seq: 2, payload: try body.encoded())
        let ackFrame = try await harness.socket.nextFrame(after: 1)
        XCTAssertEqual(ackFrame.type, .journalAck)
        let ack = try JournalAckBody.decode(ackFrame.payload)
        XCTAssertEqual(ack.level, .write)
        XCTAssertEqual(ack.uptoJseq, 1)
        XCTAssertEqual(ack.sessionID, "session-1")

        // The duplicate is not appended again but is acknowledged.
        push(harness, .journal, seq: 3, payload: try body.encoded())
        let duplicateAck = try JournalAckBody.decode(
            try await harness.socket.nextFrame(after: 2).payload)
        XCTAssertEqual(duplicateAck.uptoJseq, 1)
        let highest = await journal.highestJseq(sessionID: "session-1")
        XCTAssertEqual(highest, 1)
    }

    func testJournalGapIsBadPayload() async throws {
        let harness = try await start(journalLog: InMemoryJournalLog(), defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        let body = JournalBody(jseq: 3, sessionID: "session-1",
                               record: Data("x".utf8))
        push(harness, .journal, seq: 2, payload: try body.encoded())
        let error = try await errorPayload(harness.socket.nextFrame(after: 1))
        XCTAssertEqual(error.code, .badPayload)
    }

    func testJournalDuplicateOnOneConnectionIsNotAppendedTwice() async throws {
        let journal = CountingJournalLog()
        let harness = try await start(journalLog: journal)
        _ = try await sendHello(harness, ChannelHostState())
        let body = JournalBody(jseq: 1, sessionID: "session-1",
                               record: Data("one".utf8))
        push(harness, .journal, seq: 2, payload: try body.encoded())
        let first = try JournalAckBody.decode(try await harness.socket.nextFrame(after: 1).payload)
        XCTAssertEqual(first.uptoJseq, 1)
        let forged = JournalBody(jseq: 1, sessionID: "session-1",
                                 record: Data("{\"type\":\"completed\",\"key\":\"xl1-forged\"}".utf8))
        push(harness, .journal, seq: 3, payload: try forged.encoded())
        let duplicate = try JournalAckBody.decode(
            try await harness.socket.nextFrame(after: 2).payload)
        XCTAssertEqual(duplicate.uptoJseq, 1)
        let calls = await journal.appendCount()
        XCTAssertEqual(calls, 1, "the duplicate must not reach the journal append")
        let stored = await journal.storedAppends
        XCTAssertEqual(stored, 1)
        let projected = await harness.recorder.journals
        XCTAssertEqual(projected.count, 1,
                       "same-jseq bytes cannot replace or project over the durable record")
        let highest = await journal.highestJseq(sessionID: "session-1")
        XCTAssertEqual(highest, 1)
    }

    func testJournalReconnectResendsUnackedRecordsAgainstPersistedHighWater() async throws {
        let journal = CountingJournalLog()
        let state = ChannelHostState()

        // First connection persists jseq 1 and 2, then dies before the worker
        // sees both acks.
        let first = try await start(state: state, journalLog: journal)
        _ = try await sendHello(first, state)
        for (jseq, record) in [(UInt64(1), "one"), (UInt64(2), "two")] {
            let body = JournalBody(jseq: jseq, sessionID: "session-1",
                                   record: Data(record.utf8))
            push(first, .journal, seq: jseq + 1, payload: try body.encoded())
            let ack = try JournalAckBody.decode(
                try await first.socket.nextFrame(after: Int(jseq)).payload)
            XCTAssertEqual(ack.uptoJseq, jseq)
        }
        let beforeReconnect = await journal.appendCount()
        XCTAssertEqual(beforeReconnect, 2)
        await first.server.close()

        // The new connection has a fresh seq space and no journal state of its
        // own. It re-sends the whole range 1..4: the persisted prefix 1, 2 is
        // acked without being appended again, 3 and 4 are appended normally.
        let second = try await start(state: state, journalLog: journal)
        _ = try await sendHello(second, state)
        for (index, jseq) in [UInt64(1), 2, 3, 4].enumerated() {
            let body = JournalBody(jseq: jseq, sessionID: "session-1",
                                   record: Data("resend-\(jseq)".utf8))
            push(second, .journal, seq: UInt64(index + 2), payload: try body.encoded())
            let ack = try JournalAckBody.decode(
                try await second.socket.nextFrame(after: index + 1).payload)
            XCTAssertEqual(ack.uptoJseq, max(jseq, 2),
                           "resends up to the persisted mark ack that mark")
        }
        let afterReconnect = await journal.appendCount()
        XCTAssertEqual(afterReconnect, beforeReconnect + 2,
                       "only the records above the persisted high-water are appended")
        let storedAfterReconnect = await journal.storedAppends
        XCTAssertEqual(storedAfterReconnect, 4)
        let one = await journal.record(sessionID: "session-1", jseq: 1)
        let two = await journal.record(sessionID: "session-1", jseq: 2)
        XCTAssertEqual(one, Data("one".utf8),
                       "the duplicate resend must not replace the stored record")
        XCTAssertEqual(two, Data("two".utf8))
        let four = await journal.record(sessionID: "session-1", jseq: 4)
        XCTAssertEqual(four, Data("resend-4".utf8))
        let highest = await journal.highestJseq(sessionID: "session-1")
        XCTAssertEqual(highest, 4)
    }

    func testJournalGapAbovePersistedHighWaterIsRejected() async throws {
        let journal = CountingJournalLog(seed: ["session-1": [
            1: Data("one".utf8), 2: Data("two".utf8),
        ]])
        let harness = try await start(journalLog: journal)
        _ = try await sendHello(harness, ChannelHostState())
        let gap = JournalBody(jseq: 4, sessionID: "session-1",
                              record: Data("four".utf8))
        push(harness, .journal, seq: 2, payload: try gap.encoded())
        let error = try await errorPayload(harness.socket.nextFrame(after: 1))
        XCTAssertEqual(error.code, .badPayload)
        let calls = await journal.appendCount()
        XCTAssertEqual(calls, 0, "a forward gap must not be appended")
        let highest = await journal.highestJseq(sessionID: "session-1")
        XCTAssertEqual(highest, 2)
    }

    func testJournalSessionsInterleaveIndependently() async throws {
        let journal = CountingJournalLog(seed: [
            "session-a": [1: Data("a1".utf8)],
            "session-b": [1: Data("b1".utf8), 2: Data("b2".utf8)],
        ])
        let harness = try await start(journalLog: journal)
        _ = try await sendHello(harness, ChannelHostState())

        // A/2 is new, B/2 and A/1 are duplicates; then B/3 and A/3 are new.
        // Each session keeps its own high-water mark across the interleaving.
        let frames: [(seq: UInt64, session: String, jseq: UInt64, record: String)] = [
            (2, "session-a", 2, "a2"),
            (3, "session-b", 2, "b2-again"),
            (4, "session-a", 1, "a1-again"),
            (5, "session-b", 3, "b3"),
            (6, "session-a", 3, "a3"),
        ]
        let expected: [(session: String, upto: UInt64)] = [
            ("session-a", 2), ("session-b", 2), ("session-a", 2),
            ("session-b", 3), ("session-a", 3),
        ]
        for (index, entry) in frames.enumerated() {
            let body = JournalBody(jseq: entry.jseq, sessionID: entry.session,
                                   record: Data(entry.record.utf8))
            push(harness, .journal, seq: entry.seq, payload: try body.encoded())
            // Wait for each ack so the 2 ms coalescing window cannot merge the
            // interleaved per-session acknowledgements.
            let frame = try await harness.socket.nextFrame(after: index + 1)
            XCTAssertEqual(frame.type, .journalAck)
            let ack = try JournalAckBody.decode(frame.payload)
            let want = expected[index]
            XCTAssertEqual(ack.sessionID, want.session)
            XCTAssertEqual(ack.uptoJseq, want.upto)
        }
        let highestA = await journal.highestJseq(sessionID: "session-a")
        let highestB = await journal.highestJseq(sessionID: "session-b")
        XCTAssertEqual(highestA, 3)
        XCTAssertEqual(highestB, 3)
        let calls = await journal.appendCount()
        XCTAssertEqual(calls, 3, "only A/2, B/3 and A/3 are new")
        let a1 = await journal.record(sessionID: "session-a", jseq: 1)
        let b2 = await journal.record(sessionID: "session-b", jseq: 2)
        XCTAssertEqual(a1, Data("a1".utf8))
        XCTAssertEqual(b2, Data("b2".utf8))
    }

    // MARK: - Host → worker API requests

    func testAPIRequestStreamsResponseAndEnd() async throws {
        let harness = try await start()
        _ = try await sendHello(harness, ChannelHostState())
        let stream = try await harness.server.sendAPIRequest(
            head: ApiRequestHead(method: "POST", path: "/api/session/message"),
            body: Data("{}".utf8))
        let requestFrame = try await harness.socket.nextFrame(after: 1)
        XCTAssertEqual(requestFrame.type, .apiRequest)
        let request = try ApiRequestFrame.decode(requestFrame.payload)
        XCTAssertEqual(request.head.path, "/api/session/message")
        XCTAssertEqual(request.body, Data("{}".utf8))

        let first = ApiResponseFrame(reqID: request.reqID,
                                     head: ApiResponseHead(status: 200,
                                                           headers: ["content-type": "application/json"]),
                                     body: Data("a".utf8))
        push(harness, .apiResponse, seq: 2, payload: try first.encoded())
        let second = ApiResponseFrame(reqID: request.reqID, head: nil, body: Data("b".utf8))
        push(harness, .apiResponse, seq: 3, payload: try second.encoded())
        push(harness, .apiEnd, seq: 4, payload: ApiEndFrame(reqID: request.reqID).encoded())

        let ended = await waitUntil { (await harness.recorder.apiEnds) == 1 }
        XCTAssertTrue(ended)
        var events: [ChannelAPIEvent] = []
        for await event in stream { events.append(event) }
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .response(reqID: request.reqID, status: 200,
                                            headers: ["content-type": "application/json"],
                                            body: Data("a".utf8)))
        XCTAssertEqual(events[1], .response(reqID: request.reqID, status: nil,
                                            headers: [:], body: Data("b".utf8)))
        XCTAssertEqual(events[2], .end(reqID: request.reqID))
        let metrics = await harness.server.currentMetrics()
        XCTAssertEqual(metrics.roundTripSamplesMillis.count, 1)
    }

    func testPendingAPIRequestIsAbortedWithConnectionClosed() async throws {
        let harness = try await start()
        _ = try await sendHello(harness, ChannelHostState())
        let stream = try await harness.server.sendAPIRequest(
            head: ApiRequestHead(method: "GET", path: "/api/events"))
        let requestFrame = try await harness.socket.nextFrame(after: 1)
        let request = try ApiRequestFrame.decode(requestFrame.payload)
        await harness.server.close()
        var events: [ChannelAPIEvent] = []
        for await event in stream { events.append(event) }
        XCTAssertEqual(events, [.abort(reqID: request.reqID, reason: "connection_closed")])
    }

    func testFirstAPIResponseChunkMustCarryHead() async throws {
        let harness = try await start()
        _ = try await sendHello(harness, ChannelHostState())
        _ = try await harness.server.sendAPIRequest(
            head: ApiRequestHead(method: "GET", path: "/api/events"))
        let requestFrame = try await harness.socket.nextFrame(after: 1)
        let request = try ApiRequestFrame.decode(requestFrame.payload)
        let bad = ApiResponseFrame(reqID: request.reqID, head: nil, body: Data("x".utf8))
        push(harness, .apiResponse, seq: 2, payload: try bad.encoded())
        let error = try await errorPayload(harness.socket.nextFrame(after: 2))
        XCTAssertEqual(error.code, .badPayload)
    }

    // MARK: - Exec

    private func execRequestFrame(seq: UInt64, execID: String, argv: [String],
                                  cwd: String = "/dsh/workspace",
                                  idemKey: String = String(repeating: "a", count: 64),
                                  requiresMseq: UInt64 = 0,
                                  deadline: Int64? = nil) throws -> Data {
        var bodyObject: [String: Any] = [
            "exec_id": execID,
            "argv": argv,
            "cwd": cwd,
            "tier": "interactive",
        ]
        if let deadline { bodyObject["deadline"] = deadline }
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObject,
                                                  options: [.sortedKeys])
        let payload = try ExecRequestPayload(body: bodyData,
                                             requiresMseq: requiresMseq,
                                             idemKey: idemKey)
        return try encodedFrame(.execRequest, seq: seq, payload: payload.encodedPayload())
    }

    private func decodedEvents(_ frames: [Frame]) throws -> [[String: Any]] {
        try frames.compactMap { frame in
            guard frame.type == .execEvent else { return nil }
            return try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
        }
    }

    func testExecRequestReplaysRecordedEventsByIDemKey() async throws {
        let provider = ScriptedExecProvider(events: [
            .stdout(seq: 0, data: Data("needle\n".utf8)),
            .exit(code: 0, signal: nil, truncated: false),
        ])
        let harness = try await start(execProvider: provider, accelerators: ["rg"],
                                      defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        harness.socket.push(try execRequestFrame(seq: 2, execID: "xl1-replay-0",
                                                 argv: ["rg", "needle"]))
        _ = try await harness.socket.waitForFrames(count: 4)
        var frames = harness.socket.sentFrames()
        let firstEvents = try decodedEvents(frames)
        XCTAssertEqual(firstEvents.compactMap { $0["type"] as? String },
                       ["start", "output", "exit"])
        XCTAssertEqual(firstEvents[0]["replayed"] as? Bool, false)
        XCTAssertEqual(provider.runCount, 1)

        // A repeated idem_key replays the recorded stream, start replayed=true.
        harness.socket.push(try execRequestFrame(seq: 3, execID: "xl1-replay-0",
                                                 argv: ["rg", "needle"]))
        _ = try await harness.socket.waitForFrames(count: 7)
        frames = harness.socket.sentFrames()
        let replayed = try decodedEvents(Array(frames.suffix(3)))
        XCTAssertEqual(replayed.compactMap { $0["type"] as? String },
                       ["start", "output", "exit"])
        XCTAssertEqual(replayed[0]["replayed"] as? Bool, true)
        XCTAssertEqual(provider.runCount, 1)
    }

    func testExecRequestForNonAcceleratorIsUnsupported() async throws {
        let provider = ScriptedExecProvider(events: [
            .exit(code: 0, signal: nil, truncated: false),
        ])
        let harness = try await start(execProvider: provider, accelerators: ["rg"],
                                      defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        harness.socket.push(try execRequestFrame(seq: 2, execID: "xl1-bash-0",
                                                 argv: ["bash", "-c", "echo hi"]))
        _ = try await harness.socket.waitForFrames(count: 2)
        let events = try decodedEvents(harness.socket.sentFrames())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"] as? String, "error")
        XCTAssertEqual(events[0]["code"] as? String, "unsupported")
        XCTAssertEqual(provider.runCount, 0)
    }

    func testExecRequestIsRefusedWhenAdmissionIsClosed() async throws {
        let provider = ScriptedExecProvider(events: [])
        let harness = try await start(execProvider: provider, accelerators: ["rg"],
                                      admission: { .closed }, defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        harness.socket.push(try execRequestFrame(seq: 2, execID: "xl1-closed-0",
                                                 argv: ["rg", "x"]))
        _ = try await harness.socket.waitForFrames(count: 2)
        let events = try decodedEvents(harness.socket.sentFrames())
        XCTAssertEqual(events[0]["type"] as? String, "error")
        XCTAssertEqual(events[0]["code"] as? String, "admission_closed")
        XCTAssertEqual(provider.runCount, 0)
    }

    func testExecProviderFailureKeepsTypedDetails() async throws {
        struct Failure: ExecProviderFailure {
            let code: String
            let message: String
        }
        let provider = ScriptedExecProvider(events: [], error: Failure(
            code: "not_configured", message: "mount unavailable"))
        let harness = try await start(execProvider: provider, accelerators: ["rg"], defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        harness.socket.push(try execRequestFrame(seq: 2, execID: "xl1-typed-provider", argv: ["rg", "x"]))
        _ = try await harness.socket.waitForFrames(count: 3)
        let events = try decodedEvents(harness.socket.sentFrames())
        XCTAssertEqual(events.last?["code"] as? String, "not_configured")
        XCTAssertEqual(events.last?["message"] as? String, "mount unavailable")
    }

    func testRequiresMseqUsesCallerDeadline() async throws {
        let provider = ScriptedExecProvider(events: [])
        let harness = try await start(execProvider: provider, accelerators: ["rg"], defaultHandler: true)
        _ = try await sendHello(harness, ChannelHostState())
        let started = Date()
        let deadline = Int64(started.addingTimeInterval(0.05).timeIntervalSince1970 * 1000)
        harness.socket.push(try execRequestFrame(seq: 2, execID: "xl1-short-deadline",
                                                 argv: ["rg", "x"], requiresMseq: 99, deadline: deadline))
        _ = try await harness.socket.waitForFrames(count: 2)
        let events = try decodedEvents(harness.socket.sentFrames())
        XCTAssertEqual(events.last?["code"] as? String, "deadline_exceeded")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(provider.runCount, 0)
    }

    // MARK: - Console, errors and metrics

    func testConsoleIsDispatchedToHandler() async throws {
        let harness = try await start()
        _ = try await sendHello(harness, ChannelHostState())
        let console = ConsolePayload(level: .info, text: "XL_DSH_READY")
        push(harness, .console, seq: 2, payload: try CanonicalJSON.encode(console))
        let delivered = await waitUntil { (await harness.recorder.consoles) == [console] }
        XCTAssertTrue(delivered)
        let metrics = await harness.server.currentMetrics()
        XCTAssertEqual(metrics.framesIn, 2)
        XCTAssertGreaterThanOrEqual(metrics.framesOut, 1)
        XCTAssertGreaterThan(metrics.bytesIn, 0)
        XCTAssertGreaterThan(metrics.bytesOut, 0)
    }

    func testWorkerErrorClosesTheConnection() async throws {
        let harness = try await start()
        _ = try await sendHello(harness, ChannelHostState())
        let payload = try CanonicalJSON.encode(
            ErrorPayload(code: .badPayload, message: "worker gave up"))
        push(harness, .error, seq: 2, payload: payload)
        let code = try await harness.socket.closedCode()
        XCTAssertEqual(code, 1000)
        let errors = await waitUntil { (await harness.recorder.errors).count == 1 }
        XCTAssertTrue(errors)
    }

    // MARK: - Helpers

    private func errorPayload(_ frame: Frame) throws -> ErrorPayload {
        XCTAssertEqual(frame.type, .error)
        return try JSONDecoder().decode(ErrorPayload.self, from: frame.payload)
    }
}

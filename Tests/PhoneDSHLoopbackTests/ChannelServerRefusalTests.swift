// SPDX-License-Identifier: MIT
// channel.md §4.8/§10 host reaction: an ERROR VFS_REFUSED frame is a resource
// diagnostic, not a protocol violation. The ordered channel stays open, the
// server records it, and a later frame is still dispatched. Every other ERROR
// code keeps the fail-loud behaviour and closes the connection.

import Foundation
import XCTest
import PhoneDSHWire
import PhoneDSHLoopback

final class ChannelServerRefusalTests: XCTestCase {
    private struct Harness {
        var server: ChannelServer
        var socket: MockChannelSocket
        var handler: RecordingChannelHandler
    }

    private func start(state: ChannelHostState = ChannelHostState(),
                       workspaceLog: (any LoopbackWorkspaceLog)? = nil,
                       defaultHandler: Bool = false) async throws -> Harness {
        let socket = MockChannelSocket()
        let handler = RecordingChannelHandler(workspaceLog: workspaceLog)
        let server: ChannelServer
        if defaultHandler {
            server = ChannelServer(socket: socket, state: state, handler: nil,
                                   workspaceLog: workspaceLog)
            try await server.installHandler(
                DefaultChannelHandling(outbound: server, workspaceLog: workspaceLog))
        } else {
            server = ChannelServer(socket: socket, state: state, handler: handler,
                                   workspaceLog: workspaceLog)
        }
        Task { await server.run() }
        addTeardownBlock { await server.close() }
        _ = try await socket.waitForFrames(count: 1)
        return Harness(server: server, socket: socket, handler: handler)
    }

    private func sendHello(_ harness: Harness,
                           state: ChannelHostState = ChannelHostState(),
                           lastMseq: UInt64 = 0) async throws {
        let payload = try CanonicalJSON.encode(workerHelloPayload(state: state,
                                                                  lastMseq: lastMseq))
        harness.socket.push(try encodedFrame(.hello, seq: 1, payload: payload))
    }

    private func push(_ harness: Harness, _ type: FrameType, seq: UInt64,
                      payload: Data) throws {
        harness.socket.push(try encodedFrame(type, seq: seq, payload: payload))
    }

    func testVFSRefusedIsADiagnosticAndDoesNotCloseTheConnection() async throws {
        let harness = try await start()
        try await sendHello(harness)
        let refusal = ErrorPayload(path: "/dsh/workspace/a",
                                   limit: 15 * 1024 * 1024,
                                   reason: .fileTooLarge,
                                   message: "EFBIG: VFS refused /dsh/workspace/a")
        try push(harness, .error, seq: 2, payload: try CanonicalJSON.encode(refusal))

        let delivered = await waitUntil { await harness.handler.errors.count == 1 }
        XCTAssertTrue(delivered, "the handler observed the refusal diagnostic")

        // A later frame of the same connection is still dispatched: the server
        // did not treat the diagnostic as a protocol error.
        try push(harness, .console, seq: 3,
                 payload: try CanonicalJSON.encode(ConsolePayload(level: .error,
                                                                 text: "pdsh-vfs: EFBIG")))
        let continued = await waitUntil { await harness.handler.consoles.count == 1 }
        XCTAssertTrue(continued, "the ordered channel stayed open after VFS_REFUSED")

        let metrics = await harness.server.currentMetrics()
        XCTAssertEqual(metrics.vfsRefusals, 1)
        XCTAssertEqual(metrics.lastVFSRefusal?.path, "/dsh/workspace/a")
        XCTAssertEqual(metrics.lastVFSRefusal?.limit, 15 * 1024 * 1024)
        XCTAssertEqual(metrics.lastVFSRefusal?.reason, .fileTooLarge)
        // The server never echoes an ERROR and never closes on this code.
        XCTAssertFalse(harness.socket.sentFrames().contains { $0.type == .error })
        do {
            let code = try await harness.socket.closedCode(timeout: 0.2)
            XCTFail("VFS_REFUSED must not close the connection (close code \(code))")
        } catch {
            // Expected: the socket is still open.
        }
    }

    func testProtocolErrorStillClosesTheConnection() async throws {
        let harness = try await start()
        try await sendHello(harness)
        let error = ErrorPayload(code: .badSeq, message: "expected 2", refSeq: 2)
        try push(harness, .error, seq: 2, payload: try CanonicalJSON.encode(error))

        let code = try await harness.socket.closedCode()
        XCTAssertEqual(code, 1000)
        let metrics = await harness.server.currentMetrics()
        XCTAssertEqual(metrics.vfsRefusals, 0)
        XCTAssertNil(metrics.lastVFSRefusal)
        let delivered = await waitUntil { await harness.handler.errors.count == 1 }
        XCTAssertTrue(delivered)
    }

    func testMalformedRefusalPayloadIsStillAProtocolError() async throws {
        let harness = try await start()
        try await sendHello(harness)
        // `VFS_REFUSED` without path/limit/reason violates channel.md §4.8.
        let malformed = Data("{\"code\":\"VFS_REFUSED\",\"message\":\"EFBIG\"}".utf8)
        try push(harness, .error, seq: 2, payload: malformed)

        let frame = try await harness.socket.nextFrame(after: 1)
        XCTAssertEqual(frame.type, .error)
        let payload = try JSONDecoder().decode(ErrorPayload.self, from: frame.payload)
        XCTAssertEqual(payload.code, .badPayload)
        let code = try await harness.socket.closedCode()
        XCTAssertEqual(code, 1002)
        let metrics = await harness.server.currentMetrics()
        XCTAssertEqual(metrics.vfsRefusals, 0)
    }

    // MARK: - Host-side resource refusal (channel.md §6, §8)

    /// A mutation the host refuses for the single-file budget is answered with
    /// one non-closing `VFS_REFUSED` on the same connection; it consumes no
    /// mseq, so the next mutation may reuse it and is accepted/persisted.
    func testHostResourceRefusalKeepsTheConnectionAndDoesNotConsumeMseq() async throws {
        let log = RecordingWorkspaceLog(nextMseq: 5, singleFileLimitBytes: 4)
        let state = ChannelHostState(ackedMseq: 4, durableMseq: 4)
        let harness = try await start(state: state, workspaceLog: log,
                                      defaultHandler: true)
        try await sendHello(harness, state: state, lastMseq: 4)

        let oversized = VfsMutationBody(op: .write, mode: 0o644,
                                        path: "/dsh/workspace/cap.bin",
                                        data: Data(repeating: 0x41, count: 8))
        try push(harness, .vfsMutation, seq: 2,
                 payload: try VfsMutationPayload.encode(mseq: 5, body: oversized))

        let refusalFrame = try await harness.socket.nextFrame(after: 1)
        XCTAssertEqual(refusalFrame.type, .error,
                       "a host resource refusal is one ERROR frame, not a close")
        let refusal = try JSONDecoder().decode(ErrorPayload.self,
                                               from: refusalFrame.payload)
        XCTAssertEqual(refusal.code, .vfsRefused)
        XCTAssertEqual(refusal.path, "/dsh/workspace/cap.bin")
        XCTAssertEqual(refusal.limit, 4)
        XCTAssertEqual(refusal.reason, .fileTooLarge)
        XCTAssertEqual(refusal.refSeq, 2, "ref_seq names the refused VFS_MUT frame")
        XCTAssertEqual(refusal.mseq, 5,
                       "a host reply carries the refused mseq structurally")
        XCTAssertEqual(refusal.acceptedBytes, 0,
                       "a complete write has no accepted prefix")
        XCTAssertTrue(refusal.message.contains("mseq 5"), refusal.message)
        XCTAssertTrue(refusal.message.contains("0 accepted bytes"), refusal.message)
        XCTAssertFalse(refusal.code.closesConnection)

        // The channel did not close and the refused mutation appended nothing.
        let stillOpen = (try? await harness.socket.closedCode(timeout: 0.2)) == nil
        XCTAssertTrue(stillOpen, "VFS_REFUSED must keep the connection open")
        let appendsAfterRefusal = await log.mutationCount()
        XCTAssertEqual(appendsAfterRefusal, 0, "the refused mutation must not reach the WAL")
        let acceptedAfterRefusal = await harness.server.acceptedMseq()
        XCTAssertEqual(acceptedAfterRefusal, 4,
                       "a refused mutation must not advance expected_mseq")
        let metrics = await harness.server.currentMetrics()
        XCTAssertEqual(metrics.vfsRefusalsSent, 1)
        XCTAssertFalse(harness.socket.sentFrames().contains { $0.type == .vfsAck },
                       "the refused mseq must not be acknowledged")

        // The Worker shrinks the same mutation and resends it with mseq 5.
        let shrunk = VfsMutationBody(op: .write, mode: 0o644,
                                     path: "/dsh/workspace/cap.bin",
                                     data: Data(repeating: 0x42, count: 4))
        try push(harness, .vfsMutation, seq: 3,
                 payload: try VfsMutationPayload.encode(mseq: 5, body: shrunk))
        let ackFrame = try await harness.socket.nextFrame(after: 2)
        XCTAssertEqual(ackFrame.type, .vfsAck)
        let ack = try VfsAckBody.decode(ackFrame.payload)
        XCTAssertEqual(ack.level, .write)
        XCTAssertEqual(ack.uptoMseq, 5, "the resent mutation kept the refused mseq")

        let persisted = await log.mutations
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.data, shrunk.data)
        let acceptedAfterResend = await harness.server.acceptedMseq()
        XCTAssertEqual(acceptedAfterResend, 5)
    }

    /// An appended mutation that would cross the budget reports the accepted
    /// prefix; the worker resends only the suffix that fits, with the same mseq.
    func testHostAppendRefusalReportsTheAcceptedPrefix() async throws {
        let path = "/dsh/workspace/cap.bin"
        let log = RecordingWorkspaceLog(nextMseq: 2, singleFileLimitBytes: 10,
                                        seedSizes: [path: 6])
        let state = ChannelHostState(ackedMseq: 1, durableMseq: 1)
        let harness = try await start(state: state, workspaceLog: log,
                                      defaultHandler: true)
        try await sendHello(harness, state: state, lastMseq: 1)

        let oversized = VfsMutationBody(op: .write, mode: 0o644,
                                        mflags: [.appended], appendFrom: 6,
                                        path: path,
                                        data: Data(repeating: 0x43, count: 8))
        try push(harness, .vfsMutation, seq: 2,
                 payload: try VfsMutationPayload.encode(mseq: 2, body: oversized))
        let refusalFrame = try await harness.socket.nextFrame(after: 1)
        let refusal = try JSONDecoder().decode(ErrorPayload.self,
                                               from: refusalFrame.payload)
        XCTAssertEqual(refusal.code, .vfsRefused)
        XCTAssertEqual(refusal.limit, 10)
        XCTAssertEqual(refusal.refSeq, 2)
        XCTAssertEqual(refusal.mseq, 2)
        XCTAssertEqual(refusal.acceptedBytes, 6,
                       "an appended refusal reports the accepted prefix structurally")
        XCTAssertTrue(refusal.message.contains("6 accepted bytes"), refusal.message)
        let acceptedAfterRefusal = await harness.server.acceptedMseq()
        XCTAssertEqual(acceptedAfterRefusal, 1)

        // Remaining capacity is limit - accepted = 4 bytes; resend at mseq 2.
        let shrunk = VfsMutationBody(op: .write, mode: 0o644,
                                     mflags: [.appended], appendFrom: 6,
                                     path: path,
                                     data: Data(repeating: 0x44, count: 4))
        try push(harness, .vfsMutation, seq: 3,
                 payload: try VfsMutationPayload.encode(mseq: 2, body: shrunk))
        let ackFrame = try await harness.socket.nextFrame(after: 2)
        let ack = try VfsAckBody.decode(ackFrame.payload)
        XCTAssertEqual(ack.uptoMseq, 2)
        let persisted = await log.mutations
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.appendFrom, 6)
        XCTAssertEqual(persisted.first?.data, shrunk.data)
    }
}

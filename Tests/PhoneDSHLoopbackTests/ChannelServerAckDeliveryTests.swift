// SPDX-License-Identifier: MIT
// G2-FIX-10 regression: host ack delivery must be lossless.
//
// Pre-fix `ChannelServer.flushAcks()` cleared the pending entry and sent the
// 0x31 frame with `try?`; one failed send dropped the only ack that could
// resolve the Worker's journal sync, so the tool-journal chain parked and the
// agent loop stopped dispatching model requests. These tests inject a failing
// transport send exactly during that window.

import Foundation
import XCTest
import PhoneDSHWire
import PhoneDSHLoopback

final class ChannelServerAckDeliveryTests: XCTestCase {
    private struct Harness {
        let server: ChannelServer
        let socket: MockChannelSocket
    }

    private func start(
        journalLog: (any LoopbackJournalLog)? = nil,
        policy: AckDeliveryPolicy = AckDeliveryPolicy(maxAttempts: 4,
                                                      initialDelay: 0.005,
                                                      maxDelay: 0.02)
    ) async throws -> Harness {
        let socket = MockChannelSocket()
        let recorder = RecordingChannelHandler()
        let server = ChannelServer(socket: socket,
                                   state: ChannelHostState(),
                                   handler: recorder,
                                   journalLog: journalLog,
                                   ackCoalescingInterval: 0.002,
                                   ackDeliveryPolicy: policy)
        Task { await server.run() }
        addTeardownBlock { await server.close() }
        return Harness(server: server, socket: socket)
    }

    private func sendHello(_ harness: Harness) async throws -> Frame {
        let payload = try CanonicalJSON.encode(workerHelloPayload(state: ChannelHostState(),
                                                                 lastMseq: 0))
        harness.socket.push(try encodedFrame(.hello, seq: 1, payload: payload))
        return try await harness.socket.nextFrame(after: 0)
    }

    private func pushJournal(_ harness: Harness, jseq: UInt64 = 1) throws {
        let body = try JournalBody(jseq: jseq,
                                   sessionID: "session-1",
                                   record: Data("{\"t\":\"start\"}".utf8)).encoded()
        harness.socket.push(try encodedFrame(.journal, seq: 2, payload: body))
    }

    /// Two failed sends during the flush must not drop the 0x31: the bounded
    /// retry re-sends the same cumulative ack.
    func testJournalAckSurvivesTransientSendFailures() async throws {
        let journal = CountingJournalLog()
        let harness = try await start(journalLog: journal)
        _ = try await sendHello(harness)
        harness.socket.failNextSends(2)
        try pushJournal(harness)

        let frames = try await harness.socket.waitForFrames(count: 2)
        XLAssertEqual(frames[0].type, .hello)
        XLAssertEqual(frames[1].type, .journalAck)
        let ack = try JournalAckBody.decode(frames[1].payload)
        XLAssertEqual(ack.level, .write)
        XLAssertEqual(ack.uptoJseq, 1)
        XLAssertEqual(ack.sessionID, "session-1")
        XLAssertEqual(await journal.highestJseq(sessionID: "session-1"), 1)
    }

    /// When every ack attempt fails, the channel must close loud (1011) after
    /// its best-effort ERROR so the Worker's `rejectAll` fires. Pre-fix the ack
    /// was swallowed and the connection stayed open forever.
    func testPersistentAckSendFailureClosesWithError() async throws {
        let policy = AckDeliveryPolicy(maxAttempts: 4,
                                       initialDelay: 0.005,
                                       maxDelay: 0.02)
        let harness = try await start(journalLog: CountingJournalLog(), policy: policy)
        _ = try await sendHello(harness)
        harness.socket.failNextSends(policy.maxAttempts)
        try pushJournal(harness)

        let frames = try await harness.socket.waitForFrames(count: 2)
        XLAssertEqual(frames[1].type, .error)
        let error = try JSONDecoder().decode(ErrorPayload.self, from: frames[1].payload)
        XLAssertEqual(error.code, .ringTimeout)
        XCTAssertTrue(error.message.contains("could not deliver"),
                      "the ERROR message must name the delivery failure: \(error.message)")
        let closeCode = try await harness.socket.closedCode()
        XLAssertEqual(closeCode, 1011)
    }
}

/// Small alias so the assertions read the same on both failure sites.
private func XLAssertEqual<T: Equatable>(_ left: T, _ right: T,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
    XCTAssertEqual(left, right, file: file, line: line)
}

// SPDX-License-Identifier: MIT
// §3.8 sender pacing and §6.2 receiver reassembly-timeout regressions
// (`pclink-v1.5`).

import Foundation
import XCTest
@testable import PhoneDSHPCLink
import PhoneDSHAgentCore

final class PCLinkPacingTests: XCTestCase {
    override func tearDown() async throws {
        await PCLinkTestTracker.stopAll()
        try await super.tearDown()
    }

    // MARK: - Bucket

    func testReferencePacingValuesLeaveMarginUnderTheRelayLimit() {
        XCTAssertLessThan(PCLinkOutboundPacer.referenceRateBytesPerSecond, 1_048_576)
        XCTAssertLessThan(PCLinkOutboundPacer.referenceBurstBytes, 4 * 1_048_576)
        XCTAssertEqual(PCLinkLimits.sendRateBytesPerSecond,
                       PCLinkOutboundPacer.referenceRateBytesPerSecond)
        XCTAssertEqual(PCLinkLimits.sendBurstBytes,
                       PCLinkOutboundPacer.referenceBurstBytes)
    }

    func testPacerWaitsForTokensInsteadOfDropping() {
        var pacer = PCLinkOutboundPacer(rateBytesPerSecond: 1_000, burstBytes: 2_000)
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<2 {
            XCTAssertEqual(pacer.delayBeforeSending(bytes: 1_000, at: start), 0)
            pacer.consume(bytes: 1_000, at: start)
            XCTAssertEqual(pacer.availableTokens, 2_000 - Double(index + 1) * 1_000,
                           "bucket \(index)")
        }
        // Empty bucket: the next 1,000-byte frame waits one second, it is not lost.
        XCTAssertEqual(pacer.delayBeforeSending(bytes: 1_000, at: start), 1, accuracy: 0.001)
        XCTAssertEqual(pacer.delayBeforeSending(bytes: 1_000, at: start.addingTimeInterval(1)), 0)
    }

    func testPacerOverdrawsOneOversizedFrameFromAFullBucket() {
        var pacer = PCLinkOutboundPacer(rateBytesPerSecond: 1_000, burstBytes: 2_000)
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(pacer.delayBeforeSending(bytes: 3_000, at: start), 0)
        pacer.consume(bytes: 3_000, at: start)
        XCTAssertEqual(pacer.availableTokens, -1_000, accuracy: 0.001)
        // Two seconds of refill pays the debt.
        XCTAssertEqual(pacer.delayBeforeSending(bytes: 1_000, at: start.addingTimeInterval(2)), 0)
        // A partly drained bucket must wait for a full bucket before overdrafting.
        var partial = PCLinkOutboundPacer(rateBytesPerSecond: 1_000, burstBytes: 2_000)
        XCTAssertEqual(partial.delayBeforeSending(bytes: 1_000, at: start), 0)
        partial.consume(bytes: 1_000, at: start)
        XCTAssertEqual(partial.delayBeforeSending(bytes: 3_000, at: start), 1, accuracy: 0.001)
    }

    // MARK: - Client single writer

    func testPacedOutboundFramesKeepSeqOrderAndAreDelayed() async throws {
        final class SentTimes: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [(Date, Int64)] = []
            func append(_ value: (Date, Int64)) {
                lock.lock(); defer { lock.unlock() }
                storage.append(value)
            }
            var values: [(Date, Int64)] {
                lock.lock(); defer { lock.unlock() }
                return storage
            }
        }
        let sent = SentTimes()
        let fixture = try await PCLinkTestFixture.make(
            configure: { config in
                // Deliberately tiny bucket so the test does not sleep long.
                config.sendRateBytesPerSecond = 2_000
                config.sendBurstBytes = 300
            },
            clientSendHook: { text in
                guard let frame = try? PCLinkJSONParser.parseObject(Data(text.utf8)),
                      frame["type"]?.stringValue == "e2e",
                      let seq = frame["seq"]?.intValue else { return }
                sent.append((Date(), seq))
            })
        let args: PCLinkJSON = .object(["_request": .object([:])])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await fixture.transport.call("session/list", args: args.jsonValue)
                }
            }
            try await group.waitForAll()
        }
        let seqs = await fixture.server.receivedSeqs
        XCTAssertEqual(seqs, (0..<Int64(seqs.count)).map { $0 },
                       "pacing must not let a later seq overtake an earlier one")
        let e2e = sent.values
        XCTAssertGreaterThanOrEqual(e2e.count, 8)
        let span = (e2e.last?.0 ?? Date()).timeIntervalSince(e2e.first?.0 ?? Date())
        XCTAssertGreaterThan(span, 0.35,
                             "the writer must wait for local tokens instead of bursting all frames")
    }

    // MARK: - Relay rate_limited

    func testRateLimitedSendsATerminalCloseBeforeRehandshaking() async throws {
        let fixture = try await PCLinkTestFixture.make { server in
            await server.setPolicy(.rateLimitedFirst(retryAfterMs: 150), for: "session/list")
        }
        _ = try await fixture.transport.call("session/list",
                                             args: .object(["_request": .object([:])]))
        let closes = await fixture.server.receivedCloseCodes
        XCTAssertTrue(closes.contains("rate_limited"),
                      "the PC must learn the session is dead without waiting for a chunk timeout")
        let handshakes = await fixture.server.handshakes
        XCTAssertEqual(handshakes, 2)
    }

    // MARK: - Receiver reassembly timeout

    func testPartialResultTimesOutAndReadCallRetries() async throws {
        let fixture = try await PCLinkTestFixture.make { config in
            config.chunkReassemblyTimeout = 0.1
        } prepareServer: { server in
            await server.setPolicy(.partialResultFirst, for: "session/list")
        }
        let result = try await fixture.transport.call("session/list",
                                                      args: .object(["_request": .object([:])]))
        XCTAssertNotNil(result.objectValue)
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 2, "a read call must retry after the reassembly timeout")
    }

    func testPartialStreamChunkTimesOutCancelsAndFailsRetryably() async throws {
        let fixture = try await PCLinkTestFixture.make(
            configure: { config in config.chunkReassemblyTimeout = 0.1 },
            prepareServer: { server in
                await server.setStreamPolicy(.partialChunkThenAwaitCancel, for: "session/follow")
            })
        let mux = try await fixture.transport.openMux()
        try await mux.send(.object([
            "type": .string("open"), "streamId": .string("follow"),
            "endpoint": .string("session/follow"),
            "payload": .object(["args": .object([:])]),
        ]))
        let frame = try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask { try await mux.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw PCLinkError.unavailable("stream chunk timeout did not fire")
            }
            guard let value = try await group.next() else {
                throw PCLinkError.unavailable("stream chunk timeout did not fire")
            }
            group.cancelAll()
            return value
        }
        XCTAssertEqual(frame?["type"]?.stringValue, "error")
        XCTAssertEqual(frame?["error"]?["code"]?.stringValue, "gateway/service-unavailable",
                       "a read-class stream must surface a retryable error")
        let opens = await fixture.server.opens
        XCTAssertEqual(opens.count, 1)
        let wireID = opens[0].streamId
        var cancelled = false
        for _ in 0..<50 {
            let cancels = await fixture.server.cancels
            if cancels.contains(wireID) { cancelled = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cancelled, "the receiver must cancel the stalled stream on the PC")
        await mux.close()
    }
}

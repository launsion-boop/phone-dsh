// SPDX-License-Identifier: MIT
// Phase 2 real-time supervision: the Bot page's watch and live loops must
// survive a stalled call, a throwing call and a live stream that ends when the
// observer is replaced. These tests drive the real `BotChatModel` loops with
// counting drivers; the production timings are shrunk to milliseconds so a
// stall is observable without waiting the real 5 s / 20 s windows.
//
// These are regressions for the field failure: the main Bot answered seven
// seconds after the user's message and the page showed nothing until it was
// backgrounded and foregrounded again. On the phase-1 tree the watch loop had
// no deadline (one wedged call froze it), the live loop returned when the
// stream ended, and the model exposed no feed health at all, so these tests
// cannot pass there.

import Foundation
import XCTest

@MainActor
final class BotChatSupervisionTests: XCTestCase {
    /// Thread-safe counters for the driver closures. The production loops call
    /// the driver on the main actor, but the counters are also touched from the
    /// abandoned-call tasks, so they stay lock-protected.
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var cursors: [Int] = []
        private var liveSubscriptions = 0

        func noteWatch(_ cursor: Int) {
            lock.lock(); cursors.append(cursor); lock.unlock()
        }

        func noteLiveSubscription() -> Int {
            lock.lock()
            liveSubscriptions += 1
            let value = liveSubscriptions
            lock.unlock()
            return value
        }

        var watchCursors: [Int] {
            lock.lock(); defer { lock.unlock() }
            return cursors
        }

        var liveSubscriptionCount: Int {
            lock.lock(); defer { lock.unlock() }
            return liveSubscriptions
        }
    }

    /// One provider that reports degraded for the first few reads and then
    /// recovers, mirroring the phase-1 row service (which returns an empty
    /// non-reset batch while degraded instead of throwing).
    private final class HealthProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private let degradedReads: Int

        init(degradedReads: Int) { self.degradedReads = degradedReads }

        func next() -> BotFeedHealth {
            lock.lock()
            reads += 1
            let value = reads
            lock.unlock()
            guard value <= degradedReads else { return .healthy }
            return .degraded(reason: "session-log", since: 1_700_000_000_000)
        }
    }

    private enum TestError: Error {
        case boom
    }

    /// A live stream that stays open and never yields, so the watchdog's
    /// stall path (not the stream-end path) is what must re-subscribe.
    private final class LiveSink: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<BotLiveFrame>.Continuation?

        func makeStream() -> AsyncStream<BotLiveFrame> {
            let (stream, continuation) = AsyncStream<BotLiveFrame>.makeStream()
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            return stream
        }

        func finish() {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.finish()
        }
    }

    private func context() -> BotRuntimeContext {
        BotRuntimeContext(botID: "main", botName: "大肥鱼")
    }

    private func makeDriver(
        counters: Counters,
        watch: @escaping (Int) async throws -> BotUIRowBatch,
        liveFrames: @escaping () async -> AsyncStream<BotLiveFrame>
    ) -> BotChatDriver {
        BotChatDriver(
            history: { _, _ in BotUIHistoryPage(rows: [], nextCursor: nil, hasMore: false) },
            watch: { cursor in
                counters.noteWatch(cursor)
                return try await watch(cursor)
            },
            perform: { _ in .rejected(reason: "unused") },
            stopCurrentTurn: { _ in },
            turnProcesses: { [:] },
            liveFrames: liveFrames,
            presentation: { BotRuntimePresentation() })
    }

    private func makeModel(
        counters: Counters,
        watch: @escaping (Int) async throws -> BotUIRowBatch,
        liveFrames: @escaping () async -> AsyncStream<BotLiveFrame> = {
            AsyncStream { $0.finish() }
        }
    ) -> BotChatModel {
        BotChatModel(context: context(),
                     driver: makeDriver(counters: counters, watch: watch,
                                        liveFrames: liveFrames))
    }

    private func emptyBatch(_ cursor: Int, reset: Bool = false) -> BotUIRowBatch {
        BotUIRowBatch(rows: [], deletes: [], cursor: cursor, reset: reset)
    }

    /// Waits on the main actor so a test only sleeps as long as the supervision
    /// it exercises needs.
    private func waitUntil(timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    // MARK: - Watch supervision

    /// A `watch` that never returns must not freeze the loop: after the
    /// deadline the poll is abandoned and the next iteration calls the driver
    /// again. The phase-1 loop awaited the call forever (one call only).
    func testStalledWatchIsAbandonedAndRetried() async throws {
        let counters = Counters()
        let model = makeModel(counters: counters, watch: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw TestError.boom
        })
        model.watchHealthProvider = { .healthy }
        model.supervision = BotChatSupervision(
            watchInterval: 0.01, watchDeadline: 0.1, degradedBackoff: [0.01, 0.01])
        let loop = Task { await model.watchLoop() }
        defer {
            loop.cancel()
            model.setPageActive(false)
        }

        try await waitUntil { counters.watchCursors.count >= 3 }
        XCTAssertGreaterThanOrEqual(counters.watchCursors.count, 3)
        XCTAssertTrue(model.feedHealth.isDegraded,
                      "an abandoned poll must not be reported as healthy")
        XCTAssertEqual(model.runtimeNotice, BotChatModel.feedDegradedNotice,
                       "the header shows the calm reconnect line while degraded")
    }

    /// A throwing driver is a transient failure: the loop keeps polling and the
    /// feed returns to `.healthy` (and the header clears) once a poll succeeds.
    func testThrowingWatchKeepsLoopingAndEndsHealthy() async throws {
        let counters = Counters()
        let model = makeModel(counters: counters, watch: { cursor in
            if counters.watchCursors.count == 1 { throw TestError.boom }
            return self.emptyBatch(cursor + 1)
        })
        model.watchHealthProvider = { .healthy }
        model.supervision = BotChatSupervision(
            watchInterval: 0.01, watchDeadline: 0.5, degradedBackoff: [0.3])
        let loop = Task { await model.watchLoop() }
        defer {
            loop.cancel()
            model.setPageActive(false)
        }

        try await waitUntil { model.feedHealth.isDegraded }
        XCTAssertEqual(model.feedHealth.reason, "watch-error")
        XCTAssertEqual(model.runtimeNotice, BotChatModel.feedDegradedNotice)

        try await waitUntil {
            counters.watchCursors.count >= 2 && !model.feedHealth.isDegraded
        }
        XCTAssertEqual(model.feedHealth, .healthy)
        XCTAssertNil(model.runtimeNotice, "recovery clears the reconnect line")
        XCTAssertGreaterThanOrEqual(counters.watchCursors.count, 2,
                                    "the loop must keep polling after a throw")
    }

    /// The row service reports degradation without throwing (phase 1 returns an
    /// empty non-reset batch and keeps its health on the service). The model
    /// must surface that verdict from the injected health provider, and clear
    /// it when the service recovers — the driver seam stays at seven members.
    func testFeedHealthFromRowServiceSurfacesAndClears() async throws {
        let counters = Counters()
        let provider = HealthProvider(degradedReads: 4)
        let model = makeModel(counters: counters, watch: { cursor in
            self.emptyBatch(cursor + 1)
        })
        model.watchHealthProvider = { provider.next() }
        model.supervision = BotChatSupervision(
            watchInterval: 0.02, watchDeadline: 0.5, degradedBackoff: [0.05])
        let loop = Task { await model.watchLoop() }
        defer {
            loop.cancel()
            model.setPageActive(false)
        }

        try await waitUntil {
            model.feedHealth == .degraded(reason: "session-log", since: 1_700_000_000_000)
        }
        XCTAssertEqual(model.runtimeNotice, BotChatModel.feedDegradedNotice)

        try await waitUntil { model.feedHealth == .healthy }
        XCTAssertNil(model.runtimeNotice)
    }

    /// A forced resync must not wait for the healthy cadence: it interrupts the
    /// parked loop, and the next poll replays from cursor 0 (the row service's
    /// reset batch) instead of from the last seen cursor.
    func testForcedResyncReplaysFromCursorZeroImmediately() async throws {
        let counters = Counters()
        let model = makeModel(counters: counters, watch: { cursor in
            self.emptyBatch(cursor + 10, reset: cursor == 0)
        })
        model.watchHealthProvider = { .healthy }
        // Five seconds of healthy cadence: only the resync signal can make the
        // second read immediate.
        model.supervision = BotChatSupervision(
            watchInterval: 5, watchDeadline: 1, degradedBackoff: [0.01])
        let loop = Task { await model.watchLoop() }
        defer {
            loop.cancel()
            model.setPageActive(false)
        }

        try await waitUntil { counters.watchCursors == [0] }
        model.forceResync(.rebind)
        try await waitUntil(timeout: 1) { counters.watchCursors.count >= 2 }
        XCTAssertEqual(counters.watchCursors.last, 0,
                       "a resync must replay the durable projection from cursor 0")
        XCTAssertEqual(model.lastResync, .rebind)
    }

    // MARK: - Live supervision

    /// A finished live stream (the observer was replaced by a rebind) must be
    /// re-subscribed, and a frame from the new subscription must reach the
    /// model. The phase-1 loop returned on `finish` and the reply never
    /// appeared until the page was rebuilt.
    func testEndedLiveStreamResubscribesAndDeliversLaterFrame() async throws {
        let counters = Counters()
        let model = makeModel(
            counters: counters,
            watch: { cursor in self.emptyBatch(cursor + 1) },
            liveFrames: {
                if counters.noteLiveSubscription() == 1 {
                    // The first observer is gone: its stream ends.
                    return AsyncStream { $0.finish() }
                }
                return AsyncStream { continuation in
                    continuation.yield(.textDelta("迟到的回复"))
                }
            })
        model.supervision = BotChatSupervision(
            liveReconnectDelay: 0.01, liveStallTimeout: 5, liveStallCheckInterval: 0.05)
        let loop = Task { await model.liveLoop() }
        defer {
            loop.cancel()
            model.setPageActive(false)
        }

        try await waitUntil { counters.liveSubscriptionCount >= 2 && model.isStreamingNow }
        XCTAssertGreaterThanOrEqual(counters.liveSubscriptionCount, 2,
                                    "the ended stream must be re-subscribed")
        try await waitUntil { model.live?.buffer == "迟到的回复" }
        XCTAssertEqual(model.live?.buffer, "迟到的回复",
                       "a frame on the new subscription must reach the transcript")
    }

    /// A running turn that stops producing frames must be re-subscribed by the
    /// watchdog; waiting forever on a silent observer is the same field failure
    /// as an ended stream.
    func testSilentLiveTurnResubscribesAfterStall() async throws {
        let counters = Counters()
        let silent = LiveSink()
        defer { silent.finish() }
        let model = makeModel(
            counters: counters,
            watch: { cursor in self.emptyBatch(cursor + 1) },
            liveFrames: {
                if counters.noteLiveSubscription() == 1 {
                    return silent.makeStream()
                }
                return AsyncStream { continuation in
                    continuation.yield(.textDelta("重连后的回复"))
                }
            })
        model.supervision = BotChatSupervision(
            liveReconnectDelay: 0.01, liveStallTimeout: 0.1, liveStallCheckInterval: 0.05)
        // A turn is running, so a silent live stream is a stall, not idle.
        model.beginTurn(turnID: "turn-stall")
        let loop = Task { await model.liveLoop() }
        defer {
            loop.cancel()
            model.setPageActive(false)
        }

        try await waitUntil { counters.liveSubscriptionCount >= 2 }
        // `receive` coalesces the text delta for 80 ms. The re-subscribed
        // turn is still running, so further watchdogs may append the same
        // frame again; the first delivered text is what proves the path.
        try await waitUntil { model.live?.buffer.contains("重连后的回复") == true }
        XCTAssertGreaterThanOrEqual(model.liveReconnects, 1)
    }

    /// A rebind can hand the page a new driver while the loops are parked. The
    /// loops must re-subscribe on the new driver instead of staying attached to
    /// the old one; one generation token keeps the old subscription harmless.
    func testDriverSwapResubscribesOnTheNewDriver() async throws {
        let first = Counters()
        let second = Counters()
        let silent = LiveSink()
        defer { silent.finish() }
        let model = makeModel(
            counters: first,
            watch: { cursor in self.emptyBatch(cursor + 1) },
            liveFrames: {
                first.noteLiveSubscription()
                return silent.makeStream()
            })
        model.watchHealthProvider = { .healthy }
        model.supervision = BotChatSupervision(
            watchInterval: 5, watchDeadline: 1, degradedBackoff: [0.01],
            liveReconnectDelay: 0.01, liveStallTimeout: 5, liveStallCheckInterval: 0.05)
        let watchLoop = Task { await model.watchLoop() }
        let liveLoop = Task { await model.liveLoop() }
        defer {
            watchLoop.cancel()
            liveLoop.cancel()
            model.setPageActive(false)
        }

        try await waitUntil {
            first.watchCursors.count == 1 && first.liveSubscriptionCount == 1
        }
        let replacement = makeDriver(
            counters: second,
            watch: { cursor in self.emptyBatch(cursor + 1) },
            liveFrames: {
                second.noteLiveSubscription()
                return silent.makeStream()
            })
        model.replaceDriver(replacement)
        XCTAssertEqual(model.lastResync, .rebind)
        try await waitUntil { second.watchCursors == [0] }
        try await waitUntil { second.liveSubscriptionCount >= 1 }
    }
}

// SPDX-License-Identifier: MIT
// Host §10.3.3–§10.3.4: the projection is pure; the scheduler applies it to
// the resident timer and the OS background channels. The scheduler's clock is
// injected so every assertion here is exact and deterministic.
import XCTest
import ProbeKit

@MainActor
final class WakeSchedulerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wake-scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func demand(_ key: String, dueAtMs: Int64,
                        kind: WakeDemandKind = .once) -> WakeDemand {
        WakeDemand(source: .hostRetry, key: key, dueAtMs: dueAtMs,
                   kind: kind, userVisible: false)
    }

    private final class Recorder {
        var wakeCount = 0
        var projected: [Int64?] = []
        var resident = true
        var nowMs: Int64 = 1_800_000_000_000
    }

    private func makeScheduler(_ recorder: Recorder,
                               overdueRetryMs: Int64 = 60_000) -> WakeScheduler {
        WakeScheduler(
            ledger: WakeDemandLedger(directory: directory),
            projection: WakeScheduler.Projection(
                wake: { recorder.wakeCount += 1 },
                project: { recorder.projected.append($0) },
                isResident: { recorder.resident }),
            now: { recorder.nowMs },
            overdueRetryMs: overdueRetryMs)
    }

    /// A scheduler whose wake path mirrors `EngineLaunchOrchestrator`: it
    /// refreshes the projection before deciding, then leaves an unconsumed
    /// demand in place (an explicit stop, a failed boot, a gated step).
    private final class RefreshingRef {
        var scheduler: WakeScheduler?
    }

    func testOverdueDemandIsRetriedAtMostOncePerRetryWindow() async throws {
        let recorder = Recorder()
        let ref = RefreshingRef()
        let scheduler = WakeScheduler(
            ledger: WakeDemandLedger(directory: directory),
            projection: WakeScheduler.Projection(
                wake: {
                    recorder.wakeCount += 1
                    await ref.scheduler?.refresh()
                },
                project: { recorder.projected.append($0) },
                isResident: { recorder.resident }),
            now: { recorder.nowMs },
            overdueRetryMs: 10_000)
        ref.scheduler = scheduler
        scheduler.start()
        let now = recorder.nowMs
        // A due routine the wake cannot consume (for example the user stopped
        // the engine): without the retry window this is the reported 0-delay
        // spin (tens of thousands of wakes per second).
        try await scheduler.upsert(demand("stuck", dueAtMs: now - 1, kind: .recurring))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(recorder.wakeCount, 1,
                       "an unconsumed overdue demand must not re-arm the resident timer at zero delay")
        scheduler.stop()
    }

    func testResidentTimerFiresAtTheEarliestDueTime() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder)
        scheduler.start()
        let dueAt = recorder.nowMs + 80
        try await scheduler.upsert(demand("soon", dueAtMs: dueAt))
        let deadline = Date().addingTimeInterval(3)
        while recorder.wakeCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(recorder.wakeCount, 1)
        scheduler.stop()
    }

    func testNotResidentSchedulesNoTimerButStillProjectsBackground() async throws {
        let recorder = Recorder()
        recorder.resident = false
        let scheduler = makeScheduler(recorder)
        scheduler.start()
        let now = recorder.nowMs
        try await scheduler.upsert(demand("later", dueAtMs: now + 120_000))
        XCTAssertEqual(recorder.wakeCount, 0)
        XCTAssertEqual(recorder.projected.last, now + 120_000)
        scheduler.stop()
    }

    func testEveryLedgerChangeReprojectsTheClampedEarliest() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder)
        scheduler.start()
        let now = recorder.nowMs
        // Far future: the background request is the due time itself.
        try await scheduler.upsert(demand("later", dueAtMs: now + 180_000))
        XCTAssertEqual(recorder.projected.last, now + 180_000)
        // Near future: clamped to now + minBackgroundDelayMs, while the
        // resident timer stays exact.
        try await scheduler.upsert(demand("near", dueAtMs: now + 5_000))
        XCTAssertEqual(recorder.projected.last, now + 60_000)
        try await scheduler.remove(source: .hostRetry, key: "near")
        XCTAssertEqual(recorder.projected.last, now + 180_000)
        try await scheduler.removeAll(source: .hostRetry)
        XCTAssertEqual(recorder.projected.last, .some(nil))
        scheduler.stop()
    }

    func testBackgroundBoundaryIsExactAtOneMillisecondAroundTheClamp() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder)
        scheduler.start()
        let now = recorder.nowMs

        // earliest is 1 ms before now+minBackgroundDelayMs: clamped up.
        try await scheduler.upsert(demand("before", dueAtMs: now + 59_999))
        XCTAssertEqual(recorder.projected.last, now + 60_000)
        try await scheduler.remove(source: .hostRetry, key: "before")
        // Exactly at the boundary: max() keeps the same value.
        try await scheduler.upsert(demand("boundary", dueAtMs: now + 60_000))
        XCTAssertEqual(recorder.projected.last, now + 60_000)
        try await scheduler.remove(source: .hostRetry, key: "boundary")
        // A demand past the minimum delay: the due time wins.
        try await scheduler.upsert(demand("past", dueAtMs: now + 60_001))
        XCTAssertEqual(recorder.projected.last, now + 60_001)
        try await scheduler.remove(source: .hostRetry, key: "past")
        // Overdue demand: due now, background still clamped.
        try await scheduler.upsert(demand("overdue", dueAtMs: now - 1_000))
        XCTAssertEqual(recorder.projected.last, now + 60_000)
        scheduler.stop()
    }

    func testEnterBackgroundAlwaysProjectsExactly() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder)
        scheduler.start()
        let now = recorder.nowMs
        try await scheduler.upsert(demand("later", dueAtMs: now + 120_000))
        let before = recorder.projected.count
        await scheduler.enterBackground()
        XCTAssertEqual(recorder.projected.count, before + 1)
        XCTAssertEqual(recorder.projected.last, now + 120_000)
        scheduler.stop()
    }

    func testUnavailableLedgerKeepsThePreviousProjection() async throws {
        let file = directory.appendingPathComponent("wake-demands.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder)
        scheduler.start()
        // Give the start's refresh a turn.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(scheduler.lastError)
        XCTAssertTrue(recorder.projected.isEmpty,
                      "an unreadable ledger must not project an empty one")
        scheduler.stop()
    }
}

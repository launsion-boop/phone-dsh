// SPDX-License-Identifier: MIT
// PLAN §2.9 I5: the host timer fires at the earliest due demand, and every
// ledger change re-projects the earliest due time onto the OS channels.
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
        WakeDemand(source: .hostRetries, key: key, dueAtMs: dueAtMs,
                   kind: kind, userVisible: false)
    }

    private final class ProjectionRecorder {
        var wakeCount = 0
        var projected: [Int64?] = []
    }

    private func makeScheduler(_ recorder: ProjectionRecorder) -> WakeScheduler {
        WakeScheduler(
            ledger: WakeDemandLedger(directory: directory),
            projection: WakeScheduler.Projection(
                wake: { recorder.wakeCount += 1 },
                project: { recorder.projected.append($0) }))
    }

    func testResidentTimerWakesAtEarliestDueTime() async throws {
        let recorder = ProjectionRecorder()
        let scheduler = makeScheduler(recorder)
        scheduler.start()
        let dueAt = WakeDemandLedger.nowMs() + 60
        try await scheduler.upsert(demand("soon", dueAtMs: dueAt))
        let deadline = Date().addingTimeInterval(3)
        while recorder.wakeCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(recorder.wakeCount, 1)
        scheduler.stop()
    }

    func testEveryLedgerChangeReprojectsTheEarliestDueTime() async throws {
        let recorder = ProjectionRecorder()
        let scheduler = makeScheduler(recorder)
        scheduler.start()
        let now = WakeDemandLedger.nowMs()
        try await scheduler.upsert(demand("later", dueAtMs: now + 120_000))
        XCTAssertEqual(recorder.projected.last, now + 120_000)
        try await scheduler.upsert(demand("earlier", dueAtMs: now + 60_000))
        XCTAssertEqual(recorder.projected.last, now + 60_000)
        try await scheduler.remove(source: .hostRetries, key: "earlier")
        XCTAssertEqual(recorder.projected.last, now + 120_000)
        try await scheduler.removeAll(source: .hostRetries)
        XCTAssertEqual(recorder.projected.last, .some(nil))
        scheduler.stop()
    }

    func testEnterBackgroundAlwaysProjects() async throws {
        let recorder = ProjectionRecorder()
        let scheduler = makeScheduler(recorder)
        scheduler.start()
        let now = WakeDemandLedger.nowMs()
        try await scheduler.upsert(demand("later", dueAtMs: now + 60_000))
        let before = recorder.projected.count
        await scheduler.enterBackground()
        XCTAssertEqual(recorder.projected.count, before + 1)
        XCTAssertEqual(recorder.projected.last, now + 60_000)
        scheduler.stop()
    }
}

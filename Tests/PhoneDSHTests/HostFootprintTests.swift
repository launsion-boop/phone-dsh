// SPDX-License-Identifier: MIT
// GAP-39 / budgets.md §3 (R1, 2026-11-13): the host-process `phys_footprint`
// input.
//
// These tests drive the real `task_info(TASK_VM_INFO)` syscall and the landed
// host pressure path; the footprint value is never stubbed. The UIKit memory
// warning cannot be posted on the macOS test host, so the existing
// `handleSystemMemoryPressureWarningForTesting()` seam drives the same handler
// that the platform notification drives in production.

import Foundation
import XCTest
import PhoneDSHController
@testable import PhoneDSH

final class HostFootprintTests: XCTestCase {
    private let mib = 1024 * 1024

    /// 1 MiB ... 4 GiB: wide enough for a minimal XCTest process (the real
    /// pressure-path reading was just under 10 MB on a fresh runner), narrow
    /// enough to catch a missing/zero reading, a page count, or a runaway
    /// value.
    private var plausibleFootprintRange: ClosedRange<Int> {
        1 * mib ... 4 * 1024 * mib
    }

    /// The sampler reads the quantity budgets.md §3 names — the App process
    /// `phys_footprint` from `TASK_VM_INFO` — through the real syscall.
    func testSamplerReturnsTheRealAppProcessFootprint() throws {
        let footprint = try XCTUnwrap(
            PhoneDSHHostFootprintSampler.sampleBytes(),
            "task_info(TASK_VM_INFO) must return the host footprint on Apple platforms")
        XCTAssertGreaterThan(footprint, 0,
                             "a missing sample is not a zero reading")
        XCTAssertTrue(plausibleFootprintRange.contains(footprint),
                      "phys_footprint \(footprint) is outside 1 MiB ... 4 GiB")
    }

    /// One §4 `App process` booking per Worker epoch: a second report in the
    /// same epoch is refused and the snapshot keeps the first value. The
    /// footprint never appears as an engine-heap sample.
    func testHostBooksOneFootprintPerWorkerEpoch() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        try await host.start()

        // A missing sample is not a zero reading (budgets.md §3).
        let absent = await host.reportHostFootprintBytes(nil)
        XCTAssertFalse(absent)
        let zero = await host.reportHostFootprintBytes(0)
        XCTAssertFalse(zero)
        let initial = await host.diagnostics()
        XCTAssertNil(try XCTUnwrap(initial.budget).appProcessFootprintBytesUsed)

        let first = 120 * mib
        let recorded = await host.reportHostFootprintBytes(first)
        XCTAssertTrue(recorded, "the first sample of the epoch is booked")
        let duplicate = await host.reportHostFootprintBytes(first + 512 * 1024)
        XCTAssertFalse(duplicate,
                       "a second sample of the same epoch must not be booked")

        let diagnostics = await host.diagnostics()
        let budget = try XCTUnwrap(diagnostics.budget)
        XCTAssertEqual(budget.appProcessFootprintBytesUsed, first)
        XCTAssertNil(budget.engineHeapBytesUsed,
                     "the host footprint must not be reported as the engine heap")
        try await host.stop()
    }

    /// The existing memory-pressure warning samples the real footprint and
    /// publishes "pressure event + current footprint" together. The action
    /// order is unchanged: a fresh host has no `/dsh/tmp` bytes to clear, so
    /// the warning still reaches the same planned restart.
    func testMemoryPressureWarningCarriesTheHostFootprint() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        try await host.start()

        await host.handleSystemMemoryPressureWarningForTesting()

        let diagnostics = await host.diagnostics()
        let budget = try XCTUnwrap(diagnostics.budget)
        let footprint = try XCTUnwrap(
            budget.appProcessFootprintBytesUsed,
            "the warning path must carry the host footprint")
        XCTAssertTrue(plausibleFootprintRange.contains(footprint),
                      "phys_footprint \(footprint) is outside 1 MiB ... 4 GiB")
        XCTAssertNil(budget.engineHeapBytesUsed,
                     "the footprint is the App process row, not the engine heap")
        XCTAssertEqual(engine.bootCount, 2,
                       "the existing warning -> plannedRestart path still runs")

        // The restart closed a Worker epoch, so the next reading is a new
        // booking even though the pre-restart epoch was already booked.
        let next = await host.reportHostFootprintBytes(footprint + mib)
        XCTAssertTrue(next, "a new Worker epoch books a new App process reading")
        try await host.stop()
    }

    /// Pure observation: a footprint above §4's `App process` row is recorded
    /// and reported but selects no budget action yet, and is never converted
    /// into an engine-heap percentage. The frozen `engine heap > 75% for 3
    /// samples` clause therefore stays `target`, exactly as budgets.md §3 says.
    func testFootprintDoesNotDriveBudgetActionsOrTheEngineHeapRow() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let engine = MockEngine(worker: MockWorker())
        let host = PhoneDSHHost(configuration: try fixture.configuration(),
                                engineFactory: { _ in engine })
        try await host.start()

        let initial = await host.diagnostics()
        let table = try XCTUnwrap(initial.budget).table
        let aboveTheAppProcessRow = table.appProcessBytes * 2
        let recorded = await host.reportHostFootprintBytes(aboveTheAppProcessRow)
        XCTAssertTrue(recorded)

        let diagnostics = await host.diagnostics()
        let budget = try XCTUnwrap(diagnostics.budget)
        XCTAssertEqual(budget.appProcessFootprintBytesUsed, aboveTheAppProcessRow)
        XCTAssertNil(budget.lastAction,
                     "the footprint is an input, not an enforcement threshold, in this unit")
        XCTAssertNil(budget.engineHeapBytesUsed,
                     "the footprint must not be fed to reportEngineHeapBytes")
        XCTAssertTrue(budget.isWithinEngineHeapLimit,
                      "the footprint did not lower or replace the engine-heap budget")
        try await host.stop()
    }
}

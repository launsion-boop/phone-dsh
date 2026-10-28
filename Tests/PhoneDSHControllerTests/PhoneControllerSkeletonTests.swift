// SPDX-License-Identifier: MIT
// W0 skeleton checks for PhoneDSHController (PLAN §2.4/§2.5).

import Foundation
import XCTest
import PhoneDSHController

final class PhoneControllerSkeletonTests: XCTestCase {
    func testHostStateHasNineStates() {
        XCTAssertEqual(HostState.allCases.count, 9)
        XCTAssertEqual(Set(HostState.allCases.map(\.rawValue)), [
            "running", "draining", "parked", "recovering", "backoff",
            "handingOff", "remote", "reclaiming", "failed",
        ])
    }

    func testStepStateHasEightStates() {
        XCTAssertEqual(StepState.allCases.count, 8)
        XCTAssertEqual(StepState.allCases.map(\.rawValue), [
            "model_streaming", "tool_dispatched", "exec_running", "exit_persisted",
            "checkpoint_applied", "wal_written", "journaled", "abandoned",
        ])
        XCTAssertTrue(StepState.journaled.isTerminal)
        XCTAssertTrue(StepState.abandoned.isTerminal)
        XCTAssertFalse(StepState.toolDispatched.isTerminal)
    }

    func testFenceTokenCarriesGeneration() {
        let token = FenceToken(owner: "phone", generation: 3, walSeq: 41)
        XCTAssertEqual(token.generation, 3)
        XCTAssertEqual(token.wireFence.walSeq, 41)
    }

    func testBudgetTableMatchesPlanConstants() {
        let budget = BudgetTable.eightGB
        // budgets.md §4: the workspace bucket holds two 64 MiB files plus
        // headroom; the VFS and heap caps cover the three buckets.
        XCTAssertEqual(budget.engineHeapBytes, 320 * 1024 * 1024)
        XCTAssertEqual(budget.vfsLogicalBytes, 260 * 1024 * 1024)
        XCTAssertEqual(budget.workspaceBytes, 160 * 1024 * 1024)
        XCTAssertEqual(budget.sessionBytes, 50 * 1024 * 1024)
        XCTAssertEqual(budget.tmpBytes, 50 * 1024 * 1024)
        XCTAssertEqual(budget.singleFileBytes, 64 * 1024 * 1024)
        XCTAssertEqual(budget.maximumSingleFileBytes, 128 * 1024 * 1024)
        XCTAssertEqual(budget.wasiHotInstanceBytes, 260 * 1024 * 1024)
        XCTAssertEqual(budget.appProcessBytes, 150 * 1024 * 1024)
        XCTAssertEqual(budget.maxSubAgents, 2)
        XCTAssertEqual(budget.thermalFairSubAgents, 1)
        XCTAssertEqual(budget.loopbackRoundTripP95Milliseconds, 5)
        XCTAssertEqual(budget.plannedRestartIntervalSeconds, 7200)
        XCTAssertEqual(budget.recoveryBaseSeconds, 3)
        XCTAssertEqual(budget.recoverySecondsPerMegabyte, 0.05)
        XCTAssertEqual(DeviceTier.default, .eightGB)
        XCTAssertEqual(BudgetTable.table(for: .eightGB), budget)
    }

    func testSignalsAreDocumentedAsStreams() {
        XCTAssertEqual(ScenePhase.allCases.count, 3)
        XCTAssertEqual(NetworkPathStatus.allCases.count, 3)
    }
}

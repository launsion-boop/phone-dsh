// SPDX-License-Identifier: MIT
// PhoneDSHController: budget table constants, tier rows and the
// clearTmp -> plannedRestart -> handoff action order (budgets.md §4).

import Foundation
import XCTest
@testable import PhoneDSHController
import PhoneDSHLog

final class BudgetMonitorTests: XCTestCase {
    private let mb = 1024 * 1024

    private func sample(workspace: Int = 0, sessions: Int = 0, tmp: Int = 0,
                        terminations: UInt64 = 0) -> MemoryProxySample {
        MemoryProxySample(
            vfsBytesByPrefix: [
                "/dsh/workspace": workspace,
                "/dsh/home/sessions": sessions,
                "/dsh/tmp": tmp,
            ],
            sessionBytes: sessions,
            webContentTerminations: terminations)
    }

    func testTierRowsMatchBudgetsSpec() {
        XCTAssertEqual(BudgetTable.table(for: .eightGB), .eightGB)
        XCTAssertEqual(BudgetTable.table(for: .sixGB).engineHeapBytes, 256 * mb)
        XCTAssertEqual(BudgetTable.table(for: .sixGB).vfsLogicalBytes, 200 * mb)
        XCTAssertEqual(BudgetTable.table(for: .sixGB).workspaceBytes, 120 * mb)
        XCTAssertEqual(BudgetTable.table(for: .fourGB).engineHeapBytes, 192 * mb)
        XCTAssertEqual(BudgetTable.table(for: .fourGB).vfsLogicalBytes, 144 * mb)
        XCTAssertEqual(BudgetTable.table(for: .fourGB).maxSubAgents, 1)
        XCTAssertEqual(BudgetTable.table(for: .threeGB).engineHeapBytes, 144 * mb)
        XCTAssertEqual(BudgetTable.table(for: .threeGB).vfsLogicalBytes, 96 * mb)
        XCTAssertEqual(BudgetTable.table(for: .threeGB).appProcessBytes, 100 * mb)
        XCTAssertEqual(DeviceTier.threeGB.rawValue, "3gb")
        XCTAssertEqual(DeviceTier.eightGB.physicalMemoryBytes, 8 * 1024 * mb)
        XCTAssertEqual(BudgetTable.eightGB.peakProcessBytes(for: .eightGB),
                       4 * 1024 * mb)
    }

    /// budgets.md §4, 12 GiB row: the office/big-file tier above the 8 GiB
    /// default. It is the only row that may publish 256 MiB files.
    func testTwelveGiBTierRowAndSelection() {
        let table = BudgetTable.table(for: .twelveGB)
        XCTAssertEqual(table.engineHeapBytes, 832 * mb)
        XCTAssertEqual(table.vfsLogicalBytes, 768 * mb)
        XCTAssertEqual(table.workspaceBytes, 576 * mb)
        XCTAssertEqual(table.sessionBytes, 96 * mb)
        XCTAssertEqual(table.tmpBytes, 96 * mb)
        XCTAssertEqual(table.singleFileBytes, 256 * mb)
        XCTAssertEqual(table.wasiHotInstanceBytes, 640 * mb)
        XCTAssertEqual(table.appProcessBytes, 400 * mb)
        XCTAssertEqual(table.maximumSingleFileBytes, 256 * mb)
        XCTAssertTrue(table.isCoherent)
        XCTAssertEqual(DeviceTier.twelveGB.physicalMemoryBytes, 12 * 1024 * mb)
        XCTAssertEqual(BudgetTable.absoluteMaximumSingleFileBytes, 256 * mb)

        // The 12 GiB row applies only at or above 12 GiB; everything below
        // keeps the previous row (the 8 GiB default down to 4 GiB).
        XCTAssertEqual(DeviceTier.forPhysicalMemory(16 * 1024 * UInt64(mb)), .twelveGB)
        XCTAssertEqual(DeviceTier.forPhysicalMemory(12 * 1024 * UInt64(mb)), .twelveGB)
        XCTAssertEqual(DeviceTier.forPhysicalMemory(12 * 1024 * UInt64(mb) - 1), .eightGB)
        XCTAssertEqual(DeviceTier.forPhysicalMemory(8 * 1024 * UInt64(mb)), .eightGB)
        XCTAssertEqual(DeviceTier.forPhysicalMemory(6 * 1024 * UInt64(mb)), .sixGB)
        XCTAssertEqual(DeviceTier.forPhysicalMemory(4 * 1024 * UInt64(mb)), .fourGB)
        XCTAssertEqual(DeviceTier.forPhysicalMemory(3 * 1024 * UInt64(mb)), .threeGB)
        XCTAssertEqual(DeviceTier.forPhysicalMemory(1), .threeGB)
    }

    func testWithinBudgetReturnsNoAction() async throws {
        let monitor = BudgetMonitor(table: .eightGB)
        let decision = await monitor.evaluate(sample(workspace: 10 * mb,
                                                     sessions: 5 * mb,
                                                     tmp: 1 * mb))
        XCTAssertTrue(decision.isClear)
        XCTAssertNil(decision.action)
        let taken = await monitor.actionsTaken
        XCTAssertTrue(taken.isEmpty)
    }

    func testPressureActionsFollowTheFixedOrderAndFailLoud() async throws {
        let monitor = BudgetMonitor(table: .eightGB)
        let over = sample(workspace: 160 * mb, sessions: 60 * mb, tmp: 10 * mb)

        let first = await monitor.evaluate(over)
        XCTAssertEqual(first.action, .clearTmp)
        XCTAssertEqual(first.actionsTaken, [.clearTmp])

        let second = await monitor.evaluate(over)
        XCTAssertEqual(second.action, .plannedRestart)
        XCTAssertEqual(second.actionsTaken, [.clearTmp, .plannedRestart])

        let third = await monitor.evaluate(over)
        XCTAssertEqual(third.action, .handoff)
        XCTAssertEqual(third.actionsTaken, [.clearTmp, .plannedRestart, .handoff])

        let fourth = await monitor.evaluate(over)
        XCTAssertNil(fourth.action)
        XCTAssertTrue(fourth.hardFail)
        XCTAssertFalse(fourth.isClear)
    }

    func testHeadroomRestoredAfterClearTmpStopsTheEscalation() async throws {
        let monitor = BudgetMonitor(table: .eightGB)
        let over = sample(workspace: 20 * mb, sessions: 5 * mb, tmp: 60 * mb)
        let first = await monitor.evaluate(over)
        XCTAssertEqual(first.action, .clearTmp)

        let recovered = sample(workspace: 20 * mb, sessions: 5 * mb, tmp: 0)
        let second = await monitor.evaluate(recovered)
        XCTAssertTrue(second.isClear)
        XCTAssertTrue(second.actionsTaken.isEmpty, "a recovered sample clears the episode")

        // A new episode starts again at clearTmp.
        let third = await monitor.evaluate(over)
        XCTAssertEqual(third.action, .clearTmp)
    }

    func testPrefixOverflowAloneTriggersPressure() async throws {
        let monitor = BudgetMonitor(table: .eightGB)
        let decision = await monitor.evaluate(sample(tmp: 51 * mb))
        XCTAssertEqual(decision.action, .clearTmp)
        XCTAssertFalse(decision.hardFail)
    }

    func testSessionOverflowAloneTriggersPressure() async throws {
        let monitor = BudgetMonitor(table: .eightGB)
        let decision = await monitor.evaluate(sample(sessions: 51 * mb))
        XCTAssertEqual(decision.action, .clearTmp)
    }

    func testRepeatedWebContentTerminationsRequestAPlannedRestart() async throws {
        let monitor = BudgetMonitor(table: .eightGB, terminationThreshold: 3)
        let decision = await monitor.evaluate(sample(workspace: 1 * mb,
                                                     terminations: 3))
        XCTAssertEqual(decision.action, .plannedRestart)
        XCTAssertEqual(decision.actionsTaken, [.plannedRestart])
        let escalated = await monitor.evaluate(sample(workspace: 1 * mb,
                                                      terminations: 4))
        XCTAssertEqual(escalated.action, .handoff)
    }

    func testMetricsAdapterUsesPerPrefixBytes() async {
        let metrics = WorkspaceLogMetrics(workspaceBytes: 2 * mb,
                                          homeSessionsBytes: 3 * mb,
                                          tmpBytes: 4 * mb,
                                          otherBytes: 5 * mb)
        let sample = MemoryProxySample(metrics: metrics,
                                       webContentTerminations: 2)
        XCTAssertEqual(sample.vfsBytesByPrefix["/dsh/workspace"], 2 * mb)
        XCTAssertEqual(sample.vfsBytesByPrefix["/dsh/home/sessions"], 3 * mb)
        XCTAssertEqual(sample.vfsBytesByPrefix["/dsh/tmp"], 4 * mb)
        XCTAssertEqual(sample.vfsBytesByPrefix["/dsh/home"], 5 * mb)
        XCTAssertEqual(sample.sessionBytes, 3 * mb)
        XCTAssertEqual(sample.webContentTerminations, 2)
    }

    func testMetricsAdapterDrivesTheMonitor() async throws {
        let monitor = BudgetMonitor(table: .eightGB)
        let metrics = WorkspaceLogMetrics(workspaceBytes: 200 * mb)
        let decision = await monitor.evaluate(metrics: metrics,
                                              webContentTerminations: 0)
        XCTAssertEqual(decision.action, .clearTmp)
        XCTAssertEqual(decision.vfsBytes, 200 * mb)
        XCTAssertEqual(decision.vfsLimitBytes, 260 * mb)
    }

    func testWorkspaceLogMetricsOverload() async throws {
        let root = ControllerTestSupport.root(for: self)
        let log = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root),
            bootID: Data(repeating: 0x22, count: 16))
        let monitor = BudgetMonitor(table: .eightGB)
        let decision = try await monitor.evaluate(workspaceLog: log,
                                                  webContentTerminations: 0)
        XCTAssertTrue(decision.isClear)
        let taken = await monitor.actionsTaken
        XCTAssertTrue(taken.isEmpty)
    }

    func testResetClearsTheEpisode() async throws {
        let monitor = BudgetMonitor(table: .eightGB)
        let over = sample(workspace: 200 * mb)
        _ = await monitor.evaluate(over)
        await monitor.reset()
        let taken = await monitor.actionsTaken
        XCTAssertTrue(taken.isEmpty)
        let again = await monitor.evaluate(over)
        XCTAssertEqual(again.action, .clearTmp)
    }
}

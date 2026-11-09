// SPDX-License-Identifier: MIT
//
// S1 round 8: the pure three-band resource classifier and its hysteresis.
// Every row of the published threshold table has its boundary pinned here, and
// a metric that is not exposed (`nil`) must never decide a band.

import XCTest
@testable import ProbeKit

final class ResourceLevelTests: XCTestCase {
    private let mib = 1024 * 1024
    private var eightGB: ResourceThresholds { .eightGB }

    // MARK: - Workspace size (8 GiB / 288 MiB budget)

    func testWorkspaceBoundaries() {
        let budget = eightGB.workspaceBudgetBytes
        XCTAssertEqual(budget, 288 * mib)

        XCTAssertEqual(classify(workspace: Int(Double(budget) * 0.35) - 1).level, .green)
        XCTAssertEqual(classify(workspace: Int(Double(budget) * 0.35) + 1).level, .yellow)
        let atSeventy = Int(Double(budget) * 0.70)
        XCTAssertEqual(classify(workspace: atSeventy).level, .yellow,
                       "70 % is still the yellow band")
        XCTAssertEqual(classify(workspace: atSeventy + 1).level, .red,
                       "only strictly above 70 % is red")
    }

    func testWorkspaceFractionsFollowTheTierBudget() {
        // 6 GiB row: 120 MiB workspace. The same percentages must apply.
        let thresholds = ResourceThresholds(workspaceBudgetBytes: 120 * mib,
                                            engineHeapBudgetBytes: 256 * mib,
                                            vfsBudgetBytes: 200 * mib)
        let fortyTwo = 42 * mib // exactly 35 %
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: fortyTwo), thresholds: thresholds).level, .yellow)
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: 42 * mib - 1), thresholds: thresholds).level, .green)
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: 84 * mib), thresholds: thresholds).level, .yellow)
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: 84 * mib + 1), thresholds: thresholds).level, .red)
        // A number that is red on the 6 GiB row stays green on the 8 GiB row.
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: 85 * mib), thresholds: .eightGB).level, .green)
    }

    // MARK: - Per-turn workspace growth

    func testTurnWriteBoundaries() {
        XCTAssertEqual(classify(turnWrite: 20 * mib - 1).level, .green)
        XCTAssertEqual(classify(turnWrite: 20 * mib).level, .yellow)
        XCTAssertEqual(classify(turnWrite: 100 * mib).level, .yellow)
        XCTAssertEqual(classify(turnWrite: 100 * mib + 1).level, .red)
        XCTAssertEqual(classify(turnWrite: 0).level, .green)
    }

    // MARK: - Engine heap / VFS

    func testEngineHeapBoundaries() {
        let budget = eightGB.engineHeapBudgetBytes
        XCTAssertEqual(budget, 448 * mib)
        XCTAssertEqual(classify(heap: Int(Double(budget) * 0.60) - 1).level, .green)
        XCTAssertEqual(classify(heap: Int(Double(budget) * 0.60) + 1).level, .yellow)
        XCTAssertEqual(classify(heap: Int(Double(budget) * 0.80)).level, .yellow,
                       "80 % is still the yellow band")
        XCTAssertEqual(classify(heap: Int(Double(budget) * 0.80) + 1).level, .red)
    }

    func testVFSBoundaries() {
        let budget = eightGB.vfsBudgetBytes
        XCTAssertEqual(budget, 388 * mib)
        XCTAssertEqual(classify(vfs: Int(Double(budget) * 0.60) - 1).level, .green)
        XCTAssertEqual(classify(vfs: Int(Double(budget) * 0.60) + 1).level, .yellow)
        XCTAssertEqual(classify(vfs: Int(Double(budget) * 0.80)).level, .yellow)
        XCTAssertEqual(classify(vfs: Int(Double(budget) * 0.80) + 1).level, .red)
    }

    // MARK: - WebContent, thermal, battery

    func testWebContentKills() {
        XCTAssertEqual(classify(kills: 0).level, .green)
        XCTAssertEqual(classify(kills: 1).level, .red)
        XCTAssertEqual(classify(kills: 7).level, .red)
    }

    func testThermalStates() {
        XCTAssertEqual(classify(thermal: .nominal).level, .green)
        XCTAssertEqual(classify(thermal: .fair).level, .yellow)
        XCTAssertEqual(classify(thermal: .serious).level, .red)
        XCTAssertEqual(classify(thermal: .critical).level, .red)
    }

    func testBatteryAndLowPowerMode() {
        XCTAssertEqual(classify(battery: 0.19, charging: false).level, .yellow)
        XCTAssertEqual(classify(battery: 0.20, charging: false).level, .green)
        XCTAssertEqual(classify(battery: 0.19, charging: true).level, .green)
        XCTAssertEqual(classify(battery: 0.05, charging: nil).level, .green,
                       "a sample without a charging flag cannot claim 'not charging'")
        XCTAssertEqual(classify(lowPower: true).level, .yellow)
        XCTAssertEqual(classify(lowPower: false).level, .green)
    }

    // MARK: - Merge, order and missing metrics

    func testHighestBandWinsAndReasonsKeepOnlyTopForTheHeadline() {
        let classification = ResourceLevelClassifier.classify(ResourceSample(
            thermal: .serious,
            lowPowerMode: true,
            workspaceBytes: Int(Double(eightGB.workspaceBudgetBytes) * 0.40)))
        XCTAssertEqual(classification.level, .red)
        XCTAssertEqual(Set(classification.reasons.map(\.reason)),
                       [.thermalSerious, .lowPowerMode, .workspacePressure])
        XCTAssertEqual(classification.topReasons,
                       [ResourceReasonHit(.thermalSerious, level: .red)])
    }

    func testReasonDisplayOrderPutsRedBeforeYellow() {
        let classification = ResourceLevelClassifier.classify(ResourceSample(
            thermal: .fair,
            batteryLevel: 0.1,
            isCharging: false,
            webContentKills: 1))
        XCTAssertEqual(classification.level, .red)
        XCTAssertEqual(classification.reasons.first?.reason, .webContentTerminated)
    }

    func testMissingMetricsNeverDecide() {
        let classification = ResourceLevelClassifier.classify(ResourceSample())
        XCTAssertEqual(classification, ResourceClassification(level: .green, reasons: []))
        // Counters that only feed the log line are not classification inputs.
        let counters = ResourceSample(workspaceFileCount: 100_000,
                                      walBytes: 400 * mib,
                                      responseLogBytes: 127 * mib)
        XCTAssertEqual(ResourceLevelClassifier.classify(counters).level, .green)
    }

    // MARK: - Hysteresis (D.3)

    func testUpgradeIsImmediate() {
        var debouncer = ResourceLevelDebouncer()
        XCTAssertEqual(debouncer.update(.red), .red)
        XCTAssertEqual(debouncer.update(.green), .red)
        XCTAssertEqual(debouncer.update(.yellow), .red)
        XCTAssertEqual(debouncer.update(.yellow), .yellow)
    }

    func testDowngradeNeedsTwoConsecutiveSamples() {
        var debouncer = ResourceLevelDebouncer(initial: .red)
        XCTAssertEqual(debouncer.update(.yellow), .red)
        XCTAssertEqual(debouncer.update(.yellow), .yellow)
        XCTAssertEqual(debouncer.update(.green), .yellow)
        XCTAssertEqual(debouncer.update(.green), .green)
    }

    func testOscillationResetsTheDowngradeStreak() {
        var debouncer = ResourceLevelDebouncer(initial: .red)
        XCTAssertEqual(debouncer.update(.yellow), .red)
        XCTAssertEqual(debouncer.update(.green), .red, "a different target restarts the streak")
        XCTAssertEqual(debouncer.update(.yellow), .red)
        XCTAssertEqual(debouncer.update(.green), .red, "the earlier yellow count must not survive")
        XCTAssertEqual(debouncer.update(.green), .green)
    }

    func testUpgradeClearsAPendingDowngrade() {
        var debouncer = ResourceLevelDebouncer(initial: .red)
        XCTAssertEqual(debouncer.update(.green), .red)
        XCTAssertEqual(debouncer.update(.red), .red)
        XCTAssertEqual(debouncer.update(.green), .red, "the streak restarted at the upgrade")
        XCTAssertEqual(debouncer.update(.green), .green)
    }

    func testResetDropsThePendingDowngrade() {
        var debouncer = ResourceLevelDebouncer(initial: .red)
        debouncer.update(.green)
        debouncer.reset(to: .green)
        XCTAssertEqual(debouncer.level, .green)
    }

    func testStreamingRatePolicy() {
        XCTAssertEqual(ResourceLevel.green.streamUpdatesPerSecond, 20)
        XCTAssertEqual(ResourceLevel.yellow.streamUpdatesPerSecond, 10)
        XCTAssertEqual(ResourceLevel.red.streamUpdatesPerSecond, 10)
        XCTAssertEqual(ResourceLevel.green.streamUpdateIntervalNanoseconds, 50_000_000)
        XCTAssertEqual(ResourceLevel.yellow.streamUpdateIntervalNanoseconds, 100_000_000)
    }

    // MARK: - Helpers

    private func classify(workspace: Int? = nil,
                          turnWrite: Int? = nil,
                          heap: Int? = nil,
                          vfs: Int? = nil,
                          kills: Int? = nil,
                          thermal: ResourceThermalState? = nil,
                          battery: Double? = nil,
                          charging: Bool? = nil,
                          lowPower: Bool? = nil) -> ResourceClassification {
        ResourceLevelClassifier.classify(ResourceSample(
            thermal: thermal,
            batteryLevel: battery,
            isCharging: charging,
            lowPowerMode: lowPower,
            workspaceBytes: workspace,
            turnWorkspaceBytes: turnWrite,
            engineHeapBytes: heap,
            vfsBytes: vfs,
            webContentKills: kills))
    }
}

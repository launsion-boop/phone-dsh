// SPDX-License-Identifier: MIT
//
// S1 round 8: the pure three-band resource classifier and its hysteresis.
// Every row of the published threshold table has its boundary pinned here:
// green owns the threshold itself, yellow starts strictly above it, red starts
// strictly above its own threshold. A metric that is not exposed (`nil`) must
// never decide a band.

import XCTest
@testable import ProbeKit

final class ResourceLevelTests: XCTestCase {
    private let mib = 1024 * 1024
    private var eightGB: ResourceThresholds { .eightGB }

    // MARK: - Published table

    func testPublishedThresholds() {
        XCTAssertEqual(eightGB.workspaceBudgetBytes, 288 * mib)
        XCTAssertEqual(eightGB.engineHeapBudgetBytes, 448 * mib)
        XCTAssertEqual(eightGB.vfsBudgetBytes, 388 * mib)
        XCTAssertEqual(eightGB.workspaceYellowFraction, 0.60)
        XCTAssertEqual(eightGB.workspaceRedFraction, 0.85)
        XCTAssertEqual(eightGB.turnWriteYellowBytes, 100 * mib)
        XCTAssertEqual(eightGB.turnWriteRedBytes, 250 * mib)
        XCTAssertEqual(eightGB.heapYellowFraction, 0.75)
        XCTAssertEqual(eightGB.heapRedFraction, 0.90)
        XCTAssertEqual(eightGB.vfsYellowFraction, 0.75)
        XCTAssertEqual(eightGB.vfsRedFraction, 0.90)
        XCTAssertEqual(eightGB.batteryYellowFraction, 0.10)
    }

    // MARK: - Workspace size (8 GiB / 288 MiB budget)

    func testWorkspaceBoundaries() {
        let budget = eightGB.workspaceBudgetBytes
        XCTAssertEqual(budget, 288 * mib)

        // Exact thresholds on a 10_000-byte budget, where 60 % and 85 % are
        // whole bytes; the tier row is pinned just below/above the same rates.
        let exact = ResourceThresholds(workspaceBudgetBytes: 10_000,
                                       engineHeapBudgetBytes: 10_000,
                                       vfsBudgetBytes: 10_000)
        XCTAssertEqual(classify(workspace: 6_000, thresholds: exact).level, .green,
                       "exactly 60 % is still green")
        XCTAssertEqual(classify(workspace: 6_001, thresholds: exact).level, .yellow,
                       "yellow starts strictly above 60 %")
        XCTAssertEqual(classify(workspace: 8_500, thresholds: exact).level, .yellow,
                       "exactly 85 % is still yellow")
        XCTAssertEqual(classify(workspace: 8_501, thresholds: exact).level, .red,
                       "only strictly above 85 % is red")

        let atSixty = Int(Double(budget) * 0.60)
        XCTAssertEqual(classify(workspace: atSixty).level, .green)
        XCTAssertEqual(classify(workspace: atSixty + 1).level, .yellow)
        let atEightyFive = Int(Double(budget) * 0.85)
        XCTAssertEqual(classify(workspace: atEightyFive).level, .yellow)
        XCTAssertEqual(classify(workspace: atEightyFive + 1).level, .red)
    }

    func testWorkspaceFractionsFollowTheTierBudget() {
        // 6 GiB row: 120 MiB workspace. The same percentages must apply.
        let thresholds = ResourceThresholds(workspaceBudgetBytes: 120 * mib,
                                            engineHeapBudgetBytes: 256 * mib,
                                            vfsBudgetBytes: 200 * mib)
        let seventyTwo = 72 * mib // exactly 60 %
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: seventyTwo), thresholds: thresholds).level, .green)
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: seventyTwo + 1), thresholds: thresholds).level, .yellow)
        let oneHundredTwo = 102 * mib // exactly 85 %
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: oneHundredTwo), thresholds: thresholds).level, .yellow)
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: oneHundredTwo + 1), thresholds: thresholds).level, .red)
        // A number that is red on the 6 GiB row stays green on the 8 GiB row.
        XCTAssertEqual(ResourceLevelClassifier.classify(
            ResourceSample(workspaceBytes: oneHundredTwo + 1), thresholds: .eightGB).level, .green)
    }

    // MARK: - Per-turn workspace growth

    func testTurnWriteBoundaries() {
        XCTAssertEqual(classify(turnWrite: 0).level, .green)
        XCTAssertEqual(classify(turnWrite: 100 * mib).level, .green,
                       "exactly 100 MB is still green")
        XCTAssertEqual(classify(turnWrite: 100 * mib + 1).level, .yellow,
                       "yellow starts strictly above 100 MB")
        XCTAssertEqual(classify(turnWrite: 250 * mib).level, .yellow,
                       "exactly 250 MB is still yellow")
        XCTAssertEqual(classify(turnWrite: 250 * mib + 1).level, .red,
                       "only strictly above 250 MB is red")
    }

    // MARK: - Engine heap / VFS

    func testEngineHeapBoundaries() {
        let budget = eightGB.engineHeapBudgetBytes
        XCTAssertEqual(budget, 448 * mib)

        let exact = ResourceThresholds(workspaceBudgetBytes: 10_000,
                                       engineHeapBudgetBytes: 10_000,
                                       vfsBudgetBytes: 10_000)
        XCTAssertEqual(classify(heap: 7_500, thresholds: exact).level, .green,
                       "exactly 75 % is still green")
        XCTAssertEqual(classify(heap: 7_501, thresholds: exact).level, .yellow)
        XCTAssertEqual(classify(heap: 9_000, thresholds: exact).level, .yellow,
                       "exactly 90 % is still yellow")
        XCTAssertEqual(classify(heap: 9_001, thresholds: exact).level, .red)

        let atSeventyFive = Int(Double(budget) * 0.75)
        XCTAssertEqual(classify(heap: atSeventyFive).level, .green)
        XCTAssertEqual(classify(heap: atSeventyFive + 1).level, .yellow)
        let atNinety = Int(Double(budget) * 0.90)
        XCTAssertEqual(classify(heap: atNinety).level, .yellow)
        XCTAssertEqual(classify(heap: atNinety + 1).level, .red)
    }

    func testVFSBoundaries() {
        let budget = eightGB.vfsBudgetBytes
        XCTAssertEqual(budget, 388 * mib)

        let exact = ResourceThresholds(workspaceBudgetBytes: 10_000,
                                       engineHeapBudgetBytes: 10_000,
                                       vfsBudgetBytes: 10_000)
        XCTAssertEqual(classify(vfs: 7_500, thresholds: exact).level, .green,
                       "exactly 75 % is still green")
        XCTAssertEqual(classify(vfs: 7_501, thresholds: exact).level, .yellow)
        XCTAssertEqual(classify(vfs: 9_000, thresholds: exact).level, .yellow,
                       "exactly 90 % is still yellow")
        XCTAssertEqual(classify(vfs: 9_001, thresholds: exact).level, .red)

        let atSeventyFive = Int(Double(budget) * 0.75)
        XCTAssertEqual(classify(vfs: atSeventyFive).level, .green)
        XCTAssertEqual(classify(vfs: atSeventyFive + 1).level, .yellow)
        let atNinety = Int(Double(budget) * 0.90)
        XCTAssertEqual(classify(vfs: atNinety).level, .yellow)
        XCTAssertEqual(classify(vfs: atNinety + 1).level, .red)
    }

    // MARK: - WebContent, thermal, battery

    func testWebContentKills() {
        XCTAssertEqual(classify(kills: 0).level, .green)
        XCTAssertEqual(classify(kills: 1).level, .yellow,
                       "one kill is the yellow row")
        XCTAssertEqual(classify(kills: 2).level, .red,
                       "two or more kills are the red row")
        XCTAssertEqual(classify(kills: 7).level, .red)
    }

    func testThermalStates() {
        XCTAssertEqual(classify(thermal: .nominal).level, .green)
        XCTAssertEqual(classify(thermal: .fair).level, .green,
                       "fair is log-only and does not move the App band")
        XCTAssertEqual(classify(thermal: .serious).level, .yellow)
        XCTAssertEqual(classify(thermal: .critical).level, .red)
        XCTAssertEqual(classify(thermal: .fair).reasons, [],
                       "fair must not add a banner reason")
    }

    func testBatteryAndLowPowerMode() {
        XCTAssertEqual(classify(battery: 0.0999, charging: false).level, .yellow)
        XCTAssertEqual(classify(battery: 0.10, charging: false).level, .green,
                       "exactly 10 % is still green")
        XCTAssertEqual(classify(battery: 0.05, charging: true).level, .green)
        XCTAssertEqual(classify(battery: 0.05, charging: nil).level, .green,
                       "a sample without a charging flag cannot claim 'not charging'")
        XCTAssertEqual(classify(lowPower: true).level, .yellow)
        XCTAssertEqual(classify(lowPower: false).level, .green)
        XCTAssertEqual(classify(battery: 0.99, lowPower: true).level, .yellow,
                       "low power mode is yellow at any battery level")
    }

    // MARK: - Merge, order and missing metrics

    func testHighestBandWinsAndReasonsKeepOnlyTopForTheHeadline() {
        let classification = ResourceLevelClassifier.classify(ResourceSample(
            thermal: .serious,
            lowPowerMode: true,
            workspaceBytes: Int(Double(eightGB.workspaceBudgetBytes) * 0.70),
            webContentKills: 2))
        XCTAssertEqual(classification.level, .red)
        XCTAssertEqual(Set(classification.reasons.map(\.reason)),
                       [.webContentTerminated, .thermalSerious, .lowPowerMode, .workspacePressure])
        XCTAssertEqual(classification.topReasons,
                       [ResourceReasonHit(.webContentTerminated, level: .red)])
    }

    func testSameBandReasonsUseTheDocumentedDisplayOrder() {
        let classification = ResourceLevelClassifier.classify(ResourceSample(
            thermal: .serious,
            lowPowerMode: true,
            workspaceBytes: Int(Double(eightGB.workspaceBudgetBytes) * 0.70)))
        XCTAssertEqual(classification.level, .yellow)
        XCTAssertEqual(classification.topReasons.map(\.reason),
                       [.workspacePressure, .thermalSerious, .lowPowerMode])
    }

    func testReasonDisplayOrderPutsRedBeforeYellow() {
        let classification = ResourceLevelClassifier.classify(ResourceSample(
            thermal: .serious,
            batteryLevel: 0.05,
            isCharging: false,
            webContentKills: 2))
        XCTAssertEqual(classification.level, .red)
        XCTAssertEqual(classification.reasons.map(\.reason),
                       [.webContentTerminated, .thermalSerious, .lowBattery])
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
                          lowPower: Bool? = nil,
                          thresholds: ResourceThresholds = .eightGB) -> ResourceClassification {
        ResourceLevelClassifier.classify(
            ResourceSample(
                thermal: thermal,
                batteryLevel: battery,
                isCharging: charging,
                lowPowerMode: lowPower,
                workspaceBytes: workspace,
                turnWorkspaceBytes: turnWrite,
                engineHeapBytes: heap,
                vfsBytes: vfs,
                webContentKills: kills),
            thresholds: thresholds)
    }
}

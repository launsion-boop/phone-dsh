// SPDX-License-Identifier: MIT
// W6-BACKGROUND policy-table tests: the thermal/battery constants of
// budgets.md §3/§4. Budgets may only be lowered, never raised.

import XCTest
import PhoneDSHController
@testable import PhoneDSH

final class BackgroundPolicyTests: XCTestCase {
    private let nominalBattery = BatterySnapshot(level: 0.8,
                                                 isLowPowerModeEnabled: false,
                                                 isCharging: false)
    private let chargingBattery = BatterySnapshot(level: 0.8,
                                                  isLowPowerModeEnabled: false,
                                                  isCharging: true)

    func testNominalUsesTheBudgetTableCap() {
        let decision = BackgroundPolicies.evaluate(thermal: .nominal,
                                                   battery: nominalBattery,
                                                   budgets: .eightGB)
        XCTAssertEqual(decision.action, .run)
        XCTAssertEqual(decision.subAgentCap, 2)
        XCTAssertFalse(decision.pausesNewWork)
        XCTAssertTrue(decision.allowsOptionalAccelerators)
        XCTAssertFalse(decision.suggestsHandoff)
        XCTAssertTrue(decision.reasons.isEmpty)
        XCTAssertTrue(decision.isNominal)
    }

    func testThermalFairCapsSubAgentsAtOne() {
        let decision = BackgroundPolicies.evaluate(thermal: .fair,
                                                   battery: nominalBattery,
                                                   budgets: .eightGB)
        XCTAssertEqual(decision.action, .limitSubAgents)
        XCTAssertEqual(decision.subAgentCap, 1)
        XCTAssertFalse(decision.pausesNewWork)
        XCTAssertTrue(decision.allowsOptionalAccelerators)
        XCTAssertFalse(decision.suggestsHandoff)
        XCTAssertEqual(decision.reasons, ["thermal fair"])
    }

    func testThermalSeriousPausesWorkAndSuggestsHandoff() {
        let decision = BackgroundPolicies.evaluate(thermal: .serious,
                                                   battery: nominalBattery,
                                                   budgets: .eightGB)
        XCTAssertEqual(decision.action, .suggestHandoff)
        XCTAssertEqual(decision.subAgentCap, 1)
        XCTAssertTrue(decision.pausesNewWork)
        XCTAssertFalse(decision.allowsOptionalAccelerators)
        XCTAssertTrue(decision.suggestsHandoff)
        XCTAssertEqual(decision.reasons, ["thermal serious"])
    }

    func testThermalCriticalMatchesSerious() {
        let serious = BackgroundPolicies.evaluate(thermal: .serious,
                                                  battery: nominalBattery,
                                                  budgets: .eightGB)
        let critical = BackgroundPolicies.evaluate(thermal: .critical,
                                                   battery: nominalBattery,
                                                   budgets: .eightGB)
        XCTAssertEqual(critical.action, .suggestHandoff)
        XCTAssertEqual(critical.subAgentCap, serious.subAgentCap)
        XCTAssertTrue(critical.pausesNewWork)
        XCTAssertTrue(critical.suggestsHandoff)
        XCTAssertEqual(critical.reasons, ["thermal critical"])
    }

    func testLowBatteryNotChargingCapsAtOne() {
        let battery = BatterySnapshot(level: 0.19, isLowPowerModeEnabled: false,
                                      isCharging: false)
        let decision = BackgroundPolicies.evaluate(thermal: .nominal,
                                                   battery: battery,
                                                   budgets: .eightGB)
        XCTAssertEqual(decision.action, .limitSubAgents)
        XCTAssertEqual(decision.subAgentCap, 1)
        XCTAssertFalse(decision.allowsOptionalAccelerators)
        XCTAssertFalse(decision.pausesNewWork)
        XCTAssertEqual(decision.reasons,
                       ["battery below 20 percent and not charging"])
    }

    func testLowBatteryWhileChargingDoesNotCap() {
        let battery = BatterySnapshot(level: 0.05, isLowPowerModeEnabled: false,
                                      isCharging: true)
        let decision = BackgroundPolicies.evaluate(thermal: .nominal,
                                                   battery: battery,
                                                   budgets: .eightGB)
        XCTAssertEqual(decision.action, .run)
        XCTAssertEqual(decision.subAgentCap, 2)
        XCTAssertTrue(decision.allowsOptionalAccelerators)
    }

    func testBatteryAtTwentyPercentIsNotBelowTheThreshold() {
        let battery = BatterySnapshot(level: 0.2, isLowPowerModeEnabled: false,
                                      isCharging: false)
        let decision = BackgroundPolicies.evaluate(thermal: .nominal,
                                                   battery: battery,
                                                   budgets: .eightGB)
        XCTAssertEqual(decision.action, .run)
        XCTAssertEqual(decision.subAgentCap, 2)
    }

    func testLowPowerModeCapsAtOne() {
        let battery = BatterySnapshot(level: 0.9, isLowPowerModeEnabled: true,
                                      isCharging: false)
        let decision = BackgroundPolicies.evaluate(thermal: .nominal,
                                                   battery: battery,
                                                   budgets: .eightGB)
        XCTAssertEqual(decision.action, .limitSubAgents)
        XCTAssertEqual(decision.subAgentCap, 1)
        XCTAssertFalse(decision.allowsOptionalAccelerators)
        XCTAssertEqual(decision.reasons, ["low power mode"])
    }

    func testSeriousThermalOutranksBatteryInTheReasonsButBothApply() {
        let battery = BatterySnapshot(level: 0.1, isLowPowerModeEnabled: true,
                                      isCharging: false)
        let decision = BackgroundPolicies.evaluate(thermal: .serious,
                                                   battery: battery,
                                                   budgets: .eightGB)
        XCTAssertEqual(decision.action, .suggestHandoff)
        XCTAssertEqual(decision.subAgentCap, 1)
        XCTAssertTrue(decision.pausesNewWork)
        XCTAssertFalse(decision.allowsOptionalAccelerators)
        XCTAssertTrue(decision.suggestsHandoff)
        XCTAssertEqual(decision.reasons.count, 3)
        XCTAssertEqual(decision.reasons.first, "thermal serious")
    }

    func testLowerTierCapsAreNeverRaised() {
        // The 4 GiB row has maxSubAgents == 1; nominal thermal must not raise
        // it back to two.
        let decision = BackgroundPolicies.evaluate(thermal: .nominal,
                                                   battery: nominalBattery,
                                                   budgets: .fourGB)
        XCTAssertEqual(decision.subAgentCap, 1)
        XCTAssertEqual(decision.action, .run)
    }

    func testCustomTableIsNeverExceeded() {
        let table = BudgetTable(
            engineHeapBytes: 1, vfsLogicalBytes: 1, workspaceBytes: 1,
            sessionBytes: 1, tmpBytes: 1, singleFileBytes: 1,
            wasiHotInstanceBytes: 1, appProcessBytes: 1, peakFraction: 0.5,
            maxSubAgents: 3, thermalFairSubAgents: 2,
            loopbackRoundTripP95Milliseconds: 5,
            plannedRestartIntervalSeconds: 7200,
            recoveryBaseSeconds: 3,
            recoverySecondsPerMegabyte: 0.05)
        let fair = BackgroundPolicies.evaluate(thermal: .fair,
                                               battery: nominalBattery,
                                               budgets: table)
        XCTAssertEqual(fair.subAgentCap, 2)
        XCTAssertLessThanOrEqual(fair.subAgentCap, table.maxSubAgents)
        let nominal = BackgroundPolicies.evaluate(thermal: .nominal,
                                                  battery: chargingBattery,
                                                  budgets: table)
        XCTAssertEqual(nominal.subAgentCap, 3)
    }
}

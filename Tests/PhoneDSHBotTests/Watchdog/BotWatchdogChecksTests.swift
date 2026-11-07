// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotWatchdogChecksTests: XCTestCase {
    func testFrozenGoldenProducesAllFiveFindingsInOrder() throws {
        let fixture = try botGolden("watchdog")
        let valid = fixture["valid"] as! [String: Any]
        let config = try botDecode(BotWatchdogConfig.self, valid["config"]!)
        let expected = try botDecode([BotWatchdogFinding].self, valid["flagged"]!)
        let unit = BotWatchdogUnit(
            startedAt: 1, lastEventAt: 1, deadlineAt: 1,
            repeatedToolSignatureCount: 5, lastToolSignature: "tool:digest",
            repeatedToolErrorCount: 3, lastToolErrorSignature: "tool:error",
            tokens: 200_001, costUsd: 0)
        XCTAssertEqual(BotWatchdogChecks.run(unit: unit, now: 1_760_000_000_000, config: config), expected)
    }

    func testStrictThresholdsAndPendingApprovalSuppressHeartbeat() {
        var config = BotWatchdogConfig(
            heartbeatTimeoutMs: 100, turnDeadlineMs: 100,
            repeatedToolCalls: 2, repeatedToolErrors: 2,
            maxUnitTokens: 10, maxUnitCostUsd: 1)
        let exact = BotWatchdogUnit(
            startedAt: 1, lastEventAt: 1, deadlineAt: 101,
            repeatedToolSignatureCount: 1, repeatedToolErrorCount: 1,
            tokens: 10, costUsd: 1)
        XCTAssertEqual(BotWatchdogChecks.run(unit: exact, now: 101, config: config), [])

        var over = exact
        over.repeatedToolSignatureCount = 2
        over.repeatedToolErrorCount = 2
        over.tokens = 11
        over.costUsd = 2
        let findings = BotWatchdogChecks.run(unit: over, now: 102, config: config)
        XCTAssertEqual(findings.map(\.check), [.deadline, .heartbeat, .repeatedToolSignature, .repeatedToolError, .quota])
        XCTAssertEqual(BotContextLintSupport.object(findings.last?.evidence)["reason"], .string("tokens_and_cost"))

        over.pendingApproval = 1
        XCTAssertFalse(BotWatchdogChecks.run(unit: over, now: 102, config: config).map(\.check).contains(.heartbeat))
        config.heartbeatTimeoutMs = 0
        config.maxUnitTokens = 0
        config.maxUnitCostUsd = 0
        over.pendingApproval = 0
        XCTAssertFalse(BotWatchdogChecks.run(unit: over, now: 102, config: config).map(\.check).contains(.heartbeat))
        XCTAssertFalse(BotWatchdogChecks.run(unit: over, now: 102, config: config).map(\.check).contains(.quota))
    }

    func testFrozenMobileDescriptorsAreObserveOnlyAndStopIsNotACheck() throws {
        let fixture = try botGolden("watchdog")
        let valid = fixture["valid"] as! [String: Any]
        let mobile = try botDecode([BotWatchdogMobileDescriptor].self, valid["mobile"]!)
        XCTAssertEqual(mobile, BotWatchdogMobileDescriptor.frozen)
        XCTAssertEqual(mobile.map(\.check), [.webcontentTerminated, .thermalPressure, .batteryPressure])
        XCTAssertTrue(mobile.allSatisfy { $0.observeOnly && $0.oncePerUnit && $0.eventType == "watchdog.flagged" })
        XCTAssertNil(BotWatchdogCheck(rawValue: "stop"))
        XCTAssertNil(BotWatchdogCheck(rawValue: "nudge"))
    }
}

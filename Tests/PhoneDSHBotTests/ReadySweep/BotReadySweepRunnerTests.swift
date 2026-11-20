// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// The Bot-owned slice of ReadySweep: fixed order, live lease gate before every
/// step, no half-run, one failure does not suppress the later steps.
final class BotReadySweepRunnerTests: XCTestCase {
    func testStepsRunInTheContractOrder() async {
        let log = ReadySweepStepLog()
        let runner = BotReadySweepRunner(
            budget: .init(remainingMs: { 60_000 }, shouldRun: { _, _ in true }),
            action: { step in log.append(step) })
        let report = await runner.run()
        XCTAssertEqual(log.all, BotReadySweepStep.allCases)
        XCTAssertEqual(report.ranSteps, BotReadySweepStep.allCases)
        XCTAssertEqual(report.steps.map(\.step), BotReadySweepStep.allCases)
    }

    func testAnUnavailableLeaseSkipsTheWholeStepAndStillRunsLaterSteps() async {
        let log = ReadySweepStepLog()
        let skipped = BotReadySweepStep.missedRoutines
        let runner = BotReadySweepRunner(
            budget: .init(remainingMs: { 6_000 }, shouldRun: { step, _ in step != skipped }),
            action: { step in log.append(step) })
        let report = await runner.run()
        XCTAssertFalse(log.all.contains(skipped), "a skipped step must not run at all")
        XCTAssertEqual(report.outcome(for: skipped), .skipped(reason: "lease"))
        XCTAssertEqual(report.ranSteps, [.botHeldInbox, .connectorScan, .approvalReminderSync])
    }

    func testRemainingLeaseIsReReadBeforeEachStep() async {
        let clock = WP6Clock(10_000)
        let seen = ReadySweepStepLog()
        let runner = BotReadySweepRunner(
            budget: .init(remainingMs: { clock.now }, shouldRun: { _, remaining in
                seen.appendRemaining(remaining)
                return true
            }),
            action: { _ in
                // The lease shrinks while the steps run; the next gate must see
                // the new value instead of one computed at the start.
                clock.advance(-1_000)
            })
        _ = await runner.run()
        XCTAssertEqual(seen.remaining, [10_000, 9_000, 8_000, 7_000])
    }

    func testAFailingStepDoesNotSuppressLaterSteps() async {
        struct ConnectorFailure: Error {}
        let log = ReadySweepStepLog()
        let runner = BotReadySweepRunner(
            budget: .init(remainingMs: { 60_000 }, shouldRun: { _, _ in true }),
            action: { step in
                if step == .connectorScan { throw ConnectorFailure() }
                log.append(step)
            })
        let report = await runner.run()
        XCTAssertEqual(report.failedSteps, [.connectorScan])
        XCTAssertEqual(report.outcome(for: .connectorScan), .failed(reason: "ConnectorFailure"))
        XCTAssertEqual(log.all, [.botHeldInbox, .missedRoutines, .approvalReminderSync])
        XCTAssertEqual(report.ranSteps, [.botHeldInbox, .missedRoutines, .approvalReminderSync])
    }

    func testCancellationIsSkippedNotFailed() async {
        let log = ReadySweepStepLog()
        let runner = BotReadySweepRunner(
            budget: .init(remainingMs: { 60_000 }, shouldRun: { _, _ in true }),
            action: { step in
                if step == .botHeldInbox { throw CancellationError() }
                log.append(step)
            })
        let report = await runner.run()
        XCTAssertEqual(report.outcome(for: .botHeldInbox), .skipped(reason: "cancelled"))
        XCTAssertTrue(report.failedSteps.isEmpty)
        XCTAssertEqual(log.all, [.missedRoutines, .connectorScan, .approvalReminderSync])
    }

    func testEachStepRunsAtMostOncePerCall() async {
        let log = ReadySweepStepLog()
        let runner = BotReadySweepRunner(
            budget: .init(remainingMs: { 60_000 }, shouldRun: { _, _ in true }),
            action: { step in log.append(step) })
        _ = await runner.run()
        _ = await runner.run()
        XCTAssertEqual(log.all, BotReadySweepStep.allCases + BotReadySweepStep.allCases)
    }
}

private final class ReadySweepStepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [BotReadySweepStep] = []
    private var remainingValues: [Int64] = []

    var all: [BotReadySweepStep] { lock.withLock { steps } }
    var remaining: [Int64] { lock.withLock { remainingValues } }

    func append(_ step: BotReadySweepStep) { lock.withLock { steps.append(step) } }
    func appendRemaining(_ value: Int64) { lock.withLock { remainingValues.append(value) } }
}

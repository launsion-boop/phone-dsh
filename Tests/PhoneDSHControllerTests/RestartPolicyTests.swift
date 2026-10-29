// SPDX-License-Identifier: MIT
// Planned-restart triggers: pressure, a WebContent death, or a 24 h uptime —
// always at a tool-call boundary.

import XCTest
@testable import PhoneDSHController

final class RestartPolicyTests: XCTestCase {
    private let policy = RestartPolicy.standard
    private let budget = 448 * 1024 * 1024

    func testHealthyEngineBelowTheCeilingNeverRestarts() {
        let evaluation = policy.evaluate(engineHeapBytes: budget / 2,
                                         heapBudgetBytes: budget,
                                         uptime: 60 * 60,
                                         highSamples: 0,
                                         webContentTerminated: false,
                                         atToolBoundary: true)
        XCTAssertNil(evaluation.trigger)
        XCTAssertEqual(evaluation.nextHighSamples, 0)
    }

    func testHeapPressureNeedsThreeConsecutiveSamples() {
        var samples = 0
        for _ in 0..<2 {
            let evaluation = policy.evaluate(engineHeapBytes: budget * 8 / 10,
                                             heapBudgetBytes: budget,
                                             uptime: 60,
                                             highSamples: samples,
                                             webContentTerminated: false,
                                             atToolBoundary: true)
            XCTAssertNil(evaluation.trigger)
            samples = evaluation.nextHighSamples
        }
        XCTAssertEqual(samples, 2)
        let third = policy.evaluate(engineHeapBytes: budget * 8 / 10,
                                    heapBudgetBytes: budget,
                                    uptime: 120,
                                    highSamples: samples,
                                    webContentTerminated: false,
                                    atToolBoundary: true)
        XCTAssertEqual(third.trigger, .heapPressure)
        XCTAssertEqual(third.nextHighSamples, 0)
    }

    func testPressureIsHeldUntilTheToolCallBoundary() {
        let busy = policy.evaluate(engineHeapBytes: budget * 9 / 10,
                                   heapBudgetBytes: budget,
                                   uptime: 60,
                                   highSamples: 2,
                                   webContentTerminated: false,
                                   atToolBoundary: false)
        XCTAssertNil(busy.trigger)
        XCTAssertEqual(busy.nextHighSamples, 3, "a busy turn cannot hide pressure")
        let boundary = policy.evaluate(engineHeapBytes: budget * 9 / 10,
                                       heapBudgetBytes: budget,
                                       uptime: 60,
                                       highSamples: busy.nextHighSamples,
                                       webContentTerminated: false,
                                       atToolBoundary: true)
        XCTAssertEqual(boundary.trigger, .heapPressure)
    }

    func testOneWebContentTerminationTriggersAtTheBoundary() {
        let busy = policy.evaluate(engineHeapBytes: nil,
                                   heapBudgetBytes: budget,
                                   uptime: 60,
                                   highSamples: 0,
                                   webContentTerminated: true,
                                   atToolBoundary: false)
        XCTAssertNil(busy.trigger)
        let boundary = policy.evaluate(engineHeapBytes: nil,
                                       heapBudgetBytes: budget,
                                       uptime: 60,
                                       highSamples: 0,
                                       webContentTerminated: true,
                                       atToolBoundary: true)
        XCTAssertEqual(boundary.trigger, .webContentTermination)
    }

    func testTwentyFourHoursIsTheUptimeCeiling() {
        let below = policy.evaluate(engineHeapBytes: nil,
                                    heapBudgetBytes: budget,
                                    uptime: 24 * 60 * 60 - 1,
                                    highSamples: 0,
                                    webContentTerminated: false,
                                    atToolBoundary: true)
        XCTAssertNil(below.trigger)
        let atCeiling = policy.evaluate(engineHeapBytes: nil,
                                        heapBudgetBytes: budget,
                                        uptime: 24 * 60 * 60,
                                        highSamples: 0,
                                        webContentTerminated: false,
                                        atToolBoundary: true)
        XCTAssertEqual(atCeiling.trigger, .maximumUptime)
    }
}

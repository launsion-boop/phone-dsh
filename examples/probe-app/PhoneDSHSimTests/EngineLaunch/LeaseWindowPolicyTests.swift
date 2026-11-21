// SPDX-License-Identifier: MIT
// Host §10.2.3: the lease window ends when the work is done, not at the last
// possible moment.
import XCTest
import ProbeKit

final class LeaseWindowPolicyTests: XCTestCase {
    private let deadline: Int64 = 100_000
    private let margin: Int64 = 5_000

    func testForegroundReleasesWithoutParking() {
        XCTAssertEqual(LeaseWindowPolicy.action(isForeground: true, turnInFlight: true,
                                                nowMs: 50_000, deadlineMs: deadline,
                                                parkMarginMs: margin),
                       .releaseForeground)
    }

    func testNoTurnParksImmediately() {
        XCTAssertEqual(LeaseWindowPolicy.action(isForeground: false, turnInFlight: false,
                                                nowMs: 10_000, deadlineMs: deadline,
                                                parkMarginMs: margin), .parkNow)
    }

    func testTurnInFlightWaitsUntilItEndsOrTheLatestStop() {
        XCTAssertEqual(LeaseWindowPolicy.action(isForeground: false, turnInFlight: true,
                                                nowMs: 10_000, deadlineMs: deadline,
                                                parkMarginMs: margin), .wait)
        XCTAssertEqual(LeaseWindowPolicy.action(isForeground: false, turnInFlight: true,
                                                nowMs: 94_999, deadlineMs: deadline,
                                                parkMarginMs: margin), .wait)
        XCTAssertEqual(LeaseWindowPolicy.action(isForeground: false, turnInFlight: true,
                                                nowMs: 95_000, deadlineMs: deadline,
                                                parkMarginMs: margin), .parkNow)
    }
}

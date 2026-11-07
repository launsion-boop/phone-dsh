// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class RoutineQuietHoursTests: XCTestCase {
    func testWeekendDefersToMondayQuietEnd() {
        let settings = wp6Settings(quietStart: "23:00", quietEnd: "08:00",
                                   weekends: true, timeZone: "Asia/Taipei")
        let saturday = wp6Date(2026, 5, 16, 10, timeZone: "Asia/Taipei")
        let monday = wp6Date(2026, 5, 18, 8, timeZone: "Asia/Taipei")
        XCTAssertTrue(RoutineQuietHours.contains(saturday, settings: settings))
        XCTAssertEqual(RoutineQuietHours.nextEnd(saturday, settings: settings), monday)
    }

    func testEqualQuietBoundariesDisableWindow() {
        let settings = wp6Settings(quietStart: "08:00", quietEnd: "08:00", timeZone: "UTC")
        let noon = wp6Date(2026, 5, 12, 12)
        XCTAssertFalse(RoutineQuietHours.contains(noon, settings: settings))
        XCTAssertEqual(RoutineQuietHours.nextEnd(noon, settings: settings), noon)
    }
}

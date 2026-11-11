// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class ProactiveSettingsStoreTests: XCTestCase {
    private func suite(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "wp6.settings.\(name)")!
        defaults.removePersistentDomain(forName: "wp6.settings.\(name)")
        return defaults
    }

    func testMissingValueUsesProductionOnDNDOffAndQuietHours() {
        let store = ProactiveSettingsStore(defaults: suite())
        let settings = store.settings()
        XCTAssertEqual(settings.mode, .on)
        XCTAssertFalse(settings.dnd)
        XCTAssertEqual(settings.quietStart, "23:00")
        XCTAssertEqual(settings.quietEnd, "08:00")
        XCTAssertNoThrow(TimeZone(identifier: settings.timeZone))
    }

    func testSaveRoundTripsThroughASecondReader() {
        let defaults = suite()
        let store = ProactiveSettingsStore(defaults: defaults)
        store.save(ProactiveSettings(mode: .on, dnd: true, quietStart: "21:30",
                                     quietEnd: "07:15", routineQuietWeekends: true,
                                     timeZone: "Asia/Taipei"))
        let reopened = ProactiveSettingsStore(defaults: defaults)
        let settings = reopened.settings()
        XCTAssertTrue(settings.dnd)
        XCTAssertEqual(settings.quietStart, "21:30")
        XCTAssertEqual(settings.quietEnd, "07:15")
        XCTAssertTrue(settings.routineQuietWeekends)
        XCTAssertEqual(settings.timeZone, "Asia/Taipei")
    }

    func testInvalidTimesAndTimeZoneAreNormalizedOnRead() throws {
        let defaults = suite()
        let store = ProactiveSettingsStore(defaults: defaults)
        let invalid = ProactiveSettings(mode: .on, dnd: false, quietStart: "25:99",
                                        quietEnd: "not-a-time", timeZone: "Not/AZone")
        store.save(invalid)
        let settings = store.settings()
        XCTAssertEqual(settings.quietStart, "23:00")
        XCTAssertEqual(settings.quietEnd, "08:00")
        XCTAssertNotNil(TimeZone(identifier: settings.timeZone))
    }

    func testUpdateKeepsOtherFieldsAndNormalizes() {
        let store = ProactiveSettingsStore(defaults: suite())
        let updated = store.update(dnd: true, quietStart: "22:00", quietEnd: "06:00")
        XCTAssertTrue(updated.dnd)
        XCTAssertEqual(updated.quietStart, "22:00")
        XCTAssertEqual(updated.quietEnd, "06:00")
        XCTAssertEqual(store.settings(), updated)
    }

    func testCorruptStoredValueFallsBackWithoutCrashing() {
        let defaults = suite()
        defaults.set(Data("not-json".utf8), forKey: ProactiveSettingsStore.defaultsKey)
        let settings = ProactiveSettingsStore(defaults: defaults).settings()
        XCTAssertEqual(settings.mode, .on)
        XCTAssertFalse(settings.dnd)
    }
}

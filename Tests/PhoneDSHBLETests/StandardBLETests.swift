// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

final class StandardBLETests: XCTestCase {
    func testSignedTemperatureAndLittleEndianHumidity() throws {
        XCTAssertEqual(try StandardBLEProfile.temperature.decode(Data([0x2e, 0xfb])), "-12.34")
        XCTAssertEqual(try StandardBLEProfile.temperature.decode(Data([0xc4, 0x09])), "25.0")
        XCTAssertEqual(try StandardBLEProfile.humidity.decode(Data([0x88, 0x13])), "50.0")
        XCTAssertEqual(try StandardBLEProfile.humidity.decode(Data([0x10, 0x27])), "100.0")
    }
    func testUnknownAndMalformedValuesAreNotMeasurements() {
        for data in [Data(), Data([1]), Data([1, 2, 3]), Data([0, 0x80]), Data([0x4c, 0x95])] {
            XCTAssertThrowsError(try StandardBLEProfile.temperature.decode(data))
        }
        for data in [Data([0xff, 0xff]), Data([0x11, 0x27])] {
            XCTAssertThrowsError(try StandardBLEProfile.humidity.decode(data))
        }
        XCTAssertThrowsError(try StandardBLEProfile.battery.decode(Data([101])))
        XCTAssertThrowsError(try StandardBLEProfile.battery.decode(Data([10, 0])))
        XCTAssertThrowsError(try StandardBLEProfile.model.decode(Data([0xff])))
        XCTAssertThrowsError(try StandardBLEProfile.manufacturer.decode(Data([0])))
    }
    func testBatteryTextAndAlertBoundaries() throws {
        XCTAssertEqual(try StandardBLEProfile.battery.decode(Data([0])), "0")
        XCTAssertEqual(try StandardBLEProfile.battery.decode(Data([100])), "100")
        XCTAssertEqual(try StandardBLEProfile.model.decode(Data("ESP32".utf8)), "ESP32")
        for level in 0...2 { XCTAssertEqual(try StandardBLEProfile.alertCommand(level: level), Data([UInt8(level)])) }
        XCTAssertThrowsError(try StandardBLEProfile.alertCommand(level: -1))
        XCTAssertThrowsError(try StandardBLEProfile.alertCommand(level: 3))
        XCTAssertThrowsError(try StandardBLEProfile.alert.decode(Data([1])))
    }
    func testAlertIsOnlyBoundToImmediateAlertService() {
        XCTAssertEqual(StandardBLEProfile.alert.service, "1802")
        XCTAssertEqual(StandardBLEProfile.alert.characteristic, "2A06")
        XCTAssertEqual(StandardBLEProfile.temperature.service, "181A")
    }
}

// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

@MainActor
final class GattBotTriggerTests: XCTestCase {
    private let id = UUID()
    private func snap(read: Bool, alert: Bool, link: Bool = false,
                      profiles: [StandardBLEProfile] = [.battery, .temperature, .alert]) -> GattBotTrigger.Snapshot {
        .init(id: id, name: "tag", profiles: profiles, allowRead: read, allowAlert: alert, isLinkDevice: link)
    }

    func testBareConnectionFiresNothing() {
        // Trust defaults turn both flags on without a user action: no edge was observed by a toggle.
        let same = snap(read: true, alert: true)
        XCTAssertNil(GattBotTrigger.decide(before: same, after: same, isBoard: false))
        XCTAssertNil(GattBotTrigger.decide(before: nil, after: same, isBoard: false))
        var device = BLEDeviceStore.Device(id: id, name: "tag", rssi: 0)
        device.allowRead = true; device.allowAlert = true; device.profiles = [.battery]
        let store = BLEDeviceStore(testDevices: [device])
        XCTAssertNotNil(store.gattGrantSnapshot(id))
    }

    func testReadOffToOnFiresOnceWithProfiles() throws {
        let t = try XCTUnwrap(GattBotTrigger.decide(before: snap(read: false, alert: false),
                                                    after: snap(read: true, alert: false), isBoard: false))
        XCTAssertEqual(t.peripheralUUID, id.uuidString)
        XCTAssertEqual(t.name, "tag")
        XCTAssertEqual(t.profiles, ["battery", "temperature"])
    }

    func testAlertOffToOnFiresWithAlert() throws {
        let t = try XCTUnwrap(GattBotTrigger.decide(before: snap(read: false, alert: false),
                                                    after: snap(read: false, alert: true), isBoard: false))
        XCTAssertEqual(t.profiles, ["alert"])
    }

    func testAlertWithoutAlertProfileListsNothingButStillFiresOnEdge() throws {
        let t = try XCTUnwrap(GattBotTrigger.decide(before: snap(read: true, alert: false, profiles: [.battery]),
                                                    after: snap(read: true, alert: true, profiles: [.battery]), isBoard: false))
        XCTAssertEqual(t.profiles, ["battery"])
    }

    func testOnToOnAndOnToOffFireNothing() {
        XCTAssertNil(GattBotTrigger.decide(before: snap(read: true, alert: true),
                                           after: snap(read: true, alert: true), isBoard: false))
        XCTAssertNil(GattBotTrigger.decide(before: snap(read: true, alert: true),
                                           after: snap(read: false, alert: true), isBoard: false))
        XCTAssertNil(GattBotTrigger.decide(before: snap(read: true, alert: true),
                                           after: snap(read: false, alert: false), isBoard: false))
    }

    func testLinkDeviceAndBoardFireNothing() {
        XCTAssertNil(GattBotTrigger.decide(before: snap(read: false, alert: false, link: true),
                                           after: snap(read: true, alert: false, link: true), isBoard: false))
        XCTAssertNil(GattBotTrigger.decide(before: snap(read: false, alert: false),
                                           after: snap(read: true, alert: false), isBoard: true))
    }

    func testStoreUserGrantUsesRealGrantPath() throws {
        var device = BLEDeviceStore.Device(id: id, name: "tag", rssi: 0)
        device.profiles = [.battery, .alert]
        let store = BLEDeviceStore(testDevices: [device])
        let on = store.userGrant(id, read: true, isBoard: false)
        XCTAssertEqual(on?.profiles, ["battery"])
        XCTAssertNil(store.userGrant(id, read: true, isBoard: false), "on->on")
        XCTAssertNil(store.userGrant(id, read: false, isBoard: false), "on->off")
        XCTAssertEqual(store.userGrant(id, read: true, isBoard: false)?.profiles, ["battery"], "off->on again")
        XCTAssertNil(store.userGrant(UUID(), read: true, isBoard: false), "unknown device")
    }
}

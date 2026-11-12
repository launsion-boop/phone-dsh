// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Drives the real tier decoder/validator with the shared frozen vectors from
/// `spec/bot/v1/golden/tool-catalog-tiers.phone.json`.
final class BotToolCatalogTierTests: XCTestCase {
    private func value(_ object: [String: Any]) throws -> BotJSONValue {
        try BotJSONValue.parse(JSONSerialization.data(withJSONObject: object))
    }

    private func availability(_ connection: [String: Any]?) -> BotDeviceAvailability {
        guard let connection else { return .all }
        func flag(_ name: String) -> Bool { connection[name] as? Bool ?? false }
        return BotDeviceAvailability(adb: flag("adb"), ble: flag("ble"),
                                     venus: flag("venus"), ssh: flag("ssh"))
    }

    private func catalog() throws -> [String: Any] {
        let data = try BotGoldenFixture.rawData("tool-catalog-tiers.phone")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return root
    }

    func testValidVectorListsCoreDiscoverableAndConnectedDeviceGroups() throws {
        let valid = try XCTUnwrap(catalog()["valid"] as? [String: Any])
        let catalog = try BotToolTierCatalog(json: try value(XCTUnwrap(valid["catalog"] as? [String: Any])))
        let state = availability(valid["connection"] as? [String: Any])
        let listed = catalog.listedNames(availability: state)
        XCTAssertEqual(listed, valid["listed"] as? [String])
        XCTAssertTrue(Set(listed).isDisjoint(with: valid["notListed"] as? [String] ?? []))
        try catalog.validate(availability: state, listed: listed)
    }

    func testDeviceGroupAppearsOnTheVeryNextListAfterConnection() throws {
        let valid = try XCTUnwrap(catalog()["valid"] as? [String: Any])
        let catalog = try BotToolTierCatalog(json: try value(XCTUnwrap(valid["catalog"] as? [String: Any])))
        let before = catalog.listedNames(availability: BotDeviceAvailability(adb: true, ble: false))
        XCTAssertFalse(before.contains("ble_read"))
        // Same catalog instance: the change is the connection state, not a
        // process restart. The next list must already expose the group.
        let after = catalog.listedNames(availability: BotDeviceAvailability(adb: true, ble: true))
        XCTAssertTrue(after.contains("ble_read"))
        XCTAssertEqual(Array(after.prefix(before.count)), before)
        try catalog.validate(availability: BotDeviceAvailability(adb: true, ble: true), listed: after)
    }

    func testInvalidVectorsAreRejectedWithTheFrozenReason() throws {
        let invalid = try XCTUnwrap(catalog()["invalid"] as? [[String: Any]])
        XCTAssertFalse(invalid.isEmpty)
        for entry in invalid {
            let reason = try XCTUnwrap(entry["reason"] as? String)
            let caseValue = try XCTUnwrap(entry["case"] as? [String: Any])
            do {
                let catalog = try BotToolTierCatalog(json: try value(XCTUnwrap(caseValue["catalog"] as? [String: Any])))
                let state = availability(caseValue["connection"] as? [String: Any])
                try catalog.validate(availability: state,
                                     listed: caseValue["listed"] as? [String])
                XCTFail("invalid tier vector accepted: \(reason)")
            } catch let error as BotToolTierValidationError {
                XCTAssertEqual(error.rawValue, reason)
            }
        }
    }

    func testBotOwnedCatalogTiersAreConsistentWithP0AndP1() throws {
        let tiers = BotToolCatalog.tiers
        XCTAssertEqual(tiers.core, BotToolCatalog.p0Names)
        XCTAssertEqual(tiers.discoverable, BotToolCatalog.p1TargetNames)
        XCTAssertTrue(tiers.device.isEmpty)
        try tiers.validate()
        XCTAssertEqual(tiers.listedNames(availability: .all),
                       BotToolCatalog.p0Names + BotToolCatalog.p1TargetNames)
    }
}

// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import UIKit
import XCTest

/// `phone info` is the one row the Worker publishes for every host that
/// advertises `accelerator:phone`. The iOS catalog used to omit it, so the
/// model's first diagnostic call failed with `unknown_tool` while the manifest
/// claimed the tool existed. These tests pin the route, the payload the
/// manifest promises, and the bridge envelope.
@MainActor
final class PhoneInfoToolTests: XCTestCase {
    func testCatalogPublishesInfoOnTheAlwaysOnDeviceCapability() throws {
        let route = try XCTUnwrap(PhoneToolCatalog.routes["info"])
        XCTAssertEqual(route.capability, .device)
        XCTAssertEqual(route.scope, "device.read")
        XCTAssertFalse(route.writes)
        XCTAssertFalse(route.requiresFullAccess)
        XCTAssertEqual(PhoneCapability.device.defaultEnabled, true)
        XCTAssertEqual(PhoneCapability.device.isReadOnlyAlwaysOn, true)
    }

    func testInfoPayloadCarriesTheFieldsTheManifestPromises() throws {
        let data = PhoneDeviceTools().info().data
        XCTAssertFalse((data["model"] as? String ?? "").isEmpty)
        XCTAssertEqual(data["systemName"] as? String, "iOS")
        XCTAssertFalse((data["systemVersion"] as? String ?? "").isEmpty)
        XCTAssertFalse((data["idiom"] as? String ?? "").isEmpty)
        let display = try XCTUnwrap(data["display"] as? [String: Any])
        XCTAssertGreaterThan(display["widthPoints"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(display["heightPoints"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(display["scale"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(display["nativeWidthPx"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(display["nativeHeightPx"] as? Int ?? 0, 0)
    }

    func testBridgeAnswersInfoInsteadOfUnknownTool() async throws {
        let bridge = PhoneCapabilityBridge()
        let text = try await bridge.callTool(name: "phone.info", arguments: "{}")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true, text)
        XCTAssertEqual(object["tool"] as? String, "info")
        let data = try XCTUnwrap(object["data"] as? [String: Any], text)
        XCTAssertFalse((data["model"] as? String ?? "").isEmpty)
        XCTAssertNotNil(data["systemVersion"])
        XCTAssertNotNil(data["display"])
        XCTAssertEqual(object["scope"] as? String, "granted")
    }
}

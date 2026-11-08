// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import PhoneDSHBLE

/// Hosts the real Bluetooth page and inspects UIKit's rendered accessibility
/// hierarchy. The device/store lifecycle comes from the production test adapter;
/// this is not evidence of a physical Bluetooth connection.
@MainActor
final class BluetoothDevicesPageTests: XCTestCase {
    private struct Element {
        let identifier: String
        let label: String
        let traits: UIAccessibilityTraits
    }

    @MainActor
    private final class PageHost {
        let controller: UIHostingController<BluetoothDevicesPage>
        let window: UIWindow

        init(store: BLEDeviceStore) {
            controller = UIHostingController(rootView: BluetoothDevicesPage(store: store))
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 1200))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func elements() -> [Element] {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            var seen = Set<ObjectIdentifier>()
            var result: [Element] = []
            @MainActor func walk(_ object: NSObject) {
                guard seen.insert(ObjectIdentifier(object)).inserted, seen.count <= 10_000 else { return }
                if let id = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier, !id.isEmpty {
                    result.append(Element(identifier: id, label: object.accessibilityLabel ?? "",
                                          traits: object.accessibilityTraits))
                }
                if let values = object.accessibilityElements {
                    for case let child as NSObject in values { walk(child) }
                }
                if #available(iOS 17.0, *), let values = object.automationElements {
                    for case let child as NSObject in values { walk(child) }
                }
                let count = object.accessibilityElementCount()
                if count > 0 && count <= 500 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject { walk(child) }
                    }
                }
                if let view = object as? UIView {
                    for child in view.subviews { walk(child) }
                }
            }
            walk(controller.view)
            return result
        }
    }

    private func waitFor(_ identifier: String, in host: PageHost,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> Element {
        for _ in 0..<200 {
            if let match = host.elements().first(where: { $0.identifier == identifier }) { return match }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Rendered accessibility element not found: \(identifier)", file: file, line: line)
        throw NSError(domain: "BluetoothDevicesPageTests", code: 1)
    }

    private func assertUnavailable(_ host: PageHost, id: UUID, expected: String,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let suffix = id.uuidString
        let status = try await waitFor("ble-device-unavailable-\(suffix)", in: host, file: file, line: line)
        XCTAssertEqual(status.label, expected, file: file, line: line)
        let actions = host.elements().map(\.identifier).filter {
            $0.hasSuffix("-\(suffix)") && $0 != "ble-device-unavailable-\(suffix)"
        }
        XCTAssertTrue(actions.isEmpty, "Unavailable device exposed actions: \(actions)", file: file, line: line)
    }

    func testClosingPageKeepsDeviceVisibleUntilDisconnectCallbackReturns() async throws {
        let id = UUID()
        let adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [
            .init(id: id, name: "PDSH test peripheral", rssi: -40),
        ])
        store.connect(id)
        store.testDidConnect(id)
        store.testDiscover(id, profiles: [.battery, .alert])
        store.grant(id, read: true, alert: true)
        let host = PageHost(store: store)
        defer { host.close() }

        // Prove the real connected page rendered controls before checking that
        // the unavailable branch removes them; absence alone is insufficient.
        let read = try await waitFor("ble-device-read-battery-\(id.uuidString)", in: host)
        let alert = try await waitFor("ble-device-alert-0-\(id.uuidString)", in: host)
        XCTAssertFalse(read.traits.contains(.notEnabled))
        XCTAssertFalse(alert.traits.contains(.notEnabled))
        _ = try await waitFor("ble-device-grant-read-\(id.uuidString)", in: host)
        _ = try await waitFor("ble-device-grant-alert-\(id.uuidString)", in: host)

        store.disconnect(id)
        try await assertUnavailable(host, id: id, expected: "正在等待系统断开，暂不可重连")
        let commandsBeforeCallback = adapter.commands
        store.testDidDisconnect(id, during: {
            XCTAssertEqual(store.devices.first(where: { $0.id == id })?.state, "正在等待系统断开，暂不可重连")
            store.connect(id)
            XCTAssertEqual(adapter.commands, commandsBeforeCallback, "Reconnect must not pass the callback boundary")
        })

        let connect = try await waitFor("ble-device-connect-\(id.uuidString)", in: host)
        XCTAssertFalse(connect.traits.contains(.notEnabled))
        XCTAssertFalse(host.elements().contains { $0.identifier == "ble-device-unavailable-\(id.uuidString)" })
        store.connect(id)
        store.testDidConnect(id)
        store.testDiscover(id, profiles: [.battery, .alert])
        let explanation = try await waitFor("ble-device-reauthorize-\(id.uuidString)", in: host)
        XCTAssertEqual(explanation.label, "每次建立新连接后，请重新授权读取或提醒控制。")
        let current = try XCTUnwrap(store.devices.first(where: { $0.id == id }))
        XCTAssertFalse(current.allowRead)
        XCTAssertFalse(current.allowAlert)
        let afterRead = try await waitFor("ble-device-read-battery-\(id.uuidString)", in: host)
        let afterAlert = try await waitFor("ble-device-alert-0-\(id.uuidString)", in: host)
        XCTAssertTrue(afterRead.traits.contains(.notEnabled))
        XCTAssertTrue(afterAlert.traits.contains(.notEnabled))
    }

    func testQuarantinedPageKeepsDeviceVisibleAndOffersNoDeviceOperations() async throws {
        let id = UUID()
        let adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [
            .init(id: id, name: "PDSH test peripheral", rssi: -40),
        ])
        store.connect(id)
        store.testDidConnect(id)
        store.testDiscover(id, profiles: [.battery, .alert])
        store.grant(id, read: true, alert: true)
        let host = PageHost(store: store)
        defer { host.close() }
        _ = try await waitFor("ble-device-read-battery-\(id.uuidString)", in: host)
        _ = try await waitFor("ble-device-alert-0-\(id.uuidString)", in: host)

        store.testRadioUnavailable(reset: true)
        try await assertUnavailable(host, id: id, expected: "连接状态无法确认，暂不可用")
        XCTAssertFalse(try XCTUnwrap(store.devices.first(where: { $0.id == id })).allowRead)
        XCTAssertFalse(try XCTUnwrap(store.devices.first(where: { $0.id == id })).allowAlert)
    }
}

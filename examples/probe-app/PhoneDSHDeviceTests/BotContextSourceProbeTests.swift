// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHBot
#if canImport(Contacts)
import Contacts
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Device-layer probe for the native context sources.
///
/// It only reads Apple's authorization status and availability flags. It never
/// enumerates contacts, fetches calendar events, reads photos, asks for a
/// location or prompts the user, so running it cannot turn a tester's personal
/// data into a fixture. A real permission grant/revoke interaction still needs
/// a signed device run and a human; this file cannot claim that.
final class BotContextSourceProbeTests: XCTestCase {
    func testCapabilityMatrixKeepsIOSUnavailableFacts() {
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "third-party-notifications.read")?.support,
                       .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "sms.read")?.support, .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "call-history.read")?.support, .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "power.system-idle")?.support, .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "android.notification-listener")?.support,
                       .deferred)
    }

    func testAuthorizationStatusesAreReadWithoutDataAccess() async {
#if canImport(Contacts)
        let contacts = CNContactStore.authorizationStatus(for: .contacts)
        XCTAssertTrue([.notDetermined, .restricted, .denied, .authorized].contains(contacts))
#if os(iOS)
        if #available(iOS 18.0, *) {
            XCTAssertTrue(contacts == .limited || [.notDetermined, .restricted, .denied, .authorized].contains(contacts))
        }
#endif
#endif
#if canImport(EventKit)
        let events = EKEventStore.authorizationStatus(for: .event)
        XCTAssertFalse(String(describing: events).isEmpty)
#endif
#if canImport(CoreLocation)
        _ = CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
        XCTAssertFalse(String(describing: CLLocationManager.authorizationStatus()).isEmpty)
#endif
    }

    func testInjectedDeliveryIsNeverReal() {
        XCTAssertFalse(BotContextObservationDelivery.injected.isReal)
        XCTAssertTrue(BotContextObservationDelivery.os.isReal)
    }

    func testSourceVersionRejectsAnUnfrozenReason() {
        let json = Data(#"{"reason":""}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BotContextSourceVersion.self, from: json))
    }
}

// SPDX-License-Identifier: MIT

@testable import PhoneDSHProbe
@testable import ProbeKit
import XCTest

final class PA_DeepLinkTests: XCTestCase {
    func testNotificationAndLegacyRoutesResolveToTheSameDestinations() throws {
        let id = UUID()
        XCTAssertEqual(AppDeepLink.parse(try XCTUnwrap(URL(string: "phonedsh://profile/model"))), .profile(.model))
        XCTAssertEqual(AppDeepLink.parse(try XCTUnwrap(URL(string: "phonedsh://chat/follow-up/\(id.uuidString)"))),
                       .chat(focus: .followUp(id)))
        XCTAssertEqual(AppDeepLink.parse(try XCTUnwrap(URL(string: "pdsh://profile?focus=model"))), .profile(.model))
        XCTAssertEqual(AppDeepLink.parse(try XCTUnwrap(URL(string: "pdsh://chat?followUp=\(id.uuidString)"))),
                       .chat(focus: .followUp(id)))
    }
}

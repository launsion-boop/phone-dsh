// SPDX-License-Identifier: MIT

#if canImport(UserNotifications)
import UserNotifications
import XCTest
@testable import PhoneDSHBot

final class UNUserNotificationProactiveDeliveryTests: XCTestCase {
    func testStableIdentifierAndDeepLinkUseRealUNNotificationRequest() async throws {
        let center = WP6UNCenter()
        let delivery = UNUserNotificationProactiveDelivery(center: center)
        let notification = ProactiveNotification(title: "Digest", body: "Result", kind: .routineResult,
                                                 botId: "bot-a", dedupeKey: "routine-result:daily:run-1:1",
                                                 rowId: "routine-run-daily-1")
        let result = try await delivery.deliver(notification)
        XCTAssertTrue(result.delivered)
        XCTAssertEqual(center.requests.count, 1)
        let request = center.requests[0]
        XCTAssertEqual(request.identifier, "routine-result:daily:run-1:1")
        XCTAssertEqual(request.content.title, "Digest")
        XCTAssertEqual(request.content.body, "Result")
        XCTAssertEqual(request.content.userInfo["deepLink"] as? String,
                       "phonedsh://bot/bot-a/row/routine-run-daily-1")
        XCTAssertEqual(request.content.userInfo["dedupeKey"] as? String, request.identifier)
        XCTAssertNil(request.trigger)

        _ = try await delivery.deliver(notification)
        XCTAssertEqual(center.requests.map(\.identifier), [notification.dedupeKey, notification.dedupeKey])
    }

    func testMissingDedupeKeyOrDeepLinkFailsClosed() async {
        let delivery = UNUserNotificationProactiveDelivery(center: WP6UNCenter())
        let noKey = ProactiveNotification(title: "Digest", body: "Result", kind: .routineResult,
                                          botId: "bot-a", dedupeKey: "", rowId: "row-1")
        await XCTAssertThrowsErrorAsync(try await delivery.deliver(noKey))
        let noLink = ProactiveNotification(title: "Digest", body: "Result", kind: .routineResult,
                                           botId: "bot-a", dedupeKey: "stable")
        await XCTAssertThrowsErrorAsync(try await delivery.deliver(noLink))
    }
}

private final class WP6UNCenter: BotProactiveNotificationCenter {
    var requests: [UNNotificationRequest] = []
    func add(_ request: UNNotificationRequest) async throws { requests.append(request) }
}
#endif

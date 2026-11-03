// SPDX-License-Identifier: MIT

import XCTest

@MainActor
final class PA_SettingsPresentationTests: XCTestCase {
    func testNotificationRefreshReflectsSystemAuthorization() async {
        let center = PA_SettingsNotificationCenter(authorization: .authorized)
        let settings = PersonalAgentNotificationSettings(center: center)

        await settings.refresh()

        XCTAssertTrue(settings.isLoaded)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.authorization, .authorized)
    }

    func testEnablingNotificationsRequestsPermissionAndUsesRefreshedStatus() async {
        let center = PA_SettingsNotificationCenter(authorization: .notDetermined, authorizationAfterRequest: .authorized)
        let settings = PersonalAgentNotificationSettings(center: center)

        await settings.setEnabled(true)

        let requestCount = await center.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(settings.requiresSystemSettings)
        XCTAssertNil(settings.errorMessage)
    }

    func testDeniedRequestStaysOffAndOffersSystemSettings() async {
        let center = PA_SettingsNotificationCenter(authorization: .denied)
        let settings = PersonalAgentNotificationSettings(center: center)

        await settings.setEnabled(true)

        let requestCount = await center.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertTrue(settings.requiresSystemSettings)
    }

    func testDisablingSystemPermissionDoesNotFakeAnOffState() async {
        let center = PA_SettingsNotificationCenter(authorization: .authorized)
        let settings = PersonalAgentNotificationSettings(center: center)
        await settings.refresh()

        await settings.setEnabled(false)

        let requestCount = await center.requestCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(settings.requiresSystemSettings)
    }

    func testFailedRequestNeverClaimsNotificationsAreEnabled() async {
        let center = PA_SettingsNotificationCenter(authorization: .denied, requestError: PA_SettingsError.failed)
        let settings = PersonalAgentNotificationSettings(center: center)

        await settings.setEnabled(true)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertNotNil(settings.errorMessage)
        XCTAssertFalse(settings.requiresSystemSettings)
    }

    func testProvisionalAuthorizationIsUsableButEphemeralIsNot() {
        XCTAssertTrue(PersonalAgentNotificationAuthorization.provisional.allowsNotifications)
        XCTAssertFalse(PersonalAgentNotificationAuthorization.unavailable.allowsNotifications)
    }

    func testAutomationSummaryCountsOnlyActiveSchedules() {
        XCTAssertEqual(PersonalAgentAutomationSummary.enabledCount(
            statuses: ["active", "stopped", "active", "paused"]), 2)
        XCTAssertEqual(PersonalAgentAutomationSummary.enabledCount(statuses: []), 0)
    }
}

private enum PA_SettingsError: Error {
    case failed
}

private actor PA_SettingsNotificationCenter: PersonalAgentNotificationCentering {
    private var currentAuthorization: PersonalAgentNotificationAuthorization
    private let authorizationAfterRequest: PersonalAgentNotificationAuthorization?
    private let requestError: Error?
    private(set) var requestCount = 0

    init(authorization: PersonalAgentNotificationAuthorization,
         authorizationAfterRequest: PersonalAgentNotificationAuthorization? = nil,
         requestError: Error? = nil) {
        currentAuthorization = authorization
        self.authorizationAfterRequest = authorizationAfterRequest
        self.requestError = requestError
    }

    func authorization() async -> PersonalAgentNotificationAuthorization {
        currentAuthorization
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if let requestError { throw requestError }
        if let authorizationAfterRequest { currentAuthorization = authorizationAfterRequest }
        return currentAuthorization.allowsNotifications
    }
}

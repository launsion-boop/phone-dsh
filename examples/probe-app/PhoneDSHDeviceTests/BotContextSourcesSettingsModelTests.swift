// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHProbe
import PhoneDSHBot

@MainActor
final class BotContextSourcesSettingsModelTests: XCTestCase {
    func testTwoBotSubscriptionAndGlobalRevokeThroughSettingsModel() async throws {
        let dependencies = BotContextSourcesDependencies(
            now: { 9_000_000 },
            consentStore: InMemoryBotContextSourceConsentStore(),
            audit: BotContextAuditLog(),
            injectedSources: [.calendar])
        let assembly = BotContextSourcesAssembly(dependencies: dependencies)
        try await assembly.start { _ in }

        let botA = BotContextSourcesSettingsModel(botID: "bot-a", assembly: assembly)
        let botB = BotContextSourcesSettingsModel(botID: "bot-b", assembly: assembly)
        await botA.load()
        await botB.load()
        XCTAssertFalse(botA.isEnabled(.calendar))
        XCTAssertFalse(botB.isEnabled(.calendar))

        await botA.set(.calendar, enabled: true)
        await botA.load()
        await botB.load()
        XCTAssertTrue(botA.isEnabled(.calendar), "A's own switch is on")
        XCTAssertFalse(botB.isEnabled(.calendar), "B must not inherit A's subscription")

        await botB.set(.calendar, enabled: true)
        await botB.load()
        await botA.load()
        XCTAssertTrue(botA.isEnabled(.calendar))
        XCTAssertTrue(botB.isEnabled(.calendar))
        let revisionAfterB = await assembly.authorization(for: .calendar)?.permissionRevision
        XCTAssertNotNil(revisionAfterB)

        // Turning off A only unsubscribes A.
        await botA.set(.calendar, enabled: false)
        await botA.load()
        await botB.load()
        XCTAssertFalse(botA.isEnabled(.calendar))
        XCTAssertTrue(botB.isEnabled(.calendar), "closing A must not stop B")

        // A global revoke invalidates both subscriptions and the generation.
        let before = await assembly.authorization(for: .calendar)?.permissionRevision
        await assembly.revoke(source: .calendar, reason: "global-user-revoke")
        await botA.load()
        await botB.load()
        XCTAssertFalse(botA.isEnabled(.calendar))
        XCTAssertFalse(botB.isEnabled(.calendar))
        let after = await assembly.authorization(for: .calendar)?.permissionRevision
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        XCTAssertGreaterThan(after ?? 0, before ?? 0)
        await assembly.stopAll()
    }
}

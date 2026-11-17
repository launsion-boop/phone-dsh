// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHProbe
import PhoneDSHBot

@MainActor
final class BotContextSourcesSettingsGenerationTests: XCTestCase {
    func testLateOldReadCannotApplyAfterNewerLoad() async throws {
        let dependencies = BotContextSourcesDependencies(
            now: { 10_000_000 },
            consentStore: InMemoryBotContextSourceConsentStore(),
            audit: BotContextAuditLog(),
            injectedSources: [.calendar])
        let assembly = BotContextSourcesAssembly(dependencies: dependencies)
        let model = BotContextSourcesSettingsModel(botID: "bot-a", assembly: assembly)

        let old = model.beginGenerationForTesting()
        let new = model.beginGenerationForTesting()
        XCTAssertFalse(model.isCurrentGenerationForTesting(old),
                       "a late old read must be rejected")
        XCTAssertTrue(model.isCurrentGenerationForTesting(new))
        // Bounded, deterministic: only the newest generation may apply its
        // states/actionError/loading. The real readStates() uses the same guard.
        let newest = model.beginGenerationForTesting()
        XCTAssertFalse(model.isCurrentGenerationForTesting(new))
        XCTAssertTrue(model.isCurrentGenerationForTesting(newest))
    }
}

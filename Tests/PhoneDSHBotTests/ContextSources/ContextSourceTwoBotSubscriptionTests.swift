// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class ContextSourceTwoBotSubscriptionTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 8_000_000 }

    func testTwoBotSubscriptionBoundaryAndGlobalRevoke() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: BotContextAuditLog(), now: now)
        _ = await ledger.load()
        try await registry.register(fake)
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")

        let aSubscribed = await registry.isSubscribed(botID: "bot-a", source: .calendar)
        let bSubscribed = await registry.isSubscribed(botID: "bot-b", source: .calendar)
        XCTAssertTrue(aSubscribed)
        XCTAssertFalse(bSubscribed, "Bot B must not inherit Bot A's subscription")
        do {
            _ = try await registry.observations(for: "bot-b", sources: [.calendar])
            XCTFail("Bot B must not read without its own subscription")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError,
                           .notAuthorized(.calendar, permissionRevision: 1))
        }

        // B reuses the existing legal App/OS authorization without a new prompt
        // or a second consent document.
        try await registry.subscribe(botID: "bot-b", sources: [.calendar])
        let aStill = await ledger.isSubscribed(botID: "bot-a", source: .calendar)
        let bNow = await ledger.isSubscribed(botID: "bot-b", source: .calendar)
        XCTAssertTrue(aStill)
        XCTAssertTrue(bNow)
        let countsAfterB = await fake.counts()
        XCTAssertEqual(countsAfterB.start, 1, "B subscribe reuses the started adapter")

        // Turning off A is per-Bot: B stays subscribed and the adapter is not
        // stopped. This is not a global revoke.
        try await registry.unsubscribe(botID: "bot-a", sources: [.calendar])
        let aOff = await registry.isSubscribed(botID: "bot-a", source: .calendar)
        let bOn = await registry.isSubscribed(botID: "bot-b", source: .calendar)
        XCTAssertFalse(aOff)
        XCTAssertTrue(bOn, "closing A must not stop B")
        let countsAfterA = await fake.counts()
        XCTAssertEqual(countsAfterA.stop, 0, "B still subscribed: adapter stays running")
        do {
            _ = try await registry.observations(for: "bot-a", sources: [.calendar])
            XCTFail("A is unsubscribed and must not read")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError,
                           .notAuthorized(.calendar, permissionRevision: 1))
        }

        // A global revoke ends all subscriptions and invalidates the generation;
        // a late callback cannot be delivered to B.
        await registry.revoke(source: .calendar, reason: "global-user-revoke")
        let bAfterRevoke = await registry.isSubscribed(
            botID: "bot-b", source: .calendar)
        XCTAssertFalse(bAfterRevoke)
        let revokedState = await ledger.state(for: .calendar)
        XCTAssertEqual(revokedState.authorization, .revoked)
        XCTAssertEqual(revokedState.permissionRevision, 2)
        do {
            _ = try await registry.observations(for: "bot-b", sources: [.calendar])
            XCTFail("global revoke must block B")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError, .revoked(.calendar))
        }
        await fake.emit(try await fake.observation(
            id: "late-global", observedAt: 8_000_009, revision: 1))
        let view = await registry.observationView(for: "bot-b", sources: [.calendar])
        XCTAssertFalse(view.items.contains { $0.state == .active })
        let finalCounts = await fake.counts()
        XCTAssertEqual(finalCounts.stop, 1)
    }
}

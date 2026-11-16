// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private actor FailingConsentStore: BotContextSourceConsentPersisting {
    func load() async throws -> BotContextConsentDocument? { nil }
    func save(_ document: BotContextConsentDocument) async throws {
        throw BotContextSourceError.unavailable("disk-full")
    }
}

private actor StaticConsentStore: BotContextSourceConsentPersisting {
    private var document: BotContextConsentDocument?
    init(document: BotContextConsentDocument?) { self.document = document }
    func load() async throws -> BotContextConsentDocument? { document }
    func save(_ document: BotContextConsentDocument) async throws { self.document = document }
}

final class ContextSourceConsentLedgerTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 5_000_000 }

    func testDefaultStateIsSafeAndNeverAuthorized() async {
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        _ = await ledger.load()
        for source in BotContextSourceKind.allCases {
            let state = await ledger.state(for: source)
            XCTAssertEqual(state.authorization, .notDetermined, source.rawValue)
            XCTAssertEqual(state.permissionRevision, 0)
            XCTAssertFalse(state.authorization.allowsReading)
        }
        let subscriptions = await ledger.subscriptions(for: "bot-a")
        XCTAssertTrue(subscriptions.isEmpty)
    }

    func testGrantSubscribeRevokeRoundTripIsPersisted() async throws {
        let store = InMemoryBotContextSourceConsentStore()
        let first = BotContextConsentLedger(store: store, now: now)
        _ = await first.load()
        let granted = try await first.grant(source: .calendar, by: .user)
        XCTAssertEqual(granted.authorization, .authorized)
        XCTAssertEqual(granted.permissionRevision, 1)
        try await first.subscribe(botID: "bot-a", source: .calendar)
        let firstSubscribed = await first.isSubscribed(botID: "bot-a", source: .calendar)
        XCTAssertTrue(firstSubscribed)

        let second = BotContextConsentLedger(store: store, now: now)
        _ = await second.load()
        let restoredState = await second.state(for: .calendar)
        let secondSubscribed = await second.isSubscribed(botID: "bot-a", source: .calendar)
        let restoredStart = await second.subscriptionStart(botID: "bot-a", source: .calendar)
        XCTAssertEqual(restoredState.authorization, .authorized)
        XCTAssertTrue(secondSubscribed)
        XCTAssertEqual(restoredStart, 5_000_000)
    }

    func testRevokeIncrementsRevisionAndRemovesSubscriptions() async throws {
        let store = InMemoryBotContextSourceConsentStore()
        let ledger = BotContextConsentLedger(store: store, now: now)
        _ = await ledger.load()
        _ = try await ledger.grant(source: .calendar)
        try await ledger.subscribe(botID: "bot-a", source: .calendar)
        let revoked = try await ledger.revoke(source: .calendar, by: .user, reason: "user-revoked")
        XCTAssertEqual(revoked.authorization, .revoked)
        XCTAssertEqual(revoked.permissionRevision, 2)
        XCTAssertEqual(revoked.detail, "user-revoked")
        let subscriptions = await ledger.subscriptions(for: "bot-a")
        XCTAssertTrue(subscriptions.isEmpty)
        let subscribedAfterRevoke = await ledger.isSubscribed(botID: "bot-a", source: .calendar)
        XCTAssertFalse(subscribedAfterRevoke)
    }

    func testOSDenialDemotesAndRemovesSubscriptionsButKeepsDeniedState() async throws {
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        _ = await ledger.load()
        _ = try await ledger.grant(source: .contacts)
        try await ledger.subscribe(botID: "bot-a", source: .contacts)
        let denied = try await ledger.noteOSStatus(source: .contacts, status: .denied)
        XCTAssertEqual(denied.authorization, .denied)
        XCTAssertEqual(denied.permissionRevision, 2)
        let contactsSubscribed = await ledger.isSubscribed(botID: "bot-a", source: .contacts)
        XCTAssertFalse(contactsSubscribed)
    }

    func testOSRegrantDoesNotResurrectUserRevokedSource() async throws {
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        _ = await ledger.load()
        _ = try await ledger.grant(source: .locationFence)
        try await ledger.subscribe(botID: "bot-a", source: .locationFence)
        _ = try await ledger.revoke(source: .locationFence, by: .user, reason: "revoked")
        let after = try await ledger.noteOSStatus(source: .locationFence, status: .authorized)
        XCTAssertEqual(after.authorization, .revoked)
        let locationSubscribed = await ledger.isSubscribed(botID: "bot-a", source: .locationFence)
        XCTAssertFalse(locationSubscribed)
    }

    func testMalformedOrFutureDocumentLoadsSafeDefaults() async throws {
        let store = StaticConsentStore(document: BotContextConsentDocument(v: 99))
        let ledger = BotContextConsentLedger(store: store, now: now)
        let error = await ledger.load()
        XCTAssertNotNil(error)
        for source in BotContextSourceKind.allCases {
            let state = await ledger.state(for: source)
            XCTAssertEqual(state.authorization, .notDetermined)
        }
        let subscriptions = await ledger.subscriptions(for: "bot-a")
        XCTAssertTrue(subscriptions.isEmpty)
    }

    func testStaleSubscriptionRevisionIsNotRestored() async throws {
        let document = BotContextConsentDocument(
            consents: [BotContextSourceConsent(
                source: .calendar, authorization: .authorized, permissionRevision: 3,
                updatedAt: 1, updatedBy: .user)],
            subscriptions: [BotContextSourceSubscription(
                botID: "bot-a", source: .calendar, subscribedAt: 1, permissionRevision: 2)])
        let store = StaticConsentStore(document: document)
        let ledger = BotContextConsentLedger(store: store, now: now)
        _ = await ledger.load()
        let calendarState = await ledger.state(for: .calendar)
        let subscribed = await ledger.isSubscribed(botID: "bot-a", source: .calendar)
        XCTAssertEqual(calendarState.authorization, .authorized)
        XCTAssertFalse(subscribed)
    }

    func testSaveFailureDoesNotGrantOrSubscribe() async throws {
        let ledger = BotContextConsentLedger(store: FailingConsentStore(), now: now)
        _ = await ledger.load()
        do {
            _ = try await ledger.grant(source: .power)
            XCTFail("grant must not be observable before it is durable")
        } catch {
            let state = await ledger.state(for: .power)
            XCTAssertEqual(state.authorization, .notDetermined)
            XCTAssertEqual(state.permissionRevision, 0)
        }
    }

    func testConsentDocumentRejectsDuplicates() throws {
        let duplicate = BotContextConsentDocument(
            consents: [
                BotContextSourceConsent(source: .calendar),
                BotContextSourceConsent(source: .calendar),
            ])
        XCTAssertThrowsError(try duplicate.validated())
        let duplicateSubscriptions = BotContextConsentDocument(
            consents: [BotContextSourceConsent(source: .calendar, authorization: .authorized)],
            subscriptions: [
                BotContextSourceSubscription(botID: "bot-a", source: .calendar,
                                             subscribedAt: 1, permissionRevision: 0),
                BotContextSourceSubscription(botID: "bot-a", source: .calendar,
                                             subscribedAt: 1, permissionRevision: 0),
            ])
        XCTAssertThrowsError(try duplicateSubscriptions.validated())
    }
}

final class ContextSourceConsentStoreTests: XCTestCase {
    func testUserDefaultsStoreUsesFrozenKeyAndRejectsUnknownVersion() async throws {
        let suite = "context-source-consent-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsBotContextSourceConsentStore(defaults: defaults)
        let document = BotContextConsentDocument(
            consents: [
                BotContextSourceConsent(
                    source: .calendar, authorization: .authorized,
                    permissionRevision: 2, updatedAt: 10, updatedBy: .user,
                    osAuthorization: .authorized),
            ],
            subscriptions: [
                BotContextSourceSubscription(
                    botID: "bot-a", source: .calendar,
                    subscribedAt: 10, permissionRevision: 2),
            ])
        try await store.save(document)
        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsBotContextSourceConsentStore.key))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "consents", "subscriptions"])
        let consents = try XCTUnwrap(object["consents"] as? [[String: Any]])
        let firstConsent = try XCTUnwrap(consents.first)
        XCTAssertEqual(Set(firstConsent.keys),
                       ["source", "state", "os_state", "generation", "updated_at_ms", "by"])
        let restored = try await store.load()
        XCTAssertEqual(restored?.v, 1)

        // A future/corrupt value must not be decoded as authorized.
        defaults.set(Data(#"{"v":99,"consents":[],"subscriptions":[]}"#.utf8),
                     forKey: UserDefaultsBotContextSourceConsentStore.key)
        do {
            _ = try await store.load()
            XCTFail("unknown consent version must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("99")
                          || String(describing: error).count > 0)
        }
    }
}

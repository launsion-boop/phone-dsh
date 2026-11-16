// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Minimal adapter-shaped source with configurable OS status/read capability
/// and a counted full-access request. The registry is the real one.
private final class CapabilitySource: BotContextSourceRequesting,
                                     BotContextSourceStreaming,
                                     @unchecked Sendable {
    let kind: BotContextSourceKind
    let current: BotSourceAuthorization
    let requestResult: BotSourceAuthorization
    let limitedReadable: Bool
    private let lock = NSLock()
    private var requests = 0
    private var starts = 0

    init(kind: BotContextSourceKind, current: BotSourceAuthorization,
         requestResult: BotSourceAuthorization, limitedReadable: Bool) {
        self.kind = kind
        self.current = current
        self.requestResult = requestResult
        self.limitedReadable = limitedReadable
    }

    func authorization() async -> BotSourceAuthorization { current }
    func requestAuthorization() async -> BotSourceAuthorization {
        lock.lock(); requests += 1; lock.unlock()
        return requestResult
    }
    func canRead(_ authorization: BotSourceAuthorization) -> Bool {
        if authorization == .limited { return limitedReadable }
        return authorization.allowsReading
    }
    func start(permissionRevision: Int,
               emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        lock.lock(); starts += 1; lock.unlock()
    }
    func observations(since: Int64?) async throws -> [BotContextObservation] { [] }
    func stop() async {}
    func requestCount() -> Int { lock.lock(); defer { lock.unlock() }; return requests }
    func startCount() -> Int { lock.lock(); defer { lock.unlock() }; return starts }
}

final class ContextSourceLimitedReadabilityTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 10_000_000 }

    private func make(_ source: CapabilitySource) async throws
        -> (BotContextSourceRegistry, BotContextConsentLedger) {
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: BotContextAuditLog(), now: now)
        _ = await ledger.load()
        try await registry.register(source)
        return (registry, ledger)
    }

    func testCalendarWriteOnlyRequestsFullAccessThenSubscribes() async throws {
        let source = CapabilitySource(
            kind: .calendar, current: .limited,
            requestResult: .authorized, limitedReadable: false)
        let (registry, ledger) = try await make(source)
        _ = try await ledger.grant(source: .calendar, by: .user, authorization: .limited)

        let state = try await registry.requestConsent(
            source: .calendar, botID: "bot-a")
        XCTAssertEqual(source.requestCount(), 1, "write-only calendar must request full access")
        XCTAssertEqual(state.authorization, .authorized)
        XCTAssertEqual(source.startCount(), 1)
        let subscribed = await ledger.isSubscribed(botID: "bot-a", source: .calendar)
        XCTAssertTrue(subscribed)
    }

    func testCalendarWriteOnlyUpgradeRejectedDoesNotSubscribeOrStart() async throws {
        for result in [BotSourceAuthorization.limited, .denied] {
            let source = CapabilitySource(
                kind: .calendar, current: .limited,
                requestResult: result, limitedReadable: false)
            let (registry, ledger) = try await make(source)
            _ = try await ledger.grant(source: .calendar, by: .user, authorization: .limited)
            do {
                _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
                XCTFail("upgrade result \(result.rawValue) must not subscribe")
            } catch {
                guard case BotContextSourceError.notAuthorized = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
            let state = await ledger.state(for: .calendar)
            XCTAssertEqual(state.authorization, result == .denied ? .denied : .limited)
            let subscribed = await ledger.isSubscribed(botID: "bot-a", source: .calendar)
            XCTAssertFalse(subscribed)
            XCTAssertEqual(source.startCount(), 0)
        }
    }

    func testContactsLimitedIsReadableWithoutUpgradeRequest() async throws {
        let source = CapabilitySource(
            kind: .contacts, current: .limited,
            requestResult: .authorized, limitedReadable: true)
        let (registry, ledger) = try await make(source)
        _ = try await ledger.grant(source: .contacts, by: .user, authorization: .limited)
        let state = try await registry.requestConsent(source: .contacts, botID: "bot-a")
        XCTAssertEqual(source.requestCount(), 0, "contacts limited is already readable")
        XCTAssertEqual(state.authorization, .limited)
        XCTAssertEqual(source.startCount(), 1)
        let subscribed = await ledger.isSubscribed(botID: "bot-a", source: .contacts)
        XCTAssertTrue(subscribed)
    }

    func testAlreadyFullAccessDoesNotPromptAgain() async throws {
        let source = CapabilitySource(
            kind: .calendar, current: .authorized,
            requestResult: .authorized, limitedReadable: false)
        let (registry, ledger) = try await make(source)
        _ = try await ledger.grant(source: .calendar, by: .user, authorization: .authorized)
        let state = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        XCTAssertEqual(source.requestCount(), 0)
        XCTAssertEqual(state.authorization, .authorized)
        XCTAssertEqual(source.startCount(), 1)
    }
}

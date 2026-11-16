// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// A real adapter-shaped source whose OS authorization callback the test can
/// hold open, reusing the registry's request identity rather than a fake
/// permission store.
private final class GatedAuthorizationSource: BotContextSourceRequesting,
                                             BotContextSourceStreaming,
                                             @unchecked Sendable {
    let kind: BotContextSourceKind = .calendar
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BotSourceAuthorization, Never>?
    private var requested = false
    private var starts = 0

    func authorization() async -> BotSourceAuthorization { .notDetermined }

    func requestAuthorization() async -> BotSourceAuthorization {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.requested = true
            lock.unlock()
        }
    }

    func start(permissionRevision: Int,
               emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        lock.lock(); starts += 1; lock.unlock()
    }

    func observations(since: Int64?) async throws -> [BotContextObservation] { [] }
    func stop() async {}

    func waitUntilRequested() async {
        for _ in 0..<100 {
            lock.lock(); let value = requested; lock.unlock()
            if value { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func resume(_ status: BotSourceAuthorization) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(returning: status)
    }

    func startCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return starts
    }
}

final class ContextSourceConsentRaceTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 9_000_000 }

    private func make() async throws
        -> (BotContextSourceRegistry, BotContextConsentLedger, GatedAuthorizationSource) {
        let source = GatedAuthorizationSource()
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: BotContextAuditLog(), now: now)
        _ = await ledger.load()
        try await registry.register(source)
        return (registry, ledger, source)
    }

    func testRevokeWhilePromptPendingRejectsLateAuthorizedCallback() async throws {
        let (registry, ledger, source) = try await make()
        let request = Task {
            try await registry.requestConsent(source: .calendar, botID: "bot-a")
        }
        await source.waitUntilRequested()
        await registry.revoke(source: .calendar, reason: "user-cancel-during-prompt")
        source.resume(.authorized)
        do {
            _ = try await request.value
            XCTFail("late authorized callback must not grant after revoke")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError, .staleCallback)
        }
        let state = await ledger.state(for: .calendar)
        XCTAssertEqual(state.authorization, .revoked)
        let subscribed = await ledger.isSubscribed(botID: "bot-a", source: .calendar)
        XCTAssertFalse(subscribed)
        XCTAssertEqual(source.startCount(), 0, "cancelled request must not start the provider")
    }

    func testUnsubscribeWhilePromptPendingRejectsLateAuthorizedCallback() async throws {
        let (registry, ledger, source) = try await make()
        let request = Task {
            try await registry.requestConsent(source: .calendar, botID: "bot-a")
        }
        await source.waitUntilRequested()
        await registry.unsubscribe(botID: "bot-a", source: .calendar)
        source.resume(.authorized)
        do {
            _ = try await request.value
            XCTFail("late authorized callback must not grant after cancel")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError, .staleCallback)
        }
        let state = await ledger.state(for: .calendar)
        XCTAssertEqual(state.authorization, .notDetermined)
        let subscribed = await ledger.isSubscribed(botID: "bot-a", source: .calendar)
        XCTAssertFalse(subscribed)
        XCTAssertEqual(source.startCount(), 0)
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFeedbackStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var domain: SQLiteDomainStore!
    private var root: URL!

    override func setUp() async throws {
        suiteName = "feedback-store-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        (domain, root) = try makeMemoryTestStore()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? await domain?.close()
        cleanupMemoryTestStore(root)
    }

    private func makeCenter(_ clock: WP6Clock,
                            store: (any BotFeedbackStoring)? = nil) throws -> BotFeedbackCenter {
        let resolved: any BotFeedbackStoring = try store
            ?? (UserDefaultsBotFeedbackStore(defaults: defaults) as any BotFeedbackStoring)
        return BotFeedbackCenter(store: resolved, eventLog: domain, memory: nil,
                                 now: { clock.now })
    }

    func testRoundTripAndMissingKeyIsEmpty() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = try makeCenter(clock)
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await center.noteConsidered(decision, candidate: candidate)
        let outcome = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .user, nonce: "persist"))
        XCTAssertEqual(outcome.status, .accepted)
        XCTAssertNotNil(defaults.data(forKey: BotFeedbackIndexFile.defaultsKey))

        let reloaded = try makeCenter(clock)
        let preferences = try await reloaded.preferences(botID: "bot-1", scope: nil)
        XCTAssertEqual(preferences.active.count, 1)
        let health = await reloaded.storeHealth()
        XCTAssertEqual(health, "ok")
    }

    func testUnknownVersionIsIgnoredAndRebuiltFromEvents() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = try makeCenter(clock)
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await center.noteConsidered(decision, candidate: candidate)
        _ = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .user, nonce: "future"))

        defaults.set(Data("{\"v\":2,\"records\":[],\"rebuilt_from_commit_seq\":0}".utf8),
                     forKey: BotFeedbackIndexFile.defaultsKey)
        let rebuilt = try makeCenter(clock)
        let preferences = try await rebuilt.preferences(botID: "bot-1", scope: nil)
        XCTAssertEqual(preferences.active.count, 1, "the event log is the fact source")
        let health = await rebuilt.storeHealth()
        XCTAssertTrue(health.contains("index-version-2-ignored"), health)
        let hold = await rebuilt.hold(for: FeedbackFixtures.candidate("task-2"),
                                      botID: "bot-1", at: clock.now)
        XCTAssertTrue(hold.isHeld)
    }

    func testCorruptIndexIsIgnoredAndRebuiltFromEvents() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = try makeCenter(clock)
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await center.noteConsidered(decision, candidate: candidate)
        _ = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .user, nonce: "corrupt"))

        defaults.set(Data("{not-json".utf8), forKey: BotFeedbackIndexFile.defaultsKey)
        let rebuilt = try makeCenter(clock)
        let preferences = try await rebuilt.preferences(botID: "bot-1", scope: nil)
        XCTAssertEqual(preferences.active.count, 1)
        let health = await rebuilt.storeHealth()
        XCTAssertTrue(health.contains("decode-failed") || health.contains("corrupted"), health)
    }

    func testIndexWriteFailureWithoutJournalFailsTheCall() async throws {
        let inMemory = InMemoryBotFeedbackStore(saveError: .unavailable("disk-full"))
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = BotFeedbackCenter(store: inMemory, eventLog: nil, memory: nil,
                                       now: { clock.now })
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await center.noteConsidered(decision, candidate: candidate)
        do {
            _ = try await center.record(
                FeedbackFixtures.suppress(decision, scope: .user, nonce: "full"))
            XCTFail("a failed index write without a journal must throw")
        } catch let error as BotFeedbackStoreError {
            XCTAssertEqual(error, .unavailable("disk-full"))
        }
        let active = try await center.preferences(botID: "bot-1", scope: nil).active
        XCTAssertEqual(active.count, 0)
    }

    func testEventFirstIndexFailureStillReplaysThePreference() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let failing = InMemoryBotFeedbackStore(saveError: .unavailable("index-full"))
        let center = BotFeedbackCenter(store: failing, eventLog: domain, memory: nil,
                                       now: { clock.now })
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await center.noteConsidered(decision, candidate: candidate)
        let outcome = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .user, nonce: "durable"))
        XCTAssertEqual(outcome.status, .accepted)
        XCTAssertTrue(outcome.auditPending, "the durable fact landed but the index did not")

        let recovered = try makeCenter(clock, store: InMemoryBotFeedbackStore())
        let preferences = try await recovered.preferences(botID: "bot-1", scope: nil)
        XCTAssertEqual(preferences.active.count, 1, "startup replay must rebuild the index")
        let hold = await recovered.hold(for: FeedbackFixtures.candidate("task-2"),
                                        botID: "bot-1", at: clock.now)
        XCTAssertTrue(hold.isHeld)
    }

    func testReplayCursorSkipsAlreadyAppliedEvents() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = try makeCenter(clock)
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await center.noteConsidered(decision, candidate: candidate)
        _ = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .user, nonce: "cursor-1"))
        let data = try XCTUnwrap(defaults.data(forKey: BotFeedbackIndexFile.defaultsKey))
        let index = try JSONDecoder().decode(BotFeedbackIndexFile.self, from: data)
        XCTAssertGreaterThan(index.rebuiltFromCommitSeq, 0)

        let reloaded = try makeCenter(clock)
        let preferences = try await reloaded.preferences(botID: "bot-1", scope: nil)
        XCTAssertEqual(preferences.active.count, 1)
        let index2Data = try XCTUnwrap(defaults.data(forKey: BotFeedbackIndexFile.defaultsKey))
        let index2 = try JSONDecoder().decode(BotFeedbackIndexFile.self, from: index2Data)
        XCTAssertEqual(index2.rebuiltFromCommitSeq, index.rebuiltFromCommitSeq,
                       "a clean reload must not duplicate or rewrite the cursor")
    }

    func testIndexCapsActiveRecordsAtContractLimit() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let store = InMemoryBotFeedbackStore()
        let center = BotFeedbackCenter(store: store, eventLog: nil, memory: nil,
                                       now: { clock.now })
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await center.noteConsidered(decision, candidate: candidate)
        // One suppress per distinct class is enough to exercise the cap logic
        // without inventing 512 different artifacts.
        _ = try await center.record(
            FeedbackFixtures.suppress(decision, scope: .user, nonce: "cap"))
        let currentIndex = await store.currentIndex()
        let index = try XCTUnwrap(currentIndex)
        XCTAssertLessThanOrEqual(index.records.filter { $0.status == .active }.count,
                                 BotFeedbackIndexLimits.maximumActive)
    }
}

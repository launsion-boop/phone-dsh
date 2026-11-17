// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFeedbackProactiveTests: XCTestCase {
    private func makeCenter(_ clock: WP6Clock,
                            store: InMemoryBotFeedbackStore = InMemoryBotFeedbackStore(),
                            eventLog: (any BotEventLog)? = nil) -> BotFeedbackCenter {
        BotFeedbackCenter(store: store, eventLog: eventLog, memory: nil,
                          now: { clock.now })
    }

    func testHeldCandidateDoesNotConsumeTheFrequencyFuse() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(
            settings: { wp6Settings() }, now: { clock.now },
            policy: ProactivePolicyConfiguration(fuseWindowMs: 900_000, fuseMaxWakeups: 1),
            deliverer: deliverer, feedback: center)

        let first = await engine.consider(FeedbackFixtures.candidate("first"))
        XCTAssertEqual(first.decision, .did)
        let suppression = try await center.record(
            FeedbackFixtures.suppress(first, scope: .user, nonce: "stop-task-done"))
        XCTAssertEqual(suppression.status, .accepted)

        // A held candidate is not a disturbance: it must not spend the fuse.
        let held = await engine.consider(FeedbackFixtures.candidate("held-candidate"))
        XCTAssertEqual(held.reason, "feedback-held")
        let fused = await engine.consider(
            FeedbackFixtures.candidate("third", kind: .routineResult, routineId: "r-third"))
        XCTAssertEqual(fused.reason, "fuse")
    }

    func testHeldEventCarriesNoFuseAndKeepsNotification() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let spy = FeedbackSpyEventLog()
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let engine = ProactiveEngine(settings: { wp6Settings() }, now: { clock.now },
                                     deliverer: deliverer, eventLog: spy, feedback: center)
        let first = await engine.consider(FeedbackFixtures.candidate("task-1"))
        XCTAssertEqual(first.decision, .did)
        _ = try await center.record(
            FeedbackFixtures.suppress(first, scope: .user, nonce: "held-event"))
        let held = await engine.consider(FeedbackFixtures.candidate("task-2"))
        XCTAssertEqual(held.decision, .skip)
        XCTAssertEqual(held.reason, "feedback-held")
        XCTAssertNotNil(held.notification, "G-2 r4 keeps the notification shape")
        XCTAssertNil(held.delivery)
        let events = await spy.all
        guard let event = events.last, case .object(let data) = event.data else {
            return XCTFail("missing proactive.considered event")
        }
        XCTAssertEqual(data["reason"] ?? .null, .string("feedback-held"))
        XCTAssertEqual(data["fuseRecorded"] ?? .null, .bool(false))
        XCTAssertEqual(data["decision"] ?? .null, .string("skip"))
        XCTAssertNotNil(data["feedback_id"])
    }

    func testOffModeStaysModeOffEvenWhenPreferenceExists() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let center = makeCenter(clock)
        let engine = ProactiveEngine(settings: { wp6Settings(mode: .on) }, now: { clock.now },
                                     deliverer: deliverer, feedback: center)
        let candidate = FeedbackFixtures.candidate("task-1")
        let delivered = await engine.consider(candidate)
        _ = try await center.record(
            FeedbackFixtures.suppress(delivered, scope: .artifact, nonce: "stop-it"))

        let offEngine = ProactiveEngine(settings: { wp6Settings(mode: .off) },
                                        now: { clock.now }, deliverer: deliverer,
                                        feedback: center)
        let decision = await offEngine.consider(FeedbackFixtures.candidate("task-2"))
        XCTAssertEqual(decision.reason, "mode-off")
    }

    func testWouldModeRecordsNoWouldWhenHeld() async throws {
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let deliverer = WP6NotificationDeliverer()
        let store = InMemoryBotFeedbackStore()
        let center = makeCenter(clock, store: store)
        let onEngine = ProactiveEngine(settings: { wp6Settings() }, now: { clock.now },
                                       deliverer: deliverer, feedback: center)
        let delivered = await onEngine.consider(FeedbackFixtures.candidate("task-1"))
        _ = try await center.record(
            FeedbackFixtures.suppress(delivered, scope: .user, nonce: "stop-it"))

        let wouldEngine = ProactiveEngine(settings: { wp6Settings(mode: .would) },
                                          now: { clock.now }, deliverer: nil,
                                          feedback: center)
        let decision = await wouldEngine.consider(FeedbackFixtures.candidate("task-2"))
        XCTAssertEqual(decision.reason, "feedback-held")
        XCTAssertEqual(decision.decision, .skip)
    }

    func testPreferenceSurvivesCenterRestart() async throws {
        let suiteName = "feedback-restart-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let firstCenter = try BotFeedbackCenter.live(eventLog: nil, memory: nil,
                                                     defaults: defaults,
                                                     now: { clock.now })
        let candidate = FeedbackFixtures.candidate("task-1")
        let decision = FeedbackFixtures.deliveredDecision(candidate, at: clock.now)
        await firstCenter.noteConsidered(decision, candidate: candidate)
        let suppression = try await firstCenter.record(
            FeedbackFixtures.suppress(decision, scope: .user, nonce: "persist-1"))
        XCTAssertEqual(suppression.status, .accepted)

        let secondCenter = try BotFeedbackCenter.live(eventLog: nil, memory: nil,
                                                      defaults: defaults,
                                                      now: { clock.now })
        let preferences = try await secondCenter.preferences(botID: "bot-1", scope: nil)
        XCTAssertEqual(preferences.active.count, 1)
        let hold = await secondCenter.hold(
            for: FeedbackFixtures.candidate("task-2"), botID: "bot-1", at: clock.now)
        XCTAssertTrue(hold.isHeld)
    }
}

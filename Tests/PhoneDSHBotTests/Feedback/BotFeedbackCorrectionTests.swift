// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFeedbackCorrectionTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!
    private var memory: BotMemory!
    private let path = "user/prefs/coffee.md"
    private let session = "s-chat"

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
        memory = makeMemory(store: store, botID: "bot-1")
    }

    override func tearDown() async throws {
        try? await store?.close()
        cleanupMemoryTestStore(root)
    }

    private func context(trust: BotRecordTrust? = .user) -> BotMemoryWriteContext {
        BotMemoryWriteContext(
            botID: "bot-1", sessionID: session, authorKind: .chat,
            source: BotMemorySource(kind: .userTurn, sessionID: session),
            trust: trust)
    }

    @discardableResult
    private func write(_ content: String, expected: Int) async throws -> BotMemoryWriteResult {
        try await memory.write(
            BotMemoryWriteRequest(action: .write, path: path, content: content,
                                  expectedVersion: expected),
            context: context())
    }

    private func makeCenter(_ clock: WP6Clock,
                            eventLog: (any BotEventLog)? = nil) -> BotFeedbackCenter {
        let reader: any BotFeedbackMemoryReading = memory
        return BotFeedbackCenter(store: InMemoryBotFeedbackStore(), eventLog: eventLog,
                                 memory: { _ in reader }, now: { clock.now })
    }

    func testCorrectionVerifiesAppliedVersionAndPublishesDisputedRefs() async throws {
        let written = try await write("decaf; no sugar", expected: 0)
        XCTAssertTrue(written.ok)
        XCTAssertEqual(written.version, 1)
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = makeCenter(clock, eventLog: store)

        let outcome = try await center.record(
            FeedbackFixtures.correct(path: path, version: 1,
                                     refs: ["record://session/s-chat#7"],
                                     nonce: "correct-1"))
        XCTAssertEqual(outcome.status, .accepted)
        XCTAssertEqual(outcome.code, nil)
        XCTAssertEqual(outcome.appliedMemory?.path, path)
        XCTAssertEqual(outcome.appliedMemory?.version, 1)
        XCTAssertEqual(outcome.appliedMemory?.previousVersion, 0)

        let disputed = try await center.disputedRefs(paths: [path])
        let views = try XCTUnwrap(disputed[path])
        XCTAssertEqual(views.count, 1)
        guard let view = views.first else { return XCTFail("no disputed view") }
        XCTAssertEqual(view.state, "active")
        XCTAssertEqual(view.correctedVersion, 1)
        XCTAssertEqual(view.refs, ["record://session/s-chat#7"])

        let events = try await store.events(after: 0, limit: 100)
        let feedback = events.filter { $0.type == BotFeedbackCenter.feedbackEventType }
        guard let feedbackEvent = feedback.first else {
            return XCTFail("missing feedback.recorded event")
        }
        XCTAssertEqual(feedback.count, 1)
        XCTAssertEqual(feedbackEvent.ignorable, true)
        XCTAssertEqual(feedbackEvent.principal.botId, "bot-1")
        XCTAssertEqual(feedbackEvent.origin, .local(source: "card-bridge"))
        let reviews = events.filter { $0.type == "memory.review_requested" }
        guard let review = reviews.first else {
            return XCTFail("missing memory.review_requested event")
        }
        XCTAssertEqual(reviews.count, 1)
        guard case .object(let data) = review.data else {
            return XCTFail("review data must be an object")
        }
        XCTAssertEqual(data["path"] ?? .null, .string(path))
        XCTAssertEqual(data["version"] ?? .null, .number(1))
        XCTAssertEqual(data["evidence"] ?? .null,
                       .array([.string("record://session/s-chat#7")]))
    }

    func testCorrectionRejectsVersionThatWasNotApplied() async throws {
        try await write("decaf", expected: 0)
        try await write("espresso", expected: 1)
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = makeCenter(clock, eventLog: store)

        let stale = try await center.record(
            FeedbackFixtures.correct(path: path, version: 1, nonce: "correct-stale"))
        XCTAssertEqual(stale.status, .rejected)
        XCTAssertEqual(stale.code, "correction-not-applied")
        let disputed = try await center.disputedRefs(paths: [path])
        XCTAssertEqual(disputed[path]?.count ?? 0, 0)

        let current = try await center.record(
            FeedbackFixtures.correct(path: path, version: 2,
                                     refs: ["record://event/7"], nonce: "correct-current"))
        XCTAssertEqual(current.status, .accepted)
        XCTAssertEqual(current.appliedMemory?.previousVersion, 1)
    }

    func testCorrectionNeedsMemoryPort() async throws {
        try await write("decaf", expected: 0)
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = BotFeedbackCenter(store: InMemoryBotFeedbackStore(),
                                       eventLog: store, memory: nil,
                                       now: { clock.now })
        let outcome = try await center.record(
            FeedbackFixtures.correct(path: path, version: 1, nonce: "correct-noport"))
        XCTAssertEqual(outcome.code, "insufficient-evidence")
    }

    func testCorrectionRejectsMalformedRefs() async throws {
        try await write("decaf", expected: 0)
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = makeCenter(clock, eventLog: store)
        let outcome = try await center.record(
            FeedbackFixtures.correct(path: path, version: 1,
                                     refs: ["not-a-record-reference"], nonce: "correct-bad"))
        XCTAssertEqual(outcome.code, "insufficient-evidence")
    }

    func testCorrectionUsesDocumentEvidenceWhenCallerSuppliesNone() async throws {
        let writeContext = context()
        _ = try await memory.write(
            BotMemoryWriteRequest(action: .write, path: path, content: "decaf",
                                  expectedVersion: 0,
                                  evidence: ["record://session/s-chat#9"]),
            context: writeContext)
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = makeCenter(clock, eventLog: store)
        let outcome = try await center.record(
            FeedbackFixtures.correct(path: path, version: 1, nonce: "correct-evidence"))
        XCTAssertEqual(outcome.status, .accepted)
        let disputed = try await center.disputedRefs(paths: [path])
        XCTAssertEqual(disputed[path]?.first?.refs, ["record://session/s-chat#9"])
    }

    func testDuplicateCorrectionAndUndoRetraction() async throws {
        try await write("decaf", expected: 0)
        let clock = WP6Clock(FeedbackFixtures.baseNow)
        let center = makeCenter(clock, eventLog: store)
        let first = try await center.record(
            FeedbackFixtures.correct(path: path, version: 1, nonce: "correct-1"))
        let duplicate = try await center.record(
            FeedbackFixtures.correct(path: path, version: 1, nonce: "correct-2"))
        XCTAssertEqual(duplicate.status, .duplicated)
        XCTAssertEqual(duplicate.feedbackID, first.feedbackID)

        let undo = try await center.undo(try XCTUnwrap(first.feedbackID))
        XCTAssertEqual(undo.status, .accepted)
        XCTAssertTrue(undo.reversed)
        let disputed = try await center.disputedRefs(paths: [path])
        XCTAssertEqual(disputed[path]?.first?.state, "retracted")
        let secondUndo = try await center.undo(try XCTUnwrap(first.feedbackID))
        XCTAssertEqual(secondUndo.status, .duplicated)
    }
}

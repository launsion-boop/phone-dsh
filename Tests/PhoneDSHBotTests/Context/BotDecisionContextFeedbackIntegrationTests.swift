// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// A05 retrieval: the real F center supplies an active correction, and the
/// real BotDecisionContextService must turn that memory candidate into
/// unknown/feedback-disputed. This is not a fake status map: F's durable
/// feedback store and memory reader are the production types.
final class BotDecisionContextFeedbackIntegrationTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var memory: BotMemory!
    private let path = "user/client.md"

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
        suiteName = "feedback-r-integration-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        memory = makeMemory(store: store, botID: "main")
        try await seedDocument(makeDocument(
            path, "- 客户喜欢先看结论\n- 风险段必须写", evidence: ["record://session/gb-main#1"]),
            store: store)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        cleanupMemoryTestStore(root)
        root = nil
        store = nil
        memory = nil
    }

    private func center() throws -> BotFeedbackCenter {
        try BotFeedbackCenter.live(
            eventLog: store, memory: { [memory] _ in memory }, defaults: defaults)
    }

    private func service(_ center: BotFeedbackCenter) -> BotDecisionContextService {
        let memory = self.memory!
        return BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in "rev-1" },
            materialState: { _ in (.current, nil) },
            disputedRefs: { paths in try await center.disputedRefs(paths: paths) },
            now: { MemoryTestFixtures.now })
    }

    private func request() -> BotDecisionRequest {
        BotDecisionRequest(
            stage: .preStep, botID: "main", sessionID: "gb-main",
            turnID: "gb-main#1", query: "客户 结论 风险", scopes: [.user])
    }

    func testActiveCorrectionMarksTheCandidateDisputedAndUndoClearsIt() async throws {
        let center = try center()
        let outcome = try await center.record(BotFeedback(
            botID: "main", action: .correct,
            target: BotFeedbackArtifactRef(kind: .memory, id: path, version: 1),
            scope: .artifact,
            origin: BotFeedbackOrigin(kind: .uiAction, nonce: "ui-disputed-r"),
            disputedRefs: ["record://session/gb-main#1"]))
        XCTAssertEqual(outcome.status, .accepted)
        let feedbackID = try XCTUnwrap(outcome.feedbackID)
        let disputed = try await center.disputedRefs(paths: [path])
        XCTAssertEqual(disputed[path]?.first?.state, "active")
        XCTAssertEqual(disputed[path]?.first?.correctedVersion, 1)

        let block = try await service(center).materials(for: request())
        let material = try XCTUnwrap(block.materials.first { $0.path == path })
        XCTAssertEqual(material.state, .unknown)
        XCTAssertEqual(material.reason, .feedbackDisputed)
        XCTAssertEqual(material.version, 1)

        _ = try await center.undo(
            feedbackID, botID: "main",
            origin: BotFeedbackOrigin(kind: .uiAction, nonce: "ui-disputed-r-undo"))
        let cleared = try await center.disputedRefs(paths: [path])
        XCTAssertEqual(cleared[path]?.first?.state, "retracted")
        let after = try await service(center).materials(for: request())
        let restored = try XCTUnwrap(after.materials.first { $0.path == path })
        XCTAssertEqual(restored.state, .current)
        XCTAssertNotEqual(restored.reason, .feedbackDisputed)
    }
}

// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private final class RevisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    func get() -> String { lock.withLock { value } }
    func set(_ next: String) { lock.withLock { value = next } }
}

final class BotDecisionContextTests: XCTestCase {
    private var root: URL?
    private var store: SQLiteDomainStore!
    private var memory: BotMemory!
    private let revision = RevisionBox("rev-1")

    override func setUp() async throws {
        let made = try makeMemoryTestStore()
        root = made.root
        store = made.store
        memory = makeMemory(store: made.store)
        try await seedDocument(
            makeDocument("user/profile.md", "- 我叫小林\n- 我喜欢简洁的回复",
                         evidence: ["record://session/gb-main#3"]),
            store: made.store)
        try await seedDocument(
            makeDocument("agent/notes/routine.md", "- 工作日要早起，早起后先看邮件"),
            store: made.store)
        try await seedDocument(
            makeDocument("agent/log/2025-10.md", "- 我负责 iOS 工作\n- 咖啡因摄入要控制"),
            store: made.store)
        try await seedDocument(
            makeDocument("user/travel.md", "- 出行准备：护照、充电器、耳机"),
            store: made.store)
        try await seedDocument(
            makeDocument("user/food.md", "- 早饭喜欢吃燕麦"),
            store: made.store)
        try await seedDocument(
            makeDocument("agent/long.md", String(repeating: "咖啡因 控制 ", count: 120)),
            store: made.store)
    }

    override func tearDown() async throws {
        cleanupMemoryTestStore(root)
        root = nil
        store = nil
        memory = nil
    }

    private func service() -> BotDecisionContextService {
        let memory = self.memory!
        let revision = self.revision
        return BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in revision.get() },
            materialState: { _ in (.current, nil) },
            now: { MemoryTestFixtures.now })
    }

    private func request(
        stage: BotDecisionStage = .preStep,
        query: String = "咖啡因 早起 简洁",
        scopes: [BotMemoryScope] = [.user, .agent],
        permissionRevision: String = "",
        activeMaterialRefs: [String] = [],
        activeMaterialVersions: [String: String] = [:],
        activeTurnID: String? = nil,
        activeRecipientID: String? = nil,
        activeGoalDigest: String? = nil,
        turn: String = "gb-main#1"
    ) -> BotDecisionRequest {
        BotDecisionRequest(
            stage: stage,
            botID: "main",
            sessionID: "gb-main",
            turnID: turn,
            tool: stage == .preDelivery ? "SendToUser" : nil,
            query: query,
            scopes: scopes,
            permissionRevision: permissionRevision,
            activeMaterialRefs: activeMaterialRefs,
            activeMaterialVersions: activeMaterialVersions,
            activeTurnID: activeTurnID,
            activeRecipientID: activeRecipientID,
            activeGoalDigest: activeGoalDigest)
    }

    func testMaterialsStayBoundedAndCarryOnlyStoredProvenance() async throws {
        let result = try await service().materials(for: request())
        XCTAssertTrue(result.blockID.hasPrefix("dm:"))
        XCTAssertEqual(result.botID, "main")
        XCTAssertEqual(result.sessionID, "gb-main")
        XCTAssertEqual(result.turnID, "gb-main#1")
        XCTAssertEqual(result.stage, .preStep)
        XCTAssertEqual(result.authorizationRevision, "rev-1")
        XCTAssertTrue(result.queryDigest.hasPrefix("sha256:"))
        XCTAssertEqual(result.queryDigest.unicodeScalars.count, "sha256:".unicodeScalars.count + 64)
        XCTAssertFalse(result.canceled)
        XCTAssertFalse(result.materials.isEmpty)
        XCTAssertLessThanOrEqual(result.materials.count, 4)
        XCTAssertLessThanOrEqual(
            result.materials.reduce(0) { $0 + $1.snippet.unicodeScalars.count }, 1_600)
        for material in result.materials {
            XCTAssertTrue(material.materialID.hasPrefix("mat:"))
            XCTAssertTrue(material.ref.hasPrefix("memory:"))
            XCTAssertTrue(material.ref.hasSuffix("@v\(material.version)"))
            XCTAssertGreaterThanOrEqual(material.version, 1)
            XCTAssertFalse(material.snippet.isEmpty)
            XCTAssertLessThanOrEqual(material.snippet.unicodeScalars.count, 240)
            XCTAssertLessThanOrEqual(material.evidence.count, 2)
            XCTAssertTrue(material.evidence.allSatisfy { $0.hasPrefix("record://") })
            XCTAssertEqual(material.state, .current)
            XCTAssertNil(material.reason)
            XCTAssertTrue([BotDecisionSelectionReason.match, .recency, .goal, .recipient]
                .contains(material.selectionReason))
        }
        XCTAssertEqual(result.retrievedAtMS, MemoryTestFixtures.now)
    }

    func testScopesFilterSelection() async throws {
        let agentOnly = try await service().materials(for: request(
            query: "咖啡因 早起", scopes: [.agent]))
        XCTAssertFalse(agentOnly.materials.isEmpty)
        XCTAssertTrue(agentOnly.materials.allSatisfy { $0.scope == .agent })

        let userOnly = try await service().materials(for: request(
            query: "咖啡因 早起", scopes: [.user]))
        XCTAssertTrue(userOnly.materials.allSatisfy { $0.scope == .user })
    }

    func testEmptyQueryReturnsTypedReasonAndNoMaterial() async throws {
        let result = try await service().materials(for: request(query: "   "))
        XCTAssertTrue(result.materials.isEmpty)
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(result.canceled)
    }

    func testNoMatchReturnsTypedReason() async throws {
        let result = try await service().materials(for: request(query: "量子引力波观测"))
        XCTAssertTrue(result.materials.isEmpty)
    }

    func testSnippetFoldsControlCharactersAndHonoursSmallerLimit() async throws {
        var limited = request()
        limited.limits = BotDecisionLimits(maxMaterials: 2, maxCharacters: 800,
                                           maxSnippetCharacters: 60)
        let result = try await service().materials(for: limited)
        XCTAssertLessThanOrEqual(result.materials.count, 2)
        for material in result.materials {
            XCTAssertLessThanOrEqual(material.snippet.unicodeScalars.count, 60)
            XCTAssertFalse(material.snippet.unicodeScalars.contains { scalar in
                scalar.properties.generalCategory == .control
            })
            XCTAssertFalse(material.snippet.contains("\n"))
        }
    }

    func testInvalidRequestFailsClosed() async throws {
        let service = service()
        var empty = request()
        empty.sessionID = ""
        do {
            _ = try await service.materials(for: empty)
            XCTFail("empty session must be rejected")
        } catch let error as BotDecisionContextError {
            guard case .invalidRequest = error else { return XCTFail("unexpected \(error)") }
        }
        var long = self.request()
        long.query = String(repeating: "x", count: 601)
        do {
            _ = try await service.materials(for: long)
            XCTFail("overlong query must be rejected")
        } catch let error as BotDecisionContextError {
            guard case .invalidRequest = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testReviewProceedsWhileBundleAndPermissionAreCurrent() async throws {
        let service = service()
        let materials = try await service.materials(for: request())
        let ref = try XCTUnwrap(materials.materials.first?.ref)
        var delivery = request(stage: .preDelivery,
                               permissionRevision: materials.authorizationRevision,
                               activeMaterialRefs: [ref],
                               activeMaterialVersions: [ref: "v\(materials.materials[0].version)"])
        delivery.tool = "SendToUser"
        let proposal = BotDeliveryProposal(
            request: delivery, tool: "SendToUser", materialRefs: [ref])
        let review = try await service.review(proposal)
        XCTAssertEqual(review, .proceed)
    }

    func testReviewRegeneratesWhenPermissionRevisionChanges() async throws {
        let service = service()
        let materials = try await service.materials(for: request())
        let ref = try XCTUnwrap(materials.materials.first?.ref)
        revision.set("rev-2")
        var delivery = request(stage: .preDelivery,
                               permissionRevision: materials.authorizationRevision,
                               activeMaterialRefs: [ref])
        delivery.tool = "SendToUser"
        let review = try await service.review(BotDeliveryProposal(
            request: delivery, tool: "SendToUser"))
        guard case let .regenerate(block, reason) = review else {
            return XCTFail("expected regenerate, got \(review)")
        }
        XCTAssertEqual(reason, .authorizationRevisionChanged)
        XCTAssertEqual(block.authorizationRevision, "rev-2")
    }

    func testReviewRegeneratesWhenActiveMaterialVersionMoves() async throws {
        let service = service()
        let materials = try await service.materials(for: request())
        let first = try XCTUnwrap(materials.materials.first { $0.path == "user/profile.md" })
        try await seedDocument(
            makeDocument("user/profile.md", "- 我叫小林\n- 我现在喜欢详细的回复", version: 2),
            store: store,
            atMS: MemoryTestFixtures.now + 1_000)
        var delivery = request(stage: .preDelivery, query: "小林 详细",
                               permissionRevision: materials.authorizationRevision,
                               activeMaterialRefs: [first.ref])
        delivery.tool = "SendToUser"
        let review = try await service.review(BotDeliveryProposal(
            request: delivery, tool: "SendToUser", materialRefs: [first.ref]))
        guard case let .regenerate(block, reason) = review else {
            return XCTFail("expected regenerate, got \(review)")
        }
        XCTAssertEqual(reason, .materialChanged)
        XCTAssertTrue(block.materials.contains { $0.path == "user/profile.md" })
    }

    func testReviewRejectsStaleOrInventedRefBeforeDelivery() async throws {
        let service = service()
        let materials = try await service.materials(for: request())
        var delivery = request(stage: .preDelivery,
                               permissionRevision: materials.authorizationRevision)
        delivery.tool = "show_attachment"
        let review = try await service.review(BotDeliveryProposal(
            request: delivery, tool: "show_attachment",
            materialRefs: ["memory:user/profile.md@v99"]))
        guard case let .regenerate(block, reason) = review else {
            return XCTFail("expected regenerate, got \(review)")
        }
        XCTAssertEqual(reason, .materialChanged)
        XCTAssertEqual(block.stage, .preDelivery)
    }

    func testReviewRequiresPreDeliveryStage() async throws {
        let service = service()
        do {
            _ = try await service.review(BotDeliveryProposal(
                request: request(), tool: "SendToUser"))
            XCTFail("pre-step proposals are not deliveries")
        } catch let error as BotDecisionContextError {
            guard case .invalidRequest = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testReviewRegeneratesWhenTurnRecipientOrGoalChanges() async throws {
        let service = service()
        let materials = try await service.materials(for: request())
        let ref = try XCTUnwrap(materials.materials.first?.ref)

        var otherTurn = request(stage: .preDelivery,
                                permissionRevision: materials.authorizationRevision,
                                activeMaterialRefs: [ref],
                                activeTurnID: "gb-main#1",
                                turn: "gb-main#2")
        otherTurn.tool = "SendToUser"
        guard case let .regenerate(_, reason) = try await service.review(
            BotDeliveryProposal(request: otherTurn, tool: "SendToUser")) else {
            return XCTFail("a changed turn must regenerate")
        }
        XCTAssertEqual(reason, .turnChanged)

        var recipientChanged = request(stage: .preDelivery,
                                       permissionRevision: materials.authorizationRevision,
                                       activeMaterialRefs: [ref],
                                       activeRecipientID: "bot:other")
        recipientChanged.tool = "SendToAgent"
        recipientChanged.recipient = BotDecisionRecipient(kind: .bot, id: "target")
        guard case let .regenerate(_, recipientReason) = try await service.review(
            BotDeliveryProposal(request: recipientChanged, tool: "SendToAgent")) else {
            return XCTFail("a changed recipient must regenerate")
        }
        XCTAssertEqual(recipientReason, .recipientChanged)

        var goalChanged = request(stage: .preDelivery,
                                  permissionRevision: materials.authorizationRevision,
                                  activeMaterialRefs: [ref],
                                  activeGoalDigest: BotDecisionContextService.goalDigest("旧目标"))
        goalChanged.tool = "SendToUser"
        goalChanged.goal = "新目标"
        guard case let .regenerate(_, goalReason) = try await service.review(
            BotDeliveryProposal(request: goalChanged, tool: "SendToUser")) else {
            return XCTFail("a changed goal must regenerate")
        }
        XCTAssertEqual(goalReason, .goalChanged)
    }

    func testDecisionToolResultMatchesG2R2ShapeAndBoundsMessage() async throws {
        let materials = try await service().materials(for: request())
        let longMessage = String(repeating: "m", count: 400)
        let result = BotDecisionToolResult(
            reason: .materialChanged, materials: materials, message: longMessage)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.code, "decision_context_changed")
        XCTAssertEqual(result.reason, .materialChanged)
        XCTAssertEqual(result.message.unicodeScalars.count, 300)
        XCTAssertEqual(result.materials.blockID, materials.blockID)

        let data = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys),
                       Set(["ok", "code", "reason", "materials", "message"]))
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["code"] as? String, "decision_context_changed")
        XCTAssertEqual(object["reason"] as? String, "material-changed")
        let decoded = try JSONDecoder().decode(BotDecisionToolResult.self, from: data)
        XCTAssertEqual(decoded, result)

        var invalid = object
        invalid["ok"] = true
        let invalidData = try JSONSerialization.data(withJSONObject: invalid)
        XCTAssertThrowsError(try JSONDecoder().decode(BotDecisionToolResult.self, from: invalidData))
    }

    func testMaterialStateProviderFlowsThroughAndReceivesEvidence() async throws {
        let memory = self.memory!
        let captured = LockedEvidenceCapture()
        let service = BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in "rev-1" },
            materialState: { lookup in
                captured.record(botID: lookup.botID, sessionID: lookup.sessionID,
                                path: lookup.path, version: lookup.version,
                                evidence: lookup.evidence)
                return (.changed, .sourceChanged)
            },
            now: { MemoryTestFixtures.now })
        let block = try await service.materials(for: request(query: "简洁"))
        XCTAssertFalse(block.materials.isEmpty)
        for material in block.materials {
            XCTAssertEqual(material.state, .changed)
            XCTAssertEqual(material.reason, .sourceChanged)
            XCTAssertTrue(captured.paths.contains(material.path))
            XCTAssertEqual(captured.versions[material.path], material.version)
            XCTAssertEqual(captured.botIDs.last, "main")
            XCTAssertEqual(captured.sessionIDs.last, "gb-main")
        }
        XCTAssertTrue(captured.evidence.contains { !$0.isEmpty },
                      "the provider must receive the document's evidence refs")
    }

    func testReferenceParserRejectsTraversalAndNonPositiveVersions() {
        XCTAssertNil(BotDecisionContextService.parseRef("memory:../secret@v1"))
        XCTAssertNil(BotDecisionContextService.parseRef("memory:user/profile.md@v0"))
        XCTAssertNil(BotDecisionContextService.parseRef("memory:user/profile.md@v01"))
        XCTAssertNil(BotDecisionContextService.parseRef("record://session/gb-main#1"))
        XCTAssertEqual(BotDecisionContextService.parseRef("memory:user/profile.md@v2"),
                       BotDecisionContextService.ParsedRef(path: "user/profile.md", version: 2))
    }

    func testActiveDisputedCorrectionIsNotCurrent() async throws {
        let memory = self.memory!
        let revision = self.revision
        let service = BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in revision.get() },
            materialState: { _ in (.current, nil) },
            disputedRefs: { paths in
                guard paths.contains("user/travel.md") else { return [:] }
                return ["user/travel.md": [BotFeedbackDisputedRef(
                    path: "user/travel.md", refs: ["record://event/9"],
                    feedbackID: "feedback:main:test", correctedVersion: 1,
                    supersededVersion: 0, atMS: 1_760_000_000_000, state: "active")]]
            },
            now: { MemoryTestFixtures.now })
        let block = try await service.materials(for: request(query: "护照 出行"))
        let material = try XCTUnwrap(block.materials.first { $0.path == "user/travel.md" })
        XCTAssertEqual(material.state, .unknown)
        XCTAssertEqual(material.reason, .feedbackDisputed)
        XCTAssertEqual(material.evidence, ["record://event/9"])
    }

    func testRetractedDisputedCorrectionDoesNotOverrideCurrent() async throws {
        let memory = self.memory!
        let revision = self.revision
        let service = BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in revision.get() },
            materialState: { _ in (.current, nil) },
            disputedRefs: { _ in
                ["user/travel.md": [BotFeedbackDisputedRef(
                    path: "user/travel.md", refs: ["record://event/9"],
                    feedbackID: "feedback:main:test", correctedVersion: 1,
                    supersededVersion: 0, atMS: 1_760_000_000_000, state: "retracted")]]
            },
            now: { MemoryTestFixtures.now })
        let block = try await service.materials(for: request(query: "护照 出行"))
        let material = try XCTUnwrap(block.materials.first { $0.path == "user/travel.md" })
        XCTAssertEqual(material.state, .current)
    }

    func testActiveUserPreferenceEntersMaterialBudget() async throws {
        let memory = self.memory!
        let revision = self.revision
        let preference = BotFeedbackPreference(
            id: "feedback:main:pref-1", botID: "main", scopeKind: .user,
            scopeKey: "proactive:routine-result", classKey: "proactive:routine-result",
            createdAtMS: 1_760_000_000_000)
        let service = BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in revision.get() },
            materialState: { _ in (.current, nil) },
            preferences: { botID in
                BotFeedbackPreferences(
                    botID: botID, generatedAtMS: 1_760_000_000_001,
                    active: [preference], recentlyRevoked: [])
            },
            now: { MemoryTestFixtures.now })
        let block = try await service.materials(for: request(query: "护照 出行"))
        let material = try XCTUnwrap(block.materials.first {
            $0.ref == "feedback:preference:feedback:main:pref-1"
        })
        XCTAssertEqual(material.path, "feedback/preference/feedback:main:pref-1")
        XCTAssertEqual(material.scope, .user)
        XCTAssertEqual(material.version, 1)
        XCTAssertEqual(material.state, .current)
        XCTAssertTrue(material.evidence.isEmpty)
        XCTAssertTrue(material.snippet.contains("proactive:routine-result"))
    }

    func testAuthorizationChangeDuringMaterialStateDoesNotLabelStaleMaterial() async throws {
        let gate = MaterialStateGate()
        let memory = self.memory!
        let revision = self.revision
        let service = BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in revision.get() },
            materialState: { _ in
                await gate.pause()
                return (.current, nil)
            },
            now: { MemoryTestFixtures.now })
        let task = Task { try await service.materials(for: request()) }
        await gate.waitUntilStarted()
        revision.set("rev-2")
        await gate.release()
        let block = try await task.value
        XCTAssertTrue(block.canceled)
        XCTAssertTrue(block.materials.isEmpty)
        XCTAssertEqual(block.authorizationRevision, "rev-2")
    }
}

private actor MaterialStateGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        guard !released else { return }
        if !started {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        released = true
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() async {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class LockedEvidenceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var paths: [String] = []
    private(set) var versions: [String: Int] = [:]
    private(set) var evidence: [[String]] = []
    private(set) var botIDs: [String] = []
    private(set) var sessionIDs: [String] = []

    func record(botID: String, sessionID: String, path: String,
                version: Int, evidence: [String]) {
        lock.lock(); defer { lock.unlock() }
        paths.append(path)
        versions[path] = version
        self.evidence.append(evidence)
        botIDs.append(botID)
        sessionIDs.append(sessionID)
    }
}

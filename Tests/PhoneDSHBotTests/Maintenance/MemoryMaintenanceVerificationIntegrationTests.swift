// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private final class VerificationBatchRunner: BotMemoryMaintenanceTurnRunning, @unchecked Sendable {
    let sessionID: String
    let memory: BotMemory
    var writes: [(path: String, content: String, evidence: [String],
                 trust: BotRecordTrust, expectedVersion: Int, deleted: Bool)] = []
    var lastPrompt = ""
    var status = "completed"

    init(sessionID: String, memory: BotMemory) {
        self.sessionID = sessionID
        self.memory = memory
    }

    func ensureMaintenanceSession() async throws -> String { sessionID }

    func runMaintenanceTurn(prompt: String, batchID: String) async throws
        -> BotRemoteTurnResult {
        lastPrompt = prompt
        for write in writes {
            _ = try await memory.write(
                BotMemoryWriteRequest(
                    action: write.deleted ? .delete : .write,
                    path: write.path, content: write.content,
                    expectedVersion: write.expectedVersion,
                    evidence: write.evidence),
                context: BotMemoryWriteContext(
                    botID: "main", sessionID: sessionID,
                    authorKind: .maintainer,
                    source: BotMemorySource(kind: .maintenance, sessionID: sessionID),
                    trust: write.trust, isMainBot: true, batchID: batchID))
        }
        return BotRemoteTurnResult(
            sessionId: sessionID, turnId: nil, status: status, text: "")
    }

    func cancelMaintenanceTurn() async {}
    func mainTurnIsBusy() async -> Bool { false }
}

private struct VerificationRecordReader: BotMemoryMaintenanceRecordReading {
    var trust: BotRecordTrust = .user
    var texts: [String: String] = [:]

    func resolveEvidence(_ references: [String], callerBotID: String,
                         callerSessionID: String) async throws -> BotRecordEvidence {
        for reference in references where texts[reference] == nil {
            throw BotRecordServiceError.unknownRecord
        }
        return BotRecordEvidence(trust: trust, refs: references)
    }

    func recordText(_ reference: String, callerSessionID: String) async throws -> String {
        guard let text = texts[reference] else {
            throw BotRecordServiceError.unknownRecord
        }
        return text
    }
}

private struct AlwaysCurrentSource: BotMaintenanceSourceChecking {
    func probe(references: [String], callerBotID: String,
               callerSessionID: String) async throws -> [BotMaintenanceSourceProbe] {
        references.map {
            BotMaintenanceSourceProbe(
                reference: $0, current: .current, trust: .user,
                recordType: "message", text: "用户：我每天八点起床，不要七点叫醒我。")
        }
    }
}

private final class StubBatchVerifier: BotMemoryMaintenanceVerifying, @unchecked Sendable {
    var state: BotMaintenanceFindingState = .verified
    var reasons: [BotMaintenanceFindingReason] = []
    var calls = 0

    func verify(_ request: BotMaintenanceVerificationRequest) async throws
        -> BotMaintenanceVerificationSummary {
        calls += 1
        let findings = request.documents.map { document in
            BotMaintenanceDocumentVerification(
                path: document.path,
                documentVersion: document.version,
                state: state,
                reasons: reasons,
                references: document.evidence,
                newerReferences: [],
                preferredReference: nil,
                claims: [],
                checkedAtMS: request.checkedAtMS,
                persistedReviewState: document.review?.state.rawValue,
                blocking: request.strictPaths.contains(document.path)
                    && state != .verified)
        }
        return BotMaintenanceVerificationSummary(findings: findings)
    }
}

final class MemoryMaintenanceVerificationIntegrationTests: XCTestCase {
    private let maintainerSession = "gb-maintainer-0123456789abcdef0123456789abcdef"
    private let evidence = "record://session/gb-main#3"

    private func settings() -> (BotMemoryMaintenanceSettingsStore, String) {
        let suite = "maintenance-verification-\(UUID().uuidString)"
        return (BotMemoryMaintenanceSettingsStore(
            defaults: UserDefaults(suiteName: suite)!), suite)
    }

    private func document(_ path: String, _ content: String,
                          evidence: [String] = []) -> BotMemoryDocument {
        BotMemoryDocument(
            path: path, scope: path.hasPrefix("user/") ? .user : .agent,
            content: content, version: 1, updatedAtMS: 1_000,
            author: BotMemoryAuthor(botID: "main", kind: .chat),
            evidence: evidence)
    }

    private func makeCase(verification: (any BotMemoryMaintenanceVerifying)?)
        async throws -> (BotMCPTestFixture, BotMemory, BotMemoryMaintenanceController,
                         VerificationBatchRunner, BotMemoryMaintenanceSettingsStore,
                         String) {
        let fixture = try makeBotMCPFixture()
        let memory = await fixture.runtime.memory(for: "main")
        _ = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/wake.md",
                content: "用户每天七点起床。", expectedVersion: 0),
            context: BotMemoryWriteContext(
                botID: "main", sessionID: "gb-main", authorKind: .chat,
                source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
                trust: .user, isMainBot: true))
        let runner = VerificationBatchRunner(
            sessionID: maintainerSession, memory: memory)
        runner.writes = [(
            path: "agent/wake.md", content: "用户每天八点起床。",
            evidence: [evidence], trust: .user,
            expectedVersion: 1, deleted: false)]
        let (settingsStore, suite) = settings()
        let controller = BotMemoryMaintenanceController(
            store: fixture.store, botID: "main", memory: memory,
            runtime: fixture.runtime, remote: runner,
            settingsStore: settingsStore,
            recordReading: VerificationRecordReader(
                trust: .user, texts: [evidence: "用户：我每天八点起床，不要七点叫醒我。"]),
            verification: verification,
            isMainBot: { true }, isAppActive: { true },
            now: { 1_760_000_000_000 })
        await controller.setEnabled(true)
        return (fixture, memory, controller, runner, settingsStore, suite)
    }

    func testMissingFeedbackAndInvalidationReadersFailClosed() async throws {
        let realVerifier = BotMaintenanceEvidenceVerifier(source: AlwaysCurrentSource())
        let (fixture, _, controller, _, _, suite) = try await makeCase(
            verification: realVerifier)
        defer { fixture.cleanup() }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let result = await controller.runNow(trigger: .manual)
        let view = try XCTUnwrap(result)
        XCTAssertEqual(view.batch.status, .rolledBack)
        XCTAssertEqual(view.batch.failureCode,
                       "maintenance-verification-unrechecked")
        XCTAssertEqual(view.batch.checks.verificationRechecked, false)
    }

    func testHostRecheckIsRecordedOnACommittedBatch() async throws {
        let verifier = StubBatchVerifier()
        let (fixture, _, controller, runner, _, suite) = try await makeCase(
            verification: verifier)
        defer { fixture.cleanup() }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let result = await controller.runNow(trigger: .manual)
        let view = try XCTUnwrap(result)
        XCTAssertEqual(view.batch.status, .committed)
        XCTAssertEqual(view.batch.checks.verificationRechecked, true)
        XCTAssertEqual(view.batch.failureCode, nil)
        let verification = try XCTUnwrap(view.batch.verification)
        XCTAssertGreaterThanOrEqual(verification.checked, 1)
        XCTAssertGreaterThanOrEqual(verification.verified, 1)
        XCTAssertEqual(verification.blocking, 0)
        XCTAssertTrue(verification.findings.contains {
            $0.path == "agent/wake.md" && $0.state == .verified
        })
        XCTAssertGreaterThanOrEqual(verifier.calls, 2, "candidate and changed doc")
        XCTAssertTrue(runner.lastPrompt.contains("宿主回读核验材料"),
                      "the objective findings are material in the turn")
    }

    func testBlockingHostRecheckRollsTheBatchBack() async throws {
        let verifier = StubBatchVerifier()
        verifier.state = .stale
        verifier.reasons = [.sourceVersionChanged]
        let (fixture, memory, controller, _, _, suite) = try await makeCase(
            verification: verifier)
        defer { fixture.cleanup() }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let result = await controller.runNow(trigger: .manual)
        let view = try XCTUnwrap(result)
        XCTAssertEqual(view.batch.status, .rolledBack)
        XCTAssertEqual(view.batch.failureCode,
                       "maintenance-verification-unrechecked")
        XCTAssertEqual(view.batch.checks.verificationRechecked, false)
        XCTAssertEqual(view.batch.verification?.blocking, 1)
        let documents = try await memory.documents(scope: .agent)
        let document = try XCTUnwrap(
            documents.first { $0.path == "agent/wake.md" })
        XCTAssertEqual(document.content, "用户每天七点起床。",
                       "the failed batch is rolled back, not partially kept")
    }

    func testConflictNotPreservedMapsToItsOwnFailureCode() async throws {
        let verifier = StubBatchVerifier()
        verifier.state = .disputed
        verifier.reasons = [.conflictNotPreserved]
        let (fixture, _, controller, _, _, suite) = try await makeCase(
            verification: verifier)
        defer { fixture.cleanup() }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let result = await controller.runNow(trigger: .manual)
        let view = try XCTUnwrap(result)
        XCTAssertEqual(view.batch.status, .rolledBack)
        XCTAssertEqual(view.batch.failureCode,
                       "maintenance-conflict-not-preserved")
    }

    func testUserScopeEvidenceMapsToItsOwnFailureCode() async throws {
        let verifier = StubBatchVerifier()
        verifier.state = .unverifiable
        verifier.reasons = [.userScopeWithoutUserEvidence]
        let (fixture, _, controller, _, _, suite) = try await makeCase(
            verification: verifier)
        defer { fixture.cleanup() }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let result = await controller.runNow(trigger: .manual)
        let view = try XCTUnwrap(result)
        XCTAssertEqual(view.batch.status, .rolledBack)
        XCTAssertEqual(view.batch.failureCode,
                       "maintenance-user-scope-evidence")
    }

    func testLegacyReaderWithoutVerificationKeepsTheOldShape() async throws {
        let (fixture, memory, _, runner, settingsStore, suite) = try await makeCase(
            verification: nil)
        defer { fixture.cleanup() }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        // Rebuild a controller whose reader only implements the legacy
        // record-reading protocol: no verifier can be derived, so the batch
        // keeps the old shape instead of fabricating verification.
        let controller = BotMemoryMaintenanceController(
            store: fixture.store, botID: "main", memory: memory,
            runtime: fixture.runtime, remote: runner,
            settingsStore: settingsStore,
            recordReading: VerificationRecordReader(
                trust: .user, texts: [evidence: "用户：我每天八点起床，不要七点叫醒我。"]),
            isMainBot: { true }, isAppActive: { true },
            now: { 1_760_000_000_000 })
        await controller.setEnabled(true)
        let result = await controller.runNow(trigger: .manual)
        let view = try XCTUnwrap(result)
        XCTAssertEqual(view.batch.status, .committed)
        XCTAssertNil(view.batch.checks.verificationRechecked)
        XCTAssertNil(view.batch.verification)
    }
}

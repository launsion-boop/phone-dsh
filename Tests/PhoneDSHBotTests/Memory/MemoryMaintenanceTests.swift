// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import XCTest
@testable import PhoneDSHBot

private final class FakeMaintenanceRunner: BotMemoryMaintenanceTurnRunning, @unchecked Sendable {
    struct Write {
        var path: String
        var content: String
        var evidence: [String]
        var trust: BotRecordTrust
        var expectedVersion: Int
        var deleted = false
    }

    let sessionID: String
    let memory: BotMemory
    var writes: [Write] = []
    var status = "completed"
    var lastPrompt = ""
    var cancelCount = 0

    init(sessionID: String, memory: BotMemory) {
        self.sessionID = sessionID
        self.memory = memory
    }

    func ensureMaintenanceSession() async throws -> String { sessionID }

    func runMaintenanceTurn(prompt: String, batchID: String) async throws -> BotRemoteTurnResult {
        lastPrompt = prompt
        for write in writes {
            _ = try await memory.write(
                BotMemoryWriteRequest(
                    action: write.deleted ? .delete : .write,
                    path: write.path, content: write.content,
                    expectedVersion: write.expectedVersion, evidence: write.evidence),
                context: BotMemoryWriteContext(
                    botID: "main", sessionID: sessionID,
                    authorKind: .maintainer,
                    source: BotMemorySource(kind: .maintenance, sessionID: sessionID),
                    trust: write.trust, isMainBot: true, batchID: batchID))
        }
        return BotRemoteTurnResult(
            sessionId: sessionID, turnId: nil, status: status, text: "")
    }

    func cancelMaintenanceTurn() async { cancelCount += 1 }
    func mainTurnIsBusy() async -> Bool { false }
}

private struct FakeMaintenanceReader: BotMemoryMaintenanceRecordReading {
    var trust: BotRecordTrust = .user
    var texts: [String: String] = [:]
    var failReferences = false

    func resolveEvidence(_ references: [String], callerBotID: String,
                         callerSessionID: String) async throws -> BotRecordEvidence {
        if failReferences { throw BotRecordServiceError.unknownRecord }
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

final class MemoryMaintenanceTests: XCTestCase {
    private let maintainerSession = "gb-maintainer-0123456789abcdef0123456789abcdef"
    private let evidence = "record://session/gb-main#3"

    private func makeSettings() -> (BotMemoryMaintenanceSettingsStore, String) {
        let suite = "memory-maintenance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (BotMemoryMaintenanceSettingsStore(defaults: defaults), suite)
    }

    private func makeController(
        fixture: BotMCPTestFixture,
        memory: BotMemory,
        runner: FakeMaintenanceRunner,
        reader: FakeMaintenanceReader,
        settings: BotMemoryMaintenanceSettingsStore,
        notifications: @escaping @Sendable (String) async -> Void = { _ in }
    ) -> BotMemoryMaintenanceController {
        BotMemoryMaintenanceController(
            store: fixture.store, botID: "main", memory: memory,
            runtime: fixture.runtime, remote: runner,
            settingsStore: settings, recordReading: reader,
            isMainBot: { true }, isAppActive: { true },
            notify: notifications,
            now: { 1_760_000_000_000 })
    }

    func testGoldenBatchAndRollbackEncodeAgainstTheFrozenSchema() throws {
        let data = try MemoryTestFixtures.data("memory-maintenance")
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let valid = fixture["valid"] as! [String: Any]
        let start = try botDecode(
            BotMemoryMaintenanceStart.self, valid["start"] as! [String: Any])
        XCTAssertEqual(start.batchID, "mm-0123456789abcdef0123456789abcdef")
        XCTAssertEqual(start.candidates.count, 4)

        let committed = try botDecode(
            BotMemoryMaintenanceBatch.self, valid["committed"] as! [String: Any])
        XCTAssertEqual(committed.status, .committed)
        XCTAssertEqual(committed.changes.count, 2)
        XCTAssertTrue(committed.checks.passedAll)

        let rolled = try botDecode(
            BotMemoryMaintenanceBatch.self, valid["rolledBack"] as! [String: Any])
        XCTAssertEqual(rolled.status, .rolledBack)
        XCTAssertEqual(rolled.failureCode, "maintenance-document-longer-than-evidence")

        let rollback = try botDecode(
            BotMemoryMaintenanceRollback.self, valid["rollback"] as! [String: Any])
        XCTAssertEqual(rollback.restored.first?.path, "agent/profile.md")

        let startObject = try botJSONObject(start) as! [String: Any]
        XCTAssertEqual(startObject["batch_id"] as? String, start.batchID)
        XCTAssertNil(startObject["status"])
    }

    func testChangesCollapseOnePathIntoBeforeAndAfterVersions() throws {
        let events = [
            makeMemoryEvent(type: "memory.document_written", path: "agent/a.md",
                            expected: 0, version: 1, scope: "agent"),
            makeMemoryEvent(type: "memory.document_written", path: "agent/a.md",
                            expected: 1, version: 2, scope: "agent"),
            makeMemoryEvent(type: "memory.document_deleted", path: "agent/b.md",
                            expected: 3, version: 4, scope: "agent"),
        ]
        let changes = BotMemoryMaintenanceController.changes(in: events)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].path, "agent/a.md")
        XCTAssertEqual(changes[0].beforeVersion, 0)
        XCTAssertEqual(changes[0].afterVersion, 2)
        XCTAssertEqual(changes[1].afterVersion, 4)
        XCTAssertTrue(changes[1].deleted)
    }

    func testReadableRecordTextPrefersMessageContent() throws {
        let raw = #"{"data":{"content":[{"type":"text","text":"早上八点起床"}]}}"#
        XCTAssertEqual(BotMemoryMaintenanceText.readableText(raw: raw), "早上八点起床")
        let nested = #"{"data":{"message":{"content":[{"type":"text","text":"abc"},{"type":"reasoning","text":"x"}]}}}"#
        XCTAssertEqual(BotMemoryMaintenanceText.readableText(raw: nested), "abc")
        XCTAssertEqual(BotMemoryMaintenanceText.readableText(raw: "not json"), "not json")
    }

    func testDisabledByDefaultAndCommittedBatchIsVisibleAndRollbackable() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let memory = await fixture.runtime.memory(for: "main")
        try await seedDocument(
            makeDocument("agent/notes/state.md", "旧内容", version: 1),
            store: fixture.store)
        try await seedDocument(
            makeDocument("user/profile.md", "旧偏好：回答可以长一点。", version: 1),
            store: fixture.store)
        try await seedDocument(
            makeDocument("agent/notes/obsolete.md", "要删掉的旧知识", version: 1),
            store: fixture.store)
        let runner = FakeMaintenanceRunner(sessionID: maintainerSession, memory: memory)
        runner.writes = [
            .init(path: "agent/notes/state.md", content: "用户每天早上八点起床。",
                  evidence: [evidence], trust: .user, expectedVersion: 1),
            .init(path: "agent/INDEX.md", content: "# Index\n- agent/notes/state.md",
                  evidence: [], trust: .assistant, expectedVersion: 1),
            .init(path: "user/profile.md", content: "用户偏好简短回答。",
                  evidence: [evidence], trust: .user, expectedVersion: 1),
            .init(path: "agent/notes/obsolete.md", content: "",
                  evidence: [], trust: .assistant, expectedVersion: 1, deleted: true),
        ]
        let reader = FakeMaintenanceReader(
            trust: .user, texts: [evidence: "用户：我每天早上八点起床，不要七点叫醒我。"])
        let notified = LockedNotifications()
        let controller = makeController(
            fixture: fixture, memory: memory, runner: runner, reader: reader,
            settings: settings, notifications: { await notified.append($0) })

        let disabled = await controller.runNow(trigger: .manual)
        XCTAssertNil(disabled)
        XCTAssertEqual(settings.settings().enabled, false)

        await controller.setEnabled(true)
        let batch = await controller.runNow(trigger: .manual)
        let committed = try XCTUnwrap(batch)
        XCTAssertEqual(committed.batch.status, .committed)
        XCTAssertEqual(committed.batch.changes.count, 4)
        XCTAssertTrue(committed.batch.checks.passedAll)
        XCTAssertTrue(committed.canRollback)
        XCTAssertEqual(runner.lastPrompt.contains("终态"), true)

        let documents = try await memory.documents(scope: .agent)
        let stored = try XCTUnwrap(documents.first { $0.path == "agent/notes/state.md" })
        XCTAssertEqual(stored.content, "用户每天早上八点起床。")
        XCTAssertEqual(stored.author.kind, .maintainer)
        XCTAssertEqual(stored.source?.kind, .maintenance)

        let events = try await fixture.store.events(after: 0, limit: 1_000)
        XCTAssertTrue(events.contains { $0.type == "memory.maintenance_started" })
        XCTAssertTrue(events.contains { $0.type == "memory.maintenance_finished" })
        XCTAssertEqual(events.filter {
            $0.type == "memory.document_written" || $0.type == "memory.document_deleted"
        }.filter { $0.correlationId != nil }.count, 4)

        try await controller.rollback(batchID: committed.batch.batchID)
        let rolled = try await memory.documents(scope: .agent)
        let restored = try XCTUnwrap(rolled.first { $0.path == "agent/notes/state.md" })
        XCTAssertEqual(restored.content, "旧内容")
        let userRolled = try await memory.documents(scope: .user)
        let restoredProfile = try XCTUnwrap(userRolled.first { $0.path == "user/profile.md" })
        XCTAssertEqual(restoredProfile.content, "旧偏好：回答可以长一点。")
        XCTAssertEqual(restoredProfile.version, 3)
        let restoredObsolete = try await memory.documents(scope: .agent)
            .first { $0.path == "agent/notes/obsolete.md" }
        XCTAssertEqual(restoredObsolete?.content, "要删掉的旧知识")
        XCTAssertEqual(restoredObsolete?.version, 3)
        let after = try await fixture.store.events(after: 0, limit: 1_000)
        XCTAssertTrue(after.contains { $0.type == "memory.maintenance_rolled_back" })
        let last = try await controller.lastBatch()
        XCTAssertEqual(last?.isRolledBack, true)
        XCTAssertEqual(last?.canRollback, false)
        let lines = await notified.values
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("记忆整理"))
    }

    func testRollbackAfterErasureSkipsMissingPayloadAndReportsConflict() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await settings.save(BotMemoryMaintenanceSettings(enabled: true))
        let memory = await fixture.runtime.memory(for: "main")
        let path = "agent/notes/erased-before-rollback.md"
        try await seedDocument(
            makeDocument(path, "抹除前的原始内容", version: 1),
            store: fixture.store)
        let runner = FakeMaintenanceRunner(sessionID: maintainerSession, memory: memory)
        runner.writes = [.init(
            path: path, content: "整理后的内容",
            evidence: [], trust: .assistant, expectedVersion: 1)]
        let controller = makeController(
            fixture: fixture, memory: memory, runner: runner,
            reader: FakeMaintenanceReader(), settings: settings)
        let batchValue = await controller.runNow(trigger: .manual)
        let batch = try XCTUnwrap(batchValue)
        XCTAssertEqual(batch.batch.status, .committed)

        // S6 physically removes every version and the batch's own write
        // payloads. The batch event itself survives without content.
        let erased = try await memory.erase(path: path)
        XCTAssertTrue(erased.ok, erased.error ?? "")

        let rollbackValue = try await controller.rollback(batchID: batch.batch.batchID)
        let rollback = try XCTUnwrap(rollbackValue)
        XCTAssertTrue(rollback.restored.isEmpty)
        XCTAssertEqual(rollback.conflicts, [path])

        // The missing before-version is skipped, never resurrected, and a
        // later read/replay still sees no document.
        if case .failure = try await memory.read(path: path) {
        } else {
            XCTFail("erased document must not be recreated by rollback")
        }
        let versions = try await memory.versions(path: path)
        XCTAssertTrue(versions.isEmpty)
        let last = try await controller.lastBatch()
        XCTAssertEqual(last?.isRolledBack, true)
        XCTAssertEqual(last?.canRollback, false)
        try await fixture.store.verifyIntegrity()

        // No event payload may regain the original text or the batch text.
        let events = try await fixture.store.events(after: 0, limit: 1_000)
        let encoder = JSONEncoder()
        for event in events where !event.isErasedPayload {
            guard let payload = try? encoder.encode(event.data),
                  let text = String(data: payload, encoding: .utf8) else { continue }
            XCTAssertFalse(text.contains("抹除前的原始内容"), event.eventId)
            XCTAssertFalse(text.contains("整理后的内容"), event.eventId)
        }
    }

    func testMaintenanceEventsUseTheSameHeaderPayloadStorageAsEveryEvent() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await settings.save(BotMemoryMaintenanceSettings(enabled: true))
        let memory = await fixture.runtime.memory(for: "main")
        try await seedDocument(
            makeDocument("agent/notes/split.md", "拆分前的原文", version: 1),
            store: fixture.store)
        let runner = FakeMaintenanceRunner(sessionID: maintainerSession, memory: memory)
        runner.writes = [.init(
            path: "agent/notes/split.md", content: "拆分后的整理内容",
            evidence: [], trust: .assistant, expectedVersion: 1)]
        let controller = makeController(
            fixture: fixture, memory: memory, runner: runner,
            reader: FakeMaintenanceReader(), settings: settings)
        let value = await controller.runNow(trigger: .manual)
        let batch = try XCTUnwrap(value)
        XCTAssertEqual(batch.batch.status, .committed)

        let events = try await fixture.store.events(after: 0, limit: 1_000)
        let maintenance = events.filter { $0.type.hasPrefix("memory.maintenance_") }
        XCTAssertEqual(
            maintenance.map(\.type).sorted(),
            ["memory.maintenance_finished", "memory.maintenance_started"])
        for event in maintenance {
            XCTAssertFalse(event.isErasedPayload)
            XCTAssertEqual(event.data["batch_id"]?.stringValue, batch.batch.batchID)
        }

        // P25 v3 stores every event as a header row plus a payload row. The S3
        // maintenance events must take that same path, not a second table.
        let file = fixture.store.fileURL
        XCTAssertEqual(try databaseScalar(
            """
            SELECT COUNT(*) FROM bot_event_payloads AS p
            JOIN bot_event_headers AS h ON h.commit_seq = p.commit_seq
            WHERE h.event_type LIKE 'memory.maintenance_%' AND p.payload IS NOT NULL
            """, file: file), "2")
        let payloadBytes = try XCTUnwrap(Int(try databaseScalar(
            """
            SELECT COALESCE(SUM(h.payload_size), 0) FROM bot_event_payloads AS p
            JOIN bot_event_headers AS h ON h.commit_seq = p.commit_seq
            WHERE h.event_type LIKE 'memory.maintenance_%' AND p.payload IS NOT NULL
            """, file: file) ?? "0"))
        XCTAssertGreaterThan(payloadBytes, 0)
    }

    func testFailedMechanicalCheckRollsTheWholeBatchBack() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await settings.save(BotMemoryMaintenanceSettings(enabled: true))
        let memory = await fixture.runtime.memory(for: "main")
        try await seedDocument(
            makeDocument("agent/notes/state.md", "旧内容", version: 1),
            store: fixture.store)
        // A pending contradiction on the path must stay pending when the
        // batch fails: the rollback means nothing was actually processed.
        _ = try await fixture.store.append(BotEvent(
            type: "memory.review_requested", eventId: "memory.review_requested:test",
            commitSeq: nil, time: 1_759_999_999_000,
            origin: .local(source: "memory-service"), traceId: "test",
            principal: BotPrincipal(botId: "main", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: nil,
            data: .object([
                "path": .string("agent/notes/state.md"),
                "scope": .string("agent"),
                "version": .number(1),
            ])))
        let runner = FakeMaintenanceRunner(sessionID: maintainerSession, memory: memory)
        runner.writes = [.init(
            path: "agent/notes/state.md",
            content: "这是一段被扩写得很长很长、远超原始记录的内容，说明没有完成抽象。",
            evidence: [evidence], trust: .user, expectedVersion: 1)]
        let reader = FakeMaintenanceReader(trust: .user, texts: [evidence: "短"])
        let controller = makeController(
            fixture: fixture, memory: memory, runner: runner, reader: reader,
            settings: settings)
        let batch = await controller.runNow(trigger: .manual)
        let rolled = try XCTUnwrap(batch)
        XCTAssertEqual(rolled.batch.status, .rolledBack)
        XCTAssertEqual(rolled.batch.failureCode, "maintenance-document-longer-than-evidence")
        XCTAssertFalse(rolled.batch.checks.documentsNotLongerThanEvidence)
        let documents = try await memory.documents(scope: .agent)
        let restored = try XCTUnwrap(documents.first { $0.path == "agent/notes/state.md" })
        XCTAssertEqual(restored.content, "旧内容")
        XCTAssertEqual(restored.version, 3) // v1 seed, v2 failed write, v3 restore
        let events = try await fixture.store.events(after: 0, limit: 1_000)
        XCTAssertFalse(events.contains { $0.type == "memory.review_resolved" })
    }

    func testUnresolvableEvidenceAndBudgetExceededBothRollBack() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await settings.save(BotMemoryMaintenanceSettings(enabled: true))
        let memory = await fixture.runtime.memory(for: "main")
        let runner = FakeMaintenanceRunner(sessionID: maintainerSession, memory: memory)
        runner.writes = [.init(
            path: "agent/notes/evidence.md", content: "短",
            evidence: [evidence], trust: .user, expectedVersion: 0)]
        let reader = FakeMaintenanceReader(trust: .user, texts: [evidence: "短"], failReferences: true)
        let controller = makeController(
            fixture: fixture, memory: memory, runner: runner, reader: reader,
            settings: settings)
        let unresolved = await controller.runNow(trigger: .manual)
        XCTAssertEqual(unresolved?.batch.status, .rolledBack)
        XCTAssertEqual(unresolved?.batch.failureCode, "maintenance-evidence-unresolved")
        let remaining = try await memory.documents(scope: .agent)
        XCTAssertFalse(remaining.contains { $0.path == "agent/notes/evidence.md" })

        // A previously recorded maintenance spend above the per-run budget
        // forces the next batch to roll back even when its own turn succeeds.
        let ledger = BotLLMLedger(eventLog: fixture.store)
        try await ledger.append(BotLLMLedgerRecord(
            ts: "2025-10-09T08:53:20.000Z", botId: "main", sessionId: maintainerSession,
            purpose: .memoryMaintenance, model: "deepseek-flash", provider: "deepseek",
            inputTokens: 99_999, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
            durationMs: 1))
        let readerOK = FakeMaintenanceReader(trust: .user, texts: [evidence: "短"])
        let controller2 = makeController(
            fixture: fixture, memory: memory, runner: runner, reader: readerOK,
            settings: settings)
        let status = await controller2.budgetStatus()
        XCTAssertTrue(status.exhausted)
        // A normal opportunity does not start a batch once the UTC-day budget
        // is gone; the memory page shows the exhausted budget instead.
        let stopped = await controller2.runNow(trigger: .manual)
        XCTAssertNil(stopped)
        // A forced batch still runs so the post-run cap remains enforced; it
        // rolls back when the ledger says the daily cap was exceeded.
        let budget = await controller2.runNow(trigger: .manual, force: true)
        XCTAssertEqual(budget?.batch.status, .rolledBack)
        XCTAssertEqual(budget?.batch.failureCode, "maintenance-budget-exceeded")
    }

    func testMaintainerWriteRulesMatchTheMainChat() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: maintainerSession, kind: .maintainer)
        await fixture.runtime.beginMaintenanceTurn(
            sessionId: maintainerSession, batchID: "mm-0123456789abcdef0123456789abcdef")
        await fixture.runtime.beginTurn(sessionId: maintainerSession, hidden: true)
        let evidenceValue = BotJSONValue.array([.string(evidence)])
        let shared = try await registerAndExecute(
            fixture.runtime, name: "UpdateMemory",
            arguments: .object([
                "action": .string("write"), "path": .string("user/profile.md"),
                "content": .string("用户喜欢简短回答。"), "expected_version": .number(0),
                "evidence": evidenceValue,
            ]), sessionId: maintainerSession)
        XCTAssertEqual(shared.structuredContent?["ok"], .bool(true),
                       String(describing: shared.structuredContent))
        let memory = await fixture.runtime.memory(for: "main")
        let profile = try await memory.documents(scope: .user)
            .first { $0.path == "user/profile.md" }
        XCTAssertEqual(profile?.author.kind, .maintainer)
        XCTAssertEqual(profile?.source?.kind, .maintenance)
        XCTAssertEqual(profile?.trust, "user")

        let missingEvidence = try await registerAndExecute(
            fixture.runtime, name: "UpdateMemory",
            arguments: .object([
                "action": .string("write"), "path": .string("user/notes/no-evidence.md"),
                "content": .string("没有引用"), "expected_version": .number(0),
            ]), sessionId: maintainerSession)
        XCTAssertEqual(missingEvidence.structuredContent?["ok"], .bool(false))
        XCTAssertEqual(missingEvidence.structuredContent?["code"],
                       .string("memory-evidence-required"))

        let agentWrite = try await registerAndExecute(
            fixture.runtime, name: "UpdateMemory",
            arguments: .object([
                "action": .string("write"), "path": .string("agent/notes/no-evidence.md"),
                "content": .string("自己的推断"), "expected_version": .number(0),
            ]), sessionId: maintainerSession)
        XCTAssertEqual(agentWrite.structuredContent?["ok"], .bool(true))

        await fixture.runtime.setMainBotProvider { _ in false }
        let nonMain = try await registerAndExecute(
            fixture.runtime, name: "UpdateMemory",
            arguments: .object([
                "action": .string("write"), "path": .string("user/notes/other.md"),
                "content": .string("非主 Bot 不许写"), "expected_version": .number(0),
                "evidence": evidenceValue,
            ]), sessionId: maintainerSession)
        XCTAssertEqual(nonMain.structuredContent?["ok"], .bool(false))
        XCTAssertEqual(nonMain.structuredContent?["code"], .string("memory-scope-denied"))
    }

    func testUserCancelledBatchKeepsCommittedWrites() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let (settings, suite) = makeSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await settings.save(BotMemoryMaintenanceSettings(enabled: true))
        let memory = await fixture.runtime.memory(for: "main")
        let runner = FakeMaintenanceRunner(sessionID: maintainerSession, memory: memory)
        runner.status = "cancelled"
        runner.writes = [.init(
            path: "agent/notes/cancelled.md", content: "已写成功的这一份要保留。",
            evidence: [], trust: .assistant, expectedVersion: 0)]
        let controller = makeController(
            fixture: fixture, memory: memory, runner: runner, reader: FakeMaintenanceReader(),
            settings: settings)
        let view = await controller.runNow(trigger: .manual)
        let batch = try XCTUnwrap(view)
        XCTAssertEqual(batch.batch.status, .cancelled)
        XCTAssertEqual(batch.batch.changes.count, 1)
        XCTAssertTrue(batch.canRollback)
        let documents = try await memory.documents(scope: .agent)
        XCTAssertEqual(
            documents.first { $0.path == "agent/notes/cancelled.md" }?.content,
            "已写成功的这一份要保留。")
    }

    func testMarkedContradictionLeavesAReviewRequest() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.beginTurn(
            sessionId: "gb-main", hidden: false,
            origin: BotTurnOrigin(rpcId: "user-action:contradiction"))
        let result = try await registerAndExecute(
            fixture.runtime, name: "UpdateMemory",
            arguments: .object([
                "action": .string("write"), "path": .string("user/profile.md"),
                "content": .string("用户每天七点起床。"), "expected_version": .number(0),
                "evidence": .array([.string(evidence)]),
                "marked_contradiction": .bool(true),
            ]))
        XCTAssertEqual(result.structuredContent?["ok"], .bool(true),
                       String(describing: result.structuredContent))
        let events = try await fixture.store.events(after: 0, limit: 1_000)
        let review = events.first { $0.type == "memory.review_requested" }
        XCTAssertEqual(review?.data["path"]?.stringValue, "user/profile.md")
        XCTAssertEqual(review?.principal.kind, "chat")
    }

    private func makeMemoryEvent(
        type: String, path: String, expected: Int, version: Int, scope: String
    ) -> BotEvent {
        BotEvent(
            type: type, eventId: "\(type):\(path):\(version)",
            commitSeq: version, time: 1_760_000_000_000,
            origin: .local(source: "memory-service"), traceId: "test",
            principal: BotPrincipal(botId: "main", sessionId: maintainerSession, kind: "maintainer"),
            causationId: nil, correlationId: "memory-maintenance:mm-test",
            data: .object([
                "path": .string(path), "scope": .string(scope),
                "expected_version": .number(Double(expected)),
                "version": .number(Double(version)),
                "content": .string("x"),
            ]))
    }

    private func databaseScalar(_ sql: String, file: URL) throws -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "MemoryMaintenanceTests", code: 1)
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "MemoryMaintenanceTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
}

private actor LockedNotifications {
    private(set) var values: [String] = []

    func append(_ value: String) { values.append(value) }
}

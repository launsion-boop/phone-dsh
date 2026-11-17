// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// PC-20261116-bot-aha-evidence: writer-recorded `review` and the host-derived
/// `evidence_status` view (spec/bot/v2 §1.5.1). Every test drives the real
/// MCP tool surface or the real document store; none hand-copies the contract.
final class MemoryReviewTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteDomainStore!
    private var gateway: BotGateway!
    private var service: BotRecordService!
    private var runtime: BotMCPRuntime!

    private let userMessage = "record://session/gb-main#3"
    private var observation = "record://session/gb-main#4"
    private let assistantLine = "record://session/gb-main#5"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materialized/home/sessions/gb-main", isDirectory: true),
            withIntermediateDirectories: true)
        try writeSessionLog()
        store = try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        gateway = BotGateway(now: { 1_000 })
        try await gateway.issueSession(botId: "bot-a", sessionId: "gb-main", kind: .chat)
        service = BotRecordService(store: store, gateway: gateway, workspaceRoot: root)
        runtime = BotMCPRuntime(store: store, gateway: gateway,
                                recordEvidence: service, now: { 1_760_000_030_000 })
        await runtime.installProvenance(BotProvenanceService(eventLog: store))
        try await runtime.grants.recover()
        observation = try await appendSyntheticObservation()
    }

    /// A real web observation carrier: the envelope carries the resource
    /// identity and its body is the versioned text. The earlier `tool/call`
    /// line is a call, not an observation and has no resource.
    private func appendSyntheticObservation() async throws -> String {
        let envelope = try XCTUnwrap(BotObservationEnvelope(
            source: "web", origin: "https://example.com/article",
            at: "2026-11-16T08:00:00.000Z", owner: "bot-a",
            reference: BotRecordReference.session(sessionID: "gb-main", seq: 4),
            text: "observed web article"))
        let sequence = try await store.append(BotEvent(
            type: "conversation.tool_result", eventId: "review-observation:test",
            time: 1_760_000_004_000, origin: .local(source: "runtime"),
            traceId: "trace-review-observation",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil, correlationId: "gb-main",
            data: .object(["message": .object([
                "role": .string("tool"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(envelope.encoded()),
                ])]),
            ])])))
        return "record://event/\(sequence)"
    }

    override func tearDown() async throws {
        try? await store?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - shared fixtures

    /// Drives the phone-extension `memory-write.phone.json` reviewCases through
    /// the real authorizer (shape) and, where the shape is legal, the real
    /// record resolver (existence/ownership). The shared `memory-write.json`
    /// baseline stays review-free for consumers that only implement the common
    /// fields; this test reads the overlay that carries the extension vectors.
    func testReviewGoldenCasesThroughAuthorizerAndResolver() async throws {
        let golden = try MemoryTestFixtures.decode(
            MemoryWriteReviewGolden.self, "memory-write.phone")
        // The shared vectors reference `record://event/7` and `#8`; give this
        // Bot eight of its own durable events so those refs really resolve.
        for index in 1...8 {
            _ = try await store.append(BotEvent(
                type: "conversation.turn_started",
                eventId: "review-golden-\(index)",
                time: 1_760_000_000_000 + Int64(index) * 1_000,
                origin: .local(source: "runtime"),
                traceId: "review-golden-\(index)",
                principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
                causationId: nil,
                correlationId: nil,
                data: .object([:])))
        }
        for item in golden.reviewCases.valid {
            var review = item.review
            review.refs = review.refs.map { raw in
                raw == BotMemoryAuthorizer.currentUserTurnEvidence
                    ? (item.currentUserTurn ?? raw) : raw
            }
            XCTAssertNil(BotMemoryAuthorizer.reviewError(review), item.name)
            if !review.refs.isEmpty {
                let snapshot = try await service.evidenceSnapshot(
                    for: review.refs, callerBotID: "bot-a",
                    callerSessionID: "gb-main")
                for ref in review.refs {
                    XCTAssertEqual(snapshot.point(for: ref)?.resolved, true,
                                   "\(item.name): \(ref)")
                }
            }
        }
        for item in golden.reviewCases.invalid {
            if item.review.refs.contains(BotMemoryAuthorizer.currentUserTurnEvidence) {
                // The placeholder only exists inside a live user turn; the
                // hidden-turn rejection is covered by the MCP test below.
                continue
            }
            if BotMemoryAuthorizer.reviewError(item.review) != nil { continue }
            // Shape is legal, so the rejection must come from resolution.
            let snapshot = try await service.evidenceSnapshot(
                for: item.review.refs, callerBotID: "bot-a",
                callerSessionID: "gb-main")
            let allResolved = item.review.refs.allSatisfy {
                snapshot.point(for: $0)?.resolved == true
            }
            XCTAssertFalse(allResolved, "\(item.name) must not resolve")
        }
    }

    /// The reviewed recall hit is a phone-extension vector: the shared
    /// `memory-recall.json` baseline stays review-free, so decode the overlay
    /// through the real `BotMemoryRecallHit` codec (not a hand-written copy).
    func testReviewedRecallHitDecodesThroughTheRealCodec() throws {
        struct Overlay: Decodable { let hits: [BotMemoryRecallHit] }
        let overlay: Overlay = try MemoryTestFixtures.decode(
            Overlay.self, "memory-recall.phone")
        let reviewed = try XCTUnwrap(overlay.hits.first { $0.review != nil })
        XCTAssertEqual(reviewed.path, "user/profile.md")
        XCTAssertEqual(reviewed.review?.state, .verified)
        XCTAssertEqual(reviewed.review?.basis, .userStatement)
        XCTAssertEqual(reviewed.review?.refs, [userMessage])
    }

    func testHiddenTurnCannotUseCurrentUserTurnAsReviewRef() async throws {        let rejected = try await call([
            "action": "write", "path": "user/preferences/hidden.md",
            "content": "# hidden",
            "expected_version": 0,
            "evidence": [userMessage],
            "review": ["state": "verified", "basis": "user-statement",
                       "refs": ["current-user-turn"]],
        ], hidden: true)
        XCTAssertEqual(rejected.isError, true)
        XCTAssertEqual(rejected.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")
    }

    // MARK: - review write/read

    func testVerifiedReviewPersistsAndReadsBack() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/web.md",
            "content": "Example Domain",
            "expected_version": 0,
            "evidence": [observation],
            "review": [
                "state": "verified",
                "basis": "record-recheck",
                "method": "回读 web_fetch 结果",
                "at_ms": 1_760_000_020_000,
                "refs": [observation],
            ],
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true),
                       "\(String(describing: written.structuredContent))")

        let read = try await call(["path": "agent/notes/web.md"], name: "ReadMemory")
        XCTAssertEqual(read.structuredContent?["review"]?["state"]?.stringValue, "verified")
        XCTAssertEqual(read.structuredContent?["review"]?["basis"]?.stringValue,
                       "record-recheck")
        XCTAssertEqual(read.structuredContent?["review"]?["method"]?.stringValue,
                       "回读 web_fetch 结果")
        XCTAssertEqual(read.structuredContent?["review"]?["at_ms"], .number(1_760_000_020_000))
        XCTAssertEqual(read.structuredContent?["review"]?["refs"]?.arrayValue?.count, 1)
    }

    func testVerifiedWithoutRefsIsRejected() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/no-refs.md",
            "content": "no refs",
            "expected_version": 0,
            "review": ["state": "verified", "basis": "record-recheck",
                       "method": "looked", "at_ms": 1],
        ])
        XCTAssertEqual(written.isError, true)
        XCTAssertEqual(written.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")
    }

    func testVerifiedWithModelInferenceIsRejected() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/inference.md",
            "content": "inference",
            "expected_version": 0,
            "review": ["state": "verified", "basis": "model-inference",
                       "refs": [observation]],
        ])
        XCTAssertEqual(written.isError, true)
        XCTAssertEqual(written.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")
    }

    func testDisputedWithoutRefsIsRejected() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/disputed.md",
            "content": "disputed",
            "expected_version": 0,
            "review": ["state": "disputed", "basis": "user-statement"],
        ])
        XCTAssertEqual(written.isError, true)
        XCTAssertEqual(written.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")
    }

    func testVerifiedWithUnresolvableOrForeignRefIsRejected() async throws {
        let missing = try await call([
            "action": "write", "path": "agent/notes/missing.md",
            "content": "missing",
            "expected_version": 0,
            "review": ["state": "verified", "basis": "record-recheck",
                       "refs": ["record://event/999"]],
        ])
        XCTAssertEqual(missing.isError, true)
        XCTAssertEqual(missing.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")

        let foreign = try await call([
            "action": "write", "path": "agent/notes/foreign.md",
            "content": "foreign",
            "expected_version": 0,
            "review": ["state": "verified", "basis": "record-recheck",
                       "refs": ["record://session/gb-other#3"]],
        ])
        XCTAssertEqual(foreign.isError, true)
        XCTAssertEqual(foreign.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")
    }

    func testUnverifiedModelInferenceIsAcceptedButNotVerified() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/unverified.md",
            "content": "guess",
            "expected_version": 0,
            "review": ["state": "unverified", "basis": "model-inference"],
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true),
                       "\(String(describing: written.structuredContent))")
        let read = try await call(["path": "agent/notes/unverified.md"], name: "ReadMemory")
        XCTAssertEqual(read.structuredContent?["review"]?["state"]?.stringValue, "unverified")
    }

    func testCurrentUserTurnReviewRefResolvesToTheUserMessage() async throws {
        let written = try await call([
            "action": "write", "path": "user/preferences/drinks.md",
            "content": "# Drinks\n\n- OAT_LATTE_B",
            "expected_version": 0,
            "evidence": [userMessage],
            "review": ["state": "verified", "basis": "user-statement",
                       "refs": ["current-user-turn"]],
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true),
                       "\(String(describing: written.structuredContent))")
        let read = try await call(
            ["path": "user/preferences/drinks.md"], name: "ReadMemory")
        XCTAssertEqual(read.structuredContent?["review"]?["refs"]?.arrayValue?.first?.stringValue,
                       userMessage)
    }

    /// Old data: no `review` member at all reads as "no recorded judgment".
    func testAbsentReviewReadsAsNoJudgment() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/plain.md",
            "content": "plain",
            "expected_version": 0,
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true))
        let read = try await call(["path": "agent/notes/plain.md"], name: "ReadMemory")
        XCTAssertNil(read.structuredContent?["review"])
        // COMPACT stored_with_provenance anchors an evidence-less agent chat
        // write to the host-observed current user turn. The read view must
        // report that real ref (and its real observation time) rather than an
        // empty list or a synthesized source version.
        let status = read.structuredContent?["evidence_status"]?.arrayValue
        XCTAssertEqual(status?.count, 1)
        XCTAssertEqual(status?.first?["ref"]?.stringValue, userMessage)
        XCTAssertEqual(status?.first?["source_version"], .null)
    }

    // MARK: - evidence_status (host-derived, never persisted)

    func testReadEvidenceStatusUsesRecordTimeNotDocumentTime() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/times.md",
            "content": "observed",
            "expected_version": 0,
            "evidence": [userMessage],
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true))
        let read = try await call(["path": "agent/notes/times.md"], name: "ReadMemory")
        let status = read.structuredContent?["evidence_status"]?.arrayValue?.first
        XCTAssertEqual(status?["ref"]?.stringValue, userMessage)
        // Expected value comes from the frozen fixture, not a hand copy.
        let expected = try goldenEvidenceStatus(case: "read-document-evidence-status")
        XCTAssertEqual(status?["observed_at_ms"]?.numberValue.map(Int64.init), expected)
        XCTAssertEqual(status?["source_version"], .null)
        // The document's own update time is the write clock, never the source time.
        XCTAssertNotEqual(read.structuredContent?["updated_at_ms"], .number(1_760_000_000_300))
    }

    func testEvidenceStatusBecomesNullWhenTheRecordNoLongerResolves() async throws {
        _ = try await call([
            "action": "write", "path": "agent/notes/erased-later.md",
            "content": "observed",
            "expected_version": 0,
            "evidence": [userMessage],
        ])
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"))
        let read = try await call(
            ["path": "agent/notes/erased-later.md"], name: "ReadMemory")
        let status = read.structuredContent?["evidence_status"]?.arrayValue?.first
        XCTAssertEqual(status?["ref"]?.stringValue, userMessage)
        XCTAssertEqual(status?["observed_at_ms"], .null,
                       "an unresolvable record must read as unknown, not as fresh")
        XCTAssertEqual(status?["source_version"], .null)
    }

    func testRecallCarriesEvidenceStatusInEvidenceOrder() async throws {
        _ = try await call([
            "action": "write", "path": "agent/notes/first.md",
            "content": "Example Domain first",
            "expected_version": 0,
            "evidence": [userMessage, observation],
        ])
        _ = try await call([
            "action": "write", "path": "agent/notes/second.md",
            "content": "Example Domain second",
            "expected_version": 0,
            "evidence": [observation],
        ])
        let recall = try await call(
            ["query": "Example Domain", "limit": 10], name: "RecallMemory")
        let hits = recall.structuredContent?["hits"]?.arrayValue ?? []
        XCTAssertEqual(hits.count, 2)
        for hit in hits {
            let evidence = hit["evidence"]?.arrayValue ?? []
            let status = hit["evidence_status"]?.arrayValue ?? []
            XCTAssertEqual(status.count, evidence.count)
            for (index, ref) in evidence.enumerated() {
                XCTAssertEqual(status[index]["ref"]?.stringValue, ref.stringValue)
            }
        }
        let first = hits.first { $0["path"]?.stringValue == "agent/notes/first.md" }
        XCTAssertEqual(first?["evidence_status"]?.arrayValue?.first?["observed_at_ms"],
                       .number(1_760_000_003_000))
        XCTAssertEqual(first?["evidence_status"]?.arrayValue?.last?["observed_at_ms"],
                       .number(1_760_000_004_000))
    }

    /// Q-09: over the batch ceiling the resolver rejects instead of silently
    /// degrading to unknown times.
    func testEvidenceSnapshotRejectsMoreThan512DistinctRefs() async throws {
        let references = (0..<513).map { "record://session/gb-main#\($0)" }
        do {
            _ = try await service.evidenceSnapshot(
                for: references, callerBotID: "bot-a", callerSessionID: "gb-main")
            XCTFail("513 distinct refs must be rejected")
        } catch let error as BotRecordServiceError {
            XCTAssertEqual(error, .invalidArguments)
        }
    }

    func testEvidenceSnapshotCoversTheFullRecallBatchAndDeduplicates() async throws {
        let references = (0..<400).map { "record://session/gb-main#\($0)" }
        let snapshot = try await service.evidenceSnapshot(
            for: references + references,
            callerBotID: "bot-a", callerSessionID: "gb-main")
        XCTAssertEqual(snapshot.points.count, 400,
                       "50 hits x 8 refs must fit in one batched resolve, deduplicated")
    }

    // MARK: - regressions requested by the pre-review

    /// A record whose structure does not let the host infer a trust is still a
    /// legal reference: the aggregate stays `assistant` instead of erroring.
    func testRecordWithUninferableTrustStillCountsAsEvidence() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/odd-record.md",
            "content": "odd record",
            "expected_version": 0,
            "evidence": [assistantLine],
        ])
        XCTAssertNotEqual(written.isError, true,
                          "\(String(describing: written.structuredContent))")
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true))
        let memory = await runtime.memory(for: "bot-a")
        guard case let .document(document) = try await memory.read(
            path: "agent/notes/odd-record.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.trust, "assistant")
    }

    // MARK: - pre-review fixes (round 2)

    func testExplicitNullReviewIsRejected() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/null-review.md",
            "content": "null review",
            "expected_version": 0,
            "review": NSNull(),
        ])
        XCTAssertEqual(written.isError, true,
                       "an explicit null is not the same as an absent review")
        XCTAssertEqual(written.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")
    }

    func testReviewAtMillisecondsMustBeAnInteger() async throws {
        for atMS in [1.5, -1, NSNull()] as [Any] {
            let written = try await call([
                "action": "write", "path": "agent/notes/at-\(UUID().uuidString).md",
                "content": "at_ms",
                "expected_version": 0,
                "review": ["state": "unverified", "basis": "model-inference",
                           "at_ms": atMS],
            ])
            XCTAssertEqual(written.isError, true, "at_ms=\(atMS) must be rejected")
            XCTAssertEqual(written.structuredContent?["error"]?["code"]?.stringValue,
                           "memory-review-invalid", "at_ms=\(atMS)")
        }
    }

    /// A legacy version may carry `import`/`system`; restore must inherit the
    /// raw value instead of narrowing it through `BotRecordTrust`.
    func testRestorePreservesLegacyImportAndSystemTrust() async throws {
        let context = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .agentMessage, sessionID: "gb-main"),
            trust: nil, isMainBot: true)
        let memory = await runtime.memory(for: "bot-a")
        for legacyTrust in ["import", "system"] {
            let path = "agent/notes/legacy-\(legacyTrust).md"
            try await appendLegacyVersion(
                path: path, trust: legacyTrust, content: "old \(legacyTrust)")
            let restored = try await memory.write(
                BotMemoryWriteRequest(
                    action: .restore, path: path,
                    expectedVersion: 1, restoreVersion: 1),
                context: context)
            XCTAssertTrue(restored.ok, "\(String(describing: restored.code))")
            guard case let .document(document) = try await memory.read(path: path) else {
                return XCTFail("expected document for \(path)")
            }
            XCTAssertEqual(document.trust, legacyTrust,
                           "restore must not narrow a legal legacy trust")
        }
    }

    // MARK: - Q-10: review validation boundaries

    func testUnknownReviewStateOrBasisIsRejected() async throws {
        let unknownState = try await call([
            "action": "write", "path": "agent/notes/bad-state.md",
            "content": "x", "expected_version": 0,
            "review": ["state": "confirmed", "basis": "observation"],
        ])
        XCTAssertEqual(unknownState.isError, true)
        XCTAssertEqual(unknownState.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")

        let unknownBasis = try await call([
            "action": "write", "path": "agent/notes/bad-basis.md",
            "content": "x", "expected_version": 0,
            "review": ["state": "unverified", "basis": "vibes"],
        ])
        XCTAssertEqual(unknownBasis.isError, true)
        XCTAssertEqual(unknownBasis.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")
    }

    func testReviewExtraMemberIsRejected() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/extra.md",
            "content": "x", "expected_version": 0,
            "review": ["state": "unverified", "basis": "model-inference",
                       "confidence": 0.9],
        ])
        XCTAssertEqual(written.isError, true)
        XCTAssertEqual(written.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")
    }

    func testReviewRefsCapIsEnforced() async throws {
        let refs = Array(repeating: observation, count: 9)
        let written = try await call([
            "action": "write", "path": "agent/notes/too-many-refs.md",
            "content": "x", "expected_version": 0,
            "review": ["state": "verified", "basis": "record-recheck", "refs": refs],
        ])
        XCTAssertEqual(written.isError, true)
        XCTAssertEqual(written.structuredContent?["error"]?["code"]?.stringValue,
                       "memory-review-invalid")
    }

    func testReviewMethodLengthBoundary() async throws {
        let empty = try await call([
            "action": "write", "path": "agent/notes/empty-method.md",
            "content": "x", "expected_version": 0,
            "review": ["state": "unverified", "basis": "model-inference", "method": ""],
        ])
        XCTAssertEqual(empty.isError, true)

        let tooLong = try await call([
            "action": "write", "path": "agent/notes/long-method.md",
            "content": "x", "expected_version": 0,
            "review": ["state": "unverified", "basis": "model-inference",
                       "method": String(repeating: "a", count: 201)],
        ])
        XCTAssertEqual(tooLong.isError, true)

        let boundary = try await call([
            "action": "write", "path": "agent/notes/ok-method.md",
            "content": "x", "expected_version": 0,
            "review": ["state": "unverified", "basis": "model-inference",
                       "method": String(repeating: "a", count: 200)],
        ])
        XCTAssertEqual(boundary.structuredContent?["ok"], .bool(true),
                       "\(String(describing: boundary.structuredContent))")
    }

    func testDisputedWithOneSideIsAccepted() async throws {
        // r5 wording: disputed needs at least one cited side, not both.
        let written = try await call([
            "action": "write", "path": "agent/notes/disputed-one.md",
            "content": "两个说法冲突，先保留一边。", "expected_version": 0,
            "evidence": [observation],
            "review": ["state": "disputed", "basis": "record-recheck",
                       "refs": [observation]],
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true),
                       "\(String(describing: written.structuredContent))")
        let read = try await call(["path": "agent/notes/disputed-one.md"], name: "ReadMemory")
        XCTAssertEqual(read.structuredContent?["review"]?["state"]?.stringValue, "disputed")
    }

    // MARK: - Q-10: truly erased records (tombstone, not a deleted file)

    func testTombstonedSessionLineMakesEvidenceStatusNull() async throws {
        _ = try await call([
            "action": "write", "path": "agent/notes/tombstoned.md",
            "content": "observed", "expected_version": 0,
            "evidence": [userMessage],
        ])
        try rewriteSessionLog(tombstoneSeq: 3)
        let read = try await call(["path": "agent/notes/tombstoned.md"], name: "ReadMemory")
        let status = read.structuredContent?["evidence_status"]?.arrayValue?.first
        XCTAssertEqual(status?["ref"]?.stringValue, userMessage)
        XCTAssertEqual(status?["observed_at_ms"], .null)
    }

    func testErasedEventPayloadMakesEvidenceStatusNull() async throws {
        // The grant store fails closed on a non-empty event stream without a
        // snapshot; production recovers at composition start.
        try await runtime.grants.recover()
        let sequence = try await store.append(BotEvent(
            type: "comm.inbound",
            eventId: "q10-erased-event",
            time: 1_760_000_000_600,
            origin: .local(source: "comm-service"),
            traceId: "q10-erased-event",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil,
            correlationId: nil,
            data: .object(["note": .string("will be erased")])))
        let reference = "record://event/\(sequence)"
        _ = try await call([
            "action": "write", "path": "agent/notes/erased-event.md",
            "content": "observed", "expected_version": 0,
            "evidence": [reference],
        ])
        let erasure = BotErasureEventData(
            erasureId: "q10-erasure",
            reason: "memory-path-erase",
            atMS: 1_760_000_000_700,
            // The target path deliberately differs from the document under
            // test: this simulates erasing the *cited event's payload*, not
            // the memory document that cites it.
            targets: [BotErasureEventData.Target(
                kind: "memory", scope: "agent", path: "agent/notes/unrelated.md")])
        let event = BotEvent(
            type: "erasure",
            eventId: "q10-erasure",
            time: 1_760_000_000_700,
            origin: .local(source: "user"),
            traceId: "q10-erasure",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil,
            correlationId: nil,
            data: try BotJSONValue.parse(JSONEncoder().encode(erasure)))
        try await store.erasePayloads(
            [sequence], erasureEvent: event, atMS: 1_760_000_000_700)
        let read = try await call(["path": "agent/notes/erased-event.md"], name: "ReadMemory")
        let status = read.structuredContent?["evidence_status"]?.arrayValue?.first
        XCTAssertEqual(status?["ref"]?.stringValue, reference)
        XCTAssertEqual(status?["observed_at_ms"], .null)
    }

    /// Q-07 / r5: restore inherits without re-resolving. A later-erased
    /// verified ref keeps the review verbatim and reports a null observation.
    func testRestoreAfterVerifiedRefErasureKeepsReviewVerbatim() async throws {
        let written = try await call([
            "action": "write", "path": "agent/notes/verified-later-erased.md",
            "content": "observed", "expected_version": 0,
            "evidence": [userMessage],
            "review": ["state": "verified", "basis": "record-recheck",
                       "refs": [userMessage]],
        ])
        XCTAssertEqual(written.structuredContent?["ok"], .bool(true))
        try rewriteSessionLog(tombstoneSeq: 3)
        let restored = try await call([
            "action": "restore", "path": "agent/notes/verified-later-erased.md",
            "expected_version": 1, "restore_version": 1,
        ])
        XCTAssertEqual(restored.structuredContent?["ok"], .bool(true),
                       "\(String(describing: restored.structuredContent))")
        let read = try await call(
            ["path": "agent/notes/verified-later-erased.md"], name: "ReadMemory")
        XCTAssertEqual(read.structuredContent?["review"]?["state"]?.stringValue, "verified",
                       "restore inherits the review; it does not re-validate or downgrade it")
        XCTAssertEqual(read.structuredContent?["review"]?["refs"]?.arrayValue?.first?.stringValue,
                       userMessage)
        XCTAssertEqual(read.structuredContent?["evidence_status"]?.arrayValue?
                        .first?["observed_at_ms"], .null)
    }

    // MARK: - restore / rollback inheritance

    func testRestoreInheritsEvidenceTrustAndReview() async throws {
        let context = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .agentMessage, sessionID: "gb-main"),
            trust: nil, isMainBot: true)
        let memory = await runtime.memory(for: "bot-a")
        let first = try await call([
            "action": "write", "path": "agent/notes/plan.md", "content": "v1",
            "expected_version": 0,
            "evidence": [observation],
            "review": ["state": "verified", "basis": "record-recheck",
                       "method": "re-read", "at_ms": 1_760_000_020_000,
                       "refs": [observation]],
        ])
        XCTAssertEqual(first.structuredContent?["ok"], .bool(true),
                       "\(String(describing: first.structuredContent))")
        let second = try await call([
            "action": "append", "path": "agent/notes/plan.md", "content": "\nv2",
            "expected_version": 1,
            "review": ["state": "unverified", "basis": "model-inference"],
        ])
        XCTAssertEqual(second.structuredContent?["ok"], .bool(true))

        // A model supplying `review` on restore cannot inject or clear the
        // restored version's metadata: it is ignored, even when its refs are
        // not resolvable.
        let restored = try await call([
            "action": "restore", "path": "agent/notes/plan.md",
            "expected_version": 2, "restore_version": 1,
            "review": ["state": "verified", "basis": "record-recheck",
                       "refs": ["record://event/999"]],
        ])
        XCTAssertEqual(restored.structuredContent?["ok"], .bool(true),
                       "\(String(describing: restored.structuredContent))")
        guard case let .document(document) = try await memory.read(
            path: "agent/notes/plan.md") else {
            return XCTFail("expected document")
        }
        XCTAssertEqual(document.content, "v1")
        XCTAssertEqual(document.evidence, [observation])
        XCTAssertEqual(document.trust, "observation")
        XCTAssertEqual(document.review?.state, .verified)
        XCTAssertEqual(document.review?.refs, [observation])
    }

    /// "被恢复版本本身缺这些字段时保持缺失": a version payload without `trust`
    /// must not have `assistant`/`user` fabricated by the restore.
    func testRestoreKeepsAMissingTrustMissing() async throws {
        let data = BotJSONValue.object([
            "path": .string("agent/notes/legacy.md"),
            "scope": .string("agent"),
            "content": .string("legacy body"),
            "version": .number(1),
            "expected_version": .number(0),
            "updated_at_ms": .number(1_760_000_000_500),
            "author": .object([
                "bot_id": .string("bot-a"), "kind": .string("chat"),
            ]),
            "evidence": .array([]),
        ])
        _ = try await store.append(BotEvent(
            type: "memory.document_written",
            eventId: "legacy-document-without-trust",
            time: 1_760_000_000_500,
            origin: .local(source: "memory-service"),
            traceId: "legacy-document-without-trust",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil,
            correlationId: nil,
            data: data))
        let context = BotMemoryWriteContext(
            botID: "bot-a", sessionID: "gb-main", authorKind: .chat,
            source: BotMemorySource(kind: .agentMessage, sessionID: "gb-main"),
            trust: nil, isMainBot: true)
        let memory = await runtime.memory(for: "bot-a")
        let restored = try await memory.write(
            BotMemoryWriteRequest(
                action: .restore, path: "agent/notes/legacy.md",
                expectedVersion: 1, restoreVersion: 1),
            context: context)
        XCTAssertTrue(restored.ok, "\(String(describing: restored.code))")
        guard case let .document(document) = try await memory.read(
            path: "agent/notes/legacy.md") else {
            return XCTFail("expected document")
        }
        XCTAssertNil(document.trust, "an absent trust must stay absent, not be defaulted")
        XCTAssertNil(document.review)
    }

    // MARK: - Helpers

    private struct MemoryWriteReviewGolden: Decodable {
        struct Cases: Decodable {
            let valid: [Case]
            let invalid: [Case]
        }
        struct Case: Decodable {
            let name: String
            let currentUserTurn: String?
            let turn: String?
            let refs: [String]?
            let review: BotMemoryReview
        }
        let reviewCases: Cases
    }

    /// Pull one expected `evidence_status.observed_at_ms` out of the frozen
    /// read vectors.
    private func goldenEvidenceStatus(case name: String) throws -> Int64? {
        let data = try MemoryTestFixtures.data("memory-read")
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cases = root?["cases"] as? [[String: Any]]
        guard let expect = cases?.first(where: { $0["name"] as? String == name })?["expect"]
            as? [String: Any],
              let statuses = expect["evidenceStatus"] as? [[String: Any]] else {
            throw FixtureError.missingCase(name)
        }
        return (statuses.first?["observed_at_ms"] as? NSNumber)?.int64Value
    }

    private enum FixtureError: Error {
        case missingCase(String)
    }

    private func appendLegacyVersion(
        path: String, trust: String, content: String
    ) async throws {
        let data = BotJSONValue.object([
            "path": .string(path),
            "scope": .string("agent"),
            "content": .string(content),
            "version": .number(1),
            "expected_version": .number(0),
            "updated_at_ms": .number(1_760_000_000_500),
            "author": .object([
                "bot_id": .string("bot-a"), "kind": .string("chat"),
            ]),
            "evidence": .array([]),
            "trust": .string(trust),
        ])
        _ = try await store.append(BotEvent(
            type: "memory.document_written",
            eventId: "legacy-trust-\(path)",
            time: 1_760_000_000_500,
            origin: .local(source: "memory-service"),
            traceId: "legacy-trust-\(path)",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-main", kind: "chat"),
            causationId: nil,
            correlationId: nil,
            data: data))
    }

    /// Rewrite the session log with a real erasure tombstone at `seq`, so the
    /// record reader sees `line.erased` (not merely a deleted file).
    private func rewriteSessionLog(tombstoneSeq seq: Int) throws {
        let events: [[String: Any]] = [
            [
                "type": BotSessionErasureTombstone.type, "seq": seq,
                "time": 1_760_000_000_300, "ignorable": true,
                "data": [String: Any](),
            ],
            [
                "type": "tool/call", "seq": 4, "time": 1_760_000_004_000,
                "data": ["turn": 1, "step": 1, "callId": "call-1",
                         "name": "web_fetch", "arguments": "{\"url\":\"https://example.com\"}"],
            ],
            [
                "type": "assistant/message", "seq": 5, "time": 1_760_000_005_000,
                "data": "opaque-non-object",
            ],
        ]
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let lines = try [header] + events
        let text = try lines.map { object in
            String(decoding: try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }

    private func call(
        _ fields: [String: Any],
        name: String = "UpdateMemory",
        hidden: Bool = false,
        held: Bool = false,
        rpcId: String = "bot-1"
    ) async throws -> BotMCPCallResult {
        let arguments = try BotJSONValue.parse(
            JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
        await runtime.beginTurn(sessionId: "gb-main", hidden: hidden, held: held,
                                origin: BotTurnOrigin(rpcId: rpcId))
        await runtime.observeUserMessage(
            sessionId: "gb-main", seq: 3,
            source: ["kind": .string("user"), "rpcId": .string(rpcId)])
        return try await registerAndExecute(
            runtime, name: name, arguments: arguments,
            sessionId: "gb-main", callId: UUID().uuidString)
    }

    private func writeSessionLog() throws {
        let events: [[String: Any]] = [
            [
                "type": "user/message", "seq": 3, "time": 1_760_000_003_000,
                "data": [
                    "message": ["role": "user", "content": [["type": "text", "text": "我叫小林"]]],
                    "source": ["kind": "user", "rpcId": "bot-1"],
                ],
                "surfaceOp": "append",
            ],
            [
                "type": "tool/call", "seq": 4, "time": 1_760_000_004_000,
                "data": ["turn": 1, "step": 1, "callId": "call-1",
                         "name": "web_fetch", "arguments": "{\"url\":\"https://example.com\"}"],
            ],
            // `data` is not an object, so trust inference returns nil: the
            // record still exists and must remain valid evidence.
            [
                "type": "assistant/message", "seq": 5, "time": 1_760_000_005_000,
                "data": "opaque-non-object",
            ],
        ]
        let header: [String: Any] = [
            "type": "session", "version": 4, "id": "gb-main",
            "createdAt": 1_760_000_000_000, "isSeeded": false, "delegationDepth": 0,
        ]
        let lines = try [header] + events
        let text = try lines.map { object in
            String(decoding: try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(
            to: root.appendingPathComponent(
                "materialized/home/sessions/gb-main/session.v4.jsonl"),
            atomically: true, encoding: .utf8)
    }
}

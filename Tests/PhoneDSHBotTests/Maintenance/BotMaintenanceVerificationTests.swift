// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private struct StubSourceChecking: BotMaintenanceSourceChecking {
    var probes: [String: BotMaintenanceSourceProbe]
    var fail = false

    func probe(references: [String], callerBotID: String,
               callerSessionID: String) async throws -> [BotMaintenanceSourceProbe] {
        if fail { throw BotRecordServiceError.unavailable("stub") }
        return references.compactMap { probes[$0] }
    }
}

final class BotMaintenanceVerificationTests: XCTestCase {
    private let now: Int64 = 1_760_000_100_000

    private func probe(
        _ reference: String,
        current: BotMaintenanceSourceCurrent = .current,
        trust: BotRecordTrust = .user,
        observedAt: Int64? = 1_760_000_000_000,
        text: String? = nil,
        subject: String? = nil,
        revision: String? = nil
    ) -> BotMaintenanceSourceProbe {
        BotMaintenanceSourceProbe(
            reference: reference, current: current,
            observedAtMS: observedAt, trust: trust,
            recordType: trust == .observation ? "observation" : "message",
            text: text, subject: subject,
            revision: revision.map {
                BotMaintenanceSourceRevision(kind: "content-sha256", value: $0)
            })
    }

    private func document(
        _ path: String,
        content: String,
        evidence: [String] = [],
        trust: String? = nil,
        scope: BotMemoryScope = .agent,
        review: BotMemoryReview? = nil
    ) -> BotMemoryDocument {
        BotMemoryDocument(
            path: path, scope: scope, content: content, version: 1,
            updatedAtMS: 1_760_000_000_000,
            author: BotMemoryAuthor(botID: "main", kind: .maintainer),
            evidence: evidence, trust: trust, source: nil, review: review)
    }

    private func verify(
        _ documents: [BotMemoryDocument],
        probes: [BotMaintenanceSourceProbe],
        strict: Set<String> = [],
        baselines: [String: BotMaintenanceSourceBaseline] = [:],
        disputed: [String: [String]] = [:],
        invalidated: [String: BotMaintenanceDependencyStatus] = [:],
        feedbackComplete: Bool = true,
        invalidationComplete: Bool = true
    ) async throws -> BotMaintenanceVerificationSummary {
        var byReference: [String: BotMaintenanceSourceProbe] = [:]
        for probe in probes { byReference[probe.reference] = probe }
        let verifier = BotMaintenanceEvidenceVerifier(
            source: StubSourceChecking(probes: byReference))
        return try await verifier.verify(BotMaintenanceVerificationRequest(
            documents: documents, callerBotID: "main",
            callerSessionID: "gb-maintainer-0123456789abcdef",
            checkedAtMS: now, baselines: baselines, strictPaths: strict,
            disputedReferences: disputed, invalidatedReferences: invalidated,
            feedbackComplete: feedbackComplete,
            invalidationComplete: invalidationComplete))
    }

    // MARK: Review is a writer assertion, the host rechecks it

    func testVerifiedReviewWithChangedSourceIsBlocking() async throws {
        let reference = "record://session/gb-main#3"
        let doc = document(
            "agent/wake.md", content: "每天八点起床。", evidence: [reference],
            trust: "observation",
            review: BotMemoryReview(state: .verified, basis: .recordRecheck,
                                    atMS: 1_760_000_000_000, refs: [reference]))
        let summary = try await verify(
            [doc],
            probes: [probe(reference, current: .changed, trust: .observation,
                           text: "八点")],
            strict: [doc.path])
        XCTAssertEqual(summary.findings.count, 1)
        XCTAssertEqual(summary.findings[0].state, .stale)
        XCTAssertTrue(summary.findings[0].reasons.contains(.sourceVersionChanged))
        XCTAssertTrue(summary.findings[0].blocking)
        XCTAssertEqual(summary.blocking, 1)
    }

    func testVerifiedReviewWithoutHostBackingIsBlocking() async throws {
        let reference = "record://session/gb-main#3"
        let doc = document(
            "agent/wake.md", content: "每天八点起床。", evidence: [reference],
            trust: "observation",
            review: BotMemoryReview(state: .verified, basis: .modelInference,
                                    atMS: 1_760_000_000_000, refs: [reference]))
        let summary = try await verify(
            [doc], probes: [probe(reference, trust: .observation, text: "八点")],
            strict: [doc.path])
        XCTAssertEqual(summary.findings[0].state, .unverifiable)
        XCTAssertTrue(summary.findings[0].reasons.contains(.reviewModelBasis))
        XCTAssertTrue(summary.findings[0].blocking)
    }

    func testReviewDecisionOlderThanNewObservationIsStale() async throws {
        let reference = "record://session/gb-main#3"
        let doc = document(
            "agent/wake.md", content: "八点起床。", evidence: [reference],
            trust: "user",
            review: BotMemoryReview(state: .verified, basis: .userStatement,
                                    atMS: 1_760_000_000_000, refs: [reference]))
        let summary = try await verify(
            [doc],
            probes: [probe(reference, trust: .user, observedAt: 1_760_000_050_000)],
            strict: [doc.path])
        XCTAssertEqual(summary.findings[0].state, .stale)
        XCTAssertTrue(summary.findings[0].reasons.contains(.reviewStale))
        XCTAssertTrue(summary.findings[0].blocking)
    }

    // MARK: Erasure never becomes valid again

    func testErasedEvidenceIsUnverifiableAndNotResurrected() async throws {
        let reference = "record://event/42"
        let doc = document(
            "agent/old.md", content: "已经抹除的事。", evidence: [reference],
            trust: "observation")
        let summary = try await verify(
            [doc], probes: [probe(reference, current: .erased, trust: .observation)])
        XCTAssertEqual(summary.findings[0].state, .unverifiable)
        XCTAssertTrue(summary.findings[0].reasons.contains(.evidenceErased))
        XCTAssertFalse(summary.findings[0].reasons.contains(.sourceVersionChanged))
    }

    func testUnresolvedEvidenceFailsClosed() async throws {
        let doc = document(
            "agent/a.md", content: "x", evidence: ["record://event/9"])
        let summary = try await verify([doc], probes: [])
        XCTAssertEqual(summary.findings[0].state, .unverifiable)
        XCTAssertTrue(summary.findings[0].reasons.contains(.evidenceUnresolved))
    }

    // MARK: Trust and scope

    func testDerivedTrustMismatchFailsClosed() async throws {
        let reference = "record://session/gb-main#1"
        let doc = document(
            "agent/a.md", content: "用户说的。", evidence: [reference],
            trust: "user")
        let summary = try await verify(
            [doc], probes: [probe(reference, trust: .assistant)])
        XCTAssertEqual(summary.findings[0].state, .unverifiable)
        XCTAssertTrue(summary.findings[0].reasons.contains(.trustMismatch))
    }

    func testUserScopeNeedsUserEvidence() async throws {
        let reference = "record://event/7"
        let doc = document(
            "user/profile.md", content: "喜欢早上开会。", evidence: [reference],
            trust: "observation", scope: .user)
        let summary = try await verify(
            [doc], probes: [probe(reference, trust: .observation)])
        XCTAssertEqual(summary.findings[0].state, .unverifiable)
        XCTAssertTrue(summary.findings[0].reasons.contains(.userScopeWithoutUserEvidence))
    }

    // MARK: Important facts and cross-signal

    func testSingleSignalObservationFactIsNotVerified() async throws {
        let reference = "record://session/asr#3"
        let doc = document(
            "agent/meeting.md", content: "会议在 3 号会议室，预算 12000 元。",
            evidence: [reference], trust: "observation")
        let summary = try await verify(
            [doc],
            probes: [probe(reference, trust: .observation,
                           text: "会议在 3 号会议室，预算 12000 元。")])
        XCTAssertEqual(summary.findings[0].state, .unverifiable)
        XCTAssertTrue(summary.findings[0].reasons.contains(.singleSignalFact))
    }

    func testTwoIndependentSignalsVerifyObservationFact() async throws {
        let first = "record://session/asr#3"
        let second = "record://event/17"
        let doc = document(
            "agent/meeting.md", content: "会议在 3 号会议室。",
            evidence: [first, second], trust: "observation")
        let summary = try await verify(
            [doc],
            probes: [
                probe(first, trust: .observation, text: "3 号会议室"),
                probe(second, trust: .observation, text: "确认 3 号会议室"),
            ])
        XCTAssertEqual(summary.findings[0].state, .verified)
        XCTAssertFalse(summary.findings[0].reasons.contains(.singleSignalFact))
    }

    func testUserStatementDoesNotRequireSecondSignal() async throws {
        let reference = "record://session/gb-main#3"
        let doc = document(
            "agent/wake.md", content: "用户每天 8 点起床。", evidence: [reference],
            trust: "user")
        let summary = try await verify(
            [doc], probes: [probe(reference, trust: .user, text: "我 8 点起床")])
        XCTAssertEqual(summary.findings[0].state, .verified)
    }

    func testUnsupportedImportantFactIsReported() async throws {
        let reference = "record://event/11"
        let doc = document(
            "agent/a.md", content: "合同金额 88000 元。", evidence: [reference],
            trust: "observation")
        let summary = try await verify(
            [doc], probes: [probe(reference, trust: .observation, text: "合同金额待定")])
        XCTAssertTrue(summary.findings[0].reasons.contains(.unsupportedImportantFact))
    }

    // MARK: Conflict preservation and ordering

    func testUndecidableConflictKeepsBothSidesCited() async throws {
        let older = "record://session/a#2"
        let newer = "record://session/b#4"
        let doc = document(
            "agent/wake.md", content: "用户七点起床。", evidence: [older],
            trust: "observation")
        let summary = try await verify(
            [doc],
            probes: [
                probe(older, trust: .observation, observedAt: 1_000,
                      text: "七点", subject: "wake-time", revision: "7"),
                probe(newer, trust: .observation, observedAt: 1_000,
                      text: "八点", subject: "wake-time", revision: "8"),
            ],
            disputed: [doc.path: [older, newer]])
        XCTAssertEqual(summary.findings[0].state, .disputed)
        XCTAssertTrue(summary.findings[0].reasons.contains(.conflictUndecidable))
        XCTAssertTrue(summary.findings[0].reasons.contains(.conflictNotPreserved))
    }

    func testNewerClaimWinsButLoserStaysInFinding() async throws {
        let older = "record://session/a#2"
        let newer = "record://session/b#4"
        let doc = document(
            "agent/wake.md", content: "用户八点起床。", evidence: [newer],
            trust: "observation")
        let summary = try await verify(
            [doc],
            probes: [
                probe(older, trust: .observation, observedAt: 1_000,
                      text: "七点", subject: "wake-time", revision: "7"),
                probe(newer, trust: .observation, observedAt: 2_000,
                      text: "八点", subject: "wake-time", revision: "8"),
            ],
            disputed: [doc.path: [older, newer]])
        XCTAssertEqual(summary.findings[0].state, .verified)
        XCTAssertEqual(summary.findings[0].preferredReference, newer)
        XCTAssertEqual(Set(summary.findings[0].claims.map(\.reference)),
                       Set([older, newer]))
    }

    func testUserClaimBeatsObservationClaim() async throws {
        let observation = "record://session/asr#1"
        let user = "record://session/gb-main#9"
        let doc = document(
            "agent/wake.md", content: "用户八点起床。", evidence: [user],
            trust: "user")
        let summary = try await verify(
            [doc],
            probes: [
                probe(observation, trust: .observation, observedAt: 9_000,
                      text: "七点", subject: "wake-time", revision: "7"),
                probe(user, trust: .user, observedAt: 1_000,
                      text: "八点", subject: "wake-time", revision: "8"),
            ],
            disputed: [doc.path: [observation, user]])
        XCTAssertEqual(summary.findings[0].preferredReference, user)
        XCTAssertEqual(summary.findings[0].state, .verified)
    }

    func testBaselineRevisionChangeFlagsStale() async throws {
        let reference = "record://event/3"
        let second = "record://event/4"
        let doc = document(
            "agent/ticket.md", content: "票据 120 元。", evidence: [reference, second],
            trust: "observation")
        let baseline = BotMaintenanceSourceBaseline(
            reference: reference, subject: "ticket:9", observedAtMS: 1_000,
            revisionKind: "content-sha256", revisionValue: "aaa")
        let summary = try await verify(
            [doc],
            probes: [
                probe(reference, trust: .observation, text: "票据 120 元",
                      subject: "ticket:9", revision: "bbb"),
                probe(second, trust: .observation, text: "票据 120 元",
                      subject: "ticket:9", revision: "bbb"),
            ],
            baselines: [reference: baseline])
        XCTAssertTrue(summary.findings[0].reasons.contains(.sourceVersionChanged))
        XCTAssertEqual(summary.findings[0].state, .stale)
    }

    func testInvalidatedDependencyIsNotCurrent() async throws {
        let reference = "record://event/5"
        let doc = document(
            "agent/a.md", content: "x", evidence: [reference])
        let summary = try await verify(
            [doc], probes: [probe(reference, trust: .observation)],
            invalidated: [reference: BotMaintenanceDependencyStatus(
                reference: reference, state: .revoked, reason: "grant-revoked")])
        XCTAssertEqual(summary.findings[0].state, .unverifiable)
        XCTAssertTrue(summary.findings[0].reasons.contains(.sourceRevoked))
    }

    func testMissingDependencyReadersFailClosed() async throws {
        let reference = "record://event/12"
        let doc = document(
            "agent/a.md", content: "x", evidence: [reference],
            trust: "observation")
        let summary = try await verify(
            [doc], probes: [probe(reference, trust: .observation)],
            strict: [doc.path], feedbackComplete: false)
        XCTAssertEqual(summary.findings[0].state, .unverifiable)
        XCTAssertTrue(summary.findings[0].reasons.contains(.sourceStatusUnknown))
        XCTAssertTrue(summary.findings[0].blocking)
    }

    func testFactExtractionIsDomainFree() {
        let facts = BotMaintenanceFacts.importantFacts(
            in: #"会面在「Blue Bottle」3 号桌，预算 12,000 元，编号 QUOKKA_9D2，邮箱 a@b.com。"#)
        XCTAssertTrue(facts.contains("3"))
        XCTAssertTrue(facts.contains("12,000"))
        XCTAssertTrue(facts.contains("Blue Bottle"))
        XCTAssertTrue(facts.contains("QUOKKA_9D2"))
        XCTAssertTrue(facts.contains("a@b.com"))
        XCTAssertFalse(facts.contains("会面"))
    }
}

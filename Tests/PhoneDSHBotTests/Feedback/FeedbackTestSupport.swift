// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

actor FeedbackSpyEventLog: BotEventLog {
    private var recorded: [BotEvent] = []
    private let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    @discardableResult
    func append(_ event: BotEvent) async throws -> Int {
        if failing { throw BotFeedbackStoreError.unavailable("spy-append-failed") }
        let sequence = recorded.count + 1
        recorded.append(event.assigningCommitSeq(sequence))
        return sequence
    }

    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        guard limit > 0 else { return [] }
        let page = recorded.filter { ($0.commitSeq ?? 0) > commitSeq }
            .prefix(limit)
        return Array(page)
    }

    var all: [BotEvent] { recorded }
}

final class FeedbackMemoryPort: BotFeedbackMemoryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: BotFeedbackMemorySnapshot]
    var failure: Error?
    var readCount = 0

    init(_ snapshots: [String: BotFeedbackMemorySnapshot] = [:]) {
        self.snapshots = snapshots
    }

    func memorySnapshot(path: String) async throws -> BotFeedbackMemorySnapshot? {
        if let failure { throw failure }
        lock.withLock { readCount += 1 }
        return lock.withLock { snapshots[path] }
    }

    func set(_ snapshot: BotFeedbackMemorySnapshot?, path: String) {
        lock.withLock { snapshots[path] = snapshot }
    }
}

enum FeedbackFixtures {
    static let baseNow: Int64 = wp6Date(2026, 5, 12, 12)

    static func candidate(_ key: String, kind: ProactiveKind = .taskDone,
                          botId: String = "bot-1", routineId: String? = nil,
                          reminderId: String? = nil, at: Int64? = nil) -> ProactiveCandidate {
        var candidate = ProactiveCandidate(
            id: key, kind: kind, botId: botId, dedupeKey: key,
            trigger: "test-trigger", createdAt: at ?? baseNow,
            taskId: kind == .taskDone ? key : nil, status: "completed")
        candidate.routineId = routineId
        candidate.reminderId = reminderId
        if kind == .routineResult {
            candidate.delivery = .interrupt
            candidate.resultExcerpt = "result"
        }
        return candidate
    }

    static func deliveredDecision(_ candidate: ProactiveCandidate, at: Int64,
                                  sequence: Int = 1) -> ProactiveDecision {
        ProactiveDecision(
            id: "proactive:\(at):\(sequence)", at: at, decision: .did,
            reason: "delivered", kind: candidate.kind, botId: candidate.botId,
            dedupeKey: candidate.dedupeKey,
            mode: .on, channel: "system-notification",
            notification: ProactiveNotification(
                title: "t", body: "b", kind: candidate.kind, botId: candidate.botId,
                dedupeKey: candidate.dedupeKey ?? "k"),
            delivery: ProactiveDeliveryResult(delivered: true))
    }

    static func uiOrigin(_ nonce: String) -> BotFeedbackOrigin {
        BotFeedbackOrigin(kind: .uiAction, nonce: nonce)
    }

    static func chatOrigin(_ nonce: String, session: String = "s-chat") -> BotFeedbackOrigin {
        BotFeedbackOrigin(kind: .userChatTurn, sessionID: session, nonce: nonce)
    }

    static func adopt(_ delivery: ProactiveDecision, botID: String? = nil,
                      nonce: String = "ui-adopt-1") -> BotFeedback {
        BotFeedback(
            botID: botID ?? delivery.botId ?? "bot-1", action: .adopt,
            target: BotFeedbackArtifactRef(
                kind: .proactive, id: delivery.id,
                deliveryKey: delivery.dedupeKey),
            scope: .artifact, origin: uiOrigin(nonce))
    }

    static func suppress(_ delivery: ProactiveDecision, scope: BotFeedbackScopeKind,
                         nonce: String = "ui-suppress-1") -> BotFeedback {
        BotFeedback(
            botID: delivery.botId ?? "bot-1", action: .suppress,
            target: BotFeedbackArtifactRef(
                kind: .proactive, id: delivery.id,
                deliveryKey: delivery.dedupeKey),
            scope: scope, origin: uiOrigin(nonce))
    }

    static func correct(path: String, version: Int, botID: String = "bot-1",
                        refs: [String] = [], nonce: String = "ui-correct-1") -> BotFeedback {
        BotFeedback(
            botID: botID, action: .correct,
            target: BotFeedbackArtifactRef(kind: .memory, id: path, version: version),
            scope: .artifact, origin: uiOrigin(nonce), disputedRefs: refs)
    }
}

/// Forwards durable events to a real log but drops the review request, so a
/// feedback event can exist without its review companion (crash window).
actor DropReviewEventLog: BotEventLog {
    private let inner: any BotEventLog

    init(inner: any BotEventLog) {
        self.inner = inner
    }

    @discardableResult
    func append(_ event: BotEvent) async throws -> Int {
        if event.type == "memory.review_requested" { return 0 }
        return try await inner.append(event)
    }

    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        try await inner.events(after: commitSeq, limit: limit)
    }
}

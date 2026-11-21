// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// A durable approval that reaches its expiry must read `expired` /
/// `stale(expired)` for the whole expiry, including while the audit append is
/// still in flight.
///
/// Regression: `expireDurable` removed the pending record and only recorded the
/// terminal notice after awaiting `approval.decided`, so a concurrent
/// `durableStatus` / `resolve` in that window answered `unknown` /
/// `unknown_approval` for a todo that had already expired.
final class BotApprovalExpiryRaceTests: XCTestCase {
    /// An event log that parks the `approval.decided` append until the test has
    /// observed the coordinator midway through expiry.
    actor BlockingDecidedEventLog: BotEventLog {
        private var stored: [BotEvent] = []
        private var appendEntered: CheckedContinuation<Void, Never>?
        private var appendRelease: CheckedContinuation<Void, Never>?
        private var appendIsBlocked = false

        func append(_ event: BotEvent) async throws -> Int {
            if event.type == "approval.decided" {
                appendIsBlocked = true
                appendEntered?.resume()
                appendEntered = nil
                await withCheckedContinuation { appendRelease = $0 }
            }
            let commitSeq = (stored.compactMap(\.commitSeq).max() ?? 0) + 1
            stored.append(event.assigningCommitSeq(commitSeq))
            return commitSeq
        }

        func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
            Array(stored.filter { ($0.commitSeq ?? 0) > commitSeq }
                .sorted { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }.prefix(limit))
        }

        func waitForBlockedAppend() async {
            if appendIsBlocked { return }
            await withCheckedContinuation { appendEntered = $0 }
        }

        func releaseBlockedAppend() {
            appendRelease?.resume()
            appendRelease = nil
        }
    }

    private func makeCall() async throws -> BotResolvedToolCall {
        let registry = BotTokenRegistry(now: { 1_000 })
        let issued = try await registry.issue(botId: "main", sessionId: "gb-task", kind: .task)
        let arguments = BotJSONValue.object(["action": .string("delete")])
        let attribution = BotAttribution(
            id: "call-expiry-race", sessionId: "gb-task",
            incarnation: issued.principal.incarnation, callId: "call-expiry-race",
            name: "UpdateMemory", argsDigest: try BotArgumentsDigest.string(for: arguments),
            runtimeId: BotMCPRuntime.defaultRuntimeID, createdAt: 1_000, expiresAt: 3_600_000)
        return try XCTUnwrap(BotResolvedToolCall(
            sessionId: "gb-task", callId: "call-expiry-race", agentId: "main",
            principal: issued.principal, attribution: attribution))
    }

    func testExpiredDurableApprovalIsNeverUnknownWhileTheAuditAppendIsInFlight() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let grants = BotGrantStore(domainStore: store)
        let log = BlockingDecidedEventLog()
        let coordinator = BotApprovalCoordinator(
            grants: grants, eventWriter: BotMCPEventWriter(eventLog: log), eventLog: log,
            now: { 1_000 }, approvalTimeoutMs: 300_000, durableExpiryMs: 20)

        let call = try await makeCall()
        let effect = BotToolEffect(
            tool: "UpdateMemory", operation: "memory.delete",
            resource: "user:private.md", target: "user/private.md",
            mutability: .destructive, policy: .ask)
        let outcome = await coordinator.request(
            call: call, effects: [effect], action: "删除记忆", detail: "", command: "",
            alwaysScope: "until", persistence: .durable)
        XCTAssertTrue(outcome.pending, "a task approval must park as durable")
        let approvalID = try XCTUnwrap(outcome.approvalId)

        // The 20 ms expiry has removed the pending record and is suspended on
        // the audit append. Both reads must still answer from the recorded
        // terminal state, not fall through to `unknown`.
        await log.waitForBlockedAppend()
        let statusDuringAppend = await coordinator.durableStatus(approvalId: approvalID)
        XCTAssertEqual(statusDuringAppend, .expired)
        let resolveDuringAppend = await coordinator.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: call.attribution.argsDigest)
        XCTAssertEqual(resolveDuringAppend, .stale(reason: "expired"))
        await log.releaseBlockedAppend()

        // The terminal state is stable after the append lands too.
        let statusAfterAppend = await coordinator.durableStatus(approvalId: approvalID)
        XCTAssertEqual(statusAfterAppend, .expired)
        var persisted = false
        for _ in 0..<200 {
            if try await log.events(after: 0, limit: 100)
                .contains(where: { $0.type == "approval.decided" }) {
                persisted = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(persisted, "the expiry must still persist its durable decision")
    }
}

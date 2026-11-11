// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class RoutineAuthorityTests: XCTestCase {
    private func makeCreatedRoutine(_ fixture: BotMCPTestFixture) async throws -> Routine {
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        let created = try await registerAndExecute(
            fixture.runtime, name: "UpdateRoutine", arguments: .object([
                "action": .string("create"), "title": .string("Morning"),
                "prompt": .string("Report once"),
                "schedule": .string("@every 60m"),
                "completion_criteria": .string("列出三项变化"),
                "constraints": .string("没有变化时保持安静"),
            ]))
        await fixture.runtime.endTurn(sessionId: "gb-main")
        let id = try XCTUnwrap(created.structuredContent?["id"]?.stringValue)
        let routine = try await fixture.runtime.routineMachine.get(botId: "main", routineId: id)
        return try XCTUnwrap(routine)
    }

    func testUserTurnCreationRecordsCreatorCompletionAndConstraints() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let routine = try await makeCreatedRoutine(fixture)
        let creator = try XCTUnwrap(routine.creator)
        XCTAssertEqual(creator.origin, .user)
        XCTAssertEqual(creator.authorization, .userTurn)
        XCTAssertEqual(creator.rpcId, "bot-test")
        XCTAssertNil(creator.approvalID)
        XCTAssertEqual(routine.completionCriteria, "列出三项变化")
        XCTAssertEqual(routine.constraints, "没有变化时保持安静")
    }

    func testNonUserCreationWaitsForApprovalAndRecordsConfirmation() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        // No beginTurn: unknown source, like a hidden or asynchronous turn.
        let pending = Task {
            try await registerAndExecute(
                fixture.runtime, name: "UpdateRoutine", arguments: .object([
                    "action": .string("create"), "title": .string("Hidden"),
                    "prompt": .string("Report once"),
                    "schedule": .string("@every 60m"),
                ]))
        }
        let approvalID = try await waitForApproval(fixture.runtime)
        let hiddenBefore = try await fixture.runtime.routineMachine.list(botId: "main")
            .contains { $0.title == "Hidden" }
        XCTAssertFalse(hiddenBefore, "the routine exists before the user confirmed")
        let pendingDigest = await fixture.runtime.approvals.pendingDigest(approvalId: approvalID)
        let digest = try XCTUnwrap(pendingDigest)
        let resolution = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        XCTAssertEqual(resolution, .resolved)
        _ = try await pending.value
        let createdRoutine = try await fixture.runtime.routineMachine.list(botId: "main")
            .first { $0.title == "Hidden" }
        let routine = try XCTUnwrap(createdRoutine)
        let creator = try XCTUnwrap(routine.creator)
        XCTAssertEqual(creator.origin, .unknown)
        XCTAssertEqual(creator.authorization, .userConfirmed)
        XCTAssertEqual(creator.approvalID, approvalID)
    }

    func testDeniedApprovalDoesNotCreateARoutine() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let pending = Task {
            try await registerAndExecute(
                fixture.runtime, name: "UpdateRoutine", arguments: .object([
                    "action": .string("create"), "title": .string("Denied"),
                    "prompt": .string("Report once"), "schedule": .string("@every 60m"),
                ]))
        }
        let approvalID = try await waitForApproval(fixture.runtime)
        let pendingDigest = await fixture.runtime.approvals.pendingDigest(approvalId: approvalID)
        let digest = try XCTUnwrap(pendingDigest)
        _ = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .deny, digest: digest)
        let result = try await pending.value
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("permission_denied"))
        let remaining = try await fixture.runtime.routineMachine.list(botId: "main")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLooseningIsGatedButNarrowingRunsInline() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let routine = try await makeCreatedRoutine(fixture)
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        // No user turn: making it fire four times more often is widening.
        let pending = Task {
            try await registerAndExecute(
                fixture.runtime, name: "UpdateRoutine", arguments: .object([
                    "action": .string("update"), "routine_id": .string(routine.id),
                    "schedule": .string("@every 15m"),
                ]))
        }
        let approvalID = try await waitForApproval(fixture.runtime)
        let before = try await fixture.runtime.routineMachine.get(
            botId: "main", routineId: routine.id)
        XCTAssertEqual(before?.schedule.everyMinutes, 60)
        let pendingDigest = await fixture.runtime.approvals.pendingDigest(approvalId: approvalID)
        let digest = try XCTUnwrap(pendingDigest)
        _ = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        _ = try await pending.value
        let widened = try await fixture.runtime.routineMachine.get(
            botId: "main", routineId: routine.id)
        XCTAssertEqual(widened?.schedule.everyMinutes, 15)
        XCTAssertEqual(widened?.creator?.authorization, .userTurn,
                       "an update must not rewrite the original creator")

        // Slowing it down is not widening and runs without a card.
        let narrowed = try await registerAndExecute(
            fixture.runtime, name: "UpdateRoutine", arguments: .object([
                "action": .string("update"), "routine_id": .string(routine.id),
                "schedule": .string("@every 120m"),
            ]))
        XCTAssertNotEqual(narrowed.isError, true)
        let slowed = try await fixture.runtime.routineMachine.get(
            botId: "main", routineId: routine.id)
        XCTAssertEqual(slowed?.schedule.everyMinutes, 120)
        let pendingIDs = await fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(pendingIDs.isEmpty)
    }

    func testHeldTurnIsNotAUserTurnForRoutineAuthority() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.beginTurn(
            sessionId: "gb-main", hidden: false, held: true,
            origin: BotTurnOrigin(rpcId: "held:digest"))
        let pending = Task {
            try await registerAndExecute(
                fixture.runtime, name: "UpdateRoutine", arguments: .object([
                    "action": .string("create"), "title": .string("Held"),
                    "prompt": .string("Report once"), "schedule": .string("@every 60m"),
                ]))
        }
        let approvalID = try await waitForApproval(fixture.runtime)
        let pendingDigest = await fixture.runtime.approvals.pendingDigest(approvalId: approvalID)
        let digest = try XCTUnwrap(pendingDigest)
        _ = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce, digest: digest)
        _ = try await pending.value
        let createdRoutine = try await fixture.runtime.routineMachine.list(botId: "main").first
        let routine = try XCTUnwrap(createdRoutine)
        XCTAssertEqual(routine.creator?.origin, .held)
        XCTAssertEqual(routine.creator?.authorization, .userConfirmed)
        await fixture.runtime.endTurn(sessionId: "gb-main")
    }
}

func waitForApproval(_ runtime: BotMCPRuntime,
                     timeoutIterations: Int = 200) async throws -> String {
    for _ in 0..<timeoutIterations {
        if let id = await runtime.approvals.pendingIDs.first { return id }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw NSError(domain: "RoutineAuthorityTests", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "no approval card was presented"])
}

// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotTeammateAuthorityTests: XCTestCase {
    private func setup() async throws -> (BotMCPTestFixture, FakeBotTeamHost) {
        let fixture = try makeBotMCPFixture()
        _ = try await fixture.runtime.issueSession(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        let host = FakeBotTeamHost(roster: botTeamRoster())
        await fixture.runtime.registerTeamTools(BotTeamTools(host: host))
        return (fixture, host)
    }

    func testNonUserTurnRequiresApprovalAndRecordsTheAuthor() async throws {
        let (fixture, host) = try await setup()
        defer { fixture.cleanup() }
        let pending = Task {
            try await registerAndExecute(
                fixture.runtime, name: BotTeamTools.createTeammateName,
                arguments: .object([
                    "name": .string("Hidden teammate"),
                    "description": .string("watches the inbox"),
                ]),
                sessionId: "gb-bot-a")
        }
        let approvalID = try await waitForApproval(fixture.runtime)
        let createdBefore = await host.created
        XCTAssertTrue(createdBefore.isEmpty, "the Bot was created before the user confirmed")
        let pendingDigest = await fixture.runtime.approvals.pendingDigest(approvalId: approvalID)
        _ = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .allowOnce,
            digest: try XCTUnwrap(pendingDigest))
        let result = try await pending.value
        XCTAssertNotEqual(result.isError, true, String(describing: result))
        let created = await host.created
        XCTAssertEqual(created.map(\.name), ["Hidden teammate"])
        let author = await host.createdAuthors.last ?? nil
        let resolved = try XCTUnwrap(author)
        XCTAssertEqual(resolved.origin, .unknown)
        XCTAssertEqual(resolved.authorization, .userConfirmed)
        XCTAssertEqual(resolved.approvalID, approvalID)
        XCTAssertEqual(resolved.rpcId, nil)
    }

    func testUserTurnCreatesWithoutACardAndRecordsUserTurnAuthor() async throws {
        let (fixture, host) = try await setup()
        defer { fixture.cleanup() }
        await beginUserTurn(fixture.runtime, sessionId: "gb-bot-a", rpcId: "bot-main")
        let result = try await registerAndExecute(
            fixture.runtime, name: BotTeamTools.createTeammateName,
            arguments: .object(["name": .string("Visible teammate")]),
            sessionId: "gb-bot-a")
        await fixture.runtime.endTurn(sessionId: "gb-bot-a")
        XCTAssertNotEqual(result.isError, true, String(describing: result))
        let pendingIDs = await fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(pendingIDs.isEmpty)
        let author = await host.createdAuthors.last ?? nil
        let resolved = try XCTUnwrap(author)
        XCTAssertEqual(resolved.origin, .user)
        XCTAssertEqual(resolved.authorization, .userTurn)
        XCTAssertNil(resolved.approvalID)
        XCTAssertEqual(resolved.rpcId, "bot-main")
    }

    func testDeniedApprovalDoesNotCreateTheTeammate() async throws {
        let (fixture, host) = try await setup()
        defer { fixture.cleanup() }
        let pending = Task {
            try await registerAndExecute(
                fixture.runtime, name: BotTeamTools.createTeammateName,
                arguments: .object(["name": .string("Rejected teammate")]),
                sessionId: "gb-bot-a")
        }
        let approvalID = try await waitForApproval(fixture.runtime)
        let pendingDigest = await fixture.runtime.approvals.pendingDigest(approvalId: approvalID)
        _ = await fixture.runtime.approvals.resolve(
            approvalId: approvalID, decision: .deny,
            digest: try XCTUnwrap(pendingDigest))
        let result = try await pending.value
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("permission_denied"))
        let created = await host.created
        XCTAssertTrue(created.isEmpty)
    }

    func testNonUserAuthorWithoutApprovalIDIsRefusedLocally() async throws {
        let (fixture, host) = try await setup()
        defer { fixture.cleanup() }
        let tools = BotTeamTools(host: host)
        let authority = BotTurnAuthority(
            rpcId: "routine:run-1", turnId: "3", sessionId: "gb-bot-a",
            origin: .routine, isUserTurn: false)
        let result = await tools.execute(
            name: BotTeamTools.createTeammateName,
            arguments: .object(["name": .string("No approval")]),
            principal: botTeamPrincipal("bot-a"),
            context: BotMCPRequestContext(callId: "no-approval"),
            authority: authority)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("permission_denied"))
        let created = await host.created
        XCTAssertTrue(created.isEmpty)
    }
}

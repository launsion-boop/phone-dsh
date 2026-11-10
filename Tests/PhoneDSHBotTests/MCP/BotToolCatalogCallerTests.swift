// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// `tools/list` must use the same App-minted session identity as `tools/call`
/// attribution. These tests drive the real `BotMCPHandler` and the real
/// `BotTeamTools` catalog provider; no catalog is passed by hand.
final class BotToolCatalogCallerTests: XCTestCase {
    private func makeHandler() async throws -> (BotMCPTestFixture, BotMCPHandler) {
        let fixture = try makeBotMCPFixture()
        for (botID, sessionID) in [
            ("bot-a", "gb-bot-a"), ("bot-b", "gb-bot-b"),
            ("bot-c", "gb-bot-c"), ("bot-x", "gb-bot-x"),
        ] {
            _ = try await fixture.runtime.issueSession(
                botId: botID, sessionId: sessionID, kind: .chat)
        }
        await fixture.runtime.registerTeamTools(
            BotTeamTools(host: FakeBotTeamHost(roster: botTeamRoster())))
        return (fixture, BotMCPHandler(runtime: fixture.runtime))
    }

    private func list(_ handler: BotMCPHandler,
                      session: String? = nil) async throws -> [String: BotJSONValue] {
        var headers: [String: String] = [:]
        if let session {
            headers[BotMCPHandler.callerSessionHeader] = session
        }
        let response = await handler.rpc(
            method: "tools/list", params: .object([:]), id: .number(1), headers: headers)
        let tools = try XCTUnwrap(response["result"]?["tools"]?.arrayValue)
        return Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
            guard let name = tool["name"]?.stringValue else { return nil }
            return (name, tool)
        })
    }

    private func description(_ tools: [String: BotJSONValue],
                             _ name: String) -> String {
        tools[name]?["description"]?.stringValue ?? ""
    }

    func testMainBotSeesCreateTeammateAndAExcludingRoster() async throws {
        let (fixture, handler) = try await makeHandler()
        defer { fixture.cleanup() }

        let tools = try await list(handler, session: "gb-bot-a")
        XCTAssertNotNil(tools["CreateTeammate"])
        XCTAssertNotNil(tools["SendToAgent"])

        let send = description(tools, "SendToAgent")
        XCTAssertTrue(send.contains("Available bots: Bee (id: bot-b); Xray (id: bot-x)."))
        XCTAssertFalse(send.contains("Alpha"))
        XCTAssertFalse(send.contains("Hidden"))
        XCTAssertTrue(description(tools, "CreateTeammate")
            .contains("Available bots: Bee (id: bot-b); Xray (id: bot-x)."))
    }

    func testNonMainBotDoesNotSeeCreateTeammateAndSeesMainBot() async throws {
        let (fixture, handler) = try await makeHandler()
        defer { fixture.cleanup() }

        let tools = try await list(handler, session: "gb-bot-b")
        XCTAssertNil(tools["CreateTeammate"])
        XCTAssertNotNil(tools["SendToAgent"])

        let send = description(tools, "SendToAgent")
        XCTAssertTrue(send.contains(
            "Available bots: Alpha (id: bot-a, main Bot); Xray (id: bot-x)."))
        XCTAssertFalse(send.contains("Bee"))
        XCTAssertFalse(send.contains("Hidden"))
    }

    func testHiddenCallerIsExcludedAlongsideHiddenPeers() async throws {
        let (fixture, handler) = try await makeHandler()
        defer { fixture.cleanup() }

        let tools = try await list(handler, session: "gb-bot-c")
        XCTAssertNil(tools["CreateTeammate"])
        let send = description(tools, "SendToAgent")
        XCTAssertTrue(send.contains(
            "Available bots: Alpha (id: bot-a, main Bot); Bee (id: bot-b); Xray (id: bot-x)."))
        XCTAssertFalse(send.contains("Hidden"))
    }

    func testUnknownOrMissingIdentityFallsBackToTheStaticCatalog() async throws {
        let (fixture, handler) = try await makeHandler()
        defer { fixture.cleanup() }

        for session in [nil, "gb-does-not-exist", ""] as [String?] {
            let tools = try await list(handler, session: session)
            XCTAssertNotNil(tools["CreateTeammate"], "session \(session ?? "nil")")
            let send = description(tools, "SendToAgent")
            XCTAssertFalse(send.contains("Available bots:"), "session \(session ?? "nil")")
            XCTAssertEqual(tools.count, BotToolCatalog.allDefinitions.count)
        }
    }

    func testCatalogProviderChangesTheCatalogWithoutWiringTheApp() async throws {
        let roster = botTeamRoster()
        XCTAssertEqual(
            BotToolCatalog.allDefinitions(roster: roster, callerBotID: "bot-a").count,
            BotToolCatalog.allDefinitions.count)
        XCTAssertEqual(
            BotToolCatalog.allDefinitions(roster: roster, callerBotID: "bot-b").count,
            BotToolCatalog.allDefinitions.count - 1)
        XCTAssertEqual(
            BotToolCatalog.allDefinitions(roster: roster, callerBotID: nil).count,
            BotToolCatalog.allDefinitions.count)
    }

    func testHTTPHeaderSelectsTheCallerCatalog() async throws {
        let (fixture, handler) = try await makeHandler()
        defer { fixture.cleanup() }
        let server = BotMCPHTTPServer(handler: handler, token: "catalog-token")
        let url = try await server.start()
        defer { server.stop() }

        let main = try await postTools(url, token: "catalog-token", session: "gb-bot-a")
        XCTAssertTrue(main.contains("CreateTeammate"))
        let nonMain = try await postTools(url, token: "catalog-token", session: "gb-bot-b")
        XCTAssertFalse(nonMain.contains("CreateTeammate"))
        XCTAssertTrue(nonMain.contains("SendToAgent"))
        let anonymous = try await postTools(url, token: "catalog-token", session: nil)
        XCTAssertTrue(anonymous.contains("CreateTeammate"))
    }

    private func postTools(_ url: URL, token: String, session: String?) async throws -> [String] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let session {
            request.setValue(session, forHTTPHeaderField: BotMCPHandler.callerSessionHeader)
        }
        request.httpBody = try BotJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(7), "method": .string("tools/list"),
        ]).encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let value = try BotJSONValue.parse(data)
        return (value["result"]?["tools"]?.arrayValue ?? [])
            .compactMap { $0["name"]?.stringValue }
    }
}

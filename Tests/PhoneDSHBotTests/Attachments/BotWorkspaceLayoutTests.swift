// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotWorkspaceLayoutTests: XCTestCase {
    func testBotRootMatchesTheAgentsLayout() {
        XCTAssertEqual(
            BotWorkspaceLayout.botRoot(botId: "main"),
            "/dsh/workspace/.dshbot/agents/main")
        XCTAssertEqual(
            BotWorkspaceLayout.botRoot(botId: "team-1"),
            "/dsh/workspace/.dshbot/agents/team-1")
    }

    func testBotRootNeverEscapesTheDataDirectory() {
        XCTAssertEqual(
            BotWorkspaceLayout.botRoot(botId: "../main"),
            "/dsh/workspace/.dshbot/agents/.._main")
        XCTAssertEqual(
            BotWorkspaceLayout.botRoot(botId: "a/b"),
            "/dsh/workspace/.dshbot/agents/a_b")
        XCTAssertEqual(
            BotWorkspaceLayout.botRoot(botId: "."),
            "/dsh/workspace/.dshbot/agents/bot")
        XCTAssertEqual(
            BotWorkspaceLayout.botRoot(botId: ".."),
            "/dsh/workspace/.dshbot/agents/bot")
    }

    func testDataDirectoryTrailingSlashIsNormalized() {
        XCTAssertEqual(
            BotWorkspaceLayout.botRoot(botId: "main", dataDirectory: "/dsh/workspace/.dshbot/"),
            "/dsh/workspace/.dshbot/agents/main")
    }
}

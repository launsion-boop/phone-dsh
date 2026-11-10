// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFishDisplayContractTests: XCTestCase {
    func testFishActionToolCallNeverReachesTheTranscriptOrProcessList() {
        let projected = BotDisplayContract.project([
            "kind": .string("tool-call"),
            "toolName": .string("mcp__phone__FishAction"),
            "name": .string("FishAction"),
            "arguments": .object(["action": .string("happy")]),
        ])
        XCTAssertEqual(projected.surface, BotDisplayContract.hidden)
        XCTAssertFalse(projected.renderable)
        XCTAssertEqual(projected.wire.kind, "event")
        XCTAssertEqual(projected.wire.type, "tool-call")

        XCTAssertFalse(BotDisplayContract.isToolCallVisible(named: "FishAction"))
        XCTAssertFalse(BotDisplayContract.isToolCallVisible(named: "mcp__phone__FishAction"))
        XCTAssertFalse(BotDisplayContract.isToolCallVisible(named: "mcp__dshbot__FishAction"))
        XCTAssertTrue(BotDisplayContract.isToolCallVisible(named: "bash"))
        XCTAssertTrue(BotDisplayContract.isToolCallVisible(named: "mcp__phone__show_progress"))
        XCTAssertEqual(
            BotDisplayContract.visibleToolCallNames([
                "FishAction", "bash", "mcp__phone__FishAction", "mcp__phone__show_progress",
            ]),
            ["bash", "mcp__phone__show_progress"])
    }

    func testFishActionIsTheOnlyHiddenToolThusFar() {
        XCTAssertEqual(BotDisplayContract.hiddenToolNames, ["FishAction"])
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFishActionTests: XCTestCase {
    func testCatalogAdvertisesTheUpstreamReactionVocabulary() throws {
        XCTAssertEqual(BotToolCatalog.fishActions, [
            "waving", "bowing", "clapping", "kiss", "cheering", "shy", "smug", "crying",
            "sighing", "shaking-head", "stretching", "yawning", "high-five", "nod",
            "celebrate", "dancing",
        ])
        XCTAssertEqual(BotToolCatalog.fishExpressions, [
            "happy", "sad", "surprised", "confused", "laughing", "love", "angry", "wink",
        ])
        XCTAssertEqual(BotToolCatalog.fishReactions, BotToolCatalog.fishActions + BotToolCatalog.fishExpressions)

        let definition = try XCTUnwrap(BotToolCatalog.allDefinitions.first {
            $0.name == BotToolCatalog.fishActionName
        })
        XCTAssertEqual(BotToolCatalog.allDefinitions.filter { $0.name == "FishAction" }.count, 1)
        XCTAssertEqual(definition.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue),
                       ["action"])
        let properties = try XCTUnwrap(definition.inputSchema["properties"]?.objectValue)
        XCTAssertEqual(Array(properties.keys), ["action"])
        XCTAssertEqual(properties["action"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
                       BotFishReactionVocabulary.reactions)
        XCTAssertEqual(definition.inputSchema["additionalProperties"], .bool(false))
        for needle in [
            "at most once per reply",
            "only when the emotional beat genuinely fits",
            "never changes task state",
            "never use it as evidence that work is done",
            "Do not use it when the user asks for a plain, serious answer",
            "Actions: waving, bowing, clapping, kiss",
            "Expressions: happy, sad, surprised",
        ] {
            XCTAssertTrue(definition.description.contains(needle), "missing \(needle)")
        }
    }

    func testCatalogDoesNotLetTheGenericDispatchClaimFishAction() {
        // The catalog advertises FishAction, but its execution is a host tool
        // (like the team seam) so the generic dispatch switch cannot fall
        // through to `unknown_tool`.
        XCTAssertFalse(BotToolCatalog.definitions.contains { $0.name == "FishAction" })
        XCTAssertTrue(BotToolCatalog.allDefinitions.contains { $0.name == "FishAction" })
        XCTAssertFalse(BotToolCatalog.isRegistered("FishAction"))
        XCTAssertTrue(BotToolCatalog.isFishTool("FishAction"))
        XCTAssertTrue(BotToolCatalog.isFishTool("mcp__phone__FishAction"))
        XCTAssertFalse(BotToolCatalog.isFishTool("mcp__phone__UpdateMemory"))
    }

    func testHostToolPlaysOneReactionAndReturnsTheUpstreamText() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.registerFishActionTool()

        let result = try await registerAndExecute(
            fixture.runtime, name: "FishAction",
            arguments: .object(["action": .string("waving")]))
        XCTAssertNil(result.isError)
        XCTAssertEqual(result.structuredContent?["ok"], .bool(true))
        XCTAssertEqual(result.structuredContent?["action"], .string("waving"))
        XCTAssertEqual(result.structuredContent?["kind"], .string("action"))
        XCTAssertEqual(result.structuredContent?["durationMs"], .number(1_600))
        let text = result.content.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("已在界面播放「waving」"))
        XCTAssertTrue(text.contains("没有改变任何工作状态"))
        let events = try await botEvents(fixture.store)
        XCTAssertFalse(events.contains { $0.type == "approval.requested" },
                       "FishAction is auto-policy and must not ask for approval")
    }

    func testInvalidOrMissingActionFailsClosedWithoutStateChange() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.registerFishActionTool()

        let invalid = try await registerAndExecute(
            fixture.runtime, name: "FishAction",
            arguments: .object(["action": .string("moonwalk")]))
        XCTAssertEqual(invalid.isError, true)
        XCTAssertEqual(invalid.structuredContent?["error"]?["code"], .string("invalid_arguments"))
        let invalidText = invalid.content.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(invalidText.contains("不支持的动作「moonwalk」"))
        XCTAssertTrue(invalidText.contains("happy"))

        let missing = try await registerAndExecute(
            fixture.runtime, name: "FishAction", arguments: .object([:]))
        XCTAssertEqual(missing.isError, true)
        XCTAssertEqual(missing.structuredContent?["error"]?["code"], .string("invalid_arguments"))
    }

    func testEveryVocabularyValueExecutesThroughTheHostTool() async {
        let tool = BotFishActionTool()
        let principal = BotGatewayPrincipal(
            botId: "main", sessionId: "gb-main", kind: .chat, expiresAt: .max)
        let context = BotMCPRequestContext(callId: "fish-test")
        for action in BotFishReactionVocabulary.reactions {
            let result = await tool.execute(
                name: "mcp__phone__FishAction",
                arguments: .object(["action": .string(action)]),
                principal: principal, context: context)
            XCTAssertNil(result.isError, action)
            XCTAssertEqual(result.structuredContent?["action"], .string(action))
        }
    }
}

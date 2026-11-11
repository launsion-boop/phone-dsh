// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotAttachmentGoldenTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try RowTestSupport.golden("bot-attachments")
    }

    func testGoldenLimitsMatchPolicy() throws {
        let limits = try RowTestSupport.object(try fixture()["limits"], in: "bot-attachments.limits")
        XCTAssertEqual(limits["maxAttachments"] as? Int, BotAttachmentPolicy.maxCount)
        XCTAssertEqual((limits["maxBytes"] as? NSNumber)?.int64Value, BotAttachmentPolicy.maxBytes)
    }

    func testGoldenPromptBlockUsesTheFrozenPhoneBytes() throws {
        let fixture = try fixture()
        let prompt = try RowTestSupport.object(fixture["promptBlock"], in: "bot-attachments.promptBlock")
        let items = try RowTestSupport.decode([BotAttachment].self, prompt["items"])
        // The upstream file stays the Mac export. The phone overlay is the
        // authority for the bytes the model sees on iOS.
        let upstream = try XCTUnwrap(prompt["prompt"] as? String)
        XCTAssertTrue(upstream.contains("saved on this Mac"))
        let expectedBlock = try XCTUnwrap(fixture["promptBlockPhone"] as? String)
        XCTAssertTrue(expectedBlock.contains(BotAttachmentPrompt.explanation))
        XCTAssertEqual(BotAttachmentPrompt.block(items), expectedBlock)
        let empty = try XCTUnwrap(fixture["emptyBlock"] as? String)
        XCTAssertEqual(BotAttachmentPrompt.block([]), empty)
    }

    func testEveryGoldenSafeNameCaseUsesTheRealSanitizer() throws {
        let cases = try RowTestSupport.array(try fixture()["safeNameCases"], in: "bot-attachments.safeNameCases")
        XCTAssertFalse(cases.isEmpty)
        for (index, vector) in cases.enumerated() {
            let input = try XCTUnwrap(vector["input"] as? String)
            let expected = try XCTUnwrap(vector["safeName"] as? String)
            XCTAssertEqual(BotAttachmentPolicy.safeName(input), expected,
                           "safeNameCases[\(index)] \(input)")
        }
    }

    func testEveryGoldenImportPathCaseUsesTheRealWorkspaceLayout() throws {
        let cases = try RowTestSupport.array(try fixture()["importPathCases"], in: "bot-attachments.importPathCases")
        XCTAssertFalse(cases.isEmpty)
        for (index, vector) in cases.enumerated() {
            let botID = try XCTUnwrap(vector["botID"] as? String)
            let messageID = try XCTUnwrap(vector["messageID"] as? String)
            let expectedRoot = try XCTUnwrap(vector["botRoot"] as? String)
            let expectedDirectory = try XCTUnwrap(vector["directory"] as? String)
            let root = BotWorkspaceLayout.botRoot(botId: botID)
            XCTAssertEqual(root, expectedRoot, "importPathCases[\(index)].botRoot")
            XCTAssertEqual("\(root)/imports/attachments-\(messageID)", expectedDirectory,
                           "importPathCases[\(index)].directory")
        }
    }

    func testEveryGoldenParseVectorUsesTheRealParser() throws {
        let cases = try RowTestSupport.array(try fixture()["parse"], in: "bot-attachments.parse")
        XCTAssertEqual(cases.count, 4)
        for (index, vector) in cases.enumerated() {
            let input = try XCTUnwrap(vector["input"] as? String)
            let output = try RowTestSupport.object(vector["output"], in: "bot-attachments.parse[\(index)].output")
            let parsed = BotAttachmentPrompt.parse(input)
            XCTAssertEqual(parsed.text, output["text"] as? String, "input \(index)")
            let expected = try RowTestSupport.decode([BotAttachment].self, output["attachments"])
            XCTAssertEqual(parsed.attachments, expected, "input \(index)")
        }
    }

    func testTextWithoutMarkersIsReturnedUnchanged() {
        let text = "no attachments here"
        let parsed = BotAttachmentPrompt.parse(text)
        XCTAssertEqual(parsed.text, text)
        XCTAssertEqual(parsed.attachments, [])
    }

    func testEveryGoldenKindForVectorUsesTheRealClassifier() throws {
        let cases = try RowTestSupport.array(try fixture()["kindFor"], in: "bot-attachments.kindFor")
        XCTAssertEqual(cases.count, 8)
        for (index, vector) in cases.enumerated() {
            let name = try XCTUnwrap(vector["name"] as? String)
            let mimeType = try XCTUnwrap(vector["mimeType"] as? String)
            let expected = try XCTUnwrap(vector["kind"] as? String)
            XCTAssertEqual(BotAttachmentPolicy.kind(name: name, mimeType: mimeType), expected,
                           "kindFor[\(index)] \(name)")
        }
    }
}

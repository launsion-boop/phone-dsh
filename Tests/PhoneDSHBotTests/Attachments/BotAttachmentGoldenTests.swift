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

    func testGoldenPromptBlockUsesThePhoneExplanationAndExactJSONLines() throws {
        let prompt = try RowTestSupport.object(try fixture()["promptBlock"], in: "bot-attachments.promptBlock")
        let items = try RowTestSupport.decode([BotAttachment].self, prompt["items"])
        let upstream = try XCTUnwrap(prompt["prompt"] as? String)
        let mac = "The user attached these files. They are saved on this Mac; read them with your file tools when the task needs their contents."
        let phonePrompt = upstream.replacingOccurrences(of: mac, with: BotAttachmentPrompt.explanation)
        let text = try XCTUnwrap(prompt["text"] as? String)
        XCTAssertTrue(phonePrompt.hasPrefix(text))
        let expectedBlock = String(phonePrompt.dropFirst(text.count))
        XCTAssertEqual(BotAttachmentPrompt.block(items), expectedBlock)
        let empty = try XCTUnwrap(try fixture()["emptyBlock"] as? String)
        XCTAssertEqual(BotAttachmentPrompt.block([]), empty)
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

    func testSafeNameMatchesTheUpstreamRules() {
        XCTAssertEqual(BotAttachmentPolicy.safeName("a/b.png"), "b.png")
        XCTAssertEqual(BotAttachmentPolicy.safeName("a\\b.png"), "b.png")
        XCTAssertEqual(BotAttachmentPolicy.safeName(".hidden"), "hidden")
        XCTAssertEqual(BotAttachmentPolicy.safeName(""), "file")
        XCTAssertEqual(BotAttachmentPolicy.safeName("/"), "file")
        XCTAssertEqual(BotAttachmentPolicy.safeName("bad:name?.txt"), "bad_name_.txt")
        XCTAssertEqual(BotAttachmentPolicy.safeName("周报.pdf"), "周报.pdf")
        // dsh-bot replaces each non-BMP UTF-16 unit, so one emoji becomes "__".
        XCTAssertEqual(BotAttachmentPolicy.safeName("🐟.png"), "__.png")
        XCTAssertEqual(BotAttachmentPolicy.safeName(String(repeating: "a", count: 130)).count, 120)
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotContextProfilesTests: XCTestCase {
    func testFrozenProfilesAndRenderedYAMLMatchGoldenExactly() throws {
        let fixture = try botGolden("context-profiles")
        let document = try botDecode(BotContextProfileDocument.self, fixture["valid"]!)
        XCTAssertEqual(document, .frozen)
        XCTAssertEqual(document.profiles.default.compaction.thresholdRatio, 0.8)
        XCTAssertEqual(document.profiles.conservative.compaction.thresholdRatio, 0.4)
        XCTAssertEqual(document.profiles.default.spillPolicy.maxInlineTokens, 12_500)
        XCTAssertEqual(document.profiles.conservative.spillPolicy.maxInlineTokens, 4_096)
        XCTAssertEqual(BotContextProfileName.resolve("unknown"), .default)
        XCTAssertEqual(BotContextProfileName.resolve(nil), .default)
        XCTAssertEqual(BotContextProfileName.resolve(" CONSERVATIVE "), .conservative)
    }

    func testIndependentProfileCatalogContainsByteExactFrozenPatches() throws {
        let fixture = try botGolden("context-profiles")
        let document = try botDecode(BotContextProfileDocument.self, fixture["valid"]!)
        let url = botRepositoryRoot().appendingPathComponent("plugins/profile/bot-context.cordis.patch.yml")
        let catalog = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(try literalScalar(named: "default", in: catalog), document.yaml.default)
        XCTAssertEqual(try literalScalar(named: "conservative", in: catalog), document.yaml.conservative)
        XCTAssertFalse(catalog.contains("process.env"))
    }

    private func literalScalar(named name: String, in catalog: String) throws -> String {
        let lines = catalog.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "\(name): |") else {
            XCTFail("missing profile \(name)")
            return ""
        }
        var content: [String] = []
        for line in lines[(start + 1)...] {
            if !line.hasPrefix(" ") && !line.isEmpty { break }
            content.append(line.hasPrefix("  ") ? String(line.dropFirst(2)) : line)
        }
        while content.last == "" { content.removeLast() }
        return content.joined(separator: "\n") + "\n"
    }
}

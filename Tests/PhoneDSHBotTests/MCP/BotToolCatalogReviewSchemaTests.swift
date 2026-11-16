// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Q-01: the model-facing UpdateMemory schema must expose the same optional
/// `review` object the frozen write contract accepts. Without this, an agent
/// following the description could not send `review` at all because the tool
/// schema is closed.
final class BotToolCatalogReviewSchemaTests: XCTestCase {
    func testUpdateMemoryInputSchemaExposesTheFrozenReviewObject() throws {
        let definition = try XCTUnwrap(
            BotToolCatalog.allDefinitions.first { $0.name == "UpdateMemory" })
        let properties = try XCTUnwrap(definition.inputSchema["properties"]?.objectValue)
        let review = try XCTUnwrap(properties["review"]?.objectValue)
        XCTAssertEqual(review["type"]?.stringValue, "object")
        XCTAssertEqual(review["additionalProperties"]?.boolValue, false)
        XCTAssertEqual(
            review["required"]?.arrayValue?.compactMap(\.stringValue),
            ["state", "basis"])

        let reviewProperties = try XCTUnwrap(review["properties"]?.objectValue)
        XCTAssertEqual(
            reviewProperties["state"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
            ["verified", "unverified", "disputed"])
        XCTAssertEqual(
            reviewProperties["basis"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
            ["user-statement", "observation", "record-recheck", "model-inference"])
        XCTAssertEqual(reviewProperties["method"]?["maxLength"]?.intValue, 200)
        XCTAssertEqual(reviewProperties["at_ms"]?["minimum"]?.intValue, 0)
        XCTAssertEqual(reviewProperties["refs"]?["maxItems"]?.intValue, 8)
        XCTAssertFalse(definition.description.isEmpty)
    }
}

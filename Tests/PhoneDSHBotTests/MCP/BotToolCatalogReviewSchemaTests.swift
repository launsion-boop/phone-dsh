// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Q-01/Q-09: the model-facing UpdateMemory schema must be structurally the
/// same as the r5/r7 frozen golden (`memory.updateMemory.review`), not a
/// hand-written copy that can drift. Q-10's MCP direction test covers the
/// request path but does not validate input against this schema.
final class BotToolCatalogReviewSchemaTests: XCTestCase {
    func testUpdateMemoryInputSchemaExposesTheFrozenReviewObject() throws {
        let definition = try XCTUnwrap(
            BotToolCatalog.allDefinitions.first { $0.name == "UpdateMemory" })
        let properties = try XCTUnwrap(definition.inputSchema["properties"]?.objectValue)
        let review = try XCTUnwrap(properties["review"]?.objectValue)

        let fixture = try RowTestSupport.golden("tool-catalog.phone")
        let memory = try RowTestSupport.object(fixture["memory"], in: "tool-catalog.phone.memory")
        let update = try RowTestSupport.object(
            memory["updateMemory"], in: "tool-catalog.phone.memory.updateMemory")
        let expected = try RowTestSupport.object(
            update["review"], in: "tool-catalog.phone.memory.updateMemory.review")

        XCTAssertEqual(review["type"]?.stringValue, expected["type"] as? String)
        XCTAssertEqual(review["additionalProperties"]?.boolValue,
                       expected["additionalProperties"] as? Bool)
        XCTAssertEqual(review["required"]?.arrayValue?.compactMap(\.stringValue),
                       expected["required"] as? [String])

        let reviewProperties = try XCTUnwrap(review["properties"]?.objectValue)
        let expectedProperties = try RowTestSupport.object(
            expected["properties"], in: "tool-catalog.phone.memory.updateMemory.review.properties")
        let expectedStates = try RowTestSupport.object(
            expectedProperties["state"], in: "review.state")["enum"] as? [String]
        let expectedBases = try RowTestSupport.object(
            expectedProperties["basis"], in: "review.basis")["enum"] as? [String]
        XCTAssertEqual(
            reviewProperties["state"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
            expectedStates)
        XCTAssertEqual(
            reviewProperties["basis"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
            expectedBases)

        let method = try RowTestSupport.object(expectedProperties["method"], in: "review.method")
        XCTAssertEqual(reviewProperties["method"]?["minLength"]?.intValue,
                       method["minLength"] as? Int)
        XCTAssertEqual(reviewProperties["method"]?["maxLength"]?.intValue,
                       method["maxLength"] as? Int)

        let at = try RowTestSupport.object(expectedProperties["at_ms"], in: "review.at_ms")
        XCTAssertEqual(reviewProperties["at_ms"]?["minimum"]?.intValue, at["minimum"] as? Int)

        let refs = try RowTestSupport.object(expectedProperties["refs"], in: "review.refs")
        XCTAssertEqual(reviewProperties["refs"]?["maxItems"]?.intValue, refs["maxItems"] as? Int)
        let items = try RowTestSupport.object(refs["items"], in: "review.refs.items")
        let expectedOneOf = try RowTestSupport.array(items["oneOf"], in: "review.refs.items.oneOf")
        let oneOf = try XCTUnwrap(
            reviewProperties["refs"]?["items"]?["oneOf"]?.arrayValue)
        XCTAssertEqual(oneOf.count, expectedOneOf.count)
        for (index, entry) in expectedOneOf.enumerated() {
            let actual = try XCTUnwrap(oneOf[index].objectValue)
            XCTAssertEqual(actual["type"]?.stringValue, entry["type"] as? String)
            XCTAssertEqual(actual["const"]?.stringValue, entry["const"] as? String)
            XCTAssertEqual(actual["pattern"]?.stringValue, entry["pattern"] as? String)
            XCTAssertEqual(actual["maxLength"]?.intValue, entry["maxLength"] as? Int)
        }
    }
}

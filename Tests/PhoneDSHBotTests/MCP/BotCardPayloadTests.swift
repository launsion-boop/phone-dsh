// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotCardPayloadTests: XCTestCase {
    private struct Vector: Decodable {
        let valid: [Call]
        let invalid: [Call]
    }
    private struct Call: Decodable {
        let tool: String
        let args: BotJSONValue
        let result: BotJSONValue
    }

    func testP0CardsMatchUpstreamGolden() throws {
        let vector = try golden("card-payload")
        for call in vector.valid where call.tool.hasPrefix("show_") || call.tool == "ask_user" {
            if BotToolCatalog.p1TargetNames.contains(call.tool) {
                XCTAssertThrowsError(try BotCardPayloads.build(tool: call.tool, arguments: call.args))
                continue
            }
            let built = try BotCardPayloads.build(tool: call.tool, arguments: call.args)
            // `card-payload.json` is the untouched exporter output; the phone
            // delta (host option ids) is asserted against the separate file.
            if call.tool == "ask_user" || call.tool == "show_next_steps" {
                XCTAssertEqual(strippingChoiceIDs(built), call.result, call.tool)
            } else {
                XCTAssertEqual(built, call.result, call.tool)
            }
        }
        for call in vector.invalid {
            XCTAssertThrowsError(try BotCardPayloads.build(tool: call.tool, arguments: call.args)) { error in
                guard case BotCardPayloadError.invalid(let message) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(message, call.result["error"]?.stringValue)
            }
        }
    }

    /// R4: the phoneDSH delta lives in its own vector file and is compared
    /// against the real builder, including the option ids, the recommended
    /// reordering and the negative fixtures.
    func testP0CardsMatchPhoneDeltaGolden() throws {
        let vector = try golden("card-payload.phone")
        XCTAssertFalse(vector.valid.isEmpty)
        for call in vector.valid {
            if BotToolCatalog.p1TargetNames.contains(call.tool) {
                XCTAssertThrowsError(try BotCardPayloads.build(tool: call.tool, arguments: call.args))
                continue
            }
            XCTAssertEqual(try BotCardPayloads.build(tool: call.tool, arguments: call.args),
                           call.result, call.tool)
        }
        for call in vector.invalid {
            XCTAssertThrowsError(try BotCardPayloads.build(tool: call.tool, arguments: call.args)) { error in
                guard case BotCardPayloadError.invalid(let message) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(message, call.result["error"]?.stringValue)
            }
        }
    }

    private func strippingChoiceIDs(_ value: BotJSONValue) -> BotJSONValue {
        guard case .object(var result) = value, case .object(var card)? = result["card"] else {
            return value
        }
        for key in ["options", "steps"] {
            guard case .array(let items)? = card[key] else { continue }
            card[key] = .array(items.map { item in
                guard case .object(var fields) = item else { return item }
                fields.removeValue(forKey: "id")
                return .object(fields)
            })
        }
        result["card"] = .object(card)
        return .object(result)
    }

    func testProgressUsesStableCardKeyAndValidatesRecommendations() throws {
        let first = try BotCardPayloads.build(tool: "show_progress", arguments: .object([
            "title": .string("Generate"), "state": .string("running"),
        ]))
        let second = try BotCardPayloads.build(tool: "show_progress", arguments: .object([
            "title": .string("Generate"), "state": .string("done"),
        ]))
        XCTAssertEqual(first["card"]?["cardKey"], second["card"]?["cardKey"])
        XCTAssertEqual(second["card"]?["percent"], .number(100))
        let normalized = try BotCardPayloads.build(tool: "ask_user", arguments: .object([
            "question": .string("Choose"),
            "options": .array([
                .object(["label": .string("A"), "recommended": .bool(true)]),
                .object(["label": .string("B"), "style": .string("primary")]),
            ]),
        ]))
        let options = try XCTUnwrap(normalized["card"]?["options"]?.arrayValue)
        XCTAssertEqual(options.map { $0["id"]?.stringValue }, ["o0", "o1"])
        XCTAssertEqual(options[0]["recommended"], .bool(true))
        XCTAssertNil(options[1]["recommended"])
        XCTAssertEqual(options[1]["style"], .string("default"))
        let danger = try BotCardPayloads.build(tool: "show_next_steps", arguments: .object([
            "steps": .array([
                .object(["label": .string("A"), "style": .string("danger"), "recommended": .bool(true)]),
                .string("B"),
            ]),
        ]))
        let steps = try XCTUnwrap(danger["card"]?["steps"]?.arrayValue)
        XCTAssertEqual(steps.map { $0["id"]?.stringValue }, ["o0", "o1"])
        XCTAssertNil(steps[0]["recommended"])
        XCTAssertEqual(steps[0]["style"], .string("danger"))
    }

    func testPlainDocumentUsesAChineseTypeLabelWithoutDuplication() throws {
        let built = try BotCardPayloads.build(tool: "show_document", arguments: .object([
            "path": .string("/dsh/workspace/.dshbot/agents/main/notes/sim-int-2-f.md"),
            "kind": .string("document"),
        ]))
        XCTAssertEqual(built["card"]?["docKind"], .string("document"))
        XCTAssertEqual(built["card"]?["docTypeLabel"], .string("文档"))
        XCTAssertEqual(built["card"]?["title"], .string("sim-int-2-f.md"))
    }

    func testContentCardFinalIsAcceptedValidatedAndStripped() throws {
        let cases: [(String, [String: BotJSONValue])] = [
            ("show_progress", ["title": .string("Wrap up"), "state": .string("done")]),
            ("show_checklist", ["title": .string("Release"), "items": .array([.object(["text": .string("Test")])])]),
            ("show_link", ["links": .array([.object(["url": .string("https://example.test/docs")])])]),
            ("show_attachment", ["path": .string("/tmp/report.txt")]),
            ("show_document", ["title": .string("Report"), "content": .string("# Report")]),
        ]
        for (tool, base) in cases {
            var final = base
            final["final"] = .bool(true)
            let built = try BotCardPayloads.build(tool: tool, arguments: .object(final))
            XCTAssertNil(built["card"]?["final"], "\(tool) must strip final from the payload")
            XCTAssertEqual(try BotCardPayloads.contentCardFinal(tool: tool, arguments: .object(final)),
                           true, tool)
            var omitted = base
            XCTAssertEqual(try BotCardPayloads.contentCardFinal(tool: tool, arguments: .object(omitted)), false)
            omitted["final"] = .bool(false)
            XCTAssertEqual(try BotCardPayloads.contentCardFinal(tool: tool, arguments: .object(omitted)), false)
            var invalid = base
            invalid["final"] = .string("yes")
            XCTAssertThrowsError(try BotCardPayloads.build(tool: tool, arguments: .object(invalid))) { error in
                guard case BotCardPayloadError.invalid(let message) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(message, "final 必须是 boolean。")
            }
        }
        // ask_user/show_next_steps already end the turn; `final` is not their flag.
        XCTAssertFalse(try BotCardPayloads.contentCardFinal(
            tool: "ask_user",
            arguments: .object(["question": .string("Continue?"), "options": .array([]), "final": .bool(true)])))
    }

    func testContentCardsAdvertiseTheOptionalFinalFlag() {
        let byName = Dictionary(uniqueKeysWithValues: BotToolCatalog.definitions.map { ($0.name, $0) })
        for name in BotToolCatalog.contentCardNames {
            let schema = byName[name]?.inputSchema
            XCTAssertEqual(schema?["properties"]?["final"]?["type"], .string("boolean"), name)
            XCTAssertEqual(schema?["properties"]?["final"]?["default"], .bool(false), name)
            let required = schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            XCTAssertFalse(required.contains("final"), "\(name) must keep final optional")
        }
        for name in ["ask_user", "show_next_steps"] {
            XCTAssertNil(byName[name]?.inputSchema["properties"]?["final"], name)
        }
    }

    func testContentCardFinalMatchesThePhoneCatalogGolden() throws {
        let fixture = try RowTestSupport.golden("tool-catalog.phone")
        let valid = try RowTestSupport.object(fixture["valid"], in: "tool-catalog.phone.valid")
        let p0 = try RowTestSupport.array(valid["p0"], in: "tool-catalog.phone.valid.p0")
        let runtime = Dictionary(uniqueKeysWithValues: BotToolCatalog.definitions.map { ($0.name, $0) })
        var checked = Set<String>()
        for entry in p0 {
            guard let name = entry["name"] as? String,
                  BotToolCatalog.contentCardNames.contains(name) else { continue }
            checked.insert(name)
            let expected = try RowTestSupport.decode(
                BotJSONValue.self, entry["inputSchema"])["properties"]?["final"]
            XCTAssertEqual(runtime[name]?.inputSchema["properties"]?["final"], expected, name)
        }
        XCTAssertEqual(checked, BotToolCatalog.contentCardNames)
    }

    func testCatalogRegistersExactlyP0AndVolatileContext() {
        XCTAssertEqual(BotToolCatalog.definitions.map(\.name), BotToolCatalog.p0Names)
        XCTAssertEqual(BotToolCatalog.allDefinitions.count, BotToolCatalog.p0Names.count + 5)
        for name in BotToolCatalog.p1TargetNames + ["show_canvas", "show_product", "show_gift", "GenerateImage"] {
            XCTAssertFalse(BotToolCatalog.isRegistered(name))
        }
        XCTAssertEqual(BotToolCatalog.volatileContextDefinition.name, "BotVolatileContext")
    }

    func testRecommendationNormalizationMovesTheChosenOptionFirst() throws {
        let multiple = try BotCardPayloads.build(tool: "ask_user", arguments: .object([
            "question": .string("Choose"),
            "options": .array([
                .object(["label": .string("A"), "recommended": .bool(true)]),
                .object(["label": .string("B"), "recommended": .bool(true)]),
            ]),
        ]))
        let multipleOptions = try XCTUnwrap(multiple["card"]?["options"]?.arrayValue)
        XCTAssertEqual(multipleOptions.map { $0["label"]?.stringValue }, ["A", "B"])
        XCTAssertEqual(multipleOptions.map { $0["id"]?.stringValue }, ["o0", "o1"])
        XCTAssertEqual(multipleOptions[0]["recommended"], .bool(true))
        XCTAssertNil(multipleOptions[1]["recommended"])

        let danger = try BotCardPayloads.build(tool: "ask_user", arguments: .object([
            "question": .string("Choose"),
            "options": .array([
                .object(["label": .string("Delete"), "style": .string("danger"), "recommended": .bool(true)]),
                .object(["label": .string("Keep"), "recommended": .bool(true)]),
            ]),
        ]))
        let dangerOptions = try XCTUnwrap(danger["card"]?["options"]?.arrayValue)
        XCTAssertEqual(dangerOptions.map { $0["label"]?.stringValue }, ["Keep", "Delete"])
        XCTAssertEqual(dangerOptions[0]["id"], .string("o0"))
        XCTAssertEqual(dangerOptions[0]["recommended"], .bool(true))
        XCTAssertNil(dangerOptions[1]["recommended"])
        XCTAssertEqual(dangerOptions[1]["style"], .string("danger"))

        let last = try BotCardPayloads.build(tool: "show_next_steps", arguments: .object([
            "steps": .array([
                .object(["label": .string("A")]),
                .object(["label": .string("B"), "recommended": .bool(true)]),
            ]),
        ]))
        let reordered = try XCTUnwrap(last["card"]?["steps"]?.arrayValue)
        XCTAssertEqual(reordered.map { $0["label"]?.stringValue }, ["B", "A"])
        XCTAssertEqual(reordered.map { $0["id"]?.stringValue }, ["o0", "o1"])
    }

    func testToolsListMatchesSharedGolden() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let listed = await handler.rpc(
            method: "tools/list", params: .object([:]), id: .number(1))
        let tools = try XCTUnwrap(listed["result"]?["tools"]?.arrayValue)
        XCTAssertTrue(tools.contains { $0["name"]?.stringValue == BotToolCatalog.volatileContextName })
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool -> (String, BotJSONValue)? in
            guard let name = tool["name"]?.stringValue else { return nil }
            return (name, tool)
        })

        let golden = try RowTestSupport.golden("tool-catalog")
        let valid = try RowTestSupport.object(golden["valid"], in: "tool-catalog.valid")
        let p0 = try RowTestSupport.array(valid["p0"], in: "tool-catalog.valid.p0")
        for expected in p0 {
            let name = try XCTUnwrap(expected["name"] as? String)
            let definition = try XCTUnwrap(byName[name], "tools/list is missing \(name)")
            let expectedSchema = try XCTUnwrap(expected["inputSchema"] as? [String: Any])
            let expectedRequired = expectedSchema["required"] as? [String] ?? []
            let actualRequired = definition["inputSchema"]?["required"]?.arrayValue?
                .compactMap { $0.stringValue } ?? []
            if name == "UpdateMemory" {
                // The upstream v1 golden predates the v2 document-tree tool.
                XCTAssertEqual(actualRequired, ["action", "path", "expected_version"])
            } else {
                XCTAssertEqual(actualRequired, expectedRequired, "tools/list required mismatch for \(name)")
            }
            XCTAssertFalse(definition["description"]?.stringValue?.isEmpty ?? true)
        }

        for name in ["ask_user", "show_next_steps"] {
            let description = try XCTUnwrap(byName[name]?["description"]?.stringValue)
            XCTAssertTrue(description.contains("at most one"), "\(name) must cap recommendations")
            XCTAssertTrue(description.contains("never recommend a danger"), "\(name) must exclude danger")
            XCTAssertTrue(description.contains("first"), "\(name) must put the recommendation first")
        }
    }

    func testCatalogRegistersP0AndVolatileContext() {
        XCTAssertEqual(Array(BotToolCatalog.definitions.prefix(BotToolCatalog.p0Names.count)).map(\.name),
                       BotToolCatalog.p0Names)
        for name in BotToolCatalog.p0Names {
            XCTAssertTrue(BotToolCatalog.isRegistered(name))
        }
        XCTAssertTrue(BotToolCatalog.allDefinitions.contains {
            $0.name == BotToolCatalog.volatileContextName
        })
        for name in BotToolCatalog.p1TargetNames + ["show_canvas", "show_product", "show_gift", "GenerateImage"] {
            XCTAssertFalse(BotToolCatalog.isRegistered(name))
        }
        XCTAssertEqual(BotToolCatalog.volatileContextDefinition.name, "BotVolatileContext")
    }

    private func golden(_ name: String) throws -> Vector {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Vector.self,
            from: Data(contentsOf: root.appendingPathComponent("spec/bot/v1/golden/\(name).json")))
    }
}

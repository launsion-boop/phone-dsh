// SPDX-License-Identifier: MIT
// Runtime conformance for spec/device/v1/device-panel.md §2 and §4.2
// (contract revision spec/device/v1/device-panel.md@5ed9d78d3f2b5c7eb22c8301dc3f39c98ee1bcec).
//
// Every shared golden vector is read from the repository and driven through the
// REAL classifier (`classifyDevicePanelTool`) and descriptor evaluator
// (`evaluateDevicePanelDescriptor`) — there is no hand-written copy of either in
// this file. The vector line counts are asserted before iterating so an empty or
// truncated read cannot make the suite pass. `testFlippedExpectationsAreCaught`
// flips real expected values and proves the same comparisons reject them.
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBLE

final class DevicePanelVectorTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let golden = repoRoot.appendingPathComponent("spec/device/v1/golden")

    // MARK: - Vector loading

    private func rows(_ name: String) throws -> [JSONValue] {
        let text = try String(
            contentsOf: Self.golden.appendingPathComponent(name), encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map { try JSONValue.parse(Data($0.utf8)) }
    }

    private func mappingRows() throws -> [JSONValue] {
        let rows = try rows("device-panel-mapping.jsonl")
        XCTAssertEqual(rows.count, 44, "device-panel-mapping.jsonl must hold 44 vectors")
        return rows
    }

    private func descriptorRows() throws -> [JSONValue] {
        let rows = try rows("device-panel-descriptor-cases.jsonl")
        XCTAssertEqual(rows.count, 62, "device-panel-descriptor-cases.jsonl must hold 62 vectors")
        return rows
    }

    // MARK: - Expected value shapes

    /// The mapping vector's `editors` entry with an exact member set; a vector
    /// that adds or drops a member is rejected rather than compared loosely.
    private enum VectorEditor: Equatable {
        case toggle(arg: String, required: Bool)
        case slider(arg: String, required: Bool, integer: Bool, minimum: Double, maximum: Double)
        case picker(arg: String, required: Bool, options: [String])
    }

    private static func vectorEditor(_ value: JSONValue) -> VectorEditor? {
        guard case .object(var object) = value else { return nil }
        object.removeValue(forKey: "title")   // compared separately (devicePanelEditorTitles)
        guard
              case .string(let arg)? = object["arg"],
              case .string(let kind)? = object["kind"],
              case .bool(let required)? = object["required"] else { return nil }
        switch kind {
        case "toggle":
            guard Set(object.keys) == Set(["arg", "kind", "required"]) else { return nil }
            return .toggle(arg: arg, required: required)
        case "slider":
            guard Set(object.keys) == Set(["arg", "kind", "required", "integer", "min", "max"]),
                  case .bool(let integer)? = object["integer"],
                  case .number(let minimum)? = object["min"],
                  case .number(let maximum)? = object["max"] else { return nil }
            return .slider(
                arg: arg, required: required, integer: integer, minimum: minimum, maximum: maximum)
        case "picker":
            guard Set(object.keys) == Set(["arg", "kind", "required", "options"]),
                  case .array(let optionValues)? = object["options"] else { return nil }
            var options: [String] = []
            for optionValue in optionValues {
                guard case .string(let option) = optionValue else { return nil }
                options.append(option)
            }
            return .picker(arg: arg, required: required, options: options)
        default:
            return nil
        }
    }

    private static func vectorEditor(_ editor: DevicePanelEditor) -> VectorEditor {
        switch editor {
        case .toggle(let arg, let required):
            return .toggle(arg: arg, required: required)
        case .slider(let arg, let required, let integer, let minimum, let maximum):
            return .slider(
                arg: arg, required: required, integer: integer, minimum: minimum, maximum: maximum)
        case .picker(let arg, let required, let options):
            return .picker(arg: arg, required: required, options: options)
        }
    }

    // MARK: - One-vector comparisons (shared by the real check and the mutation check)

    /// `nil` when the real classifier reproduces this vector, otherwise a
    /// description of the first mismatch.
    private static func mappingMismatch(_ row: JSONValue) -> String? {
        guard case .object(let object) = row,
              case .string(let name)? = object["name"],
              let inputSchema = object["input_schema"],
              case .string(let expectedRender)? = object["render"],
              case .array(let expectedEditorValues)? = object["editors"] else {
            return "malformed mapping vector row"
        }
        let render = classifyDevicePanelTool(inputSchema: inputSchema)
        switch (expectedRender, render) {
        case ("agent_only", .agentOnly):
            guard expectedEditorValues.isEmpty else {
                return "\(name): agent_only vector carries editors"
            }
            return nil
        case ("editors", .editors(let editors)):
            var expected: [VectorEditor] = []
            for value in expectedEditorValues {
                guard let editor = vectorEditor(value) else {
                    return "\(name): malformed expected editor \(value)"
                }
                expected.append(editor)
            }
            let actual = editors.map(vectorEditor)
            guard actual == expected else {
                return "\(name): editors \(actual) != expected \(expected)"
            }
            var expectedTitles: [String: String] = [:]
            for value in expectedEditorValues {
                if case .string(let arg)? = value["arg"], case .string(let title)? = value["title"] { expectedTitles[arg] = title }
            }
            let titles = devicePanelEditorTitles(inputSchema: inputSchema)
            guard titles == expectedTitles else {
                return "\(name): titles \(titles) != expected \(expectedTitles)"
            }
            return nil
        default:
            return "\(name): render \(render) != expected \(expectedRender)"
        }
    }

    /// `nil` when the real evaluator reproduces this vector, otherwise a
    /// description of the first mismatch. The descriptor value must be non-nil
    /// exactly when the result is `.ok`.
    private static func descriptorMismatch(_ row: JSONValue) -> String? {
        guard case .object(let object) = row,
              case .string(let name)? = object["name"],
              case .string(let descriptorText)? = object["descriptor"],
              case .string(let expectedResult)? = object["result"],
              case .string(let deviceID)? = object["device_id"],
              case .array(let tools)? = object["tools"] else {
            return "malformed descriptor vector row"
        }
        guard let knownResult = DevicePanelDescriptorResult(rawValue: expectedResult) else {
            return "\(name): unknown expected result \(expectedResult)"
        }
        let (result, descriptor) = evaluateDevicePanelDescriptor(
            Data(descriptorText.utf8), linkDeviceID: deviceID, tools: tools)
        guard result == knownResult else {
            return "\(name): result \(result.rawValue) != expected \(expectedResult)"
        }
        guard (result == .ok) == (descriptor != nil) else {
            return "\(name): descriptor presence does not match result \(result.rawValue)"
        }
        guard let descriptor else { return nil }

        // For an `ok` row the descriptor text itself carries the expected title,
        // labels, groups and presets. Recover them from the same decoded text the
        // evaluator receives and compare what the evaluator produced.
        guard let document = try? JSONValue.parse(Data(descriptorText.utf8)),
              case .object(let documentObject) = document,
              case .array(let expectedControls)? = documentObject["controls"] else {
            return "\(name): ok vector's descriptor does not parse"
        }
        guard descriptor.title == documentObject["title"]?.stringValue else {
            return "\(name): title \(String(describing: descriptor.title)) != expected " +
                "\(String(describing: documentObject["title"]?.stringValue))"
        }
        guard descriptor.controls.count == expectedControls.count else {
            return "\(name): \(descriptor.controls.count) controls != \(expectedControls.count)"
        }
        for (index, pair) in zip(descriptor.controls, expectedControls).enumerated() {
            let (control, expectedValue) = pair
            guard case .object(let expected) = expectedValue,
                  case .string(let tool)? = expected["tool"],
                  case .string(let label)? = expected["label"] else {
                return "\(name): control \(index) is malformed"
            }
            guard control.tool == tool, control.label == label else {
                return "\(name): control \(index) \(control.tool)/\(control.label) != \(tool)/\(label)"
            }
            guard control.group == expected["group"]?.stringValue else {
                return "\(name): control \(index) group \(String(describing: control.group)) != " +
                    "\(String(describing: expected["group"]?.stringValue))"
            }
            guard control.preset == expected["preset"] else {
                return "\(name): control \(index) preset \(String(describing: control.preset)) != " +
                    "\(String(describing: expected["preset"]))"
            }
        }
        return nil
    }

    // MARK: - Every shared vector

    func testEveryMappingVectorMatchesTheRealClassifier() throws {
        let vectors = try mappingRows()
        XCTAssertEqual(vectors.count, 44)
        for row in vectors {
            let name = row["name"]?.stringValue ?? "<unnamed>"
            XCTAssertNil(Self.mappingMismatch(row), name)
        }
        // The vectors must actually exercise the whole §2 result space; a green
        // run over only `agent_only` rows would not prove much.
        let renders = Set(vectors.compactMap { $0["render"]?.stringValue })
        XCTAssertEqual(renders, ["editors", "agent_only"])
        let kinds = Set(vectors.compactMap { row -> Set<String>? in
            guard case .array(let editors)? = row["editors"] else { return nil }
            return Set(editors.compactMap { $0["kind"]?.stringValue })
        }.flatMap { $0 })
        XCTAssertEqual(kinds, ["toggle", "slider", "picker"])
        XCTAssertTrue(vectors.contains { row in
            guard case .array(let editors)? = row["editors"] else { return false }
            return row["render"]?.stringValue == "editors" && editors.isEmpty
        }, "the empty-properties tool must be covered")
    }

    func testEveryDescriptorVectorMatchesTheRealEvaluator() throws {
        let vectors = try descriptorRows()
        XCTAssertEqual(vectors.count, 62)
        for row in vectors {
            let name = row["name"]?.stringValue ?? "<unnamed>"
            XCTAssertNil(Self.descriptorMismatch(row), name)
        }
        // Every result code, including `ok`, must be represented by a vector.
        let results = Set(vectors.compactMap { $0["result"]?.stringValue })
        XCTAssertEqual(results, Set(DevicePanelDescriptorResult.allCases.map(\.rawValue)))
    }

    // MARK: - Mutation: the comparisons above are not vacuous

    func testFlippedExpectationsAreCaught() throws {
        let mapping = try mappingRows()
        let descriptor = try descriptorRows()

        // 1. Flip an `editors` row to `agent_only`.
        let editorsRow = try XCTUnwrap(mapping.first {
            $0["name"]?.stringValue == "light_set" && $0["render"]?.stringValue == "editors"
        })
        XCTAssertNotNil(Self.mappingMismatch(
            Self.replacing(editorsRow, "render", with: .string("agent_only"))))

        // 2. Flip an `agent_only` row to `editors`.
        let agentOnlyRow = try XCTUnwrap(mapping.first {
            $0["name"]?.stringValue == "home_http_required_free_string"
        })
        XCTAssertNotNil(Self.mappingMismatch(
            Self.replacing(agentOnlyRow, "render", with: .string("editors"))))

        // 3. Flip one field of a real expected editor: the full-list comparison
        //    must notice, not just the render name.
        let sortedRow = try XCTUnwrap(mapping.first {
            $0["name"]?.stringValue == "editors_required_first_then_by_arg"
        })
        var sortedObject = try XCTUnwrap(sortedRow.objectValue)
        var editorValues = try XCTUnwrap(sortedObject["editors"]?.arrayValue)
        var slider = try XCTUnwrap(editorValues[0].objectValue)
        XCTAssertEqual(slider["kind"]?.stringValue, "slider")
        slider["min"] = .number(1)
        editorValues[0] = .object(slider)
        sortedObject["editors"] = .array(editorValues)
        XCTAssertNotNil(Self.mappingMismatch(.object(sortedObject)))

        // 3b. Swap the order (required first) and drop a title: both must be noticed.
        var swapped = try XCTUnwrap(sortedRow.objectValue)
        var swappedEditors = try XCTUnwrap(swapped["editors"]?.arrayValue)
        swappedEditors.swapAt(0, 1)
        swapped["editors"] = .array(swappedEditors)
        XCTAssertNotNil(Self.mappingMismatch(.object(swapped)))
        let titledRow = try XCTUnwrap(mapping.first { $0["name"]?.stringValue == "title_labels_every_editor_kind" })
        var titled = try XCTUnwrap(titledRow.objectValue)
        var titledEditors = try XCTUnwrap(titled["editors"]?.arrayValue)
        var first = try XCTUnwrap(titledEditors[0].objectValue)
        first.removeValue(forKey: "title")
        titledEditors[0] = .object(first)
        titled["editors"] = .array(titledEditors)
        XCTAssertNotNil(Self.mappingMismatch(.object(titled)))

        // 4. Flip a real `ok` descriptor row's expected result.
        let okRow = try XCTUnwrap(descriptor.first { $0["result"]?.stringValue == "ok" })
        XCTAssertNotNil(Self.descriptorMismatch(
            Self.replacing(okRow, "result", with: .string("schema"))))

        // 5. Flip a real non-`ok` descriptor row's expected result to `ok`.
        let tooLargeRow = try XCTUnwrap(descriptor.first {
            $0["result"]?.stringValue == "too_large"
        })
        XCTAssertNotNil(Self.descriptorMismatch(
            Self.replacing(tooLargeRow, "result", with: .string("ok"))))

        // 6. Changing the evaluated device ID of an `ok` row must be caught
        //    independently of the descriptor text.
        XCTAssertNotNil(Self.descriptorMismatch(
            Self.replacing(okRow, "device_id", with: .string("another-device"))))
    }

    private static func replacing(_ row: JSONValue, _ name: String, with value: JSONValue) -> JSONValue {
        guard case .object(var object) = row else { return row }
        object[name] = value
        return .object(object)
    }

    // MARK: - Spec rules the shared vector values do not pin directly

    private static let testDeviceID = "test-device"
    private static let noArgumentsTool: JSONValue = .object([
        "name": .string("noop"),
        "inputSchema": .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([:]),
        ]),
    ])

    private static func descriptor(_ body: String) -> Data {
        Data(body.utf8)
    }

    private static func testDescriptor(version: String = "1") -> Data {
        descriptor(
            #"{"v":"# + version + #","device_id":"\#(testDeviceID)","controls":[{"tool":"noop","label":"x"}]}"#)
    }

    private func result(
        _ bytes: Data, tools: [JSONValue] = [DevicePanelVectorTests.noArgumentsTool]
    ) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?) {
        evaluateDevicePanelDescriptor(
            bytes, linkDeviceID: Self.testDeviceID, tools: tools)
    }

    /// §4.2 step 2 is about a UTF-8 JSON text: other encodings and a BOM are not
    /// one, even though Foundation would decode them.
    func testNonUTF8InputIsInvalidJSON() throws {
        let valid = Self.testDescriptor()
        var invalidUTF8 = valid
        invalidUTF8.append(0xFF)
        XCTAssertEqual(result(invalidUTF8).0, .invalid_json)
        XCTAssertEqual(result(Data([0xEF, 0xBB, 0xBF]) + valid).0, .invalid_json)
        let text = try XCTUnwrap(String(data: valid, encoding: .utf8))
        XCTAssertEqual(result(try XCTUnwrap(text.data(using: .utf16))).0, .invalid_json)
    }

    /// §4.2 step 2 names NaN/Infinity explicitly; Foundation must not accept them
    /// and then let a control pass.
    func testNaNAndInfinityLiteralsAreInvalidJSON() {
        for literal in ["NaN", "Infinity", "-Infinity"] {
            let bytes = Self.descriptor(
                #"{"v":1,"device_id":"\#(Self.testDeviceID)","# +
                #""controls":[{"tool":"noop","label":"x","preset":{"a":"# + literal + "}}]}")
            XCTAssertEqual(result(bytes).0, .invalid_json, literal)
        }
    }

    /// §4.2 step 5: `v` is the JSON integer token `1`; `1.0`, `1e0` and `"1"` are
    /// all `unsupported_version`, which `Double`-based parsing would erase.
    func testVersionMustBeTheIntegerTokenOne() {
        XCTAssertEqual(result(Self.testDescriptor(version: "1")).0, .ok)
        for version in ["1.0", "1e0", "10e-1", "\"1\"", "2", "true"] {
            XCTAssertEqual(
                result(Self.testDescriptor(version: version)).0, .unsupported_version, version)
        }
    }

    /// §4.2 step 3 counts duplicates at any depth, including inside a preset.
    func testDuplicateMemberNamesAreDetectedAtAnyDepth() {
        let tool: JSONValue = .object([
            "name": .string("http"),
            "inputSchema": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "headers": .object(["type": .string("object")]),
                ]),
            ]),
        ])
        let bytes = Self.descriptor(
            #"{"v":1,"device_id":"\#(Self.testDeviceID)","# +
            #""controls":[{"tool":"http","label":"x","preset":{"headers":{"a":1,"a":2}}}]}"#)
        XCTAssertEqual(result(bytes, tools: [tool]).0, .duplicate_key)
    }

    /// §4.2: title/label length counts Unicode scalar values, not grapheme
    /// clusters: 40 scalars that form one grapheme are 40, one more is rejected.
    func testTextLengthCountsUnicodeScalars() {
        func descriptor(label: String) -> Data {
            Self.descriptor(
                #"{"v":1,"device_id":"\#(Self.testDeviceID)","# +
                #""controls":[{"tool":"noop","label":"\#(label)"}]}"#)
        }
        let fortyScalars = "e" + String(repeating: "\u{0301}", count: 39)
        XCTAssertEqual(fortyScalars.unicodeScalars.count, 40)
        XCTAssertEqual(fortyScalars.count, 1)
        XCTAssertEqual(result(descriptor(label: fortyScalars)).0, .ok)
        XCTAssertEqual(result(descriptor(label: fortyScalars + "\u{0301}")).0, .schema)
    }

    /// §2 orders editors by the argument name's Unicode code points. Swift's
    /// default `String` order normalizes to NFC and would put `b` before
    /// `a`+combining acute; code point order puts `a`+combining acute first.
    func testEditorSortUsesUnicodeCodePoints() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "b": .object(["type": .string("boolean")]),
                "a\u{0301}": .object(["type": .string("boolean")]),
            ]),
        ])
        XCTAssertEqual(classifyDevicePanelTool(inputSchema: schema), .editors([
            .toggle(arg: "a\u{0301}", required: false),
            .toggle(arg: "b", required: false),
        ]))
    }

    /// §4.2 step 8: enum comparison is type- and value-strict, so a string `"1"`
    /// in the enum never matches the number `1`.
    func testPresetEnumComparisonIsTypeStrict() {
        func tool(_ enumValues: JSONValue) -> JSONValue {
            .object([
                "name": .string("num"),
                "inputSchema": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "n": .object(["type": .string("number"), "enum": enumValues]),
                    ]),
                ]),
            ])
        }
        let bytes = Self.descriptor(
            #"{"v":1,"device_id":"\#(Self.testDeviceID)","# +
            #""controls":[{"tool":"num","label":"x","preset":{"n":1}}]}"#)
        XCTAssertEqual(result(bytes, tools: [tool(.array([.string("1")]))]).0, .preset_invalid)
        XCTAssertEqual(result(bytes, tools: [tool(.array([.number(1)]))]).0, .ok)
    }
}

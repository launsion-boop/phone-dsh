// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Runs the frozen xiaozhi-firmware-v1 goldens (spec/device/v1/xiaozhi-firmware.md) through the
/// real Swift definitions, effect classifier and device-Bot key/name/description functions.
final class XiaozhiGoldenTests: XCTestCase {
    static func specFile(_ relative: String, from file: StaticString = #filePath) throws -> Data {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("golden \(relative) not found")
    }

    // MARK: (a) tool definitions equal the frozen catalog section

    func testToolDefinitionsEqualTheGoldenXiaozhiFirmwareSection() throws {
        let data = try Self.specFile("spec/bot/v1/golden/tool-catalog.phone.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let section = try XCTUnwrap(root["xiaozhiFirmware"] as? [String: Any])
        let tools = try XCTUnwrap(section["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 4)
        XCTAssertEqual(XiaozhiFirmwareToolDefinitions.all.count, tools.count)
        for (expected, actual) in zip(tools, XiaozhiFirmwareToolDefinitions.all) {
            XCTAssertEqual(actual.name, expected["name"] as? String)
            XCTAssertEqual(actual.description, expected["description"] as? String, actual.name)
            let schema = try BotJSONValue.parse(
                JSONSerialization.data(withJSONObject: try XCTUnwrap(expected["inputSchema"])))
            XCTAssertEqual(actual.inputSchema, schema, actual.name)
        }
        XCTAssertEqual(XiaozhiFirmwareToolNames.all, tools.compactMap { $0["name"] as? String })
    }

    func testToolsAreNotInTheStaticCatalog() {
        let names = Set(BotToolCatalog.workerDefinitions.map(\.name))
        for name in XiaozhiFirmwareToolNames.all { XCTAssertFalse(names.contains(name), name) }
    }

    // MARK: (b) effect classifier equals the frozen vectors

    func testEffectClassifierEqualsTheFourFrozenVectors() throws {
        struct Vector: Decodable {
            struct Call: Decodable {
                let name: String
                let args: BotJSONValue
                let policy: BotToolPolicy
                let effect: BotToolEffect
            }
            let valid: [Call]
        }
        let data = try Self.specFile("spec/bot/v1/golden/tool-effects.phone.json")
        let vector = try JSONDecoder().decode(Vector.self, from: data)
        let calls = vector.valid.filter { XiaozhiFirmwareToolNames.handles($0.name) }
        XCTAssertEqual(calls.map(\.name).sorted(), XiaozhiFirmwareToolNames.all.sorted())
        for call in calls {
            XCTAssertEqual(BotToolEffectClassifier.effect(for: call.name, arguments: call.args), call.effect,
                           call.name)
            XCTAssertEqual(BotToolEffectClassifier.policy(for: call.name, arguments: call.args), call.policy)
            // The Worker prefix form classifies identically (apart from isMcp).
            let prefixed = BotToolEffectClassifier.effect(for: "mcp__phone__" + call.name, arguments: call.args)
            XCTAssertEqual(prefixed.operation, call.effect.operation)
            XCTAssertEqual(prefixed.resource, call.effect.resource)
        }
    }

    func testFlashResourceNeverCarriesAMalformedDigest() {
        let effect = BotToolEffectClassifier.effect(
            for: XiaozhiFirmwareToolNames.flash, arguments: .object(["elfSha256": .string("../etc")]))
        XCTAssertEqual(effect.resource, "xiaozhi:flash")
        XCTAssertEqual(effect.policy, .ask)
        XCTAssertFalse(effect.canUseStandingGrant)
    }

    // MARK: (c) key, name and description vectors

    func testKeyNameAndDescriptionVectors() throws {
        let data = try Self.specFile("spec/device/v1/golden/xiaozhi-ota.jsonl")
        let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        var seen = Set<String>()
        for row in rows {
            let id = row["id"] as? String ?? "?"
            let input = row["input"] as? [String: Any] ?? [:]
            switch row["kind"] as? String {
            case "key":
                seen.insert("key")
                XCTAssertEqual(DeviceBotKey.xiaozhi(mac: input["mac"] as? String ?? ""),
                               row["key"] as? String, id)
            case "name":
                seen.insert("name")
                XCTAssertEqual(DeviceBotText.xiaozhiRawName(mac: input["mac"] as? String ?? ""),
                               row["raw"] as? String, id)
            case "description":
                seen.insert("description")
                XCTAssertEqual(DeviceBotText.xiaozhiDescription(mac: input["mac"] as? String ?? ""),
                               row["description"] as? String, id)
            default:
                continue
            }
        }
        XCTAssertEqual(seen, ["key", "name", "description"])
    }

    func testNameGoesThroughTheSharedNameRules() {
        let raw = DeviceBotText.xiaozhiRawName(mac: "98:c3:77:f4:ff:38")!
        XCTAssertEqual(DeviceBotText.name(raw, rosterNames: []), "小智 FF38")
        XCTAssertEqual(DeviceBotText.name(raw, rosterNames: ["小智 FF38"]), "小智 FF38 2")
        XCTAssertNil(DeviceBotText.xiaozhiRawName(mac: "98:C3:77:F4:FF:38"))
        XCTAssertNil(DeviceBotText.xiaozhiDescription(mac: "98c377f4ff38"))
    }

    func testBindingMACRoundTrip() {
        XCTAssertEqual(XiaozhiFirmwareBinding.mac(inKey: "xiaozhi:98:c3:77:f4:ff:38"), "98:c3:77:f4:ff:38")
        for bad in ["dev-1", "gatt:98:c3:77:f4:ff:38", "xiaozhi:", "xiaozhi:98:C3:77:F4:FF:38",
                    "xiaozhi:98:c3:77:f4:ff", "xiaozhi:98:c3:77:f4:ff:38:00"] {
            XCTAssertNil(XiaozhiFirmwareBinding.mac(inKey: bad), bad)
        }
    }
}

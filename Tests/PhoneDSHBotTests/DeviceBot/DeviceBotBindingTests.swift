// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Runs every vector of spec/device/v1/golden/device-bot-binding.jsonl through the real code.
final class DeviceBotBindingGoldenTests: XCTestCase {
    private func vectors(file: StaticString = #filePath) throws -> [[String: Any]] {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("spec/device/v1/golden/device-bot-binding.jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let text = try String(contentsOf: candidate, encoding: .utf8)
                return try text.split(separator: "\n").map {
                    try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
                }
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("golden not found")
    }

    private func state(_ raw: [String: Any]) -> DeviceBotState {
        DeviceBotState(
            bindings: raw["bindings"] as? [String: String] ?? [:],
            intents: raw["intents"] as? [String: String] ?? [:],
            roster: Set(raw["roster"] as? [String] ?? []),
            created: raw["created"] as? [String: String] ?? [:])
    }

    private func action(_ raw: [String: Any]) -> DeviceBotAction {
        switch raw["do"] as? String {
        case "none": return .none
        case "bind": return .bind(bot: raw["bot"] as? String ?? "")
        default: return .create(creationID: raw["creation_id"] as? String ?? "")
        }
    }

    func testEveryVectorRunsThroughTheRealCode() throws {
        let rows = try vectors()
        XCTAssertGreaterThanOrEqual(rows.count, 50)
        var kinds = Set<String>()
        for row in rows {
            let id = row["id"] as? String ?? "?"
            let kind = row["kind"] as? String ?? "?"
            kinds.insert(kind)
            switch kind {
            case "key":
                let input = row["input"] as! [String: Any]
                let expected = row["key"] as? String
                let got: String?
                switch row["class"] as! String {
                case "link": got = DeviceBotKey.link(deviceID: input["device_id"] as! String)
                case "gatt": got = DeviceBotKey.gatt(peripheralUUID: input["peripheral_uuid"] as! String)
                case "lan": got = DeviceBotKey.lan(host: input["host"] as! String, port: input["port"] as! Int)
                case "tonolink": got = DeviceBotKey.tonolink(bleName: input["ble_name"] as! String)
                default: XCTFail("\(id): class"); continue
                }
                XCTAssertEqual(got, expected, id)
            case "name":
                let name = DeviceBotText.name(row["raw"] as! String, rosterNames: row["roster_names"] as! [String])
                XCTAssertEqual(name, row["name"] as? String, id)
                XCTAssertLessThanOrEqual(name.unicodeScalars.count, 60, id)
            case "description":
                let input = row["input"] as! [String: Any]
                let got: String
                switch row["class"] as! String {
                case "board": got = DeviceBotText.boardDescription
                case "link": got = DeviceBotText.linkDescription(tools: input["tools"] as! [String])
                case "gatt": got = DeviceBotText.gattDescription(profiles: input["profiles"] as! [String])
                case "lan": got = DeviceBotText.lanDescription(host: input["host"] as! String)
                default: XCTFail("\(id): class"); continue
                }
                XCTAssertEqual(got, row["description"] as? String, id)
            case "decide":
                let before = state(row["state"] as! [String: Any])
                let result = DeviceBotBinding.decide(
                    before, key: row["key"] as! String, newCreationID: row["new_creation_id"] as! String,
                    alias: row["alias"] as? String)
                XCTAssertEqual(result.action, action(row["action"] as! [String: Any]), id)
                let after = row["after"] as! [String: Any]
                XCTAssertEqual(result.state.bindings, after["bindings"] as? [String: String], id)
                XCTAssertEqual(result.state.intents, after["intents"] as? [String: String], id)
            case "complete":
                let result = DeviceBotBinding.complete(
                    state(row["state"] as! [String: Any]), key: row["key"] as! String, bot: row["bot"] as! String)
                let after = row["after"] as! [String: Any]
                XCTAssertEqual(result.bindings, after["bindings"] as? [String: String], id)
                XCTAssertEqual(result.intents, after["intents"] as? [String: String], id)
            default:
                XCTFail("\(id): unknown kind \(kind)")
            }
        }
        XCTAssertEqual(kinds, ["key", "name", "description", "decide", "complete"])
    }

    func testStrictPatternsRejectTrailingNewline() {
        XCTAssertFalse(DeviceBotText.isToolName("a\n"))
        XCTAssertFalse(DeviceBotText.isCanonicalHost("lamp.local\n"))
        XCTAssertNil(DeviceBotKey.lan(host: "lamp.local\n", port: 443))
    }
}

private actor FakeHost: DeviceBotHost {
    var bots: [(id: String, name: String)]
    var createdMap: [String: String] = [:]
    var failNextCreate = false
    var creates: [(name: String, description: String, key: String, creationID: String)] = []

    init(bots: [(id: String, name: String)] = []) { self.bots = bots }

    func roster() async throws -> [(id: String, name: String)] { bots }
    func createdBots() async throws -> [String: String] { createdMap }
    func createDeviceBot(name: String, description: String, key: String, creationID: String) async throws -> String {
        creates.append((name, description, key, creationID))
        if failNextCreate { failNextCreate = false; throw NSError(domain: "t", code: 1) }
        let id = "bot-\(creates.count)"
        bots.append((id, name))
        createdMap[creationID] = id
        return id
    }
    func setFailNext() { failNextCreate = true }
    func removeBot(_ id: String) { bots.removeAll { $0.id == id } }
    func dropCreatedEvents() { createdMap = [:] }
    func createCount() -> Int { creates.count }
    func lastCreate() -> (name: String, description: String, key: String, creationID: String)? { creates.last }
}

final class DeviceBotFlowTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "device-bot-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func request(_ key: String = "k1", alias: String? = nil) -> DeviceBotRequest {
        DeviceBotRequest(key: key, rawName: "灯", description: DeviceBotText.linkDescription(tools: ["a"]), alias: alias)
    }

    func testCreateThenExisting() async {
        let store = DeviceBotMapStore(defaults: defaults())
        let host = FakeHost()
        let binder = DeviceBotBinder(store: store, host: host, makeCreationID: { "c1" })
        let first = await binder.ensure(request())
        XCTAssertEqual(first, .created(bot: "bot-1"))
        XCTAssertEqual(store.bindings, ["k1": "bot-1"])
        XCTAssertEqual(store.intents, [:])
        let second = await binder.ensure(request())
        XCTAssertEqual(second, .existing(bot: "bot-1"))
        let count = await host.createCount()
        XCTAssertEqual(count, 1)
        let last = await host.lastCreate()
        XCTAssertEqual(last?.key, "k1")
        XCTAssertEqual(last?.creationID, "c1")
    }

    func testIntentIsDurableBeforeCreateAndFailureRetriesSameCreationID() async {
        let store = DeviceBotMapStore(defaults: defaults())
        let host = FakeHost()
        await host.setFailNext()
        var counter = 0
        let binder = DeviceBotBinder(store: store, host: host, makeCreationID: { counter += 1; return "c\(counter)" })
        let failed = await binder.ensure(request())
        guard case .failed = failed else { return XCTFail("expected failure") }
        XCTAssertEqual(store.intents, ["k1": "c1"])
        XCTAssertEqual(store.bindings, [:])
        let retry = await binder.ensure(request())
        XCTAssertEqual(retry, .created(bot: "bot-2"))
        let last = await host.lastCreate()
        XCTAssertEqual(last?.creationID, "c1", "the retry reuses the persisted creation id")
    }

    func testCrashAfterBotBindsByCreationIDWithoutSecondBot() async {
        let d = defaults()
        let store = DeviceBotMapStore(defaults: d)
        // The earlier run persisted the intent and created the Bot, then died before the binding.
        store.write(bindings: [:], intents: ["k1": "c-old"])
        let host = FakeHost(bots: [("bot9", "灯")])
        await host.setCreated(["c-old": "bot9"])
        let binder = DeviceBotBinder(store: store, host: host, makeCreationID: { "c-new" })
        let outcome = await binder.ensure(request())
        XCTAssertEqual(outcome, .bound(bot: "bot9"))
        XCTAssertEqual(store.bindings, ["k1": "bot9"])
        XCTAssertEqual(store.intents, [:])
        let count = await host.createCount()
        XCTAssertEqual(count, 0)
    }

    func testSameNameUserBotIsNeverBoundAndGetsNumberedName() async {
        let store = DeviceBotMapStore(defaults: defaults())
        let host = FakeHost(bots: [("user-bot", "灯")])
        let binder = DeviceBotBinder(store: store, host: host, makeCreationID: { "c1" })
        let outcome = await binder.ensure(request())
        XCTAssertEqual(outcome, .created(bot: "bot-1"))
        let last = await host.lastCreate()
        XCTAssertEqual(last?.name, "灯 2")
        XCTAssertEqual(store.bindings["k1"], "bot-1")
    }

    func testDeletedBotIsRecreatedAndForgottenBindingSurvives() async {
        let store = DeviceBotMapStore(defaults: defaults())
        let host = FakeHost()
        let binder = DeviceBotBinder(store: store, host: host, makeCreationID: { "c\(Int.random(in: 0...1_000_000))" })
        _ = await binder.ensure(request())
        await host.removeBot("bot-1")
        let again = await binder.ensure(request())
        XCTAssertEqual(again, .created(bot: "bot-2"))
        XCTAssertEqual(store.bindings["k1"], "bot-2")
    }

    func testAliasMovesLegacyBindingToLinkKeyKeepingTheOldEntry() async {
        let store = DeviceBotMapStore(defaults: defaults())
        store.write(bindings: ["tonolink:phoneagent-ab12": "bot1"], intents: [:])
        let host = FakeHost(bots: [("bot1", "手机助手")])
        let binder = DeviceBotBinder(store: store, host: host)
        let outcome = await binder.ensure(request("link-id", alias: "tonolink:phoneagent-ab12"))
        XCTAssertEqual(outcome, .bound(bot: "bot1"))
        XCTAssertEqual(store.bindings, ["tonolink:phoneagent-ab12": "bot1", "link-id": "bot1"])
    }

    func testUnknownEntriesSurviveReadWriteCycles() async {
        let d = defaults()
        d.set(["future:abc": "bot7", "future:struct": ["x": 1], "k0": "bot0"] as [String: Any],
              forKey: DeviceBotMapStore.bindingsKey)
        d.set(["future:int": 5] as [String: Any], forKey: DeviceBotMapStore.intentsKey)
        let store = DeviceBotMapStore(defaults: d)
        XCTAssertEqual(store.bindings, ["future:abc": "bot7", "k0": "bot0"])
        let host = FakeHost(bots: [("bot7", "x"), ("bot0", "y")])
        let binder = DeviceBotBinder(store: store, host: host, makeCreationID: { "c1" })
        _ = await binder.ensure(request())
        let rawBindings = d.dictionary(forKey: DeviceBotMapStore.bindingsKey) ?? [:]
        XCTAssertNotNil(rawBindings["future:struct"], "a foreign entry is written back unchanged")
        XCTAssertEqual(rawBindings["future:abc"] as? String, "bot7")
        XCTAssertEqual(rawBindings["k1"] as? String, "bot-1")
        let rawIntents = d.dictionary(forKey: DeviceBotMapStore.intentsKey) ?? [:]
        XCTAssertEqual(rawIntents["future:int"] as? Int, 5)
    }
}

extension FakeHost {
    func setCreated(_ map: [String: String]) { createdMap = map }
}

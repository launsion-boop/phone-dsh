// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotProfileStoreTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64

        init(_ value: Int64) { self.value = value }

        func now() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(_ delta: Int64) {
            lock.lock()
            value += delta
            lock.unlock()
        }
    }

    private func store(at directory: URL, clock: TestClock) -> BotProfileStore {
        BotProfileStore(directory: directory, now: { clock.now() })
    }

    private func indexURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("agents-index.json")
    }

    private func settingsURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("runtime-settings.json")
    }

    private func readObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProfileTestSupport.FixtureError(description: "\(url.lastPathComponent) is not an object")
        }
        return object
    }

    private func records(_ index: [String: Any]) throws -> [[String: Any]] {
        guard let records = index["agents"] as? [[String: Any]] else {
            throw ProfileTestSupport.FixtureError(description: "agents is not an object array")
        }
        return records
    }

    private func number(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    func testBootstrapCreatesExplicitClassicMainAndPointer() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("bootstrap")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(1_760_000_000_000)
        let store = store(at: directory, clock: clock)

        let profile = try await store.bootstrapMainIfNeeded(legacyName: nil)
        XCTAssertEqual(profile.id, "main")
        XCTAssertEqual(profile.name, "大肥鱼")
        XCTAssertEqual(profile.fishColor, .blue)
        XCTAssertEqual(profile.fishHairstyle, .long)
        XCTAssertEqual(profile.nameExplicit, false)
        XCTAssertEqual(profile.createdAt, 1_760_000_000_000)
        XCTAssertEqual(profile.updatedAt, 1_760_000_000_000)

        let mainID = try await store.mainBotID()
        XCTAssertEqual(mainID, "main")
        let allProfiles = try await store.profiles()
        XCTAssertEqual(allProfiles.count, 1)

        let index = try readObject(indexURL(directory))
        XCTAssertEqual(number(index["schemaVersion"]), 3)
        let agents = try records(index)
        XCTAssertEqual(agents.count, 1)
        let record = agents[0]
        XCTAssertEqual(number(record["schema"]), 3)
        XCTAssertEqual(record["id"] as? String, "main")
        XCTAssertEqual(record["name"] as? String, "大肥鱼")
        XCTAssertEqual(record["fish_color"] as? String, "blue")
        XCTAssertEqual(record["fish_hairstyle"] as? String, "long")
        XCTAssertEqual(record["name_explicit"] as? Bool, false)
        XCTAssertEqual(number(record["created_at"]), 1_760_000_000_000)
        XCTAssertEqual(number(record["updated_at"]), 1_760_000_000_000)

        let settings = try readObject(settingsURL(directory))
        XCTAssertEqual(number(settings["version"]), 1)
        XCTAssertEqual(settings["mainAgentId"] as? String, "main")
        XCTAssertEqual(number(settings["updatedAt"]), 1_760_000_000_000)
    }

    func testBootstrapUsesLegacyNameAndIsIdempotent() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(10)
        let store = store(at: directory, clock: clock)

        let first = try await store.bootstrapMainIfNeeded(legacyName: "老鱼")
        XCTAssertEqual(first.name, "老鱼")
        XCTAssertEqual(first.nameExplicit, true)

        clock.advance(5_000)
        let second = try await store.bootstrapMainIfNeeded(legacyName: "另一个名字")
        XCTAssertEqual(second.name, "老鱼")
        XCTAssertEqual(second.createdAt, 10)
        XCTAssertEqual(second.updatedAt, 10)

        let agents = try records(try readObject(indexURL(directory)))
        XCTAssertEqual(agents.count, 1)
    }

    func testUpsertThreeStatePatchAndNameExplicit() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("patch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(100)
        let store = store(at: directory, clock: clock)

        _ = try await store.bootstrapMainIfNeeded(legacyName: nil)

        clock.advance(1)
        let named = try await store.upsert(id: "main", patch: .init(name: "新名字"))
        XCTAssertEqual(named.name, "新名字")
        XCTAssertEqual(named.nameExplicit, true)
        XCTAssertEqual(named.fishColor, .blue)

        clock.advance(1)
        let red = try await store.upsert(id: "main", patch: .init(fishColor: .some(.red)))
        XCTAssertEqual(red.fishColor, .red)
        XCTAssertEqual(red.fishHairstyle, .long)
        XCTAssertEqual(red.updatedAt, 102)

        clock.advance(1)
        let auto = try await store.upsert(id: "main", patch: .init(fishColor: .some(nil)))
        XCTAssertNil(auto.fishColor)
        let record = try records(try readObject(indexURL(directory)))[0]
        XCTAssertTrue(record["fish_color"] is NSNull)

        clock.advance(1)
        let unchanged = try await store.upsert(id: "main", patch: .init())
        XCTAssertNil(unchanged.fishColor)
        XCTAssertEqual(unchanged.name, "新名字")

        clock.advance(1)
        let hairstyle = try await store.upsert(
            id: "main", patch: .init(fishColor: .some(.sky), fishHairstyle: .some(.bob)))
        XCTAssertEqual(hairstyle.fishColor, .sky)
        XCTAssertEqual(hairstyle.fishHairstyle, .bob)
        XCTAssertEqual(hairstyle.updatedAt, 105)
    }

    func testSecondBotIsIndependentAndSeededByItsOwnID() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("second")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(at: directory, clock: TestClock(500))

        _ = try await store.bootstrapMainIfNeeded(legacyName: nil)
        let side = try await store.upsert(id: "agent-123", patch: .init(name: "侧鱼"))
        XCTAssertEqual(side.name, "侧鱼")
        XCTAssertNil(side.fishColor)
        XCTAssertNil(side.fishHairstyle)
        XCTAssertEqual(BotFishAppearance.resolve(side).color, .brown)
        XCTAssertEqual(BotFishAppearance.resolve(side).hairstyle, .sideBraid)

        let main = try await store.profile(id: "main")
        XCTAssertEqual(main?.fishColor, .blue)
        let allProfiles = try await store.profiles()
        XCTAssertEqual(allProfiles.count, 2)
    }

    func testUnknownFieldsRoundTripInIndexAndSettings() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("unknown")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index: [String: Any] = [
            "schemaVersion": 3,
            "futureTop": ["keep": true],
            "agents": [[
                "schema": 3,
                "id": "main",
                "name": "大肥鱼",
                "fish_color": "blue",
                "fish_hairstyle": "long",
                "name_explicit": true,
                "created_at": 1,
                "updated_at": 2,
                "avatar_color": "red",
                "futureRecord": ["x": [1, 2]],
            ]],
        ]
        let settings: [String: Any] = [
            "version": 1,
            "mainAgentId": "main",
            "updatedAt": 1,
            "futureSettings": ["keep": "yes"],
        ]
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL(directory))
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL(directory))
        let store = store(at: directory, clock: TestClock(100))

        let loaded = try await store.profile(id: "main")
        XCTAssertEqual(loaded?.fishColor, .blue)
        XCTAssertEqual(loaded?.fishHairstyle, .long)

        _ = try await store.upsert(id: "main", patch: .init(name: "改名"))
        try await store.setMainBotID("main")

        let rewrittenIndex = try readObject(indexURL(directory))
        XCTAssertEqual((rewrittenIndex["futureTop"] as? [String: Any])?["keep"] as? Bool, true)
        let rewrittenRecord = try records(rewrittenIndex)[0]
        XCTAssertEqual(rewrittenRecord["avatar_color"] as? String, "red")
        let futureRecord = rewrittenRecord["futureRecord"] as? [String: Any]
        XCTAssertEqual(futureRecord?["x"] as? [Int], [1, 2])

        let rewrittenSettings = try readObject(settingsURL(directory))
        XCTAssertEqual((rewrittenSettings["futureSettings"] as? [String: Any])?["keep"] as? String, "yes")
        XCTAssertEqual(rewrittenSettings["mainAgentId"] as? String, "main")
    }

    func testMainBotPointerCanBeSetAndCleared() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("pointer")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(1)
        let store = store(at: directory, clock: clock)
        _ = try await store.bootstrapMainIfNeeded(legacyName: nil)

        clock.advance(10)
        try await store.setMainBotID("main")
        let mainID = try await store.mainBotID()
        XCTAssertEqual(mainID, "main")
        let settings = try readObject(settingsURL(directory))
        XCTAssertEqual(number(settings["updatedAt"]), 11)

        try await store.setMainBotID(nil)
        let cleared = try await store.mainBotID()
        XCTAssertNil(cleared)
        let clearedSettings = try readObject(settingsURL(directory))
        XCTAssertTrue(clearedSettings["mainAgentId"] is NSNull)
    }

    func testCorruptIndexIsBackedUpAndRecoveredWithoutOverwriting() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("corrupt-index")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "{not valid json"
        try Data(original.utf8).write(to: indexURL(directory))
        let store = store(at: directory, clock: TestClock(7))

        let emptyProfiles = try await store.profiles()
        XCTAssertTrue(emptyProfiles.isEmpty)
        let issue = await store.lastIssue
        XCTAssertTrue(issue?.contains("agents-index.json") == true)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backup = try XCTUnwrap(names.first { $0.hasPrefix("agents-index.json.corrupt-7") })
        let backedUp = try String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8)
        XCTAssertEqual(backedUp, original)

        let created = try await store.bootstrapMainIfNeeded(legacyName: nil)
        XCTAssertEqual(created.id, "main")
        let recovered = try await store.profiles()
        XCTAssertEqual(recovered.count, 1)
        let recoveredMain = try await store.mainBotID()
        XCTAssertEqual(recoveredMain, "main")
    }

    func testCorruptSettingsIsBackedUpAndRecovered() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("corrupt-settings")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "[]"
        try Data(original.utf8).write(to: settingsURL(directory))
        let store = store(at: directory, clock: TestClock(9))

        let missingMain = try await store.mainBotID()
        XCTAssertNil(missingMain)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backup = try XCTUnwrap(names.first { $0.hasPrefix("runtime-settings.json.corrupt-9") })
        let backedUp = try String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8)
        XCTAssertEqual(backedUp, original)

        try await store.setMainBotID("main")
        let recoveredMain = try await store.mainBotID()
        XCTAssertEqual(recoveredMain, "main")
    }

    func testBootstrapRepairsMissingMainPointerWithoutChangingProfile() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("pointer-repair")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(at: directory, clock: TestClock(42))
        let first = try await store.bootstrapMainIfNeeded(legacyName: nil)
        try FileManager.default.removeItem(at: settingsURL(directory))
        let missing = try await store.mainBotID()
        XCTAssertNil(missing)

        let second = try await store.bootstrapMainIfNeeded(legacyName: "ignored")
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.name, first.name)
        XCTAssertEqual(second.createdAt, first.createdAt)
        let mainID = try await store.mainBotID()
        XCTAssertEqual(mainID, "main")
    }

    func testEmptyIDIsRejected() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("empty-id")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(at: directory, clock: TestClock(1))
        do {
            _ = try await store.upsert(id: "", patch: .init(name: "x"))
            XCTFail("empty id must be rejected")
        } catch let error as BotProfileStoreError {
            XCTAssertEqual(error, .invalidID)
        }
    }
}

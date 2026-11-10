// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

final class BotRosterTests: XCTestCase {
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

    private func makeStore(at directory: URL, clock: TestClock = TestClock(1_760_000_000_000)) -> BotProfileStore {
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

    private func record(_ index: [String: Any], id: String) throws -> [String: Any] {
        guard let record = try records(index).first(where: { $0["id"] as? String == id }) else {
            throw ProfileTestSupport.FixtureError(description: "missing record \(id)")
        }
        return record
    }

    private func number(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    /// Minimal, realistic agents-index.json + runtime-settings.json fixture.
    @discardableResult
    private func writeRosterFixture(ids: [String], mainAgentId: String?,
                                    unknownFields: Bool = false) throws -> URL {
        let directory = try ProfileTestSupport.temporaryDirectory("roster-fixture")
        var index: [String: Any] = ["schemaVersion": 3]
        if unknownFields { index["futureTop"] = ["keep": true] }
        let agents: [[String: Any]] = ids.enumerated().map { offset, id in
            var record: [String: Any] = [
                "schema": 3,
                "id": id,
                "name": "Bot \(id)",
                "description": "",
                "fish_color": "blue",
                "fish_hairstyle": "long",
                "name_explicit": true,
                "pinned": false,
                "hidden_by_user": false,
                "unread_count": 0,
                "last_message_at": NSNull(),
                "created_at": 1_760_000_000_000 + Int64(offset),
                "updated_at": 1_760_000_000_000 + Int64(offset),
            ]
            if unknownFields { record["futureRecord"] = ["x": [1, 2]] }
            return record
        }
        index["agents"] = agents
        var settings: [String: Any] = [
            "version": 1,
            "mainAgentId": mainAgentId ?? NSNull(),
            "updatedAt": 1_760_000_000_000,
        ]
        if unknownFields { settings["futureSettings"] = ["keep": "yes"] }
        try JSONSerialization.data(withJSONObject: index).write(to: indexURL(directory))
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL(directory))
        return directory
    }

    // MARK: - Create

    func testCreateBotIDDefaultsFirstMainAndInsertionOrder() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("create")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(1_000)
        let store = makeStore(at: directory, clock: clock)

        let first = try await store.createBot(
            name: "  小鱼  ", fishColor: nil, fishHairstyle: nil, description: "简介")
        XCTAssertNotNil(first.id.range(of: "^agent-[0-9a-f]{16}$", options: .regularExpression),
                        "unexpected id \(first.id)")
        XCTAssertEqual(first.name, "小鱼")
        XCTAssertEqual(first.fishColor, .blue)
        XCTAssertEqual(first.fishHairstyle, .long)
        XCTAssertEqual(first.nameExplicit, true)
        XCTAssertEqual(first.description, "简介")
        XCTAssertEqual(first.hiddenByUser, false)
        XCTAssertEqual(first.unreadCount, 0)
        XCTAssertNil(first.lastMessageAt)
        XCTAssertEqual(first.createdAt, 1_000)
        XCTAssertEqual(first.updatedAt, 1_000)
        XCTAssertTrue(first.pinned, "the first Bot becomes the pinned main Bot")

        var main = try await store.mainBotID()
        XCTAssertEqual(main, first.id)
        let settings = try readObject(settingsURL(directory))
        XCTAssertEqual(settings["mainAgentId"] as? String, first.id)

        clock.advance(1)
        let second = try await store.createBot(
            name: "第二只", fishColor: .red, fishHairstyle: .bob, description: nil)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.fishColor, .red)
        XCTAssertEqual(second.fishHairstyle, .bob)
        XCTAssertEqual(second.description, "")
        XCTAssertFalse(second.pinned)
        XCTAssertEqual(second.createdAt, 1_001)

        let roster = try await store.roster()
        XCTAssertEqual(roster.bots.map(\.id), [first.id, second.id])
        XCTAssertEqual(roster.visibleBots.map(\.id), [first.id, second.id])
        main = try await store.mainBotID()
        XCTAssertEqual(main, first.id)
        let firstRecord = try record(readObject(indexURL(directory)), id: first.id)
        XCTAssertEqual(number(firstRecord["schema"]), 3)
        XCTAssertEqual(firstRecord["description"] as? String, "简介")
        XCTAssertEqual(firstRecord["hidden_by_user"] as? Bool, false)
        XCTAssertEqual(firstRecord["pinned"] as? Bool, true)
        XCTAssertEqual(number(firstRecord["unread_count"]), 0)
        XCTAssertTrue(firstRecord["last_message_at"] is NSNull)
    }

    func testCreateBotRejectsInvalidNamesAtTheBoundary() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("names")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)

        for name in ["", "   ", "\n\t", String(repeating: "a", count: 61)] {
            do {
                _ = try await store.createBot(
                    name: name, fishColor: nil, fishHairstyle: nil, description: nil)
                XCTFail("name \(String(reflecting: name)) must be rejected")
            } catch let error as BotProfileStoreError {
                XCTAssertEqual(error, .invalidName(name))
            }
            let count = try await store.profiles().count
            XCTAssertEqual(count, 0, "a rejected name must not create a record")
        }

        let sixty = String(repeating: "a", count: 60)
        let created = try await store.createBot(
            name: "  \(sixty)  ", fishColor: nil, fishHairstyle: nil, description: nil)
        XCTAssertEqual(created.name, sixty, "trim before the 60-character check")
    }

    func testUpsertRenameValidationAndNewPatchFields() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("upsert-roster")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        let bot = try await store.createBot(
            name: "原名", fishColor: nil, fishHairstyle: nil, description: nil)

        do {
            _ = try await store.upsert(id: bot.id, patch: .init(name: "   "))
            XCTFail("upsert must validate a renamed Bot")
        } catch let error as BotProfileStoreError {
            XCTAssertEqual(error, .invalidName("   "))
        }
        do {
            _ = try await store.upsert(id: bot.id, patch: .init(name: String(repeating: "b", count: 61)))
            XCTFail("upsert must enforce the 60-character boundary")
        } catch let error as BotProfileStoreError {
            XCTAssertEqual(error, .invalidName(String(repeating: "b", count: 61)))
        }
        let unchanged = try await store.profile(id: bot.id)
        XCTAssertEqual(unchanged?.name, "原名")

        let longDescription = String(repeating: "x", count: 2_001)
        let updated = try await store.upsert(id: bot.id, patch: .init(
            name: "  新名字  ", fishColor: .some(.red), fishHairstyle: nil,
            description: longDescription, hiddenByUser: true))
        XCTAssertEqual(updated.name, "新名字")
        XCTAssertEqual(updated.nameExplicit, true)
        XCTAssertEqual(updated.description, String(repeating: "x", count: 2_000))
        XCTAssertEqual(updated.hiddenByUser, true)
        XCTAssertEqual(updated.fishColor, BotFishColor.red)

        let persisted = try await store.profile(id: bot.id)
        XCTAssertEqual(persisted?.description.utf16.count, 2_000)
        XCTAssertEqual(persisted?.hiddenByUser, true)
    }

    // MARK: - Delete

    func testDeleteLastBotIsRejected() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("last-bot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        let only = try await store.createBot(
            name: "唯一", fishColor: nil, fishHairstyle: nil, description: nil)

        do {
            _ = try await store.deleteBot(id: only.id)
            XCTFail("the only Bot must not be deleted")
        } catch let error as BotProfileStoreError {
            XCTAssertEqual(error, .lastBot)
        }
        let count = try await store.profiles().count
        XCTAssertEqual(count, 1)
        let main = try await store.mainBotID()
        XCTAssertEqual(main, only.id)
    }

    func testDeleteUnknownBotIsRejected() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("delete-unknown")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        _ = try await store.createBot(name: "一", fishColor: nil, fishHairstyle: nil, description: nil)
        _ = try await store.createBot(name: "二", fishColor: nil, fishHairstyle: nil, description: nil)

        do {
            _ = try await store.deleteBot(id: "agent-missing")
            XCTFail("unknown Bot must be rejected")
        } catch let error as BotProfileStoreError {
            XCTAssertEqual(error, .unknownBot("agent-missing"))
        }
        let count = try await store.profiles().count
        XCTAssertEqual(count, 2)
    }

    func testDeleteMainMigratesPointerAndKeepsInsertionOrder() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("delete-main")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        let first = try await store.createBot(name: "甲", fishColor: nil, fishHairstyle: nil, description: nil)
        let second = try await store.createBot(name: "乙", fishColor: .red, fishHairstyle: .bob, description: "被删")
        let third = try await store.createBot(name: "丙", fishColor: nil, fishHairstyle: nil, description: nil)
        try await store.setMainBotID(second.id)

        let deleted = try await store.deleteBot(id: second.id)
        XCTAssertEqual(deleted.removed.id, second.id)
        XCTAssertEqual(deleted.removed.description, "被删")
        XCTAssertEqual(deleted.mainBotID, first.id)

        let roster = try await store.roster()
        XCTAssertEqual(roster.bots.map(\.id), [first.id, third.id])
        XCTAssertEqual(roster.mainBotID, first.id)
        let settings = try readObject(settingsURL(directory))
        XCTAssertEqual(settings["mainAgentId"] as? String, first.id)
        let migrated = try await store.profile(id: first.id)
        XCTAssertEqual(migrated?.pinned, true)

        // Deleting a non-main Bot leaves the pointer alone.
        let nonMain = try await store.deleteBot(id: third.id)
        XCTAssertEqual(nonMain.removed.id, third.id)
        XCTAssertEqual(nonMain.mainBotID, first.id)
        let remaining = try await store.roster()
        XCTAssertEqual(remaining.bots.map(\.id), [first.id])
        XCTAssertEqual(remaining.mainBotID, first.id)
    }

    // MARK: - Main pointer repair and pin

    func testMainBotIDRepairsEmptyAndDanglingPointers() async throws {
        let emptyDirectory = try writeRosterFixture(ids: ["agent-a", "agent-b"], mainAgentId: nil)
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }
        let emptyStore = makeStore(at: emptyDirectory)
        var main = try await emptyStore.mainBotID()
        XCTAssertEqual(main, "agent-a")
        var settings = try readObject(settingsURL(emptyDirectory))
        XCTAssertEqual(settings["mainAgentId"] as? String, "agent-a")

        let danglingDirectory = try writeRosterFixture(ids: ["agent-a", "agent-b"], mainAgentId: "agent-gone")
        defer { try? FileManager.default.removeItem(at: danglingDirectory) }
        let danglingStore = makeStore(at: danglingDirectory)
        main = try await danglingStore.mainBotID()
        XCTAssertEqual(main, "agent-a")
        settings = try readObject(settingsURL(danglingDirectory))
        XCTAssertEqual(settings["mainAgentId"] as? String, "agent-a")
        let pinned = try await danglingStore.profile(id: "agent-a")
        XCTAssertEqual(pinned?.pinned, true)

        let validDirectory = try writeRosterFixture(ids: ["agent-a", "agent-b"], mainAgentId: "agent-b")
        defer { try? FileManager.default.removeItem(at: validDirectory) }
        let validStore = makeStore(at: validDirectory)
        main = try await validStore.mainBotID()
        XCTAssertEqual(main, "agent-b")
        let validSettings = try readObject(settingsURL(validDirectory))
        XCTAssertEqual(validSettings["mainAgentId"] as? String, "agent-b")
    }

    func testEmptyRosterHasNilMainWithoutInventingAPointer() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("empty-roster")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        let roster = try await store.roster()
        XCTAssertTrue(roster.bots.isEmpty)
        XCTAssertNil(roster.mainBotID)
        let main = try await store.mainBotID()
        XCTAssertNil(main)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL(directory).path))
    }

    func testSetMainRejectsUnknownAndPinsTarget() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("set-main")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        _ = try await store.createBot(name: "甲", fishColor: nil, fishHairstyle: nil, description: nil)
        let second = try await store.createBot(name: "乙", fishColor: nil, fishHairstyle: nil, description: nil)
        let before = try await store.profile(id: second.id)
        XCTAssertEqual(before?.pinned, false)

        try await store.setMainBotID(second.id)
        let main = try await store.mainBotID()
        XCTAssertEqual(main, second.id)
        let pinned = try await store.profile(id: second.id)
        XCTAssertEqual(pinned?.pinned, true)
        let settings = try readObject(settingsURL(directory))
        XCTAssertEqual(settings["mainAgentId"] as? String, second.id)

        do {
            try await store.setMainBotID("agent-missing")
            XCTFail("unknown main id must be rejected")
        } catch let error as BotProfileStoreError {
            XCTAssertEqual(error, .unknownBot("agent-missing"))
        }
        let unchanged = try await store.mainBotID()
        XCTAssertEqual(unchanged, second.id)
    }

    // MARK: - Hidden, unread, touch

    func testHiddenBotsStayInRosterAndLeaveVisibleBots() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("hidden")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        let first = try await store.createBot(name: "甲", fishColor: nil, fishHairstyle: nil, description: nil)
        let second = try await store.createBot(name: "乙", fishColor: nil, fishHairstyle: nil, description: nil)

        try await store.setHidden(id: first.id, hidden: true)
        var roster = try await store.roster()
        XCTAssertEqual(roster.bots.map(\.id), [first.id, second.id])
        XCTAssertEqual(roster.visibleBots.map(\.id), [second.id])
        let persistHidden = try await store.profile(id: first.id)
        XCTAssertEqual(persistHidden?.hiddenByUser, true)

        try await store.setHidden(id: first.id, hidden: false)
        roster = try await store.roster()
        XCTAssertEqual(roster.visibleBots.map(\.id), [first.id, second.id])

        do {
            try await store.setHidden(id: "agent-missing", hidden: true)
            XCTFail("unknown Bot must be rejected")
        } catch let error as BotProfileStoreError {
            XCTAssertEqual(error, .unknownBot("agent-missing"))
        }
    }

    func testUnreadMarkReadAndTouchPersist() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("unread")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        _ = try await store.createBot(name: "甲", fishColor: nil, fishHairstyle: nil, description: nil)
        let second = try await store.createBot(name: "乙", fishColor: nil, fishHairstyle: nil, description: nil)

        try await store.incrementUnread(id: second.id, by: 3)
        var loaded = try await store.profile(id: second.id)
        XCTAssertEqual(loaded?.unreadCount, 3)
        try await store.incrementUnread(id: second.id)
        loaded = try await store.profile(id: second.id)
        XCTAssertEqual(loaded?.unreadCount, 4)
        // dsh-bot clamps bumpUnread to at least one.
        try await store.incrementUnread(id: second.id, by: -5)
        loaded = try await store.profile(id: second.id)
        XCTAssertEqual(loaded?.unreadCount, 5)

        try await store.markRead(id: second.id)
        loaded = try await store.profile(id: second.id)
        XCTAssertEqual(loaded?.unreadCount, 0)

        try await store.touch(id: second.id, at: 1_760_000_001_234)
        loaded = try await store.profile(id: second.id)
        XCTAssertEqual(loaded?.lastMessageAt, 1_760_000_001_234)
        try await store.touch(id: second.id, at: nil)
        loaded = try await store.profile(id: second.id)
        XCTAssertNil(loaded?.lastMessageAt)
        let row = try record(readObject(indexURL(directory)), id: second.id)
        XCTAssertTrue(row["last_message_at"] is NSNull)

        let operations: [() async throws -> Void] = [
            { try await store.markRead(id: "agent-missing") },
            { try await store.incrementUnread(id: "agent-missing") },
            { try await store.touch(id: "agent-missing", at: 1) },
        ]
        for operation in operations {
            do {
                try await operation()
                XCTFail("unknown Bot must be rejected")
            } catch let error as BotProfileStoreError {
                XCTAssertEqual(error, .unknownBot("agent-missing"))
            }
        }
    }

    // MARK: - Roster updates

    func testRosterUpdatesPushCurrentThenEveryWrite() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("updates")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)
        let first = try await store.createBot(name: "甲", fishColor: nil, fishHairstyle: nil, description: nil)
        let second = try await store.createBot(name: "乙", fishColor: nil, fishHairstyle: nil, description: nil)

        let stream = await store.rosterUpdates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.bots.map(\.id), [first.id, second.id])
        XCTAssertEqual(initial?.mainBotID, first.id)

        let third = try await store.createBot(name: "丙", fishColor: nil, fishHairstyle: nil, description: nil)
        let afterCreate = await iterator.next()
        XCTAssertEqual(afterCreate?.bots.map(\.id), [first.id, second.id, third.id])

        try await store.setHidden(id: first.id, hidden: true)
        let afterHidden = await iterator.next()
        XCTAssertEqual(afterHidden?.bots.first(where: { $0.id == first.id })?.hiddenByUser, true)
        XCTAssertEqual(afterHidden?.visibleBots.map(\.id), [second.id, third.id])

        try await store.incrementUnread(id: third.id, by: 2)
        let afterUnread = await iterator.next()
        XCTAssertEqual(afterUnread?.bots.first(where: { $0.id == third.id })?.unreadCount, 2)

        try await store.touch(id: third.id, at: 9_999)
        let afterTouch = await iterator.next()
        XCTAssertEqual(afterTouch?.bots.first(where: { $0.id == third.id })?.lastMessageAt, 9_999)

        try await store.markRead(id: third.id)
        let afterRead = await iterator.next()
        XCTAssertEqual(afterRead?.bots.first(where: { $0.id == third.id })?.unreadCount, 0)

        let deleted = try await store.deleteBot(id: third.id)
        let afterDelete = await iterator.next()
        XCTAssertEqual(deleted.mainBotID, first.id)
        XCTAssertEqual(afterDelete?.bots.map(\.id), [first.id, second.id])
    }

    // MARK: - Preservation and corruption

    func testUnknownFieldsSurviveRosterWrites() async throws {
        let directory = try writeRosterFixture(
            ids: ["agent-a", "agent-b"], mainAgentId: "agent-a", unknownFields: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory)

        try await store.setHidden(id: "agent-b", hidden: true)
        try await store.setMainBotID("agent-b")
        _ = try await store.roster()

        let index = try readObject(indexURL(directory))
        XCTAssertEqual((index["futureTop"] as? [String: Any])?["keep"] as? Bool, true)
        let recordA = try record(index, id: "agent-a")
        XCTAssertEqual((recordA["futureRecord"] as? [String: Any])?["x"] as? [Int], [1, 2])
        let recordB = try record(index, id: "agent-b")
        XCTAssertEqual((recordB["futureRecord"] as? [String: Any])?["x"] as? [Int], [1, 2])
        XCTAssertEqual(recordB["hidden_by_user"] as? Bool, true)
        XCTAssertEqual(recordB["pinned"] as? Bool, true)
        let settings = try readObject(settingsURL(directory))
        XCTAssertEqual((settings["futureSettings"] as? [String: Any])?["keep"] as? String, "yes")
        XCTAssertEqual(settings["mainAgentId"] as? String, "agent-b")
    }

    func testCorruptIndexIsBackedUpAndNeverOverwritten() async throws {
        let directory = try ProfileTestSupport.temporaryDirectory("corrupt-roster")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "{not valid json"
        try Data(original.utf8).write(to: indexURL(directory))
        let store = makeStore(at: directory, clock: TestClock(77))

        let roster = try await store.roster()
        XCTAssertTrue(roster.bots.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backup = try XCTUnwrap(names.first { $0.hasPrefix("agents-index.json.corrupt-77") })
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8),
                       original)

        let created = try await store.createBot(
            name: "恢复", fishColor: nil, fishHairstyle: nil, description: nil)
        let recovered = try await store.profiles()
        XCTAssertEqual(recovered.map(\.id), [created.id])
        let main = try await store.mainBotID()
        XCTAssertEqual(main, created.id)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8),
                       original, "the moved-aside original must stay intact")
    }

    // MARK: - Upstream conformance vectors

    private struct Golden: Decodable {
        struct MainRepair: Decodable {
            let name: String
            let records: [String]
            let mainAgentId: String?
            let expectedMainAgentId: String?
        }

        struct DeleteMigration: Decodable {
            let name: String
            let records: [String]
            let mainAgentId: String?
            let deleteId: String
            let expectedRemaining: [String]
            let expectedMainAgentId: String?
        }

        struct PatchCase: Decodable {
            let name: String
            let input: [String: BotJSONValue]
            let expected: [String: BotJSONValue]
            let droppedKeys: [String]
        }

        struct RosterRules: Decodable {
            let mainPointerRepair: [MainRepair]
            let deleteMainMigration: [DeleteMigration]
            let normalizePatch: [PatchCase]
        }

        let rosterRules: RosterRules
    }

    private func golden() throws -> Golden {
        let url = try ProfileTestSupport.repositoryRoot()
            .appendingPathComponent("spec/bot/v1/golden/bot-profile.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    private func string(_ value: BotJSONValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    private func bool(_ value: BotJSONValue?) -> Bool? {
        guard case .bool(let bool) = value else { return nil }
        return bool
    }

    func testUpstreamMainPointerRepairVectors() async throws {
        for entry in try golden().rosterRules.mainPointerRepair {
            let directory = try writeRosterFixture(ids: entry.records, mainAgentId: entry.mainAgentId)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = makeStore(at: directory)
            let main = try await store.mainBotID()
            XCTAssertEqual(main, entry.expectedMainAgentId, entry.name)
            let settings = try readObject(settingsURL(directory))
            if let expected = entry.expectedMainAgentId {
                XCTAssertEqual(settings["mainAgentId"] as? String, expected, entry.name)
            } else {
                XCTAssertTrue(settings["mainAgentId"] is NSNull, entry.name)
            }
        }
    }

    func testUpstreamDeleteMainMigrationVectors() async throws {
        for entry in try golden().rosterRules.deleteMainMigration {
            let directory = try writeRosterFixture(ids: entry.records, mainAgentId: entry.mainAgentId)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = makeStore(at: directory)
            let deleted = try await store.deleteBot(id: entry.deleteId)
            XCTAssertEqual(deleted.removed.id, entry.deleteId, entry.name)
            XCTAssertEqual(deleted.mainBotID, entry.expectedMainAgentId, entry.name)
            let roster = try await store.roster()
            XCTAssertEqual(roster.bots.map(\.id), entry.expectedRemaining, entry.name)
            let settings = try readObject(settingsURL(directory))
            if let expected = entry.expectedMainAgentId {
                XCTAssertEqual(settings["mainAgentId"] as? String, expected, entry.name)
            } else {
                XCTAssertTrue(settings["mainAgentId"] is NSNull, entry.name)
            }
        }
    }

    func testUpstreamNormalizePatchVectors() async throws {
        for entry in try golden().rosterRules.normalizePatch {
            let directory = try writeRosterFixture(ids: ["agent-target"], mainAgentId: "agent-target")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = makeStore(at: directory)

            var patch = BotProfilePatch()
            if let name = string(entry.input["name"]) { patch.name = name }
            if let description = string(entry.input["description"]) { patch.description = description }
            if let color = string(entry.input["fish_color"]) {
                patch.fishColor = .some(BotProfileNormalizer.fishColor(color))
            }
            if let hidden = bool(entry.input["hidden_by_user"]) { patch.hiddenByUser = hidden }
            let updated = try await store.upsert(id: "agent-target", patch: patch)
            XCTAssertEqual(updated.id, "agent-target", entry.name)

            for (key, value) in entry.expected {
                switch key {
                case "name":
                    XCTAssertEqual(updated.name, string(value), entry.name)
                case "description":
                    XCTAssertEqual(updated.description, string(value), entry.name)
                case "fish_color":
                    let expected = BotProfileNormalizer.fishColor(string(value))
                    XCTAssertEqual(updated.fishColor, expected, entry.name)
                case "hidden_by_user":
                    XCTAssertEqual(updated.hiddenByUser, bool(value), entry.name)
                default:
                    XCTFail("\(entry.name): unhandled upstream patch field \(key)")
                }
            }

            let index = try readObject(indexURL(directory))
            let row = try record(index, id: "agent-target")
            XCTAssertEqual(row["id"] as? String, "agent-target", entry.name)
            for key in entry.droppedKeys {
                if key == "id" {
                    XCTAssertEqual(row["id"] as? String, "agent-target",
                                   "\(entry.name): an injected id must not replace the record identity")
                } else {
                    XCTAssertNil(row[key], "\(entry.name): \(key) must not be written to the record")
                }
            }
            let main = try await store.mainBotID()
            XCTAssertEqual(main, "agent-target", entry.name)
        }
    }
}

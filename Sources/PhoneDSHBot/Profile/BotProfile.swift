// SPDX-License-Identifier: MIT

import Foundation

/// One Bot record as stored in dsh-bot `agents-index.json` (record `schema: 3`).
///
/// The phone model keeps only the fields this round exposes. The store reads
/// and writes the file through a raw JSON object, so unknown fields from a
/// future/desktop record survive an update even though they are not part of
/// this struct.
public struct BotProfile: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// `nil` means automatic (seeded from the Bot id).
    public var fishColor: BotFishColor?
    /// `nil` means automatic (seeded from the Bot id).
    public var fishHairstyle: BotFishHairstyle?
    public var nameExplicit: Bool
    /// Milliseconds since the Unix epoch, matching dsh-bot.
    public var createdAt: Int64
    /// Milliseconds since the Unix epoch, matching dsh-bot.
    public var updatedAt: Int64

    public init(id: String, name: String, fishColor: BotFishColor? = nil,
                fishHairstyle: BotFishHairstyle? = nil, nameExplicit: Bool = false,
                createdAt: Int64 = 0, updatedAt: Int64 = 0) {
        self.id = id
        self.name = name
        self.fishColor = fishColor
        self.fishHairstyle = fishHairstyle
        self.nameExplicit = nameExplicit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Three-state patch for `BotProfileStore.upsert`:
/// - `nil` leaves the field untouched;
/// - `.some(value)` stores that value;
/// - `.some(nil)` returns the field to automatic (`null` in the file).
public struct BotProfilePatch: Sendable {
    public var name: String?
    public var fishColor: BotFishColor??
    public var fishHairstyle: BotFishHairstyle??

    public init(name: String? = nil, fishColor: BotFishColor?? = nil,
                fishHairstyle: BotFishHairstyle?? = nil) {
        self.name = name
        self.fishColor = fishColor
        self.fishHairstyle = fishHairstyle
    }
}

public enum BotProfileStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file is corrupt and could not be moved aside, so writing would
    /// destroy data that is still on disk.
    case unreadableFile(String)
    /// The caller supplied an empty Bot id.
    case invalidID
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unreadableFile(let path):
            return "Bot profile file is unreadable and could not be backed up: \(path)"
        case .invalidID:
            return "Bot profile id must not be empty"
        case .writeFailed(let detail):
            return "Bot profile write failed: \(detail)"
        }
    }
}

/// JSON-backed store for the desktop DSH Bot profile index.
///
/// Files (inside `directory`):
/// - `agents-index.json`: `{ "schemaVersion": 3, "agents": [record…] }`
/// - `runtime-settings.json`: `{ "version": 1, "mainAgentId": "<id>"|null, "updatedAt": <ms> }`
///
/// Both files keep unknown fields, are written atomically (temporary file +
/// replace) and carry `completeUntilFirstUserAuthentication` protection. A
/// missing file means "empty". A corrupt file is moved to
/// `<name>.corrupt-<ms>` before the store treats it as empty; if that backup
/// cannot be made, writes fail instead of overwriting the original.
public actor BotProfileStore {
    public typealias Clock = @Sendable () -> Int64

    private let directory: URL
    private let now: Clock
    private let encoder: JSONEncoder

    /// Human-readable description of the most recent recovered read error.
    /// Reads never throw for missing/corrupt files, so this is the diagnostic
    /// channel available to the caller.
    public private(set) var lastIssue: String?

    public init(directory: URL, now: @escaping Clock = {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }) {
        self.directory = directory
        self.now = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    // MARK: - Public reads

    public func profiles() throws -> [BotProfile] {
        let snapshot = readIndex()
        return snapshot.agents.compactMap { value -> BotProfile? in
            guard case .object(let object) = value else { return nil }
            return makeProfile(from: object)
        }
    }

    public func profile(id: String) throws -> BotProfile? {
        let snapshot = readIndex()
        guard let object = record(withID: id, in: snapshot.agents) else { return nil }
        return makeProfile(from: object)
    }

    public func mainBotID() throws -> String? {
        readSettings().mainAgentID
    }

    // MARK: - Public writes

    public func setMainBotID(_ id: String?) throws {
        let settings = readSettings()
        guard settings.writable else {
            throw BotProfileStoreError.unreadableFile(settingsURL.path)
        }
        try writeSettings(settings, mainAgentID: id, timestamp: now())
    }

    @discardableResult
    public func upsert(id: String, patch: BotProfilePatch) throws -> BotProfile {
        guard !id.isEmpty else { throw BotProfileStoreError.invalidID }
        let snapshot = readIndex()
        guard snapshot.writable else {
            throw BotProfileStoreError.unreadableFile(indexURL.path)
        }

        var agents = snapshot.agents
        let timestamp = now()
        let updated: BotProfile

        if let index = agents.firstIndex(where: { value in
            guard case .object(let object) = value else { return false }
            return string(object, "id") == id
        }) {
            let oldObject: [String: BotJSONValue]
            if case .object(let object) = agents[index] { oldObject = object } else { oldObject = [:] }
            var profile = makeProfile(from: oldObject)
                ?? BotProfile(id: id, name: id, createdAt: timestamp, updatedAt: timestamp)
            if let name = patch.name {
                profile.name = name
                profile.nameExplicit = true
            }
            if let color = patch.fishColor { profile.fishColor = color }
            if let hairstyle = patch.fishHairstyle { profile.fishHairstyle = hairstyle }
            profile.updatedAt = timestamp
            updated = profile
            agents[index] = .object(record(from: profile, preserving: oldObject))
        } else {
            var profile = BotProfile(id: id, name: patch.name ?? id,
                                     createdAt: timestamp, updatedAt: timestamp)
            if let name = patch.name {
                profile.name = name
                profile.nameExplicit = true
            }
            if let color = patch.fishColor { profile.fishColor = color }
            if let hairstyle = patch.fishHairstyle { profile.fishHairstyle = hairstyle }
            updated = profile
            agents.append(.object(record(from: profile, preserving: [:])))
        }

        try writeIndex(snapshot, agents: agents)
        return updated
    }

    /// First launch: create the single phoneDSH Bot as explicit blue/long and
    /// make it the main Bot. An existing `main` is returned unchanged.
    @discardableResult
    public func bootstrapMainIfNeeded(legacyName: String?) throws -> BotProfile {
        let snapshot = readIndex()
        guard snapshot.writable else {
            throw BotProfileStoreError.unreadableFile(indexURL.path)
        }
        if let oldObject = record(withID: "main", in: snapshot.agents),
           let existing = makeProfile(from: oldObject) {
            // A previous bootstrap may have written the record and then failed
            // before the pointer. Do not change the profile, but repair the
            // pointer when it is absent (never override a present pointer).
            let settings = readSettings()
            if settings.mainAgentID == nil {
                guard settings.writable else {
                    throw BotProfileStoreError.unreadableFile(settingsURL.path)
                }
                try writeSettings(settings, mainAgentID: existing.id, timestamp: now())
            }
            return existing
        }

        let timestamp = now()
        let profile = BotProfile(
            id: "main",
            name: legacyName ?? "大肥鱼",
            fishColor: .blue,
            fishHairstyle: .long,
            nameExplicit: legacyName != nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var agents = snapshot.agents
        agents.append(.object(record(from: profile, preserving: [:])))
        try writeIndex(snapshot, agents: agents)

        let settings = readSettings()
        guard settings.writable else {
            throw BotProfileStoreError.unreadableFile(settingsURL.path)
        }
        try writeSettings(settings, mainAgentID: profile.id, timestamp: timestamp)
        return profile
    }

    // MARK: - File locations

    private var indexURL: URL { directory.appendingPathComponent("agents-index.json") }
    private var settingsURL: URL { directory.appendingPathComponent("runtime-settings.json") }

    // MARK: - Read model

    private struct IndexSnapshot {
        var base: [String: BotJSONValue]
        var agents: [BotJSONValue]
        var writable: Bool
    }

    private struct SettingsSnapshot {
        var base: [String: BotJSONValue]
        var mainAgentID: String?
        var writable: Bool
    }

    private func readIndex() -> IndexSnapshot {
        let loaded = readObject(at: indexURL, label: "agents-index.json")
        guard loaded.writable else {
            return IndexSnapshot(base: [:], agents: [], writable: false)
        }

        var agents: [BotJSONValue] = []
        if let rawAgents = loaded.object["agents"] {
            guard case .array(let values) = rawAgents else {
                return recoverIndex(after: "agents-index.json has a non-array agents member")
            }
            agents = values
        }
        return IndexSnapshot(base: loaded.object, agents: agents, writable: true)
    }

    private func recoverIndex(after detail: String) -> IndexSnapshot {
        let backup = backupCorrupt(indexURL)
        if backup {
            lastIssue = "\(detail); original moved to \(indexURL.lastPathComponent).corrupt-*"
            return IndexSnapshot(base: [:], agents: [], writable: true)
        }
        lastIssue = "\(detail); original could not be moved, refusing to overwrite it"
        return IndexSnapshot(base: [:], agents: [], writable: false)
    }

    private func readSettings() -> SettingsSnapshot {
        let loaded = readObject(at: settingsURL, label: "runtime-settings.json")
        guard loaded.writable else {
            return SettingsSnapshot(base: [:], mainAgentID: nil, writable: false)
        }
        let main = loaded.object["mainAgentId"].flatMap { value -> String? in
            guard case .string(let id) = value else { return nil }
            return id
        }
        return SettingsSnapshot(base: loaded.object, mainAgentID: main, writable: true)
    }

    private func readObject(at url: URL, label: String) -> (object: [String: BotJSONValue], writable: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([:], true)
        }
        do {
            let data = try Data(contentsOf: url)
            let value = try BotJSONValue.parse(data)
            guard case .object(let object) = value else {
                throw BotProfileStoreError.writeFailed("\(label) root is not a JSON object")
            }
            return (object, true)
        } catch {
            let backedUp = backupCorrupt(url)
            if backedUp {
                lastIssue = "\(label) unreadable: \(error); original moved to \(label).corrupt-*"
                return ([:], true)
            }
            lastIssue = "\(label) unreadable: \(error); original could not be moved, refusing to overwrite it"
            return ([:], false)
        }
    }

    // MARK: - Encoding

    private func record(withID id: String, in agents: [BotJSONValue]) -> [String: BotJSONValue]? {
        for value in agents {
            guard case .object(let object) = value else { continue }
            if string(object, "id") == id { return object }
        }
        return nil
    }

    private func makeProfile(from object: [String: BotJSONValue]) -> BotProfile? {
        guard let id = string(object, "id"), !id.isEmpty else { return nil }
        let name = string(object, "name") ?? ""
        let createdAt = int64(object, "created_at") ?? 0
        return BotProfile(
            id: id,
            name: name,
            fishColor: BotProfileNormalizer.fishColor(string(object, "fish_color")),
            fishHairstyle: BotProfileNormalizer.fishHairstyle(string(object, "fish_hairstyle")),
            nameExplicit: bool(object, "name_explicit") ?? false,
            createdAt: createdAt,
            updatedAt: int64(object, "updated_at") ?? createdAt
        )
    }

    private func record(from profile: BotProfile,
                        preserving old: [String: BotJSONValue]) -> [String: BotJSONValue] {
        var object = old
        if object["schema"] == nil { object["schema"] = .number(3) }
        object["id"] = .string(profile.id)
        object["name"] = .string(profile.name)
        if let color = profile.fishColor {
            object["fish_color"] = .string(color.rawValue)
        } else {
            object["fish_color"] = .null
        }
        if let hairstyle = profile.fishHairstyle {
            object["fish_hairstyle"] = .string(hairstyle.rawValue)
        } else {
            object["fish_hairstyle"] = .null
        }
        object["name_explicit"] = .bool(profile.nameExplicit)
        object["created_at"] = .number(Double(profile.createdAt))
        object["updated_at"] = .number(Double(profile.updatedAt))
        return object
    }

    private func writeIndex(_ snapshot: IndexSnapshot, agents: [BotJSONValue]) throws {
        var object = snapshot.base
        if object["schemaVersion"] == nil { object["schemaVersion"] = .number(3) }
        object["agents"] = .array(agents)
        try writeObject(object, to: indexURL)
    }

    private func writeSettings(_ snapshot: SettingsSnapshot, mainAgentID: String?, timestamp: Int64) throws {
        var object = snapshot.base
        if object["version"] == nil { object["version"] = .number(1) }
        object["mainAgentId"] = mainAgentID.map { BotJSONValue.string($0) } ?? BotJSONValue.null
        object["updatedAt"] = .number(Double(timestamp))
        try writeObject(object, to: settingsURL)
    }

    private func string(_ object: [String: BotJSONValue], _ key: String) -> String? {
        guard case .string(let value) = object[key] else { return nil }
        return value
    }

    private func bool(_ object: [String: BotJSONValue], _ key: String) -> Bool? {
        guard case .bool(let value) = object[key] else { return nil }
        return value
    }

    private func int64(_ object: [String: BotJSONValue], _ key: String) -> Int64? {
        guard case .number(let value) = object[key], value.isFinite,
              value.rounded() == value,
              value >= -9_223_372_036_854_775_808.0,
              value < 9_223_372_036_854_775_808.0 else { return nil }
        return Int64(value)
    }

    // MARK: - Atomic file IO

    private func writeObject(_ object: [String: BotJSONValue], to url: URL) throws {
        do {
            try ensureDirectory()
            var data = try encoder.encode(object)
            data.append(0x0A)
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            do {
                try data.write(to: temporary)
                applyProtection(to: temporary, directory: false)
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: url)
                }
                applyProtection(to: url, directory: false)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        } catch let error as BotProfileStoreError {
            throw error
        } catch {
            throw BotProfileStoreError.writeFailed("\(url.lastPathComponent): \(error)")
        }
    }

    private func ensureDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
    }

    private func applyProtection(to url: URL, directory: Bool) {
        let manager = FileManager.default
        try? manager.setAttributes([.posixPermissions: directory ? 0o700 : 0o600],
                                   ofItemAtPath: url.path)
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    /// Moves an unreadable file aside. Returns `true` when the move succeeded;
    /// `false` means the original is still in place and must not be overwritten.
    private func backupCorrupt(_ url: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return true }
        let stamp = now()
        var destination = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)")
        var suffix = 1
        while manager.fileExists(atPath: destination.path) {
            destination = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)-\(suffix)")
            suffix += 1
        }
        do {
            try manager.moveItem(at: url, to: destination)
            return true
        } catch {
            return false
        }
    }
}

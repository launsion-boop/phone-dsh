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
    /// Free-form profile text, at most 2000 UTF-16 units (dsh-bot truncates
    /// the same field on write). Stored as `description`.
    public var description: String
    /// The sidebar hides this Bot but keeps it in the roster. Stored as
    /// `hidden_by_user`.
    public var hiddenByUser: Bool
    /// A pinned Bot is kept at the top of the sidebar. Setting a Bot as the
    /// main Bot pins it automatically. Stored as `pinned`.
    public var pinned: Bool
    /// Per-Bot unread count, never negative. Stored as `unread_count`.
    public var unreadCount: Int
    /// Milliseconds since the Unix epoch of the last message, or `nil` when
    /// the Bot has no message timestamp. Stored as `last_message_at`.
    public var lastMessageAt: Int64?

    public init(id: String, name: String, fishColor: BotFishColor? = nil,
                fishHairstyle: BotFishHairstyle? = nil, nameExplicit: Bool = false,
                createdAt: Int64 = 0, updatedAt: Int64 = 0,
                description: String = "", hiddenByUser: Bool = false, pinned: Bool = false,
                unreadCount: Int = 0, lastMessageAt: Int64? = nil) {
        self.id = id
        self.name = name
        self.fishColor = fishColor
        self.fishHairstyle = fishHairstyle
        self.nameExplicit = nameExplicit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.description = description
        self.hiddenByUser = hiddenByUser
        self.pinned = pinned
        self.unreadCount = unreadCount
        self.lastMessageAt = lastMessageAt
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
    /// `nil` leaves the description untouched; any value is truncated to the
    /// 2000 UTF-16 unit record limit.
    public var description: String?
    /// `nil` leaves the sidebar visibility untouched.
    public var hiddenByUser: Bool?

    public init(name: String? = nil, fishColor: BotFishColor?? = nil,
                fishHairstyle: BotFishHairstyle?? = nil, description: String? = nil,
                hiddenByUser: Bool? = nil) {
        self.name = name
        self.fishColor = fishColor
        self.fishHairstyle = fishHairstyle
        self.description = description
        self.hiddenByUser = hiddenByUser
    }
}

public enum BotProfileStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The file is corrupt and could not be moved aside, so writing would
    /// destroy data that is still on disk.
    case unreadableFile(String)
    /// The caller supplied an empty Bot id.
    case invalidID
    /// A Bot name was empty after trimming or longer than 60 characters.
    case invalidName(String)
    /// The roster would become empty; the phone client always keeps one Bot.
    case lastBot
    /// The id does not name a record in `agents-index.json`.
    case unknownBot(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unreadableFile(let path):
            return "Bot profile file is unreadable and could not be backed up: \(path)"
        case .invalidID:
            return "Bot profile id must not be empty"
        case .invalidName(let name):
            return "Bot name must be non-empty after trimming and at most 60 characters: \(name)"
        case .lastBot:
            return "The only Bot in the roster cannot be deleted"
        case .unknownBot(let id):
            return "Unknown Bot: \(id)"
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
    private var rosterContinuations: [UUID: AsyncStream<BotRoster>.Continuation] = [:]

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

    /// The full roster in insertion order, including hidden Bots, plus the
    /// main-Bot pointer after repair. An empty/dangling pointer is repaired to
    /// the first Bot (insertion order) and written back.
    public func roster() throws -> BotRoster {
        let loaded = try loadRoster(repairMain: true)
        if loaded.repaired {
            broadcast(loaded.roster)
        }
        return loaded.roster
    }

    /// The repaired main-Bot id. A nil, dangling or unknown pointer falls back
    /// to the first Bot in insertion order and is written back to
    /// `runtime-settings.json`. With no Bots the pointer is repaired to nil.
    public func mainBotID() throws -> String? {
        let loaded = try loadRoster(repairMain: true)
        if loaded.repaired {
            broadcast(loaded.roster)
        }
        return loaded.roster.mainBotID
    }

    /// Roster changes: the current roster is yielded immediately on
    /// subscription, then one snapshot per successful write. The stream is
    /// unbounded so a slow consumer does not lose an intermediate write.
    public func rosterUpdates() -> AsyncStream<BotRoster> {
        // Run the repair before registering: a repair is itself a write, so
        // existing subscribers get it, while this subscriber gets the repaired
        // roster as its single initial element.
        let current = (try? roster()) ?? BotRoster(bots: [], mainBotID: nil)
        let (stream, continuation) = AsyncStream<BotRoster>.makeStream()
        let token = UUID()
        rosterContinuations[token] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeRosterContinuation(token) }
        }
        continuation.yield(current)
        return stream
    }

    // MARK: - Public writes

    public func setMainBotID(_ id: String?) throws {
        let snapshot = readIndex()
        guard snapshot.writable else {
            throw BotProfileStoreError.unreadableFile(indexURL.path)
        }
        let settings = readSettings()
        guard settings.writable else {
            throw BotProfileStoreError.unreadableFile(settingsURL.path)
        }
        var agents = snapshot.agents
        if let id, index(of: id, in: agents) == nil {
            throw BotProfileStoreError.unknownBot(id)
        }
        try writeSettings(settings, mainAgentID: id, timestamp: now())
        if let id, pinRecord(id: id, in: &agents) {
            try writeIndex(snapshot, agents: agents)
        }
        publishCurrentRoster()
    }

    /// Create a Bot with a fresh `agent-<16 lowercase hex>` id.
    ///
    /// The name is trimmed, must be non-empty and at most 60 characters. A nil
    /// colour/hairstyle writes explicit `blue`/`long` so the desktop and the
    /// phone render the same look; the first Bot in an empty roster becomes the
    /// main Bot (and is pinned).
    @discardableResult
    public func createBot(name: String, fishColor: BotFishColor?,
                          fishHairstyle: BotFishHairstyle?,
                          description: String?) throws -> BotProfile {
        let trimmedName = try validateName(name)
        let snapshot = readIndex()
        guard snapshot.writable else {
            throw BotProfileStoreError.unreadableFile(indexURL.path)
        }
        let settings = readSettings()
        guard settings.writable else {
            throw BotProfileStoreError.unreadableFile(settingsURL.path)
        }

        let timestamp = now()
        let existing = snapshot.agents.compactMap { value -> BotProfile? in
            guard case .object(let object) = value else { return nil }
            return makeProfile(from: object)
        }
        let isFirst = existing.isEmpty
        let profile = BotProfile(
            id: newBotID(existing: snapshot.agents),
            name: trimmedName,
            fishColor: fishColor ?? .blue,
            fishHairstyle: fishHairstyle ?? .long,
            nameExplicit: true,
            createdAt: timestamp,
            updatedAt: timestamp,
            description: clampedDescription(description ?? ""),
            hiddenByUser: false,
            pinned: isFirst,
            unreadCount: 0,
            lastMessageAt: nil
        )

        var agents = snapshot.agents
        agents.append(.object(record(from: profile, preserving: [:])))
        try writeIndex(snapshot, agents: agents)
        if isFirst {
            try writeSettings(settings, mainAgentID: profile.id, timestamp: timestamp)
        }
        publishCurrentRoster()
        return profile
    }

    /// Delete one Bot. The phone client keeps at least one Bot, so deleting the
    /// last record throws `.lastBot`. When the pointer names the removed Bot it
    /// moves to the first remaining Bot in insertion order; a dangling pointer
    /// is repaired at the same time. The new main Bot is pinned.
    @discardableResult
    public func deleteBot(id: String) throws -> (removed: BotProfile, mainBotID: String?) {
        let snapshot = readIndex()
        guard snapshot.writable else {
            throw BotProfileStoreError.unreadableFile(indexURL.path)
        }
        let settings = readSettings()
        guard settings.writable else {
            throw BotProfileStoreError.unreadableFile(settingsURL.path)
        }
        var agents = snapshot.agents
        guard let removedIndex = index(of: id, in: agents),
              case .object(let removedObject) = agents[removedIndex],
              let removed = makeProfile(from: removedObject) else {
            throw BotProfileStoreError.unknownBot(id)
        }
        let bots = agents.compactMap { value -> BotProfile? in
            guard case .object(let object) = value else { return nil }
            return makeProfile(from: object)
        }
        guard bots.count > 1 else {
            throw BotProfileStoreError.lastBot
        }

        let oldMain = resolveMainID(in: bots, stored: settings.mainAgentID)
        agents.remove(at: removedIndex)
        let remaining = agents.compactMap { value -> BotProfile? in
            guard case .object(let object) = value else { return nil }
            return makeProfile(from: object)
        }
        let newMain: String?
        if oldMain == id {
            newMain = remaining.first?.id
        } else if let oldMain, remaining.contains(where: { $0.id == oldMain }) {
            newMain = oldMain
        } else {
            newMain = remaining.first?.id
        }
        if let newMain {
            _ = pinRecord(id: newMain, in: &agents)
        }

        try writeIndex(snapshot, agents: agents)
        if newMain != settings.mainAgentID {
            try writeSettings(settings, mainAgentID: newMain, timestamp: now())
        }
        publishCurrentRoster()
        return (removed, newMain)
    }

    /// Hide or unhide a Bot. Hidden Bots stay in `roster().bots` and are
    /// excluded from `visibleBots`.
    public func setHidden(id: String, hidden: Bool) throws {
        _ = try mutateProfile(id: id) { profile in
            profile.hiddenByUser = hidden
            return true
        }
    }

    /// Clear a Bot's unread counter. Already-zero counters are a no-op and do
    /// not emit a roster update.
    public func markRead(id: String) throws {
        _ = try mutateProfile(id: id) { profile in
            guard profile.unreadCount != 0 else { return false }
            profile.unreadCount = 0
            return true
        }
    }

    /// Add to a Bot's unread counter. `by` is clamped to at least 1, matching
    /// dsh-bot `bumpUnread`.
    public func incrementUnread(id: String, by: Int = 1) throws {
        let step = max(1, by)
        _ = try mutateProfile(id: id) { profile in
            let (sum, overflow) = profile.unreadCount.addingReportingOverflow(step)
            profile.unreadCount = overflow ? Int.max : max(0, sum)
            return true
        }
    }

    /// Set or clear the last-message timestamp. `nil` writes JSON `null`.
    public func touch(id: String, at: Int64?) throws {
        _ = try mutateProfile(id: id) { profile in
            profile.lastMessageAt = at
            return true
        }
    }

    @discardableResult
    public func upsert(id: String, patch: BotProfilePatch) throws -> BotProfile {
        guard !id.isEmpty else { throw BotProfileStoreError.invalidID }
        let normalizedName = try patch.name.map { try validateName($0) }
        let clampedPatchDescription = patch.description.map(clampedDescription)
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
            if let name = normalizedName {
                profile.name = name
                profile.nameExplicit = true
            }
            if let color = patch.fishColor { profile.fishColor = color }
            if let hairstyle = patch.fishHairstyle { profile.fishHairstyle = hairstyle }
            if let description = clampedPatchDescription { profile.description = description }
            if let hidden = patch.hiddenByUser { profile.hiddenByUser = hidden }
            profile.updatedAt = timestamp
            updated = profile
            agents[index] = .object(record(from: profile, preserving: oldObject))
        } else {
            var profile = BotProfile(id: id, name: id,
                                     createdAt: timestamp, updatedAt: timestamp)
            if let name = normalizedName {
                profile.name = name
                profile.nameExplicit = true
            }
            if let color = patch.fishColor { profile.fishColor = color }
            if let hairstyle = patch.fishHairstyle { profile.fishHairstyle = hairstyle }
            if let description = clampedPatchDescription { profile.description = description }
            if let hidden = patch.hiddenByUser { profile.hiddenByUser = hidden }
            updated = profile
            agents.append(.object(record(from: profile, preserving: [:])))
        }

        try writeIndex(snapshot, agents: agents)
        publishCurrentRoster()
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
                publishCurrentRoster()
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
        publishCurrentRoster()
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

    // MARK: - Roster rules

    private struct RosterLoad {
        var roster: BotRoster
        var repaired: Bool
    }

    /// Resolve the pointer against the records, repair it (and pin the main
    /// Bot) when asked, and return the roster that was actually observed.
    private func loadRoster(repairMain: Bool) throws -> RosterLoad {
        let snapshot = readIndex()
        guard snapshot.writable else {
            throw BotProfileStoreError.unreadableFile(indexURL.path)
        }
        var agents = snapshot.agents
        var bots = agents.compactMap { value -> BotProfile? in
            guard case .object(let object) = value else { return nil }
            return makeProfile(from: object)
        }
        let settings = readSettings()
        guard settings.writable else {
            throw BotProfileStoreError.unreadableFile(settingsURL.path)
        }

        let resolved = resolveMainID(in: bots, stored: settings.mainAgentID)
        var repaired = false
        if repairMain {
            if resolved != settings.mainAgentID {
                try writeSettings(settings, mainAgentID: resolved, timestamp: now())
                repaired = true
            }
            if let resolved, let index = bots.firstIndex(where: { $0.id == resolved }),
               !bots[index].pinned, pinRecord(id: resolved, in: &agents) {
                try writeIndex(snapshot, agents: agents)
                bots[index].pinned = true
                repaired = true
            }
        }
        return RosterLoad(roster: BotRoster(bots: bots, mainBotID: resolved), repaired: repaired)
    }

    /// A valid stored pointer wins; nil, dangling and empty-roster pointers
    /// fall back to the first record in insertion order.
    private func resolveMainID(in bots: [BotProfile], stored: String?) -> String? {
        if let stored, bots.contains(where: { $0.id == stored }) {
            return stored
        }
        return bots.first?.id
    }

    /// Mutate one record in place. A `false` return means "no observable
    /// change", so the file is left alone and no roster update is emitted.
    @discardableResult
    private func mutateProfile(id: String, _ body: (inout BotProfile) -> Bool) throws -> BotProfile {
        let snapshot = readIndex()
        guard snapshot.writable else {
            throw BotProfileStoreError.unreadableFile(indexURL.path)
        }
        var agents = snapshot.agents
        guard let index = index(of: id, in: agents),
              case .object(let old) = agents[index],
              var profile = makeProfile(from: old) else {
            throw BotProfileStoreError.unknownBot(id)
        }
        if body(&profile) {
            profile.updatedAt = now()
            agents[index] = .object(record(from: profile, preserving: old))
            try writeIndex(snapshot, agents: agents)
            publishCurrentRoster()
        }
        return profile
    }

    private func index(of id: String, in agents: [BotJSONValue]) -> Int? {
        agents.firstIndex { value in
            guard case .object(let object) = value else { return false }
            return string(object, "id") == id
        }
    }

    /// Set `pinned = true` on a raw record without changing `updated_at`,
    /// matching dsh-bot `setMainAgent`/`ensurePinnedAgent`.
    @discardableResult
    private func pinRecord(id: String, in agents: inout [BotJSONValue]) -> Bool {
        guard let index = index(of: id, in: agents),
              case .object(var object) = agents[index],
              bool(object, "pinned") != true else { return false }
        object["pinned"] = .bool(true)
        agents[index] = .object(object)
        return true
    }

    private func publishCurrentRoster() {
        guard !rosterContinuations.isEmpty else { return }
        guard let loaded = try? loadRoster(repairMain: false) else { return }
        broadcast(loaded.roster)
    }

    private func broadcast(_ roster: BotRoster) {
        for continuation in rosterContinuations.values {
            continuation.yield(roster)
        }
    }

    private func removeRosterContinuation(_ token: UUID) {
        rosterContinuations.removeValue(forKey: token)
    }

    private func validateName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 60 else {
            throw BotProfileStoreError.invalidName(raw)
        }
        return trimmed
    }

    /// Truncate to the record's 2000 UTF-16 unit budget without splitting a
    /// surrogate pair or grapheme.
    private func clampedDescription(_ value: String) -> String {
        guard value.utf16.count > 2_000 else { return value }
        var result = ""
        var units = 0
        for character in value {
            let width = character.utf16.count
            if units + width > 2_000 { break }
            result.append(character)
            units += width
        }
        return result
    }

    private func newBotID(existing agents: [BotJSONValue]) -> String {
        var used = Set<String>()
        for value in agents {
            guard case .object(let object) = value,
                  let id = string(object, "id") else { continue }
            used.insert(id)
        }
        var candidate: String
        repeat {
            var generator = SystemRandomNumberGenerator()
            let value = UInt64.random(in: UInt64.min...UInt64.max, using: &generator)
            let hex = String(value, radix: 16)
            candidate = "agent-" + String(repeating: "0", count: 16 - hex.count) + hex
        } while used.contains(candidate)
        return candidate
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
        let unread = max(0, Int(clamping: int64(object, "unread_count") ?? 0))
        return BotProfile(
            id: id,
            name: name,
            fishColor: BotProfileNormalizer.fishColor(string(object, "fish_color")),
            fishHairstyle: BotProfileNormalizer.fishHairstyle(string(object, "fish_hairstyle")),
            nameExplicit: bool(object, "name_explicit") ?? false,
            createdAt: createdAt,
            updatedAt: int64(object, "updated_at") ?? createdAt,
            description: clampedDescription(string(object, "description") ?? ""),
            hiddenByUser: bool(object, "hidden_by_user") ?? false,
            pinned: bool(object, "pinned") ?? false,
            unreadCount: unread,
            lastMessageAt: int64(object, "last_message_at")
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
        object["description"] = .string(profile.description)
        object["hidden_by_user"] = .bool(profile.hiddenByUser)
        object["pinned"] = .bool(profile.pinned)
        object["unread_count"] = .number(Double(profile.unreadCount))
        object["last_message_at"] = profile.lastMessageAt.map { BotJSONValue.number(Double($0)) } ?? .null
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

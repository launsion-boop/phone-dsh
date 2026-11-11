// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhoneDSHBot

/// Live, sidebar-ready runtime snapshot of one Bot. The values come from the
/// Bot's own runtime unit and its projected rows; the roster model only stores
/// them so one observable object can serve the selected page and the sidebar.
struct BotRosterRuntimeState: Equatable, Sendable {
    var fishState: BotFishLifecycle = .idle
    var activity: BotActivity?
    var isRunning = false
    var pendingApprovalCount = 0
    /// One-shot FishAction overlay for every avatar of this Bot. It is
    /// cosmetic; `fishState` remains the lifecycle base underneath.
    var reaction: BotFishReaction?
    var runtimeState: BotRuntimeState = .idle
}

/// One sidebar row: durable profile fields plus the live runtime snapshot.
/// `unreadCount` and `lastMessageAt` are the durable profile values; the live
/// fields are refreshed by `BotRosterModel.setRuntimeState`.
struct BotRosterEntry: Identifiable, Equatable {
    let id: String
    var name: String
    var description: String
    var appearance: BotFishAppearance
    var isMainBot: Bool
    var isHidden: Bool
    var unreadCount: Int
    var lastMessageAt: Int64?
    var runtime: BotRosterRuntimeState

    var fishState: BotFishLifecycle { runtime.fishState }
    var activity: BotActivity? { runtime.activity }
    var isRunning: Bool { runtime.isRunning }
    var pendingApprovalCount: Int { runtime.pendingApprovalCount }
    var reaction: BotFishReaction? { runtime.reaction }
}

/// The one App-side roster view. It owns selection, unread/read state and the
/// per-Bot live status cache; the production hub owns each Bot's
/// `BotChatModel`/`BotInfoModel`.
///
/// Public surface consumed by the wave-3 sidebar:
/// - `entries` / `visibleEntries` (main Bot first, hidden Bots excluded from
///   `visibleEntries` only),
/// - `selectedBotID` / `selectedEntry`,
/// - `select(_:)` (persists + `markRead`),
/// - `setRuntimeState(_:for:)` to feed live fish/activity/approval state,
/// - `setMain(_:)`, `setHidden(_:hidden:)`, `create(...)`.
@MainActor
@Observable
final class BotRosterModel {
    private(set) var roster: BotRoster
    private(set) var selectedBotID: String?
    private(set) var runtimeStates: [String: BotRosterRuntimeState] = [:]
    var loadError: String?
    var actionError: String?
    /// The reason the last delete attempt was refused (for example the last
    /// Bot in the roster). The info page surfaces this verbatim.
    var deletionError: String?
    /// Called when `anyBotRunning` changes. `ChatModel` uses this instead of
    /// polling once a second; no other view reads it.
    @ObservationIgnored
    var onAnyBotRunningChange: ((Bool) -> Void)?
    /// Fired after every applied roster snapshot. The production composition
    /// keeps its synchronous main-Bot pointer in sync through this.
    @ObservationIgnored
    var onRosterChange: ((BotRoster) -> Void)?

    private let store: BotProfileStore
    private let selectionStore: BotSelectionStore
    private let defaults: UserDefaults
    private let selectedKey = BotSelectionDefaults.key
    private var streamTask: Task<Void, Never>?
    private var started = false

    init(roster: BotRoster, selectedBotID: String?, store: BotProfileStore,
         selectionStore: BotSelectionStore, defaults: UserDefaults = .standard) {
        self.roster = roster
        self.store = store
        self.selectionStore = selectionStore
        self.defaults = defaults
        let restored = BotMainPointerRouting.restoredSelection(
            selectedBotID ?? defaults.string(forKey: selectedKey), in: roster)
        self.selectedBotID = restored
        if let restored { defaults.set(restored, forKey: selectedKey) }
        Task { await selectionStore.set(restored) }
    }

    var mainBotID: String? { roster.mainBotID }
    var mainBot: BotProfile? { BotMainPointerRouting.mainBot(in: roster) }
    var bots: [BotProfile] { roster.bots }
    var visibleBots: [BotProfile] { roster.visibleBots }

    /// Insertion order, with the main Bot lifted first for the sidebar.
    var entries: [BotRosterEntry] {
        let main = roster.bots.filter { $0.id == roster.mainBotID }
        let rest = roster.bots.filter { $0.id != roster.mainBotID }
        return (main + rest).map { entry(for: $0) }
    }

    var visibleEntries: [BotRosterEntry] { entries.filter { !$0.isHidden } }

    var selectedEntry: BotRosterEntry? {
        guard let selectedBotID else { return nil }
        return entries.first { $0.id == selectedBotID }
    }

    var selectedIsMainBot: Bool { selectedBotID != nil && selectedBotID == roster.mainBotID }

    var anyBotRunning: Bool { entries.contains { $0.isRunning } }

    func entry(for botID: String) -> BotRosterEntry? {
        guard let profile = roster.bots.first(where: { $0.id == botID }) else { return nil }
        return entry(for: profile)
    }

    func profile(for botID: String) -> BotProfile? {
        roster.bots.first { $0.id == botID }
    }

    func appearance(for botID: String) -> BotFishAppearance? {
        profile(for: botID).map(BotFishAppearance.resolve)
    }

    func displayName(for botID: String) -> String? {
        profile(for: botID)?.name
    }

    /// Starts the durable roster subscription. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        streamTask = Task { [weak self, store] in
            let updates = await store.rosterUpdates()
            for await snapshot in updates {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        started = false
    }

    func refresh() async {
        do {
            apply(try await store.roster())
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func select(_ botID: String) async {
        guard roster.bots.contains(where: { $0.id == botID }) else { return }
        selectedBotID = botID
        defaults.set(botID, forKey: selectedKey)
        await selectionStore.set(botID)
        actionError = nil
        do { try await store.markRead(id: botID) }
        catch { actionError = "标记已读失败：\(error.localizedDescription)" }
    }

    func markRead(_ botID: String) async {
        do { try await store.markRead(id: botID) }
        catch { actionError = "标记已读失败：\(error.localizedDescription)" }
    }

    /// Touch the durable message timestamp and optionally add one unread
    /// count. The caller decides `bumpUnread` with `BotUnreadRules`.
    func noteMessage(to botID: String, bumpUnread: Bool,
                     at timestamp: Int64? = Int64(Date().timeIntervalSince1970 * 1_000)) async {
        do {
            if bumpUnread { try await store.incrementUnread(id: botID) }
            try await store.touch(id: botID, at: timestamp)
        } catch {
            actionError = "更新未读失败：\(error.localizedDescription)"
        }
    }

    func setMain(_ botID: String) async {
        do {
            try await store.setMainBotID(botID)
            actionError = nil
            await refresh()
        } catch {
            actionError = "设为主 Bot 失败：\(error.localizedDescription)"
        }
    }

    func setHidden(_ botID: String, hidden: Bool) async {
        do {
            try await store.setHidden(id: botID, hidden: hidden)
            actionError = nil
            await refresh()
        } catch {
            actionError = "更新隐藏状态失败：\(error.localizedDescription)"
        }
    }

    /// Renames one record through the profile store, then refreshes the
    /// roster. The store owns the trimmed/non-empty/<= 60 UTF-16-unit rules.
    func rename(_ botID: String, to name: String) async throws {
        _ = try await store.upsert(id: botID, patch: BotProfilePatch(name: name))
        actionError = nil
        await refresh()
    }

    @discardableResult
    func create(name: String, description: String = "",
                color: BotFishColor? = nil,
                hairstyle: BotFishHairstyle? = nil) async throws -> BotProfile {
        let created = try await store.createBot(
            name: name, fishColor: color, fishHairstyle: hairstyle,
            description: description.isEmpty ? nil : description)
        await refresh()
        return created
    }

    /// Deletes the durable profile record. The full cascade is owned by the
    /// production composition; this is exposed for wave-3 management screens
    /// and for the last-Bot error text.
    @discardableResult
    func deleteProfile(_ botID: String) async throws -> (removed: BotProfile, mainBotID: String?) {
        let result = try await store.deleteBot(id: botID)
        await refresh()
        if selectedBotID == botID {
            await select(result.mainBotID ?? roster.bots.first?.id ?? "")
        }
        return result
    }

    func setRuntimeState(_ state: BotRosterRuntimeState, for botID: String) {
        guard roster.bots.contains(where: { $0.id == botID }) else { return }
        let wasRunning = anyBotRunning
        if runtimeStates[botID] != state { runtimeStates[botID] = state }
        let isRunning = anyBotRunning
        if wasRunning != isRunning { onAnyBotRunningChange?(isRunning) }
    }

    func runtimeState(for botID: String) -> BotRosterRuntimeState {
        runtimeStates[botID] ?? BotRosterRuntimeState()
    }

    // MARK: - Private

    private func entry(for profile: BotProfile) -> BotRosterEntry {
        BotRosterEntry(
            id: profile.id,
            name: profile.name,
            description: profile.description,
            appearance: BotFishAppearance.resolve(profile),
            isMainBot: profile.id == roster.mainBotID,
            isHidden: profile.hiddenByUser,
            unreadCount: profile.unreadCount,
            lastMessageAt: profile.lastMessageAt,
            runtime: runtimeState(for: profile.id))
    }

    private func apply(_ snapshot: BotRoster) {
        let wasRunning = anyBotRunning
        let previousSelection = selectedBotID
        roster = snapshot
        let stillExists = selectedBotID.map { id in snapshot.bots.contains { $0.id == id } } ?? false
        if !stillExists {
            let restored = BotMainPointerRouting.restoredSelection(
                previousSelection ?? defaults.string(forKey: selectedKey), in: snapshot)
            selectedBotID = restored
            if let restored {
                defaults.set(restored, forKey: selectedKey)
                Task { await selectionStore.set(restored) }
                Task { [weak self] in await self?.markRead(restored) }
            } else {
                defaults.removeObject(forKey: selectedKey)
                Task { await selectionStore.set(nil) }
            }
        }
        let ids = Set(snapshot.bots.map(\.id))
        runtimeStates = runtimeStates.filter { ids.contains($0.key) }
        let isRunning = anyBotRunning
        if wasRunning != isRunning { onAnyBotRunningChange?(isRunning) }
        onRosterChange?(snapshot)
    }
}

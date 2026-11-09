// SPDX-License-Identifier: MIT

import Combine
import Foundation
import PhoneDSHBot

/// The Bot page's single in-memory view of the durable Bot profile
/// (`agents-index.json`). The profile is the authority for the displayed name
/// and for the fish appearance; the existing `renamed` system event keeps
/// feeding the conversation/persona path, so both are written on a rename.
///
/// The profile store is optional so the DEBUG fixtures (and the capture app,
/// which excludes the production wiring) can render a chosen appearance
/// without touching Application Support. A nil store means "local only".
@MainActor
final class BotProfileCenter: ObservableObject {
    @Published private(set) var profile: BotProfile? = nil
    @Published private(set) var appearance: BotFishAppearance = .classic
    @Published private(set) var displayName: String
    @Published var errorMessage: String? = nil

    let botID: String
    private let store: BotProfileStore?
    private let legacyName: String?
    private(set) var bootstrapped = false

    init(botID: String = "main", store: BotProfileStore? = nil,
         legacyName: String? = nil, fallbackName: String = "大肥鱼",
         appearance initialAppearance: BotFishAppearance = .classic) {
        self.botID = botID
        self.store = store
        self.legacyName = legacyName
        self.displayName = fallbackName
        self.appearance = initialAppearance
    }

    /// Creates the one "main" record on first launch: name from the last
    /// `renamed` event (else 大肥鱼), explicit blue/long so the existing fish
    /// keeps its look. An existing index is returned unchanged.
    func bootstrap() async {
        guard let store, !bootstrapped else { return }
        do {
            let created = try await store.bootstrapMainIfNeeded(legacyName: legacyName)
            apply(created)
            bootstrapped = true
        } catch {
            errorMessage = "Bot 资料读取失败：\(error.localizedDescription)"
        }
    }

    /// Applies an appearance choice immediately, then persists only the fields
    /// that actually changed. UI selection is never rolled back on a write
    /// failure; the error is surfaced instead.
    func select(color: BotFishColor) async {
        guard appearance.color != color || appearance.autoColor else { return }
        var next = appearance
        next.color = color
        next.autoColor = false
        appearance = next
        await persist { patch in
            patch.fishColor = .some(.some(color))
        }
    }

    func select(hairstyle: BotFishHairstyle) async {
        guard appearance.hairstyle != hairstyle || appearance.autoHairstyle else { return }
        var next = appearance
        next.hairstyle = hairstyle
        next.autoHairstyle = false
        appearance = next
        await persist { patch in
            patch.fishHairstyle = .some(.some(hairstyle))
        }
    }

    /// Mirrors a successful `renamed` system event into the profile record.
    /// Throws so the caller can distinguish "event written, profile not".
    func rename(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let store else {
            displayName = trimmed
            return
        }
        do {
            let updated = try await store.upsert(id: botID, patch: BotProfilePatch(name: trimmed))
            apply(updated)
        } catch {
            displayName = trimmed
            throw error
        }
    }

    private func persist(_ mutate: (inout BotProfilePatch) -> Void) async {
        guard let store else { return }
        var patch = BotProfilePatch()
        mutate(&patch)
        do {
            let updated = try await store.upsert(id: botID, patch: patch)
            apply(updated)
        } catch {
            errorMessage = "外观保存失败：\(error.localizedDescription)"
        }
    }

    private func apply(_ next: BotProfile) {
        let nameChanged = profile?.name != next.name || displayName != next.name
        profile = next
        appearance = BotFishAppearance.resolve(next)
        if nameChanged { displayName = next.name }
    }
}

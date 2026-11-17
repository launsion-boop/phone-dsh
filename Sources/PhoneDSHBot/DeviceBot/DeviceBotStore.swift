// SPDX-License-Identifier: MIT
//
// device-bot-v1 §2: the two persisted maps (P18) and the creation flow that drives §6.

import Foundation

/// `deviceBots.v1` (key to Bot id) and `deviceBots.intents.v1` (key to creation id). Written
/// whole and synchronized before the call returns. Entries this reader does not understand
/// (non-string values) are kept and written back unchanged, so an older or newer build never
/// drops the other's entries.
public struct DeviceBotMapStore: @unchecked Sendable {
    public static let bindingsKey = "deviceBots.v1"
    public static let intentsKey = "deviceBots.intents.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var bindings: [String: String] { strings(Self.bindingsKey) }
    public var intents: [String: String] { strings(Self.intentsKey) }

    /// Replaces the string entries of both maps; foreign (non-string) entries stay as they are.
    public func write(bindings: [String: String], intents: [String: String]) {
        put(Self.bindingsKey, bindings)
        put(Self.intentsKey, intents)
        defaults.synchronize()   // a killed App must not forget a binding or an intent
    }

    private func raw(_ name: String) -> [String: Any] { defaults.dictionary(forKey: name) ?? [:] }

    private func strings(_ name: String) -> [String: String] {
        raw(name).compactMapValues { $0 as? String }
    }

    private func put(_ name: String, _ strings: [String: String]) {
        var merged: [String: Any] = raw(name).filter { !($0.value is String) }
        for (key, value) in strings { merged[key] = value }
        defaults.set(merged, forKey: name)
    }
}

/// What the creation flow needs from the Bot host. The App implements it over the profile store
/// and the durable event log; tests implement it in memory.
public protocol DeviceBotHost: Sendable {
    /// The Bot roster: id and name.
    func roster() async throws -> [(id: String, name: String)]
    /// creation id to Bot id from the durable `ui.system_event{event:"teammate.created"}` rows.
    func createdBots() async throws -> [String: String]
    /// Creates the Bot through the audited path with author kind `device`, the key and the
    /// creation id, and returns the new Bot id.
    func createDeviceBot(name: String, description: String, key: String, creationID: String) async throws -> String
}

public struct DeviceBotRequest: Sendable, Equatable {
    public var key: String
    /// A raw name (sanitized and made unique by the flow) and the template description.
    public var rawName: String
    public var description: String
    /// A legacy key whose live binding moves to `key` (the board's `tonolink:` key).
    public var alias: String?

    public init(key: String, rawName: String, description: String, alias: String? = nil) {
        self.key = key
        self.rawName = rawName
        self.description = description
        self.alias = alias
    }
}

public enum DeviceBotOutcome: Equatable, Sendable {
    case existing(bot: String)
    case bound(bot: String)
    case created(bot: String)
    case failed(String)
    /// Another call for the same key is already in flight.
    case busy
}

public actor DeviceBotBinder {
    private let store: DeviceBotMapStore
    private let host: DeviceBotHost
    private let makeCreationID: @Sendable () -> String
    private var inFlight: Set<String> = []

    public init(store: DeviceBotMapStore, host: DeviceBotHost,
                makeCreationID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.store = store
        self.host = host
        self.makeCreationID = makeCreationID
    }

    public func ensure(_ request: DeviceBotRequest) async -> DeviceBotOutcome {
        let key = request.key
        guard inFlight.insert(key).inserted else { return .busy }
        defer { inFlight.remove(key) }
        let roster: [(id: String, name: String)]
        do { roster = try await host.roster() } catch { return .failed("roster unavailable: \(error)") }
        // Fast path: a live binding needs nothing else (the common poll must not read the log).
        let live = Set(roster.map(\.id))
        if let bound = store.bindings[key], live.contains(bound) { return .existing(bot: bound) }
        // The creation rows are read only when an earlier attempt left an intent for this key.
        var created: [String: String] = [:]
        if store.intents[key] != nil {
            do { created = try await host.createdBots() } catch { return .failed("created events unavailable: \(error)") }
        }
        var state = DeviceBotState(bindings: store.bindings, intents: store.intents,
                                   roster: Set(roster.map(\.id)), created: created)
        let decision = DeviceBotBinding.decide(state, key: key, newCreationID: makeCreationID(),
                                               alias: request.alias)
        state = decision.state
        // The intent (or the new binding) is durable before anything is created.
        if state.bindings != store.bindings || state.intents != store.intents {
            store.write(bindings: state.bindings, intents: state.intents)
        }
        switch decision.action {
        case .none:
            return .existing(bot: state.bindings[key] ?? "")
        case .bind(let bot):
            return .bound(bot: bot)
        case .create(let creationID):
            let name = DeviceBotText.name(request.rawName, rosterNames: roster.map(\.name))
            do {
                let bot = try await host.createDeviceBot(
                    name: name, description: request.description, key: key, creationID: creationID)
                // Re-read: another key may have been written while the Bot was being created.
                let after = DeviceBotBinding.complete(
                    DeviceBotState(bindings: store.bindings, intents: store.intents), key: key, bot: bot)
                store.write(bindings: after.bindings, intents: after.intents)
                return .created(bot: bot)
            } catch {
                // The intent stays; the next trigger retries with the same creation id.
                return .failed("create failed: \(error)")
            }
        }
    }
}

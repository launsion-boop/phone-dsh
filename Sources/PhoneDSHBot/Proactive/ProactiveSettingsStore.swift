// SPDX-License-Identifier: MIT

import Foundation

/// Durable "can this Bot disturb me" authorization. The plan puts what is
/// worth saying in memory; DND and quiet hours are the user's host-level
/// authorization and live here so every Bot and every scheduler reads one
/// value.
///
/// The UserDefaults key and JSON shape are registered by P18 in
/// `spec/README.md`; the first production default turns delivery on because
/// §3.8 requires interrupt routines to actually notify.
public final class ProactiveSettingsStore: @unchecked Sendable {
    public static let defaultsKey = "phone-dsh.bot.proactive-settings.v1"
    public static let shared = ProactiveSettingsStore()

    public static var productionDefault: ProactiveSettings {
        ProactiveSettings(mode: .on, dnd: false, quietStart: "23:00", quietEnd: "08:00")
    }

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = ProactiveSettingsStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func settings() -> ProactiveSettings {
        let data: Data? = lock.withLock { defaults.data(forKey: key) }
        guard let data,
              let decoded = try? JSONDecoder().decode(ProactiveSettings.self, from: data) else {
            return Self.productionDefault.normalized()
        }
        return decoded.normalized()
    }

    public func save(_ settings: ProactiveSettings) {
        let normalized = settings.normalized()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        lock.withLock { defaults.set(data, forKey: key) }
    }

    @discardableResult
    public func update(dnd: Bool? = nil, quietStart: String? = nil,
                       quietEnd: String? = nil) -> ProactiveSettings {
        var next = settings()
        if let dnd { next.dnd = dnd }
        if let quietStart { next.quietStart = quietStart }
        if let quietEnd { next.quietEnd = quietEnd }
        next = next.normalized()
        save(next)
        return next
    }
}

// SPDX-License-Identifier: MIT

import Foundation

@MainActor
public final class PhonePermissionStore: ObservableObject {
    public static let keyPrefix = "phone-dsh.permissions."
    public static let shared = PhonePermissionStore()

    @Published private var values: [PhoneCapability: Bool]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [PhoneCapability: Bool] = [:]
        for capability in PhoneCapability.allCases {
            let key = Self.key(for: capability)
            loaded[capability] = defaults.object(forKey: key) as? Bool ?? capability.defaultEnabled
        }
        values = loaded
    }

    public func isEnabled(_ capability: PhoneCapability) -> Bool {
        capability.isReadOnlyAlwaysOn || values[capability] == true
    }

    public func setEnabled(_ enabled: Bool, for capability: PhoneCapability) {
        guard !capability.isReadOnlyAlwaysOn else {
            values[capability] = true
            return
        }
        values[capability] = enabled
        defaults.set(enabled, forKey: Self.key(for: capability))
    }

    public static func key(for capability: PhoneCapability) -> String {
        keyPrefix + capability.rawValue
    }
}

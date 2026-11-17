// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// User-confirmed Bot geofences survive app restarts. This is product
/// configuration, not an OS permission: the OS still holds the actual
/// `CLCircularRegion` and may deliver callbacks only on a real device.
enum BotContextSourcesGeofenceStore {
    static let defaultsKey = "phone-dsh.bot.geofences.v1"

    static func load(from defaults: UserDefaults = .standard) -> [BotContextGeofenceSpec] {
        guard let data = defaults.data(forKey: defaultsKey),
              let fences = try? JSONDecoder().decode([BotContextGeofenceSpec].self, from: data) else {
            return []
        }
        return fences
    }

    static func save(_ fences: [BotContextGeofenceSpec],
                     to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(fences) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

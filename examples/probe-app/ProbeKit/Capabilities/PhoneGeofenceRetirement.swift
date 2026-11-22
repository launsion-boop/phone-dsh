// SPDX-License-Identifier: MIT

import CoreLocation
import Foundation

/// Removes circular regions registered by app versions that exposed `location.geofence`.
@MainActor
public enum PhoneGeofenceRetirement {
    private static let completedKey = "phone-dsh.location-geofence-retired.v1"

    public static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedKey) else { return }

        let manager = CLLocationManager()
        for region in manager.monitoredRegions where region is CLCircularRegion {
            manager.stopMonitoring(for: region)
        }
        defaults.set(true, forKey: completedKey)
    }
}

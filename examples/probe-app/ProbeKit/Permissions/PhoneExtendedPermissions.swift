// SPDX-License-Identifier: MIT

import ActivityKit
import Intents
import MusicKit
import UIKit

@MainActor
public final class PhoneExtendedPermissionController {
    public init() {}

    public func status(for capability: PhoneCapability) -> CapabilityStatus {
        switch capability {
        case .focus:
            switch INFocusStatusCenter.default.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            case .denied: return .denied
            case .authorized: return .authorized
            @unknown default: return .unavailable
            }
        case .music:
            switch MusicAuthorization.currentStatus {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .restricted
            case .authorized: return .authorized
            @unknown default: return .unavailable
            }
        case .liveActivity:
            return ActivityAuthorizationInfo().areActivitiesEnabled ? .authorized : .unavailable
        case .shortcuts:
            guard let url = URL(string: "shortcuts://") else { return .unavailable }
            return UIApplication.shared.canOpenURL(url) ? .authorized : .unavailable
        default:
            return .unavailable
        }
    }

    public func request(for capability: PhoneCapability) async -> CapabilityStatus {
        switch capability {
        case .focus:
            await withCheckedContinuation { continuation in
                INFocusStatusCenter.default.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        case .music:
            _ = await MusicAuthorization.request()
        default:
            break
        }
        return status(for: capability)
    }

    public func focusStatus() -> Bool? {
        INFocusStatusCenter.default.focusStatus.isFocused
    }
}

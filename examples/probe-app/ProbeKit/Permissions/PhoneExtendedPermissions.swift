// SPDX-License-Identifier: MIT

import ActivityKit
import CoreLocation
import HomeKit
import Intents
import MusicKit
import UIKit

@MainActor
public final class PhoneExtendedPermissionController {
    private var homeManager: HMHomeManager?
    private var homeDelegate: PhoneHomeAuthorizationDelegate?
    private var homeContinuation: CheckedContinuation<Void, Never>?
    private var alwaysManager: CLLocationManager?
    private var alwaysDelegate: PhoneAlwaysLocationDelegate?

    public init() {}

    public func status(for capability: PhoneCapability) -> CapabilityStatus {
        switch capability {
        case .locationAlways:
            switch CLLocationManager.authorizationStatus() {
            case .authorizedAlways: return .authorized
            case .authorizedWhenInUse, .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .restricted
            @unknown default: return .unavailable
            }
        case .focus:
            switch INFocusStatusCenter.default.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            case .denied: return .denied
            case .authorized: return .authorized
            @unknown default: return .unavailable
            }
        case .homekit:
            guard let homeManager else { return .notDetermined }
            let status = homeManager.authorizationStatus
            if status.contains(.authorized) { return .authorized }
            if status.contains(.restricted) { return .restricted }
            return .notDetermined
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
        case .locationAlways:
            let manager = alwaysManager ?? CLLocationManager()
            alwaysManager = manager
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let delegate = PhoneAlwaysLocationDelegate { [weak self] in
                    self?.alwaysDelegate = nil
                    self?.alwaysManager = nil
                    continuation.resume()
                }
                alwaysDelegate = delegate
                manager.delegate = delegate
                manager.requestAlwaysAuthorization()
            }
        case .focus:
            await withCheckedContinuation { continuation in
                INFocusStatusCenter.default.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        case .homekit:
            if homeManager == nil {
                let manager = HMHomeManager()
                homeManager = manager
                let delegate = PhoneHomeAuthorizationDelegate { [weak self] in
                    self?.finishHomeRequest()
                }
                homeDelegate = delegate
                manager.delegate = delegate
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    homeContinuation = continuation
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(15))
                        self?.finishHomeRequest()
                    }
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

    public func homes() throws -> [HMHome] {
        guard let homeManager else { throw PhoneToolError.permissionRequired(.homekit) }
        return homeManager.homes
    }

    private func finishHomeRequest() {
        guard let continuation = homeContinuation else { return }
        homeContinuation = nil
        continuation.resume()
    }
}

private final class PhoneHomeAuthorizationDelegate: NSObject, HMHomeManagerDelegate {
    private let updated: () -> Void

    init(updated: @escaping () -> Void) {
        self.updated = updated
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        updated()
    }

    func homeManager(_ manager: HMHomeManager,
                     didUpdate status: HMHomeManagerAuthorizationStatus) {
        updated()
    }
}

private final class PhoneAlwaysLocationDelegate: NSObject, CLLocationManagerDelegate {
    private let updated: () -> Void

    init(updated: @escaping () -> Void) {
        self.updated = updated
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updated()
    }
}

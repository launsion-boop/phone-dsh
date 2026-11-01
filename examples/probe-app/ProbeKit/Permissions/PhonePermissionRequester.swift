// SPDX-License-Identifier: MIT

import AVFoundation
import Contacts
import CoreBluetooth
import CoreLocation
import CoreMotion
import EventKit
import HealthKit
import LocalAuthentication
import Network
import Photos
import PhotosUI
import Speech
import UIKit
import UserNotifications

public struct PhoneLocalNetworkResult: Sendable {
    public let services: [String]
    public let status: CapabilityStatus
    public let detail: String

    public init(services: [String], status: CapabilityStatus, detail: String) {
        self.services = services
        self.status = status
        self.detail = detail
    }
}

@MainActor
public final class PhonePermissionRequester: ObservableObject {
    public static let shared = PhonePermissionRequester()
    public let extended = PhoneExtendedPermissionController()

    @Published public private(set) var statuses: [PhoneCapability: CapabilityStatus]
    @Published public private(set) var requesting: PhoneCapability?

    private lazy var locationManager = CLLocationManager()
    private var locationDelegate: PhoneLocationAuthorizationDelegate?
    private var bluetoothManager: CBCentralManager?
    private var bluetoothDelegate: PhoneBluetoothAuthorizationDelegate?
    private var localNetworkStatus: CapabilityStatus = .notDetermined

    public init() {
        var initial: [PhoneCapability: CapabilityStatus] = [:]
        for capability in PhoneCapability.allCases {
            initial[capability] = capability == .device || capability == .clipboard
                ? .authorized : .notDetermined
        }
        statuses = initial
    }

    public func refresh() async {
        for capability in PhoneCapability.allCases {
            statuses[capability] = await status(for: capability)
        }
    }

    public func status(for capability: PhoneCapability) async -> CapabilityStatus {
        switch capability {
        case .contacts:
            let authorization = CNContactStore.authorizationStatus(for: .contacts)
            if #available(iOS 18.0, *), authorization == .limited {
                return .limited(Self.contactCount())
            }
            return Self.status(authorization)
        case .calendar:
            return Self.status(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return Self.status(EKEventStore.authorizationStatus(for: .reminder))
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
            do {
                let state = try await HKHealthStore().statusForAuthorizationRequest(
                    toShare: [], read: Self.healthReadTypes)
                switch state {
                case .shouldRequest: return .notDetermined
                case .unnecessary: return .requested
                default: return .notDetermined
                }
            } catch {
                return .unavailable
            }
        case .photos:
            let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if authorization == .limited {
                return .limited(PHAsset.fetchAssets(with: nil).count)
            }
            return Self.status(authorization)
        case .camera:
            return Self.status(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return Self.status(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speech:
            return Self.status(SFSpeechRecognizer.authorizationStatus())
        case .location:
            return locationStatus(capability)
        case .motion:
            return Self.status(CMMotionActivityManager.authorizationStatus())
        case .bluetooth:
            return Self.status(CBManager.authorization)
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized: return .authorized
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            case .provisional, .ephemeral: return .limited(0)
            @unknown default: return .unavailable
            }
        case .biometrics:
            let context = LAContext()
            var error: NSError?
            return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
                ? .authorized : .unavailable
        case .localNetwork:
            return localNetworkStatus
        case .clipboard:
            return .authorized
        case .filesFolder:
            return PhoneFolderGrantStore.shared.hasGrants ? .authorized : .notDetermined
        case .device:
            return .authorized
        case .locationAlways, .focus, .homekit, .music, .liveActivity, .shortcuts:
            return extended.status(for: capability)
        }
    }

    public func request(_ capability: PhoneCapability) async -> CapabilityStatus {
        guard requesting == nil else { return statuses[capability] ?? .unavailable }
        let current = await status(for: capability)
        statuses[capability] = current
        guard current == .notDetermined else { return current }
        requesting = capability
        defer { requesting = nil }

        switch capability {
        case .contacts:
            let store = CNContactStore()
            _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestAccess(for: .contacts) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
        case .calendar:
            let store = EKEventStore()
            _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestFullAccessToEvents { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
        case .reminders:
            let store = EKEventStore()
            _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestFullAccessToReminders { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
        case .health:
            _ = try? await HKHealthStore().requestAuthorization(toShare: [], read: Self.healthReadTypes)
        case .photos:
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorization in
                    continuation.resume(returning: authorization)
                }
            }
        case .location:
            await requestLocation()
        case .motion:
            let manager = CMMotionActivityManager()
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                manager.queryActivityStarting(from: Date(timeIntervalSinceNow: -1), to: Date(), to: .main) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        case .bluetooth:
            await requestBluetooth()
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        case .localNetwork:
            let result = await PhoneLocalNetworkProbe().run()
            localNetworkStatus = result.status
        case .filesFolder:
            _ = try? await PhoneFolderGrantStore.shared.grantFolder()
        case .locationAlways, .focus, .homekit, .music:
            _ = await extended.request(for: capability)
        case .biometrics, .clipboard, .device, .liveActivity, .shortcuts:
            break
        }
        let updated = await status(for: capability)
        statuses[capability] = updated
        return updated
    }

    public func testLocalNetwork() async -> PhoneLocalNetworkResult {
        let result = await PhoneLocalNetworkProbe().run()
        localNetworkStatus = result.status
        statuses[.localNetwork] = result.status
        return result
    }

    public func confirmBiometricWrite(tool: String) async -> Bool {
        guard await status(for: .biometrics) == .authorized else { return false }
        return (try? await LAContext().evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "确认允许 \(tool) 执行敏感写操作")) == true
    }

    public func presentLimitedPhotosPicker() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited,
              let controller = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    private func requestLocation() async {
        let manager = locationManager
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let delegate = PhoneLocationAuthorizationDelegate {
                Task { @MainActor in
                    self.locationManager.delegate = nil
                    self.locationDelegate = nil
                    continuation.resume()
                }
            }
            locationDelegate = delegate
            manager.delegate = delegate
            manager.requestWhenInUseAuthorization()
        }
    }

    private func requestBluetooth() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let delegate = PhoneBluetoothAuthorizationDelegate {
                Task { @MainActor in
                    self.bluetoothManager?.delegate = nil
                    self.bluetoothManager = nil
                    self.bluetoothDelegate = nil
                    continuation.resume()
                }
            }
            bluetoothDelegate = delegate
            bluetoothManager = CBCentralManager(delegate: delegate, queue: .main)
        }
    }

    private func locationStatus(_ capability: PhoneCapability) -> CapabilityStatus {
        let manager = locationManager
        let authorization: CLAuthorizationStatus
        if #available(iOS 14.0, *) { authorization = manager.authorizationStatus }
        else { authorization = CLLocationManager.authorizationStatus() }
        switch authorization {
        case .authorizedAlways: return .authorized
        case .authorizedWhenInUse: return capability == .location ? .authorized : .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    private static var healthReadTypes: Set<HKObjectType> {
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .bodyMass,
        ]
        let types = quantities.compactMap { HKObjectType.quantityType(forIdentifier: $0) as HKObjectType? }
        let categories: [HKCategoryTypeIdentifier] = [.sleepAnalysis, .mindfulSession]
        let categoryTypes = categories.compactMap { HKObjectType.categoryType(forIdentifier: $0) as HKObjectType? }
        return Set(types + categoryTypes + [HKObjectType.workoutType()])
    }

    private static func contactCount() -> Int {
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        var count = 0
        try? CNContactStore().enumerateContacts(with: request) { _, _ in count += 1 }
        return count
    }

    private static func status(_ status: CNAuthorizationStatus) -> CapabilityStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        default:
            if #available(iOS 18.0, *), status == .limited { return .limited(0) }
            return .unavailable
        }
    }

    private static func status(_ status: EKAuthorizationStatus) -> CapabilityStatus {
        switch status {
        case .fullAccess: return .authorized
        case .writeOnly: return .limited(0)
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    private static func status(_ status: PHAuthorizationStatus) -> CapabilityStatus {
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited(0)
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    private static func status(_ status: AVAuthorizationStatus) -> CapabilityStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    private static func status(_ status: SFSpeechRecognizerAuthorizationStatus) -> CapabilityStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    private static func status(_ status: CMAuthorizationStatus) -> CapabilityStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    private static func status(_ status: CBManagerAuthorization) -> CapabilityStatus {
        switch status {
        case .allowedAlways: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        func descend(_ base: UIViewController?) -> UIViewController? {
            guard let base else { return nil }
            if let navigation = base as? UINavigationController { return descend(navigation.visibleViewController) }
            if let tab = base as? UITabBarController { return descend(tab.selectedViewController) }
            if let presented = base.presentedViewController { return descend(presented) }
            return base
        }
        return descend(window?.rootViewController)
    }
}

private final class PhoneLocationAuthorizationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let changed: @Sendable () -> Void

    init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if #available(iOS 14.0, *) {
            guard manager.authorizationStatus != .notDetermined else { return }
        } else {
            guard CLLocationManager.authorizationStatus() != .notDetermined else { return }
        }
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        changed()
    }
}

private final class PhoneBluetoothAuthorizationDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let changed: @Sendable () -> Void

    init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown else { return }
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        changed()
    }
}

@MainActor
private final class PhoneLocalNetworkProbe {
    private var continuation: CheckedContinuation<PhoneLocalNetworkResult, Never>?
    private var browser: NWBrowser?
    private var services = Set<String>()
    private var finished = false

    func run() async -> PhoneLocalNetworkResult {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_pdsh._tcp", domain: nil), using: parameters)
        self.browser = browser
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .failed(let error):
                        let denied = String(describing: error).localizedCaseInsensitiveContains("denied")
                        self.finish(status: denied ? .denied : .unavailable, detail: String(describing: error))
                    case .cancelled:
                        self.finish(status: .unavailable, detail: "系统浏览器已取消")
                    default:
                        break
                    }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for result in results {
                        if case let .service(name, _, _, _) = result.endpoint { self.services.insert(name) }
                    }
                }
            }
            browser.start(queue: .main)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.finish(status: .authorized, detail: "NWBrowser 实测完成")
            }
        }
    }

    private func finish(status: CapabilityStatus, detail: String) {
        guard !finished, let continuation else { return }
        finished = true
        browser?.cancel()
        browser = nil
        self.continuation = nil
        continuation.resume(returning: PhoneLocalNetworkResult(
            services: services.sorted(), status: status, detail: detail))
    }
}

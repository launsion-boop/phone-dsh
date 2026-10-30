// SPDX-License-Identifier: MIT

import CoreBluetooth
import CoreLocation
import CoreMotion
import Foundation
import UIKit
import UserNotifications

@MainActor
public struct PhoneDeviceTools {
    private let requester: PhonePermissionRequester
    private let folders: PhoneFolderGrantStore
    private let locations: PhoneLocationService
    private let bluetooth: PhoneBluetoothScanner

    public init(requester: PhonePermissionRequester = .shared,
                folders: PhoneFolderGrantStore = .shared) {
        self.requester = requester
        self.folders = folders
        self.locations = PhoneLocationService()
        self.bluetooth = PhoneBluetoothScanner()
    }

    public func currentLocation(object: [String: Any]) async throws -> PhoneToolPayload {
        let accuracy = try PhoneToolEnvelope.text(object, "accuracy", required: false, limit: 12) ?? "city"
        guard accuracy == "city" || accuracy == "precise" else {
            throw PhoneToolError.invalidArguments("accuracy 仅支持 city 或 precise")
        }
        let location = try await locations.current(precise: accuracy == "precise")
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location)
        let place = placemark?.first
        let placeName = [place?.locality, place?.administrativeArea, place?.country]
            .compactMap { $0 }.joined(separator: ", ")
        return PhoneToolPayload(data: [
            "lat": location.coordinate.latitude,
            "lng": location.coordinate.longitude,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "placemark": placeName.isEmpty ? NSNull() : placeName,
            "accuracyM": location.horizontalAccuracy,
            "altitude": location.altitude,
            "at": PhoneToolEnvelope.iso8601(location.timestamp),
        ])
    }

    public func notify(object: [String: Any]) async throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        let title = try PhoneToolEnvelope.text(object, "title", limit: 200) ?? ""
        let body = try PhoneToolEnvelope.text(object, "body", limit: 4000) ?? ""
        let delay: Int
        let at: Date?
        if object["at"] != nil {
            let date = try PhoneToolEnvelope.date(object, "at")
            let seconds = date.timeIntervalSinceNow
            guard seconds >= 1, seconds <= 86400 else {
                throw PhoneToolError.invalidArguments("at 必须在未来 1 秒至 24 小时内")
            }
            delay = Int(ceil(seconds))
            at = date
        } else {
            delay = try PhoneToolEnvelope.integer(object, "delay", default: 1,
                                                  minimum: 1, maximum: 86400)
            at = nil
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let link = try PhoneToolEnvelope.text(object, "deepLink", required: false, limit: 512) {
            content.userInfo["deepLink"] = link
        }
        let identifier = "phone-dsh-\(UUID().uuidString.lowercased())"
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(delay), repeats: false))
        try await UNUserNotificationCenter.current().add(request)
        return PhoneToolPayload(data: [
            "status": "scheduled", "id": identifier, "delay": delay,
            "at": at.map(PhoneToolEnvelope.iso8601) ?? NSNull(),
        ])
    }

    public func readClipboard() throws -> PhoneToolPayload {
        guard let text = UIPasteboard.general.string else {
            throw PhoneToolError.noData("剪贴板没有文本")
        }
        guard text.utf8.count <= 8192 else { throw PhoneToolError.invalidArguments("剪贴板文本超过 8 KB") }
        return PhoneToolPayload(data: ["text": text, "hasString": true])
    }

    public func writeClipboard(object: [String: Any]) throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        let text = try PhoneToolEnvelope.text(object, "text", limit: 8192) ?? ""
        guard text.utf8.count <= 8192 else { throw PhoneToolError.invalidArguments("text 超过 8 KB") }
        UIPasteboard.general.string = text
        return PhoneToolPayload(data: ["status": "written", "characters": text.count])
    }

    public func grantFolder(object: [String: Any]) async throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        let root = try await folders.grantFolder()
        return PhoneToolPayload(data: [
            "root": folders.metadata(for: root), "status": "granted", "persistent": true,
        ])
    }

    public func listRoots() -> PhoneToolPayload {
        let roots = folders.roots.map(folders.metadata)
        var data: [String: Any] = ["roots": roots, "items": roots, "count": roots.count]
        if let error = folders.restoreError { data["error"] = error }
        return PhoneToolPayload(data: data)
    }

    public func deviceStatus() async -> PhoneToolPayload {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let process = ProcessInfo.processInfo
        let batteryState = switch device.batteryState {
        case .unknown: "unknown"
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        @unknown default: "unknown"
        }
        let thermal = switch process.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        var freeDisk: Any = NSNull()
        if let values = try? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            freeDisk = capacity
        }
        return PhoneToolPayload(data: [
            "model": device.model,
            "systemName": device.systemName,
            "systemVersion": device.systemVersion,
            "battery": [
                "levelPercent": device.batteryLevel >= 0
                    ? NSNumber(value: Int((device.batteryLevel * 100).rounded())) : NSNull(),
                "state": batteryState,
            ],
            "thermal": thermal,
            "freeDisk": freeDisk,
            "network": await PhoneNetworkStateProbe().current(),
            "lowPower": process.isLowPowerModeEnabled,
            "processorCount": process.processorCount,
            "activeProcessorCount": process.activeProcessorCount,
            "physicalMemory": process.physicalMemory,
            "timeZone": TimeZone.current.identifier,
            "at": PhoneToolEnvelope.iso8601(Date()),
        ])
    }

    public func motionActivity(object: [String: Any]) async throws -> PhoneToolPayload {
        let end = try PhoneToolEnvelope.date(object, "end", default: Date())
        let start = try PhoneToolEnvelope.date(object, "start", default: end.addingTimeInterval(-86400))
        guard end > start, end.timeIntervalSince(start) <= 7 * 86400 else {
            throw PhoneToolError.invalidArguments("运动查询范围必须大于 0 且不超过 7 天")
        }
        let cursor = try PhoneToolEnvelope.integer(object, "cursor", default: 0, minimum: 0, maximum: 100_000)
        let limit = try PhoneToolEnvelope.integer(object, "limit", default: 20, minimum: 1, maximum: 50)
        guard CMMotionActivityManager.isActivityAvailable() else {
            throw PhoneToolError.unavailable(.motion, "当前设备不支持运动活动记录")
        }
        let manager = CMMotionActivityManager()
        let activities = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CMMotionActivity], Error>) in
            manager.queryActivityStarting(from: start, to: end, to: .main) { activities, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: activities ?? []) }
            }
        }.sorted { $0.startDate > $1.startDate }
        guard cursor <= activities.count else { throw PhoneToolError.invalidArguments("cursor 超出结果范围") }
        let page = activities.dropFirst(cursor).prefix(limit)
        let items = page.map { activity -> [String: Any] in
            [
                "start": PhoneToolEnvelope.iso8601(activity.startDate),
                "confidence": activity.confidence.rawValue,
                "stationary": activity.stationary,
                "walking": activity.walking,
                "running": activity.running,
                "cycling": activity.cycling,
                "automotive": activity.automotive,
                "unknown": activity.unknown,
            ]
        }
        let next = cursor + items.count
        return PhoneToolPayload(data: ["items": items, "count": items.count, "total": activities.count],
                                nextCursor: next < activities.count ? next : NSNull(), truncated: next < activities.count)
    }

    public func steps(object: [String: Any]) async throws -> PhoneToolPayload {
        let end = try PhoneToolEnvelope.date(object, "end", default: Date())
        let start = try PhoneToolEnvelope.date(object, "start", default: end.addingTimeInterval(-86400))
        guard end > start, end.timeIntervalSince(start) <= 7 * 86400 else {
            throw PhoneToolError.invalidArguments("步数查询范围必须大于 0 且不超过 7 天")
        }
        guard CMPedometer.isStepCountingAvailable() else {
            throw PhoneToolError.unavailable(.motion, "当前设备不支持计步")
        }
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CMPedometerData, Error>) in
            CMPedometer().queryPedometerData(from: start, to: end) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: PhoneToolError.unavailable(.motion, "没有计步数据")) }
            }
        }
        return PhoneToolPayload(data: [
            "start": PhoneToolEnvelope.iso8601(start),
            "end": PhoneToolEnvelope.iso8601(end),
            "steps": data.numberOfSteps,
            "distanceMeters": data.distance ?? NSNull(),
            "floorsAscended": data.floorsAscended ?? NSNull(),
            "floorsDescended": data.floorsDescended ?? NSNull(),
        ])
    }

    public func bluetoothScan(object: [String: Any]) async throws -> PhoneToolPayload {
        let duration = try PhoneToolEnvelope.integer(object, "duration", default: 5,
                                                     minimum: 1, maximum: 15)
        let items = try await bluetooth.scan(duration: duration)
        return PhoneToolPayload(data: ["items": items, "count": items.count, "duration": duration])
    }

    public func browseNetwork() async -> PhoneToolPayload {
        let result = await requester.testLocalNetwork()
        return PhoneToolPayload(data: [
            "items": result.services.map { ["name": $0] },
            "count": result.services.count,
            "status": result.status.rawValueForTool,
            "detail": result.detail,
        ])
    }

}

private extension CapabilityStatus {
    var rawValueForTool: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .authorized: return "authorized"
        case .limited(let count): return "limited(\(count))"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .requested: return "requested"
        case .unavailable: return "unavailable"
        }
    }
}

@MainActor
private final class PhoneLocationService {
    private var manager: CLLocationManager?
    private var delegate: PhoneCurrentLocationDelegate?
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func current(precise: Bool) async throws -> CLLocation {
        guard continuation == nil else {
            throw PhoneToolError.unavailable(.location, "已有定位操作在进行")
        }
        let manager = CLLocationManager()
        manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyKilometer
        self.manager = manager
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let delegate = PhoneCurrentLocationDelegate(
                located: { [weak self] locations in
                    if let location = locations.last { self?.finish(.success(location)) }
                },
                failed: { [weak self] error in self?.finish(.failure(error)) })
            self.delegate = delegate
            manager.delegate = delegate
            manager.requestLocation()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.finish(.failure(PhoneToolError.unavailable(.location, "定位超时")))
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        manager?.delegate = nil
        manager = nil
        delegate = nil
        continuation.resume(with: result)
    }
}

private final class PhoneCurrentLocationDelegate: NSObject, CLLocationManagerDelegate {
    private let located: ([CLLocation]) -> Void
    private let failed: (Error) -> Void

    init(located: @escaping ([CLLocation]) -> Void, failed: @escaping (Error) -> Void) {
        self.located = located
        self.failed = failed
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        located(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        failed(error)
    }
}

@MainActor
private final class PhoneBluetoothScanner {
    private struct Peripheral {
        let id: String
        let name: String
        let rssi: Int
    }

    private var manager: CBCentralManager?
    private var delegate: PhoneBluetoothScanDelegate?
    private var continuation: CheckedContinuation<[[String: Any]], Error>?
    private var peripherals: [String: Peripheral] = [:]

    func scan(duration: Int) async throws -> [[String: Any]] {
        guard continuation == nil else {
            throw PhoneToolError.unavailable(.bluetooth, "已有蓝牙扫描在进行")
        }
        peripherals.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let delegate = PhoneBluetoothScanDelegate(
                state: { [weak self] state in
                    guard let self else { return }
                    if state == .poweredOn {
                        self.manager?.scanForPeripherals(withServices: nil, options: [
                            CBCentralManagerScanOptionAllowDuplicatesKey: false,
                        ])
                    } else if state != .unknown {
                        self.finish(.failure(PhoneToolError.unavailable(.bluetooth, "蓝牙未开启或当前不可用")))
                    }
                },
                discovered: { [weak self] peripheral, rssi in
                    self?.peripherals[peripheral.identifier.uuidString] = Peripheral(
                        id: peripheral.identifier.uuidString, name: peripheral.name ?? "", rssi: rssi.intValue)
                })
            self.delegate = delegate
            manager = CBCentralManager(delegate: delegate, queue: .main)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
                self?.finish(.success(()))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        manager?.stopScan()
        manager?.delegate = nil
        manager = nil
        delegate = nil
        self.continuation = nil
        let items = peripherals.values.sorted { $0.id < $1.id }.map {
            ["id": $0.id, "name": $0.name, "rssi": $0.rssi]
        }
        switch result {
        case .success: continuation.resume(returning: items)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

private final class PhoneBluetoothScanDelegate: NSObject, CBCentralManagerDelegate {
    private let state: (CBManagerState) -> Void
    private let discovered: (CBPeripheral, NSNumber) -> Void

    init(state: @escaping (CBManagerState) -> Void,
         discovered: @escaping (CBPeripheral, NSNumber) -> Void) {
        self.state = state
        self.discovered = discovered
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state(central.state)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discovered(peripheral, RSSI)
    }
}

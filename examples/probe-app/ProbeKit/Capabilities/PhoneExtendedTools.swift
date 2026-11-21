// SPDX-License-Identifier: MIT

import ActivityKit
import CoreLocation
import MusicKit
import UIKit

public struct PhoneLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var detail: String
    }
    public let sessionID: String
}

/// A tool that brings another app to the foreground (Shortcuts) sends this app
/// to the background in the middle of a turn. The App target installs these
/// hooks so it can arm its background keep-alive while it is still in the
/// foreground; arming it only after `didEnterBackground` can be refused by the
/// system, and the fallback park cannot settle a turn whose Worker iOS has
/// already frozen (field report: "Park failed … did not quiesce").
@MainActor
public enum PhoneExternalAppHandoff {
    /// Called right before the other app is opened.
    public static var willOpen: (@MainActor () -> Void)?
    /// Called after the open attempt with whether the system opened it.
    public static var didOpen: (@MainActor (Bool) -> Void)?
}

@MainActor
public struct PhoneExtendedTools {
    private let permissions: PhoneExtendedPermissionController
    private let geofenceService = PhoneGeofenceService()

    public init(permissions: PhoneExtendedPermissionController) {
        self.permissions = permissions
    }

    public func geofence(object: [String: Any]) throws -> PhoneToolPayload {
        try geofenceService.perform(object: object)
    }

    public func focus() -> PhoneToolPayload {
        PhoneToolPayload(data: [
            "isFocused": permissions.focusStatus().map(NSNumber.init(value:)) ?? NSNull(),
            "source": "INFocusStatusCenter",
        ])
    }

    public func musicPlay(object: [String: Any]) async throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        let identifier = try PhoneToolEnvelope.text(object, "id", limit: 128) ?? ""
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(identifier))
        request.limit = 1
        let response = try await request.response()
        guard let song = response.items.first else { throw PhoneToolError.noData("未找到这个音乐目录项目") }
        let player = SystemMusicPlayer.shared
        player.queue = [song]
        try await player.play()
        return PhoneToolPayload(data: [
            "status": "playing", "id": song.id.rawValue,
            "title": song.title, "artist": song.artistName ?? "",
        ])
    }

    public func activityStart(object: [String: Any]) throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        let sessionID = try PhoneToolEnvelope.text(object, "sessionId", limit: 128) ?? "phone-dsh-agent"
        let state = try activityState(object: object)
        let activity = try Activity<PhoneLiveActivityAttributes>.request(
            attributes: PhoneLiveActivityAttributes(sessionID: sessionID),
            content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        return PhoneToolPayload(data: ["status": "started", "id": activity.id])
    }

    public func activityUpdate(object: [String: Any]) async throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        let identifier = try PhoneToolEnvelope.text(object, "id", limit: 200) ?? ""
        guard let activity = Activity<PhoneLiveActivityAttributes>.activities.first(where: { $0.id == identifier }) else {
            throw PhoneToolError.noData("未找到这个实时活动")
        }
        let state = try activityState(object: object)
        await activity.update(ActivityContent(state: state, staleDate: nil))
        return PhoneToolPayload(data: ["status": "updated", "id": identifier])
    }

    public func runShortcut(object: [String: Any]) async throws -> PhoneToolPayload {
        try PhoneToolEnvelope.requireConfirmation(object)
        let name = try PhoneToolEnvelope.text(object, "name", limit: 200) ?? ""
        var components = URLComponents(string: "shortcuts://run-shortcut")
        var query = [URLQueryItem(name: "name", value: name)]
        if let input = try PhoneToolEnvelope.text(object, "input", required: false, limit: 4000) {
            query.append(URLQueryItem(name: "input", value: "text"))
            query.append(URLQueryItem(name: "text", value: input))
        }
        components?.queryItems = query
        guard let url = components?.url, UIApplication.shared.canOpenURL(url) else {
            throw PhoneToolError.unavailable(.shortcuts, "无法打开快捷指令；请确认已安装并可访问该应用")
        }
        PhoneExternalAppHandoff.willOpen?()
        let opened = await UIApplication.shared.open(url)
        PhoneExternalAppHandoff.didOpen?(opened)
        guard opened else {
            throw PhoneToolError.unavailable(.shortcuts, "无法打开快捷指令；请确认已安装并可访问该应用")
        }
        return PhoneToolPayload(data: [
            "status": "opened", "completion": "not_observed", "name": name,
        ])
    }

    private func activityState(object: [String: Any]) throws -> PhoneLiveActivityAttributes.ContentState {
        PhoneLiveActivityAttributes.ContentState(
            title: try PhoneToolEnvelope.text(object, "title", limit: 200) ?? "",
            detail: try PhoneToolEnvelope.text(object, "detail", limit: 4000) ?? "")
    }
}

@MainActor
private final class PhoneGeofenceService {
    private let manager = CLLocationManager()
    private let delegate = PhoneGeofenceDelegate()

    func perform(object: [String: Any]) throws -> PhoneToolPayload {
        let action = try PhoneToolEnvelope.text(object, "action", required: false, limit: 12) ?? "start"
        switch action {
        case "list":
            return PhoneToolPayload(data: [
                "items": manager.monitoredRegions.map(Self.describe),
                "events": delegate.events,
            ])
        case "start":
            try PhoneToolEnvelope.requireConfirmation(object)
            let identifier = try PhoneToolEnvelope.text(object, "id", limit: 128) ?? ""
            guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
                throw PhoneToolError.unavailable(.locationAlways, "当前设备不支持区域监测")
            }
            if let existing = manager.monitoredRegions.first(where: { $0.identifier == identifier }) {
                return PhoneToolPayload(data: ["id": identifier, "status": "already_monitoring",
                                                "region": Self.describe(existing)])
            }
            let latitude = try coordinate(object: object, key: "lat", minimum: -90, maximum: 90)
            let longitude = try coordinate(object: object, key: "lng", minimum: -180, maximum: 180)
            let radius = try coordinate(object: object, key: "radiusM", minimum: 10, maximum: 1000)
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                          radius: radius, identifier: identifier)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.delegate = delegate
            manager.startMonitoring(for: region)
            guard manager.monitoredRegions.contains(where: { $0.identifier == identifier }) else {
                throw PhoneToolError.unavailable(.locationAlways, "系统没有注册这个区域")
            }
            return PhoneToolPayload(data: [
                "id": identifier, "status": "monitoring", "region": Self.describe(region),
                "delivery": "system_events_not_observed_by_this_call",
            ])
        case "stop":
            try PhoneToolEnvelope.requireConfirmation(object)
            let identifier = try PhoneToolEnvelope.text(object, "id", limit: 128) ?? ""
            guard let region = manager.monitoredRegions.first(where: { $0.identifier == identifier }) else {
                throw PhoneToolError.noData("未找到这个地理围栏")
            }
            manager.stopMonitoring(for: region)
            return PhoneToolPayload(data: ["id": identifier, "status": "stopped"])
        default:
            throw PhoneToolError.invalidArguments("action 仅支持 start、stop 或 list")
        }
    }

    private func coordinate(object: [String: Any], key: String,
                            minimum: Double, maximum: Double) throws -> Double {
        guard let value = object[key] as? NSNumber, value.doubleValue.isFinite,
              value.doubleValue >= minimum, value.doubleValue <= maximum else {
            throw PhoneToolError.invalidArguments("\(key) 必须在 \(minimum)...\(maximum) 范围内")
        }
        return value.doubleValue
    }

    private static func describe(_ region: CLRegion) -> [String: Any] {
        guard let region = region as? CLCircularRegion else {
            return ["id": region.identifier]
        }
        return [
            "id": region.identifier,
            "lat": region.center.latitude,
            "lng": region.center.longitude,
            "radiusM": region.radius,
        ]
    }
}

private final class PhoneGeofenceDelegate: NSObject, CLLocationManagerDelegate {
    private(set) var events: [[String: Any]] = []

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        record(region: region, state: "entered")
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        record(region: region, state: "exited")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        events.append(["state": "failed", "message": error.localizedDescription])
    }

    private func record(region: CLRegion, state: String) {
        events.append(["id": region.identifier, "state": state,
                       "at": PhoneToolEnvelope.iso8601(Date())])
        if events.count > 50 { events.removeFirst(events.count - 50) }
    }
}

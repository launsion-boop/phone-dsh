// SPDX-License-Identifier: MIT

import ActivityKit
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

    public init(permissions: PhoneExtendedPermissionController) {
        self.permissions = permissions
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

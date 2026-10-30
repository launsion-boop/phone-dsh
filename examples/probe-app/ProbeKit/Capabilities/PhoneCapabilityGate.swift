// SPDX-License-Identifier: MIT

import Foundation

public struct PhoneToolRoute: Sendable {
    public let capability: PhoneCapability
    public let scope: String
    public let writes: Bool
    public let requiresFullAccess: Bool
    public let presentsUserGrant: Bool

    public init(capability: PhoneCapability, scope: String, writes: Bool = false,
                requiresFullAccess: Bool = false, presentsUserGrant: Bool = false) {
        self.capability = capability
        self.scope = scope
        self.writes = writes
        self.requiresFullAccess = requiresFullAccess
        self.presentsUserGrant = presentsUserGrant
    }
}

public enum PhoneToolCatalog {
    public static let routes: [String: PhoneToolRoute] = [
        "contacts.get": PhoneToolRoute(capability: .contacts, scope: "contacts.read"),
        "calendar.list": PhoneToolRoute(capability: .calendar, scope: "calendar.read", requiresFullAccess: true),
        "reminders.list": PhoneToolRoute(capability: .reminders, scope: "reminders.read", requiresFullAccess: true),
        "reminders.create": PhoneToolRoute(capability: .reminders, scope: "reminders.write", writes: true),
        "reminders.complete": PhoneToolRoute(capability: .reminders, scope: "reminders.write", writes: true),
        "health.summary": PhoneToolRoute(capability: .health, scope: "health.read"),
        "health.query": PhoneToolRoute(capability: .health, scope: "health.read"),
        "photos.recent": PhoneToolRoute(capability: .photos, scope: "photos.metadata.read"),
        "photos.search": PhoneToolRoute(capability: .photos, scope: "photos.metadata.read"),
        "camera.capture": PhoneToolRoute(capability: .camera, scope: "camera.capture", writes: true),
        "camera.scan_document": PhoneToolRoute(capability: .camera, scope: "camera.scan", writes: true),
        "audio.record": PhoneToolRoute(capability: .microphone, scope: "microphone.record", writes: true),
        "audio.transcribe": PhoneToolRoute(capability: .speech, scope: "speech.transcribe"),
        "location.current": PhoneToolRoute(capability: .location, scope: "location.current"),
        "notify.local": PhoneToolRoute(capability: .notifications, scope: "notifications.local", writes: true),
        "clipboard.read": PhoneToolRoute(capability: .clipboard, scope: "clipboard.read"),
        "clipboard.write": PhoneToolRoute(capability: .clipboard, scope: "clipboard.write", writes: true),
        "files.grant_folder": PhoneToolRoute(capability: .filesFolder, scope: "files.folder.grant", writes: true, presentsUserGrant: true),
        "files.list_roots": PhoneToolRoute(capability: .filesFolder, scope: "files.folder.list"),
        "device.status": PhoneToolRoute(capability: .device, scope: "device.read"),
        "motion.activity": PhoneToolRoute(capability: .motion, scope: "motion.activity.read"),
        "motion.steps": PhoneToolRoute(capability: .motion, scope: "motion.steps.read"),
        "bluetooth.scan": PhoneToolRoute(capability: .bluetooth, scope: "bluetooth.scan"),
        "network.browse": PhoneToolRoute(capability: .localNetwork, scope: "network.local.browse"),
        "location.geofence": PhoneToolRoute(capability: .locationAlways, scope: "location.geofence", writes: true),
        "focus.status": PhoneToolRoute(capability: .focus, scope: "focus.read"),
        "home.list": PhoneToolRoute(capability: .homekit, scope: "home.read"),
        "home.set": PhoneToolRoute(capability: .homekit, scope: "home.write", writes: true),
        "music.play": PhoneToolRoute(capability: .music, scope: "music.play", writes: true),
        "activity.start": PhoneToolRoute(capability: .liveActivity, scope: "activity.write", writes: true),
        "activity.update": PhoneToolRoute(capability: .liveActivity, scope: "activity.write", writes: true),
        "shortcuts.run": PhoneToolRoute(capability: .shortcuts, scope: "shortcuts.open", writes: true),
    ]
}

@MainActor
public struct PhoneCapabilityGate {
    private let store: PhonePermissionStore
    private let requester: PhonePermissionRequester

    public init(store: PhonePermissionStore = .shared,
                requester: PhonePermissionRequester = .shared) {
        self.store = store
        self.requester = requester
    }

    public func scope(for capability: PhoneCapability) async -> String {
        switch await requester.status(for: capability) {
        case .authorized: return "granted"
        case .limited: return "limited"
        case .requested: return "requested"
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .unavailable: return "unavailable"
        }
    }

    public func authorize(tool: String, route: PhoneToolRoute) async throws {
        guard store.isEnabled(route.capability) else {
            throw PhoneToolError.capabilityDisabled(route.capability)
        }
        let status = await requester.status(for: route.capability)
        switch status {
        case .notDetermined:
            if !route.presentsUserGrant {
                throw PhoneToolError.permissionRequired(route.capability)
            }
        case .denied, .restricted:
            throw PhoneToolError.permissionDenied(route.capability)
        case .unavailable:
            throw PhoneToolError.unavailable(route.capability, "当前设备不支持或系统尚未验证\(route.capability.title)")
        case .limited:
            if route.requiresFullAccess {
                throw PhoneToolError.permissionDenied(route.capability)
            }
        case .authorized, .requested:
            break
        }
        if route.writes, store.isEnabled(.biometrics), route.capability != .biometrics {
            guard await requester.confirmBiometricWrite(tool: tool) else {
                throw PhoneToolError.permissionDenied(.biometrics)
            }
        }
    }
}

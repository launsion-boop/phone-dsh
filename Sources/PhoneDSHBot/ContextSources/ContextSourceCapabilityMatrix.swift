// SPDX-License-Identifier: MIT

import Foundation

/// One row of the iOS native-context capability matrix.
///
/// The matrix is code, not a Markdown promise: the App's authorization surface
/// and the tests read the same entries. `unsupported` rows exist so no caller
/// can accidentally claim a platform capability iOS does not expose.
public enum BotContextCapabilitySupport: String, Codable, Sendable, CaseIterable {
    case supported
    case limited
    case unsupported
    case deferred

    public var allowsImplementationClaim: Bool {
        self == .supported || self == .limited
    }
}

/// Evidence layer a row was actually exercised at. A compile/unit row never
/// upgrades itself to a device row.
public enum BotContextCapabilityLayer: String, Codable, Sendable, CaseIterable {
    case unit
    case simulator
    case device
    case notRun = "not-run"
}

public struct BotContextCapability: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: BotContextSourceKind?
    public var support: BotContextCapabilitySupport
    public var framework: String
    public var usageDescriptionKeys: [String]
    public var layer: BotContextCapabilityLayer
    /// Bounded, deterministic explanation. For `unsupported`/`deferred` rows this
    /// is the platform fact, never a fixture limitation.
    public var reason: String

    public init(id: String, source: BotContextSourceKind? = nil,
                support: BotContextCapabilitySupport, framework: String,
                usageDescriptionKeys: [String] = [], layer: BotContextCapabilityLayer,
                reason: String) {
        self.id = id
        self.source = source
        self.support = support
        self.framework = framework
        self.usageDescriptionKeys = usageDescriptionKeys
        self.layer = layer
        self.reason = String(reason.prefix(300))
    }

    public var isUsableOnIOS: Bool {
        source != nil && support.allowsImplementationClaim
    }
}

/// The frozen-by-code inventory of what this iOS target can and cannot observe.
///
/// Android/HarmonyOS rows are `deferred`: they are not emulated with fixtures.
/// Third-party notification/SMS/call-history rows are `unsupported` because iOS
/// exposes no public API for them; the legal substitute is a user-shared item or
/// the App's own notification, both of which are separate rows below.
public enum BotContextCapabilityMatrix {
    public static let all: [BotContextCapability] = [
        // Calendar
        BotContextCapability(
            id: "calendar.read", source: .calendar, support: .supported,
            framework: "EventKit.EKEventStore", usageDescriptionKeys: ["NSCalendarsFullAccessUsageDescription"],
            layer: .simulator,
            reason: "Authorized calendars only; EKEventStoreChanged names no changed event; sync freshness is not guaranteed."),
        BotContextCapability(
            id: "calendar.background-change", source: .calendar, support: .limited,
            framework: "EventKit.EKEventStoreChanged", usageDescriptionKeys: ["NSCalendarsFullAccessUsageDescription"],
            layer: .notRun,
            reason: "The change notification is delivered while the process runs; iOS does not promise a background wake for it."),
        // Contacts
        BotContextCapability(
            id: "contacts.read", source: .contacts, support: .limited,
            framework: "Contacts.CNContactStore", usageDescriptionKeys: ["NSContactsUsageDescription"],
            layer: .simulator,
            reason: "Minimal keys, only for a user-initiated query/identifier; default masked; no full enumeration."),
        BotContextCapability(
            id: "contacts.background-change", source: .contacts, support: .limited,
            framework: "Contacts.CNContactStoreDidChange", usageDescriptionKeys: ["NSContactsUsageDescription"],
            layer: .notRun,
            reason: "Change notification carries no contact identity and is not a promised background wake."),
        // User-selected media/share
        BotContextCapability(
            id: "selected-media.read", source: .selectedMedia, support: .supported,
            framework: "PhotosUI.PHPickerViewController / Foundation.NSItemProvider",
            usageDescriptionKeys: [], layer: .simulator,
            reason: "Only the items the user explicitly picks or shares; no photo-library enumeration; metadata only in the observation."),
        // Location fence
        BotContextCapability(
            id: "location-fence.monitor", source: .locationFence, support: .supported,
            framework: "CoreLocation.CLCircularRegion",
            usageDescriptionKeys: ["NSLocationAlwaysAndWhenInUseUsageDescription"],
            layer: .simulator,
            reason: "User-confirmed fences only; Always authorization required; system delivery is delayed/approximate and may relaunch the App."),
        BotContextCapability(
            id: "location.continuous", source: .locationFence, support: .unsupported,
            framework: "CoreLocation", usageDescriptionKeys: ["NSLocationAlwaysAndWhenInUseUsageDescription"],
            layer: .notRun,
            reason: "This module intentionally does not start continuous location; only system geofence callbacks."),
        // Power / idle
        BotContextCapability(
            id: "power.charging", source: .power, support: .limited,
            framework: "UIKit.UIDevice.batteryState", usageDescriptionKeys: [],
            layer: .simulator,
            reason: "Requires batteryMonitoringEnabled; simulator may report unknown; no OS permission but App opt-in required."),
        BotContextCapability(
            id: "power.low-power", source: .power, support: .supported,
            framework: "Foundation.NSProcessInfoPowerStateDidChange", usageDescriptionKeys: [],
            layer: .simulator,
            reason: "Low Power Mode observation only; it does not imply charging state."),
        BotContextCapability(
            id: "power.system-idle", source: .power, support: .unsupported,
            framework: "none", usageDescriptionKeys: [],
            layer: .notRun,
            reason: "iOS exposes no public system-idle signal; BGTask is best-effort and is not an idle fact. Only App foreground/background is observed."),
        BotContextCapability(
            id: "app.lifecycle", source: .power, support: .supported,
            framework: "UIKit.UIApplication notifications", usageDescriptionKeys: [],
            layer: .simulator,
            reason: "App active/inactive/background transitions only; not a device-idle or charging proxy."),
        // The App's own notifications
        BotContextCapability(
            id: "own-notification.response", source: .ownNotification, support: .supported,
            framework: "UserNotifications.UNUserNotificationCenter", usageDescriptionKeys: [],
            layer: .simulator,
            reason: "Only notifications this App posted; the delegate is owned by the App, this module only receives the response."),
        BotContextCapability(
            id: "own-notification.delivered", source: .ownNotification, support: .supported,
            framework: "UserNotifications.UNUserNotificationCenter", usageDescriptionKeys: [],
            layer: .notRun,
            reason: "getDeliveredNotifications returns this App's notifications only; reading the whole notification center is impossible."),
        // Legal external entries
        BotContextCapability(
            id: "external.url", source: .externalEntry, support: .supported,
            framework: "UIKit.onOpenURL / SwiftUI.onOpenURL", usageDescriptionKeys: [],
            layer: .simulator,
            reason: "Only declared schemes/hosts are accepted; query strings are dropped from the observation."),
        BotContextCapability(
            id: "external.user-activity", source: .externalEntry, support: .supported,
            framework: "Foundation.NSUserActivity", usageDescriptionKeys: [],
            layer: .simulator,
            reason: "Only declared activity types are accepted; free-form userInfo is not copied."),
        BotContextCapability(
            id: "external.share-item", source: .externalEntry, support: .supported,
            framework: "Foundation.NSItemProvider (share extension)", usageDescriptionKeys: [],
            layer: .simulator,
            reason: "Requires a share-extension target (C owns project.yml); only the shared item is observed, not other App data."),
        BotContextCapability(
            id: "external.paste", source: .externalEntry, support: .supported,
            framework: "UIKit.UIPasteboard", usageDescriptionKeys: [],
            layer: .simulator,
            reason: "Only after a user tap; never polled in the background; credential-shaped text is rejected."),
        // Platform negatives: these are the rows the product must not fake.
        BotContextCapability(
            id: "third-party-notifications.read", support: .unsupported,
            framework: "none", layer: .notRun,
            reason: "iOS has no public API to read notifications posted by other apps. Legal substitutes: user-shared content or this App's own notification."),
        BotContextCapability(
            id: "sms.read", support: .unsupported,
            framework: "none", layer: .notRun,
            reason: "iOS has no public API for SMS messages. Use a user share/paste entry instead; do not emulate with mock data."),
        BotContextCapability(
            id: "call-history.read", support: .unsupported,
            framework: "CallKit", layer: .notRun,
            reason: "CallKit does not expose call history. iOS cannot read the Phone app's call log."),
        BotContextCapability(
            id: "photos-library.enumerate", support: .unsupported,
            framework: "Photos.PHAsset", layer: .notRun,
            reason: "Deliberately out of scope: this source processes only user-selected items, never a whole-library enumeration."),
        BotContextCapability(
            id: "android.notification-listener", support: .deferred,
            framework: "Android NotificationListenerService", layer: .notRun,
            reason: "Android-only; deferred by the user. Not implemented or simulated on iOS."),
        BotContextCapability(
            id: "android.sms-call-log", support: .deferred,
            framework: "Android Telephony", layer: .notRun,
            reason: "Android-only and policy-restricted; deferred by the user. Not implemented or simulated on iOS."),
    ]

    public static func entry(id: String) -> BotContextCapability? {
        all.first { $0.id == id }
    }

    public static func entries(for source: BotContextSourceKind) -> [BotContextCapability] {
        all.filter { $0.source == source }
    }

    /// The best usable capability of a source. Unsupported *sub-capability*
    /// rows (for example `power.system-idle`) do not make the whole source
    /// unsupported; the UI must show them as explicit unavailable rows.
    public static func support(for source: BotContextSourceKind) -> BotContextCapabilitySupport {
        let rows = entries(for: source)
        if rows.contains(where: { $0.support == .supported }) { return .supported }
        if rows.contains(where: { $0.support == .limited }) { return .limited }
        return .unsupported
    }

    public static func matrixJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(all)
    }
}

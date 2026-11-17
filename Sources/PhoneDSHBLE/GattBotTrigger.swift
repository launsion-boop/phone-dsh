// SPDX-License-Identifier: MIT
import Foundation

/// device-bot-v1 §4, standard GATT class: the Bot trigger is "the user turns on a read grant or
/// an alert grant for that peripheral". `BLEDeviceStore.trustConnectedDevices` makes both flags
/// true after a bare connection, so the stored flags alone never prove a user action. The
/// decision is therefore an edge between the flags observed immediately before and after one
/// explicit user toggle (`BLEDeviceStore.grant(_:read:alert:)`). A connection, a scan, a restored
/// default or a toggle to off never produces a trigger, and nothing here deletes or hides a Bot.
public struct GattBotTrigger: Equatable, Sendable {
    /// CoreBluetooth peripheral UUID, as `UUID.uuidString`; the Bot key lowercases it.
    public let peripheralUUID: String
    public let name: String
    /// Granted profile names (`StandardBLEProfile.rawValue`), the labels of `DeviceBotText.gattDescription`.
    public let profiles: [String]

    /// The grant flags of one device at one instant.
    public struct Snapshot: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let profiles: [StandardBLEProfile]
        public let allowRead: Bool
        public let allowAlert: Bool
        /// A Link device (identity, device ID or tool list known) is not a standard GATT device.
        public let isLinkDevice: Bool

        public init(id: UUID, name: String, profiles: [StandardBLEProfile],
                    allowRead: Bool, allowAlert: Bool, isLinkDevice: Bool) {
            self.id = id; self.name = name; self.profiles = profiles
            self.allowRead = allowRead; self.allowAlert = allowAlert; self.isLinkDevice = isLinkDevice
        }
    }

    /// `nil` unless a read or alert grant went from off to on between `before` and `after`.
    /// `isBoard` is the app's classification of the TonoLink board (its voice link is not a GATT device).
    public static func decide(before: Snapshot?, after: Snapshot?, isBoard: Bool) -> GattBotTrigger? {
        guard let before, let after, before.id == after.id else { return nil }
        guard !isBoard, !before.isLinkDevice, !after.isLinkDevice else { return nil }
        let readOn = !before.allowRead && after.allowRead
        let alertOn = !before.allowAlert && after.allowAlert
        guard readOn || alertOn else { return nil }
        var granted: [String] = []
        if after.allowRead {
            granted += after.profiles.filter { $0 != .alert }.map(\.rawValue)
        }
        if after.allowAlert, after.profiles.contains(.alert) { granted.append(StandardBLEProfile.alert.rawValue) }
        return GattBotTrigger(peripheralUUID: after.id.uuidString, name: after.name, profiles: granted)
    }
}

extension BLEDeviceStore {
    /// The grant-relevant state of a device, or nil when it is not in the store.
    public func gattGrantSnapshot(_ id: UUID) -> GattBotTrigger.Snapshot? {
        guard let d = devices.first(where: { $0.id == id }) else { return nil }
        return GattBotTrigger.Snapshot(
            id: d.id, name: d.name, profiles: d.profiles, allowRead: d.allowRead, allowAlert: d.allowAlert,
            isLinkDevice: !d.linkIdentity.isEmpty || !d.linkDeviceID.isEmpty || !d.linkTools.isEmpty)
    }

    /// The user's grant action: applies it, then reports the Bot trigger when it turned a grant on.
    /// Only this explicit path can trigger; connection, discovery and trust restore never call it.
    @discardableResult
    public func userGrant(_ id: UUID, read: Bool? = nil, alert: Bool? = nil, isBoard: Bool) -> GattBotTrigger? {
        let before = gattGrantSnapshot(id)
        grant(id, read: read, alert: alert)
        return GattBotTrigger.decide(before: before, after: gattGrantSnapshot(id), isBoard: isBoard)
    }
}

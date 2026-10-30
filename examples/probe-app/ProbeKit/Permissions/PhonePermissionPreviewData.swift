// SPDX-License-Identifier: MIT

import Foundation

public enum PhonePermissionPreviewData {
    public static let statuses: [PhoneCapability: CapabilityStatus] = [
        .contacts: .limited(12),
        .calendar: .authorized,
        .reminders: .notDetermined,
        .health: .requested,
        .photos: .limited(8),
        .camera: .denied,
        .microphone: .authorized,
        .speech: .notDetermined,
        .location: .authorized,
        .locationAlways: .notDetermined,
        .motion: .notDetermined,
        .bluetooth: .notDetermined,
        .notifications: .authorized,
        .biometrics: .authorized,
        .localNetwork: .notDetermined,
        .clipboard: .authorized,
        .filesFolder: .notDetermined,
        .device: .authorized,
        .shortcuts: .authorized,
        .focus: .notDetermined,
        .homekit: .notDetermined,
        .music: .notDetermined,
        .liveActivity: .authorized,
    ]

    public static let audit: [PhoneCapabilityAuditRecord] = [
        PhoneCapabilityAuditRecord(capability: .device, tool: "device.status", outcome: "success"),
        PhoneCapabilityAuditRecord(capability: .contacts, tool: "contacts.search", outcome: "success"),
    ]
}

// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — device panels on the Discover page.
//
// A panel used to be four levels deep (Discover › Devices › Connect a device ›
// the device row › panel). This section lists the panels a user already has —
// every connected device with Link tools, plus adopted descriptors whose
// device is not connected right now — so a panel is one tap from Discover.
//
// Local reads only: the device list and the adopted copies. Nothing here calls
// a device (device-panel.md §2).

import PhoneDSHBLE
import SwiftUI

@MainActor
struct DevicePanelShortcuts: View {
    @State private var store = BLEDeviceStore.shared
    @State private var adopted: [DevicePanelStore.AdoptedSummary] = []

    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        /// The connected peripheral, when the panel can be opened right now.
        let deviceID: UUID?
    }

    /// Connected devices first (a device without an adopted descriptor still
    /// has its generated panel), then adopted panels waiting for their device.
    static func entries(devices: [BLEDeviceStore.Device],
                        adopted: [DevicePanelStore.AdoptedSummary]) -> [Entry] {
        var entries: [Entry] = []
        var connectedLinkIDs = Set<String>()
        for device in devices where !device.linkTools.isEmpty && !device.linkDeviceID.isEmpty {
            connectedLinkIDs.insert(device.linkDeviceID)
            let title = adopted.first { $0.linkDeviceID == device.linkDeviceID }?.title
            entries.append(Entry(id: "device:" + device.id.uuidString, title: title ?? device.name,
                                 subtitle: title == nil ? "已连接" : "\(device.name) · 已连接",
                                 deviceID: device.id))
        }
        for summary in adopted where !connectedLinkIDs.contains(summary.linkDeviceID) {
            entries.append(Entry(id: "adopted:" + summary.linkDeviceID, title: summary.title ?? "设备面板",
                                 subtitle: "设备未连接，点按去连接", deviceID: nil))
        }
        return entries
    }

    var body: some View {
        let entries = Self.entries(devices: store.devices, adopted: adopted)
        Group {
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink {
                            if let device = store.devices.first(where: { $0.id == entry.deviceID }) {
                                DevicePanelPage(device: device, store: store)
                            } else {
                                BluetoothDevicesPage()
                            }
                        } label: {
                            row(entry)
                        }
                        .accessibilityIdentifier("discover-device-panel")
                    }
                } header: {
                    Text("设备面板")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(HomeSpec.textPlaceholder)
                        .textCase(nil)
                }
            }
        }
        .task { adopted = DevicePanelStore.shared.adoptedSummaries() }
        .onChange(of: store.devices.map(\.linkDeviceID)) { _, _ in
            adopted = DevicePanelStore.shared.adoptedSummaries()
        }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(entry.deviceID == nil ? HomeSpec.iconMuted : Color(red: 0.19, green: 0.69, blue: 0.78),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title)
                    .font(.system(size: HomeSpec.bodySize))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .lineLimit(1)
                Text(verbatim: entry.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

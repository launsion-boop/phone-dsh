// SPDX-License-Identifier: MIT

import ProbeKit
import SwiftUI
import UIKit

struct NativeDeviceEntryIcon: View {
    let online: Bool

    var body: some View {
        Image(systemName: "iphone")
            .font(.system(size: 18, weight: .regular))
            .overlay(alignment: .topTrailing) {
                if online {
                    Circle()
                        .fill(HomeSpec.success)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1))
                        .offset(x: 4, y: -2)
                }
            }
    }
}

struct NativeDeviceSessionRows: View {
    let devices: [DeviceConnectionSnapshot]
    let connectorAvailable: Bool
    let openingDeviceID: String?
    let open: (DeviceConnectionSnapshot) -> Void

    var body: some View {
        if !connectorAvailable {
            ContentUnavailableView("未接入设备连接器", systemImage: "iphone.slash",
                                   description: Text("当前版本不会扫描、配对或伪造在线设备。"))
        } else if devices.isEmpty {
            ContentUnavailableView("没有在线设备", systemImage: "iphone",
                                   description: Text("连接器尚未发布真实在线设备。"))
        } else {
            ForEach(devices) { device in
                Button { open(device) } label: {
                    HStack(spacing: 10) {
                        NativeDeviceEntryIcon(online: true)
                            .frame(width: 22, height: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.displayName)
                                .font(.system(size: HomeSpec.bodySize))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(device.deviceID)
                                .font(.system(size: 13))
                                .foregroundStyle(ChatPage.inkSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if openingDeviceID == device.deviceID {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(openingDeviceID != nil)
                .accessibilityIdentifier("device-session-\(device.deviceID)")
            }
        }
    }
}

struct NativeDeviceConnectionPage: View {
    /// False when pushed onto a stack: the back button already returns.
    var showsDone = true
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = DeviceSessionCoordinator.shared
    @State private var selection: DeviceSessionMapping?
    @State private var openingDeviceID: String?
    @State private var selectionError: String?
    @State private var failedDeviceID: String?

    var body: some View {
        List {
            if let error = selectionError ?? coordinator.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(ChatPage.danger)
                        .textSelection(.enabled)
                    if let failedDeviceID,
                       coordinator.savedMapping(for: failedDeviceID) != nil {
                        Button("解除该设备的会话映射") {
                            forgetMapping(for: failedDeviceID)
                        }
                        .accessibilityIdentifier("device-session-forget-\(failedDeviceID)")
                    }
                }
            }

            Section {
                NativeDeviceSessionRows(devices: coordinator.onlineDevices,
                                        connectorAvailable: coordinator.isConnectorAvailable,
                                        openingDeviceID: openingDeviceID) { device in
                    open(device)
                }
            } header: {
                Text("真实连接设备")
            }

            Section {
                capabilityRow("蓝牙连接器")
                capabilityRow("局域网连接器")
            } header: {
                Text("传输能力")
            } footer: {
                Text("真实传输尚未实现。此页只展示已注入连接器发布的状态，不会主动发起扫描。")
            }
        }
        .homeGroupedList()
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selection) { mapping in
            NativeDeviceSessionPage(mapping: mapping)
        }
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private func open(_ device: DeviceConnectionSnapshot) {
        guard openingDeviceID == nil else { return }
        openingDeviceID = device.deviceID
        selectionError = nil
        failedDeviceID = nil
        Task {
            defer { openingDeviceID = nil }
            do {
                selection = try await coordinator.resolveSession(for: device.deviceID)
            } catch {
                selectionError = error.localizedDescription
                failedDeviceID = device.deviceID
            }
        }
    }

    /// A saved Session can disappear (DSH data reset, app reinstall). The mapping is kept
    /// on failure by design; this is the explicit way out that never silently rebinds.
    private func forgetMapping(for deviceID: String) {
        do {
            try coordinator.forgetMapping(for: deviceID)
            selectionError = nil
            failedDeviceID = nil
        } catch {
            selectionError = error.localizedDescription
        }
    }

    private func capabilityRow(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("未提供")
                .foregroundStyle(ChatPage.inkSecondary)
        }
        .frame(minHeight: 44)
    }
}

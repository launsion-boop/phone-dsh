// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native preview of a device panel descriptor file.
//
// The chat and the Files page open a workspace file in `PreviewSurface`. A
// descriptor under `device-panels/` used to appear there as raw JSON. This
// view shows what the panel will look like instead and gives the user one tap
// to adopt it and open the real panel.
//
// It stays inside device-panel.md §4.1: nothing here calls the device. The
// preview buttons are inert pictures of the controls; only the adopted,
// host-private copy drives the panel, and adoption is this explicit tap in
// native UI. The descriptor is evaluated with the real §4.2 evaluator against
// the connected device's live tool table.

import PhoneDSHAgentCore
import PhoneDSHBLE
import SwiftUI

@MainActor
struct DevicePanelDescriptorPreview: View {
    let path: String

    @State private var store = BLEDeviceStore.shared
    @State private var bytes: Data?
    @State private var model: DevicePanelModel?
    @State private var modelDeviceID: UUID?
    @State private var adopting = false
    @State private var adoptError: String?
    @State private var openPanel = false

    /// Workspace files the model writes for a device panel (native-mcp.md
    /// `panel_path`). The name is only how the preview is chosen; the content
    /// is evaluated like any other descriptor.
    static func handles(_ path: String) -> Bool {
        path.hasPrefix("device-panels/") && path.hasSuffix(".json")
    }

    /// The connected device this descriptor names, or the only connected device
    /// with Link tools (evaluation then explains a mismatch).
    private var device: BLEDeviceStore.Device? {
        let candidates = store.devices.filter { !$0.linkTools.isEmpty && !$0.linkDeviceID.isEmpty }
        if let bytes, let named = (try? JSONValue.parse(bytes))?["device_id"]?.stringValue,
           let match = candidates.first(where: { $0.linkDeviceID == named }) {
            return match
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    var body: some View {
        let device = self.device
        List {
            if bytes == nil {
                Section { Text("无法读取这个文件。").foregroundStyle(.secondary) }
            } else if let device, let model, let bytes {
                content(bytes: bytes, device: device, model: model)
            } else {
                Section {
                    Text("这是一份设备面板描述。先在蓝牙设备页连接对应的设备，再回来采用。")
                        .foregroundStyle(.secondary)
                }
            }
            rawSection
        }
        .homeGroupedList()
        .task(id: path) { load() }
        .onChange(of: device?.id) { _, _ in bind(device) }
        .onChange(of: device?.linkToolDescriptors) { _, _ in model?.refresh() }
        .onChange(of: device?.grantedTools) { _, _ in model?.refresh() }
        .navigationDestination(isPresented: $openPanel) {
            if let device { DevicePanelPage(device: device, store: store) }
        }
    }

    @ViewBuilder
    private func content(bytes: Data, device: BLEDeviceStore.Device, model: DevicePanelModel) -> some View {
        let review = model.reviewDescriptor(bytes)
        if review.isOK, let descriptor = review.descriptor {
            let adopted = model.descriptor == descriptor
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: descriptor.title ?? device.name)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                    Text(verbatim: "\(device.name) 的面板预览")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(Array(Self.groups(descriptor).enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(Array(group.controls.enumerated()), id: \.offset) { _, control in
                        controlPicture(control, model: model)
                    }
                } header: {
                    if let title = group.title { Text(verbatim: title).lineLimit(1) }
                }
            }
            Section {
                Button {
                    adoptAndOpen(bytes: bytes, model: model, alreadyAdopted: adopted)
                } label: {
                    if adopting {
                        ProgressView().tint(HomeSpec.primaryButtonInk)
                    } else {
                        Text(adopted ? "打开面板" : "采用并打开面板")
                    }
                }
                .buttonStyle(HomePrimaryButtonStyle())
                .disabled(adopting)
                .accessibilityIdentifier("device-panel-preview-adopt")
                if let adoptError {
                    Text(verbatim: adoptError).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text(adopted
                     ? "这份描述已经是这台设备的面板。"
                     : "预览里的按钮不会调用设备。采用后它成为这台设备的面板，只改变显示，不改变授权；之后可以在面板里移除。")
                    .font(.footnote)
            }
        } else {
            Section("这份描述现在不能用") {
                Text(verbatim: DevicePanelPage.descriptorReason(review.result))
                    .foregroundStyle(.red)
                Button("打开设备现有的面板") { openPanel = true }
            }
        }
    }

    /// An inert picture of one control: the label as it will appear, and the
    /// exact tool and arguments a tap would send once adopted.
    private func controlPicture(_ control: DevicePanelControl, model: DevicePanelModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: control.label)
                .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                .foregroundStyle(HomeSpec.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(HomeSpec.page, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(HomeSpec.borderList, lineWidth: 1)
                }
            Text(verbatim: control.preset.map { "\(control.tool) \(DevicePanelJSONText.compact($0))" }
                 ?? "\(control.tool)（带参数编辑）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if !model.isAuthorized(control.tool) {
                Text("这个工具还没有授权，采用后也要先到蓝牙设备页允许。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var rawSection: some View {
        Section {
            DisclosureGroup("文件内容") {
                Text(verbatim: bytes.map { String(decoding: $0.prefix(16_384), as: UTF8.self) } ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.footnote)
        }
    }

    private static func groups(_ descriptor: DevicePanelDescriptor) -> [DevicePanelGroup] {
        var groups: [DevicePanelGroup] = []
        for control in descriptor.controls {
            if let index = groups.firstIndex(where: { $0.title == control.group }) {
                groups[index].controls.append(control)
            } else {
                groups.append(DevicePanelGroup(id: groups.count, title: control.group, controls: [control]))
            }
        }
        return groups
    }

    // MARK: Actions (local only)

    private func load() {
        bytes = DevicePanelAdoptionSheet.descriptorURL(for: path).flatMap(DevicePanelAdoptionSheet.readCapped)
        bind(device)
    }

    private func bind(_ device: BLEDeviceStore.Device?) {
        guard let device else { model = nil; modelDeviceID = nil; return }
        if modelDeviceID != device.id {
            let bound = DevicePanelModel(source: LiveDevicePanelSource(device: device, store: store),
                                         results: .shared(for: device.id))
            bound.refresh()
            model = bound
            modelDeviceID = device.id
        }
    }

    private func adoptAndOpen(bytes: Data, model: DevicePanelModel, alreadyAdopted: Bool) {
        adoptError = nil
        if alreadyAdopted { openPanel = true; return }
        adopting = true
        Task {
            let result = await model.adoptDescriptor(bytes)
            adopting = false
            if result == .ok {
                openPanel = true
            } else {
                adoptError = result.map { "没有采用：\(DevicePanelPage.descriptorReason($0))" }
                    ?? (model.errorText ?? "采用失败。")
            }
        }
    }
}

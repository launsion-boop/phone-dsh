// SPDX-License-Identifier: MIT
import SwiftUI
import PhoneDSHBLE

struct BluetoothDevicesPage: View {
    @State private var store = BLEDeviceStore.shared
    @State private var message = ""
    @State private var showOtherDevices = false
    @State private var legacyInspection = LegacyTaskInspectionModel()
    #if PDSH_ENABLE_DEVICE_TASKS
    @State private var taskManager = DeviceTaskManager.shared
    #endif

    /// A device is shown by default when it is connecting/connected, has a known
    /// standard or Link capability, or is one of our own PDSH peripherals.
    /// Unconnected nearby devices with nothing known are collapsed.
    static func isVisible(_ device: BLEDeviceStore.Device) -> Bool {
        device.state != "未连接" || !device.profiles.isEmpty || !device.linkTools.isEmpty || device.name.hasPrefix("PDSH")
    }

    var body: some View {
        let hidden = store.devices.filter { !Self.isVisible($0) }
        List {
            Section {
                Text(store.status)
                Button(store.scanning ? "停止扫描" : "扫描附近 BLE 设备") {
                    if store.scanning { store.stopScan() } else { store.scan() }
                }
                Text("只在此页主动扫描。选择设备后发现标准服务；每次连接需单独授权 Agent 读取或提醒控制。设备名称和系统标识不代表已验证身份。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(store.devices.filter(Self.isVisible)) { device in
                deviceSection(device)
            }
            if !hidden.isEmpty {
                Section {
                    Button(showOtherDevices ? "收起其他设备" : "展开其他设备（\(hidden.count) 个，未发现设备能力）") {
                        showOtherDevices.toggle()
                    }
                }
                if showOtherDevices {
                    ForEach(hidden) { device in
                        deviceSection(device)
                    }
                }
            }
            if !message.isEmpty { Section("结果") { Text(message).textSelection(.enabled) } }
            LegacyTaskInspectionSection(model: legacyInspection, language: NativeChatPreferences.shared.language)
            #if PDSH_ENABLE_DEVICE_TASKS
            if let error = taskManager.error { Section { Text(error).foregroundStyle(.red) } }
            #endif
            Section("支持范围") {
                Text("标准电量、环境温度 / 湿度、厂商 / 型号与 Immediate Alert；兼容 xiaozhi-link 握手的 PDSH Link 工具扩展支持 light.set 和 home.http。提醒是标准 Write Without Response，只能确认提交，不能确认硬件执行。暂不支持音频、HID 控制、HomeKit / Matter 或私有 GATT 协议。")
            }
        }
        .navigationTitle("蓝牙设备")
        .onDisappear { legacyInspection.cancelAndClear(); store.stopScan() }
    }

    @ViewBuilder
    private func deviceSection(_ device: BLEDeviceStore.Device) -> some View {
        Section {
            Text(device.id.uuidString).font(.caption).textSelection(.enabled)
            Text("\(device.state) · RSSI \(device.rssi)")
            if device.state == "未连接" {
                Button("连接并发现设备能力") { store.connect(device.id) }
            } else {
                Button("断开连接", role: .destructive) { store.disconnect(device.id) }
                Toggle("允许读取标准数据", isOn: Binding(get: {
                    store.devices.first(where: { $0.id == device.id })?.allowRead ?? false
                }, set: { store.grant(device.id, read: $0) }))
                if device.profiles.contains(.alert) {
                    Toggle("允许提醒控制（蜂鸣 / 震动）", isOn: Binding(get: {
                        store.devices.first(where: { $0.id == device.id })?.allowAlert ?? false
                    }, set: { store.grant(device.id, alert: $0) }))
                    ForEach(0...2, id: \.self) { level in
                        Button(["停止提醒", "轻度提醒", "高度提醒"][level]) {
                            do { message = try store.alert(device.id, level: level) } catch { message = error.localizedDescription }
                        }.disabled(!device.allowAlert)
                    }
                }
                ForEach(device.profiles.filter { $0 != .alert }, id: \.self) { profile in
                    Button("读取 \(profile.rawValue)") {
                        Task {
                            do { message = try await store.read(device.id, profile: profile) }
                            catch { message = error.localizedDescription }
                        }
                    }.disabled(!device.allowRead)
                    if let value = device.readings[profile.rawValue] { Text(value).font(.caption) }
                }
                Text(device.linkState).font(.footnote)
                #if PDSH_ENABLE_DEVICE_TASKS
                if !device.pendingIdentity.isEmpty {
                    Text("实验性身份指纹：记录指纹不会开启设备派任务；蓝牙任务授权目前不可用。")
                        .font(.footnote)
                    Text(device.pendingIdentity).font(.caption.monospaced()).textSelection(.enabled)
                    Button("记录此实验性指纹") { store.trustPendingIdentity(device.id) }
                }
                if device.supportsDeviceTasks {
                    let key = DeviceTaskManager.bleKey(device.id)
                    Toggle("允许设备向手机派任务", isOn: Binding(get: { taskManager.isActive(key) }, set: { enabled in
                        Task { if enabled { await taskManager.startBLE(device.id) } else { await taskManager.stop(key) } }
                    }))
                    Text("仅当前连接和前台有效，设备只能提交文字任务并接收最终答复。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                #endif
                if !device.linkIdentity.isEmpty { Text("设备 ID：\(device.linkIdentity)").font(.caption).textSelection(.enabled) }
                ForEach(device.linkTools, id: \.self) { name in
                    Toggle("允许工具：\(name)", isOn: Binding(get: {
                        store.devices.first(where: { $0.id == device.id })?.grantedTools.contains(name) ?? false
                    }, set: { store.grantLinkTool(device.id, name: name, enabled: $0) }))
                }
                if device.linkTools.contains("home.http") {
                    TextField("允许的家居地址：http://192.168.1.50:8123", text: Binding(get: {
                        store.devices.first(where: { $0.id == device.id })?.homeOrigins ?? ""
                    }, set: { store.setHomeOrigins(device.id, text: $0) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("只允许填写明确的私网 IP 与端口，多个地址用空格分隔。设备固件也必须允许该地址。HTTP 不跟随跳转。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(device.events.enumerated()), id: \.offset) { _, event in Text(event).font(.caption).textSelection(.enabled) }
                if device.profiles.isEmpty && device.linkTools.isEmpty { Text("尚未发现可用标准能力；厂商私有服务需要专用适配器。") }
            }
        } header: { Text(device.name) }
    }
}

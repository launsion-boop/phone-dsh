// SPDX-License-Identifier: MIT
import CoreBluetooth
import Foundation
import Observation
import PhoneDSHAgentCore

@MainActor @Observable public final class BLEDeviceStore: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public static let shared = BLEDeviceStore()
    static func isReservedTaskTool(_ name: String) -> Bool { name.hasPrefix("pdsh.task.") || name.hasPrefix("pdsh.identity.") }
    public struct Device: Identifiable {
        public let id: UUID
        public var name: String
        public var rssi: Int
        public var state = "未连接"
        public var profiles: [StandardBLEProfile] = []
        public var allowRead = false
        public var allowAlert = false
        public var linkIdentity = ""
        public var linkState = "未发现 Link"
        public var linkTools: [String] = []
        public var linkToolDescriptors: [JSONValue] = []
        public var allowDeviceTasks = false
        public var supportsDeviceTasks = false
        /// Identity proven on the current connection and confirmed by the user ("ble:" + key hash).
        public var taskIdentity = ""
        /// Identity proven on the current connection but not yet confirmed by the user.
        public var pendingIdentity = ""
        public var grantedTools: Set<String> = []
        public var homeOrigins = ""
        public var events: [String] = []
        public var readings: [String: String] = [:]
    }
    public private(set) var devices: [Device] = []
    public private(set) var status = "点击扫描以请求蓝牙权限"
    public private(set) var scanning = false
    override init() { super.init() }
    // Allows the grant boundary to be tested without a physical peripheral.
    init(testDevices: [Device]) { self.devices = testDevices; super.init() }
    @ObservationIgnored private var linkBootIDs: [UUID: UInt32] = [:]
    @ObservationIgnored private var linkEventSequences: [UUID: UInt32] = [:]
    @ObservationIgnored private var linkCharacteristics: [UUID: [String: CBCharacteristic]] = [:]
    @ObservationIgnored private var linkChannels: [UUID: BLELinkChannel] = [:]
    @ObservationIgnored private var linkClients: [UUID: PDSHLinkClient] = [:]
    @ObservationIgnored private var deviceTaskDiscoveryEnabled = false
    @ObservationIgnored private var linkTaskTools: [UUID: Set<String>] = [:]
    @ObservationIgnored private var linkTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var linkBusy = Set<UUID>()
    @ObservationIgnored private var scanRequested = false
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var characteristics: [UUID: [StandardBLEProfile: CBCharacteristic]] = [:]
    @ObservationIgnored private var ambiguousProfiles: [UUID: Set<StandardBLEProfile>] = [:]
    @ObservationIgnored private var connectionTimers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var scanTimer: Task<Void, Never>?
    @ObservationIgnored private var pending: (token: UUID, device: UUID, profile: StandardBLEProfile, continuation: CheckedContinuation<String, Error>)?
    @ObservationIgnored private var operationTimer: Task<Void, Never>?

    public var bluetoothDiagnostics: String {
        "authorization=\(CBManager.authorization.rawValue) state=\(central?.state.rawValue ?? -1) scanning=\(central?.isScanning ?? false) delegate=\(central?.delegate === self)"
    }
    /// Must be selected before connecting; changing it never upgrades an
    /// already-negotiated connection.
    public func setDeviceTaskDiscoveryEnabled(_ enabled: Bool) {
        guard linkClients.isEmpty, linkTasks.isEmpty else { return }
        deviceTaskDiscoveryEnabled = enabled
    }
    public func scan() {
        if central == nil { scanRequested = true; status = "正在初始化蓝牙"; central = CBCentralManager(delegate: self, queue: .main); return }
        guard central?.state == .poweredOn else { status = "请在系统设置中开启蓝牙并授权"; return }
        // Foreground, bounded scan. Unadvertised services are discovered after user selection.
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true; status = "正在扫描（15 秒）"
        scanTimer?.cancel()
        scanTimer = Task { try? await Task.sleep(for: .seconds(15)); guard !Task.isCancelled else { return }; stopScan() }
    }
    public func stopScan() { scanRequested = false; central?.stopScan(); scanning = false; scanTimer?.cancel() }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            status = "蓝牙已就绪，请点击扫描"
            if scanRequested { scanRequested = false; scan() }
        }
        else {
            stopScan(); status = "蓝牙不可用，状态：\(central.state.rawValue)"
            finish(.failure(BLEFailure("Bluetooth unavailable")))
            for id in peripherals.keys { clearConnection(id) }
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripherals[peripheral.identifier] != nil || devices.count < 100 else { return }
        peripherals[peripheral.identifier] = peripheral
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName.flatMap { $0.isEmpty ? nil : $0 } ?? peripheral.name ?? "未命名 BLE 设备"
        if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[index].rssi = RSSI.intValue
            devices[index].name = name
        } else { devices.append(Device(id: peripheral.identifier, name: name, rssi: RSSI.intValue)) }
    }
    public func connect(_ id: UUID) {
        guard let peripheral = peripherals[id], central?.state == .poweredOn, peripheral.state == .disconnected else { return }
        stopScan(); update(id) { $0.state = "连接中" }
        peripheral.delegate = self; central?.connect(peripheral)
        connectionTimers[id] = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            status = "连接或服务发现超时"; disconnect(id)
        }
    }
    public func disconnect(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        central?.cancelPeripheralConnection(peripheral)
        clearConnection(id)
    }
    public func grant(_ id: UUID, read: Bool? = nil, alert: Bool? = nil) {
        update(id) { if let read { $0.allowRead = read }; if let alert { $0.allowAlert = alert } }
        if pending?.device == id { finish(.failure(BLEFailure("Device permissions changed"))); disconnect(id) }
    }
    private func update(_ id: UUID, _ body: (inout Device) -> Void) {
        if let index = devices.firstIndex(where: { $0.id == id }) { body(&devices[index]) }
    }
    private func clearConnection(_ id: UUID) {
        linkTasks.removeValue(forKey: id)?.cancel()
        linkChannels.removeValue(forKey: id)?.fail(BLEFailure("Link disconnected; outcome_unknown"))
        linkClients[id] = nil; linkTaskTools[id] = nil; linkCharacteristics[id] = nil; linkBootIDs[id] = nil; linkEventSequences[id] = nil
        update(id) { $0.linkState = "未连接"; $0.linkIdentity = ""; $0.linkTools = []; $0.linkToolDescriptors = []; $0.allowDeviceTasks = false; $0.supportsDeviceTasks = false; $0.taskIdentity = ""; $0.pendingIdentity = ""; $0.grantedTools = []; $0.homeOrigins = ""; $0.events = [] }
        connectionTimers.removeValue(forKey: id)?.cancel(); characteristics[id] = nil; ambiguousProfiles[id] = nil
        update(id) { $0.state = "未连接"; $0.profiles = []; $0.readings = [:]; $0.allowRead = false; $0.allowAlert = false }
        if pending?.device == id { finish(.failure(BLEFailure("Device disconnected"))) }
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        update(peripheral.identifier) { $0.state = "发现服务中" }
        peripheral.discoverServices((Array(Set(StandardBLEProfile.allCases.map(\.service))) + [PDSHLink.service]).map { CBUUID(string: $0) })
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = error?.localizedDescription ?? "连接失败"; clearConnection(peripheral.identifier)
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { clearConnection(peripheral.identifier) }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { status = error!.localizedDescription; disconnect(peripheral.identifier); return }
        let services = peripheral.services ?? []
        if services.isEmpty { connectionTimers.removeValue(forKey: peripheral.identifier)?.cancel(); update(peripheral.identifier) { $0.state = "无支持的标准服务" } }
        for service in services {
            if service.uuid == CBUUID(string: PDSHLink.service) {
                update(peripheral.identifier) { $0.linkState = "发现 Link 特征中" }
                peripheral.discoverCharacteristics([PDSHLink.rx, PDSHLink.tx, PDSHLink.audioUp].map { CBUUID(string: $0) }, for: service)
                continue
            }
            let ids = StandardBLEProfile.allCases.filter { CBUUID(string: $0.service) == service.uuid }.map { CBUUID(string: $0.characteristic) }
            peripheral.discoverCharacteristics(ids, for: service)
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { status = error!.localizedDescription; disconnect(peripheral.identifier); return }
        if service.uuid == CBUUID(string: PDSHLink.service) {
            let id = peripheral.identifier
            var found: [String: CBCharacteristic] = [:]
            for c in service.characteristics ?? [] { found[c.uuid.uuidString.lowercased()] = c }
            linkCharacteristics[id] = found
            if let rx = found[PDSHLink.rx], let tx = found[PDSHLink.tx], let audio = found[PDSHLink.audioUp],
               rx.properties.contains(.write), tx.properties.contains(.notify), audio.properties.contains(.notify) {
                let channel = BLELinkChannel(peripheral: peripheral, rx: rx, tx: tx, audio: audio)
                channel.onFailure = { [weak self] in self?.disconnect(id) }
                channel.onEvent = { [weak self] data in
                    guard let self, let bootID = self.linkBootIDs[id],
                          let device = self.devices.first(where: { $0.id == id }),
                          let event = try? PDSHLinkEvent(data: data, expectedBootID: bootID, expectedDeviceID: device.linkIdentity),
                          event.sequence > (self.linkEventSequences[id] ?? 0), let text = String(data: data, encoding: .utf8) else { return }
                    self.linkEventSequences[id] = event.sequence
                    self.update(id) { $0.events.append(text); if $0.events.count > 32 { $0.events.removeFirst() } }
                }
                linkChannels[id] = channel
                peripheral.setNotifyValue(true, for: tx); peripheral.setNotifyValue(true, for: audio)
                update(id) { $0.linkState = "等待加密、绑定与订阅" }
            } else { update(id) { $0.linkState = "Link 特征不完整" } }
        }
        for characteristic in service.characteristics ?? [] {
            guard let profile = StandardBLEProfile.allCases.first(where: {
                CBUUID(string: $0.service) == service.uuid && CBUUID(string: $0.characteristic) == characteristic.uuid
            }) else { continue }
            let supported = profile == .alert ? characteristic.properties.contains(.writeWithoutResponse) : characteristic.properties.contains(.read)
            if supported {
                let id = peripheral.identifier
                if characteristics[id]?[profile] != nil {
                    ambiguousProfiles[id, default: []].insert(profile)
                    characteristics[id]?[profile] = nil
                } else if !(ambiguousProfiles[id]?.contains(profile) ?? false) {
                    characteristics[id, default: [:]][profile] = characteristic
                }
            }
        }
        update(peripheral.identifier) { $0.profiles = StandardBLEProfile.allCases.filter { characteristics[peripheral.identifier]?[$0] != nil } }
        if (peripheral.services ?? []).allSatisfy({ $0.characteristics != nil }) {
            connectionTimers.removeValue(forKey: peripheral.identifier)?.cancel()
            update(peripheral.identifier) { $0.state = "已连接" }
        }
    }
    public func read(_ id: UUID, profile: StandardBLEProfile) async throws -> String {
        try Task.checkCancellation()
        guard profile != .alert, let device = devices.first(where: { $0.id == id }), device.allowRead else { throw BLEFailure("Enable device read access in Settings → Bluetooth devices") }
        guard pending == nil else { throw BLEFailure("Another Bluetooth read is running") }
        guard let peripheral = peripherals[id], peripheral.state == .connected,
              let characteristic = characteristics[id]?[profile] else { throw BLEFailure("Device disconnected or unsupported profile") }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (token, id, profile, continuation)
                operationTimer = Task {
                    try? await Task.sleep(for: .seconds(10)); guard !Task.isCancelled, pending?.token == token else { return }
                    finish(.failure(BLEFailure("Bluetooth read timed out"))); disconnect(id)
                }
                peripheral.readValue(for: characteristic)
            }
        } onCancel: {
            Task { @MainActor in
                guard self.pending?.token == token else { return }
                self.finish(.failure(CancellationError())); self.disconnect(id)
            }
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.service?.uuid == CBUUID(string: PDSHLink.service) {
            linkChannels[peripheral.identifier]?.receive(characteristic, error: error); return
        }
        guard let pending, pending.device == peripheral.identifier,
              characteristics[pending.device]?[pending.profile] === characteristic else { return }
        if let error { finish(.failure(error)); return }
        do {
            let value = try pending.profile.decode(characteristic.value ?? Data())
            let result = "\(value) \(pending.profile.unit) @ \(ISO8601DateFormatter().string(from: Date()))"
            update(pending.device) { $0.readings[pending.profile.rawValue] = result }
            finish(.success(result))
        } catch { finish(.failure(error)) }
    }
    private func finish(_ result: Result<String, Error>) {
        let continuation = pending?.continuation; pending = nil; operationTimer?.cancel(); operationTimer = nil
        continuation?.resume(with: result)
    }
    public func cancelRead() { if let id = pending?.device { finish(.failure(CancellationError())); disconnect(id) } }
    public func alert(_ id: UUID, level: Int) throws -> String {
        guard let device = devices.first(where: { $0.id == id }), device.allowAlert else { throw BLEFailure("Enable Immediate Alert access for this device in Settings") }
        guard let peripheral = peripherals[id], peripheral.state == .connected,
              let characteristic = characteristics[id]?[.alert], peripheral.canSendWriteWithoutResponse else { throw BLEFailure("Alert unavailable or Bluetooth busy") }
        peripheral.writeValue(try StandardBLEProfile.alertCommand(level: level), for: characteristic, type: .withoutResponse)
        return "submitted_unconfirmed: Immediate Alert has no application acknowledgement; inspect device before repeating."
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        linkChannels[peripheral.identifier]?.didWrite(characteristic, error: error)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard characteristic.service?.uuid == CBUUID(string: PDSHLink.service) else { return }
        guard error == nil else { status = error!.localizedDescription; disconnect(id); return }
        guard let channel = linkChannels[id], channel.tx.isNotifying, channel.audio.isNotifying, linkTasks[id] == nil else { return }
        linkTasks[id] = Task {
            do {
                let client = PDSHLinkClient(transport: channel, allowTaskProfile: deviceTaskDiscoveryEnabled), peer = try await client.handshake()
                guard !Task.isCancelled, linkChannels[id] === channel else { return }
                update(id) { $0.linkState = "Link \(peer.version >> 8).\(peer.version & 255) · boot \(peer.bootID)" }
                guard peer.supportsTools else { update(id) { $0.linkState += " · 旧固件，未协商工具扩展" }; return }
                try await discoverLinkTools(id, client: client, bootID: peer.bootID) { self.linkChannels[id] === channel }
            } catch { if !Task.isCancelled { status = error.localizedDescription; disconnect(id) } }
        }
    }

    /// Installs ordinary Link tools without invoking the draft task identity profile.
    func discoverLinkTools(_ id: UUID, client: PDSHLinkClient, bootID: UInt32,
                           isCurrent: () -> Bool) async throws {
        let list = try await client.invoke(requestID: UUID(), name: "tools/list", arguments: .object([:]), idempotencyKey: UUID().uuidString)
        guard case .object(let root) = list, root["status"] == .string("completed"),
              case .object(let result) = root["result"], case .string(let deviceID) = result["device_id"], UUID(uuidString: deviceID) != nil,
              result["boot_id"] == .number(Double(bootID)), case .array(let tools) = result["tools"], tools.count <= 32 else { throw BLEFailure("Invalid Link tools/list") }
        let names = try tools.map { tool -> String in
            guard case .object(let fields) = tool, case .string(let name) = fields["name"], !name.isEmpty,
                  name.utf8.count <= 64, name.utf8.allSatisfy({ (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else { throw BLEFailure("Invalid tool name") }
            return name
        }
        guard Set(names).count == names.count, !Task.isCancelled, isCurrent() else { throw BLEFailure("Duplicate tools or stale connection") }
        linkClients[id] = client; linkBootIDs[id] = bootID
        linkTaskTools[id] = Set(names.filter(Self.isReservedTaskTool))
        let ordinaryTools = tools.filter { !Self.isReservedTaskTool($0["name"]?.stringValue ?? "") }
        // GAP-16 remains open; advertised task tools are never invoked here.
        update(id) { $0.linkIdentity = deviceID.lowercased(); $0.linkTools = names.filter { !Self.isReservedTaskTool($0) }; $0.linkToolDescriptors = ordinaryTools; $0.supportsDeviceTasks = false; $0.taskIdentity = ""; $0.pendingIdentity = ""; $0.linkState += " · PDSH Tools v1" }
    }
    public func grantLinkTool(_ id: UUID, name: String, enabled: Bool) {
        guard !linkBusy.contains(id) else { status = "请等待当前设备操作结束，或断开连接"; return }
        // These are host control-plane operations, never model device skills.
        guard !Self.isReservedTaskTool(name) else { return }
        update(id) { if enabled && $0.linkTools.contains(name) { $0.grantedTools.insert(name) } else { $0.grantedTools.remove(name) } }
    }

    /// Sends a fresh nonce and verifies the device's signed identity proof.
    /// A verified identity the user has not confirmed yet is held as pending.
    private func proveIdentity(_ id: UUID, client: PDSHLinkClient) async throws {
        let nonce = try BLEIdentity.randomNonce()
        let reply = try await client.invoke(requestID: UUID(), name: "pdsh.identity.prove",
            arguments: .object(["nonce": .string(BLEIdentity.hexEncode([UInt8](nonce)))]),
            idempotencyKey: UUID().uuidString.lowercased())
        guard case .object(let root) = reply, root["status"] == .string("completed"),
              case .object(let result) = root["result"],
              case .string(let publicKey) = result["pubkey"],
              case .string(let signature) = result["signature"] else {
            throw BLEFailure("设备身份证明返回无效")
        }
        let identity = try BLEIdentity.verify(nonce: nonce, publicKeyHex: publicKey, signatureHex: signature)
        guard !Task.isCancelled else { return }
        if BLETrustedIdentities.contains(identity) {
            update(id) { $0.taskIdentity = identity; $0.pendingIdentity = ""; $0.supportsDeviceTasks = false }
        } else {
            update(id) { $0.taskIdentity = ""; $0.pendingIdentity = identity; $0.supportsDeviceTasks = false }
        }
    }

    /// The user confirms the fingerprint shown for a newly proven device (first use).
    public func trustPendingIdentity(_ id: UUID) {
        guard let device = devices.first(where: { $0.id == id }), !device.pendingIdentity.isEmpty,
              linkClients[id] != nil else {
            status = "请先连接设备并完成身份证明"
            return
        }
        let identity = device.pendingIdentity
        BLETrustedIdentities.insert(identity)
        update(id) { $0.taskIdentity = identity; $0.pendingIdentity = ""; $0.supportsDeviceTasks = false }
    }

    /// GAP-16 requires BLE task grants to remain unavailable until authenticated
    /// peer binding is specified and verified. Revocation remains available.
    public func grantDeviceTasks(_ id: UUID, enabled: Bool) throws {
        if enabled {
            update(id) { $0.allowDeviceTasks = false }
            throw BLEFailure("设备身份认证尚未完成验证，暂不能授权蓝牙设备派任务")
        }
        update(id) { $0.allowDeviceTasks = false }
        if linkBusy.contains(id) { disconnect(id) }
    }

    func invokeTaskLink(_ id: UUID, identity: String, requestID: UUID, name: String,
                        arguments: JSONValue, key: String, fresh: Bool) async throws -> JSONValue {
        let allowed: Set<String> = ["pdsh.task.next", "pdsh.task.accept", "pdsh.task.complete", "pdsh.task.fail"]
        guard allowed.contains(name), let device = devices.first(where: { $0.id == id }),
              device.allowDeviceTasks, !device.taskIdentity.isEmpty, device.taskIdentity == identity,
              linkTaskTools[id]?.contains(name) == true, let client = linkClients[id],
              !linkBusy.contains(id) else { throw BLEFailure("Device task grant or Link connection unavailable") }
        linkBusy.insert(id); defer { linkBusy.remove(id) }
        if fresh { return try await client.invoke(requestID: requestID, name: name, arguments: arguments, idempotencyKey: key) }
        guard let result = try await client.query(requestID: requestID) else { throw BLEFailure("Link operation still running") }
        return result
    }
    public func setHomeOrigins(_ id: UUID, text: String) {
        guard !linkBusy.contains(id) else { return }
        update(id) { $0.homeOrigins = text }
    }
    public func authorizeLink(_ id: UUID, name: String, arguments: JSONValue?) throws {
        guard !Self.isReservedTaskTool(name),
              let device = devices.first(where: { $0.id == id }), linkClients[id] != nil,
              device.grantedTools.contains(name), device.linkTools.contains(name) else { throw BLEFailure("Authorize this Link tool in Settings → Bluetooth devices") }
        if name == "home.http", let arguments {
            _ = try HomeHTTPPolicy.validate(arguments, allowedOrigins: HomeHTTPPolicy.origins(device.homeOrigins))
        }
    }
    public func invokeLink(_ id: UUID, requestID: UUID, name: String, arguments: JSONValue, key: String) async throws -> JSONValue {
        try authorizeLink(id, name: name, arguments: arguments)
        guard let client = linkClients[id], !linkBusy.contains(id) else { throw BLEFailure("Link is busy") }
        linkBusy.insert(id); defer { linkBusy.remove(id) }
        return try await client.invoke(requestID: requestID, name: name, arguments: arguments, idempotencyKey: key)
    }
    public func queryLink(_ id: UUID, requestID: UUID, name: String) async throws -> JSONValue? {
        try authorizeLink(id, name: name, arguments: nil)
        guard let client = linkClients[id], !linkBusy.contains(id) else { throw BLEFailure("Link is busy") }
        linkBusy.insert(id); defer { linkBusy.remove(id) }
        return try await client.query(requestID: requestID)
    }
    public func cancelLinkOperations() { for id in Array(linkBusy) { disconnect(id) } }

}

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
        public var identityError = ""
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
    @ObservationIgnored private var linkPhysicalEndpoints: [UUID: [String: AnyObject]] = [:]
    @ObservationIgnored private var linkChannels: [UUID: BLELinkChannel] = [:]
    @ObservationIgnored private var linkClients: [UUID: PDSHLinkClient] = [:]
    @ObservationIgnored private var deviceTaskDiscoveryEnabled = false
    @ObservationIgnored private var linkTaskTools: [UUID: Set<String>] = [:]
    @ObservationIgnored private var linkTasks: [UUID: Task<Void, Never>] = [:]
    private final class LinkOperation {
        let owner: Owner
        init(owner: Owner) { self.owner = owner }
    }
    @ObservationIgnored private var linkBusy: [UUID: LinkOperation] = [:]
    @ObservationIgnored private var scanRequested = false
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var characteristics: [UUID: [StandardBLEProfile: CBCharacteristic]] = [:]
    @ObservationIgnored private var ambiguousProfiles: [UUID: Set<StandardBLEProfile>] = [:]
    @ObservationIgnored private var connectionTimers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var scanTimer: Task<Void, Never>?
    @ObservationIgnored private var closingTimers: [UUID: Task<Void, Never>] = [:]
    private final class Owner {
        enum Phase: String { case idle, connecting, connected, closing, quarantined }
        var phase: Phase = .idle
        var submitted = false
        var wasConnected = false
        var peripheral: CBPeripheral?
        var physicalIdentity: AnyObject?
        var read = false, alert = false
        var readVersion = Revision(), alertVersion = Revision()
        var identityRevision = Revision()
        var channelRevision = Revision()
        var identityPendingRevision: Revision?
        var identityAttempt: Revision?
        var identityErrorRevision = Revision()
        var standardSubscribed = Set<StandardBLEProfile>()
        var standardSubscriptionUnknown = Set<StandardBLEProfile>()
    }
    private final class Revision {}
    private final class ReadClaim: @unchecked Sendable {
        enum Outcome { case cancelled, permission, timeout, unavailable, disconnected, value(Result<String, Error>) }
        private let lock = NSLock()
        private var outcome: Outcome?
        private var submitted = false
        func claim(_ proposed: Outcome) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard outcome == nil else { return false }
            outcome = proposed; return true
        }
        func reserve() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard outcome == nil else { return false }
            submitted = true; return true
        }
        func snapshot() -> (Outcome?, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (outcome, submitted)
        }
    }
    private final class PendingRead {
        let token = UUID()
        let device: UUID
        let profile: StandardBLEProfile
        let owner: Owner
        let claim: ReadClaim
        var continuation: CheckedContinuation<String, Error>?
        var timer: Task<Void, Never>?
        var timerCreated = false
        var timerCancelled = false
        init(device: UUID, profile: StandardBLEProfile, owner: Owner, claim: ReadClaim,
             continuation: CheckedContinuation<String, Error>) {
            self.device = device; self.profile = profile; self.owner = owner
            self.claim = claim; self.continuation = continuation
        }
    }
    @ObservationIgnored private var owners: [UUID: Owner] = [:]
    @ObservationIgnored private var submittedDevices: Set<UUID> = []
    @ObservationIgnored private var pending: PendingRead?

    #if DEBUG
    enum TestCommand: Equatable {
        case connect(UUID), disconnect(UUID), read(UUID, StandardBLEProfile), alert(UUID, Int)
        case discoverServices(UUID), discoverCharacteristics(UUID), link(UUID), notify(UUID), other(UUID), scan, stopScan
    }
    final class TestAdapter {
        var poweredOn = true
        var commands: [TestCommand] = []
        var beforeConnect: ((UUID) -> Void)?
        var beforeReadReserve: (() -> Void)?
        var afterReadReserve: (() -> Void)?
        var afterReadOutcomeClaim: (() -> Void)?
        var afterNotify: ((UUID) -> Void)?
        var notifyEndpoints: [ObjectIdentifier] = []
        var profiles: [UUID: Set<StandardBLEProfile>] = [:]
        var validPeers: [UUID: NSObject] = [:]
        var profileEndpoints: [UUID: [StandardBLEProfile: NSObject]] = [:]
        var identityDefaults: UserDefaults?
    }
    @ObservationIgnored private var testAdapter: TestAdapter?
    init(testAdapter: TestAdapter, testDevices: [Device]) {
        self.testAdapter = testAdapter; self.devices = testDevices
        testAdapter.validPeers = Dictionary(uniqueKeysWithValues: testDevices.map { ($0.id, NSObject()) }); super.init()
    }
    #endif

    private var poweredOn: Bool {
        #if DEBUG
        if let testAdapter { return testAdapter.poweredOn }
        #endif
        return central?.state == .poweredOn
    }
    private func owner(_ id: UUID) -> Owner {
        if let value = owners[id] { return value }
        let value = Owner(); owners[id] = value; return value
    }

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
        #if DEBUG
        if let testAdapter {
            guard testAdapter.poweredOn else { return }
            testAdapter.commands.append(.scan); scanning = true; return
        }
        #endif
        if central == nil { scanRequested = true; status = "正在初始化蓝牙"; central = CBCentralManager(delegate: self, queue: .main); return }
        guard central?.state == .poweredOn else { status = "请在系统设置中开启蓝牙并授权"; return }
        // Foreground, bounded scan. Unadvertised services are discovered after user selection.
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true; status = "正在扫描（15 秒）"
        scanTimer?.cancel()
        scanTimer = Task { try? await Task.sleep(for: .seconds(15)); guard !Task.isCancelled else { return }; stopScan() }
    }
    public func stopScan() {
        scanRequested = false; scanTimer?.cancel(); scanTimer = nil
        #if DEBUG
        if let testAdapter { if testAdapter.poweredOn { testAdapter.commands.append(.stopScan) }; scanning = false; return }
        #endif
        if poweredOn { central?.stopScan() }
        scanning = false
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { managerUnavailable(reset: true); return }
        centralStateChanged(central.state)
    }
    private func centralStateChanged(_ state: CBManagerState) {
        if state == .poweredOn {
            status = "蓝牙已就绪，请点击扫描"
            if scanRequested { scanRequested = false; scan() }
        } else {
            let invalidatesPeers: Bool
            switch state {
            case .unknown, .resetting, .unsupported, .unauthorized: invalidatesPeers = true
            case .poweredOff, .poweredOn: invalidatesPeers = false
            @unknown default: invalidatesPeers = true
            }
            #if DEBUG
            if invalidatesPeers { testAdapter?.validPeers.removeAll(); testAdapter?.profiles.removeAll(); testAdapter?.profileEndpoints.removeAll() }
            #endif
            managerUnavailable(reset: invalidatesPeers)
            status = "蓝牙不可用，状态：\(state.rawValue)"
        }
    }
    private func recordDiscovery(_ id: UUID, physical: AnyObject, name: String, rssi: Int) {
        guard peripherals[id] != nil || devices.contains(where: { $0.id == id }) || devices.count < 100 else { return }
        #if DEBUG
        if let testAdapter, let peer = physical as? NSObject { testAdapter.validPeers[id] = peer }
        else if let peripheral = physical as? CBPeripheral { peripherals[id] = peripheral }
        #else
        if let peripheral = physical as? CBPeripheral { peripherals[id] = peripheral }
        #endif
        if devices.contains(where: { $0.id == id }) {
            update(id) { $0.rssi = rssi; $0.name = name }
        } else {
            withMutation(keyPath: \.devices) {
                guard !_devices.contains(where: { $0.id == id }), _devices.count < 100 else { return }
                _devices.append(Device(id: id, name: name, rssi: rssi))
            }
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central, poweredOn else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName.flatMap { $0.isEmpty ? nil : $0 } ?? peripheral.name ?? "未命名 BLE 设备"
        recordDiscovery(peripheral.identifier, physical: peripheral, name: name, rssi: RSSI.intValue)
    }
    public func connect(_ id: UUID) {
        guard poweredOn, devices.contains(where: { $0.id == id }) else { return }
        let old = owner(id)
        guard old.phase == .idle else { return }
        #if DEBUG
        let testing = testAdapter?.validPeers[id] != nil
        #else
        let testing = false
        #endif
        let peripheral = peripherals[id]
        guard testing || (peripheral != nil && peripheral?.state == .disconnected) else { return }
        let current = Owner(); current.phase = .connecting; current.peripheral = peripheral
        #if DEBUG
        testAdapter?.profiles[id] = nil; testAdapter?.profileEndpoints[id] = nil
        current.physicalIdentity = testAdapter?.validPeers[id] ?? peripheral
        #else
        current.physicalIdentity = peripheral
        #endif
        owners[id] = current
        let initialErrorRevision = current.identityErrorRevision
        update(id) {
            guard self.owners[id] === current, current.phase == .connecting else { return }
            $0.allowRead = current.read; $0.allowAlert = current.alert; $0.state = "连接中"
            if current.identityErrorRevision === initialErrorRevision { $0.identityError = "" }
        }
        guard owners[id] === current, current.phase == .connecting, poweredOn else { return }
        stopScan()
        guard owners[id] === current, current.phase == .connecting, poweredOn else { return }
        #if DEBUG
        testAdapter?.beforeConnect?(id)
        #endif
        guard owners[id] === current, current.phase == .connecting, poweredOn else { return }
        current.submitted = true
        submittedDevices.insert(id)
        connectionTimers[id] = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            connectionTimedOut(id, current: current)
        }
        #if DEBUG
        if let testAdapter { testAdapter.commands.append(.connect(id)); return }
        #endif
        guard let peripheral else { return }
        peripheral.delegate = self
        central?.connect(peripheral, options: nil)
    }
    private func connectionTimedOut(_ id: UUID, current: Owner) {
        guard owners[id] === current, current.phase == .connecting || current.phase == .connected else { return }
        status = "连接或服务发现超时"
        guard owners[id] === current, current.phase == .connecting || current.phase == .connected else { return }
        disconnect(id)
    }
    public func disconnect(_ id: UUID) {
        guard let current = owners[id], current.phase != .idle else { return }
        close(id, current: current, outcome: .disconnected, quarantine: current.phase == .connecting)
    }
    public func grant(_ id: UUID, read: Bool? = nil, alert: Bool? = nil) {
        guard devices.contains(where: { $0.id == id }) else { return }
        let current = owner(id)
        if let pending, pending.device == id, pending.owner === current {
            close(id, current: current, outcome: .permission, quarantine: current.phase == .connecting)
            return
        }
        if current.phase == .closing || current.phase == .quarantined {
            // Positive declarations cannot reopen an unavailable owner.
            return
        }
        guard read != nil || alert != nil else { return }
        let readRevision = Revision(), alertRevision = Revision()
        if read != nil { current.readVersion = readRevision; current.read = false }
        if alert != nil { current.alertVersion = alertRevision; current.alert = false }
        withMutation(keyPath: \.devices) {
            guard self.owners[id] === current,
                  current.phase != .closing, current.phase != .quarantined,
                  let index = _devices.firstIndex(where: { $0.id == id }) else { return }
            if let read, current.readVersion === readRevision {
                current.read = read; _devices[index].allowRead = read
            }
            if let alert, current.alertVersion === alertRevision {
                current.alert = alert; _devices[index].allowAlert = alert
            }
        }
    }
    private func update(_ id: UUID, _ body: (inout Device) -> Void) {
        guard devices.contains(where: { $0.id == id }) else { return }
        withMutation(keyPath: \.devices) {
            guard let index = _devices.firstIndex(where: { $0.id == id }) else { return }
            body(&_devices[index])
        }
    }
    private func finishRead(_ read: PendingRead) {
        guard pending === read, let outcome = read.claim.snapshot().0 else { return }
        pending = nil
        if let timer = read.timer { timer.cancel(); read.timerCancelled = true; read.timer = nil }
        let continuation = read.continuation; read.continuation = nil
        switch outcome {
        case .cancelled: continuation?.resume(throwing: CancellationError())
        case .permission: continuation?.resume(throwing: BLEFailure("Device permissions changed"))
        case .timeout: continuation?.resume(throwing: BLEFailure("Bluetooth read timed out"))
        case .unavailable: continuation?.resume(throwing: BLEFailure("Bluetooth unavailable"))
        case .disconnected: continuation?.resume(throwing: BLEFailure("Device disconnected"))
        case .value(let result): continuation?.resume(with: result)
        }
    }

    private func close(_ id: UUID, current: Owner, outcome: ReadClaim.Outcome,
                       quarantine: Bool, sendDisconnect: Bool = true, forceQuarantine: Bool = false) {
        guard owners[id] === current else { return }
        if current.phase == .closing || current.phase == .quarantined { return }
        let unsent = current.phase == .connecting && !current.submitted && !forceQuarantine
        let connection = current.peripheral
        current.phase = unsent ? .idle : (quarantine || !current.wasConnected || !poweredOn ? .quarantined : .closing)
        current.read = false; current.alert = false
        current.readVersion = Revision(); current.alertVersion = Revision()
        invalidateIdentity(current)
        let errorRevision = current.identityErrorRevision
        let oldRead = pending.flatMap { $0.device == id && $0.owner === current ? $0 : nil }
        if let oldRead, oldRead.claim.claim(outcome) {
            #if DEBUG
            testAdapter?.afterReadOutcomeClaim?()
            #endif
        }
        if linkBusy[id]?.owner === current { linkBusy[id] = nil }
        let task = linkTasks.removeValue(forKey: id)
        let channel = linkChannels.removeValue(forKey: id)
        linkClients[id] = nil; linkTaskTools[id] = nil; linkCharacteristics[id] = nil; linkPhysicalEndpoints[id] = nil
        linkBootIDs[id] = nil; linkEventSequences[id] = nil
        let timer = connectionTimers.removeValue(forKey: id)
        characteristics[id] = nil; ambiguousProfiles[id] = nil
        task?.cancel(); timer?.cancel()
        channel?.fail(BLEFailure("Link disconnected; outcome_unknown"))
        if let oldRead { finishRead(oldRead) }
        if current.phase == .closing {
            closingTimers[id]?.cancel()
            closingTimers[id] = Task {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                closingTimedOut(id, current: current)
            }
        }
        if !unsent, sendDisconnect, poweredOn {
            #if DEBUG
            if let testAdapter { testAdapter.commands.append(.disconnect(id)) }
            else if let connection { central?.cancelPeripheralConnection(connection) }
            #else
            if let connection { central?.cancelPeripheralConnection(connection) }
            #endif
        }
        update(id) {
            guard self.owners[id] === current else { return }
            $0.state = self.phaseLabel(current.phase)
            $0.linkState = "未连接"; $0.linkIdentity = ""; $0.linkTools = []; $0.linkToolDescriptors = []
            $0.allowDeviceTasks = false; $0.supportsDeviceTasks = false; $0.taskIdentity = ""; $0.pendingIdentity = ""; if current.identityErrorRevision === errorRevision { $0.identityError = "" }
            $0.grantedTools = []; $0.homeOrigins = ""; $0.events = []; $0.profiles = []; $0.readings = [:]
            $0.allowRead = current.read; $0.allowAlert = current.alert
        }
    }

    private func closingTimedOut(_ id: UUID, current: Owner) {
        guard owners[id] === current, current.phase == .closing else { return }
        current.phase = .quarantined
        closingTimers.removeValue(forKey: id)?.cancel()
        update(id) {
            guard self.owners[id] === current, current.phase == .quarantined else { return }
            $0.state = self.phaseLabel(.quarantined)
        }
    }

    private func phaseLabel(_ phase: Owner.Phase) -> String {
        switch phase {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .closing: return "正在等待系统断开，暂不可重连"
        case .quarantined: return "连接状态无法确认，暂不可用"
        }
    }

    private func managerUnavailable(reset: Bool) {
        scanRequested = false; scanTimer?.cancel(); scanTimer = nil
        // Invalidate every owner before the first observer can reenter.
        let snapshot = Array(owners)
        var tasks: [Task<Void, Never>] = [], channels: [BLELinkChannel] = []
        var errorRevisions: [UUID: Revision] = [:]
        for (id, current) in snapshot {
            let neverSubmitted = current.phase == .idle && !submittedDevices.contains(id)
            current.phase = neverSubmitted ? .idle : .quarantined
            current.read = false; current.alert = false
            current.readVersion = Revision(); current.alertVersion = Revision()
            invalidateIdentity(current)
            errorRevisions[id] = current.identityErrorRevision
            if linkBusy[id]?.owner === current { linkBusy[id] = nil }
            if let task = linkTasks.removeValue(forKey: id) { tasks.append(task) }
            if let task = connectionTimers.removeValue(forKey: id) { tasks.append(task) }
            if let task = closingTimers.removeValue(forKey: id) { tasks.append(task) }
            if let channel = linkChannels.removeValue(forKey: id) { channels.append(channel) }
            linkClients[id] = nil; linkTaskTools[id] = nil; linkCharacteristics[id] = nil; linkPhysicalEndpoints[id] = nil
            linkBootIDs[id] = nil; linkEventSequences[id] = nil
            characteristics[id] = nil; ambiguousProfiles[id] = nil
        }
        if reset { peripherals.removeAll() }
        if let read = pending { _ = read.claim.claim(.unavailable); finishRead(read) }
        tasks.forEach { $0.cancel() }
        channels.forEach { $0.fail(BLEFailure("Bluetooth unavailable")) }
        for (id, current) in snapshot {
            update(id) {
                guard self.owners[id] === current else { return }
                $0.allowRead = current.read; $0.allowAlert = current.alert; $0.state = self.phaseLabel(current.phase)
                $0.allowDeviceTasks = false; $0.supportsDeviceTasks = false
                $0.linkIdentity = ""; $0.linkState = "未连接"; $0.linkTools = []; $0.linkToolDescriptors = []
                $0.taskIdentity = ""; $0.pendingIdentity = ""; if current.identityErrorRevision === errorRevisions[id] { $0.identityError = "" }; $0.grantedTools = []; $0.homeOrigins = ""
                $0.events = []; $0.profiles = []; $0.readings = [:]
            }
        }
        scanning = false
    }
    private func quarantineUnexpected(_ id: UUID, current: Owner, sendDisconnect: Bool) {
        guard owners[id] === current else { return }
        if current.phase == .closing {
            current.phase = .quarantined
            closingTimers.removeValue(forKey: id)?.cancel()
            if sendDisconnect, poweredOn {
                #if DEBUG
                if let testAdapter { testAdapter.commands.append(.disconnect(id)) }
                else if let peripheral = current.peripheral { central?.cancelPeripheralConnection(peripheral) }
                #else
                if let peripheral = current.peripheral { central?.cancelPeripheralConnection(peripheral) }
                #endif
            }
            update(id) {
                guard self.owners[id] === current, current.phase == .quarantined else { return }
                $0.state = self.phaseLabel(.quarantined)
            }
        } else if current.phase != .quarantined {
            close(id, current: current, outcome: .disconnected, quarantine: true, sendDisconnect: sendDisconnect, forceQuarantine: true)
        }
    }
    private func acceptDelegatePeer(_ id: UUID, physical: AnyObject) -> Owner? {
        guard poweredOn, let current = owners[id] else { return nil }
        guard current.physicalIdentity === physical else {
            quarantineUnexpected(id, current: current, sendDisconnect: current.submitted && current.phase != .closing)
            return nil
        }
        return current
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central else { managerUnavailable(reset: true); return }
        guard acceptDelegatePeer(peripheral.identifier, physical: peripheral) != nil else { return }
        connected(peripheral.identifier, peripheral: peripheral)
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.central === central else { managerUnavailable(reset: true); return }
        guard acceptDelegatePeer(peripheral.identifier, physical: peripheral) != nil else { return }
        failedConnect(peripheral.identifier)
        status = error?.localizedDescription ?? "连接失败"
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central else { managerUnavailable(reset: true); return }
        let id = peripheral.identifier
        guard let current = acceptDelegatePeer(id, physical: peripheral) else { return }
        disconnectCallback(id, current: current)
        scheduleDisconnectBoundary(id, current: current)
    }

    private func connected(_ id: UUID, peripheral: CBPeripheral?) {
        guard poweredOn, let current = owners[id] else { return }
        if current.phase == .quarantined {
            if current.submitted {
                #if DEBUG
                if let testAdapter { testAdapter.commands.append(.disconnect(id)) }
                else if let peripheral { central?.cancelPeripheralConnection(peripheral) }
                #else
                if let peripheral { central?.cancelPeripheralConnection(peripheral) }
                #endif
            }
            return
        }
        guard current.phase == .connecting, current.submitted,
              current.peripheral === peripheral else {
            quarantineUnexpected(id, current: current, sendDisconnect: true)
            return
        }
        current.phase = .connected; current.wasConnected = true
        update(id) {
            guard self.owners[id] === current, current.phase == .connected else { return }
            $0.state = "已连接"
        }
        guard owners[id] === current, current.phase == .connected, poweredOn else { return }
        submitConnected(id, current: current, action: .discoverServices) {
            peripheral?.discoverServices((Array(Set(StandardBLEProfile.allCases.map(\.service))) + [PDSHLink.service]).map { CBUUID(string: $0) })
        }
    }

    private func failedConnect(_ id: UUID) {
        guard let current = owners[id] else { return }
        if current.phase == .connecting && current.submitted {
            close(id, current: current, outcome: .disconnected, quarantine: true, sendDisconnect: false)
        } else if current.phase != .quarantined {
            quarantineUnexpected(id, current: current, sendDisconnect: current.phase == .connected)
        }
    }

    private func disconnectCallback(_ id: UUID, current: Owner) {
        guard owners[id] === current else { return }
        if current.phase == .connected, current.wasConnected {
            close(id, current: current, outcome: .disconnected, quarantine: false, sendDisconnect: false)
        } else if current.phase != .closing && current.phase != .quarantined {
            close(id, current: current, outcome: .disconnected, quarantine: true, sendDisconnect: false)
        }
    }

    private func scheduleDisconnectBoundary(_ id: UUID, current: Owner) {
        Task { @MainActor in self.finishDisconnectBoundary(id, current: current) }
    }
    private func finishDisconnectBoundary(_ id: UUID, current: Owner) {
        guard owners[id] === current, current.phase == .closing, current.wasConnected, poweredOn else { return }
        closingTimers.removeValue(forKey: id)?.cancel()
        current.phase = .idle; current.submitted = false
        update(id) {
            guard self.owners[id] === current, current.phase == .idle else { return }
            $0.state = "未连接"
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        guard let current = acceptDelegatePeer(id, physical: peripheral), current.phase == .connected else { return }
        guard error == nil else { status = error!.localizedDescription; disconnect(peripheral.identifier); return }
        let services = peripheral.services ?? []
        if services.isEmpty { connectionTimers.removeValue(forKey: peripheral.identifier)?.cancel(); update(peripheral.identifier) { guard self.owners[id] === current, current.phase == .connected else { return }; $0.state = "无支持的标准服务" } }
        for service in services {
            guard poweredOn, owners[id] === current, current.phase == .connected else { return }
            if service.uuid == CBUUID(string: PDSHLink.service) {
                update(peripheral.identifier) { guard self.owners[id] === current, current.phase == .connected else { return }; $0.linkState = "发现 Link 特征中" }
                guard poweredOn, owners[id] === current, current.phase == .connected else { return }
                submitConnected(id, current: current, action: .discoverCharacteristics) {
                    peripheral.discoverCharacteristics([PDSHLink.rx, PDSHLink.tx, PDSHLink.audioUp].map { CBUUID(string: $0) }, for: service)
                }
                continue
            }
            let ids = StandardBLEProfile.allCases.filter { CBUUID(string: $0.service) == service.uuid }.map { CBUUID(string: $0.characteristic) }
            submitConnected(id, current: current, action: .discoverCharacteristics) { peripheral.discoverCharacteristics(ids, for: service) }
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        guard let current = acceptDelegatePeer(id, physical: peripheral), current.phase == .connected else { return }
        guard error == nil else { status = error!.localizedDescription; disconnect(peripheral.identifier); return }
        if service.uuid == CBUUID(string: PDSHLink.service) {
            let id = peripheral.identifier
            var found: [String: CBCharacteristic] = [:]
            for c in service.characteristics ?? [] { found[c.uuid.uuidString.lowercased()] = c }
            linkCharacteristics[id] = found
            recordLinkPhysicalEndpoints(id, current: current, endpoints: found.mapValues { $0 as AnyObject })
            if let rx = found[PDSHLink.rx], let tx = found[PDSHLink.tx], let audio = found[PDSHLink.audioUp],
               rx.properties.contains(.write), tx.properties.contains(.notify), audio.properties.contains(.notify) {
                let channel = BLELinkChannel(peripheral: peripheral, rx: rx, tx: tx, audio: audio)
                guard installAndSubscribeLink(id, current: current, channel: channel, txEndpoint: tx, audioEndpoint: audio,
                          notifyTX: { peripheral.setNotifyValue(true, for: tx) },
                          notifyAudio: { peripheral.setNotifyValue(true, for: audio) }) else { return }
            } else { update(id) { guard self.owners[id] === current, current.phase == .connected else { return }; $0.linkState = "Link 特征不完整" } }
        }
        guard poweredOn, owners[id] === current, current.phase == .connected else { return }
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
        update(peripheral.identifier) { guard self.owners[id] === current, current.phase == .connected else { return }; $0.profiles = StandardBLEProfile.allCases.filter { characteristics[peripheral.identifier]?[$0] != nil } }
        guard poweredOn, owners[id] === current, current.phase == .connected else { return }
        if (peripheral.services ?? []).allSatisfy({ $0.characteristics != nil }) {
            connectionTimers.removeValue(forKey: peripheral.identifier)?.cancel()
            update(peripheral.identifier) { guard self.owners[id] === current, current.phase == .connected else { return }; $0.state = "已连接" }
        }
    }
    private func invalidateIdentity(_ current: Owner) {
        current.identityRevision = Revision()
        current.identityPendingRevision = nil
        current.identityAttempt = nil
        current.identityErrorRevision = Revision()
    }
    @discardableResult private func installIdentityChannel(_ id: UUID, current: Owner, channel: BLELinkChannel) -> Revision? {
        guard poweredOn, owners[id] === current, current.phase == .connected else { return nil }
        let installation = Revision(); current.channelRevision = installation
        channel.onFailure = { [weak self, weak current, weak channel] in
            guard let self, let current, let channel,
                  self.isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return }
            self.disconnect(id)
        }
        channel.onEvent = { [weak self, weak current, weak channel] data in
            guard let self, let current, let channel,
                  self.isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return }
            self.handleLinkEvent(id, current: current, data: data)
        }
        invalidateIdentity(current)
        let revision = current.identityRevision, errorRevision = current.identityErrorRevision
        let oldChannel = linkChannels.updateValue(channel, forKey: id)
        let oldTask = linkTasks.removeValue(forKey: id)
        linkClients[id] = nil; linkTaskTools[id] = nil; linkBootIDs[id] = nil; linkEventSequences[id] = nil
        if linkBusy[id]?.owner === current { linkBusy[id] = nil }
        oldTask?.cancel()
        if oldChannel !== channel { oldChannel?.fail(BLEFailure("Link replaced; outcome_unknown")) }
        update(id) {
            guard self.owners[id] === current, current.phase == .connected,
                  current.identityRevision === revision, self.linkChannels[id] === channel else { return }
            $0.pendingIdentity = ""; $0.taskIdentity = ""; $0.supportsDeviceTasks = false; $0.allowDeviceTasks = false
            if current.identityErrorRevision === errorRevision { $0.identityError = "" }
        }
        return installation
    }
    private func isCurrentChannelInstallation(_ id: UUID, current: Owner, channel: BLELinkChannel, installation: Revision) -> Bool {
        poweredOn && owners[id] === current && current.phase == .connected &&
        current.channelRevision === installation && linkChannels[id] === channel
    }
    @discardableResult private func installAndSubscribeLink(_ id: UUID, current: Owner, channel: BLELinkChannel,
                                                             txEndpoint: AnyObject, audioEndpoint: AnyObject,
                                                             notifyTX: () -> Void, notifyAudio: () -> Void) -> Bool {
        guard let installation = installIdentityChannel(id, current: current, channel: channel),
              isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return false }
        submitConnected(id, current: current, action: .notify, endpoint: txEndpoint, physical: notifyTX)
        guard isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return false }
        submitConnected(id, current: current, action: .notify, endpoint: audioEndpoint, physical: notifyAudio)
        guard isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return false }
        update(id) {
            guard self.isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return }
            $0.linkState = "等待加密、绑定与订阅"
        }
        return isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation)
    }
    private func installIdentityClient(_ id: UUID, current: Owner, client: PDSHLinkClient,
                                       isCurrent: () -> Bool, publish: (inout Device) -> Void) {
        guard poweredOn, owners[id] === current, current.phase == .connected, isCurrent() else { return }
        invalidateIdentity(current)
        let revision = current.identityRevision, errorRevision = current.identityErrorRevision
        let channel = linkChannels[id]
        linkClients[id] = client
        update(id) {
            guard self.owners[id] === current, current.phase == .connected,
                  current.identityRevision === revision, self.linkChannels[id] === channel,
                  self.linkClients[id] === client, isCurrent() else { return }
            $0.pendingIdentity = ""; $0.taskIdentity = ""; $0.supportsDeviceTasks = false; $0.allowDeviceTasks = false
            if current.identityErrorRevision === errorRevision { $0.identityError = "" }
            publish(&$0)
        }
    }
    private func recordLinkPhysicalEndpoints(_ id: UUID, current: Owner, endpoints: [String: AnyObject]) {
        guard poweredOn, owners[id] === current, current.phase == .connected else { return }
        linkPhysicalEndpoints[id] = endpoints
    }
    private func handleLinkEvent(_ id: UUID, current: Owner, data: Data) {
        guard poweredOn, owners[id] === current, current.phase == .connected,
              let bootID = linkBootIDs[id], let device = devices.first(where: { $0.id == id }),
              let event = try? PDSHLinkEvent(data: data, expectedBootID: bootID, expectedDeviceID: device.linkIdentity),
              event.sequence > (linkEventSequences[id] ?? 0), let text = String(data: data, encoding: .utf8) else { return }
        linkEventSequences[id] = event.sequence
        update(id) {
            guard self.owners[id] === current, current.phase == .connected else { return }
            $0.events.append(text); if $0.events.count > 32 { $0.events.removeFirst() }
        }
    }
    private enum ConnectedAction { case discoverServices, discoverCharacteristics, notify, link }
    @discardableResult private func submitConnected(_ id: UUID, current: Owner?, action: ConnectedAction,
                                                      endpoint: AnyObject? = nil, physical: () -> Void) -> Bool {
        guard poweredOn, let current, owners[id] === current, current.phase == .connected else { return false }
        #if DEBUG
        if let testAdapter {
            switch action {
            case .discoverServices: testAdapter.commands.append(.discoverServices(id))
            case .discoverCharacteristics: testAdapter.commands.append(.discoverCharacteristics(id))
            case .notify:
                testAdapter.commands.append(.notify(id))
                if let endpoint { testAdapter.notifyEndpoints.append(ObjectIdentifier(endpoint)) }
                testAdapter.afterNotify?(id)
            case .link: testAdapter.commands.append(.link(id))
            }
            return true
        }
        #endif
        physical(); return true
    }

    #if DEBUG
    final class TestTimerProbe {
        private let getState: () -> String
        private let fire: () -> Void
        init(state: @escaping () -> String, fire: @escaping () -> Void) {
            self.getState = state; self.fire = fire
        }
        var state: String { getState() }
        func invoke() { fire() }
    }
    func testDidConnect(_ id: UUID) {
        guard let peer = testAdapter?.validPeers[id], acceptDelegatePeer(id, physical: peer) != nil else { return }
        connected(id, peripheral: nil)
    }
    func testDidFail(_ id: UUID) {
        guard let peer = testAdapter?.validPeers[id], acceptDelegatePeer(id, physical: peer) != nil else { return }
        failedConnect(id)
    }
    func testDidDisconnect(_ id: UUID, during: (() -> Void)? = nil) {
        guard let peer = testAdapter?.validPeers[id], let current = acceptDelegatePeer(id, physical: peer) else { return }
        disconnectCallback(id, current: current)
        during?()
        scheduleDisconnectBoundary(id, current: current)
    }
    func testDiscover(_ id: UUID, profiles: Set<StandardBLEProfile>) {
        guard let testAdapter, poweredOn, let current = owners[id], current.phase == .connected else { return }
        testAdapter.profiles[id] = profiles
        testAdapter.profileEndpoints[id] = Dictionary(uniqueKeysWithValues: profiles.map { ($0, NSObject()) })
        connectionTimers.removeValue(forKey: id)?.cancel()
        update(id) {
            guard self.owners[id] === current, current.phase == .connected else { return }
            $0.profiles = StandardBLEProfile.allCases.filter { profiles.contains($0) }
        }
    }
    func testValue(_ id: UUID, profile: StandardBLEProfile?, data: Data, error: Error? = nil) {
        guard let peer = testAdapter?.validPeers[id], acceptDelegatePeer(id, physical: peer) != nil else { return }
        let source: ValueSource
        if let profile, testAdapter?.profiles[id]?.contains(profile) == true { source = .standard(profile, data, false) }
        else { source = .unknown }
        dispatchValue(id, source: source, error: error)
    }
    func testUnassignablePeer(_ id: UUID) {
        guard testAdapter != nil else { return }
        _ = acceptDelegatePeer(id, physical: NSObject())
    }
    func testRadioUnavailable(reset: Bool) { testManagerState(reset ? .resetting : .poweredOff) }
    func testManagerState(_ state: CBManagerState) {
        guard let testAdapter else { return }
        testAdapter.poweredOn = state == .poweredOn
        centralStateChanged(state)
    }
    func testRadioOn() { testManagerState(.poweredOn) }
    func testRediscover(_ id: UUID) {
        guard testAdapter != nil, poweredOn, let device = devices.first(where: { $0.id == id }) else { return }
        recordDiscovery(id, physical: NSObject(), name: device.name, rssi: device.rssi)
    }
    func testPhase(_ id: UUID) -> String { owner(id).phase.rawValue }
    func testDeclarations(_ id: UUID) -> (read: Bool, alert: Bool) { let value = owner(id); return (value.read, value.alert) }
    func testOwner(_ id: UUID) -> ObjectIdentifier? { owners[id].map(ObjectIdentifier.init) }
    func testPending(_ id: UUID) -> Bool { pending?.device == id }
    func testPendingToken(_ id: UUID) -> ObjectIdentifier? {
        guard let pending, pending.device == id else { return nil }
        return ObjectIdentifier(pending)
    }
    func testReadAdmission(_ id: UUID, profile: StandardBLEProfile) throws { _ = try readAdmission(id, profile: profile) }
    func testInstallPending(_ id: UUID, profile: StandardBLEProfile, continuation: CheckedContinuation<String, Error>) throws {
        let current = try readAdmission(id, profile: profile)
        beginRead(id, profile: profile, current: current, claim: ReadClaim(), continuation: continuation)
    }
    func testCaptureReadTimeout() -> TestTimerProbe? {
        guard let read = pending, read.timerCreated else { return nil }
        return TestTimerProbe(state: { read.timerCancelled ? "cancelled" : "active" },
                              fire: { [weak self] in self?.timeoutRead(read) })
    }
    func testCaptureClosingTimeout(_ id: UUID) -> TestTimerProbe? {
        guard let current = owners[id], current.phase == .closing, closingTimers[id] != nil else { return nil }
        return TestTimerProbe(state: { [weak self] in self?.closingTimers[id] == nil ? "cancelled" : "active" },
                              fire: { [weak self] in self?.closingTimedOut(id, current: current) })
    }
    func testCaptureConnectionTimeout(_ id: UUID) -> TestTimerProbe? {
        guard let current = owners[id], connectionTimers[id] != nil else { return nil }
        return TestTimerProbe(state: { [weak self] in self?.owners[id] === current && self?.connectionTimers[id] != nil ? "active" : "cancelled" },
                              fire: { [weak self] in self?.connectionTimedOut(id, current: current) })
    }
    func testSubscription(_ id: UUID, profile: StandardBLEProfile, state: String) {
        testNotification(id, profile: profile, matchingPeer: true, notifying: state == "subscribed")
    }
    func testNotification(_ id: UUID, profile: StandardBLEProfile?, matchingPeer: Bool = true,
                          notifying: Bool, error: Error? = nil) {
        guard let adapter = testAdapter, let knownPeer = adapter.validPeers[id] else { return }
        let peer = matchingPeer ? knownPeer : NSObject()
        let endpoint = profile.flatMap { adapter.profileEndpoints[id]?[$0] } ?? NSObject()
        let source = notificationSource(id, characteristic: endpoint, notifying: notifying)
        dispatchNotification(id, physical: peer, source: source, error: error)
    }
    func testDiscoverIncompleteLink(_ id: UUID) {
        guard testAdapter != nil, let current = owners[id], current.phase == .connected,
              linkChannels[id] == nil else { return }
        recordLinkPhysicalEndpoints(id, current: current, endpoints: [PDSHLink.tx: NSObject()])
    }
    @discardableResult func testIncompleteLinkNotification(_ id: UUID) -> Bool {
        guard let peer = testAdapter?.validPeers[id], let endpoint = linkPhysicalEndpoints[id]?[PDSHLink.tx] else { return false }
        let source = notificationSource(id, characteristic: endpoint, notifying: true)
        dispatchNotification(id, physical: peer, source: source, error: nil)
        return true
    }
    func testUnrelatedUpdate(_ id: UUID) { update(id) { $0.name += "!" } }
    func testAttemptDiscovery(_ id: UUID) {
        guard testAdapter != nil else { return }
        submitConnected(id, current: owners[id], action: .discoverCharacteristics) {}
    }
    func testAttemptLink(_ id: UUID) {
        guard testAdapter != nil else { return }
        submitConnected(id, current: owners[id], action: .link) {}
    }
    func testAttemptNotify(_ id: UUID) {
        guard testAdapter != nil else { return }
        submitConnected(id, current: owners[id], action: .notify) {}
    }
    func testPrepareLink(_ id: UUID, bootID: UInt32, deviceID: String) {
        guard testAdapter != nil, poweredOn, let current = owners[id], current.phase == .connected else { return }
        let channel = BLELinkChannel(testing: ())
        guard let installation = installIdentityChannel(id, current: current, channel: channel),
              isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return }
        linkBootIDs[id] = bootID
        update(id) {
            guard self.isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return }
            $0.linkIdentity = deviceID.lowercased()
        }
    }
    func testLinkEvent(_ id: UUID, segment: Data) {
        guard let peer = testAdapter?.validPeers[id], acceptDelegatePeer(id, physical: peer) != nil else { return }
        dispatchValue(id, source: .linkTX(segment), error: nil)
    }
    func testLinkDeliveries(_ id: UUID) -> Int { devices.first(where: { $0.id == id })?.events.count ?? 0 }
    @discardableResult func testDiscoverIdentityChannelAndNotify(_ id: UUID) -> (tx: ObjectIdentifier, audio: ObjectIdentifier)? {
        guard testAdapter != nil, let current = owners[id], current.phase == .connected else { return nil }
        let channel = BLELinkChannel(testing: ()), tx = NSObject(), audio = NSObject()
        let endpoints = (tx: ObjectIdentifier(tx), audio: ObjectIdentifier(audio))
        installAndSubscribeLink(id, current: current, channel: channel, txEndpoint: tx, audioEndpoint: audio,
                                notifyTX: {}, notifyAudio: {})
        return endpoints
    }
    func testReinstallCurrentIdentityChannel(_ id: UUID) {
        guard testAdapter != nil, let current = owners[id], let channel = linkChannels[id] else { return }
        installIdentityChannel(id, current: current, channel: channel)
    }
    func testIdentityInstallationRevision(_ id: UUID) -> ObjectIdentifier? { owners[id].map { ObjectIdentifier($0.channelRevision) } }
    func testReplaceIdentityChannel(_ id: UUID) {
        guard testAdapter != nil, let current = owners[id], current.phase == .connected else { return }
        installIdentityChannel(id, current: current, channel: BLELinkChannel(testing: ()))
    }
    func testInstallIdentityClient(_ id: UUID, reuse: Bool = false) {
        guard testAdapter != nil, let current = owners[id], current.phase == .connected,
              let channel = linkChannels[id] else { return }
        let client: PDSHLinkClient
        if reuse {
            guard let existing = linkClients[id] else { return }
            client = existing
        } else { client = PDSHLinkClient(transport: channel) }
        installIdentityClient(id, current: current, client: client,
                              isCurrent: { self.owners[id] === current && self.linkChannels[id] === channel }, publish: { _ in })
    }
    func testCaptureIdentityProof(_ id: UUID) -> ((String) -> Void)? {
        guard testAdapter != nil, let context = identityContext(id) else { return nil }
        return { [weak self] identity in self?.completeIdentityProof(id, context: context, identity: identity) }
    }
    func testCaptureIdentityProofFailure(_ id: UUID) -> ((Error) throws -> Void)? {
        guard testAdapter != nil, let context = identityContext(id) else { return nil }
        return { [weak self] error in
            guard let self else { return }
            try self.completeIdentityProofFailure(id, context: context, error: error)
        }
    }
    func testSetIdentityPending(_ id: UUID, label: String) {
        guard testAdapter != nil, let context = identityContext(id) else { return }
        publishIdentityProof(id, context: context, identity: label, known: false)
    }
    func testIdentityRevision(_ id: UUID) -> ObjectIdentifier? { owners[id].map { ObjectIdentifier($0.identityRevision) } }
    func testIdentityClient(_ id: UUID) -> ObjectIdentifier? { linkClients[id].map(ObjectIdentifier.init) }
    func testIdentityChannel(_ id: UUID) -> ObjectIdentifier? { linkChannels[id].map(ObjectIdentifier.init) }
    @discardableResult func testStartIdentityLinkHandshake(_ id: UUID, transport: any PDSHLinkTransport) -> Task<Void, Never>? {
        guard testAdapter != nil, let current = owners[id], let channel = linkChannels[id], linkTasks[id] == nil else { return nil }
        startLinkHandshake(id, current: current, channel: channel, transport: transport)
        return linkTasks[id]
    }
    func testCaptureIdentityChannelFailure(_ id: UUID) -> (() -> Void)? {
        guard testAdapter != nil, let channel = linkChannels[id], let callback = channel.onFailure else { return nil }
        return { _ = channel; callback() }
    }
    func testCaptureIdentityChannelEvent(_ id: UUID) -> ((Data) -> Void)? {
        guard testAdapter != nil, let channel = linkChannels[id], let callback = channel.onEvent else { return nil }
        return { data in _ = channel; callback(data) }
    }
    #endif

    private func readAdmission(_ id: UUID, profile: StandardBLEProfile) throws -> Owner {
        guard profile != .alert, let current = owners[id], current.read else {
            throw BLEFailure("Enable device read access in Settings → Bluetooth devices")
        }
        guard pending == nil else { throw BLEFailure("Another Bluetooth read is running") }
        guard poweredOn, current.phase == .connected,
              !current.standardSubscribed.contains(profile), !current.standardSubscriptionUnknown.contains(profile) else {
            throw BLEFailure("Device disconnected or unsupported profile")
        }
        #if DEBUG
        if let testAdapter {
            guard testAdapter.profiles[id]?.contains(profile) == true else { throw BLEFailure("Device disconnected or unsupported profile") }
            return current
        }
        #endif
        guard let peripheral = current.peripheral, peripheral.state == .connected,
              let characteristic = characteristics[id]?[profile], !characteristic.isNotifying else {
            throw BLEFailure("Device disconnected or unsupported profile")
        }
        return current
    }

    private func beginRead(_ id: UUID, profile: StandardBLEProfile, current: Owner,
                           claim: ReadClaim, continuation: CheckedContinuation<String, Error>) {
        if case .cancelled? = claim.snapshot().0 { continuation.resume(throwing: CancellationError()); return }
        guard owners[id] === current, (try? readAdmission(id, profile: profile)) === current else {
            continuation.resume(throwing: BLEFailure("Device disconnected or unsupported profile")); return
        }
        let read = PendingRead(device: id, profile: profile, owner: current, claim: claim, continuation: continuation)
        pending = read
        #if DEBUG
        testAdapter?.beforeReadReserve?()
        #endif
        guard claim.reserve() else { finishRead(read); return }
        #if DEBUG
        testAdapter?.afterReadReserve?()
        #endif
        if claim.snapshot().0 != nil { settleReadCancellation(read); return }
        read.timer = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self.timeoutRead(read)
        }
        read.timerCreated = true
        #if DEBUG
        if let testAdapter { testAdapter.commands.append(.read(id, profile)); return }
        #endif
        guard poweredOn, owners[id] === current, current.phase == .connected,
              let peripheral = current.peripheral, let characteristic = characteristics[id]?[profile] else {
            _ = claim.claim(.disconnected); finishRead(read); return
        }
        peripheral.readValue(for: characteristic)
    }

    public func read(_ id: UUID, profile: StandardBLEProfile) async throws -> String {
        try Task.checkCancellation()
        let current = try readAdmission(id, profile: profile)
        let claim = ReadClaim()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginRead(id, profile: profile, current: current, claim: claim, continuation: continuation)
            }
        } onCancel: {
            if claim.claim(.cancelled) {
                Task { @MainActor in
                    guard let read = self.pending, read.claim === claim else { return }
                    self.settleReadCancellation(read)
                }
            }
        }
    }

    private func settleReadCancellation(_ read: PendingRead) {
        guard pending === read else { return }
        let (outcome, submitted) = read.claim.snapshot()
        guard case .cancelled? = outcome else { return }
        if submitted, owners[read.device] === read.owner {
            close(read.device, current: read.owner, outcome: .cancelled, quarantine: false)
        } else { finishRead(read) }
    }

    private func timeoutRead(_ read: PendingRead) {
        guard pending === read, owners[read.device] === read.owner, read.claim.claim(.timeout) else { return }
        close(read.device, current: read.owner, outcome: .timeout, quarantine: false)
    }
    private enum ValueSource {
        case linkTX(Data), linkOther, standard(StandardBLEProfile, Data, Bool), unknown
    }
    private func dispatchValue(_ id: UUID, source: ValueSource, error: Error?) {
        guard poweredOn, let current = owners[id], current.phase == .connected else { return }
        switch source {
        case .linkTX(let data):
            guard let channel = linkChannels[id] else {
                close(id, current: current, outcome: .disconnected, quarantine: true); return
            }
            channel.receiveSegment(data, error: error)
        case .linkOther:
            return
        case .standard(let profile, let data, let notifying):
            guard let read = pending, read.device == id, read.owner === current,
                  read.profile == profile, !notifying,
                  !current.standardSubscribed.contains(profile), !current.standardSubscriptionUnknown.contains(profile) else {
                close(id, current: current, outcome: .disconnected, quarantine: true); return
            }
            receivedRead(read, data: data, error: error)
        case .unknown:
            close(id, current: current, outcome: .disconnected, quarantine: true)
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard acceptDelegatePeer(id, physical: peripheral) != nil else { return }
        let source: ValueSource
        if linkCharacteristics[id]?.values.contains(where: { $0 === characteristic }) == true {
            if let channel = linkChannels[id] {
                source = channel.tx === characteristic ? .linkTX(characteristic.value ?? Data()) : .linkOther
            } else { source = .unknown }
        } else if let profile = StandardBLEProfile.allCases.first(where: { characteristics[id]?[$0] === characteristic }) {
            source = .standard(profile, characteristic.value ?? Data(), characteristic.isNotifying)
        } else { source = .unknown }
        dispatchValue(id, source: source, error: error)
    }
    private func receivedRead(_ read: PendingRead, data: Data, error: Error?) {
        guard pending === read else { return }
        let result: Result<String, Error>
        do {
            if let error { throw error }
            let value = try read.profile.decode(data)
            result = .success("\(value) \(read.profile.unit) @ \(ISO8601DateFormatter().string(from: Date()))")
        } catch { result = .failure(error) }
        guard read.claim.claim(.value(result)) else { return }
        finishRead(read)
        if case .success(let value) = result {
            update(read.device) {
                guard self.owners[read.device] === read.owner, read.owner.phase == .connected else { return }
                $0.readings[read.profile.rawValue] = value
            }
        }
    }
    public func cancelRead() {
        guard let read = pending else { return }
        guard read.claim.claim(.cancelled) else { return }
        settleReadCancellation(read)
    }
    public func alert(_ id: UUID, level: Int) throws -> String {
        guard let current = owners[id], current.alert else { throw BLEFailure("Enable Immediate Alert access for this device in Settings") }
        let data = try StandardBLEProfile.alertCommand(level: level)
        guard poweredOn, current.phase == .connected else { throw BLEFailure("Alert unavailable or Bluetooth busy") }
        #if DEBUG
        if let testAdapter {
            guard testAdapter.profiles[id]?.contains(.alert) == true else { throw BLEFailure("Alert unavailable or Bluetooth busy") }
            testAdapter.commands.append(.alert(id, level))
            return "submitted_unconfirmed: Immediate Alert has no application acknowledgement; inspect device before repeating."
        }
        #endif
        guard let peripheral = current.peripheral, peripheral.state == .connected,
              let characteristic = characteristics[id]?[.alert], peripheral.canSendWriteWithoutResponse else { throw BLEFailure("Alert unavailable or Bluetooth busy") }
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        return "submitted_unconfirmed: Immediate Alert has no application acknowledgement; inspect device before repeating."
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let current = acceptDelegatePeer(peripheral.identifier, physical: peripheral), current.phase == .connected else { return }
        linkChannels[peripheral.identifier]?.didWrite(characteristic, error: error)
    }
    private enum NotificationSource { case standard(StandardBLEProfile, notifying: Bool), link, unknown }
    private func dispatchNotification(_ id: UUID, physical: AnyObject, source: NotificationSource, error: Error?) {
        guard let current = acceptDelegatePeer(id, physical: physical), current.phase == .connected else { return }
        switch source {
        case .standard(let profile, let notifying):
            if error != nil { current.standardSubscriptionUnknown.insert(profile) }
            if notifying { current.standardSubscribed.insert(profile) }
            else { current.standardSubscriptionUnknown.insert(profile) }
            return
        case .unknown:
            quarantineUnexpected(id, current: current, sendDisconnect: true)
            return
        case .link:
            break
        }
        guard error == nil else { status = error!.localizedDescription; disconnect(id); return }
        guard let channel = linkChannels[id], channel.tx?.isNotifying == true, channel.audio?.isNotifying == true else { return }
        startLinkHandshake(id, current: current, channel: channel, transport: channel)
    }
    private func startLinkHandshake(_ id: UUID, current: Owner, channel: BLELinkChannel,
                                    transport: any PDSHLinkTransport) {
        guard poweredOn, owners[id] === current, current.phase == .connected,
              linkChannels[id] === channel, linkTasks[id] == nil else { return }
        let handshakeRevision = current.identityRevision
        linkTasks[id] = Task {
            do {
                let client = PDSHLinkClient(transport: transport, allowTaskProfile: deviceTaskDiscoveryEnabled), peer = try await client.handshake()
                guard !Task.isCancelled, owners[id] === current, current.phase == .connected,
                      linkChannels[id] === channel, current.identityRevision === handshakeRevision else { return }
                update(id) { guard self.owners[id] === current, current.phase == .connected, self.linkChannels[id] === channel, current.identityRevision === handshakeRevision else { return }; $0.linkState = "Link \(peer.version >> 8).\(peer.version & 255) · boot \(peer.bootID)" }
                guard poweredOn, owners[id] === current, current.phase == .connected, linkChannels[id] === channel, current.identityRevision === handshakeRevision else { return }
                guard peer.supportsTools else { update(id) { guard self.owners[id] === current, current.phase == .connected, self.linkChannels[id] === channel, current.identityRevision === handshakeRevision else { return }; $0.linkState += " · 旧固件，未协商工具扩展" }; return }
                try await discoverLinkTools(id, client: client, bootID: peer.bootID) { self.linkChannels[id] === channel }
            } catch {
                if !Task.isCancelled, poweredOn, owners[id] === current, current.phase == .connected,
                   linkChannels[id] === channel, current.identityRevision === handshakeRevision {
                    withMutation(keyPath: \.status) {
                        guard self.poweredOn, self.owners[id] === current, current.phase == .connected,
                              self.linkChannels[id] === channel, current.identityRevision === handshakeRevision else { return }
                        _status = error.localizedDescription
                    }
                    guard poweredOn, owners[id] === current, current.phase == .connected,
                          linkChannels[id] === channel, current.identityRevision === handshakeRevision else { return }
                    disconnect(id)
                }
            }
        }
    }

    private func notificationSource(_ id: UUID, characteristic: AnyObject, notifying: Bool) -> NotificationSource {
        if let profile = StandardBLEProfile.allCases.first(where: { characteristics[id]?[$0] === characteristic }) {
            return .standard(profile, notifying: notifying)
        }
        #if DEBUG
        if let adapter = testAdapter,
           let profile = StandardBLEProfile.allCases.first(where: { adapter.profileEndpoints[id]?[$0] === characteristic }) {
            return .standard(profile, notifying: notifying)
        }
        #endif
        if linkChannels[id] != nil, linkPhysicalEndpoints[id]?.values.contains(where: { $0 === characteristic }) == true {
            return .link
        }
        return .unknown
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        let source = notificationSource(id, characteristic: characteristic, notifying: characteristic.isNotifying)
        dispatchNotification(id, physical: peripheral, source: source, error: error)
    }

    /// Installs ordinary Link tools without invoking the draft task identity profile.
    func discoverLinkTools(_ id: UUID, client: PDSHLinkClient, bootID: UInt32,
                           isCurrent: () -> Bool) async throws {
        guard poweredOn, let capturedOwner = owners[id], capturedOwner.phase == .connected,
              isCurrent() else { throw BLEFailure("Stale connection") }
        let capturedChannel = linkChannels[id], capturedRevision = capturedOwner.identityRevision
        let list = try await client.invoke(requestID: UUID(), name: "tools/list", arguments: .object([:]), idempotencyKey: UUID().uuidString)
        guard poweredOn, owners[id] === capturedOwner, capturedOwner.phase == .connected,
              linkChannels[id] === capturedChannel, capturedOwner.identityRevision === capturedRevision,
              !Task.isCancelled, isCurrent() else { throw BLEFailure("Stale connection") }
        guard case .object(let root) = list, root["status"] == .string("completed"),
              case .object(let result) = root["result"], case .string(let deviceID) = result["device_id"], UUID(uuidString: deviceID) != nil,
              result["boot_id"] == .number(Double(bootID)), case .array(let tools) = result["tools"], tools.count <= 32 else { throw BLEFailure("Invalid Link tools/list") }
        let names = try tools.map { tool -> String in
            guard case .object(let fields) = tool, case .string(let name) = fields["name"], !name.isEmpty,
                  name.utf8.count <= 64, name.utf8.allSatisfy({ (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else { throw BLEFailure("Invalid tool name") }
            return name
        }
        guard Set(names).count == names.count, !Task.isCancelled, isCurrent() else { throw BLEFailure("Duplicate tools or stale connection") }
        guard poweredOn, owners[id] === capturedOwner, capturedOwner.phase == .connected,
              linkChannels[id] === capturedChannel, capturedOwner.identityRevision === capturedRevision,
              isCurrent() else { throw BLEFailure("Stale connection") }
        let current = capturedOwner
        linkBootIDs[id] = bootID
        linkTaskTools[id] = Set(names.filter(Self.isReservedTaskTool))
        let ordinaryTools = tools.filter { !Self.isReservedTaskTool($0["name"]?.stringValue ?? "") }
        // GAP-16 remains open; advertised task tools are never invoked here.
        installIdentityClient(id, current: current, client: client, isCurrent: isCurrent) {
            $0.linkIdentity = deviceID.lowercased(); $0.linkTools = names.filter { !Self.isReservedTaskTool($0) }
            $0.linkToolDescriptors = ordinaryTools; $0.linkState += " · PDSH Tools v1"
        }
    }
    public func grantLinkTool(_ id: UUID, name: String, enabled: Bool) {
        guard poweredOn, let current = owners[id], current.phase == .connected else { return }
        guard linkBusy[id] == nil else { status = "请等待当前设备操作结束，或断开连接"; return }
        // These are host control-plane operations, never model device skills.
        guard !Self.isReservedTaskTool(name) else { return }
        update(id) { guard self.owners[id] === current, current.phase == .connected else { return }; if enabled && $0.linkTools.contains(name) { $0.grantedTools.insert(name) } else { $0.grantedTools.remove(name) } }
    }

    private struct IdentityContext {
        let owner: Owner
        let channel: BLELinkChannel
        let client: PDSHLinkClient
        let revision: Revision
    }
    private struct ConfirmationContext {
        let identity: IdentityContext
        let pending: String
        let attempt: Revision
    }
    private struct RejectedConfirmation {
        let owner: Owner
        let revision: Revision
        let errorRevision: Revision
        let attempt: Revision?
        let channel: BLELinkChannel?
        let client: PDSHLinkClient?
        let pending: String
    }
    private var identityDefaults: UserDefaults {
        #if DEBUG
        if let defaults = testAdapter?.identityDefaults { return defaults }
        #endif
        return .standard
    }
    private func identityContext(_ id: UUID, client: PDSHLinkClient? = nil) -> IdentityContext? {
        guard poweredOn, let current = owners[id], current.phase == .connected,
              let channel = linkChannels[id], let actualClient = linkClients[id],
              client == nil || client === actualClient else { return nil }
        return IdentityContext(owner: current, channel: channel, client: actualClient, revision: current.identityRevision)
    }
    private func isCurrentIdentity(_ id: UUID, _ context: IdentityContext) -> Bool {
        poweredOn && owners[id] === context.owner && context.owner.phase == .connected &&
        context.owner.identityRevision === context.revision && linkChannels[id] === context.channel &&
        linkClients[id] === context.client
    }
    private func sameScalars(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }
    private func isCurrentConfirmationState(_ id: UUID, _ context: ConfirmationContext) -> Bool {
        isCurrentIdentity(id, context.identity) &&
        context.identity.owner.identityPendingRevision === context.identity.revision &&
        context.identity.owner.identityAttempt === context.attempt
    }
    private func isCurrentConfirmation(_ id: UUID, _ context: ConfirmationContext) -> Bool {
        guard isCurrentConfirmationState(id, context), let device = devices.first(where: { $0.id == id }) else { return false }
        return sameScalars(device.pendingIdentity, context.pending)
    }
    /// Publishes the result of the local proof lookup. The wire proof helper is
    /// dormant; this transition itself neither calls it nor establishes trust.
    private func publishIdentityProof(_ id: UUID, context: IdentityContext, identity: String, known: Bool) {
        guard isCurrentIdentity(id, context) else { return }
        let current = context.owner
        invalidateIdentity(current)
        let revision = current.identityRevision, errorRevision = current.identityErrorRevision
        update(id) {
            guard self.owners[id] === current, current.phase == .connected, self.poweredOn,
                  current.identityRevision === revision, self.linkChannels[id] === context.channel,
                  self.linkClients[id] === context.client else { return }
            if known {
                $0.taskIdentity = identity; $0.pendingIdentity = ""
            } else {
                current.identityPendingRevision = revision
                $0.taskIdentity = ""; $0.pendingIdentity = identity
            }
            $0.supportsDeviceTasks = false; $0.allowDeviceTasks = false
            if current.identityErrorRevision === errorRevision { $0.identityError = "" }
        }
    }
    private func completeIdentityProof(_ id: UUID, context: IdentityContext, identity: String) {
        guard isCurrentIdentity(id, context) else { return }
        let known = BLETrustedIdentities.contains(identity, defaults: identityDefaults)
        guard isCurrentIdentity(id, context) else { return }
        publishIdentityProof(id, context: context, identity: identity, known: known)
    }

    private func completeIdentityProofFailure(_ id: UUID, context: IdentityContext, error: Error) throws {
        guard !Task.isCancelled, isCurrentIdentity(id, context) else { return }
        throw error
    }

    /// This helper remains unused while the authenticated identity profile is target.
    private func proveIdentity(_ id: UUID, client: PDSHLinkClient) async throws {
        guard let context = identityContext(id, client: client) else { return }
        let nonce = try BLEIdentity.randomNonce()
        let reply: JSONValue
        do {
            reply = try await client.invoke(requestID: UUID(), name: "pdsh.identity.prove",
                arguments: .object(["nonce": .string(BLEIdentity.hexEncode([UInt8](nonce)))]),
                idempotencyKey: UUID().uuidString.lowercased())
        } catch {
            guard !Task.isCancelled else { return }
            try completeIdentityProofFailure(id, context: context, error: error)
            return
        }
        guard !Task.isCancelled, isCurrentIdentity(id, context) else { return }
        guard case .object(let root) = reply, root["status"] == .string("completed"),
              case .object(let result) = root["result"],
              case .string(let publicKey) = result["pubkey"],
              case .string(let signature) = result["signature"] else {
            throw BLEFailure("设备身份证明返回无效")
        }
        let identity = try BLEIdentity.verify(nonce: nonce, publicKeyHex: publicKey, signatureHex: signature)
        guard !Task.isCancelled else { return }
        completeIdentityProof(id, context: context, identity: identity)
    }

    /// Records only the visible legacy label; this does not authenticate a peer.
    public func trustPendingIdentity(_ id: UUID) {
        guard let initial = devices.first(where: { $0.id == id }) else { return }
        let requested = initial.pendingIdentity
        var accepted: ConfirmationContext?
        var rejected: RejectedConfirmation?
        let outcome = BLETrustedIdentities.confirm(requested, defaults: identityDefaults, onAccepted: {
            guard let device = self.devices.first(where: { $0.id == id }) else { return false }
            let current = self.owner(id)
            guard let identity = self.identityContext(id),
                  identity.owner.identityPendingRevision === identity.revision,
                  !device.pendingIdentity.isEmpty, self.sameScalars(device.pendingIdentity, requested) else {
                rejected = RejectedConfirmation(owner: current, revision: current.identityRevision,
                    errorRevision: current.identityErrorRevision, attempt: current.identityAttempt,
                    channel: self.linkChannels[id], client: self.linkClients[id], pending: device.pendingIdentity)
                return false
            }
            let attempt = Revision(); current.identityAttempt = attempt
            accepted = ConfirmationContext(identity: identity, pending: device.pendingIdentity, attempt: attempt)
            return true
        }, isCurrent: {
            guard let accepted else { return false }
            return self.isCurrentConfirmation(id, accepted)
        })
        switch outcome {
        case .reentrantBusy, .stale:
            return
        case .notAdmitted:
            guard let rejected, owners[id] === rejected.owner,
                  rejected.owner.identityRevision === rejected.revision,
                  rejected.owner.identityErrorRevision === rejected.errorRevision,
                  rejected.owner.identityAttempt === rejected.attempt,
                  linkChannels[id] === rejected.channel, linkClients[id] === rejected.client,
                  let device = devices.first(where: { $0.id == id }), sameScalars(device.pendingIdentity, rejected.pending) else { return }
            let errorRevision = Revision(); rejected.owner.identityErrorRevision = errorRevision
            update(id) {
                guard self.owners[id] === rejected.owner, rejected.owner.identityRevision === rejected.revision,
                      rejected.owner.identityErrorRevision === errorRevision,
                      rejected.owner.identityAttempt === rejected.attempt,
                      self.linkChannels[id] === rejected.channel, self.linkClients[id] === rejected.client,
                      self.sameScalars($0.pendingIdentity, rejected.pending) else { return }
                $0.identityError = "请先连接设备并完成身份证明"
            }
        case .success:
            guard let accepted, isCurrentConfirmation(id, accepted) else { return }
            update(id) {
                guard self.isCurrentConfirmationState(id, accepted), self.sameScalars($0.pendingIdentity, accepted.pending) else { return }
                self.invalidateIdentity(accepted.identity.owner)
                $0.taskIdentity = accepted.pending; $0.pendingIdentity = ""; $0.identityError = ""
                $0.supportsDeviceTasks = false; $0.allowDeviceTasks = false
            }
        case .storageFailure:
            guard let accepted, isCurrentConfirmation(id, accepted) else { return }
            let errorRevision = Revision(); accepted.identity.owner.identityErrorRevision = errorRevision
            update(id) {
                guard self.isCurrentConfirmationState(id, accepted), self.sameScalars($0.pendingIdentity, accepted.pending),
                      accepted.identity.owner.identityErrorRevision === errorRevision else { return }
                $0.identityError = "记录身份失败，请重试"
            }
        }
    }

    /// GAP-16 requires BLE task grants to remain unavailable until authenticated
    /// peer binding is specified and verified. Revocation remains available.
    public func grantDeviceTasks(_ id: UUID, enabled: Bool) throws {
        if enabled {
            update(id) { $0.allowDeviceTasks = false }
            throw BLEFailure("设备身份认证尚未完成验证，暂不能授权蓝牙设备派任务")
        }
        update(id) { $0.allowDeviceTasks = false }
        if linkBusy[id] != nil { disconnect(id) }
    }

    func invokeTaskLink(_ id: UUID, identity: String, requestID: UUID, name: String,
                        arguments: JSONValue, key: String, fresh: Bool) async throws -> JSONValue {
        let allowed: Set<String> = ["pdsh.task.next", "pdsh.task.accept", "pdsh.task.complete", "pdsh.task.fail"]
        guard allowed.contains(name), let device = devices.first(where: { $0.id == id }),
              device.allowDeviceTasks, !device.taskIdentity.isEmpty, device.taskIdentity == identity,
              linkTaskTools[id]?.contains(name) == true, let client = linkClients[id],
              linkBusy[id] == nil else { throw BLEFailure("Device task grant or Link connection unavailable") }
        guard let current = owners[id], current.phase == .connected, poweredOn else { throw BLEFailure("Link disconnected") }
        let operation = LinkOperation(owner: current); linkBusy[id] = operation
        defer { if linkBusy[id] === operation { linkBusy[id] = nil } }
        guard submitConnected(id, current: current, action: .link, physical: {}) else { throw BLEFailure("Link disconnected") }
        if fresh { return try await client.invoke(requestID: requestID, name: name, arguments: arguments, idempotencyKey: key) }
        guard let result = try await client.query(requestID: requestID) else { throw BLEFailure("Link operation still running") }
        return result
    }
    public func setHomeOrigins(_ id: UUID, text: String) {
        guard linkBusy[id] == nil else { return }
        update(id) { $0.homeOrigins = text }
    }
    public func authorizeLink(_ id: UUID, name: String, arguments: JSONValue?) throws {
        guard poweredOn, owners[id]?.phase == .connected, !Self.isReservedTaskTool(name),
              let device = devices.first(where: { $0.id == id }), linkClients[id] != nil,
              device.grantedTools.contains(name), device.linkTools.contains(name) else { throw BLEFailure("Authorize this Link tool in Settings → Bluetooth devices") }
        if name == "home.http", let arguments {
            _ = try HomeHTTPPolicy.validate(arguments, allowedOrigins: HomeHTTPPolicy.origins(device.homeOrigins))
        }
    }
    public func invokeLink(_ id: UUID, requestID: UUID, name: String, arguments: JSONValue, key: String) async throws -> JSONValue {
        try authorizeLink(id, name: name, arguments: arguments)
        guard let client = linkClients[id], linkBusy[id] == nil else { throw BLEFailure("Link is busy") }
        guard let current = owners[id], current.phase == .connected, poweredOn else { throw BLEFailure("Link disconnected") }
        let operation = LinkOperation(owner: current); linkBusy[id] = operation
        defer { if linkBusy[id] === operation { linkBusy[id] = nil } }
        guard submitConnected(id, current: current, action: .link, physical: {}) else { throw BLEFailure("Link disconnected") }
        return try await client.invoke(requestID: requestID, name: name, arguments: arguments, idempotencyKey: key)
    }
    public func queryLink(_ id: UUID, requestID: UUID, name: String) async throws -> JSONValue? {
        try authorizeLink(id, name: name, arguments: nil)
        guard let client = linkClients[id], linkBusy[id] == nil else { throw BLEFailure("Link is busy") }
        guard let current = owners[id], current.phase == .connected, poweredOn else { throw BLEFailure("Link disconnected") }
        let operation = LinkOperation(owner: current); linkBusy[id] = operation
        defer { if linkBusy[id] === operation { linkBusy[id] = nil } }
        guard submitConnected(id, current: current, action: .link, physical: {}) else { throw BLEFailure("Link disconnected") }
        return try await client.query(requestID: requestID)
    }
    public func cancelLinkOperations() { for (id, operation) in Array(linkBusy) where owners[id] === operation.owner { disconnect(id) } }

}

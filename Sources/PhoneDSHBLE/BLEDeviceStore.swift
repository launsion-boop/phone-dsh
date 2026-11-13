// SPDX-License-Identifier: MIT
import CoreBluetooth
import Foundation
import Observation
import PhoneDSHAgentCore

@MainActor @Observable public final class BLEDeviceStore: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public static let shared = BLEDeviceStore()
    /// When true (the app sets it), a board the user connected is trusted: its Link tools and
    /// standard read/alert are allowed by default and only the user's revocations are stored
    /// (BLEDeviceTrustMemory). Off by default so the library keeps explicit per-connection grants.
    @ObservationIgnored public var trustConnectedDevices = false
    @ObservationIgnored public var trustMemory = BLEDeviceTrustMemory()
    /// Boards to reconnect when they show up (remembered boards after launch).
    @ObservationIgnored private var autoConnectIDs = Set<UUID>()
    /// Known boards that bypass the 100-entry discovery cap.
    @ObservationIgnored private var priorityIDs = Set<UUID>()
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
        /// The Link device ID exactly as `tools/list` returned it. `linkIdentity`
        /// stays lowercased for existing trust/journal consumers; the device panel
        /// descriptor compares `device_id` verbatim (device-panel.md §4).
        public var linkDeviceID = ""
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
        /// secure-session-v2: the selected record's device ID for this
        /// connection ("ble:" + 64 hex), or empty when none is selected.
        public var secureDevice = ""
        /// secure-session-v2 service / CoC state of this connection (UI text).
        public var secureState = ""
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
    @ObservationIgnored private var linkPhysicalServices: [UUID: AnyObject] = [:]
    @ObservationIgnored private var linkChannels: [UUID: BLELinkChannel] = [:]
    @ObservationIgnored private var linkClients: [UUID: PDSHLinkClient] = [:]
    @ObservationIgnored private var deviceTaskDiscoveryEnabled = false
    @ObservationIgnored private var linkTaskTools: [UUID: Set<String>] = [:]
    @ObservationIgnored private var linkTasks: [UUID: Task<Void, Never>] = [:]
    private final class LinkOperation {
        /// Identity for the shared entry's hold/release pair.
        let id = UUID()
        /// The connection generation that owns the slot, if any was connected at admission.
        let owner: Owner?
        /// False for a call the user started from the device panel. An Agent
        /// turn or MCP cancellation must not disconnect it: panel calls are not
        /// part of the device Session (device-panel.md §3).
        let agentCancellable: Bool
        init(owner: Owner?, agentCancellable: Bool = true) {
            self.owner = owner; self.agentCancellable = agentCancellable
        }
    }
    @ObservationIgnored private var linkBusy: [UUID: LinkOperation] = [:]
    /// ble-link.md@scan-intent-v1: the latest admitted scan/stop owns every later scan effect.
    @ObservationIgnored private var scanIntent = Revision()
    /// The intent whose initialization still waits for a powered-on manager.
    @ObservationIgnored private var pendingScan: Revision?
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var characteristics: [UUID: [StandardBLEProfile: AnyObject]] = [:]
    @ObservationIgnored private var ambiguousProfiles: [UUID: Set<StandardBLEProfile>] = [:]
    private final class ConnectionDeadline {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel(); task = nil }
    }
    @ObservationIgnored private var connectionTimers: [UUID: ConnectionDeadline] = [:]
    private final class ScanDeadline {
        let intent: Revision
        var task: Task<Void, Never>?
        init(intent: Revision) { self.intent = intent }
        func cancel() { task?.cancel(); task = nil }
    }
    @ObservationIgnored private var scanDeadline: ScanDeadline?
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
        var discovery: DiscoveryLedger?
        var disconnectRevision = Revision()
        // secure-session-v2 (§5, §8.2): captured at connect from the selection.
        var secureDevice: String?
        var secureLease: BLESecureLease?
        var securePSMEndpoint: AnyObject?
        var secureUnavailable = false
        var secureSlot: SecureSlot?
        var secureGrantAdmitted: BLESecureLease?
    }
    /// One CoC attempt / channel on a connection: a fresh PSM read, the open,
    /// then the bounded stream. At most one per connection at any time.
    private final class SecureSlot {
        let owner: Owner
        let lease: BLESecureLease
        var psm: UInt16?
        var readContinuation: CheckedContinuation<[UInt8], Error>?
        var openContinuation: CheckedContinuation<BLESecureByteStream, Error>?
        var timer: Task<Void, Never>?
        var stream: BLESecureBoundedStream?
        /// Retains the CBL2CAPChannel wrapper (or the test I/O).
        var io: AnyObject?
        init(owner: Owner, lease: BLESecureLease) { self.owner = owner; self.lease = lease }
        var pending: Bool { readContinuation != nil || openContinuation != nil }
        var live: Bool { pending || (stream.map { !$0.isClosed } ?? false) }
    }
    /// ble-link ownership plus secure-session-v2 M1: the one record the next
    /// connection to this peripheral is for.
    @ObservationIgnored private var secureSelection: (id: UUID, device: String)?
    private final class Revision {}
    @ObservationIgnored private var statusRevision = Revision()
    @ObservationIgnored private var managerUnavailableRevision = Revision()
    private func reserveStatus() -> Revision {
        let revision = Revision(); statusRevision = revision; return revision
    }
    private func publishStatus(_ revision: Revision, _ text: @autoclosure () -> String,
                               eligible: () -> Bool = { true }) {
        let message = text()
        guard statusRevision === revision, eligible(), _status != message else { return }
        withMutation(keyPath: \.status) {
            guard self.statusRevision === revision, eligible(), self._status != message else { return }
            self._status = message
        }
    }
    private struct ServiceObservation {
        let object: AnyObject, parent: AnyObject?
        let uuid: CBUUID
        let primary: Bool
    }
    private struct CharacteristicObservation {
        let object: AnyObject, parent: AnyObject?
        let uuid: CBUUID
        let properties: CBCharacteristicProperties
    }
    private final class DiscoveryRequest {
        enum State { case planned, submitted, completed, skipped }
        let service: ServiceObservation
        var state: State = .planned
        var snapshot: [CharacteristicObservation]?
        init(_ service: ServiceObservation) { self.service = service }
    }
    private final class DiscoveryLedger {
        let peer: AnyObject
        var servicesSubmitted = false
        var services: [ServiceObservation]?
        var requests: [DiscoveryRequest] = []
        var revision = Revision()
        init(peer: AnyObject) { self.peer = peer }
    }
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
        case secureRead(UUID), secureOpen(UUID, UInt16)
    }
    final class TestAdapter {
        var poweredOn = true
        var managerInitialized = true
        var managerState: CBManagerState = .poweredOn
        var commands: [TestCommand] = []
        var managerConstructions = 0
        var beforeConnect: ((UUID) -> Void)?
        var beforeDisconnectSubmit: ((UUID) -> Void)?
        var beforeReadReserve: (() -> Void)?
        var afterReadReserve: (() -> Void)?
        var afterReadOutcomeClaim: (() -> Void)?
        var afterReadValueClaim: (() -> Void)?
        var linkWrites: [(UUID, Data)] = []
        var onLinkWrite: ((UUID, Data) -> Void)?
        var linkTXEndpoints: [UUID: NSObject] = [:]
        var linkRXEndpoints: [UUID: NSObject] = [:]
        var afterNotify: ((UUID) -> Void)?
        var notifyEndpoints: [ObjectIdentifier] = []
        var profiles: [UUID: Set<StandardBLEProfile>] = [:]
        var validPeers: [UUID: NSObject] = [:]
        var profileEndpoints: [UUID: [StandardBLEProfile: NSObject]] = [:]
        var identityDefaults: UserDefaults?
        var discoverySubmissions: [(id: UUID, peer: AnyObject, service: AnyObject?)] = []
        var beforeCharacteristicReserve: ((UUID, TestService) -> Void)?
        var afterCharacteristicSubmit: ((UUID, TestService) -> Void)?
        var linkNotifying: [UUID: Set<ObjectIdentifier>] = [:]
        var serviceDiscoveryUUIDs: [UUID: [String]] = [:]
    }
    final class TestService: NSObject {
        var parent: AnyObject?, uuid: String, primary: Bool
        init(parent: AnyObject?, uuid: String, primary: Bool = true) {
            self.parent = parent; self.uuid = uuid; self.primary = primary
        }
    }
    final class TestCharacteristic: NSObject {
        var parent: AnyObject?, uuid: String, properties: CBCharacteristicProperties
        init(parent: AnyObject?, uuid: String, properties: CBCharacteristicProperties) {
            self.parent = parent; self.uuid = uuid; self.properties = properties
        }
    }
    @ObservationIgnored private var testAdapter: TestAdapter?
    @ObservationIgnored private var testCommittedLinkEvents: [UUID: Int] = [:]
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
    private var managerInitialized: Bool {
        #if DEBUG
        if let testAdapter { return testAdapter.managerInitialized }
        #endif
        return central != nil
    }
    private func managerMatches(_ state: CBManagerState) -> Bool {
        #if DEBUG
        if let adapter = testAdapter {
            return adapter.managerInitialized && adapter.managerState == state &&
                   (state == .poweredOn ? adapter.poweredOn : !adapter.poweredOn)
        }
        #endif
        return central?.state == state
    }
    /// Supersedes every older scan intent, its pending start and its deadline.
    private func takeScanIntent() -> Revision {
        let intent = Revision()
        scanIntent = intent; pendingScan = nil
        scanDeadline?.cancel(); scanDeadline = nil
        return intent
    }
    /// The value is rechecked inside the mutation: a nested newer intent
    /// delivered by will-change wins over this older frame.
    private func publishScanning(_ value: Bool, _ intent: Revision) {
        guard scanIntent === intent, _scanning != value else { return }
        withMutation(keyPath: \.scanning) {
            guard self.scanIntent === intent else { return }
            self._scanning = value
        }
    }
    public func scan() {
        if !managerInitialized {
            let intent = takeScanIntent()
            let revision = reserveStatus()
            pendingScan = intent
            publishStatus(revision, "正在初始化蓝牙", eligible: {
                !self.managerInitialized && self.scanIntent === intent && self.pendingScan === intent
            })
            // A stop delivered by the status observer cancels construction.
            guard scanIntent === intent, pendingScan === intent, !managerInitialized else { return }
            #if DEBUG
            if let adapter = testAdapter { adapter.managerConstructions += 1; adapter.managerInitialized = true; return }
            #endif
            if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
            return
        }
        guard poweredOn else {
            let revision = reserveStatus()
            publishStatus(revision, "请在系统设置中开启蓝牙并授权", eligible: { self.managerInitialized && !self.poweredOn })
            return
        }
        let intent = takeScanIntent()
        let revision = reserveStatus()
        // Foreground, bounded scan. Unadvertised services are discovered after user selection.
        #if DEBUG
        if let adapter = testAdapter { adapter.commands.append(.scan) }
        else { central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]) }
        #else
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        #endif
        surfaceKnownPeripherals()
        publishScanning(true, intent)
        guard scanIntent === intent else { return }
        guard poweredOn else { observeManagerUnavailable(); return }
        publishStatus(revision, "正在扫描（15 秒）", eligible: {
            self.scanIntent === intent && self.poweredOn && self.managerInitialized
        })
        guard scanIntent === intent else { return }
        guard poweredOn else { observeManagerUnavailable(); return }
        let deadline = ScanDeadline(intent: intent)
        scanDeadline = deadline
        deadline.task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.scanDeadlineFired(deadline)
        }
    }
    /// Identity first: a stale or cancelled deadline is inert regardless of power.
    private func scanDeadlineFired(_ deadline: ScanDeadline) {
        guard scanDeadline === deadline, scanIntent === deadline.intent else { return }
        stopScan()
    }
    public func stopScan() {
        let intent = takeScanIntent()
        #if DEBUG
        if let testAdapter { if testAdapter.poweredOn { testAdapter.commands.append(.stopScan) }; publishScanning(false, intent); return }
        #endif
        if poweredOn { central?.stopScan() }
        publishScanning(false, intent)
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { managerUnavailable(reset: true); return }
        centralStateChanged(central.state)
    }
    private func centralStateChanged(_ state: CBManagerState) {
        guard managerMatches(state) else {
            if !poweredOn { observeManagerUnavailable() }
            return
        }
        let revision = reserveStatus()
        if state == .poweredOn {
            publishStatus(revision, "蓝牙已就绪，请点击扫描", eligible: { self.managerMatches(state) })
            guard poweredOn else { observeManagerUnavailable(); return }
            // Only the still-current pending intent may start; a later stop cancelled it.
            if let pending = pendingScan, pending === scanIntent { pendingScan = nil; scan() }
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
            publishStatus(revision, "蓝牙不可用，状态：\(state.rawValue)", eligible: { self.managerMatches(state) })
        }
    }
    /// `present` is false for a remembered board that is only *known* (retrievePeripherals), not
    /// seen: connecting to an absent board would time out and leave it quarantined (ble-link.md).
    private func recordDiscovery(_ id: UUID, physical: AnyObject, name: String, rssi: Int, present: Bool = true) {
        guard peripherals[id] != nil || devices.contains(where: { $0.id == id }) || devices.count < 100 || priorityIDs.contains(id) else { return }
        defer {
            if present, autoConnectIDs.contains(id), owner(id).phase == .idle {
                autoConnectIDs.remove(id)
                Task { @MainActor [weak self] in self?.connect(id) }
            }
        }
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
                guard !_devices.contains(where: { $0.id == id }), _devices.count < 100 || priorityIDs.contains(id) else { return }
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
    /// A board already connected to iOS (for example over HID) is not reported by a scan, and a
    /// remembered board may not advertise; list both like discovered devices.
    private func surfaceKnownPeripherals() {
        #if DEBUG
        if testAdapter != nil { return }
        #endif
        guard let central else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: PDSHLink.service)])
        let remembered = trustConnectedDevices ? central.retrievePeripherals(withIdentifiers: trustMemory.rememberedBoards()) : []
        let present = Set(connected.map(\.identifier))
        var seen = Set<UUID>()
        for peripheral in connected + remembered where seen.insert(peripheral.identifier).inserted {
            priorityIDs.insert(peripheral.identifier)
            // Listed either way; connected only when present (system-connected now, or its advertisement later).
            recordDiscovery(peripheral.identifier, physical: peripheral, name: peripheral.name ?? "PDSH 设备", rssi: 0,
                            present: Self.rememberedBoardIsPresent(systemConnected: present.contains(peripheral.identifier),
                                                                   advertised: false))
        }
    }

    /// Reconnects the boards the user connected before (nothing when there are none, so a first
    /// launch never triggers the Bluetooth permission prompt).
    public func reconnectRemembered() {
        let boards = trustMemory.rememberedBoards()
        guard trustConnectedDevices, !boards.isEmpty else { return }
        autoConnectIDs.formUnion(boards)
        scan()
    }

    /// The user's own "disconnect": stop reconnecting this board, then disconnect it.
    public func forgetAndDisconnect(_ id: UUID) {
        trustMemory.forgetBoard(id)
        autoConnectIDs.remove(id)
        disconnect(id)
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
        testAdapter?.profiles[id] = nil; testAdapter?.profileEndpoints[id] = nil; testAdapter?.linkNotifying[id] = nil
        current.physicalIdentity = testAdapter?.validPeers[id] ?? peripheral
        #else
        current.physicalIdentity = peripheral
        #endif
        owners[id] = current
        if let selection = secureSelection, selection.id == id {
            current.secureDevice = selection.device
            current.secureLease = BLESecureLease(peripheral: id, device: selection.device)
        }
        let initialErrorRevision = current.identityErrorRevision
        let secureDevice = current.secureDevice
        update(id) {
            guard self.owners[id] === current, current.phase == .connecting else { return }
            $0.secureDevice = secureDevice.map(BLESecureIdentifiers.deviceID(fingerprint:)) ?? ""
            $0.secureState = secureDevice == nil ? "" : "等待发现安全会话服务"
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
        let deadline = ConnectionDeadline()
        connectionTimers[id] = deadline
        deadline.task = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            connectionTimedOut(id, current: current, deadline: deadline)
        }
        #if DEBUG
        if let testAdapter { testAdapter.commands.append(.connect(id)); return }
        #endif
        guard let peripheral else { return }
        peripheral.delegate = self
        central?.connect(peripheral, options: nil)
    }
    private func connectionTimedOut(_ id: UUID, current: Owner, deadline: ConnectionDeadline) {
        guard owners[id] === current, connectionTimers[id] === deadline,
              current.phase == .connecting || current.phase == .connected else { return }
        guard poweredOn else { observeManagerUnavailable(); return }
        let unavailableRevision = managerUnavailableRevision
        let revision = reserveStatus()
        connectionTimers.removeValue(forKey: id)?.cancel()
        let peer = current.physicalIdentity
        close(id, current: current, outcome: .disconnected, quarantine: current.phase == .connecting,
              serviceChange: true)
        // close applies all-owner unavailability itself at each reentrant edge.
        guard poweredOn, managerUnavailableRevision === unavailableRevision,
              owners[id] === current, current.physicalIdentity === peer,
              current.phase == .closing || current.phase == .quarantined else { return }
        let phase = current.phase
        publishStatus(revision, "连接或服务发现超时", eligible: {
            self.poweredOn && self.managerUnavailableRevision === unavailableRevision &&
            self.owners[id] === current && current.physicalIdentity === peer && current.phase == phase
        })
        if !poweredOn, managerUnavailableRevision === unavailableRevision { observeManagerUnavailable() }
    }
    public func disconnect(_ id: UUID) {
        guard let current = owners[id], current.phase != .idle else { return }
        close(id, current: current, outcome: .disconnected, quarantine: current.phase == .connecting)
    }
    public func grant(_ id: UUID, read: Bool? = nil, alert: Bool? = nil) {
        grant(id, read: read, alert: alert, recordDecision: true)
    }
    private func grant(_ id: UUID, read: Bool?, alert: Bool?, recordDecision: Bool) {
        guard devices.contains(where: { $0.id == id }) else { return }
        if recordDecision, trustConnectedDevices {
            if let read { trustMemory.setRevoked("@read", !read, for: id.uuidString) }
            if let alert { trustMemory.setRevoked("@alert", !alert, for: id.uuidString) }
        }
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

    private func submitDisconnect(_ id: UUID, current: Owner, peripheral: CBPeripheral? = nil,
                                  expectedSubmission: Revision? = nil) {
        guard poweredOn, owners[id] === current,
              expectedSubmission.map({ current.disconnectRevision === $0 }) ?? true else { return }
        let unavailableRevision = managerUnavailableRevision
        #if DEBUG
        testAdapter?.beforeDisconnectSubmit?(id)
        #endif
        guard owners[id] === current, managerUnavailableRevision === unavailableRevision,
              expectedSubmission.map({ current.disconnectRevision === $0 }) ?? true else { return }
        guard poweredOn else { observeManagerUnavailable(); return }
        #if DEBUG
        if let testAdapter {
            current.disconnectRevision = Revision()
            testAdapter.commands.append(.disconnect(id))
            return
        }
        #endif
        guard let connection = peripheral ?? current.peripheral, let central else { return }
        current.disconnectRevision = Revision()
        central.cancelPeripheralConnection(connection)
    }

    private func close(_ id: UUID, current: Owner, outcome: ReadClaim.Outcome,
                       quarantine: Bool, sendDisconnect: Bool = true, forceQuarantine: Bool = false,
                       serviceChange: Bool = false) {
        guard owners[id] === current else { return }
        if current.phase == .closing || current.phase == .quarantined { return }
        let unavailableRevision = managerUnavailableRevision
        let disconnectRevision = current.disconnectRevision
        let unsent = current.phase == .connecting && !current.submitted && !forceQuarantine
        let connection = current.peripheral
        current.phase = unsent ? .idle : (quarantine || !current.wasConnected || !poweredOn ? .quarantined : .closing)
        current.read = false; current.alert = false
        current.readVersion = Revision(); current.alertVersion = Revision()
        invalidateIdentity(current)
        teardownSecure(current, reason: "连接已结束")
        let errorRevision = current.identityErrorRevision
        let oldRead = pending.flatMap { $0.device == id && $0.owner === current ? $0 : nil }
        if let oldRead, oldRead.claim.claim(outcome) {
            #if DEBUG
            testAdapter?.afterReadOutcomeClaim?()
            #endif
        }
        if serviceChange && managerUnavailableRevision !== unavailableRevision { return }
        if serviceChange && !poweredOn { observeManagerUnavailable(); return }
        if linkBusy[id]?.owner === current { linkBusy[id] = nil }
        let task = linkTasks.removeValue(forKey: id)
        let channel = linkChannels.removeValue(forKey: id)
        linkClients[id] = nil; linkTaskTools[id] = nil; linkCharacteristics[id] = nil; linkPhysicalEndpoints[id] = nil; linkPhysicalServices[id] = nil
        linkBootIDs[id] = nil; linkEventSequences[id] = nil
        let timer = connectionTimers.removeValue(forKey: id)
        characteristics[id] = nil; ambiguousProfiles[id] = nil
        task?.cancel(); timer?.cancel()
        if serviceChange && managerUnavailableRevision !== unavailableRevision {
            channel?.fail(BLEFailure("Link disconnected; outcome_unknown"))
            return
        }
        if serviceChange && !poweredOn {
            observeManagerUnavailable(detachedChannels: channel.map { [$0] } ?? [])
            return
        }
        channel?.fail(BLEFailure("Link disconnected; outcome_unknown"))
        if serviceChange && managerUnavailableRevision !== unavailableRevision { return }
        if serviceChange && !poweredOn { observeManagerUnavailable(); return }
        if let oldRead { finishRead(oldRead) }
        if serviceChange && managerUnavailableRevision !== unavailableRevision { return }
        if serviceChange && !poweredOn { observeManagerUnavailable(); return }
        if current.phase == .closing {
            closingTimers[id]?.cancel()
            closingTimers[id] = Task {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                closingTimedOut(id, current: current)
            }
        }
        if serviceChange && !poweredOn { observeManagerUnavailable(); return }
        if !unsent, sendDisconnect, poweredOn {
            submitDisconnect(id, current: current, peripheral: connection, expectedSubmission: disconnectRevision)
        }
        if serviceChange && managerUnavailableRevision !== unavailableRevision { return }
        if serviceChange && !poweredOn { observeManagerUnavailable(); return }
        update(id) {
            guard self.owners[id] === current,
                  !serviceChange || (self.poweredOn && self.managerUnavailableRevision === unavailableRevision) else { return }
            $0.state = self.phaseLabel(current.phase)
            $0.linkState = "未连接"; $0.linkIdentity = ""; $0.linkDeviceID = ""; $0.linkTools = []; $0.linkToolDescriptors = []
            $0.allowDeviceTasks = false; $0.supportsDeviceTasks = false; $0.taskIdentity = ""; $0.pendingIdentity = ""; if current.identityErrorRevision === errorRevision { $0.identityError = "" }
            $0.grantedTools = []; $0.homeOrigins = ""; $0.events = []; $0.profiles = []; $0.readings = [:]
            $0.allowRead = current.read; $0.allowAlert = current.alert
            $0.secureDevice = ""; $0.secureState = ""
        }
        if serviceChange && !poweredOn && managerUnavailableRevision === unavailableRevision { observeManagerUnavailable() }
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

    private func observeManagerUnavailable(detachedChannels: [BLELinkChannel] = []) {
        #if DEBUG
        if testAdapter != nil {
            managerUnavailable(reset: false, detachedChannels: detachedChannels, linkFailure: BLEFailure("Link disconnected; outcome_unknown"))
            return
        }
        #endif
        let invalidatesPeers: Bool
        switch central?.state {
        case .poweredOff: invalidatesPeers = false
        default: invalidatesPeers = true
        }
        managerUnavailable(reset: invalidatesPeers, detachedChannels: detachedChannels,
                           linkFailure: BLEFailure("Link disconnected; outcome_unknown"))
    }
    private func managerUnavailable(reset: Bool, detachedChannels: [BLELinkChannel] = [],
                                    linkFailure: BLEFailure = BLEFailure("Bluetooth unavailable")) {
        managerUnavailableRevision = Revision()
        let unavailableScan = takeScanIntent()
        // Invalidate every owner before the first observer can reenter.
        let snapshot = Array(owners)
        var tasks: [Task<Void, Never>] = [], deadlines: [ConnectionDeadline] = [], channels: [BLELinkChannel] = detachedChannels
        var errorRevisions: [UUID: Revision] = [:]
        for (id, current) in snapshot {
            let neverSubmitted = current.phase == .idle && !submittedDevices.contains(id)
            current.phase = neverSubmitted ? .idle : .quarantined
            current.read = false; current.alert = false
            current.readVersion = Revision(); current.alertVersion = Revision()
            invalidateIdentity(current)
            teardownSecure(current, reason: "蓝牙不可用")
            errorRevisions[id] = current.identityErrorRevision
            if linkBusy[id]?.owner === current { linkBusy[id] = nil }
            if let task = linkTasks.removeValue(forKey: id) { tasks.append(task) }
            if let deadline = connectionTimers.removeValue(forKey: id) { deadlines.append(deadline) }
            if let task = closingTimers.removeValue(forKey: id) { tasks.append(task) }
            if let channel = linkChannels.removeValue(forKey: id) { channels.append(channel) }
            linkClients[id] = nil; linkTaskTools[id] = nil; linkCharacteristics[id] = nil; linkPhysicalEndpoints[id] = nil; linkPhysicalServices[id] = nil
            linkBootIDs[id] = nil; linkEventSequences[id] = nil
            characteristics[id] = nil; ambiguousProfiles[id] = nil
        }
        if reset { peripherals.removeAll() }
        if let read = pending { _ = read.claim.claim(.unavailable); finishRead(read) }
        tasks.forEach { $0.cancel() }
        deadlines.forEach { $0.cancel() }
        channels.forEach { $0.fail(linkFailure) }
        for (id, current) in snapshot {
            update(id) {
                guard self.owners[id] === current else { return }
                $0.allowRead = current.read; $0.allowAlert = current.alert; $0.state = self.phaseLabel(current.phase)
                $0.allowDeviceTasks = false; $0.supportsDeviceTasks = false
                $0.linkIdentity = ""; $0.linkDeviceID = ""; $0.linkState = "未连接"; $0.linkTools = []; $0.linkToolDescriptors = []
                $0.taskIdentity = ""; $0.pendingIdentity = ""; if current.identityErrorRevision === errorRevisions[id] { $0.identityError = "" }; $0.grantedTools = []; $0.homeOrigins = ""
                $0.events = []; $0.profiles = []; $0.readings = [:]; $0.secureDevice = ""; $0.secureState = ""
            }
        }
        publishScanning(false, unavailableScan)
    }
    private func quarantineUnexpected(_ id: UUID, current: Owner, sendDisconnect: Bool, serviceChange: Bool = false) {
        guard owners[id] === current else { return }
        if current.phase == .closing {
            current.phase = .quarantined
            closingTimers.removeValue(forKey: id)?.cancel()
            if sendDisconnect, poweredOn {
                submitDisconnect(id, current: current)
            }
            if serviceChange && !poweredOn { observeManagerUnavailable(); return }
            update(id) {
                guard self.owners[id] === current, current.phase == .quarantined,
                      !serviceChange || self.poweredOn else { return }
                $0.state = self.phaseLabel(.quarantined)
            }
            if serviceChange && !poweredOn { observeManagerUnavailable() }
        } else if current.phase != .quarantined {
            close(id, current: current, outcome: .disconnected, quarantine: true,
                  sendDisconnect: sendDisconnect, forceQuarantine: true, serviceChange: serviceChange)
        }
    }
    private func acceptDelegatePeer(_ id: UUID, physical: AnyObject, serviceChange: Bool = false) -> Owner? {
        guard poweredOn, let current = owners[id] else { return nil }
        guard current.physicalIdentity === physical else {
            quarantineUnexpected(id, current: current, sendDisconnect: current.submitted && current.phase != .closing,
                                 serviceChange: serviceChange)
            return nil
        }
        return current
    }
    private func dispatchServiceChange(_ id: UUID, physical: AnyObject, invalidated: [AnyObject]) {
        // The list is deliberately not used to narrow teardown: additions can
        // invalidate the connection's assumptions even when the list is empty.
        _ = invalidated
        guard poweredOn else { observeManagerUnavailable(); return }
        guard let current = acceptDelegatePeer(id, physical: physical, serviceChange: true) else { return }
        switch current.phase {
        case .connected:
            close(id, current: current, outcome: .disconnected, quarantine: false, serviceChange: true)
        case .connecting:
            quarantineUnexpected(id, current: current, sendDisconnect: current.submitted, serviceChange: true)
        case .idle:
            quarantineUnexpected(id, current: current, sendDisconnect: false, serviceChange: true)
        case .closing, .quarantined:
            return
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        dispatchServiceChange(peripheral.identifier, physical: peripheral, invalidated: invalidatedServices.map { $0 as AnyObject })
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central else { managerUnavailable(reset: true); return }
        guard acceptDelegatePeer(peripheral.identifier, physical: peripheral) != nil else { return }
        connected(peripheral.identifier, peripheral: peripheral)
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.central === central else { managerUnavailable(reset: true); return }
        dispatchConnectFailure(peripheral.identifier, physical: peripheral, error: error)
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central else { managerUnavailable(reset: true); return }
        let id = peripheral.identifier
        guard let current = acceptDelegatePeer(id, physical: peripheral) else { return }
        disconnectCallback(id, current: current)
        scheduleDisconnectBoundary(id, current: current)
        scheduleRememberedReconnect(id)
    }

    /// A remembered board that dropped (rebooted, out of range) is reconnected after the
    /// disconnect callback has completely returned (never inside it, ble-link.md), through the
    /// ordinary connect path. A board the user disconnected is no longer remembered.
    /// A remembered board is connected only when it is really there: connected at the system
    /// level (it rejoins as the iPhone's HID accessory), or seen advertising. A connect to an
    /// absent board times out, and a timed-out pending connect is quarantined until the app
    /// restarts (ble-link.md "Closing … quarantined"), so it is never submitted blind.
    public nonisolated static func rememberedBoardIsPresent(systemConnected: Bool, advertised: Bool) -> Bool {
        systemConnected || advertised
    }

    /// Watches for a remembered board after a drop: every 3 s for a minute, then every 15 s for
    /// five more (a reboot or a walk out of range), connecting the moment it is present.
    private func scheduleRememberedReconnect(_ id: UUID) {
        guard trustConnectedDevices, trustMemory.rememberedBoards().contains(id) else { return }
        Task { @MainActor [weak self] in
            for attempt in 0..<40 {
                try? await Task.sleep(for: .seconds(attempt < 20 ? 3 : 15))
                guard let self, self.poweredOn, self.trustMemory.rememberedBoards().contains(id) else { return }
                if self.owner(id).phase == .idle {
                    // Only a board our own central can submit for is connected here. A system
                    // connection (iOS keeping it as the HID accessory) is not adoptable this
                    // version: `connect` refuses a peripheral that is not `.disconnected`, and
                    // taking ownership would let a later disconnect drop the system's HID link
                    // (GAP-37). Such a board does not advertise, so the watch simply keeps
                    // waiting for one that does, or for the user to reconnect it.
                    if Self.rememberedBoardIsPresent(systemConnected: self.isSystemConnected(id), advertised: false),
                       self.peripherals[id]?.state == .disconnected {
                        self.connect(id)
                    } else {
                        // The scan's advertisement discovery connects it once it is back.
                        self.autoConnectIDs.insert(id); self.scan()
                    }
                }
                if self.owner(id).phase != .idle { return }
            }
        }
    }

    private func isSystemConnected(_ id: UUID) -> Bool {
        #if DEBUG
        if testAdapter != nil { return false }
        #endif
        guard let central else { return false }
        return central.retrieveConnectedPeripherals(withServices: [CBUUID(string: PDSHLink.service)])
            .contains { $0.identifier == id }
    }

    private func connected(_ id: UUID, peripheral: CBPeripheral?) {
        guard poweredOn, let current = owners[id] else { return }
        if current.phase == .quarantined {
            if current.submitted {
                submitDisconnect(id, current: current, peripheral: peripheral)
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
        guard poweredOn else { observeManagerUnavailable(); return }
        guard owners[id] === current, current.phase == .connected, let peer = current.physicalIdentity else { return }
        let ledger = DiscoveryLedger(peer: peer); current.discovery = ledger
        ledger.servicesSubmitted = true
        #if DEBUG
        testAdapter?.discoverySubmissions.append((id, peer, nil))
        #endif
        let secure = current.secureDevice != nil ? [BLESecureServiceProfile.serviceUUID] : []
        #if DEBUG
        testAdapter?.serviceDiscoveryUUIDs[id] = (Array(Set(StandardBLEProfile.allCases.map(\.service))) + [PDSHLink.service] + secure)
        #endif
        submitConnected(id, current: current, action: .discoverServices) {
            peripheral?.discoverServices((Array(Set(StandardBLEProfile.allCases.map(\.service))) + [PDSHLink.service] + secure).map { CBUUID(string: $0) })
        }
        if !poweredOn { observeManagerUnavailable() }
    }

    private func failedConnect(_ id: UUID) {
        guard let current = owners[id] else { return }
        if current.phase == .connecting && current.submitted {
            close(id, current: current, outcome: .disconnected, quarantine: true, sendDisconnect: false)
        } else if current.phase != .quarantined {
            quarantineUnexpected(id, current: current, sendDisconnect: current.phase == .connected)
        }
    }
    private func dispatchConnectFailure(_ id: UUID, physical: AnyObject, error: Error?) {
        guard let current = acceptDelegatePeer(id, physical: physical) else { return }
        guard current.phase == .connecting, current.submitted else {
            // An unexpected callback still follows the lifecycle quarantine
            // policy, but is not an eligible status publication.
            failedConnect(id)
            return
        }
        let revision = reserveStatus()
        failedConnect(id)
        guard poweredOn else { observeManagerUnavailable(); return }
        guard owners[id] === current, current.physicalIdentity === physical else { return }
        let phase = current.phase
        publishStatus(revision, error?.localizedDescription ?? "连接失败", eligible: {
            self.poweredOn && self.owners[id] === current && current.physicalIdentity === physical && current.phase == phase
        })
        if !poweredOn { observeManagerUnavailable() }
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
    private func sameMultiset<T>(_ lhs: [T], _ rhs: [T], equal: (T, T) -> Bool) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var remaining = rhs
        for item in lhs {
            guard let index = remaining.firstIndex(where: { equal(item, $0) }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }
    private func sameServices(_ a: [ServiceObservation], _ b: [ServiceObservation]) -> Bool {
        sameMultiset(a, b) { $0.object === $1.object && $0.parent === $1.parent && $0.uuid == $1.uuid && $0.primary == $1.primary }
    }
    private func sameCharacteristics(_ a: [CharacteristicObservation], _ b: [CharacteristicObservation]) -> Bool {
        sameMultiset(a, b) { $0.object === $1.object && $0.parent === $1.parent && $0.uuid == $1.uuid && $0.properties == $1.properties }
    }
    private func discoveryCurrent(_ id: UUID, _ current: Owner, _ ledger: DiscoveryLedger) -> Bool {
        poweredOn && owners[id] === current && current.phase == .connected &&
        current.discovery === ledger && current.physicalIdentity === ledger.peer
    }
    private func finishDiscoveryDeadline(_ id: UUID, _ current: Owner, _ ledger: DiscoveryLedger) {
        guard discoveryCurrent(id, current, ledger), ledger.services != nil,
              ledger.requests.allSatisfy({ $0.state == .completed || $0.state == .skipped }) else { return }
        connectionTimers.removeValue(forKey: id)?.cancel()
    }
    private func discoveryError(_ id: UUID, current: Owner, ledger: DiscoveryLedger, error: Error) {
        let revision = reserveStatus()
        // Closing is the error's claim. No observer may complete the pending
        // discovery or issue another request while the error is published.
        close(id, current: current, outcome: .disconnected, quarantine: false, serviceChange: true)
        guard poweredOn else { observeManagerUnavailable(); return }
        guard owners[id] === current, current.phase == .closing, current.discovery === ledger else { return }
        publishStatus(revision, error.localizedDescription, eligible: {
            self.poweredOn && self.owners[id] === current && current.phase == .closing && current.discovery === ledger
        })
        guard poweredOn else { observeManagerUnavailable(); return }
    }
    private func discoveryPeer(_ id: UUID, physical: AnyObject) -> (Owner, DiscoveryLedger)? {
        guard poweredOn else { observeManagerUnavailable(); return nil }
        guard let current = acceptDelegatePeer(id, physical: physical, serviceChange: true) else { return nil }
        guard current.phase == .connected else {
            if current.phase == .connecting || current.phase == .idle {
                quarantineUnexpected(id, current: current, sendDisconnect: current.submitted, serviceChange: true)
            }
            return nil
        }
        guard let ledger = current.discovery, ledger.peer === physical else {
            quarantineUnexpected(id, current: current, sendDisconnect: true, serviceChange: true); return nil
        }
        return (current, ledger)
    }
    private func dispatchServices(_ id: UUID, physical: AnyObject, services: [ServiceObservation]?, error: Error?) {
        guard let (current, ledger) = discoveryPeer(id, physical: physical) else { return }
        guard ledger.servicesSubmitted else { quarantineUnexpected(id, current: current, sendDisconnect: true, serviceChange: true); return }
        if let old = ledger.services {
            guard error == nil, let services, sameServices(old, services) else {
                quarantineUnexpected(id, current: current, sendDisconnect: true, serviceChange: true); return
            }
            return
        }
        if let error { discoveryError(id, current: current, ledger: ledger, error: error); return }
        guard let services else { return }
        guard services.allSatisfy({ $0.parent === physical }) else {
            quarantineUnexpected(id, current: current, sendDisconnect: true, serviceChange: true); return
        }
        ledger.services = services
        let linkUUID = CBUUID(string: PDSHLink.service)
        var distinct: [ServiceObservation] = []
        for service in services where !distinct.contains(where: { $0.object === service.object }) { distinct.append(service) }
        let linkCount = distinct.filter { $0.uuid == linkUUID }.count
        // secure-session-v2 §5: only a connection to the selected, enrolled
        // device plans the secure service; an ambiguous service is unusable.
        let secureUUID = CBUUID(string: BLESecureServiceProfile.serviceUUID)
        let secureSelected = current.secureDevice != nil
        let secureCount = secureSelected ? distinct.filter { $0.uuid == secureUUID }.count : 0
        for service in distinct {
            let standard = StandardBLEProfile.allCases.contains { CBUUID(string: $0.service) == service.uuid }
            let secure = secureSelected && service.uuid == secureUUID
            guard standard || service.uuid == linkUUID || secure else { continue }
            let request = DiscoveryRequest(service)
            if service.uuid == linkUUID && linkCount > 1 { request.state = .skipped }
            if secure && secureCount > 1 { request.state = .skipped }
            ledger.requests.append(request)
        }
        ledger.revision = Revision()
        finishDiscoveryDeadline(id, current, ledger)
        let revision = ledger.revision
        update(id) {
            guard self.discoveryCurrent(id, current, ledger), ledger.revision === revision else { return }
            $0.state = "已连接"
            if linkCount == 0 { $0.linkState = "本次未发现 Link" }
            else if linkCount > 1 { $0.linkState = "发现多个 Link 服务，暂不可用" }
            else { $0.linkState = "发现 Link 特征中" }
            if secureSelected {
                if secureCount == 0 { $0.secureState = "设备不支持安全任务会话" }
                else if secureCount > 1 { $0.secureState = "发现多个安全会话服务，暂不可用" }
                else { $0.secureState = "发现安全会话特征中" }
            }
        }
        guard poweredOn else { observeManagerUnavailable(); return }
        for request in ledger.requests where request.state == .planned {
            guard discoveryCurrent(id, current, ledger) else { return }
            #if DEBUG
            if let service = request.service.object as? TestService { testAdapter?.beforeCharacteristicReserve?(id, service) }
            #endif
            guard poweredOn else { observeManagerUnavailable(); return }
            guard discoveryCurrent(id, current, ledger), request.state == .planned else { return }
            let ids = request.service.uuid == linkUUID
                ? [PDSHLink.rx, PDSHLink.tx, PDSHLink.audioUp].map { CBUUID(string: $0) }
                : request.service.uuid == secureUUID ? [CBUUID(string: BLESecureServiceProfile.psmCharacteristicUUID)]
                : StandardBLEProfile.allCases.filter { CBUUID(string: $0.service) == request.service.uuid }.map { CBUUID(string: $0.characteristic) }
            request.state = .submitted
            #if DEBUG
            if let adapter = testAdapter, let service = request.service.object as? TestService {
                adapter.discoverySubmissions.append((id, physical, service))
                adapter.commands.append(.discoverCharacteristics(id))
                adapter.afterCharacteristicSubmit?(id, service)
            } else if let peripheral = physical as? CBPeripheral, let service = request.service.object as? CBService {
                peripheral.discoverCharacteristics(ids, for: service)
            }
            #else
            if let peripheral = physical as? CBPeripheral, let service = request.service.object as? CBService {
                peripheral.discoverCharacteristics(ids, for: service)
            }
            #endif
            guard poweredOn else { observeManagerUnavailable(); return }
        }
    }
    private func dispatchCharacteristics(_ id: UUID, physical: AnyObject, service: AnyObject,
                                         items: [CharacteristicObservation]?, error: Error?) {
        guard let (current, ledger) = discoveryPeer(id, physical: physical) else { return }
        guard let request = ledger.requests.first(where: { $0.service.object === service }),
              request.state == .submitted || request.state == .completed else {
            quarantineUnexpected(id, current: current, sendDisconnect: true, serviceChange: true); return
        }
        if request.state == .completed {
            guard error == nil, let items, let old = request.snapshot, sameCharacteristics(old, items) else {
                quarantineUnexpected(id, current: current, sendDisconnect: true, serviceChange: true); return
            }
            return
        }
        if let error { discoveryError(id, current: current, ledger: ledger, error: error); return }
        guard let items else { return }
        guard items.allSatisfy({ $0.parent === service }) else {
            quarantineUnexpected(id, current: current, sendDisconnect: true, serviceChange: true); return
        }
        request.snapshot = items; request.state = .completed; ledger.revision = Revision()
        finishDiscoveryDeadline(id, current, ledger)
        if request.service.uuid == CBUUID(string: PDSHLink.service) {
            installDiscoveredLink(id, current: current, ledger: ledger, request: request, items: items)
        } else if request.service.uuid == CBUUID(string: BLESecureServiceProfile.serviceUUID), current.secureDevice != nil {
            installDiscoveredSecure(id, current: current, ledger: ledger, items: items)
        }
        guard poweredOn else { observeManagerUnavailable(); return }
        guard discoveryCurrent(id, current, ledger) else { return }
        publishDiscoveryProfiles(id, current: current, ledger: ledger)
        if !poweredOn { observeManagerUnavailable() }
    }
    private func publishDiscoveryProfiles(_ id: UUID, current: Owner, ledger: DiscoveryLedger) {
        guard discoveryCurrent(id, current, ledger) else { return }
        var selected: [StandardBLEProfile: CharacteristicObservation] = [:]
        for profile in StandardBLEProfile.allCases {
            let group = ledger.requests.filter { $0.service.uuid == CBUUID(string: profile.service) }
            guard !group.isEmpty, group.allSatisfy({ $0.state == .completed || $0.state == .skipped }) else { continue }
            var candidates: [CharacteristicObservation] = []
            for item in group.flatMap({ $0.snapshot ?? [] }) where item.uuid == CBUUID(string: profile.characteristic) {
                if !candidates.contains(where: { $0.object === item.object }) { candidates.append(item) }
            }
            guard candidates.count == 1, let item = candidates.first else { continue }
            let required: CBCharacteristicProperties = profile == .alert ? .writeWithoutResponse : .read
            if item.properties.contains(required) { selected[profile] = item }
        }
        let revision = ledger.revision
        let result = StandardBLEProfile.allCases.filter { selected[$0] != nil }
        update(id) {
            guard self.discoveryCurrent(id, current, ledger), ledger.revision === revision else { return }
            self.characteristics[id] = selected.mapValues { $0.object }
            $0.profiles = result
        }
        if trustConnectedDevices, !result.isEmpty {
            // Same path as the user's switch, so grant ordering rules still apply.
            let revoked = trustMemory.revoked(for: id.uuidString)
            Task { @MainActor [weak self] in
                self?.grant(id, read: !revoked.contains("@read"), alert: !revoked.contains("@alert"), recordDecision: false)
            }
        }
    }
    private func installDiscoveredLink(_ id: UUID, current: Owner, ledger: DiscoveryLedger,
                                       request: DiscoveryRequest, items: [CharacteristicObservation]) {
        func unique(_ name: String) -> CharacteristicObservation? {
            var matches: [CharacteristicObservation] = []
            for item in items where item.uuid == CBUUID(string: name) {
                if !matches.contains(where: { $0.object === item.object }) { matches.append(item) }
            }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let rx = unique(PDSHLink.rx), let tx = unique(PDSHLink.tx), let audio = unique(PDSHLink.audioUp),
              rx.properties.contains(.write), tx.properties.contains(.notify), audio.properties.contains(.notify) else {
            let revision = ledger.revision
            update(id) { guard self.discoveryCurrent(id, current, ledger), ledger.revision === revision else { return }; $0.linkState = "Link 特征不完整或存在歧义" }
            return
        }
        guard discoveryCurrent(id, current, ledger) else { return }
        let endpoints = [PDSHLink.rx: rx.object, PDSHLink.tx: tx.object, PDSHLink.audioUp: audio.object]
        recordLinkPhysicalEndpoints(id, current: current, service: request.service.object, endpoints: endpoints)
        #if DEBUG
        if let adapter = testAdapter, let r = rx.object as? NSObject, let t = tx.object as? NSObject {
            adapter.linkRXEndpoints[id] = r; adapter.linkTXEndpoints[id] = t
            let io = BLELinkChannel.TestIO(), channel = BLELinkChannel(testingIO: io)
            io.write = { [weak adapter] data in adapter?.linkWrites.append((id, data)); adapter?.onLinkWrite?(id, data) }
            let installed = installAndSubscribeLink(id, current: current, channel: channel, txEndpoint: tx.object,
                                                    audioEndpoint: audio.object, installed: { installation in
                io.ready = { [weak self, weak current, weak channel, weak adapter] in
                    guard let self, let current, let channel, let adapter,
                          self.isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return false }
                    let notified = adapter.linkNotifying[id] ?? []
                    return notified.contains(ObjectIdentifier(tx.object)) && notified.contains(ObjectIdentifier(audio.object))
                }
            }, notifyTX: {}, notifyAudio: {})
            guard installed, discoveryCurrent(id, current, ledger), linkChannels[id] === channel else { return }
            return
        }
        #endif
        guard let peripheral = ledger.peer as? CBPeripheral, let r = rx.object as? CBCharacteristic,
              let t = tx.object as? CBCharacteristic, let a = audio.object as? CBCharacteristic else { return }
        linkCharacteristics[id] = [PDSHLink.rx: r, PDSHLink.tx: t, PDSHLink.audioUp: a]
        let channel = BLELinkChannel(peripheral: peripheral, rx: r, tx: t, audio: a)
        _ = installAndSubscribeLink(id, current: current, channel: channel, txEndpoint: t, audioEndpoint: a,
                                    notifyTX: { peripheral.setNotifyValue(true, for: t) },
                                    notifyAudio: { peripheral.setNotifyValue(true, for: a) })
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services?.map { ServiceObservation(object: $0, parent: $0.peripheral, uuid: $0.uuid, primary: $0.isPrimary) }
        dispatchServices(peripheral.identifier, physical: peripheral, services: services, error: error)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let items = service.characteristics?.map { CharacteristicObservation(object: $0, parent: $0.service, uuid: $0.uuid, properties: $0.properties) }
        dispatchCharacteristics(peripheral.identifier, physical: peripheral, service: service, items: items, error: error)
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
            guard self.poweredOn, self.owners[id] === current, current.phase == .connected,
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
                                                             installed: (Revision) -> Void = { _ in },
                                                             notifyTX: () -> Void, notifyAudio: () -> Void) -> Bool {
        guard let installation = installIdentityChannel(id, current: current, channel: channel),
              isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return false }
        installed(installation)
        guard isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return false }
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
    private func recordLinkPhysicalEndpoints(_ id: UUID, current: Owner, service: AnyObject? = nil,
                                             endpoints: [String: AnyObject]) {
        guard poweredOn, owners[id] === current, current.phase == .connected else { return }
        if let service { linkPhysicalServices[id] = service }
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
            #if DEBUG
            self.testCommittedLinkEvents[id, default: 0] += 1
            #endif
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

    // MARK: secure-session-v2 transport (§5, §8.2)

    /// Selects the one committed record (`device`, bare 64 hex) the next
    /// connection to peripheral `id` is for, or clears it with nil. Only that
    /// connection discovers the secure service. Changing or clearing the
    /// selection ends the secure part of a live connection to the previously
    /// selected peripheral (its generation, grant and CoC) without reusing it.
    @discardableResult public func selectSecureDevice(_ id: UUID, device: String?) -> Bool {
        guard devices.contains(where: { $0.id == id }) else { return false }
        guard let device else {
            guard secureSelection?.id == id else { return true }
            endSecureConnection(id)
            secureSelection = nil
            return true
        }
        guard BLESecureIdentifiers.isFingerprint(device) else { return false }
        if let old = secureSelection, old.id != id || old.device != device { endSecureConnection(old.id) }
        secureSelection = (id, device)
        return true
    }

    public var secureSelectionPeripheral: UUID? { secureSelection?.id }

    /// The connection generation token of the live connection to `id`, if it
    /// was made for the current selection and the secure service is usable.
    public func secureLease(_ id: UUID) -> BLESecureLease? {
        guard poweredOn, let current = owners[id], current.phase == .connected, !current.secureUnavailable,
              current.securePSMEndpoint != nil, let lease = current.secureLease, lease.isValid,
              let selection = secureSelection, selection.id == id, selection.device == lease.device else { return nil }
        return lease
    }

    private func endSecureConnection(_ id: UUID) {
        guard let current = owners[id], current.secureDevice != nil else { return }
        teardownSecure(current, reason: "所选设备已更改")
        current.secureDevice = nil; current.securePSMEndpoint = nil; current.secureUnavailable = true
        update(id) {
            guard self.owners[id] === current else { return }
            $0.secureDevice = ""; $0.secureState = current.phase == .connected ? "所选设备已更改，请断开后重新连接" : ""
        }
    }

    /// Synchronous fail-closed teardown: the lease is invalidated first, then
    /// any pending PSM read / CoC open fails and the stream closes.
    private func teardownSecure(_ current: Owner, reason: String) {
        current.secureGrantAdmitted = nil
        current.secureLease?.invalidate()
        if let slot = current.secureSlot { failSecureSlot(slot, BLEFailure(reason)) }
    }

    private func failSecureSlot(_ slot: SecureSlot, _ error: Error) {
        if slot.owner.secureSlot === slot { slot.owner.secureSlot = nil }
        slot.timer?.cancel(); slot.timer = nil
        let read = slot.readContinuation, open = slot.openContinuation
        slot.readContinuation = nil; slot.openContinuation = nil
        let stream = slot.stream
        slot.stream = nil
        stream?.ownerClosed()
        read?.resume(throwing: error)
        open?.resume(throwing: error)
    }

    private func secureSlotCurrent(_ id: UUID, _ slot: SecureSlot) -> Bool {
        poweredOn && owners[id] === slot.owner && slot.owner.phase == .connected &&
        slot.owner.secureSlot === slot && slot.lease.isValid && slot.owner.secureLease === slot.lease
    }

    private func installDiscoveredSecure(_ id: UUID, current: Owner, ledger: DiscoveryLedger, items: [CharacteristicObservation]) {
        var matches: [CharacteristicObservation] = []
        for item in items where item.uuid == CBUUID(string: BLESecureServiceProfile.psmCharacteristicUUID) {
            if !matches.contains(where: { $0.object === item.object }) { matches.append(item) }
        }
        let revision = ledger.revision
        guard matches.count == 1, matches[0].properties.contains(.read) else {
            current.secureUnavailable = true
            update(id) { guard self.discoveryCurrent(id, current, ledger), ledger.revision === revision else { return }; $0.secureState = "安全会话特征不完整或存在歧义" }
            return
        }
        current.securePSMEndpoint = matches[0].object
        update(id) { guard self.discoveryCurrent(id, current, ledger), ledger.revision === revision else { return }; $0.secureState = "安全会话服务可用" }
    }

    /// Opens one CoC to the selected device on the live connection of
    /// `lease`: reads the PSM afresh (never cached), validates it (§5), opens
    /// the channel and returns its bounded stream. At most one channel per
    /// connection is live; every owner teardown closes it.
    public func openSecureStream(_ id: UUID, lease: BLESecureLease) async throws -> BLESecureByteStream {
        guard poweredOn, let current = owners[id], current.phase == .connected, current.secureLease === lease,
              lease.isValid, !current.secureUnavailable, let endpoint = current.securePSMEndpoint else {
            throw BLEFailure("安全会话不可用")
        }
        if let old = current.secureSlot {
            guard !old.live else { throw BLEFailure("本次连接已有安全通道") }
            current.secureSlot = nil
        }
        let slot = SecureSlot(owner: current, lease: lease)
        current.secureSlot = slot
        update(id) { guard self.owners[id] === current else { return }; $0.secureState = "读取安全会话端口" }
        let value: [UInt8] = try await withCheckedThrowingContinuation { continuation in
            slot.readContinuation = continuation
            armSecureTimer(id, slot, seconds: 10, "读取安全会话端口超时")
            #if DEBUG
            if let testAdapter { testAdapter.commands.append(.secureRead(id)); return }
            #endif
            guard let peripheral = current.peripheral, let characteristic = endpoint as? CBCharacteristic else {
                failSecureSlot(slot, BLEFailure("安全会话不可用")); return
            }
            peripheral.readValue(for: characteristic)
        }
        guard secureSlotCurrent(id, slot) else { throw BLEFailure("连接已结束") }
        guard let psm = BLESecureServiceProfile.psm(fromCharacteristic: value) else {
            // §5: any other length or range → no secure session on this connection.
            current.secureUnavailable = true
            failSecureSlot(slot, BLEFailure("安全会话端口无效"))
            update(id) { guard self.owners[id] === current else { return }; $0.secureState = "安全会话端口无效，本次连接不可用" }
            throw BLEFailure("安全会话端口无效")
        }
        slot.psm = psm
        let stream: BLESecureByteStream = try await withCheckedThrowingContinuation { continuation in
            slot.openContinuation = continuation
            armSecureTimer(id, slot, seconds: 15, "打开安全通道超时")
            #if DEBUG
            if let testAdapter { testAdapter.commands.append(.secureOpen(id, psm)); return }
            #endif
            guard let peripheral = current.peripheral else { failSecureSlot(slot, BLEFailure("安全会话不可用")); return }
            peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
        }
        guard secureSlotCurrent(id, slot) else { stream.close(); throw BLEFailure("连接已结束") }
        update(id) { guard self.owners[id] === current, current.secureSlot === slot else { return }; $0.secureState = "安全通道已打开" }
        return stream
    }

    private func armSecureTimer(_ id: UUID, _ slot: SecureSlot, seconds: Int, _ message: String) {
        slot.timer?.cancel()
        slot.timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, slot.pending else { return }
            self.failSecureSlot(slot, BLEFailure(message))
        }
    }

    private func receivedSecurePSM(_ id: UUID, slot: SecureSlot, data: Data, error: Error?) {
        guard secureSlotCurrent(id, slot), let continuation = slot.readContinuation else { return }
        slot.readContinuation = nil
        slot.timer?.cancel(); slot.timer = nil
        if let error { failSecureSlot(slot, error); continuation.resume(throwing: error); return }
        continuation.resume(returning: Array(data))
    }

    private func dispatchSecureOpen(_ id: UUID, physical: AnyObject, psm: UInt16?, error: Error?,
                                    make: () -> (io: AnyObject, stream: BLESecureBoundedStream)?) {
        guard let current = acceptDelegatePeer(id, physical: physical), current.phase == .connected,
              let slot = current.secureSlot, secureSlotCurrent(id, slot), let continuation = slot.openContinuation else {
            // Unsolicited or stale: the channel is never adopted.
            make()?.stream.close()
            return
        }
        guard error == nil, let psm, psm == slot.psm, let made = make() else {
            failSecureSlot(slot, error ?? BLEFailure("打开安全通道失败"))
            return
        }
        slot.openContinuation = nil
        slot.timer?.cancel(); slot.timer = nil
        slot.io = made.io
        slot.stream = made.stream
        made.stream.onClose = { [weak self, weak slot] _ in
            Task { @MainActor in
                guard let self, let slot, slot.owner.secureSlot === slot else { return }
                slot.owner.secureSlot = nil
                slot.stream = nil; slot.io = nil
                self.update(id) { guard self.owners[id] === slot.owner, slot.owner.phase == .connected else { return }; $0.secureState = "安全通道已关闭" }
            }
        }
        continuation.resume(returning: made.stream)
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        dispatchSecureOpen(peripheral.identifier, physical: peripheral, psm: channel.map { UInt16($0.psm) }, error: error) {
            guard let channel else { return nil }
            let io = BLESecureL2CAPStream(channel: channel)
            return (io, io.stream)
        }
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
    func testSecurePSMEndpoint(_ id: UUID) -> AnyObject? { owners[id]?.securePSMEndpoint }
    func testSecureSlotLive(_ id: UUID) -> Bool { owners[id]?.secureSlot?.live ?? false }
    func testSecureConnectionLease(_ id: UUID) -> BLESecureLease? { owners[id]?.secureLease }
    func testSecurePSMValue(_ id: UUID, data: Data, notifying: Bool = false, error: Error? = nil) {
        guard let peer = testAdapter?.validPeers[id], let endpoint = owners[id]?.securePSMEndpoint else { return }
        dispatchPhysicalValue(id, physical: peer, endpoint: endpoint, data: data, notifying: notifying, error: error)
    }
    @discardableResult
    func testSecureDidOpen(_ id: UUID, psm: UInt16?, io: BLESecureStreamIO?, error: Error? = nil,
                           matchingPeer: Bool = true) -> BLESecureBoundedStream? {
        guard let peer = matchingPeer ? testAdapter?.validPeers[id] : NSObject() else { return nil }
        var made: BLESecureBoundedStream?
        dispatchSecureOpen(id, physical: peer, psm: psm, error: error) {
            guard let io else { return nil }
            let stream = BLESecureBoundedStream(io: io)
            made = stream
            return (io, stream)
        }
        return made
    }
    func testDidConnect(_ id: UUID) {
        guard let peer = testAdapter?.validPeers[id], acceptDelegatePeer(id, physical: peer) != nil else { return }
        connected(id, peripheral: nil)
    }
    func testPhysicalPeer(_ id: UUID) -> AnyObject? { testAdapter?.validPeers[id] }
    func testDiscoveryServices(_ id: UUID, peer: AnyObject, services: [TestService]?, error: Error? = nil) {
        guard testAdapter != nil else { return }
        let snapshot = services?.map { ServiceObservation(object: $0, parent: $0.parent, uuid: CBUUID(string: $0.uuid), primary: $0.primary) }
        dispatchServices(id, physical: peer, services: snapshot, error: error)
    }
    func testDiscoveryCharacteristics(_ id: UUID, peer: AnyObject, service: TestService,
                                      characteristics: [TestCharacteristic]?, error: Error? = nil) {
        guard testAdapter != nil else { return }
        let snapshot = characteristics?.map { CharacteristicObservation(object: $0, parent: $0.parent, uuid: CBUUID(string: $0.uuid), properties: $0.properties) }
        dispatchCharacteristics(id, physical: peer, service: service, items: snapshot, error: error)
    }
    func testDiscoveryNotification(_ id: UUID, peer: AnyObject, characteristic: TestCharacteristic,
                                   notifying: Bool, error: Error? = nil) {
        guard testAdapter != nil else { return }
        dispatchNotification(id, physical: peer, source: notificationSource(id, characteristic: characteristic, notifying: notifying),
                             endpoint: characteristic, notifying: notifying, error: error)
    }
    func testDiscoveryLinkEndpoints(_ id: UUID) -> (service: AnyObject, rx: AnyObject, tx: AnyObject, audio: AnyObject)? {
        guard testAdapter != nil, let service = linkPhysicalServices[id], let endpoints = linkPhysicalEndpoints[id],
              let rx = endpoints[PDSHLink.rx], let tx = endpoints[PDSHLink.tx], let audio = endpoints[PDSHLink.audioUp],
              linkChannels[id] != nil else { return nil }
        return (service, rx, tx, audio)
    }
    func testDiscoveryRawLinkStorageEmpty(_ id: UUID) -> Bool {
        guard testAdapter != nil else { return false }
        return linkPhysicalServices[id] == nil && (linkPhysicalEndpoints[id]?.isEmpty ?? true) &&
               (linkCharacteristics[id]?.isEmpty ?? true)
    }
    func testDiscoveryProfileEndpoint(_ id: UUID, profile: StandardBLEProfile) -> AnyObject? {
        testAdapter == nil ? nil : characteristics[id]?[profile]
    }
    func testConnectionDeadlineToken(_ id: UUID) -> ObjectIdentifier? {
        guard testAdapter != nil, let deadline = connectionTimers[id] else { return nil }
        return ObjectIdentifier(deadline)
    }
    func testReadClaim(_ id: UUID) -> String? {
        guard testAdapter != nil, let read = pending, read.device == id else { return nil }
        switch read.claim.snapshot().0 {
        case nil: return "none"
        case .cancelled?: return "cancelled"
        case .permission?: return "permission"
        case .timeout?: return "timeout"
        case .unavailable?: return "unavailable"
        case .disconnected?: return "disconnected"
        case .value?: return "value"
        }
    }
    func testDidFail(_ id: UUID, error: Error? = nil) {
        guard let peer = testAdapter?.validPeers[id] else { return }
        dispatchConnectFailure(id, physical: peer, error: error)
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
        characteristics[id] = testAdapter.profileEndpoints[id]?.mapValues { $0 as AnyObject }
        connectionTimers.removeValue(forKey: id)?.cancel()
        update(id) {
            guard self.owners[id] === current, current.phase == .connected else { return }
            $0.profiles = StandardBLEProfile.allCases.filter { profiles.contains($0) }
        }
    }
    func testValue(_ id: UUID, profile: StandardBLEProfile?, data: Data, error: Error? = nil) {
        guard let adapter = testAdapter, let peer = adapter.validPeers[id] else { return }
        let endpoint = profile.flatMap { characteristics[id]?[$0] } ?? NSObject()
        dispatchPhysicalValue(id, physical: peer, endpoint: endpoint, data: data, notifying: false, error: error)
    }
    func testPhysicalValue(_ id: UUID, physical: AnyObject, endpoint: AnyObject, data: Data, error: Error? = nil) {
        guard testAdapter != nil else { return }
        dispatchPhysicalValue(id, physical: physical, endpoint: endpoint, data: data, notifying: false, error: error)
    }
    func testServicesModified(_ id: UUID, matchingPeer: Bool = true, invalidated: [AnyObject] = []) {
        guard let adapter = testAdapter else { return }
        let peer = matchingPeer ? (adapter.validPeers[id] ?? NSObject()) : NSObject()
        dispatchServiceChange(id, physical: peer, invalidated: invalidated)
    }
    func testUnassignablePeer(_ id: UUID) {
        guard testAdapter != nil else { return }
        _ = acceptDelegatePeer(id, physical: NSObject())
    }
    func testRadioUnavailable(reset: Bool) { testManagerState(reset ? .resetting : .poweredOff) }
    func testManagerState(_ state: CBManagerState) {
        guard let testAdapter else { return }
        testAdapter.managerInitialized = true; testAdapter.managerState = state
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
    /// The real production scan deadline and its own handler, not a copy.
    func testCaptureScanDeadline() -> TestTimerProbe? {
        guard let deadline = scanDeadline else { return nil }
        return TestTimerProbe(state: { [weak self] in
                                  self?.scanDeadline === deadline && self?.scanIntent === deadline.intent ? "active" : "cancelled"
                              },
                              fire: { [weak self] in self?.scanDeadlineFired(deadline) })
    }
    func testCaptureConnectionTimeout(_ id: UUID) -> TestTimerProbe? {
        guard let current = owners[id], let deadline = connectionTimers[id] else { return nil }
        return TestTimerProbe(state: { [weak self] in self?.owners[id] === current && self?.connectionTimers[id] === deadline ? "active" : "cancelled" },
                              fire: { [weak self] in self?.connectionTimedOut(id, current: current, deadline: deadline) })
    }
    func testSubscription(_ id: UUID, profile: StandardBLEProfile, state: String) {
        testNotification(id, profile: profile, matchingPeer: true, notifying: state == "subscribed")
    }
    func testNotification(_ id: UUID, profile: StandardBLEProfile?, matchingPeer: Bool = true,
                          notifying: Bool, error: Error? = nil) {
        guard let adapter = testAdapter, let knownPeer = adapter.validPeers[id] else { return }
        let peer = matchingPeer ? knownPeer : NSObject()
        let endpoint = profile.flatMap { characteristics[id]?[$0] } ?? NSObject()
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
    func testPrepareLink(_ id: UUID, bootID: UInt32, deviceID: String, writeLimit: Int = 244) {
        guard testAdapter != nil, poweredOn, let current = owners[id], current.phase == .connected else { return }
        guard let adapter = testAdapter else { return }
        let io = BLELinkChannel.TestIO(), channel = BLELinkChannel(testingIO: io)
        io.writeLimit = writeLimit
        let tx = NSObject(), rx = NSObject(), service = NSObject()
        adapter.linkTXEndpoints[id] = tx; adapter.linkRXEndpoints[id] = rx
        recordLinkPhysicalEndpoints(id, current: current, service: service, endpoints: [PDSHLink.tx: tx, PDSHLink.rx: rx])
        guard let installation = installIdentityChannel(id, current: current, channel: channel),
              isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return }
        io.ready = { [weak self, weak current, weak channel] in
            guard let self, let current, let channel else { return false }
            return self.isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation)
        }
        io.write = { [weak adapter] data in
            guard let adapter else { return }
            adapter.linkWrites.append((id, data)); adapter.onLinkWrite?(id, data)
        }
        linkBootIDs[id] = bootID
        update(id) {
            guard self.isCurrentChannelInstallation(id, current: current, channel: channel, installation: installation) else { return }
            $0.linkIdentity = deviceID.lowercased()
            $0.linkDeviceID = deviceID
        }
    }
    func testLinkEvent(_ id: UUID, segment: Data) {
        guard let endpoint = testAdapter?.linkTXEndpoints[id], let peer = testAdapter?.validPeers[id] else { return }
        testLinkSegment(id, physical: peer, endpoint: endpoint, data: segment)
    }
    func testCurrentLinkTransport(_ id: UUID) -> (any PDSHLinkTransport)? {
        guard testAdapter != nil else { return nil }
        return linkChannels[id]
    }
    func testLinkPhysicalPeer(_ id: UUID) -> AnyObject? { testAdapter?.validPeers[id] }
    func testLinkTXEndpoint(_ id: UUID) -> AnyObject? { testAdapter?.linkTXEndpoints[id] }
    func testLinkRXEndpoint(_ id: UUID) -> AnyObject? { testAdapter?.linkRXEndpoints[id] }
    func testKnownService(_ id: UUID) -> AnyObject? { guard testAdapter != nil else { return nil }; return linkPhysicalServices[id] }
    func testLinkExchangePending(_ id: UUID) -> Bool { testAdapter != nil && linkChannels[id]?.testHasPending == true }
    func testLinkPhysicalReady(_ id: UUID) -> Bool? {
        guard testAdapter != nil, let channel = linkChannels[id] else { return nil }
        return channel.testPhysicalReady
    }
    func testCaptureLinkReceiveCount(_ id: UUID) -> (() -> Int)? {
        guard testAdapter != nil, let channel = linkChannels[id] else { return nil }
        return { channel.testReceiveCount }
    }
    func testLinkWriteComplete(_ id: UUID, physical: AnyObject, endpoint: AnyObject, error: Error? = nil) {
        guard testAdapter != nil else { return }
        dispatchLinkWrite(id, physical: physical, endpoint: endpoint, error: error)
    }
    func testLinkSegment(_ id: UUID, physical: AnyObject, endpoint: AnyObject, data: Data, error: Error? = nil) {
        guard testAdapter != nil else { return }
        dispatchPhysicalValue(id, physical: physical, endpoint: endpoint, data: data, notifying: false, error: error)
    }
    func testLinkDeliveries(_ id: UUID) -> Int { devices.first(where: { $0.id == id })?.events.count ?? 0 }
    func testCommittedLinkEventCount(_ id: UUID) -> Int {
        guard testAdapter != nil else { return 0 }
        return testCommittedLinkEvents[id] ?? 0
    }
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
        guard let endpoint = characteristics[id]?[profile] else { throw BLEFailure("Device disconnected or unsupported profile") }
        #if DEBUG
        if testAdapter != nil { return current }
        #endif
        guard let peripheral = current.peripheral, peripheral.state == .connected,
              let characteristic = endpoint as? CBCharacteristic, !characteristic.isNotifying else {
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
              let peripheral = current.peripheral, let characteristic = characteristics[id]?[profile] as? CBCharacteristic else {
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
        case linkTX(Data), linkOther, standard(StandardBLEProfile, Data, Bool), securePSM(Data, Bool), unknown
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
        case .securePSM(let data, let notifying):
            guard let slot = current.secureSlot, slot.readContinuation != nil, !notifying else {
                close(id, current: current, outcome: .disconnected, quarantine: true); return
            }
            receivedSecurePSM(id, slot: slot, data: data, error: error)
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
    private func dispatchPhysicalValue(_ id: UUID, physical: AnyObject, endpoint: AnyObject,
                                       data: Data, notifying: Bool, error: Error?) {
        guard acceptDelegatePeer(id, physical: physical) != nil else { return }
        let source: ValueSource
        if let psm = owners[id]?.securePSMEndpoint, psm === endpoint {
            source = .securePSM(data, notifying)
        } else if linkPhysicalEndpoints[id]?.values.contains(where: { $0 === endpoint }) == true {
            if let channel = linkChannels[id] {
                var isTX = channel.tx === endpoint
                #if DEBUG
                if let adapter = testAdapter, adapter.linkTXEndpoints[id] === endpoint { isTX = true }
                #endif
                source = isTX ? .linkTX(data) : .linkOther
            } else { source = .unknown }
        } else if let profile = StandardBLEProfile.allCases.first(where: { characteristics[id]?[$0] === endpoint }) {
            source = .standard(profile, data, notifying)
        } else { source = .unknown }
        dispatchValue(id, source: source, error: error)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        dispatchPhysicalValue(peripheral.identifier, physical: peripheral, endpoint: characteristic,
                              data: characteristic.value ?? Data(), notifying: characteristic.isNotifying, error: error)
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
        #if DEBUG
        testAdapter?.afterReadValueClaim?()
        #endif
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
        guard let endpoint = characteristics[id]?[.alert] else { throw BLEFailure("Alert unavailable or Bluetooth busy") }
        #if DEBUG
        if let testAdapter {
            testAdapter.commands.append(.alert(id, level))
            return "submitted_unconfirmed: Immediate Alert has no application acknowledgement; inspect device before repeating."
        }
        #endif
        guard let peripheral = current.peripheral, peripheral.state == .connected,
              let characteristic = endpoint as? CBCharacteristic, peripheral.canSendWriteWithoutResponse else { throw BLEFailure("Alert unavailable or Bluetooth busy") }
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        return "submitted_unconfirmed: Immediate Alert has no application acknowledgement; inspect device before repeating."
    }
    private func dispatchLinkWrite(_ id: UUID, physical: AnyObject, endpoint: AnyObject, error: Error?) {
        guard let current = acceptDelegatePeer(id, physical: physical), current.phase == .connected,
              let channel = linkChannels[id] else { return }
        var expected: AnyObject? = channel.rx
        #if DEBUG
        if expected == nil { expected = testAdapter?.linkRXEndpoints[id] }
        #endif
        guard expected === endpoint else { return }
        channel.didWriteResult(error)
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        dispatchLinkWrite(peripheral.identifier, physical: peripheral, endpoint: characteristic, error: error)
    }
    private enum NotificationSource { case standard(StandardBLEProfile, notifying: Bool), link, unknown }
    private func dispatchNotification(_ id: UUID, physical: AnyObject, source: NotificationSource,
                                      endpoint: AnyObject? = nil, notifying: Bool = false, error: Error?) {
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
            #if DEBUG
            if let adapter = testAdapter, let endpoint {
                if notifying && error == nil { adapter.linkNotifying[id, default: []].insert(ObjectIdentifier(endpoint)) }
                else { adapter.linkNotifying[id]?.remove(ObjectIdentifier(endpoint)) }
            }
            #endif
            break
        }
        if let error {
            guard let channel = linkChannels[id] else { return }
            let installation = current.channelRevision
            let revision = reserveStatus()
            publishStatus(revision, error.localizedDescription, eligible: {
                self.poweredOn && self.owners[id] === current && current.phase == .connected &&
                current.physicalIdentity === physical && self.linkChannels[id] === channel &&
                current.channelRevision === installation
            })
            guard poweredOn else { observeManagerUnavailable(); return }
            guard owners[id] === current, current.phase == .connected,
                  current.physicalIdentity === physical, linkChannels[id] === channel,
                  current.channelRevision === installation else { return }
            close(id, current: current, outcome: .disconnected, quarantine: false, serviceChange: true)
            return
        }
        guard let channel = linkChannels[id] else { return }
        #if DEBUG
        if testAdapter != nil {
            guard channel.testPhysicalReady else { return }
        } else {
            guard channel.tx?.isNotifying == true, channel.audio?.isNotifying == true else { return }
        }
        #else
        guard channel.tx?.isNotifying == true, channel.audio?.isNotifying == true else { return }
        #endif
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
                    let revision = reserveStatus()
                    publishStatus(revision, error.localizedDescription, eligible: {
                        !Task.isCancelled && self.poweredOn && self.owners[id] === current && current.phase == .connected &&
                        self.linkChannels[id] === channel && current.identityRevision === handshakeRevision
                    })
                    guard poweredOn else { observeManagerUnavailable(); return }
                    guard !Task.isCancelled, poweredOn, owners[id] === current, current.phase == .connected,
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
        if linkChannels[id] != nil, linkPhysicalEndpoints[id]?.values.contains(where: { $0 === characteristic }) == true {
            return .link
        }
        return .unknown
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        let source = notificationSource(id, characteristic: characteristic, notifying: characteristic.isNotifying)
        dispatchNotification(id, physical: peripheral, source: source, endpoint: characteristic, notifying: characteristic.isNotifying, error: error)
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
            $0.linkIdentity = deviceID.lowercased(); $0.linkDeviceID = deviceID
            $0.linkTools = names.filter { !Self.isReservedTaskTool($0) }
            $0.linkToolDescriptors = ordinaryTools; $0.linkState += " · PDSH Tools v1"
            if self.trustConnectedDevices {
                // Connecting is the trust decision: every advertised tool except the user's revocations.
                $0.grantedTools = Set($0.linkTools).subtracting(self.trustMemory.revoked(for: deviceID))
                self.trustMemory.rememberBoard(id, name: $0.name)
            }
        }
    }
    public func grantLinkTool(_ id: UUID, name: String, enabled: Bool) {
        guard poweredOn, let current = owners[id], current.phase == .connected else { return }
        guard linkBusy[id] == nil else {
            let busy = linkBusy[id], revision = reserveStatus()
            publishStatus(revision, "请等待当前设备操作结束，或断开连接", eligible: {
                self.poweredOn && self.owners[id] === current && current.phase == .connected && self.linkBusy[id] === busy
            })
            if !poweredOn { observeManagerUnavailable() }
            return
        }
        // These are host control-plane operations, never model device skills.
        guard !Self.isReservedTaskTool(name) else { return }
        update(id) {
            guard self.owners[id] === current, current.phase == .connected else { return }
            let allowed = enabled && $0.linkTools.contains(name)
            if allowed { $0.grantedTools.insert(name) } else { $0.grantedTools.remove(name) }
            if self.trustConnectedDevices, !$0.linkIdentity.isEmpty {
                self.trustMemory.setRevoked(name, !allowed, for: $0.linkIdentity)
            }
        }
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

    /// GAP-16 requires BLE task grants to remain unavailable until the
    /// secure-session-v2 acceptance (spec §14) is recorded. Every build of
    /// this package refuses: nothing defines PDSH_ENABLE_DEVICE_TASKS for the
    /// package (Package.swift does not, and the identity UI harness defines it
    /// only for its app target). Even under the flag the plaintext Link grant
    /// stays off (§11.2); only a live secure connection generation of the
    /// selected record may be admitted. Revocation remains available.
    public func grantDeviceTasks(_ id: UUID, enabled: Bool) throws {
        if enabled {
            update(id) { $0.allowDeviceTasks = false }
            #if PDSH_ENABLE_DEVICE_TASKS
            guard poweredOn, let current = owners[id], current.phase == .connected,
                  let lease = current.secureLease, lease.isValid, !current.secureUnavailable else {
                throw BLEFailure("安全会话未就绪，不能授权蓝牙设备派任务")
            }
            current.secureGrantAdmitted = lease
            return
            #else
            throw BLEFailure("设备身份认证尚未完成验证，暂不能授权蓝牙设备派任务")
            #endif
        }
        update(id) { $0.allowDeviceTasks = false }
        owners[id]?.secureGrantAdmitted = nil
        if linkBusy[id] != nil { disconnect(id) }
    }

    /// True only after `grantDeviceTasks(id, enabled: true)` admitted this
    /// exact, still-valid connection generation.
    public func secureGrantAdmitted(_ id: UUID, lease: BLESecureLease) -> Bool {
        guard poweredOn, let current = owners[id], current.phase == .connected, lease.isValid else { return false }
        return current.secureLease === lease && current.secureGrantAdmitted === lease
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
    /// Atomically claims this device's single Link slot. `callLinkTool` and
    /// `queryLinkTool` take it *before* writing the journal intent
    /// (ble-link.md「Link 调用准入」 rule 1); device tasks and grant changes see
    /// the same `linkBusy` slot. Throws `LinkBusy` without touching the journal.
    func admitLink(_ id: UUID, origin: LinkCallOrigin = .agent) throws -> LinkAdmission {
        guard linkBusy[id] == nil else { throw LinkBusy() }
        let operation = LinkOperation(owner: owners[id], agentCancellable: origin == .agent)
        linkBusy[id] = operation
        return LinkAdmission(deviceID: id, operationID: operation.id)
    }

    /// Releases a held admission. The identity check guarantees a stale release
    /// can never clear a newer operation's reservation.
    func releaseLink(_ admission: LinkAdmission) {
        guard linkBusy[admission.deviceID]?.id == admission.operationID else { return }
        linkBusy[admission.deviceID] = nil
    }

    /// The invoke half of `invokeLink` for a caller that already holds `admission`.
    /// Authorization happened in the shared entry before the journal intent; the
    /// connection and submission guards stay exactly those of `invokeLink`.
    func invokeAdmittedLink(_ admission: LinkAdmission, requestID: UUID, name: String,
                            arguments: JSONValue, key: String) async throws -> JSONValue {
        guard linkBusy[admission.deviceID]?.id == admission.operationID,
              let client = linkClients[admission.deviceID] else { throw BLEFailure("Link is busy") }
        guard let current = owners[admission.deviceID], current.phase == .connected, poweredOn else { throw BLEFailure("Link disconnected") }
        guard submitConnected(admission.deviceID, current: current, action: .link, physical: {}) else { throw BLEFailure("Link disconnected") }
        return try await client.invoke(requestID: requestID, name: name, arguments: arguments, idempotencyKey: key)
    }

    /// The query half of `queryLink` for a caller that already holds `admission`.
    func queryAdmittedLink(_ admission: LinkAdmission, requestID: UUID) async throws -> JSONValue? {
        guard linkBusy[admission.deviceID]?.id == admission.operationID,
              let client = linkClients[admission.deviceID] else { throw BLEFailure("Link is busy") }
        guard let current = owners[admission.deviceID], current.phase == .connected, poweredOn else { throw BLEFailure("Link disconnected") }
        guard submitConnected(admission.deviceID, current: current, action: .link, physical: {}) else { throw BLEFailure("Link disconnected") }
        return try await client.query(requestID: requestID)
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
    /// Agent-side cancellation (turn stop, MCP `notifications/cancelled`). It
    /// disconnects devices whose Link slot is held by the Agent or a device
    /// task, as before; a user-origin panel call keeps running.
    public func cancelLinkOperations() {
        for (id, operation) in Array(linkBusy) where operation.agentCancellable && owners[id] === operation.owner { disconnect(id) }
    }

}

/// A held per-device Link admission. The shared entry takes it before the
/// journal intent and releases it after the call/query finishes.
struct LinkAdmission: Sendable {
    let deviceID: UUID
    let operationID: UUID
}

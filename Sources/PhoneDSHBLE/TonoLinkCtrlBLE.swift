// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: CoreBluetooth client for the TonoLink BLE ctrl
// service (`cmd` write-with-response, `status` notify, `ota_data` write
// without response): enables USB NCM for the USB OTA and carries the BLE
// console, log and OTA (`TonoLinkBLEDebug`). All characteristics require an
// encrypted (bonded) link; the board is normally already paired as the
// iPhone's HID accessory.
import CoreBluetooth
import Foundation

@MainActor public final class TonoLinkCtrlBLE: NSObject, TonoLinkBLEDebugLink, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    /// Advertised-name prefix used when no connected ctrl peripheral is found
    /// (boards advertise as `PhoneAgent-<suffix>`).
    public var nameHint: String
    /// The board's CoreBluetooth identifier, kept so the reconnect after the
    /// OTA reboot targets the same board.
    public private(set) var peripheralID: UUID?
    public private(set) var peripheralName: String?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var cmd: CBCharacteristic?
    private var status: CBCharacteristic?
    private var ready: CheckedContinuation<Void, Error>?
    private var powered: [CheckedContinuation<Void, Error>] = []
    private var otaData: CBCharacteristic?
    private var audio: CBCharacteristic?
    /// Opus packets of a `listen` turn (`audio` notify, F0A3): `[seq u16 LE][flags][listen id][Opus]`.
    /// Subscribed only once this is set before `connect`, so OTA/debug links never receive audio.
    public var onAudio: ((Data) -> Void)?
    public var isAudioSubscribed: Bool { audio?.isNotifying == true }
    private var pending: (seq: UInt16, lines: [TonoLinkCtrlLine], continuation: CheckedContinuation<TonoLinkCtrlReply, Error>)?
    private var writable: CheckedContinuation<Void, Error>?
    /// Notifications that answer no pending request (`ota at`, `ota err`, `st …`).
    public var onLine: ((TonoLinkCtrlLine) -> Void)?
    /// Each time `status` notifications (re)start, including after a reconnect or a restore.
    public var onReady: (() -> Void)?

    /// A long-lived link (the voice turn, tonolink-board.md §4.1): CoreBluetooth state
    /// restoration under this identifier, and after a drop or a connect timeout a parked
    /// `connect()` that iOS keeps while the app is suspended and that wakes it when the
    /// board advertises again. Requires the `bluetooth-central` background mode.
    public let restoreIdentifier: String?
    public var staysConnected: Bool { restoreIdentifier != nil }

    public init(nameHint: String = "PhoneAgent", peripheralID: UUID? = nil, restoreIdentifier: String? = nil) {
        self.nameHint = nameHint
        self.peripheralID = peripheralID
        self.restoreIdentifier = restoreIdentifier
        super.init()
    }

    public var isConnected: Bool { peripheral?.state == .connected && status?.isNotifying == true }

    public func connect(timeout: Duration) async throws {
        if isConnected { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.failConnect(TonoLinkUSBOTAError("Bluetooth: board not found or not ready within \(timeout)"))
        }
        defer { timer.cancel() }
        try await poweredOn()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready = continuation
            locate()
        }
    }

    public func command(_ line: Data, seq: UInt16, timeout: Duration) async throws -> TonoLinkCtrlAck {
        try await request(line, seq: seq, timeout: timeout).ack
    }

    /// Writes one line and collects every `<seq> …` reply line until the ack.
    public func request(_ line: Data, seq: UInt16, timeout: Duration) async throws -> TonoLinkCtrlReply {
        guard let peripheral, let cmd, isConnected, pending == nil else { throw TonoLinkUSBOTAError("Bluetooth ctrl not ready") }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            self.failCommand(TonoLinkUSBOTAError("Bluetooth: no ack for ctrl command \(seq)"))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending = (seq, [], continuation)
            peripheral.writeValue(line, for: cmd, type: .withResponse)
        }
    }

    /// Maximum `ota_data` write, or nil when the board has no `ota_data` (GATT layout < 4).
    public var otaWriteLimit: Int? {
        guard let peripheral, otaData != nil else { return nil }
        return peripheral.maximumWriteValueLength(for: .withoutResponse)
    }

    /// Queues one `ota_data` packet, waiting while CoreBluetooth's buffer is full.
    public func writeOTA(_ packet: Data) async throws {
        guard let peripheral, let otaData, isConnected else { throw TonoLinkUSBOTAError("Bluetooth ota_data not ready") }
        if !peripheral.canSendWriteWithoutResponse {
            try await withCheckedThrowingContinuation { writable = $0 }
        }
        peripheral.writeValue(packet, for: otaData, type: .withoutResponse)
    }

    public func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset(TonoLinkUSBOTAError("Bluetooth disconnected"))
    }

    // MARK: - Connection

    private func poweredOn() async throws {
        if central == nil {
            let options = restoreIdentifier.map { [CBCentralManagerOptionRestoreIdentifierKey: $0] }
            central = CBCentralManager(delegate: self, queue: .main, options: options)
        }
        switch central?.state {
        case .poweredOn: return
        case .unauthorized: throw TonoLinkUSBOTAError("Bluetooth permission denied")
        case .unsupported, .poweredOff: throw TonoLinkUSBOTAError("Bluetooth is off or unsupported")
        default: try await withCheckedThrowingContinuation { powered.append($0) }
        }
    }

    private func locate() {
        guard let central else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: TonoLinkCtrlService.service)])
        if let match = connected.first(where: { peripheralID != nil ? $0.identifier == peripheralID : matches($0.name) }) {
            open(match); return
        }
        // A long-lived link parks a connect to the known board instead of scanning
        // (a background scan without service filters finds nothing).
        if staysConnected, let id = peripheralID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            open(known); return
        }
        // Not connected (e.g. rebooting after the OTA): scan. A pending connect
        // to a remembered identifier would wait forever if it never advertises.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func matches(_ name: String?) -> Bool {
        guard let name, !nameHint.isEmpty else { return false }
        return name.hasPrefix(nameHint)
    }

    private func open(_ target: CBPeripheral) {
        central?.stopScan()
        peripheral = target
        peripheralID = target.identifier
        peripheralName = target.name
        target.delegate = self
        if target.state == .connected { target.discoverServices([CBUUID(string: TonoLinkCtrlService.service)]) }
        else { central?.connect(target) }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let waiters = powered; powered = []
        switch central.state {
        case .poweredOn:
            waiters.forEach { $0.resume() }
            // Restored or parked link: pick it up again once Bluetooth is on.
            if staysConnected, let peripheral, status == nil {
                if peripheral.state == .connected { peripheral.discoverServices([CBUUID(string: TonoLinkCtrlService.service)]) }
                else { central.connect(peripheral) }
            }
        case .unknown, .resetting: powered = waiters
        default:
            waiters.forEach { $0.resume(throwing: TonoLinkUSBOTAError("Bluetooth unavailable (state \(central.state.rawValue))")) }
            if staysConnected { drop(TonoLinkUSBOTAError("Bluetooth unavailable")) } else { reset(TonoLinkUSBOTAError("Bluetooth unavailable")) }
        }
    }

    /// State restoration (relaunched in the background by iOS): adopt the restored board.
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let match = restored.first(where: { peripheralID != nil ? $0.identifier == peripheralID : matches($0.name) }) else { return }
        peripheral = match
        peripheralID = match.identifier
        peripheralName = match.name
        match.delegate = self
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard ready != nil, self.peripheral == nil else { return }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        if peripheralID != nil ? peripheral.identifier == peripheralID : (services.contains(CBUUID(string: TonoLinkCtrlService.service)) && matches(name)) {
            open(peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: TonoLinkCtrlService.service)])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failConnect(error ?? TonoLinkUSBOTAError("Bluetooth connect failed"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        if staysConnected {
            drop(error ?? TonoLinkUSBOTAError("Bluetooth disconnected"))
            central.connect(peripheral)   // parked: no timeout, survives suspension, wakes us on advertise
            return
        }
        reset(error ?? TonoLinkUSBOTAError("Bluetooth disconnected"))
    }

    /// A long-lived link lost its characteristics but keeps its board for the parked connect.
    private func drop(_ error: Error) {
        cmd = nil; status = nil; otaData = nil; audio = nil
        failCommand(error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: TonoLinkCtrlService.service) }) else {
            failConnect(error ?? TonoLinkUSBOTAError("\(peripheral.name ?? "device") has no TonoLink ctrl service")); return
        }
        peripheral.discoverCharacteristics([TonoLinkCtrlService.cmd, TonoLinkCtrlService.status, TonoLinkBLEDebugService.otaData,
                                            TonoLinkCtrlService.audio].map { CBUUID(string: $0) }, for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let found = service.characteristics ?? []
        cmd = found.first { $0.uuid == CBUUID(string: TonoLinkCtrlService.cmd) }
        status = found.first { $0.uuid == CBUUID(string: TonoLinkCtrlService.status) }
        otaData = found.first { $0.uuid == CBUUID(string: TonoLinkBLEDebugService.otaData) && $0.properties.contains(.writeWithoutResponse) }
        audio = found.first { $0.uuid == CBUUID(string: TonoLinkCtrlService.audio) }
        guard let status, cmd != nil else { failConnect(error ?? TonoLinkUSBOTAError("ctrl characteristics missing")); return }
        // Subscribing requires encryption; iOS pairs here if the board is not bonded yet.
        peripheral.setNotifyValue(true, for: status)
        if onAudio != nil, let audio { peripheral.setNotifyValue(true, for: audio) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == CBUUID(string: TonoLinkCtrlService.status) else { return }
        if let error { failConnect(error); return }
        if characteristic.isNotifying { ready?.resume(); ready = nil; onReady?() }
    }

    // MARK: - Commands

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failCommand(error) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == CBUUID(string: TonoLinkCtrlService.audio) {
            if let value = characteristic.value { onAudio?(value) }
            return
        }
        guard characteristic.uuid == CBUUID(string: TonoLinkCtrlService.status), let value = characteristic.value else { return }
        let line = TonoLinkCtrlLine.parse(value)
        guard var request = pending, line.seq == request.seq else { onLine?(line); return }
        if case .ack(let ack) = line {
            pending = nil
            request.continuation.resume(returning: TonoLinkCtrlReply(ack: ack, lines: request.lines))
        } else {
            request.lines.append(line)
            pending = request
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let waiter = writable; writable = nil
        waiter?.resume()
    }

    /// Service Changed (GATT layout bump after an OTA): rediscover.
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == CBUUID(string: TonoLinkCtrlService.service) }) else { return }
        cmd = nil; status = nil; otaData = nil; audio = nil
        peripheral.discoverServices([CBUUID(string: TonoLinkCtrlService.service)])
    }

    private func failConnect(_ error: Error) {
        guard let waiter = ready else { return }
        ready = nil
        central?.stopScan()
        if staysConnected, peripheral != nil {
            // Keep the parked connect: the board is out of range or rebooting, iOS finishes it later.
            waiter.resume(throwing: error)
            return
        }
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; cmd = nil; status = nil; otaData = nil; audio = nil
        waiter.resume(throwing: error)
    }

    private func failCommand(_ error: Error) {
        let request = pending; pending = nil
        request?.continuation.resume(throwing: error)
        let waiter = writable; writable = nil
        waiter?.resume(throwing: error)
    }

    private func reset(_ error: Error) {
        central?.stopScan()
        peripheral = nil; cmd = nil; status = nil; otaData = nil; audio = nil
        failConnect(error)
        failCommand(error)
    }
}

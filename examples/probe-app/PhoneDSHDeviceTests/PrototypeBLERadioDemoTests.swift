// SPDX-License-Identifier: MIT
// TEST-ONLY: controlled, manually paired Mac reference peer. This bypasses the
// production device store solely to exercise the current target contract; it
// does not authenticate arbitrary BLE peripherals or enable product UI.
import CoreBluetooth
import Foundation
import XCTest
import PhoneDSHDeviceTasks
import PhoneDSHAgentCore
@testable import PhoneDSHBLE
@testable import PhoneDSHProbe

@MainActor private final class PrototypeBLECentral: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var manager: CBCentralManager!
    var peripheral: CBPeripheral?
    var channel: BLELinkChannel?
    var error: String?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var audio: CBCharacteristic?
    override init() { super.init(); manager = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { central.scanForPeripherals(withServices: [CBUUID(string: PDSHLink.service)]) }
        else if central.state == .unauthorized || central.state == .poweredOff { error = "Bluetooth unavailable: \(central.state.rawValue)" }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil, (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name) == "PDSHRT" else { return }
        self.peripheral = peripheral; central.stopScan(); peripheral.delegate = self; central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: PDSHLink.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { self.error = "connect: \(String(describing: error))" }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        channel?.fail(BLEFailure("fixture disconnected")); self.error = "disconnect: \(String(describing: error))"
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { self.error = "services: \(error)"; return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: PDSHLink.service) }) else { self.error = "missing Link service"; return }
        peripheral.discoverCharacteristics([PDSHLink.rx, PDSHLink.tx, PDSHLink.audioUp].map { CBUUID(string: $0) }, for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { self.error = "characteristics: \(error)"; return }
        for c in service.characteristics ?? [] {
            if c.uuid == CBUUID(string: PDSHLink.rx) { rx = c }
            if c.uuid == CBUUID(string: PDSHLink.tx) { tx = c }
            if c.uuid == CBUUID(string: PDSHLink.audioUp) { audio = c }
        }
        guard let rx, let tx, let audio, rx.properties.contains(.write), tx.properties.contains(.notify), audio.properties.contains(.notify) else { self.error = "missing Link characteristics"; return }
        channel = BLELinkChannel(peripheral: peripheral, rx: rx, tx: tx, audio: audio)
        peripheral.setNotifyValue(true, for: tx); peripheral.setNotifyValue(true, for: audio)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) { if let error { self.error = "subscribe: \(error)" } }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) { channel?.didWrite(characteristic, error: error) }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) { channel?.receive(characteristic, error: error) }
    func stop() { manager.stopScan(); if let peripheral { manager.cancelPeripheralConnection(peripheral) } }
}

@MainActor private final class PrototypeBLEInbox: BLETaskLinkInbox {
    let client: PDSHLinkClient
    init(_ client: PDSHLinkClient) { self.client = client }
    func next() async throws -> DeviceTask? {
        let id = UUID()
        let value = try await client.invoke(requestID: id, name: "pdsh.task.next", arguments: .object([:]), idempotencyKey: UUID().uuidString.lowercased())
        guard value["request_id"]?.stringValue == id.uuidString.lowercased(), value["status"]?.stringValue == "completed", let item = value["result"]?["task"] else { throw BLEFailure("invalid task result") }
        if item == .null { return nil }
        return try DeviceTask.decode(item.encoded())
    }
    func invokeOrQuery(requestID: UUID, name: String, arguments: JSONValue, idempotencyKey: String, fresh: Bool) async throws -> JSONValue {
        if fresh { return try await client.invoke(requestID: requestID, name: name, arguments: arguments, idempotencyKey: idempotencyKey) }
        guard let value = try await client.query(requestID: requestID) else { throw BLEFailure("pending") }
        return value
    }
}

@MainActor final class PrototypeBLERadioDemoTests: XCTestCase {
    func testMacBluetoothReferenceDeviceDispatchesRealModelTask() async throws {
        guard ProcessInfo.processInfo.environment["PDSH_TEST_BLE_PROTOTYPE"] == "1" else { throw XCTSkip("controlled BLE prototype fixture not supplied") }
        let fixture = PrototypeBLECentral(); defer { fixture.stop() }
        for _ in 0..<600 {
            if fixture.channel?.tx?.isNotifying == true && fixture.channel?.audio?.isNotifying == true { break }
            if let error = fixture.error { throw BLEFailure(error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let channel = try XCTUnwrap(fixture.channel, "paired test fixture not found")
        XCTAssertTrue(channel.tx?.isNotifying == true && channel.audio?.isNotifying == true, "fixture not subscribed")
        let client = PDSHLinkClient(transport: channel, allowTaskProfile: true)
        _ = try await client.handshake()
        let listed = try await client.invoke(requestID: UUID(), name: "tools/list", arguments: .object([:]), idempotencyKey: UUID().uuidString.lowercased())
        let deviceID = try XCTUnwrap(listed["result"]?["device_id"]?.stringValue)
        guard deviceID.lowercased() == "42424242-4242-4242-8242-424242424242" else {
            return XCTFail("unexpected test fixture device ID")
        }
        let inbox = PrototypeBLEInbox(client)
        let received = try await inbox.next()
        let task = try XCTUnwrap(received)
        guard task.id == "task-1", task.idempotencyKey == "goal-1", task.body.text == "Hello from device" else {
            return XCTFail("unexpected test fixture task")
        }
        print("PDSH_BLE_DEMO_TASK: \(task.body.text)")
        let chat = ChatModel.shared
        for _ in 0..<100 { if chat.anchor.isInWindow { break }; try await Task.sleep(for: .milliseconds(200)) }
        for _ in 0..<100 { if chat.isStarted { break }; await chat.start(); if chat.isStarted { break }; try await Task.sleep(for: .milliseconds(200)) }
        let runner = DeviceDSHRunner(transport: try await chat.transportForManagement())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdsh-demo-ble-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = try DeviceTaskExecutor(directory: directory, runner: runner)
        try await executor.process(deviceID: "ble:" + deviceID, task: task, authorized: true, inbox: inbox)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let records = files.compactMap { url -> DeviceTaskRecord? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(DeviceTaskRecord.self, from: data)
        }
        let record = try XCTUnwrap(records.first(where: { $0.task.id == task.id }))
        guard case let .completed(output, _) = record.outcome else { return XCTFail("model task did not complete") }
        XCTAssertFalse(output.isEmpty)
        print("PDSH_BLE_DEMO_OUTPUT: \(output)")
        let remaining = try await inbox.next()
        XCTAssertNil(remaining, "reference device did not receive terminal result")
    }
}

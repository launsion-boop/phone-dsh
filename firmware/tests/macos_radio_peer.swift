// SPDX-License-Identifier: MIT
// macOS-only test peer: real CoreBluetooth radio backed by the C test firmware.
// Not a production peripheral; state and task contents are test fixtures.
import Foundation
import CoreBluetooth

final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    let serviceID = CBUUID(string: "6e400100-7f1b-4c5a-9a1e-786c696e6b00")
    let rxID = CBUUID(string: "6e400101-7f1b-4c5a-9a1e-786c696e6b00")
    let txID = CBUUID(string: "6e400102-7f1b-4c5a-9a1e-786c696e6b00")
    let audioID = CBUUID(string: "6e400103-7f1b-4c5a-9a1e-786c696e6b00")
    var manager: CBPeripheralManager!
    var tx: CBMutableCharacteristic!
    var assembly = pdsh_reassembly_t()
    var outgoing: [Data] = []
    private var resultBuffer = Data()
    private var observedTask: String?
    let process = Process(), input = Pipe(), output = Pipe()
    override init() {
        super.init()
        // This is the dedicated demo artifact, never a general deletion path.
        // Remove stale success before advertising a fresh test fixture.
        if ProcessInfo.processInfo.environment["PDSH_TEST_BLE_DEMO_RESULT"] == "/tmp/pdsh-prototype-ble-result.json" {
            try? FileManager.default.removeItem(atPath: "/tmp/pdsh-prototype-ble-result.json")
        }
        guard let bridge = ProcessInfo.processInfo.environment["PDSH_TEST_BRIDGE"], !bridge.isEmpty else {
            print("PDSH_TEST_BRIDGE is required"); exit(1)
        }
        process.executableURL = URL(fileURLWithPath: bridge)
        process.standardInput = input; process.standardOutput = output
        do { try process.run() } catch { print("bridge failed: \(error)"); exit(1) }
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("bluetooth state \(peripheral.state.rawValue)"); fflush(stdout)
        guard peripheral.state == .poweredOn else { return }
        // Explicit negative-test mode: never use this peer for real traffic.
        let insecure = ProcessInfo.processInfo.environment["PDSH_TEST_INSECURE"] == "1"
        if insecure && ProcessInfo.processInfo.environment["PDSH_TEST_BLE_DEMO_RESULT"] != nil {
            print("refusing to publish demo evidence from an insecure fixture"); fflush(stdout); return
        }
        let rx = CBMutableCharacteristic(type: rxID, properties: [.write], value: nil,
                                         permissions: insecure ? [.writeable] : [.writeEncryptionRequired])
        let notifyProperties: CBCharacteristicProperties = insecure ? [.notify] : [.notify, .notifyEncryptionRequired]
        let notifyPermissions: CBAttributePermissions = insecure ? [.readable] : [.readEncryptionRequired]
        tx = CBMutableCharacteristic(type: txID, properties: notifyProperties, value: nil, permissions: notifyPermissions)
        let audio = CBMutableCharacteristic(type: audioID, properties: notifyProperties, value: nil, permissions: notifyPermissions)
        let service = CBMutableService(type: serviceID, primary: true); service.characteristics = [rx, tx, audio]
        peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { print("add error \(error)"); fflush(stdout); return }
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: "PDSHRT", CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        print("advertising \(error.map(String.init(describing:)) ?? "ok")"); fflush(stdout)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("subscribed \(characteristic.uuid)"); fflush(stdout)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == rxID, let data = request.value else { peripheral.respond(to: request, withResult: .requestNotSupported); continue }
            let state = data.withUnsafeBytes { bytes in pdsh_segment(&assembly, bytes.bindMemory(to: UInt8.self).baseAddress, data.count) }
            guard state >= 0 else { peripheral.respond(to: request, withResult: .invalidAttributeValueLength); continue }
            peripheral.respond(to: request, withResult: .success)
            if state == 1 { handleFrame() }
        }
    }
    func handleFrame() {
        var op: UInt8 = 0; var id: UInt16 = 0; var body: UnsafePointer<UInt8>?; var length = 0
        var answerBytes: [UInt8] = []
        let frameLength = assembly.len
        let response: Data? = withUnsafePointer(to: &assembly.data) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: 512) { bytes in
                guard pdsh_decode(bytes, frameLength, &op, &id, &body, &length) == 0, let body else { return nil }
                let hex = (0..<length).map { String(format: "%02x", body[$0]) }.joined()
                do { try input.fileHandleForWriting.write(contentsOf: Data("\(op) \(hex)\n".utf8)) } catch { return nil }
                var line = Data()
                while let byte = output.fileHandleForReading.readData(ofLength: 1).first, byte != 10 { line.append(byte) }
                guard let text = String(data: line, encoding: .utf8), text.count % 2 == 0 else { return nil }
                var answer = [UInt8](); var pos = text.startIndex
                while pos < text.endIndex { let end = text.index(pos, offsetBy: 2); guard let b = UInt8(text[pos..<end], radix: 16) else { return nil }; answer.append(b); pos = end }
                answerBytes = answer
                var framed = [UInt8](repeating: 0, count: 512)
                let n = pdsh_frame(op | 0x80, id, answer, answer.count, &framed)
                return n > 0 ? Data(framed.prefix(n)) : nil
            }
        }
        guard let response else { print("bad frame"); fflush(stdout); return }
        if op == 0x56 { observeResultChunk(answerBytes) }
        if (op == 0x55 || op == 0x56), observedTask != nil { writeTerminalEvidence() }
        let bytes = [UInt8](response), count = bytes.count
        for offset in stride(from: 0, to: count, by: 19) {
            let end = min(offset + 19, count)
            outgoing.append(Data([UInt8((offset == 0 ? 2 : 0) | (end == count ? 1 : 0))] + bytes[offset..<end]))
        }
        print("reply op=\(op) id=\(id) bytes=\(count)"); fflush(stdout)
        flush()
    }
    // Test evidence is derived from the actual Link result and the C device's
    // local result accessor; no phone journal or fabricated result is used.
    private func observeResultChunk(_ answer: [UInt8]) {
        guard answer.count >= 6, answer[0] == 0, answer[1] == 2 else { return }
        let total = Int(answer[2]) | Int(answer[3]) << 8
        let offset = Int(answer[4]) | Int(answer[5]) << 8
        guard total > 0, total <= 4096 else { resultBuffer.removeAll(); return }
        if offset == 0 { resultBuffer.removeAll(keepingCapacity: true) }
        guard resultBuffer.count == offset, offset + answer.count - 6 <= total else { resultBuffer.removeAll(); return }
        resultBuffer.append(contentsOf: answer.dropFirst(6))
        guard resultBuffer.count == total,
              let object = try? JSONSerialization.jsonObject(with: resultBuffer) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let task = result["task"] as? [String: Any],
              let body = task["body"] as? [String: Any], let text = body["text"] as? String else { return }
        observedTask = text
    }
    private func writeTerminalEvidence() {
        guard let task = observedTask, task == "Hello from device",
              let path = ProcessInfo.processInfo.environment["PDSH_TEST_BLE_DEMO_RESULT"], !path.isEmpty else { return }
        do { try input.fileHandleForWriting.write(contentsOf: Data("254\n".utf8)) } catch { return }
        var line = Data()
        while let byte = output.fileHandleForReading.readData(ofLength: 1).first, byte != 10 { line.append(byte) }
        guard let hex = String(data: line, encoding: .utf8), hex.count % 2 == 0 else { return }
        var bytes = [UInt8](), cursor = hex.startIndex
        while cursor < hex.endIndex {
            let end = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<end], radix: 16) else { return }
            bytes.append(byte); cursor = end
        }
        guard let state = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              state["phase"] as? String == "completed",
              let outcome = state["outcome"] as? [String: Any], let text = outcome["output"] as? String else { return }
        let evidence: [String: Any] = ["transport": "ble", "device": "PDSHRT",
                                       "task": task, "phase": "completed", "output": text]
        guard let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) else { return }
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { print("terminal evidence write failed: \(error)"); fflush(stdout) }
    }
    func flush() {
        while let item = outgoing.first {
            guard manager.updateValue(item, for: tx, onSubscribedCentrals: nil) else { return }
            outgoing.removeFirst()
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flush() }
}
let delegate = Peripheral()
RunLoop.main.run()

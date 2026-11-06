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
    let process = Process(), input = Pipe(), output = Pipe()
    override init() {
        super.init()
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
        let rx = CBMutableCharacteristic(type: rxID, properties: [.write], value: nil, permissions: [.writeEncryptionRequired])
        tx = CBMutableCharacteristic(type: txID, properties: [.notify, .notifyEncryptionRequired], value: nil, permissions: [.readEncryptionRequired])
        let audio = CBMutableCharacteristic(type: audioID, properties: [.notify, .notifyEncryptionRequired], value: nil, permissions: [.readEncryptionRequired])
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
        let response: Data? = withUnsafePointer(to: &assembly.data) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: 512) { bytes in
                guard pdsh_decode(bytes, assembly.len, &op, &id, &body, &length) == 0, let body else { return nil }
                let hex = (0..<length).map { String(format: "%02x", body[$0]) }.joined()
                do { try input.fileHandleForWriting.write(contentsOf: Data("\(op) \(hex)\n".utf8)) } catch { return nil }
                var line = Data()
                while let byte = output.fileHandleForReading.readData(ofLength: 1).first, byte != 10 { line.append(byte) }
                guard let text = String(data: line, encoding: .utf8), text.count % 2 == 0 else { return nil }
                var answer = [UInt8](); var pos = text.startIndex
                while pos < text.endIndex { let end = text.index(pos, offsetBy: 2); guard let b = UInt8(text[pos..<end], radix: 16) else { return nil }; answer.append(b); pos = end }
                var framed = [UInt8](repeating: 0, count: 512)
                let n = pdsh_frame(op | 0x80, id, answer, answer.count, &framed)
                return n > 0 ? Data(framed.prefix(n)) : nil
            }
        }
        guard let response else { print("bad frame"); fflush(stdout); return }
        let bytes = [UInt8](response), count = bytes.count
        for offset in stride(from: 0, to: count, by: 19) {
            let end = min(offset + 19, count)
            outgoing.append(Data([UInt8((offset == 0 ? 2 : 0) | (end == count ? 1 : 0))] + bytes[offset..<end]))
        }
        print("reply op=\(op) id=\(id) bytes=\(count)"); fflush(stdout)
        flush()
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

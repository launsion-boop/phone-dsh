// SPDX-License-Identifier: MIT
// macOS virtual peripheral. All measurements are explicit synthetic test fixtures.
import Foundation
import CoreBluetooth

final class FixturePeripheral: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!
    private var remaining = 0
    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { print("Bluetooth state: \(peripheral.state.rawValue)"); return }
        let services: [(String, [(String, Data?)])] = [
            ("180F", [("2A19", Data([75]))]),
            ("181A", [("2A6E", Data([0xc4, 0x09])), ("2A6F", Data([0x88, 0x13]))]),
            ("180A", [("2A29", Data("PDSH Test Fixtures".utf8)), ("2A24", Data("VIRTUAL-NOT-A-SENSOR".utf8))]),
            ("1802", [("2A06", nil)]),
        ]
        remaining = services.count
        for (uuid, fields) in services {
            let service = CBMutableService(type: CBUUID(string: uuid), primary: true)
            service.characteristics = fields.map { characteristic, value in
                CBMutableCharacteristic(type: CBUUID(string: characteristic), properties: value == nil ? [.writeWithoutResponse] : [.read], value: value, permissions: value == nil ? [.writeable] : [.readable])
            }
            peripheral.add(service)
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { print("Add service failed: \(error)"); exit(1) }
        remaining -= 1
        if remaining == 0 {
            peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: "PDSH Virtual Fixture", CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "180F"), CBUUID(string: "1802")]])
        }
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        print(error.map { "Advertising failed: \($0)" } ?? "Advertising PDSH Virtual Fixture: battery=75%, temperature=25°C, humidity=50% (synthetic). Ctrl-C to stop.")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == CBUUID(string: "2A06"), request.offset == 0,
                  let data = request.value, data.count == 1, let level = data.first, level <= 2 else {
                peripheral.respond(to: request, withResult: .unlikelyError); continue
            }
            print("Immediate Alert level=\(level) (simulated, no physical actuator)")
            peripheral.respond(to: request, withResult: .success)
        }
    }
}
let fixture = FixturePeripheral()
RunLoop.main.run()

// SPDX-License-Identifier: MIT
import CoreBluetooth
import Foundation

@MainActor final class BLELinkChannel: PDSHLinkTransport {
    let peripheral: CBPeripheral
    let rx: CBCharacteristic
    let tx: CBCharacteristic
    let audio: CBCharacteristic
    var onFailure: (() -> Void)?
    var onEvent: ((Data) -> Void)?
    private var nextID: UInt32 = 1
    private var pending: (id: UInt16, opcode: UInt8, continuation: CheckedContinuation<Data, Error>)?
    private var packets: [Data] = []
    private var timer: Task<Void, Never>?
    private var reassembler = PDSHLink.Reassembler()
    init(peripheral: CBPeripheral, rx: CBCharacteristic, tx: CBCharacteristic, audio: CBCharacteristic) {
        self.peripheral = peripheral; self.rx = rx; self.tx = tx; self.audio = audio
    }
    func exchange(opcode: UInt8, body: Data) async throws -> Data {
        try Task.checkCancellation()
        guard pending == nil, peripheral.state == .connected, tx.isNotifying, audio.isNotifying, nextID <= 65535 else { throw BLEFailure("Link unavailable or busy") }
        let id = UInt16(nextID); nextID += 1
        let segments = try PDSHLink.Envelope(opcode: opcode, requestID: id, body: body).segments(writeLimit: peripheral.maximumWriteValueLength(for: .withResponse))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (id, opcode, continuation); packets = segments
                timer = Task {
                    try? await Task.sleep(for: .seconds(3)); guard !Task.isCancelled, pending?.id == id else { return }
                    fail(BLEFailure("outcome_unknown: Link response timed out; query result after reconnect")); onFailure?()
                }
                writeNext()
            }
        } onCancel: {
            Task { @MainActor in
                guard self.pending?.id == id else { return }
                self.fail(CancellationError()); self.onFailure?()
            }
        }
    }
    private func writeNext() {
        guard !packets.isEmpty else { return }
        peripheral.writeValue(packets.removeFirst(), for: rx, type: .withResponse)
    }
    func didWrite(_ characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === rx else { return }
        if let error { fail(error); onFailure?() } else { writeNext() }
    }
    func receive(_ characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === tx else { return }
        if let error { fail(error); onFailure?(); return }
        do {
            guard let envelope = try reassembler.push(characteristic.value ?? Data()) else { return }
            if envelope.opcode == 0x6c, envelope.requestID == 0 { onEvent?(envelope.body); return }
            guard let operation = pending, envelope.requestID == operation.id else { return }
            if envelope.opcode == 0xff { fail(BLEFailure("Link NAK: \(envelope.body.map(String.init).joined(separator: ","))")); return }
            guard envelope.opcode == operation.opcode | 0x80 else { return }
            pending = nil; packets = []; timer?.cancel(); timer = nil
            operation.continuation.resume(returning: envelope.body)
        } catch { fail(error); onFailure?() }
    }
    func fail(_ error: Error) {
        let continuation = pending?.continuation; pending = nil; packets = []; timer?.cancel(); timer = nil; reassembler.reset()
        continuation?.resume(throwing: error)
    }
}

// SPDX-License-Identifier: MIT
// BLESecureByteStream over a CoreBluetooth LE credit-based L2CAP channel
// (§5). The stream pair is scheduled on the main run loop; writes are queued
// and drained in order as space becomes available. Not exercised without a
// radio: no device test has been run against it.
import CoreBluetooth
import Foundation

public final class BLESecureL2CAPStream: NSObject, BLESecureByteStream, StreamDelegate, @unchecked Sendable {
    private let channel: CBL2CAPChannel
    private let lock = NSLock()
    private var pendingWrite: [UInt8] = []
    private var received: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8]?, Error>?
    private var closed = false

    /// Opens the channel's streams on the main run loop.
    public init(channel: CBL2CAPChannel) {
        self.channel = channel
        super.init()
        DispatchQueue.main.async {
            for stream in [channel.inputStream as Stream?, channel.outputStream as Stream?].compactMap({ $0 }) {
                stream.delegate = self
                stream.schedule(in: .main, forMode: .default)
                stream.open()
            }
        }
    }

    public var psm: CBL2CAPPSM { channel.psm }

    public func write(_ bytes: [UInt8]) throws {
        lock.lock()
        guard !closed else { lock.unlock(); throw BLEFailure("secure channel closed") }
        pendingWrite += bytes
        lock.unlock()
        DispatchQueue.main.async { self.drain() }
    }

    public func read() async throws -> [UInt8]? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !received.isEmpty { let next = received.removeFirst(); lock.unlock(); continuation.resume(returning: next); return }
            if closed { lock.unlock(); continuation.resume(returning: nil); return }
            waiter = continuation
            lock.unlock()
        }
    }

    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        pendingWrite = []
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
        DispatchQueue.main.async {
            for stream in [self.channel.inputStream as Stream?, self.channel.outputStream as Stream?].compactMap({ $0 }) {
                stream.close()
                stream.remove(from: .main, forMode: .default)
                stream.delegate = nil
            }
        }
    }

    /// Main run loop only. A short write keeps the unwritten tail queued; bytes
    /// are never re-sent.
    private func drain() {
        guard let output = channel.outputStream as OutputStream? else { return }
        while output.hasSpaceAvailable {
            lock.lock()
            guard !closed, !pendingWrite.isEmpty else { lock.unlock(); return }
            let chunk = Array(pendingWrite.prefix(4096))
            lock.unlock()
            let written = chunk.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            guard written > 0 else { if written < 0 { close() }; return }
            lock.lock()
            pendingWrite.removeFirst(min(written, pendingWrite.count))
            lock.unlock()
        }
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasSpaceAvailable: drain()
        case .hasBytesAvailable:
            guard let input = channel.inputStream as InputStream? else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let n = input.read(&buffer, maxLength: buffer.count)
                guard n > 0 else { if n < 0 { close() }; return }
                deliver(Array(buffer[0..<n]))
            }
        case .endEncountered, .errorOccurred: close()
        default: break
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        lock.lock()
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: bytes); return }
        received.append(bytes)
        lock.unlock()
    }
}

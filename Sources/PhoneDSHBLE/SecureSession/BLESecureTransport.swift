// SPDX-License-Identifier: MIT
// The abstract byte stream the TLS session runs over (§5): an LE CoC in
// production, an in-memory pipe or a socket in tests. SDU boundaries carry no
// meaning.
import Foundation

public protocol BLESecureByteStream: AnyObject, Sendable {
    /// Queues bytes for transmission strictly in call order. Never blocks;
    /// throws once the stream is closed.
    func write(_ bytes: [UInt8]) throws
    /// The next received chunk, or nil at EOF / disconnect.
    func read() async throws -> [UInt8]?
    /// Closes both directions. Pending and later reads return nil.
    func close()
}

/// A bidirectional in-memory pipe (tests and cross-runtime harnesses).
public final class BLESecureMemoryPipe: @unchecked Sendable {
    public final class End: BLESecureByteStream, @unchecked Sendable {
        fileprivate weak var peer: End?
        private let lock = NSLock()
        private var queue: [[UInt8]] = []
        private var waiter: CheckedContinuation<[UInt8]?, Error>?
        private var closed = false
        private var peerClosed = false
        /// Every chunk this end wrote, in order (test evidence).
        public private(set) var written: [[UInt8]] = []

        public func write(_ bytes: [UInt8]) throws {
            lock.lock()
            guard !closed, !peerClosed, let peer else { lock.unlock(); throw BLEFailure("secure stream closed") }
            written.append(bytes)
            lock.unlock()
            if !bytes.isEmpty { peer.deliver(bytes) }
        }

        fileprivate func deliver(_ bytes: [UInt8]) {
            lock.lock()
            if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: bytes); return }
            queue.append(bytes)
            lock.unlock()
        }

        fileprivate func peerDidClose() {
            lock.lock()
            peerClosed = true
            let waiter = self.waiter; self.waiter = nil
            lock.unlock()
            waiter?.resume(returning: nil)
        }

        public func read() async throws -> [UInt8]? {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !queue.isEmpty { let next = queue.removeFirst(); lock.unlock(); continuation.resume(returning: next); return }
                if closed || peerClosed { lock.unlock(); continuation.resume(returning: nil); return }
                waiter = continuation
                lock.unlock()
            }
        }

        public func close() {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            closed = true; queue = []
            let waiter = self.waiter; self.waiter = nil
            let peer = self.peer
            lock.unlock()
            waiter?.resume(returning: nil)
            peer?.peerDidClose()
        }
    }

    public let client = End()
    public let server = End()

    public init() {
        client.peer = server
        server.peer = client
    }
}

/// §5: the PSM characteristic value is exactly 2 bytes, u16 little-endian, in
/// the dynamic LE range 0x0080...0x00FF. Anything else: no secure session on
/// this connection. The value is untrusted routing data and is never cached.
public enum BLESecureServiceProfile {
    public static let serviceUUID = "d04ea024-c7fd-4a52-9ace-cf9d7567d0e6"
    public static let psmCharacteristicUUID = "abdd3056-28fa-441d-a470-55a75a52553a"
    public static let alpn = "pdsh-ble-task/1"

    public static func psm(fromCharacteristic value: [UInt8]) -> UInt16? {
        guard value.count == 2 else { return nil }
        let psm = UInt16(value[0]) | UInt16(value[1]) << 8
        return (0x0080...0x00FF).contains(psm) ? psm : nil
    }
}

// SPDX-License-Identifier: MIT
// BLESecureByteStream over a CoreBluetooth LE credit-based L2CAP channel
// (§5). Both directions are bounded: received bytes stop being pulled from
// the channel's input stream while the receive buffer is full (the OS then
// withholds L2CAP credits), and a write that would exceed the send buffer
// closes the stream instead of growing it. Any stream error, EOF, overflow or
// owner teardown (disconnect, service change, generation end) closes both
// directions; later reads return nil and later writes throw. Bytes are never
// re-sent. The CoreBluetooth half is not exercised without a radio; the
// bounded core is tested through `BLESecureStreamIO` fakes.
import CoreBluetooth
import Foundation

/// The byte-pump side of a bounded secure stream. Main run loop only.
public protocol BLESecureStreamIO: AnyObject {
    var hasSpaceAvailable: Bool { get }
    var hasBytesAvailable: Bool { get }
    /// Writes up to `count` bytes; returns the number written, 0 for "no space
    /// now", or a negative value for a stream error.
    func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Int
    /// Reads up to `count` bytes; 0 is EOF, negative is an error.
    func read(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int
    func closeIO()
}

public final class BLESecureBoundedStream: BLESecureByteStream, @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        /// Received bytes buffered for the TLS reader before the pump stops
        /// pulling from the channel. Two maximum TLS records (§6.1 4352 + 256).
        public var receive: Int = 2 * (4352 + 256)
        /// Bytes queued for the channel. A write beyond it fails closed.
        public var send: Int = 4 * (4352 + 256)
        /// Largest single read/write against the channel.
        public var chunk: Int = 4096
        public init() {}
    }

    public enum CloseReason: String, Sendable, Equatable {
        case local, endOfStream = "end_of_stream", streamError = "stream_error"
        case sendOverflow = "send_overflow", owner
    }

    public let limits: Limits
    private let lock = NSLock()
    private weak var io: BLESecureStreamIO?
    private var pendingWrite: [UInt8] = []
    private var received: [[UInt8]] = []
    private var receivedBytes = 0
    private var waiter: CheckedContinuation<[UInt8]?, Error>?
    private var closedReason: CloseReason?
    /// Schedules work on the run loop that owns `io` (main in production).
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    /// Called once, after the stream closed, on the scheduling context.
    public var onClose: (@Sendable (CloseReason) -> Void)?

    public init(io: BLESecureStreamIO, limits: Limits = Limits(),
                schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }) {
        self.io = io
        self.limits = limits
        self.schedule = schedule
    }

    public var closeReason: CloseReason? { lock.lock(); defer { lock.unlock() }; return closedReason }
    public var isClosed: Bool { closeReason != nil }
    public var bufferedReceiveBytes: Int { lock.lock(); defer { lock.unlock() }; return receivedBytes }
    public var bufferedSendBytes: Int { lock.lock(); defer { lock.unlock() }; return pendingWrite.count }

    // MARK: BLESecureByteStream

    public func write(_ bytes: [UInt8]) throws {
        lock.lock()
        guard closedReason == nil else { lock.unlock(); throw BLEFailure("secure channel closed") }
        guard pendingWrite.count + bytes.count <= limits.send else {
            lock.unlock()
            finish(.sendOverflow)
            throw BLEFailure("secure channel send buffer full")
        }
        pendingWrite += bytes
        lock.unlock()
        schedule { [weak self] in self?.pump() }
    }

    public func read() async throws -> [UInt8]? {
        let chunk: [UInt8]? = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !received.isEmpty {
                let next = received.removeFirst()
                receivedBytes -= next.count
                lock.unlock()
                continuation.resume(returning: next)
                return
            }
            if closedReason != nil { lock.unlock(); continuation.resume(returning: nil); return }
            guard waiter == nil else { lock.unlock(); continuation.resume(throwing: BLEFailure("concurrent secure read")); return }
            waiter = continuation
            lock.unlock()
        }
        // Space was freed: resume pulling from the channel.
        if chunk != nil { schedule { [weak self] in self?.pump() } }
        return chunk
    }

    /// Local close (TLS close_notify or a fatal alert just written, §6.1,
    /// §8.4): bytes already queued by `write` are still handed to the channel
    /// in one bounded pass on the run loop that owns `io` (as far as it has
    /// space now, never waiting for credits), then the channel is closed.
    /// Nothing is queued or delivered after this call.
    public func close() { finish(.local, flushQueued: true) }

    /// Owner teardown (disconnect, service change, generation end).
    public func ownerClosed() { finish(.owner) }

    // MARK: pump (the run loop that owns `io`)

    /// Drains queued writes while the channel has space, then pulls received
    /// bytes while the receive buffer has room. A short write keeps the
    /// unwritten tail queued.
    public func pump() {
        guard let io else { finish(.streamError); return }
        while io.hasSpaceAvailable {
            lock.lock()
            guard closedReason == nil, !pendingWrite.isEmpty else { lock.unlock(); break }
            let chunk = Array(pendingWrite.prefix(limits.chunk))
            lock.unlock()
            let written = chunk.withUnsafeBufferPointer { io.write($0.baseAddress!, count: $0.count) }
            if written < 0 { finish(.streamError); return }
            if written == 0 { break }
            lock.lock()
            pendingWrite.removeFirst(min(written, pendingWrite.count))
            lock.unlock()
        }
        var buffer = [UInt8](repeating: 0, count: limits.chunk)
        while io.hasBytesAvailable {
            lock.lock()
            let room = limits.receive - receivedBytes
            let open = closedReason == nil
            lock.unlock()
            guard open, room > 0 else { return }
            let n = buffer.withUnsafeMutableBufferPointer { io.read($0.baseAddress!, count: min(room, $0.count)) }
            if n < 0 { finish(.streamError); return }
            if n == 0 { finish(.endOfStream); return }
            deliver(Array(buffer[0..<n]))
        }
    }

    public func endEncountered() { finish(.endOfStream) }
    public func errorOccurred() { finish(.streamError) }

    private func deliver(_ bytes: [UInt8]) {
        lock.lock()
        guard closedReason == nil else { lock.unlock(); return }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: bytes)
            return
        }
        received.append(bytes)
        receivedBytes += bytes.count
        lock.unlock()
    }

    private func finish(_ reason: CloseReason, flushQueued: Bool = false) {
        lock.lock()
        guard closedReason == nil else { lock.unlock(); return }
        closedReason = reason
        // Before the on-air run (2026-11-08) a local close discarded the
        // queued close_notify / alert: `write` only schedules the pump, so the
        // TLS client's final record never reached the CoC.
        let tail = flushQueued ? pendingWrite : []
        pendingWrite = []
        received = []
        receivedBytes = 0
        let waiter = self.waiter; self.waiter = nil
        let callback = onClose
        let chunk = limits.chunk
        lock.unlock()
        waiter?.resume(returning: nil)
        schedule { [weak self] in
            if let io = self?.io, !tail.isEmpty {
                var offset = 0
                while offset < tail.count, io.hasSpaceAvailable {
                    let part = Array(tail[offset..<min(tail.count, offset + chunk)])
                    let written = part.withUnsafeBufferPointer { io.write($0.baseAddress!, count: $0.count) }
                    if written <= 0 { break }
                    offset += written
                }
            }
            self?.io?.closeIO()
            callback?(reason)
        }
    }
}

/// The CoreBluetooth `CBL2CAPChannel` side of a bounded stream. The stream
/// pair is scheduled on the main run loop.
public final class BLESecureL2CAPStream: NSObject, BLESecureStreamIO, StreamDelegate, @unchecked Sendable {
    private let channel: CBL2CAPChannel
    public private(set) var stream: BLESecureBoundedStream!

    public init(channel: CBL2CAPChannel, limits: BLESecureBoundedStream.Limits = .init()) {
        self.channel = channel
        super.init()
        stream = BLESecureBoundedStream(io: self, limits: limits)
        DispatchQueue.main.async {
            for s in [channel.inputStream as Stream?, channel.outputStream as Stream?].compactMap({ $0 }) {
                s.delegate = self
                s.schedule(in: .main, forMode: .default)
                s.open()
            }
        }
    }

    public var psm: CBL2CAPPSM { channel.psm }
    public var peer: CBPeer { channel.peer }

    public var hasSpaceAvailable: Bool { channel.outputStream.hasSpaceAvailable }
    public var hasBytesAvailable: Bool { channel.inputStream.hasBytesAvailable }
    public func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Int { channel.outputStream.write(bytes, maxLength: count) }
    public func read(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int { channel.inputStream.read(buffer, maxLength: count) }

    public func closeIO() {
        for s in [channel.inputStream as Stream?, channel.outputStream as Stream?].compactMap({ $0 }) {
            s.close()
            s.remove(from: .main, forMode: .default)
            s.delegate = nil
        }
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasSpaceAvailable, .hasBytesAvailable: stream.pump()
        case .endEncountered: stream.endEncountered()
        case .errorOccurred: stream.errorOccurred()
        default: break
        }
    }
}

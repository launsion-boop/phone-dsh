// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: injected clock, shared
// gates and the small persistence primitives of the controller.
//
// PLAN §2.5 / spec/v1/budgets.md. Every stateful service in this
// module takes its time from `HostClock`, publishes admission through
// `AdmissionGate` and persists through the atomic-write helper below. No
// UIKit/AppKit import lives in this module; the App adapts its lifecycle
// callbacks to `HostSignals`.

import Darwin
import Foundation
import PhoneDSHLog
import PhoneDSHWire

// MARK: - Clock

/// Time source of the controller (PLAN §2.5). Tests inject a manual clock; the
/// App injects ``SystemHostClock``.
public protocol HostClock: Sendable {
    /// Current wall-clock time.
    var now: Date { get }
    /// Suspends for `duration` seconds. Cancellation resumes the caller early.
    func sleep(for duration: TimeInterval) async
}

/// The process clock. The controller never calls `Date()` directly.
public struct SystemHostClock: HostClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for duration: TimeInterval) async {
        guard duration > 0 else { return }
        let nanoseconds = UInt64(min(duration, 86_400) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

// MARK: - Admission

/// Lock-protected admission state published by the host state machine
/// (budgets.md §1). The loopback layer consults `current` on every side-effect
/// frame; only `Running` publishes `.open`.
public final class AdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Admission = .closed
    private var continuations: [UUID: AsyncStream<Admission>.Continuation] = [:]
    private var finished = false

    public init(_ value: Admission = .closed) {
        self.value = value
    }

    /// The admission value the loopback layer must consult synchronously.
    public var current: Admission {
        lock.withLock { value }
    }

    /// `true` while the host accepts side-effect frames.
    public var isOpen: Bool { current == .open }

    public func set(_ newValue: Admission) {
        let targets: [AsyncStream<Admission>.Continuation]? = lock.withLock {
            guard value != newValue else { return nil }
            value = newValue
            return Array(continuations.values)
        }
        guard let targets else { return }
        for target in targets {
            target.yield(newValue)
        }
    }

    /// Admission changes, beginning with the current value.
    public func stream() -> AsyncStream<Admission> {
        AsyncStream { continuation in
            let identifier = UUID()
            let registered = lock.withLock { () -> Bool in
                if finished { return false }
                continuations[identifier] = continuation
                continuation.yield(value)
                return true
            }
            guard registered else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    _ = self.continuations.removeValue(forKey: identifier)
                }
            }
        }
    }

    func finish() {
        let targets: [AsyncStream<Admission>.Continuation] = lock.withLock {
            finished = true
            let targets = Array(continuations.values)
            continuations.removeAll()
            return targets
        }
        for target in targets { target.finish() }
    }
}

// MARK: - Cooperative drain cancellation

/// Cooperative cancellation of in-flight work when the 20 s drain deadline
/// expires (budgets.md §1/§3). The loopback layer awaits
/// `waitUntilCancelled()` or polls `isCancelled` between frames; the state
/// machine never aborts work by itself.
public final class DrainCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Cancels every in-flight request. Idempotent.
    public func cancel() {
        let waiters: [CheckedContinuation<Void, Never>]? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            let waiters = continuations
            continuations.removeAll()
            return waiters
        }
        guard let waiters else { return }
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until the drain deadline cancels in-flight work.
    public func waitUntilCancelled() async {
        await withCheckedContinuation { continuation in
            let alreadyCancelled = lock.withLock { () -> Bool in
                if cancelled { return true }
                continuations.append(continuation)
                return false
            }
            if alreadyCancelled {
                continuation.resume()
            }
        }
    }

    /// Clears the cancellation for the next drain (a new `Draining` entry).
    public func reset() {
        lock.withLock { cancelled = false }
    }
}

// MARK: - Epoch closing bridge

/// The controller's view of the workspace log. Keeping it a small protocol
/// makes the state machine testable with a recording double and keeps the
/// module boundary at the landed `WorkspaceLog` API.
public protocol HostEpochClosing: Sendable {
    /// Closes one WAL epoch in the wal.md §5.2 order.
    func closeHostEpoch() async throws
}

extension WorkspaceLog: HostEpochClosing {
    /// Bridges the landed `WorkspaceLog.closeEpoch()` to the controller.
    public func closeHostEpoch() async throws {
        _ = try await closeEpoch()
    }
}

// MARK: - Broadcast hub

/// Fan-out for the controller's observation streams. The last element is
/// replayed to a late subscriber so observers can read the current state
/// without a race.
final class SignalBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var last: Element?
    private var finished = false

    init() {}

    func stream(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let identifier = UUID()
            let registered = lock.withLock { () -> Bool in
                if finished { return false }
                continuations[identifier] = continuation
                if let last { continuation.yield(last) }
                return true
            }
            guard registered else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    _ = self.continuations.removeValue(forKey: identifier)
                }
            }
        }
    }

    func yield(_ element: Element) {
        let targets: [AsyncStream<Element>.Continuation] = lock.withLock {
            last = element
            return Array(continuations.values)
        }
        for target in targets { target.yield(element) }
    }

    func finish() {
        let targets: [AsyncStream<Element>.Continuation] = lock.withLock {
            finished = true
            let targets = Array(continuations.values)
            continuations.removeAll()
            return targets
        }
        for target in targets { target.finish() }
    }
}

// MARK: - File persistence

/// File-system failures of the controller. Bytes are never silently dropped:
/// an unreadable persisted record is fail loud.
public enum ControllerFileError: Error, Equatable, Sendable {
    case posix(operation: String, code: Int32)
    case corrupt(String)
}

enum ControllerFileStore {
    static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ControllerFileError.corrupt("expected a directory")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ControllerFileError.posix(operation: "mkdir", code: EIO)
        }
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ControllerFileError.posix(operation: "read", code: EIO)
        }
    }

    /// Decodes a JSON file; an unreadable or malformed file is `corrupt`.
    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard exists(url) else { return nil }
        let data = try read(url)
        do {
            return try makeDecoder().decode(T.self, from: data)
        } catch {
            throw ControllerFileError.corrupt("malformed JSON record")
        }
    }

    /// Temporary file → fsync → rename → fsync directory (wal.md §7.1 rule).
    static func writeAtomic(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)
        let temporary = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        }
        guard descriptor >= 0 else {
            throw ControllerFileError.posix(operation: "open", code: errno)
        }
        do {
            try writeAll(descriptor: descriptor, data: data)
            guard Darwin.fsync(descriptor) == 0 else {
                throw ControllerFileError.posix(operation: "fsync", code: errno)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        Darwin.close(descriptor)
        let renamed = temporary.path.withCString { from in
            url.path.withCString { to in
                Darwin.rename(from, to)
            }
        }
        guard renamed == 0 else {
            throw ControllerFileError.posix(operation: "rename", code: errno)
        }
        try syncDirectory(directory)
    }

    /// Appends `data` and fsyncs before returning (step records, exec ledger).
    static func append(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }
        guard descriptor >= 0 else {
            throw ControllerFileError.posix(operation: "open", code: errno)
        }
        defer { Darwin.close(descriptor) }
        try writeAll(descriptor: descriptor, data: data)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ControllerFileError.posix(operation: "fsync", code: errno)
        }
    }

    static func writeAll(descriptor: Int32, data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ControllerFileError.posix(operation: "write", code: errno)
                }
                offset += written
            }
        }
    }

    static func fileSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.intValue
    }

    /// Removes a record and fsyncs its directory. Without the directory fsync a
    /// crash after `unlink` but before the metadata reaches disk can resurrect
    /// stale authority evidence (for example a completed reclaim intent).
    static func removeIfExists(_ url: URL) throws {
        guard exists(url) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ControllerFileError.posix(operation: "remove", code: EIO)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    /// File names of one directory, sorted, without hidden entries.
    static func fileNames(in directory: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return entries.filter { !$0.hasPrefix(".") }.sorted()
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw ControllerFileError.posix(operation: "open", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ControllerFileError.posix(operation: "fsync", code: errno)
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try makeEncoder().encode(value)
        } catch {
            throw ControllerFileError.corrupt("cannot encode record")
        }
    }
}

// MARK: - Small shared helpers

enum ControllerHex {
    static func encode(_ bytes: [UInt8]) -> String {
        var output = String()
        output.reserveCapacity(bytes.count * 2)
        let digits = Array("0123456789abcdef".utf8)
        for byte in bytes {
            output.append(Character(UnicodeScalar(digits[Int(byte >> 4)])))
            output.append(Character(UnicodeScalar(digits[Int(byte & 0x0F)])))
        }
        return output
    }

    static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        let bytes = value.utf8
        guard bytes.count == count else { return false }
        return bytes.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// Constant-time-ish comparison for token digests.
    static func equalsConstantTime(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<left.count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

extension Date {
    /// Milliseconds since the Unix epoch, the only time form persisted.
    var millisecondsSinceEpoch: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}

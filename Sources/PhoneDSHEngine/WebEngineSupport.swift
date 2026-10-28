// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: non-UI supporting state.
//
// PLAN §2.1: only the WebEngine object touches WebKit on the UI actor. The
// event bus, the readable capability snapshot and the boot-id generator are
// plain thread-safe values so other modules can poll diagnostics off the main
// actor without importing WebKit.

import Foundation

/// Broadcasts engine events to every subscriber.
final class WebEngineEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<WebEngineEvent>.Continuation] = [:]
    private var finished = false

    /// Creates an independent subscription.
    func makeStream() -> WebEngineEvents {
        let (stream, continuation) = AsyncStream<WebEngineEvent>.makeStream(
            bufferingPolicy: .unbounded)
        let identifier = UUID()
        lock.lock()
        if finished {
            lock.unlock()
            continuation.finish()
        } else {
            continuations[identifier] = continuation
            lock.unlock()
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[identifier] = nil
            self.lock.unlock()
        }
        return WebEngineEvents(stream)
    }

    func send(_ event: WebEngineEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }
}

/// Lock-protected capability/diagnostic snapshot readable off the UI actor.
final class WebEngineReadableState: @unchecked Sendable {
    private let lock = NSLock()
    private var lockdown = false
    private var attached = false
    private var occlusionVisible: Bool?
    private var terminations: UInt64 = 0
    private var status: WebEngineBootStatus?
    private var probeBaseline: Double?

    var isLockdownModeEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lockdown
    }

    func setLockdownModeEnabled(_ value: Bool) {
        lock.lock()
        lockdown = value
        lock.unlock()
    }

    var isAttachedWithVisibleArea: Bool {
        lock.lock()
        defer { lock.unlock() }
        return attached
    }

    func setAttachedWithVisibleArea(_ value: Bool) {
        lock.lock()
        attached = value
        lock.unlock()
    }

    /// `nil` when the view is not in a window or the platform has no occlusion
    /// concept; otherwise whether the hosting window is visible to the user.
    var isWindowOcclusionVisible: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return occlusionVisible
    }

    func setWindowOcclusionVisible(_ value: Bool?) {
        lock.lock()
        occlusionVisible = value
        lock.unlock()
    }

    var terminationCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return terminations
    }

    func setTerminationCount(_ value: UInt64) {
        lock.lock()
        terminations = value
        lock.unlock()
    }

    var bootStatus: WebEngineBootStatus? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    func setBootStatus(_ value: WebEngineBootStatus?) {
        lock.lock()
        status = value
        lock.unlock()
    }

    var jitBaselineMilliseconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return probeBaseline
    }

    func setJITBaselineMilliseconds(_ value: Double?) {
        lock.lock()
        probeBaseline = value
        lock.unlock()
    }
}

/// Fresh 128-bit boot ids: 32 lowercase hexadecimal characters (D6).
enum WebEngineBootID {
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        var text = ""
        text.reserveCapacity(32)
        for byte in bytes {
            text.append(Character(UnicodeScalar(hexDigits[Int(byte >> 4)])))
            text.append(Character(UnicodeScalar(hexDigits[Int(byte & 0x0F)])))
        }
        return text
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
}

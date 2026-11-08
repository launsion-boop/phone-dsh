// SPDX-License-Identifier: MIT
// secure-session-v2 §8.2/§8.4: a non-reusable validity token. The store
// issues one per CoreBluetooth connection to the selected device (the
// connection generation) and invalidates it synchronously, before any
// asynchronous teardown, on disconnect, service change, manager loss,
// connection timeout or a change of the selection. The coordinator issues one
// per selected record and invalidates it before forget / reset writes
// `revoked`. Checks never block and never reach the main actor.
import Foundation

public final class BLESecureLease: @unchecked Sendable {
    public let peripheral: UUID
    /// The selected record's device fingerprint (bare 64 hex).
    public let device: String
    private let lock = NSLock()
    private var valid = true
    private var handlers: [@Sendable () -> Void] = []

    public init(peripheral: UUID, device: String) {
        self.peripheral = peripheral
        self.device = device
    }

    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }

    /// Runs `handler` once after invalidation (immediately if already
    /// invalid). Handlers run synchronously inside the invalidating call and
    /// must not re-enter the invalidator; schedule work instead.
    public func onInvalidate(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if valid { handlers.append(handler); lock.unlock(); return }
        lock.unlock()
        handler()
    }

    public func invalidate() {
        lock.lock()
        guard valid else { lock.unlock(); return }
        valid = false
        let pending = handlers; handlers = []
        lock.unlock()
        pending.forEach { $0() }
    }
}

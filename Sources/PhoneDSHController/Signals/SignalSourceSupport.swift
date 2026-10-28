// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: platform signal sources.
//
// Shared plumbing for the App-side adapters of PLAN §2.5 / budgets.md §3. The
// controller never imports UIKit/AppKit; these sources translate documented
// platform observations into the injected `HostSignals` streams. The helpers
// stay internal to the module — only the sources themselves are public.

import Foundation

/// Adds and removes a set of NotificationCenter observers with one lifetime.
///
/// The observer closures must not assume a particular queue: AppKit/UIKit
/// notifications are delivered on the posting thread unless a queue is given,
/// so the sources re-publish values through a lock-protected broadcaster and
/// never touch platform state off that callback.
final class NotificationObserverBag: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    /// Observes each name and calls `handler` once per notification.
    func observe(_ names: [Notification.Name],
                 handler: @escaping @Sendable () -> Void) {
        for name in names {
            let token = center.addObserver(forName: name, object: nil,
                                           queue: nil) { _ in handler() }
            lock.withLock { tokens.append(token) }
        }
    }

    /// Removes every observer; safe to call more than once.
    func removeAll() {
        let removed: [NSObjectProtocol] = lock.withLock {
            let current = tokens
            tokens.removeAll()
            return current
        }
        for token in removed {
            center.removeObserver(token)
        }
    }
}

/// Serializes the "emit only on change" rule of one signal source.
///
/// Platform delegates and notifications can repeat the same value (for example
/// both `willResignActive` and `didEnterBackground` are posted around one
/// backgrounding); the controller's D14 table rejects a repeated edge, so the
/// adapter drops duplicates before they reach a stream.
final class SignalValueGate<Value: Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Value?
    private var hasLast = false

    init(initial: Value? = nil) {
        if let initial {
            last = initial
            hasLast = true
        }
    }

    /// Returns `true` when `value` differs from the last accepted value.
    func accept(_ value: Value) -> Bool {
        lock.withLock {
            if hasLast, last == value { return false }
            last = value
            hasLast = true
            return true
        }
    }

    var current: Value? {
        lock.withLock { last }
    }
}

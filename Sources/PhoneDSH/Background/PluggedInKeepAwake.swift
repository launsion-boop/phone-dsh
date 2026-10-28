// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: plugged-in keep-awake.
//
// PLAN W6-BACKGROUND: while the device is charging and the host is `Running`,
// the App keeps the screen awake with `isIdleTimerDisabled = true` so a long
// task is not interrupted by the auto-lock timer.
//
// Documented caveat: this only disables the *automatic* idle timer. It cannot
// prevent a manual lock (the user pressing the side button), a system lock, a
// call, or the OS suspending the App for another reason, and it is not a
// promise that a task finishes. NOT_VERIFIED on a device: the exact auto-lock
// behaviour of a charging phone with this flag set.
//
// Only the decision is cross-platform; the actual UIKit assignment lives in
// the platform idle-timer adapter behind `#if canImport(UIKit)`.

import Foundation
import PhoneDSHController

#if canImport(UIKit)
import UIKit
#endif

/// Writes the system idle-timer flag.
public protocol IdleTimerControlling: Sendable {
    /// Enables/disables the automatic idle timer.
    func setIdleTimerDisabled(_ disabled: Bool)
}

/// iOS adapter over `UIApplication.isIdleTimerDisabled`.
public struct PlatformIdleTimer: IdleTimerControlling {
    public init() {}

    public func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        // UIKit is main-thread only. The main queue keeps the writes in call
        // order, so a fast running -> draining sequence cannot leave the flag
        // enabled by an out-of-order hop.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                UIApplication.shared.isIdleTimerDisabled = disabled
            }
        }
        #endif
    }
}

/// Recording idle timer for tests.
public final class RecordingIdleTimer: IdleTimerControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var changes: [Bool] = []

    public init(initial: Bool = false) {
        value = initial
    }

    public var isIdleTimerDisabled: Bool { lock.withLock { value } }
    public var recordedChanges: [Bool] { lock.withLock { changes } }

    public func setIdleTimerDisabled(_ disabled: Bool) {
        lock.withLock {
            value = disabled
            changes.append(disabled)
        }
    }
}

/// Applies the charging + Running keep-awake rule.
///
/// The type is deliberately not an actor: it is a small idempotent writer
/// called from the App's signal observers, and it keeps no asynchronous state.
public final class PluggedInKeepAwake: @unchecked Sendable {
    /// The flag cannot stop a manual lock; this constant is the documented
    /// caveat and is part of the public contract.
    public static let preventsManualLock = false

    private let idleTimer: any IdleTimerControlling
    private let lock = NSLock()
    private var disabled = false
    private var wrote = false

    /// Creates the controller.
    ///
    /// - Parameter idleTimer: Platform writer; tests inject
    ///   ``RecordingIdleTimer``.
    public init(idleTimer: any IdleTimerControlling = PlatformIdleTimer()) {
        self.idleTimer = idleTimer
    }

    /// The last value written to the system.
    public var isIdleTimerDisabled: Bool { lock.withLock { disabled } }

    /// The rule: charging **and** the host in `Running`.
    public static func shouldKeepAwake(isCharging: Bool, hostState: HostState) -> Bool {
        isCharging && hostState == .running
    }

    /// Applies the current signals. Returns the resulting flag.
    @discardableResult
    public func update(isCharging: Bool, hostState: HostState) -> Bool {
        let wanted = Self.shouldKeepAwake(isCharging: isCharging,
                                          hostState: hostState)
        let changed: Bool = lock.withLock {
            guard disabled != wanted else { return false }
            disabled = wanted
            wrote = true
            return true
        }
        if changed {
            idleTimer.setIdleTimerDisabled(wanted)
        }
        return wanted
    }

    /// Forces the idle timer back on (App teardown / background fail safe).
    /// Idempotent.
    public func reset() {
        let changed: Bool = lock.withLock {
            guard disabled else { return false }
            disabled = false
            wrote = true
            return true
        }
        if changed {
            idleTimer.setIdleTimerDisabled(false)
        }
    }

    deinit {
        let needsWrite = lock.withLock { disabled || wrote }
        if needsWrite {
            idleTimer.setIdleTimerDisabled(false)
        }
    }
}

// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: OS background execution windows.
//
// PLAN W6-BACKGROUND. The controller owns the 20 s drain deadline; this file
// is the seam to the OS execution window that keeps the App alive while the
// drain runs. The platform implementation is iOS-only (UIKit + BackgroundTasks
// behind `#if canImport(UIKit)`); macOS gets a no-op window so the package
// compiles and tests run there.
//
// NOT_VERIFIED: how long iOS actually keeps the App alive in each window. The
// drainer never assumes more than the documented `beginBackgroundTask`
// expectation of "a short amount of time" and always respects its own 20 s
// deadline.

import Foundation

/// Which OS facility backs a background drain window.
public enum BackgroundTaskKind: String, CaseIterable, Codable, Sendable {
    /// No window (macOS, or a deliberately disabled schedule).
    case none
    /// `UIApplication.beginBackgroundTask`: a short execution window on iOS.
    case backgroundTask
    /// iOS 26 `BGContinuedProcessingTask`, used only as the drain window.
    case continuedProcessing
}

/// Opaque ownership token for one OS background window.
public struct BackgroundTaskToken: Hashable, Codable, Sendable {
    /// Process-local identifier of the window.
    public let id: UInt64
    /// Which facility backs it.
    public let kind: BackgroundTaskKind

    public init(id: UInt64, kind: BackgroundTaskKind) {
        self.id = id
        self.kind = kind
    }
}

/// Starts and ends the OS execution window used by ``BackgroundDrainer``.
///
/// Implementations must be safe to call from any thread. `begin` returns `nil`
/// when the platform has no usable window; the drainer then keeps its deadline
/// but cannot extend the process lifetime, and reports `.none` as the kind.
public protocol BackgroundTaskScheduling: Sendable {
    /// The window kind the scheduler normally uses.
    var kind: BackgroundTaskKind { get }

    /// Begins one execution window.
    ///
    /// - Parameters:
    ///   - name: Human-readable task name shown in OS diagnostics.
    ///   - expiration: Called when the OS is about to suspend the App; the
    ///     drainer forces the controller deadline and returns promptly.
    /// - Returns: The ownership token, or `nil` when unsupported/refused.
    func beginBackgroundTask(
        name: String,
        expiration: @escaping @Sendable () -> Void) async -> BackgroundTaskToken?

    /// Reports drain-window progress (0...1). Platforms without a progress UI
    /// ignore it; iOS 26 continued processing requires it.
    func reportProgress(_ fraction: Double, for token: BackgroundTaskToken) async

    /// Ends the window. Must be called exactly once per begun token; a no-op
    /// for a token that already expired or ended.
    func endBackgroundTask(_ token: BackgroundTaskToken) async
}

public extension BackgroundTaskScheduling {
    /// Default: no progress UI.
    func reportProgress(_ fraction: Double, for token: BackgroundTaskToken) async {}
}

/// A scheduler that never opens a window. Used by tests and by an App that
/// deliberately opts out of background execution (the drain still runs while
/// the process is alive, but iOS may suspend it at any main-thread idling
/// point).
public struct NoopBackgroundTaskScheduler: BackgroundTaskScheduling {
    public init() {}

    public var kind: BackgroundTaskKind { .none }

    public func beginBackgroundTask(
        name: String,
        expiration: @escaping @Sendable () -> Void) async -> BackgroundTaskToken? {
        nil
    }

    public func endBackgroundTask(_ token: BackgroundTaskToken) async {}
}

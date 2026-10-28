// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: scene-phase signal.
//
// budgets.md §3 `scenePhase`: `background -> Draining`, `active` after a park
// enters recovery. On iOS the App lifecycle is observed through the documented
// `UIApplication` notifications; on macOS the nearest AppKit equivalents are
// used. The mapping is a policy choice, not a claim about the OS: real
// background/foreground behaviour is NOT_VERIFIED until it runs on a device.
//
// The notification names are injectable so tests post to a private
// NotificationCenter and never depend on a running application object.

import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Notification names that map to one scene phase.
public struct ScenePhaseNotifications: Equatable, Sendable {
    /// Notifications that mean the App is frontmost and interactive.
    public var active: [Notification.Name]
    /// Notifications that mean the App is still foregrounded but not taking
    /// input (for example an incoming call or the app switcher).
    public var inactive: [Notification.Name]
    /// Notifications that mean the App entered the background.
    public var background: [Notification.Name]

    public init(active: [Notification.Name],
                inactive: [Notification.Name],
                background: [Notification.Name]) {
        self.active = active
        self.inactive = inactive
        self.background = background
    }

    /// Documented platform notifications.
    ///
    /// - iOS: `UIApplication.didBecomeActiveNotification`,
    ///   `UIApplication.willResignActiveNotification`,
    ///   `UIApplication.didEnterBackgroundNotification`. The
    ///   `willEnterForeground` notification is deliberately not mapped to
    ///   `active`: the App is only active again once `didBecomeActive` fires.
    /// - macOS: `NSApplication.didBecomeActiveNotification`,
    ///   `NSApplication.willResignActiveNotification` and
    ///   `NSApplication.didHideNotification`; `didUnhideNotification` returns
    ///   to `active`. A hidden macOS App has no scene phase, so this is the
    ///   policy equivalent of iOS backgrounding.
    public static var platform: ScenePhaseNotifications {
        #if canImport(UIKit)
        return ScenePhaseNotifications(
            active: [UIApplication.didBecomeActiveNotification],
            inactive: [UIApplication.willResignActiveNotification],
            background: [UIApplication.didEnterBackgroundNotification])
        #elseif canImport(AppKit)
        return ScenePhaseNotifications(
            active: [NSApplication.didBecomeActiveNotification,
                     NSApplication.didUnhideNotification],
            inactive: [NSApplication.willResignActiveNotification],
            background: [NSApplication.didHideNotification])
        #else
        return ScenePhaseNotifications(active: [], inactive: [], background: [])
        #endif
    }
}

/// Publishes ``ScenePhase`` values from platform lifecycle notifications.
///
/// One source belongs to one App lifetime. ``start()`` registers the observers
/// and emits the initial phase; ``stop()`` removes them and finishes every
/// subscription (the `HostSignals` contract allows a source to end while the
/// App is suspended — the App must subscribe again after a resume).
public final class ScenePhaseSignalSource: @unchecked Sendable {
    /// The mapping this source observes.
    public let notifications: ScenePhaseNotifications
    /// Phase used as the first value of the stream, if known.
    public let initialPhase: ScenePhase?

    private let hub = SignalBroadcaster<ScenePhase>()
    private let gate: SignalValueGate<ScenePhase>
    private let bag: NotificationObserverBag
    private let lock = NSLock()
    private var running = false

    /// Creates a source.
    ///
    /// - Parameters:
    ///   - notificationCenter: Injected center; tests use a private instance.
    ///   - notifications: Notification-to-phase mapping. Defaults to the
    ///     documented platform lifecycle notifications.
    ///   - initial: Value emitted first, when the caller already knows the
    ///     current phase (the App calls ``platform(notificationCenter:)`` from
    ///     the main thread before it starts observing).
    public init(notificationCenter: NotificationCenter = .default,
                notifications: ScenePhaseNotifications = .platform,
                initial: ScenePhase? = nil) {
        self.notifications = notifications
        self.initialPhase = initial
        self.bag = NotificationObserverBag(center: notificationCenter)
        self.gate = SignalValueGate()
    }

    /// Creates the iOS/macOS source with the current phase, when it can be read
    /// and the caller is on the main thread; otherwise the first value comes
    /// from the next lifecycle notification.
    public static func platform(notificationCenter: NotificationCenter = .default)
        -> ScenePhaseSignalSource {
        ScenePhaseSignalSource(notificationCenter: notificationCenter,
                               notifications: .platform,
                               initial: currentPlatformPhase())
    }

    /// The current phase from the platform application object.
    ///
    /// `UIApplication.shared` / `NSApplication.shared` are main-thread objects;
    /// the read is skipped off the main thread rather than risking a runtime
    /// isolation violation. A source created before an application object
    /// exists simply starts without an initial value.
    public static func currentPlatformPhase() -> ScenePhase? {
        guard Thread.isMainThread else { return nil }
        #if canImport(UIKit)
        return MainActor.assumeIsolated {
            switch UIApplication.shared.applicationState {
            case .active: return .active
            case .inactive: return .inactive
            case .background: return .background
            @unknown default: return nil
            }
        }
        #elseif canImport(AppKit)
        return MainActor.assumeIsolated {
            let application = NSApplication.shared
            if application.isHidden { return .background }
            return application.isActive ? .active : .inactive
        }
        #else
        return nil
        #endif
    }

    /// Lifecycle phases; the last value is replayed to a late subscriber.
    public var stream: AsyncStream<ScenePhase> { hub.stream() }

    /// Registers the observers and publishes the initial phase once.
    public func start() {
        let shouldStart: Bool = lock.withLock {
            if running { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        bag.observe(notifications.active) { [weak self] in self?.emit(.active) }
        bag.observe(notifications.inactive) { [weak self] in self?.emit(.inactive) }
        bag.observe(notifications.background) { [weak self] in self?.emit(.background) }
        if let initialPhase {
            emit(initialPhase)
        }
    }

    /// Removes the observers and finishes the stream.
    public func stop() {
        lock.withLock { running = false }
        bag.removeAll()
        hub.finish()
    }

    /// Injects a phase (used by an App adapter that already observes its own
    /// lifecycle API and keeps this source for the notification path).
    public func seed(_ phase: ScenePhase) {
        emit(phase)
    }

    private func emit(_ phase: ScenePhase) {
        let isRunning = lock.withLock { running }
        guard isRunning, gate.accept(phase) else { return }
        hub.yield(phase)
    }
}

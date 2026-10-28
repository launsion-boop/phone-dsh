// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: AppKit event pump for macOS
// WKWebView harnesses.
//
// A WKWebView attached with a visible area still starts out hidden to WebKit
// when the process never runs an AppKit event loop. Ordering the host window
// in and calling `NSApplication.activate(ignoringOtherApps:)` is not enough:
// until the process dequeues and dispatches AppKit events, the window server
// never tells `NSApplication` that the window is visible, so
// `NSWindow.occlusionState` lacks `.visible` and the page's
// `document.visibilityState` stays `hidden`. WebKit throttles a hidden page —
// timers, fetch-body reads and Worker scheduling stop — which looks exactly
// like a hung Worker under `swift test`, even with the display on and the
// screen unlocked.
//
// A production app runs the AppKit main event loop (`NSApplication.run`) and
// therefore never needs this pump. An XCTest process has no such loop: every
// macOS harness that hosts a WKWebView (the smoke test, the scenario runner,
// the Phase 0 probes and the kill matrix) must pump while it waits. This file
// is the one reusable pump. See `docs/architecture.md` "Page visibility".
//
// NOT_VERIFIED on an iPhone: AppKit does not exist there; a foreground iOS app's
// run loop is the equivalent guarantee.

#if canImport(AppKit)
import AppKit
import Foundation

/// Dequeues and dispatches AppKit events for a host that does not run
/// `NSApplication.run` (an XCTest process, a CLI probe).
public enum WebEngineAppKitEventPump {
    /// Dequeues and dispatches at most one pending event.
    ///
    /// - Returns: `true` when an event was dispatched.
    @WebEngineUIActor
    @discardableResult
    public static func pumpOne() -> Bool {
        let application = NSApplication.shared
        guard let event = application.nextEvent(matching: .any,
                                                until: Date(),
                                                inMode: .default,
                                                dequeue: true) else {
            return false
        }
        application.sendEvent(event)
        return true
    }

    /// Dequeues and dispatches pending AppKit events for up to `duration`
    /// seconds.
    ///
    /// `nextEvent(matching:until:inMode:dequeue:)` blocks until an event
    /// arrives or the deadline expires, so this is also the wait: the main
    /// thread services the AppKit event queue instead of sleeping. WebKit's
    /// main-thread callbacks (navigation, script messages, JS completion
    /// handlers) run on the same loop and keep making progress.
    @WebEngineUIActor
    public static func pump(for duration: TimeInterval) {
        let application = NSApplication.shared
        let deadline = Date().addingTimeInterval(max(0, duration))
        while let event = application.nextEvent(matching: .any,
                                                until: deadline,
                                                inMode: .default,
                                                dequeue: true) {
            application.sendEvent(event)
            if Date() >= deadline { break }
        }
    }

    /// The async wait used by harness polling loops: yields the main thread to
    /// the AppKit event queue for `interval` seconds instead of sleeping.
    public static func wait(_ interval: TimeInterval) async throws {
        try Task.checkCancellation()
        await MainActor.run {
            pump(for: interval)
        }
    }

    /// Orders a test host window in front with the floating/all-spaces
    /// behaviour the harnesses use, activates the process and pumps long enough
    /// for the window server to report the window as occlusion-visible.
    @WebEngineUIActor
    public static func show(_ window: NSWindow) {
        let application = NSApplication.shared
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        pump(for: 0.05)
    }
}
#endif

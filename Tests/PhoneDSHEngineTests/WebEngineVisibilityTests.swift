// SPDX-License-Identifier: MIT
// PhoneDSHEngine tests: the page-visibility precondition that the
// macOS WKWebView harnesses must satisfy.
//
// The regression this file guards is G2-FIX-21: a WKWebView in an XCTest
// process is attached to an ordered window, and the app is activated, but
// unless the wait dispatches AppKit events the window never becomes
// occlusion-visible and WebKit keeps `document.visibilityState == "hidden"`.
// A hidden page is throttled, so the Worker's fetch stalls and the scenario
// looks hung. This test proves both directions with a real WKWebView:
//
//   1. waiting with the main run loop only (the pre-fix harness style: no
//      AppKit event is dequeued) leaves the page hidden;
//   2. the shared pump (`WebEngineAppKitEventPump`) makes the same page
//      `visible` and `engine.waitForVisiblePage` observes it.
//
// The test is synchronous on purpose. XCTest's own async-test harness already
// dispatches AppKit events while an async test waits, so the pre-fix condition
// is reproduced the way the standalone probes did: `RunLoop.main.run`, never
// `NSApplication.nextEvent`.

import AppKit
import CoreGraphics
import Foundation
import XCTest
import PhoneDSHEngine

final class WebEngineVisibilityTests: XCTestCase {
    private var server: StubLoopbackServer?
    private var window: NSWindow?
    private var engine: WebEngine?

    override func setUp() {
        super.setUp()
        onMain { _ = NSApplication.shared }
    }

    /// While the console session is locked every window is occlusion-hidden, so no event pump can make a page
    /// visible: these tests would fail for an environmental reason. Skip them loudly instead (the scenario and
    /// smoke harnesses report the same condition as a precondition failure).
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(Self.consoleSessionIsLocked, "no visible console session (locked, or a headless host without a window server); WKWebView pages are occlusion-hidden")
    }

    /// `true` when no window server session exists for this process (a headless build host reached over
    /// ssh, as the macmini is) or when the console session is locked: in both cases no window can become
    /// occlusion-visible, so the pump cannot be exercised.
    private static var consoleSessionIsLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if (dict["kCGSSessionOnConsoleKey"] as? Bool) == false { return true }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    override func tearDown() {
        let engine = self.engine
        let window = self.window
        onMain {
            engine?.shutdown()
            window?.orderOut(nil)
            window?.close()
            // The no-pump phase hides the app to make the hidden state
            // deterministic; restore it for whatever test runs next.
            NSApplication.shared.unhide(nil)
        }
        self.engine = nil
        self.window = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    // MARK: - Harness page

    /// A real WKWebView attached to an ordered, floating window, exactly like
    /// the smoke/scenario harness window. The window is ordered in front and
    /// the app is activated, but no AppKit event has been dispatched yet.
    private func makeHarnessPage(showWindow: Bool = true) throws -> WebEngine {
        let server = try StubLoopbackServer(bootMode: .direct)
        try server.start()
        self.server = server

        let engine = onMain {
            WebEngine(configuration: WebEngineConfiguration(
                origin: server.baseURL,
                imagePath: "/image/base",
                token: "visibility-token",
                bootID: "00112233445566778899aabbccddeeff",
                bootTimeout: 20))
        }
        let window = onMain { () -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                                  styleMask: [.titled],
                                  backing: .buffered,
                                  defer: false)
            window.isReleasedWhenClosed = false
            window.title = "phone-dsh visibility test"
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            window.contentView = container
            if showWindow {
                window.level = .floating
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            engine.attach(to: container)
            return window
        }
        self.engine = engine
        self.window = window

        let url = onMain { try engine.configuration.makePageURL() }
        let loaded = LockedBox<Result<Void, Error>>()
        let finished = LockedBox(false)
        Task { @MainActor in
            do {
                try await engine.load(url)
                loaded.value = .success(())
            } catch {
                loaded.value = .failure(error)
            }
            finished.value = true
        }
        guard runMainRunLoop(until: { finished.value == true }, timeout: 30) else {
            throw VisibilityTestError.timeout("page load")
        }
        if case .failure(let error)? = loaded.value {
            throw error
        }
        return engine
    }

    /// Services the main run loop without ever dequeuing an AppKit event. This
    /// is the wait style the harnesses used before the fix.
    private func runMainRunLoop(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// Starts a main-actor async operation and drives it with the main run
    /// loop only (no AppKit events).
    private func awaitOnMainRunLoop<T>(timeout: TimeInterval,
                                       _ operation: @escaping @MainActor () async -> T) -> T? {
        let result = LockedBox<T>()
        let finished = LockedBox(false)
        Task { @MainActor in
            let value = await operation()
            result.value = value
            finished.value = true
        }
        guard runMainRunLoop(until: { finished.value == true }, timeout: timeout) else {
            return nil
        }
        return result.value
    }

    // MARK: - Regression

    func testHarnessPageVisibilityRequiresTheEventPump() throws {
        let engine = try makeHarnessPage()

        // Phase 1 — no pump. Put the process in the hidden state the pre-fix
        // harness started from: the window is ordered in but the application
        // is hidden, and the wait below only runs the main run loop (it never
        // dequeues an AppKit event). `hide` makes the state deterministic even
        // when an earlier test in the same process already dispatched AppKit
        // events; without the pump the queued show/activation events are never
        // processed, so WebKit keeps the page hidden.
        onMain { NSApplication.shared.hide(nil) }
        _ = runMainRunLoop(until: { false }, timeout: 2)
        guard let hidden = awaitOnMainRunLoop(timeout: 10, {
            await engine.pageVisibility(timeout: 2)
        }) else {
            return XCTFail("the page did not answer the visibility probe without a pump")
        }
        XCTAssertEqual(hidden.documentVisibilityState, "hidden",
                       "without an AppKit event pump the harness page must stay hidden "
                       + "(precondition: \(hidden.diagnostic))")
        XCTAssertNotEqual(hidden.windowOcclusionVisible, true,
                          "without an AppKit event pump the ordered window is not "
                          + "occlusion-visible (\(hidden.diagnostic))")
        XCTAssertFalse(hidden.isVisible, hidden.diagnostic)

        // Phase 2 — the shared pump dispatches the queued AppKit events (window
        // ordering, activation), the window server reports the window visible
        // and WebKit un-hides the page. The same page and window are used, so
        // the only difference is the pump.
        onMain {
            NSApplication.shared.unhide(nil)
            if let window {
                WebEngineAppKitEventPump.show(window)
            }
            for _ in 0..<40 {
                WebEngineAppKitEventPump.pump(for: 0.05)
            }
        }
        guard let visible = awaitOnMainRunLoop(timeout: 20, {
            await engine.waitForVisiblePage(timeout: 12)
        }) else {
            return XCTFail("the page did not answer the visibility probe after the pump")
        }
        XCTAssertTrue(visible.isVisible,
                      "the shared event pump must make the harness page visible "
                      + "(precondition: \(visible.diagnostic))")
        XCTAssertEqual(visible.documentVisibilityState, "visible", visible.diagnostic)
        XCTAssertEqual(visible.windowOcclusionVisible, true, visible.diagnostic)
        XCTAssertTrue(engine.isVisibleForWebKit, visible.diagnostic)
        XCTAssertTrue(engine.isAttachedWithVisibleArea, visible.diagnostic)
    }

    /// The pump is reusable and idempotent: harness polling loops call it on
    /// every wait iteration and the page stays visible.
    func testZEventPumpKeepsThePageVisibleAcrossRepeatedWaits() throws {
        let engine = try makeHarnessPage()
        guard let first = awaitOnMainRunLoop(timeout: 20, {
            await engine.waitForVisiblePage(timeout: 12)
        }) else {
            return XCTFail("the page did not answer the visibility probe")
        }
        XCTAssertTrue(first.isVisible, first.diagnostic)
        for _ in 0..<5 {
            onMain { WebEngineAppKitEventPump.pump(for: 0.02) }
        }
        guard let again = awaitOnMainRunLoop(timeout: 10, {
            await engine.pageVisibility(timeout: 2)
        }) else {
            return XCTFail("the page did not answer the repeated visibility probe")
        }
        XCTAssertTrue(again.isVisible, again.diagnostic)
        XCTAssertEqual(again.documentVisibilityState, "visible", again.diagnostic)
    }

    /// Boot warns — instead of silently running a throttled page — when the
    /// hosting window is not occlusion-visible. A window that was never
    /// ordered in makes this independent of any AppKit events another test
    /// already dispatched.
    func testYBootWarnsWhenTheWindowIsOcclusionHidden() throws {
        let engine = try makeHarnessPage(showWindow: false)
        let collector = EventCollector(engine.events)
        let finished = LockedBox(false)
        Task { @MainActor in
            _ = try? await engine.bootWorker(engine.configuration)
            finished.value = true
        }
        _ = runMainRunLoop(until: {
            collector.recordedEvents.contains { event in
                if case .consoleLine(let line) = event, line.level == .warning {
                    return line.text.contains("not occlusion-visible")
                }
                return false
            }
        }, timeout: 10)
        let warnings = collector.recordedEvents.compactMap { event -> String? in
            guard case .consoleLine(let line) = event, line.level == .warning else {
                return nil
            }
            return line.text
        }
        XCTAssertTrue(warnings.contains { $0.contains("not occlusion-visible") },
                      "boot must warn about the occlusion-hidden window; warnings: \(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("WebEngineAppKitEventPump") },
                      "the warning must name the harness pump; warnings: \(warnings)")
        // Teardown's shutdown resumes the pending boot waiter.
        _ = finished
    }

    private enum VisibilityTestError: Error {
        case timeout(String)
    }
}

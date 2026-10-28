// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: page-visibility precondition.
//
// WebKit throttles a page it considers hidden: timers fire late (or not at
// all), fetch-body reads stall and the Worker is scheduled as a background
// page, even though the WebContent process is alive and the view has a visible
// area. AppKit only learns that the hosting window is on screen once the
// process dispatches AppKit events, so a macOS XCTest harness (no
// `NSApplication.run`) must pump them while it waits — see
// ``WebEngineAppKitEventPump``.
//
// `WebEngine.isAttachedWithVisibleArea` stays the geometric attachment check
// the facade refuses to boot without (PLAN §2.5). ``WebEngine/isVisibleForWebKit``
// and ``WebEngine/waitForVisiblePage(timeout:)`` add the second half of the
// production precondition: the window must be occlusion-visible (macOS) and the
// page must report `document.visibilityState == "visible"`. An app that runs
// its main event loop satisfies both; the harnesses assert them before the
// first turn.
//
// NOT_VERIFIED on an iPhone: on iOS a foreground app satisfies the equivalent
// condition (the app's `UIApplication.applicationState` is `.active`); the
// platform checks in this file have not been run on a device.

import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The engine's view of the page visibility precondition at one instant.
public struct WebEnginePageVisibility: Equatable, Sendable {
    /// The geometric check the facade already enforces before boot.
    public var attachedWithVisibleArea: Bool
    /// macOS: `NSWindow.occlusionState` contains `.visible`. iOS: the app is
    /// `.active`. `nil` when the view is not in a window or the platform has no
    /// equivalent signal.
    public var windowOcclusionVisible: Bool?
    /// The page's `document.visibilityState` (`visible`, `hidden`, ...); `nil`
    /// when the page did not answer (frozen or not loaded).
    public var documentVisibilityState: String?

    public init(attachedWithVisibleArea: Bool,
                windowOcclusionVisible: Bool? = nil,
                documentVisibilityState: String? = nil) {
        self.attachedWithVisibleArea = attachedWithVisibleArea
        self.windowOcclusionVisible = windowOcclusionVisible
        self.documentVisibilityState = documentVisibilityState
    }

    /// Both halves of the precondition, as WebKit sees the page.
    public var isVisible: Bool {
        attachedWithVisibleArea
            && (windowOcclusionVisible ?? true)
            && documentVisibilityState == "visible"
    }

    /// One-line evidence for logs and failure messages.
    public var diagnostic: String {
        let occlusion = windowOcclusionVisible.map(String.init) ?? "unknown"
        return "attached_with_visible_area=\(attachedWithVisibleArea), "
            + "window_occlusion_visible=\(occlusion), "
            + "document.visibilityState=\(documentVisibilityState ?? "unresponsive")"
    }

    /// Fail-loud message every macOS harness uses before its first turn.
    public var actionableFailure: String {
        "the WKWebView page is not visible (\(diagnostic)). WebKit throttles a "
            + "hidden page: timers, fetch-body reads and Worker scheduling stop while "
            + "the WebContent process stays alive, so the run looks hung. An app that "
            + "runs its main event loop satisfies this; a macOS XCTest harness must "
            + "pump AppKit events (WebEngineAppKitEventPump) while it waits. See "
            + "docs/architecture.md, page visibility."
    }
}

/// One-shot resume guard for the JavaScript visibility probe.
private final class WebEngineVisibilityOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}

extension WebEngine {
    /// Samples the window occlusion state and `document.visibilityState` once.
    ///
    /// This does not pump AppKit events; call it after
    /// ``WebEngineAppKitEventPump`` has had a chance to run, or use
    /// ``waitForVisiblePage(timeout:)``.
    ///
    /// - Parameter timeout: how long the page may take to answer the script
    ///   evaluation before the state is reported as unresponsive.
    public nonisolated func pageVisibility(timeout: TimeInterval = 2) async
        -> WebEnginePageVisibility {
        await samplePageVisibilityOnUI(timeout: timeout)
    }

    /// Waits until the hosting window is occlusion-visible and the page reports
    /// `document.visibilityState == "visible"`.
    ///
    /// - Parameter timeout: wall-clock budget for the precondition.
    /// - Returns: the last sample; `isVisible == false` on timeout.
    public nonisolated func waitForVisiblePage(timeout: TimeInterval = 12) async
        -> WebEnginePageVisibility {
        await waitForVisiblePageOnUI(timeout: timeout)
    }

    // MARK: - UI-actor implementation

    @WebEngineUIActor
    private func samplePageVisibilityOnUI(timeout: TimeInterval) async
        -> WebEnginePageVisibility {
        // Re-read the window state right before the page sample: the window can
        // have been occluded (or restored) since the last layout change.
        refreshAttachmentState()
        let document = await documentVisibilityStateOnUI(timeout: timeout)
        return WebEnginePageVisibility(
            attachedWithVisibleArea: isAttachedWithVisibleArea,
            windowOcclusionVisible: isWindowOcclusionVisible,
            documentVisibilityState: document)
    }

    @WebEngineUIActor
    private func waitForVisiblePageOnUI(timeout: TimeInterval) async
        -> WebEnginePageVisibility {
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var snapshot = await samplePageVisibilityOnUI(timeout: min(1, timeout))
        while !snapshot.isVisible && Date() < deadline {
#if canImport(AppKit)
            // The XCTest process has no `NSApplication.run`; dispatching the
            // queued AppKit events is what makes the ordered window visible to
            // the window server and the page un-hidden to WebKit.
            WebEngineAppKitEventPump.pump(for: 0.05)
#endif
            snapshot = await samplePageVisibilityOnUI(timeout: min(1, timeout))
            if !snapshot.isVisible {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return snapshot
    }

    @WebEngineUIActor
    private func documentVisibilityStateOnUI(timeout: TimeInterval) async -> String? {
        let once = WebEngineVisibilityOnce()
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<String?, Never>) in
            let finish: @Sendable (String?) -> Void = { value in
                guard once.take() else { return }
                continuation.resume(returning: value)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, timeout)) {
                finish(nil)
            }
            view.evaluateJavaScript("document.visibilityState") { value, _ in
                finish(value as? String)
            }
        }
    }
}

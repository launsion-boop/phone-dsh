// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: the visible host window.
//
// The scenario engine (PLAN W3) needs a WKWebView attached with at least one
// visible point. Under `swift test` on macOS the runner supplies a floating
// AppKit window and pumps events (see `WebEngineAppKitEventPump`); on the iOS
// Simulator it supplies the smallest foreground `UIWindow` that satisfies the
// same geometric precondition. A production app already owns such a window, so
// this type exists only for the harness.

import Foundation
import PhoneDSHEngine

#if canImport(AppKit)
import AppKit
public typealias ScenarioHostWindow = NSWindow
#elseif canImport(UIKit)
import UIKit
public typealias ScenarioHostWindow = UIWindow
#endif

/// One visible host window plus the container view the engine attaches to.
@MainActor
public final class ScenarioVisibleWindow {
    public let window: ScenarioHostWindow
    public let container: WebEngineHostView
    #if canImport(UIKit)
    private let rootController: UIViewController
    #endif

    public init(title: String) throws {
        #if canImport(AppKit)
        let scenarioWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        scenarioWindow.isReleasedWhenClosed = false
        scenarioWindow.title = title
        let scenarioContainer = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        scenarioWindow.contentView = scenarioContainer
        // The Worker must stay schedulable for the whole run: a WKWebView whose
        // window is occluded or whose app is inactive can be suspended by
        // WebKit after a few seconds, which freezes the Worker's event loop
        // (timers, fetch-body reads and channel frames all stop). A floating,
        // all-spaces window plus an active app keeps the page in the visible
        // state, and the shared AppKit event pump (used by every harness wait)
        // makes AppKit actually dispatch the ordering/activation events. This
        // is the same precondition `WebEngine.isVisibleForWebKit` enforces.
        WebEngineAppKitEventPump.show(scenarioWindow)
        self.window = scenarioWindow
        self.container = scenarioContainer
        #elseif canImport(UIKit)
        let scenarioWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 320))
        let root = UIViewController()
        let scenarioContainer = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        self.rootController = root
        scenarioWindow.rootViewController = root
        scenarioWindow.makeKeyAndVisible()
        root.view.frame = scenarioWindow.bounds
        root.view.backgroundColor = .white
        scenarioContainer.backgroundColor = .clear
        scenarioContainer.isUserInteractionEnabled = false
        scenarioContainer.isAccessibilityElement = false
        root.view.addSubview(scenarioContainer)
        scenarioWindow.layoutIfNeeded()
        self.window = scenarioWindow
        self.container = scenarioContainer
        #else
        throw ScenarioError.environment("no visible WKWebView host window on this platform")
        #endif
    }

    public func close() {
        #if canImport(AppKit)
        window.close()
        #elseif canImport(UIKit)
        container.subviews.forEach { $0.removeFromSuperview() }
        container.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }
}

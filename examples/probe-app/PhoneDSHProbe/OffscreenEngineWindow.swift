// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the offscreen anchor window for a background launch.
//
// PLAN §2.4 / host §10.2: `makeHostLaunch()` requires the anchor to be in a
// window. A push or BGTask relaunch can have no connected scene, so SwiftUI's
// `WindowGroup` renders nothing and the Worker has nowhere to run. This window
// carries the anchor until a scene renders; `VisibleAnchorView` then reparents
// the anchor back into the RootView overlay and `releaseIfAnchorMoved` closes
// the window.
//
// Rules from `ios-offscreen-anchor-spike` (§2): never `makeKeyAndVisible`,
// alpha 0.01, 2×2, and only while no measurement/boot owns the anchor.
//
// NOT_VERIFIED on a device: whether iOS lets a background relaunch create a
// usable `UIWindowScene` and run WebContent in it. When it does not, the boot
// is refused by the existing `anchor.isInWindow` gate and the wake falls back
// to native passes + `BGProcessingTask` (host §10.2).

import UIKit
import ProbeKit

@MainActor
final class OffscreenEngineWindow {
    static let shared = OffscreenEngineWindow()

    private(set) var window: UIWindow?
    private var container: UIViewController?
    private weak var hostedAnchor: VisibleEngineAnchor?
    /// Number of windows created in this process (diagnostics / spike parity).
    private(set) var attachCount = 0

    private init() {}

    /// Puts `anchor` into the offscreen window when it is not in a window yet.
    /// Returns whether the anchor is now window-attached.
    @discardableResult
    func attach(anchor: VisibleEngineAnchor) -> Bool {
        if anchor.isInWindow { return true }
        if window == nil {
            // Not makeKeyAndVisible(): WebKit needs a window, the user must not
            // see it. Off-origin and transparent; no key status is claimed.
            let window = UIWindow(frame: CGRect(x: -2, y: -2, width: 2, height: 2))
            window.windowLevel = .normal
            window.backgroundColor = .clear
            window.alpha = 0.01
            window.isHidden = false
            let controller = UIViewController()
            controller.view.backgroundColor = .clear
            controller.view.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
            window.rootViewController = controller
            // A background launch may have no connected scene at all; the
            // window then has no scene and the anchor stays out of a window,
            // which the caller treats as "cannot boot".
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState != .unattached }) {
                window.windowScene = scene
            }
            self.window = window
            self.container = controller
            self.hostedAnchor = anchor
            attachCount += 1
        }
        guard let container else { return false }
        anchor.view.frame = container.view.bounds
        if anchor.view.superview !== container.view {
            container.view.addSubview(anchor.view)
        }
        window?.isHidden = false
        return anchor.isInWindow
    }

    /// Called when the RootView overlay has taken the anchor back (it reparents
    /// the view itself). Hides and releases the window only when the anchor is
    /// no longer its child, so it can never steal the visible overlay's view.
    func releaseIfAnchorMoved(anchor: VisibleEngineAnchor) {
        guard hostedAnchor === anchor else { return }
        guard anchor.view.superview !== container?.view else {
            // Still the offscreen host: the visible container did not take it
            // over (for example the overlay renders before the window is key).
            return
        }
        window?.isHidden = true
        window = nil
        container = nil
        hostedAnchor = nil
    }

    /// Test/diagnostic view of the current offscreen state.
    var isHostingAnchor: Bool { hostedAnchor != nil && window != nil }
}

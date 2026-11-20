// SPDX-License-Identifier: MIT
//
// Offscreen anchor-window prototype for plan §2.4.
//
// `PhoneDSHHost.start()` requires `VisibleEngineAnchor.isInWindow`. A push or
// BGProcessing launch can happen with no connected, rendered scene, so the
// SwiftUI WindowGroup never puts the anchor in a window. This prototype keeps
// the anchor in a real UIWindow that is never made key and never visible to the
// user: 2x2 points, alpha 0.01, offscreen origin. It is spike-only; ios-launch
// owns the production implementation.
//
// The measurement is exactly whether WebKit starts and survives in this
// window. Do not "fix" a failure by calling makeKeyAndVisible(): that would
// change what the spike is measuring.

#if BOT_RESIDENCY_SPIKE

import ProbeKit
import UIKit

@MainActor
final class OffscreenEngineWindow {
    private(set) var window: UIWindow?
    private(set) var hostingView: UIView?
    private(set) var attachCount = 0
    private let anchor: VisibleEngineAnchor

    init(anchor: VisibleEngineAnchor) {
        self.anchor = anchor
    }

    var isHostingAnchor: Bool {
        anchor.isInWindow
    }

    /// Attaches the anchor to a non-visible window. Idempotent.
    /// - Returns: whether `anchor.isInWindow` became true.
    @discardableResult
    func attach() -> Bool {
        if window == nil {
            // Deliberately not `makeKeyAndVisible()`: the window must exist for
            // WebKit's window check while remaining invisible to the user.
            let window = UIWindow(frame: CGRect(x: -2, y: -2, width: 2, height: 2))
            window.windowLevel = .normal
            window.backgroundColor = .clear
            window.alpha = 0.01
            window.isHidden = false

            let controller = UIViewController()
            controller.view.backgroundColor = .clear
            controller.view.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
            anchor.view.frame = controller.view.bounds
            controller.view.addSubview(anchor.view)
            window.rootViewController = controller

            // Prefer an existing scene when there is one (the app was already
            // running); a truly scene-less background launch leaves this nil.
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState != .unattached }) {
                window.windowScene = scene
            }
            self.window = window
            self.hostingView = controller.view
            attachCount += 1
        }
        window?.isHidden = false
        return anchor.isInWindow
    }

    /// Moves the anchor into a visible container once a scene is rendered.
    /// - Returns: whether the anchor is now in a window through `container`.
    @discardableResult
    func moveAnchor(to container: UIView) -> Bool {
        guard anchor.view.superview !== container else { return anchor.isInWindow }
        anchor.view.removeFromSuperview()
        anchor.view.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        container.addSubview(anchor.view)
        window?.isHidden = true
        window = nil
        hostingView = nil
        return anchor.isInWindow
    }

    func teardown() {
        anchor.view.removeFromSuperview()
        window?.isHidden = true
        window = nil
        hostingView = nil
    }
}
#endif

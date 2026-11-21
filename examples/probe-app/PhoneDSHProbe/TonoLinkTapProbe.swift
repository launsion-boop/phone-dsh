// SPDX-License-Identifier: MIT
// Tells, without the screen, whether the AssistiveTouch button is where it was learned.
//
// While the mirror is down the app sees nothing of the phone's screen, and iOS exposes neither
// the button's position nor any event from it. But when this app is in front it can lay an
// invisible window over its own UI: a pointer press at the saved button position then either
// reaches AssistiveTouch (the button is there; this window gets nothing) or lands on this window
// (the button has moved). The window swallows the press, so a miss presses nothing of the app.

import UIKit

@MainActor
final class TonoLinkTapProbe {
    private final class CatchView: UIView {
        var touches: [CGPoint] = []
        var hovers: [CGPoint] = []
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            self.touches += touches.map { $0.location(in: self) }
        }
        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            hovers.append(recognizer.location(in: self))
        }
    }

    private var window: UIWindow?
    private var view: CatchView?

    /// The probe needs this app in front: only then are its windows on screen.
    static var available: Bool {
        UIApplication.shared.applicationState == .active
            && UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
    }

    /// Puts the catching window up. False when the app is not in front.
    func show() -> Bool {
        guard Self.available,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive && $0.screen == UIScreen.main }) else { return false }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 2
        let view = CatchView(frame: window.bounds)
        // Fully clear views do not receive events; this is not visible.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.011)
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: view, action: #selector(CatchView.hovered(_:))))
        let controller = UIViewController()
        controller.view = view
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        self.view = view
        return true
    }

    func hide() {
        window?.isHidden = true
        window = nil
        view = nil
    }

    /// Presses that reached this window since `show()`, in 0–1000 screen coordinates.
    var touches: [CGPoint] { (view?.touches ?? []).map(Self.normalized) }
    /// Pointer positions hovering over this window since `show()`, in 0–1000.
    var hovers: [CGPoint] { (view?.hovers ?? []).map(Self.normalized) }
    func reset() { view?.touches = []; view?.hovers = [] }

    private static func normalized(_ point: CGPoint) -> CGPoint {
        let bounds = UIScreen.main.bounds
        return CGPoint(x: point.x / bounds.width * 1000, y: point.y / bounds.height * 1000)
    }
}

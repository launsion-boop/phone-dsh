// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS probe app: edge-to-edge Web surface.
//
// The complete DSH page is the only thing on screen: no navigation bar, no
// Safari toolbar, no `SFSafariViewController`. The WKWebView is laid out under
// the safe areas so `viewport-fit=cover` can expose the notch/home-indicator
// insets to the page, while its bottom follows `keyboardLayoutGuide` so the
// composer stays above the keyboard instead of being covered by it.

import SwiftUI
import UIKit
import PhoneDSHEngine

struct WebSurfacePage: UIViewRepresentable {
    let engine: WebEngine?

    func makeUIView(context: Context) -> WebSurfaceContainerView {
        let view = WebSurfaceContainerView()
        view.backgroundColor = .systemBackground
        view.accessibilityLabel = "DSH Web 页面"
        view.attach(engine: engine)
        return view
    }

    func updateUIView(_ uiView: WebSurfaceContainerView, context: Context) {
        uiView.attach(engine: engine)
    }

    static func dismantleUIView(_ uiView: WebSurfaceContainerView, coordinator: ()) {
        uiView.detachEngine()
    }
}

/// Owns the host view the engine's WKWebView is re-parented into.
///
/// The engine creates its WKWebView against a small `VisibleEngineAnchor` so
/// the facade's boot precondition is satisfied. Once the host is running the
/// surface takes the same view and expands it edge-to-edge; the engine's
/// attachment check is refreshed on every layout/window change.
@MainActor
final class WebSurfaceContainerView: UIView {
    private(set) weak var attachedEngine: WebEngine?
    private var webViewBottomConstraint: NSLayoutConstraint?

    func attach(engine: WebEngine?) {
        if attachedEngine === engine, engine != nil { return }
        if let current = attachedEngine {
            current.view.removeFromSuperview()
        }
        attachedEngine = engine
        webViewBottomConstraint?.isActive = false
        webViewBottomConstraint = nil
        guard let engine else { return }

        let webView = engine.view
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.alpha = 1
        webView.isHidden = false
        addSubview(webView)
        // The page is allowed to scroll behind the notch and home indicator;
        // its CSS uses env(safe-area-inset-*) from viewport-fit=cover. Do not
        // let the (hidden) keyboard guide pull the bottom up to the home
        // indicator safe area: only an actual keyboard should shrink the page.
        keyboardLayoutGuide.usesBottomSafeArea = false
        let bottom = webView.bottomAnchor.constraint(
            equalTo: keyboardLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
        ])
        webViewBottomConstraint = bottom
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        setNeedsLayout()
        layoutIfNeeded()
        engine.refreshAttachmentState()
    }

    func detachEngine() {
        if let current = attachedEngine {
            current.view.removeFromSuperview()
        }
        attachedEngine = nil
        webViewBottomConstraint?.isActive = false
        webViewBottomConstraint = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachedEngine?.refreshAttachmentState()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachedEngine?.refreshAttachmentState()
    }
}

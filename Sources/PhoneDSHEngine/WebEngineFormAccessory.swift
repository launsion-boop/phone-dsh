// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: remove WebKit's form accessory on iOS.
//
// Focusing a text field in a `WKWebView` makes UIKit present WebKit's white
// form-assistant bar (previous / next / done) above the keyboard. It is the
// `inputAccessoryView` of the private content view that becomes first
// responder, not an input view: the keyboard, the Chinese IME candidate bar,
// selection, copy/paste, Return and the page's own send action are separate.
//
// There is no public API on `WKWebView` to remove that accessory, and clearing
// `inputAssistantItem` bar groups alone leaves the bar in place on iPhone.
// This adapter therefore finds the text responder inside *this* web view
// (by `UITextInput` conformance and first-responder state, never by a WebKit
// class name) and gives that one object an instance-level dynamic subclass
// whose public `inputAccessoryView` getter returns nil. The subclass
// adds no ivars, is installed with `object_setClass` on that object alone, and
// is removed again in ``invalidate()``. There is no global method swizzle, so
// another web view, a native field or a system picker keeps its own accessory.
//
// The initial scan also clears this web view's public `inputAssistantItem`
// groups (the iPad shortcut bar) and `didFinish`/keyboard notifications re-run
// the scan idempotently: WebKit can replace or reset the content view across a
// navigation or a WebContent restart. The standard dismiss gestures remain
// untouched; the iOS surface already sets `scrollView.keyboardDismissMode` to
// `.interactive` in `WebSurfacePage`.
//
// NOT_VERIFIED: the bar's disappearance has not been observed on an iPhone in
// this Linux checkout. The Mac acceptance run must focus the real DSH composer
// and confirm the bar is gone while the IME, selection, Return/send and the
// keyboard safe area still work.

#if canImport(UIKit)

import ObjectiveC
import UIKit
import WebKit

/// Per-engine remover for WebKit's iOS form-assistant accessory.
///
/// Only the web view passed to ``init(webView:)`` is touched. The object is
/// owned by ``WebEngine`` and invalidated from ``WebEngine/shutdown()``; every
/// entry point is idempotent.
@WebEngineUIActor
final class WebEngineFormAccessorySuppressor: NSObject {
    private weak var webView: WKWebView?
    private weak var adaptedResponder: UIResponder?
    private var adaptedOriginalClass: AnyClass?
    private var adaptedSubclass: AnyClass?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        _ = NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil)
        refresh()
    }

    /// Installs the accessory suppression again if WebKit replaced its content
    /// view or reset its class. Safe to call before the page has loaded, on
    /// every navigation finish and on keyboard presentation.
    func refresh() {
        guard let webView else { return }
        let groupsBefore = assistantGroupCount(on: webView)
        clearAssistantGroups(on: webView)
        let focused = Self.focusedTextResponder(in: webView)
        let candidate = focused ?? Self.textInputCandidate(in: webView)
        guard let candidate else { return }
        let classWasReset = candidate !== adaptedResponder
            || object_getClass(candidate) !== adaptedSubclass
        adaptIfNeeded(candidate)
        if focused != nil, classWasReset || groupsBefore > 0 {
            candidate.reloadInputViews()
        }
    }

    /// Removes the observers and restores the responder's original class.
    /// Calling this more than once is a no-op.
    func invalidate() {
        NotificationCenter.default.removeObserver(self)
        restoreResponder()
        webView = nil
    }

    // MARK: - Notifications

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let webView else { return }
        guard let responder = Self.focusedTextResponder(in: webView) else {
            return
        }
        let groupsBefore = assistantGroupCount(on: webView)
        clearAssistantGroups(on: webView)
        let classWasReset = responder !== adaptedResponder
            || object_getClass(responder) !== adaptedSubclass
        if classWasReset {
            adaptIfNeeded(responder)
        }
        // Proactive installation before the first focus needs no reload. A
        // fallback installation inside the show notification does: UIKit has
        // already asked the original class for its accessory.
        if classWasReset || groupsBefore > 0 {
            responder.reloadInputViews()
        }
    }

    // MARK: - Responder discovery

    private static func focusedTextResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder, view is UITextInput {
            return view
        }
        for subview in view.subviews {
            if let responder = focusedTextResponder(in: subview) {
                return responder
            }
        }
        return nil
    }

    private static func textInputCandidate(in view: UIView) -> UIResponder? {
        for subview in view.subviews {
            if subview is UITextInput {
                return subview
            }
            if let candidate = textInputCandidate(in: subview) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Instance-level getter

    private func adaptIfNeeded(_ responder: UIResponder) {
        if responder === adaptedResponder,
           let currentSubclass = adaptedSubclass,
           object_getClass(responder) === currentSubclass {
            return
        }
        restoreResponder()
        guard let originalClass = object_getClass(responder) else { return }

        let name = "PhoneDSHFormAccessory_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        guard let subclass = objc_allocateClassPair(originalClass, name, 0) else {
            return
        }
        let selector = #selector(getter: UIResponder.inputAccessoryView)
        guard let method = class_getInstanceMethod(originalClass, selector)
                ?? class_getInstanceMethod(UIResponder.self, selector),
              let types = method_getTypeEncoding(method) else {
            objc_disposeClassPair(subclass)
            return
        }
        // The block is copied by the runtime into the method IMP; it is not a
        // captured closure and the dynamic subclass therefore has no ivars.
        let implementation: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
        guard class_addMethod(subclass, selector,
                              imp_implementationWithBlock(implementation), types) else {
            objc_disposeClassPair(subclass)
            return
        }
        objc_registerClassPair(subclass)
        _ = object_setClass(responder, subclass)
        adaptedResponder = responder
        adaptedOriginalClass = originalClass
        adaptedSubclass = subclass
    }

    private func restoreResponder() {
        defer {
            adaptedResponder = nil
            adaptedOriginalClass = nil
            adaptedSubclass = nil
        }
        guard let responder = adaptedResponder,
              let originalClass = adaptedOriginalClass,
              let currentSubclass = adaptedSubclass,
              object_getClass(responder) === currentSubclass else {
            return
        }
        _ = object_setClass(responder, originalClass)
    }

    // MARK: - Public assistant item

    private func clearAssistantGroups(on webView: WKWebView) {
        webView.inputAssistantItem.leadingBarButtonGroups = []
        webView.inputAssistantItem.trailingBarButtonGroups = []
    }

    private func assistantGroupCount(on webView: WKWebView) -> Int {
        webView.inputAssistantItem.leadingBarButtonGroups.count
            + webView.inputAssistantItem.trailingBarButtonGroups.count
    }
}

#endif

// SPDX-License-Identifier: MIT

import SwiftUI
import WebKit

/// Renders a mail body with every remote fetch blocked. Two independent layers
/// do the blocking: the CSP in the document and a compiled content-rule list on
/// the web view. The rule list is compiled once per preview and added once to
/// that view's user content controller; recompiling on every update repeats
/// work, and adding it again on a reused view stacks duplicate blockers.
struct GmailHTMLPreview: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.dataDetectorTypes = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.render(html, in: view)
    }

    static func document(_ html: String) -> String {
        """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
        <style>body { font: -apple-system-body; overflow-wrap: anywhere; padding: 8px; } img { max-width: 100%; }</style>
        </head><body>\(html)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private static let blockRemote = #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}}]"#

        private var rendered: String?
        private var blockList: WKContentRuleList?
        private var waiting: String?
        private var allowDocument = false

        func render(_ html: String, in view: WKWebView) {
            guard rendered != html else { return }
            rendered = html
            guard blockList != nil else {
                waiting = html
                compileBlockList(for: view)
                return
            }
            load(html, in: view)
        }

        private func compileBlockList(for view: WKWebView) {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "pdsh-gmail-block-remote",
                encodedContentRuleList: Self.blockRemote
            ) { [weak self, weak view] list, _ in
                guard let self, let view else { return }
                if Thread.isMainThread {
                    self.finish(list, in: view)
                } else {
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view else { return }
                        self.finish(list, in: view)
                    }
                }
            }
        }

        private func finish(_ list: WKContentRuleList?, in view: WKWebView) {
            guard let list else {
                waiting = nil
                allowDocument = true
                loadUnavailable(in: view)
                return
            }
            if blockList == nil {
                view.configuration.userContentController.add(list)
                blockList = list
            }
            guard let pending = waiting else { return }
            waiting = nil
            load(pending, in: view)
        }

        private func load(_ html: String, in view: WKWebView) {
            allowDocument = true
            view.loadHTMLString(GmailHTMLPreview.document(html), baseURL: nil)
        }

        private func loadUnavailable(in view: WKWebView) {
            let unavailable = NativeText(
                "无法安全预览这封邮件。", "This message cannot be safely previewed."
            )
            view.loadHTMLString("<meta charset=\"utf-8\"><p>\(unavailable)</p>", baseURL: nil)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if allowDocument, navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.request.url?.absoluteString == "about:blank" {
                allowDocument = false
                return .allow
            }
            return .cancel
        }
    }
}

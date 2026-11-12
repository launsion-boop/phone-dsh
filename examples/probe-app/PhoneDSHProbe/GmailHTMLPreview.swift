// SPDX-License-Identifier: MIT

import SwiftUI
import WebKit

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
        let coordinator = context.coordinator
        guard coordinator.html != html else { return }
        coordinator.html = html
        let document = """
            <!doctype html><html><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
            <style>body { font: -apple-system-body; overflow-wrap: anywhere; padding: 8px; } img { max-width: 100%; }</style>
            </head><body>\(html)</body></html>
            """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "pdsh-gmail-block-remote",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}}]"#
        ) { [weak view, weak coordinator] list, _ in
            guard let view, let coordinator, coordinator.html == html else { return }
            coordinator.allowDocument = true
            if let list {
                view.configuration.userContentController.add(list)
                view.loadHTMLString(document, baseURL: nil)
            } else {
                let unavailable = NativeText("无法安全预览这封邮件。", "This message cannot be safely previewed.")
                view.loadHTMLString("<meta charset=\"utf-8\"><p>\(unavailable)</p>", baseURL: nil)
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        var allowDocument = false

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if allowDocument, navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.request.url?.absoluteString == "about:blank" {
                allowDocument = false
                return .allow
            }
            return .cancel
        }
    }
}

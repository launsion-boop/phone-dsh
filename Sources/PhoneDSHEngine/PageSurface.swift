// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: the PAGE surface (spec-render-media-v1 §B).
//
// A PAGE preview is a WKWebView that loads from the `pdsh-page:` origin, so
// the page can resolve relative scripts, textures and `.glb` models and run
// WebGL. The scheme handler injects the host-enforced CSP per the page's
// declared tier; this surface never installs a script message handler, so the
// page has no host bridge.
//
// Failure behaviour (spec §B.9): a navigation failure shows a native footer
// with the reason, and an injected world script draws an in-page bottom bar on
// `window.onerror` / `unhandledrejection` so a missing resource names itself
// instead of failing silently.

#if canImport(UIKit)
import SwiftUI
import WebKit

/// The entry a PAGE surface opens.
public enum PDSHPageEntry: Equatable, Sendable {
    /// A file in a session's workspace: `pdsh-page://<sessionID>/<path>`.
    case workspace(sessionID: String, path: String)
    /// A file in the bundled Web3DLib: `pdsh-page://lib/<path>`.
    case library(path: String)

    /// The URL this entry loads. `nil` when the path cannot be encoded.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = PDSHPageScheme.name
        switch self {
        case .workspace(let sessionID, let path):
            components.host = sessionID
            components.path = "/" + path
        case .library(let path):
            components.host = PDSHPageScheme.libraryHost
            components.path = "/" + path
        }
        return components.url
    }
}

/// A SwiftUI PAGE preview with a native failure footer.
public struct PDSHPageView: View {
    public let entry: PDSHPageEntry
    public let resolver: PDSHPageResolver

    @State private var failure: String?

    public init(entry: PDSHPageEntry, resolver: PDSHPageResolver) {
        self.entry = entry
        self.resolver = resolver
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            if let url = entry.url {
                PDSHPageWebView(url: url, resolver: resolver, failure: $failure)
            } else {
                ContentUnavailableView("无法打开这个页面。", systemImage: "doc.questionmark")
            }
            if let failure, !failure.isEmpty {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
            }
        }
    }
}

/// The `WKWebView` behind a PAGE preview.
public struct PDSHPageWebView: UIViewRepresentable {
    public let url: URL
    public let resolver: PDSHPageResolver
    @Binding public var failure: String?

    public init(url: URL, resolver: PDSHPageResolver, failure: Binding<String?>) {
        self.url = url
        self.resolver = resolver
        _failure = failure
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(resolver: resolver, failure: $failure)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // The scheme handler is the only source of page bytes; no custom
        // script message handler is installed (no host bridge).
        let handler = PDSHPageSchemeHandler(resolver: resolver)
        configuration.setURLSchemeHandler(handler, forURLScheme: PDSHPageScheme.name)
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.errorReporterScript,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = true
        view.isInspectable = false
        view.load(URLRequest(url: url))
        return view
    }

    public func updateUIView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        view.load(URLRequest(url: url))
    }

    /// Draws the missing-resource path in a page-bottom bar; never talks to
    /// the host (deliberately no message handler).
    private static let errorReporterScript = """
    (function () {
      if (window.__pdshPageErrorBar) { return }
      function show(message) {
        var bar = document.getElementById('__pdsh-page-error');
        if (!bar) {
          bar = document.createElement('div');
          bar.id = '__pdsh-page-error';
          bar.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:2147483647;' +
            'font:12px -apple-system,ui-sans-serif;color:#b45309;background:#fff8ed;' +
            'padding:8px 12px;border-top:1px solid #f0c78d;white-space:pre-wrap;';
          document.documentElement.appendChild(bar);
        }
        bar.textContent = String(message);
      }
      window.addEventListener('error', function (event) {
        var target = event.target;
        if (target && target !== window && (target.src || target.href)) {
          show('资源加载失败：' + (target.src || target.href));
        } else if (event.message) {
          show('页面脚本错误：' + event.message);
        }
      }, true);
      window.addEventListener('unhandledrejection', function (event) {
        show('页面脚本错误：' + (event.reason && event.reason.message || event.reason));
      });
    })();
    """

    public final class Coordinator: NSObject, WKNavigationDelegate {
        let resolver: PDSHPageResolver
        let failure: Binding<String?>

        init(resolver: PDSHPageResolver, failure: Binding<String?>) {
            self.resolver = resolver
            self.failure = failure
        }

        public func webView(_ webView: WKWebView,
                            decidePolicyFor navigationAction: WKNavigationAction,
                            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The page is served only from its own origin; an external
            // navigation is refused instead of silently leaving the preview.
            decisionHandler(
                navigationAction.request.url?.scheme == PDSHPageScheme.name
                    ? .allow : .cancel)
        }

        public func webView(_ webView: WKWebView,
                            didFailProvisionalNavigation navigation: WKNavigation!,
                            withError error: Error) {
            failure.wrappedValue = "页面加载失败：\(error.localizedDescription)"
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                            withError error: Error) {
            failure.wrappedValue = "页面加载失败：\(error.localizedDescription)"
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            failure.wrappedValue = nil
        }
    }
}
#endif

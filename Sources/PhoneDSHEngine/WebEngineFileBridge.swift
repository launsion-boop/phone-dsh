// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: WebKit system-file bridge.
//
// The full-screen Web surface keeps the page on the local loopback origin.
// Everything that must leave the page goes through this bridge instead of a
// Safari view controller:
//
//   - `<input type="file">` (`WKUIDelegate.runOpenPanelWith`, iOS 18.4+)
//     presents the system document picker and hands the page a copy it selected
//     itself, not an arbitrary path in the app container. On iOS 17 WebKit
//     applies its built-in Safari file-upload behavior; the deployment minimum
//     is not raised just to customize it;
//   - downloads are written to a per-engine temporary directory and shared
//     with the system activity sheet on iOS; AppKit leaves the navigation to
//     WebKit because this bridge has no macOS download delegate;
//   - external links are passed to `UIApplication.open` (or `NSWorkspace` on
//     macOS); only the exact loopback origin is allowed to navigate inside the
//     Web surface. A remote PC page is therefore never loaded as the local
//     phone surface.
//
// The bridge is the WKNavigationDelegate as well as the WKUIDelegate; it
// forwards page-load callbacks to ``WebEngine`` so the existing boot/restart
// handshake keeps working while policy and file handling live here.

import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#elseif canImport(AppKit)
import AppKit
#endif

/// Navigation policy applied to every main-frame Web surface request.
public enum WebEngineNavigationRoute: Equatable, Sendable {
    /// The URL belongs to the loopback origin; keep it inside the Web view.
    case web
    /// A link outside the loopback origin; the system opens it.
    case external(URL)
    /// A scheme the Web surface must not load or hand to another app.
    case blocked
}

/// Presents the system file picker for a `WKUIDelegate` open-panel request.
///
/// The default implementation presents `UIDocumentPickerViewController`. The
/// handler is injectable so simulator tests and embedders can drive the same
/// bridge path without automating the system picker; whatever URLs it returns
/// are copied into the bridge's confined staging area before WebKit sees them.
public typealias WebEngineFileSelectionHandler =
    (_ allowsMultipleSelection: Bool, _ completion: @escaping ([URL]?) -> Void) -> Void

/// File selection, download and external-link coordinator for one `WebEngine`.
///
/// All state is UI-actor isolated because `UIDocumentPickerViewController`,
/// `UIActivityViewController` and WebKit's delegate callbacks are UI work.
@WebEngineUIActor
public final class WebEngineFileBridge: NSObject {
    /// The engine whose page-load callbacks this bridge forwards.
    public weak var engine: WebEngine?

    /// The one origin the Web surface is allowed to navigate to.
    ///
    /// The engine creates the bridge before the host has bound its loopback
    /// listener, and ``WebEngine/bootWorker(_:)`` later replaces the engine
    /// configuration with that bound origin. The engine calls
    /// ``updateLoopbackOrigin(_:)`` at the same time so navigation policy and
    /// external-link routing follow the real page origin instead of the
    /// pre-boot placeholder.
    public private(set) var loopbackOrigin: URL

    private let temporaryFiles: TemporaryFiles
    private let openExternalHandler: (URL) -> Void
    private let fileSelectionHandler: WebEngineFileSelectionHandler?
    private let shareFileHandler: ((URL) -> Void)?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    #if canImport(UIKit)
    private var pendingOpenPanel: (([URL]?) -> Void)?
    #endif

    /// The per-engine temporary root selected files and downloads live under.
    public var stagingRoot: URL { temporaryFiles.root }

    /// Creates the bridge.
    ///
    /// - Parameters:
    ///   - loopbackOrigin: The bound local origin; only this exact scheme,
    ///     host and port may stay in the Web view.
    ///   - temporaryFiles: Test/embedding override for the download and
    ///     selected-file staging directory.
    ///   - openExternalURL: Test/embedding override for the system open call.
    ///   - fileSelectionHandler: Test/embedding override for the file picker.
    ///     The default presents `UIDocumentPickerViewController`; both paths
    ///     copy every selected URL into ``TemporaryFiles`` before returning it.
    ///   - shareFile: Test/embedding override for sharing a finished download.
    ///     The default presents `UIActivityViewController` and removes the
    ///     staged file when the sheet closes. An override owns that lifetime
    ///     and should call ``cleanup()`` when done.
    public init(loopbackOrigin: URL,
                temporaryFiles: TemporaryFiles? = nil,
                openExternalURL: ((URL) -> Void)? = nil,
                fileSelectionHandler: WebEngineFileSelectionHandler? = nil,
                shareFile: ((URL) -> Void)? = nil) {
        self.loopbackOrigin = loopbackOrigin
        self.fileSelectionHandler = fileSelectionHandler
        self.shareFileHandler = shareFile
        if let temporaryFiles {
            self.temporaryFiles = temporaryFiles
        } else {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("phone-dsh-web", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.temporaryFiles = TemporaryFiles(root: base)
        }
        if let openExternalURL {
            self.openExternalHandler = openExternalURL
        } else {
            #if canImport(UIKit)
            self.openExternalHandler = { url in
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            #elseif canImport(AppKit)
            self.openExternalHandler = { url in
                _ = NSWorkspace.shared.open(url)
            }
            #else
            self.openExternalHandler = { _ in }
            #endif
        }
        super.init()
    }

    /// Updates the origin that stays inside the Web surface.
    ///
    /// Only ``WebEngine`` calls this, when ``WebEngine/bootWorker(_:)`` adopts
    /// the origin the host bound. The value is read again for every navigation
    /// decision, so a boot from a placeholder engine is not cancelled as an
    /// external link.
    public func updateLoopbackOrigin(_ origin: URL) {
        loopbackOrigin = origin
    }

    // MARK: - Navigation policy

    /// Classifies a navigation URL against the one accepted loopback origin.
    ///
    /// Relative, `about:blank`, `blob:` and `data:` URLs are page-local. An
    /// HTTP(S) URL on any other origin, or any other external scheme, is handed
    /// to the system and never loaded inside the local surface. `file:` and
    /// `javascript:` are refused outright: the page cannot read a container
    /// path and cannot drive the native side through a navigation.
    public nonisolated static func route(
        for url: URL,
        loopbackOrigin: URL) -> WebEngineNavigationRoute {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .web
        }
        switch scheme {
        case "about":
            // `about:blank` and the `about:srcdoc` document a preview iframe
            // creates are page-internal frames, not navigations that leave the
            // surface. Any other about: URL is refused.
            let internalAbout = url.absoluteString == "about:blank"
                || url.absoluteString == "about:srcdoc"
            return internalAbout ? .web : .blocked
        case "dsh-resource", "dsh-app":
            // DSH's own resource/app addresses are not system-openable URLs;
            // keep them inside the page (a navigation to them is refused).
            return .blocked
        case "file", "javascript":
            return .blocked
        case "blob", "data":
            return .web
        case "http", "https":
            return isSameOrigin(url, loopbackOrigin) ? .web : .external(url)
        default:
            return .external(url)
        }
    }

    /// Opens a URL outside the Web surface. Keeps the system's own handling:
    /// the Web view never grows a Safari toolbar.
    public func openExternal(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        switch scheme {
        case "file", "javascript", "about", "data", "blob",
             "dsh-resource", "dsh-app":
            return
        default:
            openExternalHandler(url)
        }
    }

    // MARK: - Temporary files

    /// Per-engine staging area for selected files and downloads.
    ///
    /// A page never receives the picker's original URL. Selected files are
    /// copied into `root/<uuid>/<sanitized name>`; a download destination is
    /// the same shape. `contains(_:)` is the path-escape guard used before a
    /// URL is returned to WebKit or the share sheet.
    public struct TemporaryFiles: Sendable {
        public let root: URL

        public init(root: URL) {
            self.root = root.standardizedFileURL
        }

        /// Creates the root directory if necessary.
        public func prepare(fileManager: FileManager = .default) throws {
            try fileManager.createDirectory(at: root,
                                            withIntermediateDirectories: true)
        }

        /// A fresh, non-existing destination for `suggestedFilename`.
        ///
        /// The name is reduced to its last path component and control/path
        /// separators are replaced, so `../../etc/passwd` can only become a
        /// file below this root. Each call gets its own UUID directory.
        public func destination(forSuggestedFilename suggestedFilename: String,
                                fileManager: FileManager = .default) throws -> URL {
            try prepare(fileManager: fileManager)
            let directory = root.appendingPathComponent(UUID().uuidString,
                                                        isDirectory: true)
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(
                Self.sanitizedName(suggestedFilename))
            guard contains(destination) else {
                throw Error.pathEscaped(destination.path)
            }
            return destination
        }

        /// Copies a picker selection into the confined staging area and
        /// returns the copy. The security-scoped access ends before return;
        /// the page only ever sees the app-owned copy.
        public func importSelection(_ source: URL,
                                    fileManager: FileManager = .default) throws -> URL {
            guard source.isFileURL else { throw Error.notAFile(source.absoluteString) }
            let didAccess = source.startAccessingSecurityScopedResource()
            defer {
                if didAccess { source.stopAccessingSecurityScopedResource() }
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path,
                                         isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw Error.notARegularFile(source.absoluteString)
            }
            // A picker URL can be a symlink. `copyItem` would copy the link
            // itself, leaving the page with a path that resolves outside the
            // staging root. Only regular files are imported; the page never
            // receives the picker's original URL either way.
            let attributes = try? fileManager.attributesOfItem(atPath: source.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                throw Error.notARegularFile(source.absoluteString)
            }
            let destination = try destination(
                forSuggestedFilename: source.lastPathComponent,
                fileManager: fileManager)
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                throw Error.copyFailed(error.localizedDescription)
            }
            guard contains(destination) else {
                try? fileManager.removeItem(at: destination)
                throw Error.pathEscaped(destination.path)
            }
            return destination
        }

        /// Whether `url` resolves inside this staging root.
        ///
        /// The textual prefix check is the first guard. For a path that exists
        /// it also resolves symlinks and requires the target to stay inside the
        /// root, so a link cannot expose a container file to the page. A path
        /// that no longer exists (the cleanup assertions and temporary-file
        /// bookkeeping) keeps the textual answer; `contains` is the containment
        /// guard, not an existence check.
        public func contains(_ url: URL, fileManager: FileManager = .default) -> Bool {
            let rootURL = root.standardizedFileURL
            let candidate = url.standardizedFileURL
            guard Self.isInside(candidate, root: rootURL) else { return false }
            guard fileManager.fileExists(atPath: candidate.path) else { return true }
            let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            return Self.isInside(resolvedCandidate, root: resolvedRoot)
        }

        /// Removes one staged file and its UUID directory.
        ///
        /// The staging root itself is removed only through ``removeAll()``; a
        /// `remove(root)` call must never delete the root's parent directory.
        public func remove(_ url: URL, fileManager: FileManager = .default) {
            let standardized = url.standardizedFileURL
            let rootURL = root.standardizedFileURL
            guard standardized.path != rootURL.path else { return }
            guard contains(standardized, fileManager: fileManager) else { return }
            try? fileManager.removeItem(at: standardized)
            let parent = standardized.deletingLastPathComponent().standardizedFileURL
            if parent.path != rootURL.path {
                try? fileManager.removeItem(at: parent)
            }
        }

        private static func isInside(_ candidate: URL, root: URL) -> Bool {
            let rootPath = root.standardizedFileURL.path
            let candidatePath = candidate.standardizedFileURL.path
            return candidatePath == rootPath
                || candidatePath.hasPrefix(rootPath + "/")
        }

        /// Removes the whole staging root.
        public func removeAll(fileManager: FileManager = .default) {
            try? fileManager.removeItem(at: root)
        }

        /// Last path component with separators/control scalars made inert.
        public static func sanitizedName(_ raw: String) -> String {
            let last = (raw as NSString).lastPathComponent
            var name = ""
            for scalar in last.unicodeScalars {
                switch scalar.value {
                case 0, 47, 58, 92, 127:
                    name.append("_")
                default:
                    if scalar.value < 32 {
                        name.append("_")
                    } else {
                        name.append(Character(scalar))
                    }
                }
            }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name == "." || name == ".." {
                name = "file"
            }
            if name.count > 180 {
                name = String(name.prefix(180))
            }
            return name
        }

        /// Errors thrown by the staging area.
        public enum Error: Swift.Error, Equatable, Sendable {
            case notAFile(String)
            case notARegularFile(String)
            case pathEscaped(String)
            case copyFailed(String)
        }
    }

    // MARK: - Cleanup

    /// Cancels an open panel, removes staged/downloaded files and forgets them.
    public func cleanup() {
        #if canImport(UIKit)
        let completion = pendingOpenPanel
        pendingOpenPanel = nil
        completion?(nil)
        #endif
        downloadDestinations.removeAll()
        temporaryFiles.removeAll()
    }

    // MARK: - Helpers

    private nonisolated static func isSameOrigin(_ url: URL, _ origin: URL) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(),
              let originScheme = origin.scheme?.lowercased(),
              urlScheme == originScheme,
              urlScheme == "http" || urlScheme == "https" else {
            return false
        }
        guard url.host?.lowercased() == origin.host?.lowercased() else {
            return false
        }
        return effectivePort(url) == effectivePort(origin)
    }

    private nonisolated static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

// MARK: - Page-load forwarding and download policy

extension WebEngineFileBridge: WKNavigationDelegate {
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch Self.route(for: url, loopbackOrigin: loopbackOrigin) {
        case .web:
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .external(let externalURL):
            if isMainFrame { openExternal(externalURL) }
            decisionHandler(.cancel)
        case .blocked:
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let url = navigationResponse.response.url,
           case .external = Self.route(for: url, loopbackOrigin: loopbackOrigin) {
            decisionHandler(.cancel)
            return
        }
        #if canImport(UIKit)
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        let isAttachment = disposition?.contains("attachment") == true
        if navigationResponse.canShowMIMEType == false || isAttachment {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
        #else
        // WKDownloadDelegate is implemented for the iOS UI path only. Do not
        // ask WebKit to download on AppKit without a delegate that can choose
        // a destination and share it.
        decisionHandler(.allow)
        #endif
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        engine?.webView(webView, didFinish: navigation)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                        withError error: Error) {
        engine?.webView(webView, didFail: navigation, withError: error)
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        engine?.webView(webView, didFailProvisionalNavigation: navigation,
                        withError: error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        engine?.webViewWebContentProcessDidTerminate(webView)
    }

    #if canImport(UIKit)
    public func webView(_ webView: WKWebView,
                        navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView,
                        navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        download.delegate = self
    }
    #endif
}

// MARK: - File input

#if canImport(UIKit)
extension WebEngineFileBridge: WKUIDelegate, UIDocumentPickerDelegate {
    // The iOS 18.4 SDK annotates `WKOpenPanelParameters` and this delegate
    // method with that version, while this app keeps its iOS 17 deployment
    // minimum. On iOS 17 WebKit applies Safari's built-in file-upload
    // behavior; annotating only the typed declaration keeps file input
    // working without raising the minimum. `beginFileSelection` stays
    // available for the iOS 18.4 path and the simulator tests.
    @available(iOS 18.4, *)
    public func webView(_ webView: WKWebView,
                        runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping ([URL]?) -> Void) {
        beginFileSelection(
            allowsMultipleSelection: parameters.allowsMultipleSelection,
            completionHandler: completionHandler)
    }

    /// Starts the one-at-a-time file selection used by `runOpenPanelWith`.
    ///
    /// Exposed so a simulator test can drive the real completion/import path
    /// without automating `UIDocumentPickerViewController`; the default
    /// handler still presents the system picker.
    public func beginFileSelection(allowsMultipleSelection: Bool,
                                   completionHandler: @escaping ([URL]?) -> Void) {
        // One picker at a time; a second input waits for the next tap.
        guard pendingOpenPanel == nil else {
            completionHandler(nil)
            return
        }
        if let fileSelectionHandler {
            pendingOpenPanel = completionHandler
            fileSelectionHandler(allowsMultipleSelection) { [weak self] urls in
                self?.finishFileSelection(urls)
            }
            return
        }
        guard let presenter = Self.topViewController() else {
            completionHandler(nil)
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item],
                                                    asCopy: false)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = self
        pendingOpenPanel = completionHandler
        presenter.present(picker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController,
                               didPickDocumentsAt urls: [URL]) {
        finishFileSelection(urls)
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishFileSelection(nil)
    }

    private func finishFileSelection(_ urls: [URL]?) {
        let completion = pendingOpenPanel
        pendingOpenPanel = nil
        guard let completion else { return }
        guard let urls else {
            completion(nil)
            return
        }
        var selected: [URL] = []
        for url in urls {
            if let stored = try? temporaryFiles.importSelection(url) {
                selected.append(stored)
            }
        }
        completion(selected.isEmpty ? nil : selected)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        return topViewController(from: window?.rootViewController)
    }

    private static func topViewController(from base: UIViewController?) -> UIViewController? {
        guard let base else { return nil }
        if let navigation = base as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = base.presentedViewController {
            return topViewController(from: presented)
        }
        return base
    }

    private func presentShareSheet(for url: URL) {
        guard let presenter = Self.topViewController() else {
            temporaryFiles.remove(url)
            return
        }
        let controller = UIActivityViewController(activityItems: [url],
                                                  applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.maxY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.temporaryFiles.remove(url)
        }
        presenter.present(controller, animated: true)
    }
}

// MARK: - Downloads

extension WebEngineFileBridge: WKDownloadDelegate {
    public func download(_ download: WKDownload,
                         decideDestinationUsing response: URLResponse,
                         suggestedFilename: String,
                         completionHandler: @escaping (URL?) -> Void) {
        do {
            let destination = try temporaryFiles.destination(
                forSuggestedFilename: suggestedFilename)
            downloadDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        } catch {
            completionHandler(nil)
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloadDestinations.removeValue(
            forKey: ObjectIdentifier(download)) else { return }
        if let shareFileHandler {
            shareFileHandler(destination)
        } else {
            presentShareSheet(for: destination)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error,
                         resumeData: Data?) {
        guard let destination = downloadDestinations.removeValue(
            forKey: ObjectIdentifier(download)) else { return }
        temporaryFiles.remove(destination)
    }
}
#endif

// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: system Quick Look for Office documents.
//
// The full DSH Web page renders image, PDF, spreadsheet, HTML and text
// previews itself. Office documents are the one case iOS cannot render: the
// Worker has no LibreOffice and the host must not convert the document to PDF.
// This bridge lets the page hand one workspace file to the system Quick Look
// controller at the top of the app's view hierarchy.
//
// Contract:
// - One WKScriptMessageHandler named ``messageHandlerName``. It accepts only
//   `{v: 1, id, sessionId, path}`; everything else is refused.
// - The injected ``WebEngineNativePreviewResolving`` supplies the *current*
//   session id and resolves the path through the same
//   `workspaceFiles/stat` Remote the Web page uses. The returned absolute path
//   must be under the Worker's `/dsh/workspace` mount.
// - That path is mapped to the host's materialized `workspace/` directory and
//   re-checked with realpath, so a symlink cannot escape the materialized
//   workspace.
// - Quick Look opens the mapped file URL directly. This file never reads the
//   document bytes, never writes a temporary file and never produces a PDF.
// - The outcome is returned to the page through
//   `window.__PDSH_NATIVE_PREVIEW_RESULT__({id, ok, code, message})`.
// - At most one request owns the bridge at a time. The slot is claimed
//   synchronously, before the first `await`, so two page messages cannot both
//   pass the admission check while `workspaceFiles/stat` is in flight. A newer
//   request supersedes (cancels) an older resolving one; once Quick Look is
//   presenting, further requests get `preview-busy` until it is dismissed.
//
// Calling `install(on:)` before the page loads is the integration point. The
// native side is deliberately separate from `WebEngine` so the final host
// assembly owns the session authority and transport wiring.
//
// NOT_VERIFIED: Quick Look presentation and a real Office document on the
// iPhone simulator/device require the Mac acceptance run.

import CoreFoundation
import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(QuickLook) && canImport(UIKit)
import QuickLook
#endif

/// One validated `pdshNativePreview` message.
public struct WebEngineNativePreviewRequest: Equatable, Sendable {
    /// The only message version this bridge understands.
    public static let supportedVersion = 1
    /// Longest accepted request identifier, in UTF-8 bytes.
    public static let maximumIdentifierBytes = 200
    /// Longest accepted session identifier, in UTF-8 bytes.
    public static let maximumSessionIDBytes = 256
    /// Longest accepted workspace path, in UTF-8 bytes.
    public static let maximumPathBytes = 4096

    /// Correlation id echoed in the JavaScript result.
    public let id: String
    /// Session that owns the workspace path.
    public let sessionID: String
    /// Workspace-relative or `/dsh/workspace/...` absolute path.
    public let path: String

    public init(id: String, sessionID: String, path: String) {
        self.id = id
        self.sessionID = sessionID
        self.path = path
    }

    /// Parses a WKScriptMessage body, accepting exactly `{v,id,sessionId,path}`.
    ///
    /// - Parameter body: the bridged JavaScript value.
    /// - Throws: ``WebEngineNativePreviewFailure`` for anything malformed or a
    ///   version other than 1.
    /// - Returns: the validated request.
    public static func parse(_ body: Any) throws -> WebEngineNativePreviewRequest {
        guard let record = body as? [String: Any] else {
            throw WebEngineNativePreviewFailure.invalidMessage(
                "the native preview message must be an object")
        }
        let expected: Set<String> = ["v", "id", "sessionId", "path"]
        guard Set(record.keys) == expected else {
            throw WebEngineNativePreviewFailure.invalidMessage(
                "the native preview message must contain only v, id, sessionId and path")
        }
        guard let rawVersion = record["v"], let version = rawVersion as? NSNumber,
              CFGetTypeID(version as CFTypeRef) != CFBooleanGetTypeID(),
              version.doubleValue == Double(supportedVersion) else {
            throw WebEngineNativePreviewFailure.unsupportedVersion(
                "the native preview message version must be 1")
        }
        let id = try text(record["id"], field: "id", maximumBytes: maximumIdentifierBytes)
        let sessionID = try text(record["sessionId"], field: "sessionId",
                                 maximumBytes: maximumSessionIDBytes)
        let path = try text(record["path"], field: "path", maximumBytes: maximumPathBytes)
        return WebEngineNativePreviewRequest(id: id, sessionID: sessionID, path: path)
    }

    private static func text(_ value: Any?, field: String,
                             maximumBytes: Int) throws -> String {
        guard let text = value as? String else {
            throw WebEngineNativePreviewFailure.invalidMessage(
                "the native preview \(field) must be a string")
        }
        guard text.isEmpty == false else {
            throw WebEngineNativePreviewFailure.invalidMessage(
                "the native preview \(field) must not be empty")
        }
        guard text.utf8.count <= maximumBytes else {
            throw WebEngineNativePreviewFailure.invalidMessage(
                "the native preview \(field) is too long")
        }
        guard text.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F
        }) == false else {
            throw WebEngineNativePreviewFailure.invalidMessage(
                "the native preview \(field) contains control characters")
        }
        return text
    }
}

/// The failure returned to the page; `code` is the stable wire value.
public enum WebEngineNativePreviewFailure: Error, Equatable, Sendable {
    /// The body is not exactly the accepted object shape.
    case invalidMessage(String)
    /// The body names an unsupported protocol version.
    case unsupportedVersion(String)
    /// The native side has no current session.
    case unknownSession(String)
    /// The request names a session other than the current one.
    case sessionMismatch(String)
    /// The path is outside `/dsh/workspace` or escapes the materialized root.
    case pathOutsideWorkspace(String)
    /// `workspaceFiles/stat` did not resolve the file.
    case workspaceFileUnavailable(String)
    /// The resolved path is missing, a directory, or not a regular file.
    case notRegularFile(String)
    /// The system Quick Look controller cannot preview this file.
    case previewUnavailable(String)
    /// A view controller could not present Quick Look.
    case presentationFailed(String)
    /// Another Quick Look presentation is already on screen.
    case previewBusy(String)
    /// A newer request replaced this one while it was still resolving.
    case previewCancelled(String)
    /// The workspace path did not resolve before the bridge's deadline.
    case previewTimedOut(String)

    /// Stable code carried in `__PDSH_NATIVE_PREVIEW_RESULT__`.
    public var code: String {
        switch self {
        case .invalidMessage: return "invalid-message"
        case .unsupportedVersion: return "unsupported-version"
        case .unknownSession: return "unknown-session"
        case .sessionMismatch: return "session-mismatch"
        case .pathOutsideWorkspace: return "path-outside-workspace"
        case .workspaceFileUnavailable: return "workspace-file-unavailable"
        case .notRegularFile: return "not-regular-file"
        case .previewUnavailable: return "preview-unavailable"
        case .presentationFailed: return "presentation-failed"
        case .previewBusy: return "preview-busy"
        case .previewCancelled: return "preview-cancelled"
        case .previewTimedOut: return "preview-timeout"
        }
    }

    /// Human-readable explanation for the page's error state.
    public var message: String {
        switch self {
        case .invalidMessage(let message),
             .unsupportedVersion(let message),
             .unknownSession(let message),
             .sessionMismatch(let message),
             .pathOutsideWorkspace(let message),
             .workspaceFileUnavailable(let message),
             .notRegularFile(let message),
             .previewUnavailable(let message),
             .presentationFailed(let message),
             .previewBusy(let message),
             .previewCancelled(let message),
             .previewTimedOut(let message):
            return message
        }
    }
}

/// The JSON-shaped result evaluated in the page.
public struct WebEngineNativePreviewResult: Equatable, Sendable {
    /// Request id the page is waiting on.
    public let id: String
    /// Whether Quick Look opened the document.
    public let ok: Bool
    /// Stable outcome code.
    public let code: String
    /// Human-readable detail; empty for a successful open.
    public let message: String

    public init(id: String, ok: Bool, code: String, message: String) {
        self.id = id
        self.ok = ok
        self.code = code
        self.message = message
    }

    /// Successful presentation result.
    public static func presented(id: String) -> WebEngineNativePreviewResult {
        WebEngineNativePreviewResult(id: id, ok: true, code: "presented",
                                     message: "")
    }

    /// Failure result for `failure`.
    public static func failed(id: String,
                              failure: WebEngineNativePreviewFailure) -> WebEngineNativePreviewResult {
        WebEngineNativePreviewResult(id: id, ok: false, code: failure.code,
                                     message: failure.message)
    }

    /// The exact JavaScript call the bridge evaluates.
    ///
    /// `nil` only if JSON serialization of the four strings fails, which cannot
    /// happen for valid Swift strings.
    public func javaScriptCall() -> String? {
        let payload: [String: Any] = [
            "id": id,
            "ok": ok,
            "code": code,
            "message": message,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "window.__PDSH_NATIVE_PREVIEW_RESULT__ && "
            + "window.__PDSH_NATIVE_PREVIEW_RESULT__(\(json));"
    }
}

/// Resolves the current web session and a workspace path through the Worker's
/// `workspaceFiles/stat` Remote.
public protocol WebEngineNativePreviewResolving: Sendable {
    /// The session the full Web page currently shows, or `nil` when none is open.
    func currentSessionID() async -> String?
    /// Calls `workspaceFiles/stat` and returns its `absolutePath` result.
    func workspacePath(sessionID: String, path: String) async throws -> String
}

/// Closure-backed resolver the host assembly fills from `PhoneDSHHost.makeTransport`.
///
/// The final integration passes:
/// - `currentSessionID`: the host's current session authority (the same id the
///   Web page opened through `makeTransport`);
/// - `workspacePath`: a call to `transport.call("workspaceFiles/stat", args:)`
///   with `workspaceFileScopeId = sessionID` and `path = path`, returning the
///   result's `absolutePath` string.
public struct WebEngineNativePreviewResolver: WebEngineNativePreviewResolving {
    private let sessionProvider: @Sendable () async -> String?
    private let pathResolver: @Sendable (String, String) async throws -> String

    public init(currentSessionID: @escaping @Sendable () async -> String?,
                workspacePath: @escaping @Sendable (String, String) async throws -> String) {
        self.sessionProvider = currentSessionID
        self.pathResolver = workspacePath
    }

    public func currentSessionID() async -> String? {
        await sessionProvider()
    }

    public func workspacePath(sessionID: String, path: String) async throws -> String {
        try await pathResolver(sessionID, path)
    }
}

/// Request validation and workspace mapping, usable without WebKit.
public struct WebEngineNativePreviewService: Sendable {
    /// The injected session/stat authority.
    public let resolver: any WebEngineNativePreviewResolving
    /// Host directory that materializes the Worker's `/dsh/workspace` mount.
    public let workspaceDirectory: URL

    public init(resolver: any WebEngineNativePreviewResolving,
                workspaceDirectory: URL) {
        self.resolver = resolver
        self.workspaceDirectory = workspaceDirectory
    }

    /// Validates the request and returns the real, contained file URL.
    ///
    /// No file content is read: only metadata and the real path are inspected.
    public func resolve(_ request: WebEngineNativePreviewRequest)
        async -> Result<URL, WebEngineNativePreviewFailure> {
        let relativePath: String
        do {
            relativePath = try WebEngineNativePreviewPath.relativePath(
                fromRequestPath: request.path)
        } catch let failure as WebEngineNativePreviewFailure {
            return .failure(failure)
        } catch {
            return .failure(.pathOutsideWorkspace("the workspace path is invalid"))
        }
        guard let currentSessionID = await resolver.currentSessionID(),
              currentSessionID.isEmpty == false else {
            return .failure(.unknownSession(
                "no DSH session is currently open in the Web page"))
        }
        guard currentSessionID == request.sessionID else {
            return .failure(.sessionMismatch(
                "the request names a session other than the current one"))
        }
        let statPath: String
        do {
            statPath = try await resolver.workspacePath(sessionID: request.sessionID,
                                                        path: relativePath)
        } catch {
            return .failure(.workspaceFileUnavailable(
                "the workspace file could not be resolved: \(Self.safe(error))"))
        }
        let statRelativePath: String
        do {
            statRelativePath = try WebEngineNativePreviewPath.relativePath(
                fromStatAbsolutePath: statPath)
        } catch let failure as WebEngineNativePreviewFailure {
            return .failure(failure)
        } catch {
            return .failure(.pathOutsideWorkspace(
                "the workspace file resolved outside /dsh/workspace"))
        }
        // The stat result is still re-checked below: it may resolve a
        // `/dsh/workspace` symlink to another mount, and realpath is the
        // authority that confines the mapped URL.
        return Self.materializedFileURL(relativePath: statRelativePath,
                                        workspaceDirectory: workspaceDirectory)
    }

    private static func materializedFileURL(relativePath: String,
                                            workspaceDirectory: URL)
        -> Result<URL, WebEngineNativePreviewFailure> {
        let root = workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = workspaceDirectory
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path != root.path,
              candidate.path.hasPrefix(root.path + "/") else {
            return .failure(.pathOutsideWorkspace(
                "the workspace path resolves outside the materialized workspace"))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path,
                                             isDirectory: &isDirectory) else {
            return .failure(.notRegularFile(
                "the workspace file is missing from the materialized workspace"))
        }
        guard isDirectory.boolValue == false else {
            return .failure(.notRegularFile("the workspace path is a directory"))
        }
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey,
                                                            .isSymbolicLinkKey])
        guard values?.isRegularFile == true else {
            return .failure(.notRegularFile(
                "the workspace path is not a regular file"))
        }
        return .success(candidate)
    }

    private static func safe(_ error: Error) -> String {
        String(String(describing: error).prefix(300))
    }
}

/// `/dsh/workspace` path validation shared by message handling and tests.
enum WebEngineNativePreviewPath {
    static let mount = "/dsh/workspace"

    /// The workspace-relative path named by the page.
    ///
    /// A relative path or an absolute `/dsh/workspace/...` path is accepted.
    /// `..`, empty components, backslashes, control characters and every other
    /// absolute root are refused before the stat Remote is called.
    static func relativePath(fromRequestPath path: String) throws -> String {
        guard path.isEmpty == false else {
            throw WebEngineNativePreviewFailure.invalidMessage(
                "the native preview path must not be empty")
        }
        guard path.utf8.count <= WebEngineNativePreviewRequest.maximumPathBytes else {
            throw WebEngineNativePreviewFailure.invalidMessage(
                "the native preview path is too long")
        }
        guard path.contains("\\") == false else {
            throw WebEngineNativePreviewFailure.pathOutsideWorkspace(
                "the workspace path must use / separators")
        }
        guard path.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F
        }) == false else {
            throw WebEngineNativePreviewFailure.invalidMessage(
                "the native preview path contains control characters")
        }
        let body: String
        if path.hasPrefix("/") {
            guard path.hasPrefix(mount + "/") else {
                throw WebEngineNativePreviewFailure.pathOutsideWorkspace(
                    "the workspace path must be under /dsh/workspace")
            }
            body = String(path.dropFirst(mount.count + 1))
        } else {
            guard path.hasPrefix("~") == false else {
                throw WebEngineNativePreviewFailure.pathOutsideWorkspace(
                    "the workspace path must not be a home-relative path")
            }
            body = path
        }
        return try normalizedRelativePath(body)
    }

    /// The workspace-relative path named by a `workspaceFiles/stat` result.
    static func relativePath(fromStatAbsolutePath path: String) throws -> String {
        guard path.hasPrefix(mount + "/") else {
            throw WebEngineNativePreviewFailure.pathOutsideWorkspace(
                "the workspace file resolved outside /dsh/workspace")
        }
        return try normalizedRelativePath(String(path.dropFirst(mount.count + 1)))
    }

    private static func normalizedRelativePath(_ path: String) throws -> String {
        guard path.isEmpty == false else {
            throw WebEngineNativePreviewFailure.pathOutsideWorkspace(
                "the workspace path names the workspace root, not a file")
        }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty {
                throw WebEngineNativePreviewFailure.pathOutsideWorkspace(
                    "the workspace path contains an empty component")
            }
            if part == "." {
                continue
            }
            if part == ".." {
                throw WebEngineNativePreviewFailure.pathOutsideWorkspace(
                    "the workspace path must not contain ..")
            }
            parts.append(part)
        }
        guard parts.isEmpty == false else {
            throw WebEngineNativePreviewFailure.pathOutsideWorkspace(
                "the workspace path names the workspace root, not a file")
        }
        return parts.joined(separator: "/")
    }
}

/// The single-owner flag that makes a request in flight before its first await.
///
/// The bridge is UI-actor isolated, so an `admit` call is atomic with respect to
/// another message. The token captured here is the authority checked again after
/// `workspaceFiles/stat` returns and immediately before Quick Look presents.
/// Mutating the phase from any other request invalidates the older token, so a
/// superseded resolve can only return, never present.
struct WebEngineNativePreviewFlight {
    /// The request currently owning the bridge.
    enum Phase: Equatable {
        case idle
        case resolving(token: UUID, requestID: String)
        case presenting(token: UUID, requestID: String)
    }

    /// What happened when a new message tried to claim the bridge.
    enum Admission: Equatable {
        case admitted(token: UUID)
        case superseded(previousRequestID: String, token: UUID)
        case busy
    }

    private(set) var phase: Phase = .idle

    /// Claims the bridge for `requestID` before any asynchronous work starts.
    ///
    /// A request arriving while another is resolving replaces it: the returned
    /// previous id lets the caller send that request its cancellation result.
    /// A request arriving while Quick Look presents is refused.
    mutating func admit(requestID: String) -> Admission {
        let token = UUID()
        switch phase {
        case .presenting:
            return .busy
        case .resolving(_, let previousRequestID):
            phase = .resolving(token: token, requestID: requestID)
            return .superseded(previousRequestID: previousRequestID, token: token)
        case .idle:
            phase = .resolving(token: token, requestID: requestID)
            return .admitted(token: token)
        }
    }

    /// Whether `token` still owns the resolving phase.
    func isResolving(token: UUID, requestID: String) -> Bool {
        guard case .resolving(let activeToken, let activeRequestID) = phase else {
            return false
        }
        return activeToken == token && activeRequestID == requestID
    }

    /// Whether `token` still owns the presenting phase.
    func isPresenting(token: UUID, requestID: String) -> Bool {
        guard case .presenting(let activeToken, let activeRequestID) = phase else {
            return false
        }
        return activeToken == token && activeRequestID == requestID
    }

    /// Moves the current resolver into the presenting phase.
    ///
    /// Returns false for a superseded request, which must not present.
    mutating func beginPresenting(token: UUID, requestID: String) -> Bool {
        guard isResolving(token: token, requestID: requestID) else { return false }
        phase = .presenting(token: token, requestID: requestID)
        return true
    }

    /// Ends a resolve that failed or timed out, if it still owns the bridge.
    mutating func finishResolving(token: UUID, requestID: String) -> Bool {
        guard isResolving(token: token, requestID: requestID) else { return false }
        phase = .idle
        return true
    }

    /// Ends the presentation, if `requestID` still owns the bridge.
    mutating func finishPresenting(token: UUID, requestID: String) -> Bool {
        guard isPresenting(token: token, requestID: requestID) else { return false }
        phase = .idle
        return true
    }

    /// Drops any in-flight request; used when the handler is uninstalled.
    mutating func reset() {
        phase = .idle
    }
}

#if canImport(UIKit) && canImport(QuickLook)
/// Quick Look's item backed by the materialized file URL.
private final class WebEngineNativePreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?

    init(url: URL) {
        self.previewItemURL = url
    }
}
#endif

/// WKScriptMessageHandler that opens Office files in the system Quick Look
/// controller at the top of the app's view hierarchy.
@WebEngineUIActor
public final class WebEngineNativePreview: NSObject, WKScriptMessageHandler {
    /// Name the page posts to: `window.webkit.messageHandlers.pdshNativePreview`.
    public static let messageHandlerName = "pdshNativePreview"

    /// A resolve must answer before the page's own 20 s bridge timeout.
    private static let resolveTimeout: TimeInterval = 15

    private let service: WebEngineNativePreviewService
    private weak var webView: WKWebView?
    private var flight = WebEngineNativePreviewFlight()
    private var resolveTask: Task<Result<URL, WebEngineNativePreviewFailure>, Never>?
    private var resolveTimeoutTask: Task<Void, Never>?
    #if canImport(UIKit) && canImport(QuickLook)
    private var previewController: QLPreviewController?
    private var previewURL: URL?
    #endif

    /// Creates the bridge from a resolver and the host materialized workspace.
    public init(resolver: any WebEngineNativePreviewResolving,
                workspaceDirectory: URL) {
        self.service = WebEngineNativePreviewService(resolver: resolver,
                                                     workspaceDirectory: workspaceDirectory)
        super.init()
    }

    /// Creates the bridge from an already-built service.
    public init(service: WebEngineNativePreviewService) {
        self.service = service
        super.init()
    }

    /// Registers this handler on `webView` before its page loads.
    ///
    /// The host assembly may instead add this object directly to
    /// `userContentController`; both forms install the same handler name.
    public func install(on webView: WKWebView) {
        uninstall()
        self.webView = webView
        webView.configuration.userContentController.add(self,
                                                       name: Self.messageHandlerName)
    }

    /// Removes the handler and drops the weak web view reference.
    ///
    /// A resolve that is still in flight is cancelled so its late completion
    /// cannot answer (or present) after the handler was detached. Quick Look
    /// that is already on screen stays with its delegate; dismissing it still
    /// clears the presentation state through ``previewControllerDidDismiss(_:)``.
    public func uninstall() {
        if let webView = self.webView {
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: Self.messageHandlerName)
        }
        webView = nil
        if case .resolving = flight.phase {
            cancelResolution()
            flight.reset()
        }
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard let webView = self.webView, message.webView === webView,
              message.frameInfo.isMainFrame else {
            return
        }
        let body = message.body
        Task { @WebEngineUIActor [weak self, weak webView] in
            guard let self, let webView else { return }
            await self.handle(body, from: webView)
        }
    }

    private func handle(_ body: Any, from webView: WKWebView) async {
        let request: WebEngineNativePreviewRequest
        do {
            request = try WebEngineNativePreviewRequest.parse(body)
        } catch let failure as WebEngineNativePreviewFailure {
            // A well-shaped id lets the page retire its pending request even
            // when the rest of the message is refused.
            if let id = Self.replyIdentifier(in: body) {
                send(.failed(id: id, failure: failure), to: webView)
            }
            return
        } catch {
            return
        }
        // Claim the bridge before the first await. A second message that arrives
        // while this resolve is suspended therefore supersedes (and cancels)
        // this request instead of also passing an `isPresenting == false`
        // check and presenting its own controller.
        let token: UUID
        switch flight.admit(requestID: request.id) {
        case .busy:
            send(.failed(id: request.id, failure: .previewBusy(
                "Quick Look is already presenting another document")),
                 to: webView)
            return
        case .superseded(let previousRequestID, let admittedToken):
            cancelResolution()
            token = admittedToken
            // Reusing an id would settle the page's new pending request with
            // the old request's cancellation, so only report a different id.
            if previousRequestID != request.id {
                send(.failed(id: previousRequestID, failure: .previewCancelled(
                    "a newer Quick Look request replaced this one")),
                     to: webView)
            }
        case .admitted(let admittedToken):
            token = admittedToken
        }

        let service = self.service
        let resolveTask = Task { await service.resolve(request) }
        self.resolveTask = resolveTask
        let timeout = Self.resolveTimeout
        resolveTimeoutTask = Task { @WebEngineUIActor [weak self, weak webView] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, let webView else { return }
            self.failResolving(.previewTimedOut(
                "the workspace file did not resolve before the Quick Look deadline"),
                request: request, token: token, webView: webView)
        }

        let resolution = await resolveTask.value
        // A supersede, timeout or uninstall invalidated this token while the
        // stat call was suspended; its late result must not present.
        guard flight.isResolving(token: token, requestID: request.id) else { return }
        cancelResolution()
        switch resolution {
        case .failure(let failure):
            failResolving(failure, request: request, token: token, webView: webView)
        case .success(let fileURL):
            present(fileURL, request: request, token: token, from: webView)
        }
    }

    private func present(_ fileURL: URL,
                         request: WebEngineNativePreviewRequest,
                         token: UUID,
                         from webView: WKWebView) {
        #if canImport(UIKit) && canImport(QuickLook)
        // Checked again immediately before presentation: the resolver has
        // returned since the admission check and this request may be stale.
        guard flight.isResolving(token: token, requestID: request.id) else { return }
        guard let presenter = Self.topViewController() else {
            failResolving(.presentationFailed(
                "no view controller is available to present Quick Look"),
                request: request, token: token, webView: webView)
            return
        }
        let item = WebEngineNativePreviewItem(url: fileURL)
        guard QLPreviewController.canPreview(item) else {
            failResolving(.previewUnavailable(
                "Quick Look cannot preview \(Self.displayName(fileURL))"),
                request: request, token: token, webView: webView)
            return
        }
        guard flight.beginPresenting(token: token, requestID: request.id) else {
            return
        }
        let controller = QLPreviewController()
        controller.dataSource = self
        controller.delegate = self
        controller.modalPresentationStyle = .fullScreen
        previewURL = fileURL
        previewController = controller
        presenter.present(controller, animated: true) { [weak self, weak webView] in
            guard let self, let webView else { return }
            guard self.flight.isPresenting(token: token, requestID: request.id),
                  self.previewController === controller else {
                return
            }
            guard controller.presentingViewController != nil else {
                self.finishPresenting(controller: controller, token: token,
                                      requestID: request.id)
                self.send(.failed(id: request.id, failure: .presentationFailed(
                    "Quick Look did not stay on screen")), to: webView)
                return
            }
            self.send(.presented(id: request.id), to: webView)
        }
        #else
        failResolving(.previewUnavailable(
            "Quick Look is unavailable on this platform"),
            request: request, token: token, webView: webView)
        #endif
    }

    /// Cancels the resolve and timeout that belong to the current owner.
    private func cancelResolution() {
        resolveTask?.cancel()
        resolveTask = nil
        resolveTimeoutTask?.cancel()
        resolveTimeoutTask = nil
    }

    /// Resets a failed/timed-out resolve, but only when it still owns the bridge.
    private func failResolving(_ failure: WebEngineNativePreviewFailure,
                               request: WebEngineNativePreviewRequest,
                               token: UUID,
                               webView: WKWebView) {
        guard flight.isResolving(token: token, requestID: request.id) else { return }
        cancelResolution()
        _ = flight.finishResolving(token: token, requestID: request.id)
        send(.failed(id: request.id, failure: failure), to: webView)
    }

    #if canImport(UIKit) && canImport(QuickLook)
    /// Clears the presentation only when it is still the controller this bridge
    /// owns; a late callback from an older controller cannot reset a newer one.
    private func finishPresenting(controller: QLPreviewController,
                                  token: UUID,
                                  requestID: String) {
        guard previewController === controller else { return }
        guard flight.finishPresenting(token: token, requestID: requestID) else {
            return
        }
        previewController = nil
        previewURL = nil
    }
    #endif

    private func send(_ result: WebEngineNativePreviewResult, to webView: WKWebView) {
        guard let script = result.javaScriptCall() else { return }
        // The SDK's completion-handler overload names the content world with a
        // second `in:` label: evaluateJavaScript(_:in:in:completionHandler:).
        // `contentWorld:` belongs to the async overload, which takes no
        // completion handler, so a trailing closure there does not type-check.
        // This overload's handler receives one `Result`, not `(value, error)`.
        webView.evaluateJavaScript(script, in: nil, in: .page) { _ in }
    }

    private static func replyIdentifier(in body: Any) -> String? {
        guard let record = body as? [String: Any],
              let id = record["id"] as? String,
              id.isEmpty == false,
              id.utf8.count <= WebEngineNativePreviewRequest.maximumIdentifierBytes,
              id.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              }) == false else {
            return nil
        }
        return id
    }

    private static func displayName(_ url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? "this document" : "\"\(name.prefix(120))\""
    }

    #if canImport(UIKit)
    /// Topmost visible view controller, including presented and container VCs.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap {
            $0 as? UIWindowScene
        }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow })
                ?? scene?.windows.first else {
            return nil
        }
        var current: UIViewController? = window.rootViewController
        while let controller = current {
            if let presented = controller.presentedViewController {
                current = presented
                continue
            }
            if let navigation = controller as? UINavigationController,
               let visible = navigation.visibleViewController {
                current = visible
                continue
            }
            if let tab = controller as? UITabBarController,
               let selected = tab.selectedViewController {
                current = selected
                continue
            }
            break
        }
        return current
    }
    #endif
}

#if canImport(UIKit) && canImport(QuickLook)
extension WebEngineNativePreview: QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }

    public func previewController(_ controller: QLPreviewController,
                                  previewItemAt index: Int) -> QLPreviewItem {
        WebEngineNativePreviewItem(url: previewURL
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    public func previewControllerDidDismiss(_ controller: QLPreviewController) {
        // Only the controller this bridge currently owns may clear the state.
        // A superseded controller's late dismissal must not reset a newer
        // resolve or presentation.
        guard previewController === controller else { return }
        flight.reset()
        previewController = nil
        previewURL = nil
    }
}
#endif

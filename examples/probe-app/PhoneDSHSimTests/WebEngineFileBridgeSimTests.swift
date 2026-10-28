// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator: real WKWebView file-bridge fixtures.
//
// These tests exercise the production `WebEngineFileBridge` against a real
// WKWebView and a local loopback HTTP fixture. They cover what the portable
// `Tests/PhoneDSHEngineTests/WebEngineFileBridgeTests.swift` cannot:
//
//   * the engine installs the bridge as both navigation and UI delegate;
//   * an external link is handed to the system opener while the local page
//     stays in the Web view;
//   * an attachment response becomes a real WKDownload, is staged and handed
//     to the share path, then disappears on cleanup;
//   * selected files are copied into the confined staging directory for both
//     single and multiple selection, and cancellation completes exactly once;
//   * a real `<input type="file" multiple>` click reaches
//     `runOpenPanelWith`, imports the picker copy, and fires `change` with the
//     staged FileList (iOS 18.4+ runtime);
//   * a persistent engine on a stable origin sees the same
//     `dsh.sessions.current` after engine recreation and does not create a new
//     session.
//
// The document picker and activity sheet themselves are system UI and are not
// automated here; the bridge invokes its injectable picker/share seams. The
// production defaults still present `UIDocumentPickerViewController` and
// `UIActivityViewController`. This is simulator evidence, never device
// evidence. NOT_VERIFIED on a physical iPhone.

import Foundation
import Network
import UIKit
import WebKit
import XCTest
import PhoneDSHEngine

@MainActor
final class WebEngineFileBridgeSimTests: XCTestCase {
    func testEngineInstallsTheBridgeAsBothDelegates() throws {
        let configuration = WebEngineConfiguration(
            origin: URL(string: "http://127.0.0.1:1")!,
            token: "fixture-token")
        let engine = WebEngine(configuration: configuration)
        defer { engine.shutdown() }

        let bridge = try XCTUnwrap(engine.fileBridge)
        XCTAssertTrue((engine.view.navigationDelegate as AnyObject?) === bridge)
        XCTAssertTrue((engine.view.uiDelegate as AnyObject?) === bridge)
    }

    func testExternalLinkGoesToTheSystemOpenerAndStaysOutOfTheSurface() async throws {
        let server = try WebBridgeFixtureServer()
        try server.start()
        defer { server.stop() }
        let window = SimVisibleWindow()
        defer { window.shutdown() }

        let external = URL(string: "https://example.invalid/pc")!
        var opened: URL?
        let openedExpectation = expectation(
            description: "external URL is handed to the system opener")
        let bridge = WebEngineFileBridge(
            loopbackOrigin: server.baseURL,
            openExternalURL: { url in
                opened = url
                openedExpectation.fulfill()
            })
        let webView = Self.makeWebView(in: window, bridge: bridge)
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
        }

        webView.load(URLRequest(url: server.url(path: "/index.html")))
        try await Self.waitForPage(webView, timeout: 15)

        _ = try await Self.javaScript(
            webView, "document.getElementById('external').click()")
        await fulfillment(of: [openedExpectation], timeout: 10)

        XCTAssertEqual(opened, external)
        XCTAssertEqual(webView.url?.path, "/index.html",
                       "the remote PC link must not replace the local surface")
    }

    func testAttachmentDownloadIsStagedSharedAndCleanedUp() async throws {
        let server = try WebBridgeFixtureServer()
        try server.start()
        defer { server.stop() }
        let window = SimVisibleWindow()
        defer { window.shutdown() }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-bridge-sim-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var sharedURL: URL?
        var sharedData: Data?
        let downloaded = expectation(description: "download reached the share path")
        let bridge = WebEngineFileBridge(
            loopbackOrigin: server.baseURL,
            temporaryFiles: WebEngineFileBridge.TemporaryFiles(root: staging),
            shareFile: { url in
                sharedURL = url
                sharedData = try? Data(contentsOf: url)
                downloaded.fulfill()
            })
        let webView = Self.makeWebView(in: window, bridge: bridge)
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
        }

        webView.load(URLRequest(url: server.url(path: "/download")))
        await fulfillment(of: [downloaded], timeout: 20)

        let url = try XCTUnwrap(sharedURL)
        XCTAssertEqual(sharedData, WebBridgeFixtureServer.downloadBody)
        XCTAssertEqual(url.lastPathComponent, "fixture-download.txt")
        XCTAssertTrue(url.path.hasPrefix(bridge.stagingRoot.path + "/"),
                      "the share path got a file outside the staging root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        bridge.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "cleanup must remove the downloaded temporary file")
    }

    func testFileSelectionCopiesBothSingleAndMultipleSelections() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-bridge-selection-\(UUID().uuidString)",
                                    isDirectory: true)
        let first = base.appendingPathComponent("first.txt")
        let second = base.appendingPathComponent("second.txt")
        let directory = base.appendingPathComponent("folder", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base,
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try Data("first selection".utf8).write(to: first)
            try Data("second selection".utf8).write(to: second)
        } catch {
            XCTFail("could not create the selection fixtures: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: base) }

        var requestedMultiple: [Bool] = []
        var selection: [URL]? = [first, second, directory]
        let bridge = WebEngineFileBridge(
            loopbackOrigin: URL(string: "http://127.0.0.1:45231")!,
            temporaryFiles: WebEngineFileBridge.TemporaryFiles(
                root: base.appendingPathComponent("staged", isDirectory: true)),
            fileSelectionHandler: { allowsMultipleSelection, completion in
                requestedMultiple.append(allowsMultipleSelection)
                completion(selection)
            })

        var selected: [URL] = []
        let picked = expectation(description: "multiple selection completed")
        bridge.beginFileSelection(allowsMultipleSelection: true) { urls in
            selected = urls ?? []
            picked.fulfill()
        }
        await fulfillment(of: [picked], timeout: 5)

        XCTAssertEqual(requestedMultiple, [true])
        XCTAssertEqual(selected.count, 2,
                       "directories must not be imported as attachments")
        XCTAssertEqual(Set(selected.map(\.lastPathComponent)),
                       Set(["first.txt", "second.txt"]))
        for url in selected {
            XCTAssertTrue(url.path.hasPrefix(bridge.stagingRoot.path + "/"))
            XCTAssertFalse(url.path == first.path || url.path == second.path,
                           "the page must receive a copy, never the picker URL")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let firstCopy = try XCTUnwrap(
            selected.first(where: { $0.lastPathComponent == "first.txt" }))
        XCTAssertEqual(try String(contentsOf: firstCopy, encoding: .utf8),
                       "first selection")

        selection = [second]
        var singleSelected: [URL] = []
        let pickedSingle = expectation(description: "single selection completed")
        bridge.beginFileSelection(allowsMultipleSelection: false) { urls in
            singleSelected = urls ?? []
            pickedSingle.fulfill()
        }
        await fulfillment(of: [pickedSingle], timeout: 5)
        XCTAssertEqual(requestedMultiple, [true, false])
        XCTAssertEqual(singleSelected.count, 1)
        XCTAssertEqual(singleSelected.first?.lastPathComponent, "second.txt")

        selection = nil
        let cancelled = expectation(description: "picker cancellation completed")
        bridge.beginFileSelection(allowsMultipleSelection: true) { urls in
            XCTAssertNil(urls)
            cancelled.fulfill()
        }
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertEqual(requestedMultiple, [true, false, true])

        bridge.cleanup()
        for url in selected + singleSelected {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "cleanup must remove the selected-file copy")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    /// Drives the real `<input type="file" multiple>` element in a WKWebView.
    ///
    /// This is the path the portable logic test cannot reach: WebKit calls
    /// `WKUIDelegate.webView(_:runOpenPanelWith:initiatedByFrame:
    /// completionHandler:)`, the bridge imports the selected files into its
    /// staging root and hands those URLs back, and WebKit fires the page's
    /// `change` event with the staged `FileList`.
    func testLocalFileInputDrivesOpenPanelAndChangeEvent() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("WKUIDelegate.runOpenPanelWith requires iOS 18.4")
        }
        let server = try WebBridgeFixtureServer()
        try server.start()
        defer { server.stop() }
        let window = SimVisibleWindow()
        defer { window.shutdown() }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-input-sim-\(UUID().uuidString)",
                                    isDirectory: true)
        let source = base.appendingPathComponent("fixture-input.txt")
        do {
            try FileManager.default.createDirectory(at: base,
                                                    withIntermediateDirectories: true)
            try Data("input fixture bytes".utf8).write(to: source)
        } catch {
            XCTFail("could not create the input fixture: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let staging = base.appendingPathComponent("staged", isDirectory: true)
        var requestedMultiple: [Bool] = []
        let picked = expectation(description: "WebKit asked the page to open a panel")
        let bridge = WebEngineFileBridge(
            loopbackOrigin: server.baseURL,
            temporaryFiles: WebEngineFileBridge.TemporaryFiles(root: staging),
            fileSelectionHandler: { allowsMultipleSelection, completion in
                requestedMultiple.append(allowsMultipleSelection)
                completion([source])
                picked.fulfill()
            })
        let webView = Self.makeWebView(in: window, bridge: bridge)
        defer {
            webView.stopLoading()
            webView.removeFromSuperview()
            bridge.cleanup()
        }

        webView.load(URLRequest(url: server.url(path: "/index.html")))
        try await Self.waitForPage(webView, timeout: 15)

        _ = try await Self.javaScript(webView, """
            (function () {
              window.__fileChanges = 0;
              window.__fileNames = [];
              window.__fileSizes = [];
              var input = document.getElementById('file');
              input.addEventListener('change', function () {
                window.__fileChanges += 1;
                window.__fileNames = Array.from(input.files || [])
                  .map(function (file) { return file.name; });
                window.__fileSizes = Array.from(input.files || [])
                  .map(function (file) { return file.size; });
              });
              input.click();
            })();
            """)

        await fulfillment(of: [picked], timeout: 10)
        let changes = try await Self.waitForJavaScript(
            webView,
            "window.__fileChanges || 0",
            timeout: 10) { ($0 as? Int ?? 0) >= 1 }
        XCTAssertEqual(changes as? Int, 1,
                       "WebKit must fire one change event after the picker completes")
        XCTAssertEqual(requestedMultiple, [true],
                       "the multiple attribute must reach the open panel")

        let names = try await Self.javaScript(webView, "window.__fileNames") as? [String]
        XCTAssertEqual(names ?? [], ["fixture-input.txt"])
        let sizes = try await Self.javaScript(webView, "window.__fileSizes") as? [NSNumber]
        XCTAssertEqual(sizes?.map(\.intValue) ?? [],
                       [Data("input fixture bytes".utf8).count])

        let staged = try FileManager.default
            .subpathsOfDirectory(atPath: bridge.stagingRoot.path)
            .map { bridge.stagingRoot.appendingPathComponent($0) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path,
                                                      isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
        XCTAssertEqual(staged.map(\.lastPathComponent), ["fixture-input.txt"])
        XCTAssertNotEqual(staged.first?.path, source.path,
                          "the page must receive the staged copy, not the picker path")
        if let stagedFile = staged.first {
            XCTAssertEqual(try String(contentsOf: stagedFile, encoding: .utf8),
                           "input fixture bytes")
        } else {
            XCTFail("the bridge did not stage the selected file")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the user's original selection must be preserved")
    }

    /// Verifies the origin/storage half of the park/resume contract with a
    /// real WKWebView: after an engine is shut down, a new engine on the same
    /// origin and the persistent store must see the same
    /// `dsh.sessions.current`, and the page must not create a new session.
    func testSessionSelectionSurvivesEngineRecreationAtStableOrigin() async throws {
        let server = try WebBridgeFixtureServer()
        try server.start()
        defer { server.stop() }
        let window = SimVisibleWindow()
        defer { window.shutdown() }

        let sessionID = "web-session-\(UUID().uuidString)"
        let configuration = WebEngineConfiguration(
            origin: server.baseURL,
            pagePath: "/session.html",
            token: "fixture-token",
            usesPersistentWebsiteDataStore: true)

        let first = WebEngine(configuration: configuration)
        first.attach(to: window.anchor)
        defer { first.shutdown() }
        var firstURL = server.url(path: "/session.html")
        firstURL = URL(string: firstURL.absoluteString
            + "?session=\(sessionID)")!
        try await first.load(firstURL)
        let saved = try await Self.waitForJavaScript(
            first.view, "window.__session || null", timeout: 10) { $0 is String }
        XCTAssertEqual(saved as? String, sessionID)
        // Give WebKit a moment to settle the store before the engine (and its
        // web view) is destroyed by park().
        try await Task.sleep(nanoseconds: 300_000_000)
        first.shutdown()

        let second = WebEngine(configuration: configuration)
        second.attach(to: window.anchor)
        defer { second.shutdown() }
        try await second.load(server.url(path: "/session.html"))
        let restored = try await Self.waitForJavaScript(
            second.view, "window.__session || null", timeout: 10) { $0 is String }
        XCTAssertEqual(restored as? String, sessionID,
                       "the DSH session selection must survive engine recreation")
        XCTAssertEqual(server.sessionCreations, 0,
                       "a restored selection must not create a new session")
    }

    private static func makeWebView(in window: SimVisibleWindow,
                                    bridge: WebEngineFileBridge) -> WKWebView {
        let webView = WKWebView(frame: window.rootController.view.bounds,
                                configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = bridge
        webView.uiDelegate = bridge
        window.rootController.view.addSubview(webView)
        window.window.layoutIfNeeded()
        return webView
    }

    private static func javaScript(_ webView: WKWebView,
                                   _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private static func waitForPage(_ webView: WKWebView,
                                    timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = try? await javaScript(webView, "document.readyState"),
               (state as? String) == "complete" {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SimError.timeout("fixture page did not finish loading")
    }

    private static func waitForJavaScript(
        _ webView: WKWebView,
        _ script: String,
        timeout: TimeInterval,
        until predicate: (Any?) -> Bool) async throws -> Any? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? await javaScript(webView, script),
               predicate(value) {
                return value
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SimError.timeout("JavaScript condition was not met: \(script)")
    }
}

/// Minimal loopback HTTP fixture for the bridge's real WKWebView tests.
///
/// It serves one HTML page with an external link and a file input, plus one
/// attachment response. It never leaves 127.0.0.1 and records no request data.
private final class WebBridgeFixtureServer: @unchecked Sendable {
    static let downloadBody = Data("downloaded fixture bytes\n".utf8)

    private final class StartState: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error?
        var port: UInt16?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "phone.sim.web-bridge-fixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var sessionCreationsValue = 0
    private(set) var port: UInt16 = 0

    /// Number of `/session/new` requests the fixture page made. A restored
    /// `dsh.sessions.current` must leave this at zero.
    var sessionCreations: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionCreationsValue
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func url(path: String) -> URL {
        var components = URLComponents(url: baseURL,
                                       resolvingAgainstBaseURL: false)!
        components.path = path
        return components.url!
    }

    func start() throws {
        let state = StartState()
        let listener = self.listener
        listener.stateUpdateHandler = { update in
            switch update {
            case .ready:
                state.port = listener.port.map { UInt16($0.rawValue) }
                state.semaphore.signal()
            case .failed(let error):
                state.error = error
                state.semaphore.signal()
            case .cancelled:
                state.semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard state.semaphore.wait(timeout: .now() + 10) == .success else {
            throw StubServerError.startTimedOut
        }
        if let error = state.error {
            throw error
        }
        guard let port = state.port else {
            throw StubServerError.noPort
        }
        self.port = port
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        lock.lock()
        let live = connections
        connections.removeAll()
        lock.unlock()
        for connection in live {
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: accumulated, on: connection)
                return
            }
            if error == nil && !isComplete {
                self.receive(connection, buffer: accumulated)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let head = String(decoding: request, as: UTF8.self)
        let firstLine = head.split(separator: "\r\n", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"
        let path = target.split(separator: "?", maxSplits: 1,
                                omittingEmptySubsequences: false)
            .first.map(String.init) ?? target

        var status = "200 OK"
        var contentType = "text/html; charset=utf-8"
        var extraHeaders = ""
        var body = Data(Self.html.utf8)
        switch path {
        case "/", "/index.html":
            break
        case "/session.html":
            body = Data(Self.sessionHTML.utf8)
        case "/session/new":
            lock.lock()
            sessionCreationsValue += 1
            lock.unlock()
            contentType = "text/plain; charset=utf-8"
            body = Data("created-\(UUID().uuidString)".utf8)
        case "/download":
            contentType = "application/octet-stream"
            extraHeaders = "Content-Disposition: attachment; "
                + "filename=\"fixture-download.txt\"\r\n"
            body = Self.downloadBody
        default:
            status = "404 Not Found"
            contentType = "text/plain; charset=utf-8"
            body = Data("not found".utf8)
        }

        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + extraHeaders
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let html = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>bridge fixture</title>
    </head>
    <body>
      <a id="external" href="https://example.invalid/pc">remote PC</a>
      <input id="file" type="file" multiple>
    </body>
    </html>
    """

    /// Mirrors the DSH restore rule the Web surface depends on: a saved
    /// `dsh.sessions.current` is reused; only an empty selection asks the host
    /// to create a new session.
    private static let sessionHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>session storage fixture</title>
    </head>
    <body>
      <script>
        (function () {
          var requested = new URLSearchParams(location.search).get('session');
          if (requested) {
            localStorage.setItem('dsh.sessions.current', requested);
            window.__session = requested;
            window.__ready = true;
            return;
          }
          var saved = localStorage.getItem('dsh.sessions.current');
          if (saved) {
            window.__session = saved;
            window.__ready = true;
            return;
          }
          fetch('/session/new').then(function (response) {
            return response.text();
          }).then(function (id) {
            localStorage.setItem('dsh.sessions.current', id);
            window.__session = id;
            window.__ready = true;
          });
        })();
      </script>
    </body>
    </html>
    """
}

private enum StubServerError: Error, Equatable {
    case startTimedOut
    case noPort
}

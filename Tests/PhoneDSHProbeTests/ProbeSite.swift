// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — Phase 0 probe fixtures (PLAN W3-PROBES).
//
// The probe page and Worker are served by the real ``LoopbackServer`` on
// 127.0.0.1. `/v1/http` is backed by a deterministic echo/NDJSON egress so the
// Worker's `fetch` calls exercise the real HTTP/1.1 transport and chunked
// writer; `/channel` is backed by a raw binary WebSocket echo handler.
//
// The probe pages come from the test target's resource bundle (they are not
// generated from an absolute repository path).

import AppKit
import Foundation
import WebKit
import PhoneDSHEngine
import PhoneDSHHarness
import PhoneDSHLoopback

enum ProbeError: Error, CustomStringConvertible {
    case missingResource(String)
    case timeout(String)
    case scriptFailed(String)
    case workerFailed(String)
    case unexpected(String)

    var description: String {
        switch self {
        case .missingResource(let name): return "probe resource is missing: \(name)"
        case .timeout(let what): return "probe timed out: \(what)"
        case .scriptFailed(let detail): return "page script failed: \(detail)"
        case .workerFailed(let detail): return "worker reported an error: \(detail)"
        case .unexpected(let detail): return "probe failed: \(detail)"
        }
    }
}

/// Copies the bundled probe pages into one temporary directory per test.
final class ProbeSite {
    let directory: URL

    init() throws {
        guard let bundled = PhoneDSHHarnessResources.probeSiteDirectory else {
            throw ProbeError.missingResource("probe-site")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-probes-site-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["index.html", "probe-worker.js", "timer.html", "benchmark.js"] {
            let source = bundled.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw ProbeError.missingResource(name)
            }
            try FileManager.default.copyItem(to: root.appendingPathComponent(name), from: source)
        }
        directory = root
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension FileManager {
    func copyItem(to destination: URL, from source: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}

/// Deterministic `/v1/http` egress for the probe Worker.
///
/// `POST /probe/echo` returns the request body unchanged. `GET /probe/ndjson`
/// streams three canonical JSON lines with a delay between chunks so the
/// Worker can measure the first-chunk latency of the real chunked writer.
struct ProbeEgress: HTTPEgress {
    /// Delay between the NDJSON chunks, in nanoseconds.
    var ndjsonChunkDelay: UInt64 = 12_000_000

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        if request.url.path.hasSuffix("/probe/ndjson") {
            return ndjsonStream()
        }
        let body = request.body
        return AsyncThrowingStream { continuation in
            continuation.yield(HTTPEgressChunk(
                status: 200,
                headers: ["content-type": "application/octet-stream"],
                body: body,
                isFinal: true))
            continuation.finish()
        }
    }

    private func ndjsonStream() -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        let delay = ndjsonChunkDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                let lines: [Data] = [
                    Data("{\"n\":1,\"text\":\"first\"}\n".utf8),
                    Data("{\"n\":2,\"text\":\"second\"}\n".utf8),
                    Data("{\"n\":3,\"text\":\"third\"}\n".utf8),
                ]
                continuation.yield(HTTPEgressChunk(
                    status: 200,
                    headers: ["content-type": "application/x-ndjson"],
                    body: lines[0],
                    isFinal: false))
                for line in lines.dropFirst() {
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        continuation.finish()
                        return
                    }
                    continuation.yield(HTTPEgressChunk(body: line))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Raw binary WebSocket echo used by the 1000-round-trip probe.
enum ProbeEchoHandler {
    static func echo(_ connection: WebSocketConnection) async {
        while true {
            do {
                guard let message = try await connection.receive() else { return }
                switch message {
                case .binary(let data):
                    try await connection.send(binary: data)
                case .text(let text):
                    try await connection.send(text: text)
                }
            } catch {
                return
            }
        }
    }
}

/// One running loopback origin plus its per-start token.
struct ProbeServer {
    let server: LoopbackServer
    let endpoint: LoopbackEndpoint

    static func start(site: ProbeSite, crossOriginIsolation: Bool) async throws -> ProbeServer {
        let server = LoopbackServer(
            configuration: LoopbackConfiguration(token: "",
                                                 port: 0,
                                                 crossOriginIsolation: crossOriginIsolation),
            routes: LoopbackRoutes(staticDirectory: site.directory,
                                   httpEgress: ProbeEgress()),
            websocketHandler: { connection in
                await ProbeEchoHandler.echo(connection)
            })
        let endpoint = try await server.start()
        return ProbeServer(server: server, endpoint: endpoint)
    }

    var pageURL: URL {
        var components = URLComponents(url: endpoint.baseURL,
                                       resolvingAgainstBaseURL: false)!
        components.path = "/static/index.html"
        components.queryItems = [URLQueryItem(name: "token", value: endpoint.token)]
        return components.url!
    }

    func pageURL(mode: String) -> URL {
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "mode", value: mode))
        components.queryItems = items
        return components.url!
    }

    var timerURL: URL {
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        components.path = "/static/timer.html"
        return components.url!
    }

    /// The same page through `localhost` instead of `127.0.0.1`. This variant
    /// lets the probe report whether the loopback host name changes the
    /// secure-context / cross-origin-isolation result.
    func localhostPageURL(mode: String) -> URL {
        var components = URLComponents(url: pageURL(mode: mode),
                                       resolvingAgainstBaseURL: false)!
        components.host = "localhost"
        return components.url!
    }

    func stop() async {
        await server.stop()
    }
}

/// A WKWebView driven from the test. Attached views sit in an ordered window
/// with a one-point visible area; detached views never enter a window.
@MainActor
final class ProbeWebView {
    let view: WKWebView
    private var window: NSWindow?

    init(visible: Bool, width: CGFloat = 1, height: CGFloat = 1) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height),
                                configuration: configuration)
        self.view = webView
        if visible {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                                  styleMask: [.titled],
                                  backing: .buffered,
                                  defer: false)
            window.isReleasedWhenClosed = false
            window.title = "phone-dsh probe"
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
            window.contentView = container
            container.addSubview(webView)
            webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window.makeKeyAndOrderFront(nil)
            // The probe host has no `NSApplication.run`; pump the ordering and
            // activation events so WebKit sees the window as visible.
            WebEngineAppKitEventPump.pump(for: 0.05)
            self.window = window
        }
    }

    /// Loads a URL and waits until the document reports `complete`.
    ///
    /// Attached views additionally wait for WebKit to report the page visible:
    /// a hidden page is throttled, which would silently corrupt every timing
    /// probe that follows. The wait pumps AppKit events.
    func load(_ url: URL, timeout: TimeInterval = 30) async throws {
        view.load(URLRequest(url: url,
                             cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = try? await evaluateString("document.readyState"),
               state == "complete" {
                if window != nil {
                    try await waitForPageVisible(timeout: timeout)
                }
                return
            }
            try await WebEngineAppKitEventPump.wait(0.02)
        }
        throw ProbeError.timeout("page load \(url.path)")
    }

    /// Waits until the hosting window is occlusion-visible and the page reports
    /// `document.visibilityState == "visible"`.
    func waitForPageVisible(timeout: TimeInterval = 12) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var documentState: String?
        var occlusionVisible: Bool?
        while Date() < deadline {
            // Drain the queued AppKit events non-blockingly. A blocking
            // `nextEvent(until:)` here can leave WebKit's later
            // `evaluateJavaScript` completion with an unsupported result type,
            // so the loop drains and then yields.
            WebEngineAppKitEventPump.pump(for: 0)
            occlusionVisible = window.map { $0.occlusionState.contains(.visible) }
            documentState = try? await evaluateString("document.visibilityState")
            if occlusionVisible == true && documentState == "visible" {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ProbeError.unexpected(
            "the probe page is not visible: window_occlusion_visible="
                + "\(occlusionVisible.map(String.init) ?? "unknown"), "
                + "document.visibilityState=\(documentState ?? "unresponsive"). WebKit "
                + "throttles a hidden page, so the timing probes cannot run; the "
                + "macOS probe host must pump AppKit events while it waits "
                + "(WebEngineAppKitEventPump). See docs/architecture.md, page visibility.")
    }

    /// Waits for the probe page/Worker to publish `window.__probe` and returns
    /// its JSON object.
    func waitForProbeResult(timeout: TimeInterval = 120) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let json = try? await evaluateString(
                "window.__probe && window.__probe.done ? JSON.stringify(window.__probe) : null"),
               json.hasPrefix("{") {
                guard let data = json.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data))
                        as? [String: Any] else {
                    throw ProbeError.unexpected(
                        "the probe result is not a JSON object: \(json.prefix(400))")
                }
                // The page stores `{done, result, error}`; the Worker result is
                // the nested `result` object. A failed Worker leaves `result`
                // nil and the test records the page `error`.
                if let result = object["result"] as? [String: Any] {
                    return result
                }
                return object
            }
            try await WebEngineAppKitEventPump.wait(0.025)
        }
        throw ProbeError.timeout("worker probe result")
    }

    func evaluateString(_ script: String) async throws -> String? {
        let value = try await evaluate(script)
        if let text = value as? String {
            return text
        }
        if value is NSNull {
            return nil
        }
        if let value {
            return String(describing: value)
        }
        return nil
    }

    func evaluateNumber(_ script: String) async throws -> Double? {
        let value = try await evaluate(script)
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let number = value as? Double {
            return number
        }
        if let text = value as? String, let number = Double(text) {
            return number
        }
        return nil
    }

    func evaluate(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: ProbeError.scriptFailed(
                        "\(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    func teardown() {
        view.stopLoading()
        view.removeFromSuperview()
        window?.orderOut(nil)
        window?.close()
        window = nil
    }
}

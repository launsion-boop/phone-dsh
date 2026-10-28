// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: Phase 0 channel probe fixtures (PLAN W3-APP).
//
// The probe page and Worker are served by the real ``PhoneDSHLoopback``
// loopback server on 127.0.0.1. `/v1/http` is backed by a deterministic
// echo/NDJSON egress so the Worker's `fetch` calls exercise the real HTTP/1.1
// transport and chunked writer; `/channel` is backed by a raw binary WebSocket
// echo handler.
//
// The page/Worker JavaScript is not regenerated here: ProbeKit bundles the
// same `probe-site` fixture folder as the macOS probe suite (it is a resource
// of the shared `PhoneDSHHarness` target, referenced as a folder in
// project.yml), so both harnesses run one source of truth.

import Foundation
import UIKit
import WebKit
import PhoneDSHLoopback

/// Errors surfaced by the probe harness.
public enum ProbeError: Error, CustomStringConvertible {
    case missingResource(String)
    case timeout(String)
    case scriptFailed(String)
    case notAttached
    case unexpected(String)

    public var description: String {
        switch self {
        case .missingResource(let name): return "probe resource is missing: \(name)"
        case .timeout(let what): return "probe timed out: \(what)"
        case .scriptFailed(let detail): return "page script failed: \(detail)"
        case .notAttached:
            return "the probe host view is not attached to a window with one visible point"
        case .unexpected(let detail): return "probe failed: \(detail)"
        }
    }
}

/// Copies the bundled probe pages into one temporary directory per run.
public final class ProbeSite {
    public let directory: URL
    private static let fileNames = ["index.html", "probe-worker.js", "timer.html", "benchmark.js"]

    public init() throws {
        let bundles = [Bundle(for: ProbeSite.self), Bundle.main]
        var bundled: URL?
        for bundle in bundles {
            if let url = bundle.url(forResource: "probe-site", withExtension: nil) {
                bundled = url
                break
            }
        }
        guard let bundled else {
            throw ProbeError.missingResource("probe-site")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-probes-site-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in Self.fileNames {
            let source = bundled.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw ProbeError.missingResource(name)
            }
            let destination = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        directory = root
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Deterministic `/v1/http` egress for the probe Worker.
///
/// `POST /probe/echo` returns the request body unchanged. `GET /probe/ndjson`
/// streams three canonical JSON lines with a delay between chunks so the
/// Worker can measure the first-chunk latency of the real chunked writer.
public struct ProbeEgress: HTTPEgress {
    /// Delay between the NDJSON chunks, in nanoseconds.
    public var ndjsonChunkDelay: UInt64

    public init(ndjsonChunkDelay: UInt64 = 12_000_000) {
        self.ndjsonChunkDelay = ndjsonChunkDelay
    }

    public func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
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
public enum ProbeEchoHandler {
    public static func echo(_ connection: WebSocketConnection) async {
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
public struct ProbeServer {
    public let server: LoopbackServer
    public let endpoint: LoopbackEndpoint

    public static func start(site: ProbeSite,
                             crossOriginIsolation: Bool) async throws -> ProbeServer {
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

    public var pageURL: URL {
        var components = URLComponents(url: endpoint.baseURL,
                                       resolvingAgainstBaseURL: false)!
        components.path = "/static/index.html"
        components.queryItems = [URLQueryItem(name: "token", value: endpoint.token)]
        return components.url!
    }

    public func pageURL(mode: String) -> URL {
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "mode", value: mode))
        components.queryItems = items
        return components.url!
    }

    public var timerURL: URL {
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        components.path = "/static/timer.html"
        return components.url!
    }

    /// The same page through `localhost` instead of `127.0.0.1`. This variant
    /// lets the probe report whether the loopback host name changes the
    /// secure-context / cross-origin-isolation result.
    public func localhostPageURL(mode: String) -> URL {
        var components = URLComponents(url: pageURL(mode: mode),
                                       resolvingAgainstBaseURL: false)!
        components.host = "localhost"
        return components.url!
    }

    public func stop() async {
        await server.stop()
    }
}

/// A WKWebView driven from the probe UI.
///
/// A "visible" view is added to `host` (a one-point view already attached to a
/// window by the App); a detached view never enters a window. This mirrors the
/// macOS probe's visible/offscreen comparison.
@MainActor
public final class ProbeWebView {
    public let view: WKWebView

    public init(visible: Bool, host: UIView?, width: CGFloat = 1, height: CGFloat = 1) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height),
                                configuration: configuration)
        self.view = webView
        if visible, let host {
            host.addSubview(webView)
            webView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        }
    }

    /// Whether the view is in a window (the WebEngine's visibility precondition).
    public var isAttachedWithVisibleArea: Bool {
        view.superview != nil && view.window != nil && !view.isHidden
    }

    /// Loads a URL and waits until the document reports `complete`.
    public func load(_ url: URL, timeout: TimeInterval = 30) async throws {
        view.load(URLRequest(url: url,
                             cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let state = try? await evaluateString("document.readyState"),
               state == "complete" {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ProbeError.timeout("page load \(url.path)")
    }

    /// Waits for the probe page/Worker to publish `window.__probe` and returns
    /// its JSON object.
    public func waitForProbeResult(timeout: TimeInterval = 120) async throws -> [String: Any] {
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
                if let result = object["result"] as? [String: Any] {
                    return result
                }
                return object
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw ProbeError.timeout("worker probe result")
    }

    public func evaluateString(_ script: String) async throws -> String? {
        let value = try await evaluate(script)
        if let text = value as? String { return text }
        if value is NSNull { return nil }
        if let value { return String(describing: value) }
        return nil
    }

    public func evaluateNumber(_ script: String) async throws -> Double? {
        let value = try await evaluate(script)
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let text = value as? String, let number = Double(text) { return number }
        return nil
    }

    public func evaluate(_ script: String) async throws -> Any? {
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

    public func teardown() {
        view.stopLoading()
        view.removeFromSuperview()
    }
}

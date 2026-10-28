// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: upstream transport.
//
// One long-lived `URLSession` carries every model/tool request. The delegate
// object below turns URLSession callbacks into an ordered event stream so the
// gateway can make retry decisions before it writes the first downstream byte,
// while still forwarding SSE/chunked bodies as they arrive. The attempt object
// is intentionally not an `AsyncSequence` consumer of the downstream stream:
// a downstream cancellation only sets a flag, it never cancels the URLSession
// task, so the full upstream response is still received and recorded.

import Foundation
import PhoneDSHAgentCore

// MARK: - Host allow-list

/// One entry of `ModelGatewayConfiguration.allowedUpstreamHosts`.
///
/// Entry syntax: a bare host (optionally followed by `:port`), or the same
/// host with an explicit scheme. A bare host accepts any port; an explicit port
/// and an explicit scheme, when given, must match.
///
/// Two wildcard forms exist for Apps that admit more than a fixed list: `*`
/// admits every host (`https://*` every HTTPS host), and `*.corp.example`
/// admits `corp.example` together with every host below it. The wildcard only
/// widens the host check; the `CredentialProvider` still decides per host
/// whether a credential is attached, so `*` never leaks the model key.
struct GatewayHostRule: Equatable, Sendable {
    var scheme: String?
    var host: String
    var port: Int?

    init?(rawValue: String) {
        var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let separator = text.range(of: "://") {
            let scheme = String(text[..<separator.lowerBound])
            guard scheme == "http" || scheme == "https" else { return nil }
            self.scheme = scheme
            text = String(text[separator.upperBound...])
        } else {
            self.scheme = nil
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        var port: Int?
        if let colon = text.lastIndex(of: ":"), text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            let suffix = String(text[text.index(after: colon)...])
            guard let parsed = Int(suffix), parsed > 0, parsed <= 65535 else { return nil }
            port = parsed
            text = String(text[..<colon])
        }
        guard !text.isEmpty else { return nil }
        self.host = text
        self.port = port
    }

    func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if let required = self.scheme, required != scheme { return false }
        guard let candidate = url.host?.lowercased(),
              Self.hostMatches(candidate, pattern: host) else { return false }
        if let required = port {
            // URLComponents omits the scheme's default port from a serialized
            // URL, so compare the effective port instead of only the explicit
            // one. An explicit `:443` rule must admit `https://host/path`.
            let effective = url.port ?? (scheme == "https" ? 443 : 80)
            guard effective == required else { return false }
        }
        return true
    }

    /// `*` admits every host; `*.corp.example` admits `corp.example` and every
    /// host below it; anything else is an exact, case-insensitive match.
    static func hostMatches(_ candidate: String, pattern: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            guard !suffix.isEmpty else { return false }
            return candidate == suffix || candidate.hasSuffix("." + suffix)
        }
        return candidate == pattern
    }

    /// True for `*` and `*.suffix` rules, which admit more than one host.
    var isWildcard: Bool { host == "*" || host.hasPrefix("*.") }

    /// Best-effort URL used to open a connection in `prewarm()`. A wildcard
    /// rule names no connectable host and is skipped.
    func prewarmURL() -> URL? {
        guard !isWildcard else { return nil }
        let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        let scheme = self.scheme ?? (loopbackHosts.contains(host) ? "http" : "https")
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = "/"
        return components.url
    }
}

// MARK: - URLSession callbacks

enum UpstreamAttemptEvent: Sendable {
    case response(status: Int, headers: [String: String])
    case data(Data)
    /// The URLSession task completed; `error` is non-nil for a transport error
    /// (including a truncated body) and carries the underlying URLSession error
    /// so the gateway can preserve its domain and code (G2-FIX-32).
    case finished(error: Error?)
}

/// One in-flight URLSession data task and its ordered event stream.
final class UpstreamAttempt: @unchecked Sendable {
    let events: AsyncStream<UpstreamAttemptEvent>
    private let continuation: AsyncStream<UpstreamAttemptEvent>.Continuation
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var reusedConnection: Bool?
    private var didFinish = false

    init() {
        var captured: AsyncStream<UpstreamAttemptEvent>.Continuation!
        self.events = AsyncStream<UpstreamAttemptEvent> { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    func attach(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    /// Cancels the upstream task. Only used when the gateway itself abandons an
    /// attempt to retry; a downstream cancellation never calls this.
    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func receive(response status: Int, headers: [String: String]) {
        continuation.yield(.response(status: status, headers: headers))
    }

    func receive(data: Data) {
        continuation.yield(.data(data))
    }

    func complete(error: Error?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        continuation.yield(.finished(error: error))
        continuation.finish()
    }

    func recordConnectionReuse(_ reused: Bool) {
        lock.lock()
        reusedConnection = reused
        lock.unlock()
    }

    var connectionReused: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return reusedConnection
    }
}

/// The origin and normalized path a host credential was attached for. A
/// redirect may reuse that credential only when the new URL has the same
/// effective scope; otherwise the gateway returns the 3xx to the caller.
private struct GatewayCredentialRedirectScope: Equatable, Sendable {
    let scheme: String
    let host: String
    let effectivePort: Int
    let path: String

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.effectivePort = url.port ?? (scheme == "https" ? 443 : 80)
        self.path = ModelGatewayCredentialRouting.normalizedPath(url)
    }
}

/// The host credential attached to one in-flight task and the exact scope it
/// was resolved for. URLSession can build the redirect `newRequest` without the
/// `Authorization` header, so the delegate re-applies this credential after it
/// has verified the target is still inside the same scope.
private struct GatewayCredentialRedirect: Sendable {
    let scope: GatewayCredentialRedirectScope
    let credential: Credential
}

/// URLSession delegate shared by every gateway request. URLSession retains the
/// delegate, so the session must be invalidated in `ModelGateway.shutdown()`.
final class GatewaySessionCoordinator: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    private let rules: [GatewayHostRule]
    private let egressAuthorizer: (any EgressHostAuthorizing)?
    private let lock = NSLock()
    private var attempts: [Int: UpstreamAttempt] = [:]
    private var credentialRedirects: [Int: GatewayCredentialRedirect] = [:]
    private var sessionStorage: URLSession?
    private var lastReuse: Bool?
    private var shutDown = false
    let delegateQueue: OperationQueue

    init(allowedHosts: [GatewayHostRule],
         egressAuthorizer: (any EgressHostAuthorizing)? = nil) {
        self.rules = allowedHosts
        self.egressAuthorizer = egressAuthorizer
        let queue = OperationQueue()
        queue.name = "phone-dsh.phone-gateway.session"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        self.delegateQueue = queue
        super.init()
    }

    func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // A model request that finds the radio down waits for connectivity
        // instead of failing the turn; the caller can still cancel the stream.
        configuration.waitsForConnectivity = true
        // HTTP/2 is negotiated by URLSession (ALPN) and kept alive for the
        // lifetime of this single session; parallel tool/model calls need more
        // than the default per-host connection cap.
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(600, timeout)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        lock.lock()
        sessionStorage = session
        lock.unlock()
        return session
    }

    func session() -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessionStorage
    }

    func invalidate() {
        lock.lock()
        let session = sessionStorage
        sessionStorage = nil
        shutDown = true
        lock.unlock()
        session?.invalidateAndCancel()
    }

    var isShutDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shutDown
    }

    func begin(_ request: URLRequest,
               carriesHostCredential: Bool = false,
               credential: Credential? = nil) -> UpstreamAttempt {
        let attempt = UpstreamAttempt()
        guard let session = session() else {
            attempt.complete(error: URLError(.cannotConnectToHost))
            return attempt
        }
        let task = session.dataTask(with: request)
        attempt.attach(task)
        lock.lock()
        attempts[task.taskIdentifier] = attempt
        if carriesHostCredential, let url = request.url,
           let scope = GatewayCredentialRedirectScope(url),
           let credential {
            credentialRedirects[task.taskIdentifier] = GatewayCredentialRedirect(
                scope: scope,
                credential: credential)
        }
        lock.unlock()
        task.resume()
        return attempt
    }

    func isAllowed(_ url: URL) -> Bool {
        if rules.contains(where: { $0.matches(url) }) { return true }
        return egressAuthorizer?.allowsEgressHost(url) ?? false
    }

    var lastConnectionReuse: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return lastReuse
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        // A nil attempt is a `prewarm()` HEAD: allow it to complete so the
        // connection stays in the pool.
        guard let attempt = attempt(for: dataTask) else {
            completionHandler(.allow)
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        attempt.receive(response: http.statusCode, headers: headers)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        attempt(for: dataTask)?.receive(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let attempt = removeAttempt(for: task)
        attempt?.complete(error: error)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        let reused = metrics.transactionMetrics.contains { $0.isReusedConnection }
        lock.lock()
        lastReuse = reused
        lock.unlock()
        attempt(for: task)?.recordConnectionReuse(reused)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never follow a redirect outside the allow-list. A request carrying a
        // host credential may only follow a redirect whose scheme, host, port
        // and normalized path remain the same credential scope; URLSession
        // otherwise reuses headers such as `x-api-key` for the new URL. Return
        // nil to hand the 3xx response to the caller instead of forwarding the
        // credential to a same-host MCP path or another allow-listed host.
        guard let url = request.url, isAllowed(url) else {
            completionHandler(nil)
            return
        }
        if let original = credentialRedirect(for: task) {
            guard let target = GatewayCredentialRedirectScope(url),
                  target == original.scope else {
                completionHandler(nil)
                return
            }
            // URLSession builds `newRequest` from the redirect response and can
            // omit the host-managed `Authorization` header. The target is
            // already verified to be the exact same scope, so re-apply the
            // credential the gateway resolved for it instead of relying on
            // URLSession's header copy. The Worker never sees this value.
            var redirected = request
            original.credential.apply(to: &redirected)
            completionHandler(redirected)
            return
        }
        completionHandler(request)
    }

    /// Whether a redirect stays inside the exact credential scope the gateway
    /// already authenticated. Queries are not part of the credential scope;
    /// trailing separators are normalized so `/mcp` and `/mcp/` compare equal.
    static func sameCredentialScope(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftScheme = lhs.scheme?.lowercased(),
              let rightScheme = rhs.scheme?.lowercased(),
              leftScheme == "http" || leftScheme == "https",
              rightScheme == leftScheme,
              let leftHost = lhs.host?.lowercased(),
              let rightHost = rhs.host?.lowercased(),
              !leftHost.isEmpty,
              leftHost == rightHost else { return false }
        let leftPort = lhs.port ?? (leftScheme == "https" ? 443 : 80)
        let rightPort = rhs.port ?? (rightScheme == "https" ? 443 : 80)
        guard leftPort == rightPort else { return false }
        return ModelGatewayCredentialRouting.normalizedPath(lhs)
            == ModelGatewayCredentialRouting.normalizedPath(rhs)
    }

    private func attempt(for task: URLSessionTask) -> UpstreamAttempt? {
        lock.lock()
        defer { lock.unlock() }
        return attempts[task.taskIdentifier]
    }

    private func credentialRedirect(for task: URLSessionTask) -> GatewayCredentialRedirect? {
        lock.lock()
        defer { lock.unlock() }
        return credentialRedirects[task.taskIdentifier]
    }

    private func removeAttempt(for task: URLSessionTask) -> UpstreamAttempt? {
        lock.lock()
        defer { lock.unlock() }
        credentialRedirects.removeValue(forKey: task.taskIdentifier)
        return attempts.removeValue(forKey: task.taskIdentifier)
    }
}

// MARK: - Metrics, replay window and downstream bridge

/// Thread-safe counters behind `ModelGateway.metrics()`.
final class GatewayMetricsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var bytesUp = 0
    private var bytesDown = 0
    private var retries = 0
    private var replayHits = 0
    private var workerCredentialsDropped = 0
    private var resumeHits = 0
    private var resumeBytes = 0
    private var resumeMisses = 0

    func beginRequest() {
        lock.lock()
        inFlight += 1
        lock.unlock()
    }

    func endRequest() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
    }

    func addRequestBytes(_ count: Int) {
        lock.lock()
        bytesUp += count
        lock.unlock()
    }

    func addResponseBytes(_ count: Int) {
        lock.lock()
        bytesDown += count
        lock.unlock()
    }

    func recordRetry() {
        lock.lock()
        retries += 1
        lock.unlock()
    }

    func recordReplayHit() {
        lock.lock()
        replayHits += 1
        lock.unlock()
    }

    func recordDroppedWorkerCredential() {
        lock.lock()
        workerCredentialsDropped += 1
        lock.unlock()
    }

    func recordResumeHit(bytes: Int) {
        lock.lock()
        resumeHits += 1
        resumeBytes += max(0, bytes)
        lock.unlock()
    }

    func recordResumeMiss() {
        lock.lock()
        resumeMisses += 1
        lock.unlock()
    }

    func snapshot(connectionReused: Bool?) -> ModelGatewayMetrics {
        lock.lock()
        defer { lock.unlock() }
        return ModelGatewayMetrics(inFlight: inFlight,
                                   bytesUp: bytesUp,
                                   bytesDown: bytesDown,
                                   retries: retries,
                                   replayHits: replayHits,
                                   connectionReused: connectionReused,
                                   workerCredentialsDropped: workerCredentialsDropped,
                                   resumeHits: resumeHits,
                                   resumeBytes: resumeBytes,
                                   resumeMisses: resumeMisses)
    }
}

/// The host-controlled replay window. The controller opens it while the host
/// state machine is Recovering, so retried model calls are served from the
/// response log instead of the upstream.
final class GatewayReplayWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func set(open: Bool) {
        lock.lock()
        self.open = open
        lock.unlock()
    }
}

/// One downstream consumer. Termination is observed but never forwarded to
/// the upstream: the pump keeps reading so the response can be recorded.
final class GatewayDownstream: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<GatewayResponseChunk, Error>.Continuation
    private let lock = NSLock()
    private var cancelled = false
    private var terminated = false
    private var finished = false

    init(_ continuation: AsyncThrowingStream<GatewayResponseChunk, Error>.Continuation) {
        self.continuation = continuation
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func observe(_ termination: AsyncThrowingStream<GatewayResponseChunk, Error>.Continuation.Termination) {
        lock.lock()
        if case .cancelled = termination {
            cancelled = true
        }
        terminated = true
        lock.unlock()
    }

    func yield(_ chunk: GatewayResponseChunk) {
        lock.lock()
        let canWrite = !terminated && !finished
        lock.unlock()
        if canWrite {
            continuation.yield(chunk)
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !terminated, !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

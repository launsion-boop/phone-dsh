// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: model gateway.
//
// PLAN §2.1/§2.5. The gateway is the App-process HTTP client for model
// upstreams: it forwards request and SSE response bytes, keeps a bounded
// content-addressed response log for replay while the host recovers, injects
// credentials so the Worker never sees a key, and applies the Backoff state's
// 429/5xx/transport retry policy. It does not implement a model. Model bodies
// are forwarded unchanged; only host-managed MCP response bodies are rewritten
// to remove the credentials the host injected (see SensitiveResponseBody).
//
// The module depends on PhoneDSHAgentCore only. The loopback origin lives in
// PhoneDSHLoopback (which depends on this direction would be a cycle),
// so the request/response value types are defined here and `GatewayEgressAdapter`
// exposes the closure shape the facade maps onto `HTTPEgress`.

import Foundation
import PhoneDSHAgentCore

// MARK: - Configuration

/// Backoff policy for upstream 429, 5xx and transport failures (PLAN §2.5).
public struct ModelGatewayBackoffPolicy: Equatable, Sendable {
    /// Delay before the first retry, in seconds.
    public var initialDelay: TimeInterval
    /// Multiplier applied after each failed attempt.
    public var multiplier: Double
    /// Upper bound of one delay, in seconds.
    public var maximumDelay: TimeInterval
    /// Fraction of the delay randomized into `[delay·(1−jitter), delay]`.
    public var jitterFraction: Double
    /// Total attempts including the first one.
    ///
    /// The W1-GATEWAY spec says "at most 5 attempts", so the default five means
    /// four retries (delays 1, 2, 4 and 8 s), not five retries.
    public var maximumAttempts: Int

    public init(initialDelay: TimeInterval = 1,
                multiplier: Double = 2,
                maximumDelay: TimeInterval = 60,
                jitterFraction: Double = 0.2,
                maximumAttempts: Int = 5) {
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
        self.maximumDelay = max(0, maximumDelay)
        self.jitterFraction = min(max(0, jitterFraction), 1)
        self.maximumAttempts = max(1, maximumAttempts)
    }

    /// Delay before the retry that follows attempt `retry` (1-based).
    ///
    /// A `Retry-After` hint wins over the exponential schedule and is clamped
    /// to `maximumDelay`; otherwise the delay is exponential with optional
    /// downward jitter.
    public func delay(forRetry retry: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter {
            return min(maximumDelay, max(0, retryAfter))
        }
        let exponent = Double(max(0, retry - 1))
        let exponential = initialDelay * pow(multiplier, exponent)
        let capped = min(maximumDelay, exponential)
        guard jitterFraction > 0 else { return capped }
        return capped * Double.random(in: (1 - jitterFraction)...1)
    }
}

/// Model gateway configuration.
public struct ModelGatewayConfiguration: Equatable, Sendable {
    /// Response log cap of PLAN §2.3.
    public static let defaultResponseLogQuotaBytes = 128 * 1024 * 1024

    /// Upstream hosts the gateway may connect to; empty denies every host.
    ///
    /// Entries are a bare host (optionally followed by `:port`) or the same
    /// host with an explicit scheme. A bare host accepts any port.
    public var allowedUpstreamHosts: Set<String>
    /// Exact model endpoint URLs explicitly approved for POST retries. A
    /// match requires the same scheme, host, effective port and path; query
    /// parameters do not affect the classification. Empty disables POST
    /// retries, including for requests to ``allowedUpstreamHosts``.
    public var replaySafeModelEndpoints: Set<String>
    /// Bounded response log size; least recently used entries are evicted.
    public var responseLogQuotaBytes: Int
    /// Request headers that participate in the response-log key.
    public var responseLogHeaderNames: Set<String>
    /// 429/5xx/transport backoff policy.
    public var backoff: ModelGatewayBackoffPolicy
    /// Timeout of one upstream attempt, in seconds.
    public var upstreamRequestTimeout: TimeInterval
    /// How long a resumed request waits for the original recording to commit.
    ///
    /// The Worker asks to resume a response body at a byte offset after its
    /// downstream consumer stopped pulling (a suspended WebKit page, a broken
    /// stream hop). The gateway may still be recording the upstream body, so a
    /// resume waits up to this interval for the response-log commit before it
    /// fails the request. It never re-contacts the upstream. A constant rather
    /// than a stored field keeps ``ModelGatewayConfiguration``'s layout stable
    /// for the already-compiled host modules. A recording that is still
    /// streaming after this interval is treated as not recoverable (the stall
    /// self-test's upstream never completes).
    public static let defaultResumeWaitSeconds: TimeInterval = 4

    public init(allowedUpstreamHosts: Set<String> = [],
                replaySafeModelEndpoints: Set<String> = [],
                responseLogQuotaBytes: Int = ModelGatewayConfiguration.defaultResponseLogQuotaBytes,
                responseLogHeaderNames: Set<String> = ["accept", "content-type"],
                backoff: ModelGatewayBackoffPolicy = ModelGatewayBackoffPolicy(),
                upstreamRequestTimeout: TimeInterval = 60) {
        self.allowedUpstreamHosts = allowedUpstreamHosts
        self.replaySafeModelEndpoints = replaySafeModelEndpoints
        self.responseLogQuotaBytes = max(0, responseLogQuotaBytes)
        self.responseLogHeaderNames = Set(responseLogHeaderNames.map { $0.lowercased() })
        self.backoff = backoff
        self.upstreamRequestTimeout = max(1, upstreamRequestTimeout)
    }

    /// The model endpoints a Worker posts to under one provider base URL:
    /// `<base>/v1/messages`, `<base>/messages`, `<base>/v1/chat/completions`
    /// and `<base>/chat/completions`. Hosts pass the result as
    /// ``replaySafeModelEndpoints`` so model POSTs keep the gateway's 429/5xx
    /// backoff (and `Retry-After`) while ordinary egress POSTs stay single-shot.
    /// The base's query and fragment are dropped; an unusable base yields `[]`.
    public static func standardModelEndpoints(baseURL: URL) -> Set<String> {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else { return [] }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        var endpoints: Set<String> = []
        for suffix in ["/v1/messages", "/messages", "/v1/chat/completions", "/chat/completions"] {
            components.path = basePath + suffix
            if let url = components.url { endpoints.insert(url.absoluteString) }
        }
        return endpoints
    }

    /// The one allow-list the gateway enforces (ENG-04): the model upstream
    /// hosts plus the hosts the App/scenario explicitly admits for Worker
    /// `/v1/http` egress (`scenario.json` `network.allow`).
    ///
    /// The union is the contract; callers never pass only one of the two to
    /// the gateway. An empty result denies every host.
    public static func effectiveAllowedUpstreamHosts(modelHosts: Set<String>,
                                                     egressAllowHosts: Set<String>) -> Set<String> {
        modelHosts.union(egressAllowHosts)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }
}

// MARK: - Request, response and errors

/// One model/tool request forwarded by the host (`/v1/http` egress,
/// spec/exec-bridge-v1 §6). `method` and `url` are the upstream target; the
/// gateway drops every `Authorization`/`Proxy-Authorization`/`X-PDSH-*` header
/// before injecting the credential from the `CredentialProvider`.
///
/// Spec/exec-bridge-v1 §6 relays a harness-supplied upstream `Authorization`
/// as `X-PDSH-Upstream-Authorization`. PLAN's security decision makes the host
/// credential authoritative, so that relay is dropped too;
/// `ModelGatewayMetrics.workerCredentialsDropped` exposes how often it
/// happened instead of discarding it silently.
public struct GatewayRequest: Equatable, Sendable {
    /// Worker → host: resume a previously delivered response body at this
    /// byte offset. The gateway serves the suffix from its response log and
    /// never re-contacts the upstream.
    public static let resumeFromHeader = "x-pdsh-resume-from"
    /// Host → Worker: marks a response served from the response log because of
    /// ``resumeFromHeader``.
    public static let resumedHeader = "x-pdsh-resumed"

    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// One downstream response chunk. The first chunk carries `status` and the
/// response headers; later chunks carry body bytes only; the last chunk has
/// `isFinal` set. The loopback layer maps this 1:1 to its `HTTPEgressChunk`.
public struct GatewayResponseChunk: Equatable, Sendable {
    public var status: Int?
    public var headers: [String: String]
    public var body: Data
    public var isFinal: Bool

    public init(status: Int? = nil, headers: [String: String] = [:], body: Data = Data(),
                isFinal: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.isFinal = isFinal
    }
}

/// Gateway failures. Messages carry a host name or a short reason only; the
/// credential, request headers and request body never appear here.
public enum ModelGatewayError: Error, Equatable, Sendable {
    case hostNotAllowed(String)
    case invalidRequest(String)
    case credentialUnavailable
    case upstreamFailed(String)
    case shuttingDown
    /// The upstream transport failed after the retry budget. The URLSession
    /// error domain and code are preserved so the failure is diagnosable from
    /// the `/v1/http` response and the run log instead of a generic
    /// "transport failure" string (G2-FIX-32).
    case transportFailure(reason: String, underlyingDomain: String, underlyingCode: Int)
    /// A model-side caller needs a 2xx and treats the upstream status as the
    /// failure cause (the retry budget is already exhausted). `/v1/http` maps
    /// it to the `upstream_status` class of the egress taxonomy (ENG-04);
    /// plain tool egress never uses this case because it forwards the upstream
    /// response unchanged.
    case upstreamStatus(status: Int, host: String)
}

extension ModelGatewayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .hostNotAllowed(let host):
            return "upstream host is not allowed: \(host)"
        case .invalidRequest(let reason):
            return "invalid gateway request: \(reason)"
        case .credentialUnavailable:
            return "no credential is configured for the upstream host"
        case .upstreamFailed(let reason):
            return "upstream request failed: \(reason)"
        case .shuttingDown:
            return "model gateway is shutting down"
        case .transportFailure(let reason, let domain, let code):
            return "upstream transport failed: \(reason) (\(domain) \(code))"
        case .upstreamStatus(let status, let host):
            return "upstream \(host) answered HTTP \(status)"
        }
    }
}

extension ModelGatewayError {
    /// Stable lower-snake cause code. This is the value the loopback
    /// `/v1/http` layer copies into the response `error.code` and the
    /// `X-PDSH-Proxy-Error` header, and into the run-log diagnostic.
    public var structuredErrorCode: String {
        switch self {
        case .hostNotAllowed:
            return "host_not_allowed"
        case .invalidRequest:
            return "invalid_request"
        case .credentialUnavailable:
            return "credential_unavailable"
        case .upstreamFailed:
            return "upstream_failed"
        case .shuttingDown:
            return "shutting_down"
        case .transportFailure:
            return "transport_failure"
        case .upstreamStatus:
            return "upstream_status"
        }
    }

    /// HTTP status the loopback `/v1/http` layer writes when this failure
    /// happens before a response head (spec/exec-bridge-v1 §6): 403 for a
    /// disallowed origin, 502 for a proxy-side failure.
    public var proxyStatusCode: Int {
        switch self {
        case .hostNotAllowed:
            return 403
        case .invalidRequest:
            return 400
        case .credentialUnavailable, .upstreamFailed, .shuttingDown,
             .transportFailure, .upstreamStatus:
            return 502
        }
    }

    /// Value of the `X-PDSH-Proxy-Error` header for `proxyStatusCode`.
    public var proxyErrorCode: String {
        switch self {
        case .hostNotAllowed:
            return "forbidden"
        case .invalidRequest:
            return "bad_request"
        case .credentialUnavailable:
            return "credential_unavailable"
        case .upstreamFailed, .transportFailure, .upstreamStatus:
            return "upstream"
        case .shuttingDown:
            return "shutting_down"
        }
    }
}

/// Cross-module bridge to the loopback `/v1/http` writer.
///
/// `PhoneDSHGateway` cannot import `PhoneDSHLoopback` (the
/// dependency direction of PLAN §2.1) and the loopback writer only receives
/// `any Error` from the egress stream. Foundation's standard NSError
/// `userInfo` keys are therefore the contract between the two modules:
/// ``ModelGatewayError/structuredErrorCode`` travels in
/// `NSLocalizedFailureReasonErrorKey` and a transport cause in
/// `NSUnderlyingErrorKey`. The loopback failure envelope reads exactly those
/// keys (`HTTPEgressFailure(error:)`).
extension ModelGatewayError: CustomNSError {
    public static var errorDomain: String { "PhoneDSHGateway.ModelGatewayError" }

    /// One distinct code per case; 0 is never used.
    public var errorCode: Int {
        switch self {
        case .hostNotAllowed: return 1
        case .invalidRequest: return 2
        case .credentialUnavailable: return 3
        case .upstreamFailed: return 4
        case .shuttingDown: return 5
        case .transportFailure: return 6
        case .upstreamStatus: return 7
        }
    }

    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: errorDescription ?? structuredErrorCode,
            NSLocalizedFailureReasonErrorKey: structuredErrorCode,
        ]
        if case .transportFailure(let reason, let domain, let code) = self {
            info[NSUnderlyingErrorKey] = NSError(
                domain: domain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return info
    }
}

// MARK: - Clock

/// Clock injection point for retry backoff tests.
public protocol GatewayClock: Sendable {
    /// Current wall-clock time, used to resolve an HTTP-date `Retry-After`.
    var now: Date { get }
    /// Suspends for `seconds`; throwing cancels the retry loop.
    func sleep(for seconds: TimeInterval) async throws
}

/// Wall clock used in production.
public struct SystemGatewayClock: GatewayClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 3600) * 1_000_000_000))
    }
}

// MARK: - Metrics

/// Counters exposed by `ModelGateway.metrics()`.
public struct ModelGatewayMetrics: Equatable, Sendable {
    /// Requests accepted and not yet fully received.
    public var inFlight: Int
    /// Request body bytes handed to URLSession, across attempts.
    public var bytesUp: Int
    /// Response body bytes received from upstream, across attempts.
    public var bytesDown: Int
    /// Retries scheduled.
    public var retries: Int
    /// Responses answered from the response log.
    public var replayHits: Int
    /// Reuse flag of the most recent `URLSessionTaskMetrics`, when collected.
    public var connectionReused: Bool?
    /// Requests that carried a Worker `Authorization`,
    /// `Proxy-Authorization` or `X-PDSH-Upstream-Authorization` header which the
    /// gateway discarded before injecting the host credential (PLAN §2.5).
    public var workerCredentialsDropped: Int
    /// Resume requests served from the committed response log.
    public var resumeHits: Int
    /// Response body bytes re-delivered by those resumes.
    public var resumeBytes: Int
    /// Resume requests whose recording was not committed before the wait
    /// interval elapsed.
    public var resumeMisses: Int

    public init(inFlight: Int = 0,
                bytesUp: Int = 0,
                bytesDown: Int = 0,
                retries: Int = 0,
                replayHits: Int = 0,
                connectionReused: Bool? = nil,
                workerCredentialsDropped: Int = 0,
                resumeHits: Int = 0,
                resumeBytes: Int = 0,
                resumeMisses: Int = 0) {
        self.inFlight = inFlight
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.retries = retries
        self.replayHits = replayHits
        self.connectionReused = connectionReused
        self.workerCredentialsDropped = workerCredentialsDropped
        self.resumeHits = resumeHits
        self.resumeBytes = resumeBytes
        self.resumeMisses = resumeMisses
    }
}

// MARK: - Gateway

/// App-process model gateway (PLAN §2.5).
///
/// One actor owns one long-lived `URLSession`. The public `handle` entry point
/// is nonisolated: it starts a pump task and returns a response stream, so a
/// caller may bridge it onto the loopback `HTTPEgress` protocol without an
/// actor hop in the hot path.
public actor ModelGateway {
    public nonisolated let configuration: ModelGatewayConfiguration

    private nonisolated let credentialProvider: any CredentialProvider
    private nonisolated let egressAuthorizer: (any EgressHostAuthorizing)?
    private nonisolated let responseLog: (any ResponseLogging)?
    private nonisolated let responseOutcomeHandler: (@Sendable (GatewayResponseReceipt) -> Void)?
    private nonisolated let clock: any GatewayClock
    private nonisolated let hostRules: [GatewayHostRule]
    private nonisolated let coordinator: GatewaySessionCoordinator
    private nonisolated let session: URLSession
    private nonisolated let metricsStore = GatewayMetricsStore()
    private nonisolated let replayWindow = GatewayReplayWindow()

    private var prewarmTasks: [URLSessionTask] = []
    private var isShutdown = false

    /// Creates the gateway.
    ///
    /// - Parameters:
    ///   - configuration: Upstream allow-list, response-log and retry policy.
    ///   - credentialProvider: Host-side credential source.
    ///   - responseLog: Optional bounded response log.
    ///   - responseOutcomeHandler: Optional bounded terminal-outcome callback
    ///     (committed/replayed/resumed). It receives only the response key,
    ///     status, body size and disposition, never the body or credentials.
    ///   - clock: Retry/backoff clock.
    public init(configuration: ModelGatewayConfiguration,
                credentialProvider: any CredentialProvider,
                responseLog: (any ResponseLogging)? = nil,
                responseOutcomeHandler: (@Sendable (GatewayResponseReceipt) -> Void)? = nil,
                clock: any GatewayClock = SystemGatewayClock(),
                egressAuthorizer: (any EgressHostAuthorizing)? = nil) {
        self.configuration = configuration
        self.credentialProvider = credentialProvider
        self.responseLog = responseLog
        self.responseOutcomeHandler = responseOutcomeHandler
        self.clock = clock
        self.egressAuthorizer = egressAuthorizer
        let rules = configuration.allowedUpstreamHosts.compactMap(GatewayHostRule.init(rawValue:))
        self.hostRules = rules
        let coordinator = GatewaySessionCoordinator(allowedHosts: rules,
                                                    egressAuthorizer: egressAuthorizer)
        self.coordinator = coordinator
        self.session = coordinator.makeSession(timeout: configuration.upstreamRequestTimeout)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Replay window (owned by the host state machine)

    /// Opens or closes the replay window. The controller opens it while the
    /// host state machine is Recovering.
    public nonisolated func setReplayWindow(open: Bool) {
        replayWindow.set(open: open)
    }

    public nonisolated func openReplayWindow() {
        replayWindow.set(open: true)
    }

    public nonisolated func closeReplayWindow() {
        replayWindow.set(open: false)
    }

    public nonisolated func isReplayWindowOpen() -> Bool {
        replayWindow.isOpen
    }

    private nonisolated func emitResponseReceipt(_ receipt: GatewayResponseReceipt) {
        responseOutcomeHandler?(receipt)
    }

    // MARK: - Requests

    /// Streams one upstream response as bytes arrive.
    ///
    /// The stream may fail with `ModelGatewayError`; it never exposes a
    /// credential. Cancelling the consumer does not cancel the upstream task:
    /// the response is still received and committed to the response log.
    public nonisolated func handle(_ request: GatewayRequest) -> AsyncThrowingStream<GatewayResponseChunk, Error> {
        let replayOpen = replayWindow.isOpen
        metricsStore.beginRequest()
        return AsyncThrowingStream<GatewayResponseChunk, Error> { continuation in
            let downstream = GatewayDownstream(continuation)
            continuation.onTermination = { termination in
                downstream.observe(termination)
            }
            Task { [self] in
                await perform(request, replayOpen: replayOpen, downstream: downstream)
                metricsStore.endRequest()
            }
        }
    }

    /// Opens one connection per allow-listed host. Called by the facade when
    /// returning to the foreground so the first model call does not pay for
    /// the TCP/TLS setup.
    public func prewarm() {
        guard !isShutdown else { return }
        prewarmTasks.removeAll { $0.state == .completed || $0.state == .canceling }
        for rule in hostRules {
            guard let url = rule.prewarmURL() else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = min(configuration.upstreamRequestTimeout, 15)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let task = session.dataTask(with: request)
            prewarmTasks.append(task)
            task.resume()
        }
    }

    /// Cancels in-flight work and invalidates the one URLSession. Idempotent.
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        prewarmTasks.forEach { $0.cancel() }
        prewarmTasks.removeAll()
        coordinator.invalidate()
    }

    /// Builds the workspace response log with the quota from `configuration`.
    /// The facade injects the result into `init(configuration:...)`.
    public nonisolated static func makeResponseLog(configuration: ModelGatewayConfiguration,
                                                   workspaceRoot: URL) throws -> ResponseLog {
        try ResponseLog(root: workspaceRoot, quotaBytes: configuration.responseLogQuotaBytes)
    }

    /// Snapshot of the gateway counters.
    public nonisolated func metrics() -> ModelGatewayMetrics {
        metricsStore.snapshot(connectionReused: coordinator.lastConnectionReuse)
    }

    // MARK: - Pump

    private nonisolated func perform(_ request: GatewayRequest,
                                     replayOpen: Bool,
                                     downstream: GatewayDownstream) async {
        let method = request.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !method.isEmpty else {
            downstream.finish(throwing: ModelGatewayError.invalidRequest("empty method"))
            return
        }
        guard let url = request.url as URL?,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            downstream.finish(throwing: ModelGatewayError.invalidRequest("upstream URL must be http(s)"))
            return
        }
        guard coordinator.isAllowed(url) else {
            downstream.finish(throwing: ModelGatewayError.hostNotAllowed(url.host ?? ""))
            return
        }
        guard !coordinator.isShutDown else {
            downstream.finish(throwing: ModelGatewayError.shuttingDown)
            return
        }

        let key = ResponseLog.cacheKey(method: method,
                                       url: url,
                                       headers: request.headers,
                                       body: request.body,
                                       headerAllowList: configuration.responseLogHeaderNames)

        switch Self.resumeOffset(request.headers) {
        case .valid(let offset):
            await serveResume(key: key, offset: offset, downstream: downstream)
            return
        case .invalid:
            // A resume header that cannot be parsed is never a fresh request:
            // re-contacting the upstream would bill a new response and hide a
            // malformed Worker retry.
            downstream.finish(throwing: ModelGatewayError.invalidRequest(
                "invalid \(GatewayRequest.resumeFromHeader) header"))
            return
        case .absent:
            break
        }

        if replayOpen, let log = responseLog, let replay = await log.replay(key: key) {
            metricsStore.recordReplayHit()
            emitResponseReceipt(GatewayResponseReceipt(key: key,
                                                       status: replay.status,
                                                       bodyBytes: replay.body.count,
                                                       disposition: .replayed))
            var headers = Self.filteredResponseHeaders(replay.headers)
            headers["x-pdsh-replayed"] = "1"
            downstream.yield(GatewayResponseChunk(status: replay.status,
                                                  headers: headers,
                                                  body: Data(),
                                                  isFinal: false))
            if !replay.body.isEmpty {
                downstream.yield(GatewayResponseChunk(body: replay.body, isFinal: false))
            }
            downstream.yield(GatewayResponseChunk(isFinal: true))
            downstream.finish()
            return
        }

        // The Worker's credential is never authoritative (PLAN §2.5): the host
        // provider injects it below. Count the discard so the
        // spec/exec-bridge-v1 §6 relay seam is observable, not silent.
        if Self.hasWorkerCredentialHeaders(request.headers) {
            metricsStore.recordDroppedWorkerCredential()
        }

        let requestID = UUID().uuidString
        var attemptNumber = 0
        let maximumAttempts = max(1, configuration.backoff.maximumAttempts)
        let requestMayRetry = Self.isReplaySafeRequest(
            method: method, url: url, replaySafeModelEndpoints: configuration.replaySafeModelEndpoints)
        var logSequence: UInt64 = 0

        while true {
            attemptNumber += 1
            let credential: Credential
            do {
                credential = try await credentialProvider.credential(
                    for: ModelGatewayCredentialRouting.scope(for: url))
            } catch {
                downstream.finish(throwing: ModelGatewayError.credentialUnavailable)
                return
            }

            // A host-managed MCP credential is the only authentication the
            // upstream sees. A malicious or misconfigured MCP server can echo
            // it in an error body/header, so this response must not enter the
            // on-disk response log. The body is also rewritten before it can
            // reach the Worker: a non-2xx body is replaced by a controlled
            // status diagnostic, while a 2xx JSON/SSE body is inspected and
            // exact injected values (including the credential part of a
            // standard Authorization scheme) are redacted; JSON structure and
            // the JSON-RPC id are preserved. This is intentionally not a full
            // response pass-through.
            let sensitive = Self.usesHostInjectedCredential(request, credential)
            let redactedValues = Self.credentialSecretValues(credential)
            let upstreamRequest = makeURLRequest(request, method: method, url: url, credential: credential)
            metricsStore.addRequestBytes(request.body.count)
            let carriesHostCredential = Self.credentialCarriesSecret(credential)
            let attempt = coordinator.begin(
                upstreamRequest,
                carriesHostCredential: carriesHostCredential,
                credential: carriesHostCredential ? credential : nil)

            var headReceived = false
            var headForwarded = false
            var logStarted = false
            var attemptFailed = false
            var attemptFailure: Error?
            var retryDelay: TimeInterval?
            var shouldRetry = false
            var sensitiveMode: SensitiveResponseMode = .ordinary
            var sensitiveBuffer = Data()

            attemptLoop: for await event in attempt.events {
                switch event {
                case .response(let status, let headers):
                    guard !headReceived else { continue }
                    headReceived = true
                    if !downstream.isCancelled,
                       requestMayRetry,
                       Self.isRetryableStatus(status),
                       attemptNumber < maximumAttempts {
                        retryDelay = configuration.backoff.delay(
                            forRetry: attemptNumber,
                            retryAfter: Self.retryAfter(headers: headers, now: clock.now))
                        shouldRetry = true
                        attempt.cancel()
                        break attemptLoop
                    }
                    var responseHeaders = Self.filteredResponseHeaders(
                        headers, redacting: redactedValues)
                    if sensitive {
                        if SensitiveResponseBody.statusForbidsBody(status: status,
                                                                   method: method) {
                            sensitiveMode = .suppressed
                        } else if !(200...299).contains(status) {
                            // The status is the diagnostic; the upstream body
                            // is never forwarded for a host-managed row.
                            let diagnostic = SensitiveResponseBody.controlledDiagnostic(
                                status: status)
                            sensitiveMode = .controlled(diagnostic)
                            responseHeaders["content-type"] = "application/json; charset=utf-8"
                        } else if SensitiveResponseBody.isEventStream(headers) {
                            sensitiveMode = .eventStream(
                                SensitiveSSESanitizer(secrets: redactedValues))
                        } else {
                            sensitiveMode = .buffered
                        }
                    }
                    if !downstream.isCancelled {
                        downstream.yield(GatewayResponseChunk(status: status,
                                                              headers: responseHeaders,
                                                              body: Data(),
                                                              isFinal: false))
                        headForwarded = true
                    }
                    if !sensitive, let log = responseLog {
                        try? await log.begin(requestID: requestID,
                                             key: key,
                                             status: status,
                                             headers: responseHeaders)
                        logStarted = true
                    }
                case .data(let data):
                    metricsStore.addResponseBytes(data.count)
                    if headForwarded, !downstream.isCancelled {
                        switch sensitiveMode {
                        case .ordinary:
                            downstream.yield(GatewayResponseChunk(body: data, isFinal: false))
                        case .eventStream(let sanitizer):
                            for event in sanitizer.consume(data) {
                                downstream.yield(GatewayResponseChunk(body: event,
                                                                      isFinal: false))
                            }
                            if sanitizer.overflowed {
                                // A single SSE event grew past the bound
                                // without a blank line. The head already said
                                // text/event-stream, so fail closed with a
                                // controlled SSE event and cancel the
                                // upstream instead of buffering forever.
                                if !downstream.isCancelled {
                                    downstream.yield(GatewayResponseChunk(
                                        body: SensitiveResponseBody
                                            .controlledEventStreamOversizeEvent(),
                                        isFinal: false))
                                }
                                sensitiveMode = .suppressed
                                attempt.cancel()
                                break attemptLoop
                            }
                        case .buffered:
                            // The upstream is untrusted. A 2xx JSON/text body
                            // is only buffered up to a fixed bound; an
                            // oversized body fails closed and cancels the
                            // upstream task so neither the App nor the
                            // URLSession event queue keeps growing.
                            let remaining = SensitiveResponseBody.maximumBufferedBodyBytes
                                - sensitiveBuffer.count
                            guard data.count <= remaining else {
                                sensitiveBuffer.removeAll(keepingCapacity: false)
                                sensitiveMode = .controlled(
                                    SensitiveResponseBody.controlledOversizeDiagnostic())
                                attempt.cancel()
                                break attemptLoop
                            }
                            sensitiveBuffer.append(data)
                        case .controlled, .suppressed:
                            // The upstream body is the sensitive surface; it
                            // is discarded even when the connection completes.
                            break
                        }
                    }
                    // Record after forwarding so the caller's first byte never
                    // waits for the response log's disk I/O.
                    if !sensitive, logStarted, let log = responseLog {
                        do {
                            try await log.append(ResponseLogEntry(requestID: requestID,
                                                                  sequence: logSequence,
                                                                  body: data))
                            logSequence &+= 1
                        } catch {
                            // A failed append leaves the recording incomplete;
                            // `finish` below only commits a consistent body and
                            // reports whether the entry was retained.
                        }
                    }
                case .finished(let error):
                    if error != nil, sensitiveMode.discardsUpstreamBody {
                        // The controlled diagnostic/no-body decision was made
                        // from the head; a body transport error cannot leak or
                        // invalidate the sanitized response.
                        attemptFailed = false
                        attemptFailure = nil
                    } else {
                        attemptFailed = error != nil
                        attemptFailure = error
                    }
                    break attemptLoop
                }
            }

            if shouldRetry {
                metricsStore.recordRetry()
                do {
                    try await clock.sleep(for: retryDelay ?? 0)
                } catch {
                    downstream.finish(throwing: ModelGatewayError.upstreamFailed("retry cancelled"))
                    return
                }
                continue
            }

            if logStarted, let log = responseLog {
                if attemptFailed {
                    await log.abort(requestID: requestID)
                } else {
                    do {
                        // One atomic call: the receipt is non-nil only when the
                        // commit is still retained after quota eviction. A
                        // separate `receipt(key:)` lookup would race a
                        // concurrent finish that evicts this entry and would
                        // then have to invent a "committed" outcome for a key
                        // that no longer exists.
                        if let committed = try await log.finish(requestID: requestID) {
                            emitResponseReceipt(GatewayResponseReceipt(
                                key: committed.key,
                                status: committed.status,
                                bodyBytes: committed.bodyBytes,
                                disposition: .committed))
                        }
                    } catch {
                        // The response still reaches the caller; the absent
                        // receipt is the loud, bounded signal that it was not
                        // durably committed for replay.
                    }
                }
            }

            if attemptFailed {
                // A transport error is retried only before anything was written
                // downstream; once the head or a body byte went out the caller
                // sees the failure and the response is not retried.
                if !headReceived, !downstream.isCancelled, requestMayRetry,
                   attemptNumber < maximumAttempts {
                    metricsStore.recordRetry()
                    let delay = configuration.backoff.delay(forRetry: attemptNumber, retryAfter: nil)
                    do {
                        try await clock.sleep(for: delay)
                    } catch {
                        downstream.finish(throwing: ModelGatewayError.upstreamFailed("retry cancelled"))
                        return
                    }
                    continue
                }
                downstream.finish(throwing: Self.transportFailure(attemptFailure))
                return
            }

            if downstream.isCancelled {
                // The upstream completed and was recorded; nobody is listening.
                downstream.finish()
                return
            }
            switch sensitiveMode {
            case .eventStream(let sanitizer):
                if let tail = sanitizer.finish(), !tail.isEmpty {
                    downstream.yield(GatewayResponseChunk(body: tail, isFinal: false))
                }
            case .buffered:
                let body = SensitiveResponseBody.sanitizeBufferedBody(
                    sensitiveBuffer, secrets: redactedValues)
                if !body.isEmpty {
                    downstream.yield(GatewayResponseChunk(body: body, isFinal: false))
                }
            case .controlled(let body):
                if !body.isEmpty {
                    downstream.yield(GatewayResponseChunk(body: body, isFinal: false))
                }
            case .ordinary, .suppressed:
                break
            }
            downstream.yield(GatewayResponseChunk(isFinal: true))
            downstream.finish()
            return
        }
    }

    // MARK: - Resumed delivery

    /// Tri-state parse of `x-pdsh-resume-from`.
    ///
    /// `.absent` is a fresh request. `.invalid` covers an empty, non-decimal,
    /// negative or overflowing value, and a second differently-cased spelling
    /// of the same logical header (the caller must not guess which one wins).
    nonisolated static func resumeOffset(_ headers: [String: String]) -> ResumeOffset {
        let matches = headers.filter { $0.key.lowercased() == GatewayRequest.resumeFromHeader }
        guard let header = matches.first else { return .absent }
        guard matches.count == 1 else { return .invalid }
        let trimmed = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let offset = Int(trimmed),
              offset >= 0 else {
            return .invalid
        }
        return .valid(offset)
    }

    /// Parsed logical resume header. Kept separate from `Int?` so an absent
    /// header is never confused with a malformed one.
    enum ResumeOffset: Equatable {
        case absent
        case valid(Int)
        case invalid
    }

    /// Serves the bytes after `offset` of a committed response body.
    ///
    /// A Worker whose downstream consumer stopped pulling (a suspended WebKit
    /// page) aborts its fetch; the host gateway keeps receiving the upstream
    /// body and commits it to the response log. The Worker's resume request
    /// then reads the suffix from disk, so a completed model response is never
    /// lost at a delivery boundary and the upstream is never contacted twice.
    private nonisolated func serveResume(key: String,
                                         offset: Int,
                                         downstream: GatewayDownstream) async {
        guard let log = responseLog else {
            downstream.finish(throwing: ModelGatewayError.upstreamFailed(
                "the host response log is not configured"))
            return
        }
        let deadline = Date().addingTimeInterval(ModelGatewayConfiguration.defaultResumeWaitSeconds)
        while true {
            if downstream.isCancelled {
                downstream.finish()
                return
            }
            switch await log.replay(key: key, offset: offset) {
            case .replay(let replay):
                metricsStore.recordResumeHit(bytes: replay.body.count - offset)
                emitResponseReceipt(GatewayResponseReceipt(key: key,
                                                           status: replay.status,
                                                           bodyBytes: replay.body.count,
                                                           disposition: .resumed))
                var headers = Self.filteredResponseHeaders(replay.headers)
                headers[GatewayRequest.resumedHeader] = "1"
                downstream.yield(GatewayResponseChunk(status: replay.status,
                                                      headers: headers,
                                                      body: Data(),
                                                      isFinal: false))
                let suffix = replay.body.dropFirst(offset)
                var start = suffix.startIndex
                while start < suffix.endIndex {
                    if downstream.isCancelled {
                        downstream.finish()
                        return
                    }
                    let end = suffix.index(start, offsetBy: min(16 * 1024,
                                                               suffix.distance(from: start,
                                                                               to: suffix.endIndex)))
                    downstream.yield(GatewayResponseChunk(body: Data(suffix[start..<end])))
                    start = end
                }
                downstream.yield(GatewayResponseChunk(isFinal: true))
                downstream.finish()
                return
            case .offsetOutOfRange:
                downstream.finish(throwing: ModelGatewayError.invalidRequest(
                    "resume offset is past the recorded response body"))
                return
            case .missing:
                break
            }
            if Date() >= deadline {
                metricsStore.recordResumeMiss()
                downstream.finish(throwing: ModelGatewayError.upstreamFailed(
                    "the previously delivered response is not committed yet"))
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Request construction

    private nonisolated func makeURLRequest(_ request: GatewayRequest,
                                            method: String,
                                            url: URL,
                                            credential: Credential) -> URLRequest {
        var upstream = URLRequest(url: url)
        upstream.httpMethod = method
        upstream.timeoutInterval = configuration.upstreamRequestTimeout
        upstream.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            let lowercased = name.lowercased()
            if Self.droppedRequestHeaders.contains(lowercased) || lowercased.hasPrefix("x-pdsh-") {
                continue
            }
            // A host-managed header's Worker value is a non-secret placeholder.
            // The host credential router injects the real, scoped value (or
            // nothing at all); the placeholder must never reach the server.
            if value == Self.hostManagedHeaderPlaceholder { continue }
            upstream.setValue(value, forHTTPHeaderField: name)
        }
        // The worker's Authorization (plain or `X-PDSH-Upstream-Authorization`)
        // was removed above; the host credential is the only one sent.
        credential.apply(to: &upstream)
        if !request.body.isEmpty {
            upstream.httpBody = request.body
        }
        return upstream
    }

    /// Value the Worker puts in a header whose real value is injected by the
    /// host-side MCP credential router. Kept in sync with
    /// `plugins/phone-mcp/src/schema.ts`.
    public static let hostManagedHeaderPlaceholder = "phone-host-injects-mcp-key"

    /// Headers that must not be copied from the worker's proxy request.
    private static let droppedRequestHeaders: Set<String> = [
        "authorization", "proxy-authorization", "host", "connection",
        "content-length", "transfer-encoding", "accept-encoding", "expect",
        "upgrade", "te", "trailer", "proxy-connection",
        // The Worker's same-origin XHR carries the loopback launch cookie and
        // a loopback Referer. They authenticate this origin, not the upstream.
        "cookie", "cookie2", "referer", "referrer",
    ]

    /// True when the Worker supplied a credential the gateway replaces. Plain
    /// `Authorization` is the loopback bridge token/Worker header;
    /// `X-PDSH-Upstream-Authorization` is the §6 relay of an upstream value.
    private nonisolated static func hasWorkerCredentialHeaders(_ headers: [String: String]) -> Bool {
        headers.keys.contains { name in
            switch name.lowercased() {
            case "authorization", "proxy-authorization", "x-pdsh-upstream-authorization":
                return true
            default:
                return false
            }
        }
    }

    /// Headers that must not be copied from the upstream response: URLSession
    /// already decoded the content encoding, the loopback layer owns the
    /// framing, and browser control headers must not act on the loopback
    /// origin (launch cookie / alternative service).
    private static let droppedResponseHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length",
        "content-encoding", "set-cookie", "set-cookie2", "clear-site-data",
        "alt-svc", "alt-used",
    ]

    /// Response headers whose values are protocol/framing inputs rather than
    /// untrusted diagnostic text. Only this small allow list keeps its
    /// protocol meaning instead of being blindly substituted: the media type
    /// is validated below, and the two MCP transport headers must stay exact
    /// for the client to keep its session. Everything else (date, etag,
    /// last-modified, vary, retry-after, ...) is still exact-value redacted
    /// because an upstream can echo the injected credential in any diagnostic
    /// header.
    private static let structuralResponseHeaders: Set<String> = [
        "content-type", "mcp-session-id", "mcp-protocol-version",
    ]

    private nonisolated static func filteredResponseHeaders(
        _ headers: [String: String],
        redacting secrets: [String] = []
    ) -> [String: String] {
        var filtered: [String: String] = [:]
        for (name, value) in headers {
            let lowercased = name.lowercased()
            guard !droppedResponseHeaders.contains(lowercased) else { continue }
            guard structuralResponseHeaders.contains(lowercased) else {
                filtered[lowercased] = redactingSecrets(value, in: secrets)
                continue
            }
            switch lowercased {
            case "content-type":
                // Only a valid media type (plus well-formed, secret-free
                // parameters) is forwarded. A short injected value must not
                // rewrite "application/json"/"text/event-stream", and a
                // header that is exactly the credential is not a usable media
                // type, so it is replaced with a neutral one rather than
                // echoed.
                filtered[lowercased] = secrets.isEmpty
                    ? value
                    : sanitizedContentType(value, secrets: secrets)
            default:
                // mcp-session-id / mcp-protocol-version: exact values are
                // needed by the client. If the value contains an injected
                // credential anywhere (including a prefix/suffix wrapper),
                // withhold the header (fail closed) instead of forwarding a
                // secret or substituting a broken protocol value.
                if secrets.contains(where: { value.contains($0) }) { continue }
                filtered[lowercased] = value
            }
        }
        filtered["cache-control"] = "no-store"
        return filtered
    }

    /// Validates an upstream content-type before the Worker sees it. The media
    /// type must be a real `type/subtype`; parameters are kept only when they
    /// are syntactically well formed and do not contain an exact injected
    /// value. The media type itself is never substring-rewritten: a short
    /// credential such as "a" must not turn "application/json" into a broken
    /// value.
    private nonisolated static func sanitizedContentType(
        _ value: String,
        secrets: [String]
    ) -> String {
        let fallback = "application/octet-stream"
        let components = value.split(separator: ";", omittingEmptySubsequences: false)
        let mediaType = (components.first.map { String($0) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidMediaType(mediaType) else { return fallback }
        // The two media types that give the response its protocol structure
        // are known values, not attacker-controlled text: a short credential
        // such as "a" must not rewrite "application/json" or
        // "text/event-stream". An unknown (but syntactically valid) media type
        // is still untrusted text, so fail closed when it embeds an injected
        // value rather than echoing it through the protocol header.
        let knownStructuralMediaTypes: Set<String> = [
            "application/json", "text/event-stream",
        ]
        let lowercasedMediaType = mediaType.lowercased()
        if !knownStructuralMediaTypes.contains(lowercasedMediaType),
           secrets.contains(where: { mediaType.contains($0) }) {
            return fallback
        }
        var result = mediaType
        for component in components.dropFirst() {
            let parameter = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = parameter.firstIndex(of: "=") else { continue }
            let name = parameter[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let rawValue = parameter[parameter.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard isValidContentTypeToken(name),
                  !secrets.contains(name),
                  isValidContentTypeParameterValue(rawValue),
                  !secrets.contains(where: { rawValue.contains($0) }) else {
                continue
            }
            result += "; \(name)=\(rawValue)"
        }
        return result
    }

    private nonisolated static func isValidMediaType(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: "/") else { return false }
        let type = value[..<separator]
        let subtype = value[value.index(after: separator)...]
        return isValidContentTypeToken(String(type))
            && isValidContentTypeToken(String(subtype))
    }

    private nonisolated static func isValidContentTypeToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
                && !separators.contains(scalar)
        }
    }

    private nonisolated static func isValidContentTypeParameterValue(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.hasPrefix("\"") {
            guard value.count >= 2, value.hasSuffix("\"") else { return false }
            let inner = value.dropFirst().dropLast()
            return inner.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
            }
        }
        return isValidContentTypeToken(value)
    }

    /// True when this request is authenticated by a host-injected MCP header
    /// map (or still carries its non-secret placeholder). Such responses are
    /// excluded from the on-disk response log and their body is rewritten by
    /// ``SensitiveResponseBody`` before it reaches the Worker.
    private nonisolated static func usesHostInjectedCredential(
        _ request: GatewayRequest,
        _ credential: Credential
    ) -> Bool {
        if case .headers(let headers) = credential.kind, !headers.isEmpty {
            return true
        }
        return request.headers.values.contains { $0 == hostManagedHeaderPlaceholder }
    }

    /// Whether this credential applied real header material to the request.
    /// A `.headers` credential has an empty `value` (the values live in the
    /// associated map), so the scalar check alone would let a redirected MCP
    /// request reuse those headers for a different path/host.
    private nonisolated static func credentialCarriesSecret(_ credential: Credential) -> Bool {
        switch credential.kind {
        case .none:
            return false
        case .headers(let headers):
            return !headers.isEmpty
        case .bearer, .apiKey:
            return !credential.value.isEmpty
        }
    }

    private nonisolated static func credentialSecretValues(_ credential: Credential) -> [String] {
        guard case .headers(let headers) = credential.kind else { return [] }
        var values: [String] = []
        for (name, value) in headers where !value.isEmpty {
            values.append(value)
            // A server that echoes only the credential part of a standard
            // Authorization value (for example "mcp-token" from
            // "Bearer mcp-token") is still echoing the exact injected secret.
            // Derive that part from the header the host actually injected;
            // this is not a guessed token-shape regex.
            guard Self.schemeBearingCredentialHeaders.contains(name.lowercased()),
                  let separator = value.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }
            let scheme = value[..<separator].lowercased()
            guard Self.standardAuthorizationSchemes.contains(scheme) else { continue }
            let remainder = value[value.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                values.append(remainder)
            }
        }
        return Array(Set(values))
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
            }
    }

    private static let schemeBearingCredentialHeaders: Set<String> = [
        "authorization", "proxy-authorization",
    ]

    /// Standard authentication schemes whose value is followed by the actual
    /// credential. Only these headers get the exact-suffix variant; arbitrary
    /// header values with spaces are left untouched.
    private static let standardAuthorizationSchemes: Set<String> = [
        "bearer", "basic", "token",
    ]

    private nonisolated static func redactingSecrets(_ text: String,
                                                     in secrets: [String]) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return result
    }

    private nonisolated static func isRetryableStatus(_ status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    /// GET/HEAD are safe to replay on any allowed host. POST is retryable only
    /// when the exact endpoint is explicitly configured by the host.
    nonisolated static func isReplaySafeRequest(method: String,
                                                url: URL,
                                                replaySafeModelEndpoints: Set<String>) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD": return true
        case "POST":
            return replaySafeModelEndpoints.contains { configured in
                guard let endpoint = URLComponents(string: configured),
                      endpoint.user == nil, endpoint.password == nil,
                      endpoint.query == nil, endpoint.fragment == nil,
                      let configuredURL = endpoint.url,
                      let endpointScheme = configuredURL.scheme?.lowercased(),
                      let requestScheme = url.scheme?.lowercased(),
                      let endpointHost = configuredURL.host?.lowercased(),
                      let requestHost = url.host?.lowercased(),
                      endpointScheme == requestScheme,
                      endpointHost == requestHost,
                      configuredURL.path == url.path else { return false }
                func port(_ value: URL, scheme: String) -> Int? {
                    value.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : nil))
                }
                return port(configuredURL, scheme: endpointScheme)
                    == port(url, scheme: requestScheme)
            }
        default: return false
        }
    }

    /// Builds the terminal transport failure without losing the URLSession
    /// error identity (`GatewaySessionCoordinator` forwards it from
    /// `didCompleteWithError`). The reason is capped and newline-free because
    /// it is echoed into the `/v1/http` response body and the run log.
    nonisolated static func transportFailure(_ error: Error?) -> ModelGatewayError {
        let bridged = error as NSError?
        let domain = bridged?.domain ?? NSURLErrorDomain
        let code = bridged?.code ?? URLError.unknown.rawValue
        let raw = bridged?.localizedDescription ?? "the connection ended without a response"
        let reason = String(raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(256))
        return .transportFailure(reason: reason,
                                 underlyingDomain: domain,
                                 underlyingCode: code)
    }

    /// `Retry-After` in seconds or as an HTTP date.
    nonisolated static func retryAfter(headers: [String: String], now: Date) -> TimeInterval? {
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

// MARK: - Loopback bridge

/// Closure-shaped adapter the facade maps onto `HTTPEgress`.
///
/// The facade's conformance converts `HTTPEgressRequest` to `GatewayRequest`
/// and each `GatewayResponseChunk` to `HTTPEgressChunk`; this type exists so
/// that `PhoneDSHGateway` does not import `PhoneDSHLoopback`
/// (the module dependency direction of PLAN §2.1).
public struct GatewayEgressAdapter: Sendable {
    public let gateway: ModelGateway

    public init(gateway: ModelGateway) {
        self.gateway = gateway
    }

    public func handle(_ request: GatewayRequest) -> AsyncThrowingStream<GatewayResponseChunk, Error> {
        gateway.handle(request)
    }

    /// The function form a facade stores in its `HTTPEgress` conformance.
    public var handler: @Sendable (GatewayRequest) -> AsyncThrowingStream<GatewayResponseChunk, Error> {
        { [gateway] request in
            gateway.handle(request)
        }
    }
}

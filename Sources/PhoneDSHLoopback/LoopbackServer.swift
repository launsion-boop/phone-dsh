// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: the one loopback origin.
//
// PLAN §2.2 and PLAN W1-LOOPBACK. One Network.framework listener on
// 127.0.0.1 binds an ephemeral port and serves everything the Worker needs:
//
//   GET  /                       page (index.html)       GET /static/*      worker scripts
//   GET  /image/base|/image/lazy|/image/overlay
//   GET  /channel                RFC 6455 ordered channel (`?token=`)
//   POST /v1/exec, /v1/fs/*, /v1/lifecycle  → ExecBridgeHosting
//   ANY  /v1/http                → HTTPEgress (the model gateway in the plan)
//   ANY  /mcp*                   → configured loopback MCP server
//   GET  /v1/hello               merged capability document
//
// Security: the origin is the only allowed `Origin`, the per-start 128-bit
// token is required as `Authorization: Bearer` or `?token=`, and every
// response is `Cache-Control: no-store`.
//
// D22: the page response (`GET /?token=...`, or `/static/*.html`) also sets an
// `HttpOnly; SameSite=Strict` cookie carrying that same launch token. The page
// and `/api/*` then accept EITHER the cookie OR `?token=` so page-relative
// `boot.js` / `worker-entry.js` requests need no query rewriting. Every other
// route keeps the pre-D22 rule (Bearer or `?token=` only); a request with no
// credential is still 401 and a wrong credential is still 403.

import Foundation
import Network
import PhoneDSHAgentCore
import PhoneDSHWire

/// Loopback server addresses handed to the app after ``LoopbackServer/start()``.
public struct LoopbackEndpoint: Equatable, Sendable {
    /// `http://127.0.0.1:<port>` (no trailing slash).
    public let baseURL: URL
    /// The per-start 128-bit token.
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// The exact `Origin` value the server accepts.
    public var origin: String { baseURL.absoluteString }
}

/// Route handlers and resources of the loopback origin.
public struct LoopbackRoutes: Sendable {
    /// Directory with `index.html`, `boot.js`, `worker-entry.js`, `client.js`.
    public var staticDirectory: URL?
    /// `image.tar.gz` served at `/image/base`.
    public var imageBaseURL: URL?
    /// `lazy/<sha256>.tar.gz`; the closure receives the sha256 and returns the
    /// file URL, or nil for 404.
    public var lazyImageProvider: (@Sendable (String) -> URL?)?
    /// `<boot_id>.tar` boot overlay file, unique per boot; the closure receives
    /// the boot id and returns the file URL, or nil for 404. The file name keeps
    /// the pre-D21 route contract; its bytes are the gzip member of D21.
    public var overlayProvider: (@Sendable (String) -> URL?)?
    /// `/v1/http` implementation (the model gateway).
    public var httpEgress: (any HTTPEgress)?
    /// Target of the `/v1/exec*`, `/v1/fs/*` and `/v1/lifecycle` routes.
    public var execBridge: (any ExecBridgeHosting)?
    /// Base URL of the loopback MCP server; `/mcp*` is reverse-proxied there.
    public var mcpBaseURL: URL?
    /// Executor for the read-only accelerators (`0x20 EXEC_REQ`).
    public var execProvider: (any ExecProvider)?
    public var workspaceLog: (any LoopbackWorkspaceLog)?
    /// Journal append and persisted per-session high-water seam (`0x30`); the
    /// ordered channel derives `acked_jseq` from it across reconnects (D2).
    public var journalLog: (any LoopbackJournalLog)?
    /// Read-only command accelerators advertised in the host HELLO caps.
    public var accelerators: [String]
    /// Mount table reported by `/v1/hello` (`host path → guest path`).
    public var mounts: [String: String]
    /// Admission gate seen by EXEC_REQ handling.
    public var admission: @Sendable () async -> Admission

    public init(staticDirectory: URL? = nil,
                imageBaseURL: URL? = nil,
                lazyImageProvider: (@Sendable (String) -> URL?)? = nil,
                overlayProvider: (@Sendable (String) -> URL?)? = nil,
                httpEgress: (any HTTPEgress)? = nil,
                execBridge: (any ExecBridgeHosting)? = nil,
                mcpBaseURL: URL? = nil,
                execProvider: (any ExecProvider)? = nil,
                workspaceLog: (any LoopbackWorkspaceLog)? = nil,
                journalLog: (any LoopbackJournalLog)? = nil,
                accelerators: [String] = [],
                mounts: [String: String] = [:],
                admission: @escaping @Sendable () async -> Admission = { .open }) {
        self.staticDirectory = staticDirectory
        self.imageBaseURL = imageBaseURL
        self.lazyImageProvider = lazyImageProvider
        self.overlayProvider = overlayProvider
        self.httpEgress = httpEgress
        self.execBridge = execBridge
        self.mcpBaseURL = mcpBaseURL
        self.execProvider = execProvider
        self.workspaceLog = workspaceLog
        self.journalLog = journalLog
        self.accelerators = accelerators
        self.mounts = mounts
        self.admission = admission
    }
}

/// The single loopback HTTP+WebSocket origin.
public actor LoopbackServer {
    /// Name of the `HttpOnly; SameSite=Strict` cookie set on the page response
    /// (D22). Its value is the per-start launch token.
    public static let launchCookieName = "xl_launch_token"

    private var configuration: LoopbackConfiguration
    private let routes: LoopbackRoutes
    /// Optional route mapping from the W0 skeleton; authenticates first, then
    /// delegates the path decision. Built-in routing is used when nil.
    private let routing: (any LoopbackRouting)?
    private let channelStateProvider: ChannelHostStateProvider?
    private let channelHandlerFactory: (@Sendable (any ChannelOutbound) -> any ChannelHandling)?
    private let websocketHandler: (@Sendable (WebSocketConnection) async -> Void)?
    private let ackCoalescingInterval: TimeInterval
    private let forwarder = URLSessionForwarder()

    private var listener: LoopbackListener?
    private var endpointValue: LoopbackEndpoint?
    private var generatedToken = false
    private var connections: [UUID: ConnectionChannel] = [:]

    public init(configuration: LoopbackConfiguration = LoopbackConfiguration(),
                routes: LoopbackRoutes = LoopbackRoutes(),
                routing: (any LoopbackRouting)? = nil,
                channelStateProvider: ChannelHostStateProvider? = nil,
                channelHandlerFactory: (@Sendable (any ChannelOutbound) -> any ChannelHandling)? = nil,
                websocketHandler: (@Sendable (WebSocketConnection) async -> Void)? = nil,
                ackCoalescingInterval: TimeInterval = 0.002) {
        self.configuration = configuration
        self.routes = routes
        self.routing = routing
        self.channelStateProvider = channelStateProvider
        self.channelHandlerFactory = channelHandlerFactory
        self.websocketHandler = websocketHandler
        self.ackCoalescingInterval = ackCoalescingInterval
    }

    /// The running endpoint, or nil before ``start()``.
    public var endpoint: LoopbackEndpoint? { endpointValue }

    /// Binds 127.0.0.1, generates the per-start token when the configuration
    /// does not pin one, and returns the base URL + token.
    public func start() async throws -> LoopbackEndpoint {
        if let endpointValue { return endpointValue }
        let token: String
        if configuration.token.isEmpty {
            token = LoopbackToken.make()
            generatedToken = true
        } else {
            token = configuration.token
            generatedToken = false
        }
        let listener = LoopbackListener { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }
        do {
            let port = try await listener.start(host: LoopbackConfiguration.loopbackHost,
                                                port: configuration.port)
            guard let url = URL(string: "http://127.0.0.1:\(port)") else {
                listener.stop()
                throw LoopbackError.invalidEndpoint("the bound port is not a valid URL")
            }
            self.listener = listener
            self.configuration.token = token
            let endpoint = LoopbackEndpoint(baseURL: url, token: token)
            self.endpointValue = endpoint
            return endpoint
        } catch {
            listener.stop()
            throw error
        }
    }

    /// Stops accepting, cancels live connections and drops the token.
    public func stop() async {
        listener?.stop()
        listener = nil
        endpointValue = nil
        for connection in connections.values { await connection.cancel() }
        connections.removeAll()
        if generatedToken {
            configuration.token = ""
            generatedToken = false
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) async {
        let channel = ConnectionChannel(connection: connection)
        let id = UUID()
        connections[id] = channel
        do {
            try await channel.start()
        } catch {
            connections[id] = nil
            await channel.cancel()
            return
        }
        await serve(channel)
        connections[id] = nil
    }

    private func serve(_ channel: ConnectionChannel) async {
        var reader = HTTPRequestReader(channel: channel,
                                       maxBodyBytes: configuration.maxRequestBodyBytes)
        let writer = HTTPResponseWriter(channel: channel)
        do {
            while true {
                guard let request = try await reader.nextRequest() else { break }
                let reply = await route(request)
                if case .upgrade = reply {
                    try await writer.write(reply, keepAlive: true)
                    let websocket = WebSocketConnection(channel: channel,
                                                       initialBuffer: reader.bufferedBytes)
                    reader.bufferedBytes = Data()
                    await runWebSocket(websocket)
                    return
                }
                try await writer.write(reply, keepAlive: request.keepAlive,
                                       headRequest: request.method == "HEAD")
                if !request.keepAlive { break }
            }
        } catch let error as HTTPTransportError {
            try? await writer.write(.json(error.status, code: "bad_request",
                                          message: error.publicMessage),
                                    keepAlive: false)
        } catch {
            // The peer went away mid-response. Nothing to report.
        }
        await channel.cancel()
    }

    private func runWebSocket(_ websocket: WebSocketConnection) async {
        if let websocketHandler {
            await websocketHandler(websocket)
            await websocket.close()
            return
        }
        guard let channelStateProvider else {
            await websocket.close(code: 1011)
            return
        }
        do {
            var state = try await channelStateProvider()
            for accelerator in routes.accelerators {
                let capability = "accelerator:\(accelerator)"
                if !state.caps.contains(capability) { state.caps.append(capability) }
            }
            let server = ChannelServer(socket: websocket,
                                       state: state,
                                       handler: nil,
                                       workspaceLog: routes.workspaceLog,
                                       journalLog: routes.journalLog,
                                       admission: routes.admission,
                                       ackCoalescingInterval: ackCoalescingInterval)
            let handler: any ChannelHandling
            if let channelHandlerFactory {
                handler = channelHandlerFactory(server)
            } else {
                handler = DefaultChannelHandling(outbound: server,
                                                 workspaceLog: routes.workspaceLog,
                                                 journalLog: routes.journalLog,
                                                 execProvider: routes.execProvider,
                                                 accelerators: routes.accelerators,
                                                 admission: routes.admission)
            }
            try await server.installHandler(handler)
            await server.run()
        } catch {
            await websocket.close(code: 1011)
        }
    }

    // MARK: - Routing

    private var originString: String { endpointValue?.baseURL.absoluteString ?? "" }

    private func route(_ request: HTTPRequest) async -> LoopbackReply {
        // 1. Origin: a request that carries one must carry exactly our origin.
        if let origin = request.header("origin"), origin != originString {
            return .json(403, code: "forbidden", message: "origin mismatch")
        }
        // 2. Token: Bearer header or `?token=` (page, scripts, archives, WS).
        //    D22 adds the page cookie as an alternative on the page, static
        //    assets and `/api/*`; every other route keeps the old rule.
        guard let token = endpointValue?.token else {
            return .json(503, code: "unavailable", message: "the loopback server is stopping")
        }
        let path = request.path
        let acceptsCookie = path == "/" || path.hasPrefix("/static/")
            || path == "/api" || path.hasPrefix("/api/")
        let queryToken = request.query["token"]
        let cookieToken = acceptsCookie
            ? Self.cookieValue(named: Self.launchCookieName,
                               in: request.header("cookie"))
            : nil
        let candidates = [Self.bearerToken(request.header("authorization")),
                          queryToken, cookieToken].compactMap { $0 }
        guard candidates.isEmpty == false else {
            return .json(401, code: "unauthorized", message: "missing token")
        }
        guard candidates.contains(where: { LoopbackToken.constantTimeEquals($0, token) }) else {
            return .json(403, code: "forbidden", message: "wrong token")
        }

        if let routing {
            let loopbackRequest = LoopbackRequest(method: request.method,
                                                  path: request.target,
                                                  headers: request.headers,
                                                  body: request.body)
            let mapped = await routing.route(loopbackRequest)
            return await reply(for: mapped, request: request, token: token)
        }

        if path == "/" || path.hasPrefix("/static/") {
            guard request.method == "GET" || request.method == "HEAD" else {
                return .json(405, code: "method_not_allowed", message: "GET only")
            }
            let relative = path == "/" ? "index.html" : String(path.dropFirst("/static/".count))
            return staticReply(relative, page: true, token: token)
        }
        if path == "/image/base" {
            guard request.method == "GET" else { return methodNotAllowed() }
            guard let url = routes.imageBaseURL else { return notFound() }
            return fileReply(url, contentType: "application/gzip")
        }
        if path.hasPrefix("/image/lazy/") {
            guard request.method == "GET" else { return methodNotAllowed() }
            let name = String(path.dropFirst("/image/lazy/".count))
            guard name.hasSuffix(".tar.gz") else { return notFound() }
            let sha = String(name.dropLast(".tar.gz".count))
            guard Self.isLowercaseHex(sha, length: 64) else { return notFound() }
            guard let url = routes.lazyImageProvider?(sha) else { return notFound() }
            return fileReply(url, contentType: "application/gzip")
        }
        if path.hasPrefix("/image/overlay/") {
            guard request.method == "GET" else { return methodNotAllowed() }
            let name = String(path.dropFirst("/image/overlay/".count))
            guard name.hasSuffix(".tar") else { return notFound() }
            let bootID = String(name.dropLast(".tar".count))
            guard Self.isLowercaseHex(bootID, length: 32) else { return notFound() }
            guard let url = routes.overlayProvider?(bootID) else { return notFound() }
            return fileReply(url, contentType: "application/x-tar")
        }
        if path == "/channel" {
            guard request.method == "GET" else { return methodNotAllowed() }
            guard websocketHandler != nil || channelStateProvider != nil else {
                return .json(404, code: "not_found", message: "no ordered channel is configured")
            }
            return websocketUpgrade(request)
        }
        if path == "/v1/hello" {
            guard request.method == "GET" else { return methodNotAllowed() }
            return helloReply()
        }
        if path == "/v1/exec" || path.hasPrefix("/v1/exec/")
            || path == "/v1/fs" || path.hasPrefix("/v1/fs/")
            || path == "/v1/lifecycle" {
            return await forwardExecBridge(request)
        }
        if path == "/v1/http" || path.hasPrefix("/v1/http/") {
            return routeHTTPEgress(request)
        }
        if path.hasPrefix("/mcp") {
            return forwardMCP(request)
        }
        return notFound()
    }

    /// Maps an externally supplied ``LoopbackRoute`` to a reply.
    private func reply(for mapped: LoopbackRoute, request: HTTPRequest,
                       token: String) async -> LoopbackReply {
        switch mapped {
        case .staticAsset(let path, _):
            return staticReply(path, page: false, token: token)
        case .lazyImage(let sha):
            guard Self.isLowercaseHex(sha, length: 64),
                  let url = routes.lazyImageProvider?(sha) else {
                return notFound()
            }
            return fileReply(url, contentType: "application/gzip")
        case .modelGateway:
            return routeHTTPEgress(request)
        case .channelUpgrade:
            guard websocketHandler != nil || channelStateProvider != nil else {
                return .json(404, code: "not_found", message: "no ordered channel is configured")
            }
            return websocketUpgrade(request)
        case .notFound:
            return notFound()
        }
    }

    // MARK: - Static and image resources

    private func staticReply(_ relative: String, page: Bool,
                             token: String) -> LoopbackReply {
        guard let directory = routes.staticDirectory else { return notFound() }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return notFound() }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("\\"), !component.contains("\0") else {
                return notFound()
            }
        }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = components.reduce(directory.standardizedFileURL) {
            $0.appendingPathComponent(String($1))
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base.path + "/") else { return notFound() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return notFound()
        }
        let data = (try? Data(contentsOf: resolved)) ?? Data()
        var headers: [String: String] = [
            "Content-Type": Self.contentType(forExtension: resolved.pathExtension),
        ]
        if page && configuration.crossOriginIsolation {
            headers["Cross-Origin-Opener-Policy"] = "same-origin"
            headers["Cross-Origin-Embedder-Policy"] = "require-corp"
        }
        // D22: the HTML page response seeds the launch-token cookie. The value
        // is the per-start token; it is HttpOnly so page script cannot read it,
        // and SameSite=Strict keeps it on this loopback origin.
        if page && Self.isHTMLPage(resolved) {
            headers["Set-Cookie"] = Self.launchCookie(name: Self.launchCookieName,
                                                      token: token)
        }
        return .full(status: 200, headers: headers, body: data)
    }

    private func fileReply(_ url: URL, contentType: String) -> LoopbackReply {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return notFound()
        }
        return .file(url: url, contentType: contentType, headers: [:])
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "wasm": return "application/wasm"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    // MARK: - WebSocket

    private func websocketUpgrade(_ request: HTTPRequest) -> LoopbackReply {
        guard WebSocketHandshake.isUpgrade(headers: request.headers),
              let key = request.header("sec-websocket-key"), !key.isEmpty,
              request.header("sec-websocket-version") == "13" else {
            return .json(400, code: "bad_request", message: "invalid WebSocket upgrade")
        }
        return .upgrade(headers: ["Sec-WebSocket-Accept": WebSocketHandshake.acceptValue(for: key)])
    }

    // MARK: - /v1/hello

    private func helloReply() -> LoopbackReply {
        var capabilities: [String: CanonicalJSONValue] = [
            "accelerators": .array(routes.accelerators.map { .string($0) }),
            "channel": .object(["path": .string("/channel"), "proto": .integer(1)]),
            "confine": .array([]),
            "exec": .boolean(routes.execProvider != nil),
            "fs": .boolean(false),
            "http_proxy": .boolean(routes.httpEgress != nil),
            "lifecycle": .boolean(true),
            "mcp": .boolean(routes.mcpBaseURL != nil),
        ]
        if let provider = routes.execProvider {
            let execCaps = provider.capabilities
            capabilities["exec_provider"] = .object([
                "environment": .string(execCaps.environment),
                "network": .boolean(execCaps.network),
                "persistent_workspace": .boolean(execCaps.persistentWorkspace),
                "tiers": .array(execCaps.tiers.map { .string($0.rawValue) }),
            ])
        }
        let mounts = routes.mounts.keys.sorted().map { hostPath in
            CanonicalJSONValue.object([
                "guest_path": .string(routes.mounts[hostPath] ?? hostPath),
                "host_path": .string(hostPath),
                "read_only": .boolean(false),
            ])
        }
        return .json(200, value: .object([
            "capabilities": .object(capabilities),
            "guest": .object([
                "default_shell": .string("/bin/sh"),
                "mounts": .array(mounts),
                "path_env": .string("/usr/local/bin:/usr/bin:/bin"),
                "platform": .string("posix"),
            ]),
            "limits": .object([
                "max_concurrent": .integer(8),
                "max_output_bytes_per_stream": .integer(8 * 1024 * 1024),
                "max_request_bytes": .integer(1024 * 1024),
                "retention_seconds": .integer(600),
            ]),
            "protocol": .string("pdsh-exec-bridge/1"),
            "provider": .object([
                "name": .string("pdsh-phone-loopback"),
                "version": .string("1.0.0"),
            ]),
        ]))
    }

    // MARK: - Exec bridge

    private func forwardExecBridge(_ request: HTTPRequest) async -> LoopbackReply {
        guard let bridge = routes.execBridge else {
            return .json(503, code: "unavailable", message: "no exec bridge is configured")
        }
        guard let baseURL = await bridge.baseURL,
              let bridgeToken = await bridge.token,
              let url = URL(string: request.target, relativeTo: baseURL)?.absoluteURL,
              url.scheme == "http" || url.scheme == "https" else {
            return .json(503, code: "unavailable", message: "the exec bridge is not running")
        }
        var headers = URLSessionForwarder.forwardedHeaders(
            request.headers,
            drop: ["origin", "host", "authorization", "content-length",
                   "cookie", "cookie2", "referer",
                   "x-pdsh-target-url", "x-pdsh-target-method"])
        headers["Authorization"] = "Bearer \(bridgeToken)"
        return .egress(forwarder.forward(method: request.method, url: url,
                                         headers: headers, body: request.body),
                       target: url.absoluteString)
    }

    // MARK: - MCP proxy

    private func forwardMCP(_ request: HTTPRequest) -> LoopbackReply {
        guard let baseURL = routes.mcpBaseURL else { return notFound() }
        guard let url = URL(string: request.target, relativeTo: baseURL)?.absoluteURL else {
            return .json(400, code: "bad_request", message: "invalid MCP target")
        }
        let headers = URLSessionForwarder.forwardedHeaders(
            request.headers,
            drop: ["origin", "host", "authorization", "content-length",
                   "cookie", "cookie2", "referer"])
        return .egress(forwarder.forward(method: request.method, url: url,
                                         headers: headers, body: request.body),
                       target: url.absoluteString)
    }

    // MARK: - /v1/http

    private func routeHTTPEgress(_ request: HTTPRequest) -> LoopbackReply {
        guard let egress = routes.httpEgress else {
            return .json(503, code: "unavailable", message: "host HTTP egress is disabled")
        }
        guard let target = request.header("x-pdsh-target-url"),
              let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .json(400, code: "bad_request", message: "missing or invalid X-PDSH-Target-URL")
        }
        let method = request.header("x-pdsh-target-method")?.uppercased() ?? request.method
        var headers = URLSessionForwarder.forwardedHeaders(
            request.headers,
            drop: ["origin", "authorization", "host", "content-length",
                   // The browser attaches the loopback launch cookie and a
                   // loopback Referer to a same-origin XHR automatically. They
                   // identify this authenticated origin, never the upstream.
                   "cookie", "cookie2", "referer",
                   "x-pdsh-target-url", "x-pdsh-target-method",
                   "x-pdsh-upstream-authorization"])
        if let upstreamAuthorization = request.header("x-pdsh-upstream-authorization") {
            headers["Authorization"] = upstreamAuthorization
        }
        return .egress(egress.handle(HTTPEgressRequest(method: method, url: url,
                                                       headers: headers,
                                                       body: request.body)),
                       target: url.absoluteString)
    }

    // MARK: - Helpers

    private func notFound() -> LoopbackReply {
        .json(404, code: "not_found", message: "not found")
    }

    private func methodNotAllowed() -> LoopbackReply {
        .json(405, code: "method_not_allowed", message: "method not allowed")
    }

    private static func bearerToken(_ header: String?) -> String? {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return nil }
        return String(header.dropFirst("bearer ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads `name` from a `Cookie` header (D22). The HTTP reader joins
    /// repeated headers with `, `, so both separators are accepted.
    private static func cookieValue(named name: String, in header: String?) -> String? {
        guard let header else { return nil }
        for segment in header.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            return String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The D22 page cookie: launch token value, `Path=/`, `HttpOnly` and
    /// `SameSite=Strict`. No `Secure` attribute because the origin is loopback
    /// HTTP; the token is per start and never persisted.
    private static func launchCookie(name: String, token: String) -> String {
        "\(name)=\(token); Path=/; HttpOnly; SameSite=Strict"
    }

    private static func isHTMLPage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "html"
            || url.pathExtension.lowercased() == "htm"
    }

    private static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        let bytes = value.utf8
        guard bytes.count == length else { return false }
        return bytes.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
        }
    }
}

// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator Streamable HTTP SSE-response fixture.
//
// The normal `CapabilityMcpFixture` answers an id-bearing Streamable HTTP POST
// with a finite `application/json` body. This fixture keeps the same transport
// (POST JSON-RPC to one `/mcp` endpoint, optional session header) but answers
// every id-bearing request with a real `text/event-stream` body:
//
//   * `server/discover` receives a JSON-RPC method-not-found error on the SSE
//     stream, which is the current SDK's supported fallback to the legacy
//     `initialize` handshake;
//   * `initialize`, `tools/list` and `tools/call` return `event: message` /
//     `data: <JSON-RPC result>` frames with the request's exact id;
//   * notification-only POSTs (for example `notifications/initialized`) get a
//     bodyless 204, not a JSON-RPC reply;
//   * each SSE body is written in at least two network sends so a test pass
//     proves the client accepts frames split at a network boundary;
//   * GET follows the existing fixture protocol (405, `Allow: POST, DELETE`)
//     and DELETE returns 200 with the session id. Both check the host bearer
//     before answering, so neither is an unauthenticated side door;
//   * no `Access-Control-*` header is emitted at all.
//
// This is not the retired Legacy HTTP+SSE transport: there is no long-lived
// GET, no `endpoint` event and no second transport selector. The fixture binds
// an explicit 127.0.0.1 socket. It requires the host-injected dummy bearer (not
// the environment header the Worker configuration names). The env-only and
// model-gateway dummy values are recorded as booleans and rejected with 401.
// Values, request headers, query strings and tool arguments never enter a
// report.
//
// Test-only; no production MCP implementation is changed.

import Foundation
import Network

// MARK: - Response shape

/// One response from the test-only Streamable HTTP fixture. `eventStream`
/// carries a finite `text/event-stream` body; it is not a long-lived GET feed.
enum CapabilityMCPSSEResponse: Sendable {
    case http(status: Int, headers: [String: String], body: Data)
    case eventStream(headers: [String: String], body: Data)
}

// MARK: - Listener

/// Minimal HTTP/1.1 listener for a Streamable HTTP MCP server whose id-bearing
/// responses use `text/event-stream`.
///
/// It binds an ephemeral port explicitly on `127.0.0.1`. One serial queue owns
/// the Network callbacks. An SSE body is written with two `NWConnection.send`
/// calls so the fixture can report real network-level frame splits.
final class CapabilityMCPSSEServer: @unchecked Sendable {
    typealias Handler = @Sendable (CapabilityHTTPRequest) -> CapabilityMCPSSEResponse

    private let queue = DispatchQueue(label: "pdsh.capability.mcp-sse")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopping = false
    private var eventStreamResponses = 0
    private var eventStreamContentTypes = 0
    private var eventStreamBodySends = 0
    private var eventStreamSplits = 0
    private var corsHeaders = 0
    private(set) var port: UInt16 = 0
    var handler: Handler?

    init() {}

    var sseResponseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventStreamResponses
    }

    var sseContentTypeResponseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventStreamContentTypes
    }

    var sseBodySendCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventStreamBodySends
    }

    var sseSplitResponseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventStreamSplits
    }

    var accessControlHeaderCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return corsHeaders
    }

    /// Bind `127.0.0.1:<ephemeral>` and return the port.
    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success else {
            listener.cancel()
            throw CapabilityFixtureError.startTimedOut("MCP SSE-response listener")
        }
        if let startError {
            listener.cancel()
            throw CapabilityFixtureError.listener(String(describing: startError))
        }
        guard let rawPort = listener.port?.rawValue, rawPort != 0 else {
            listener.cancel()
            throw CapabilityFixtureError.listener("MCP SSE-response listener bound no port")
        }
        lock.lock()
        self.listener = listener
        self.port = rawPort
        lock.unlock()
        return rawPort
    }

    func stop() {
        lock.lock()
        stopping = true
        let all = Array(connections.values)
        connections.removeAll()
        let current = listener
        listener = nil
        lock.unlock()
        for connection in all { connection.cancel() }
        current?.cancel()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        lock.lock()
        if stopping {
            lock.unlock()
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = nil
        lock.unlock()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let request = CapabilityHTTPServer.parse(accumulated) {
                self.route(request, on: connection)
                return
            }
            if error != nil || isComplete {
                self.forget(connection)
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func route(_ request: CapabilityHTTPRequest, on connection: NWConnection) {
        guard let handler else {
            send(.http(status: 500,
                       headers: ["Content-Type": "text/plain; charset=utf-8"],
                       body: Data("MCP SSE-response handler is not installed".utf8)),
                 on: connection)
            return
        }
        switch handler(request) {
        case .http(let status, let headers, let body):
            send(.http(status: status, headers: headers, body: body), on: connection)
        case .eventStream(let headers, let body):
            sendEventStream(headers: headers, body: body, on: connection)
        }
    }

    // MARK: Responses

    private func send(_ response: CapabilityMCPSSEResponse, on connection: NWConnection) {
        guard case .http(let status, var headers, let body) = response else { return }
        countAccessControlHeaders(headers)
        var message = Data(responseHead(status: status,
                                       headers: &headers,
                                       bodyLength: body.count).utf8)
        if status != 204 { message.append(body) }
        connection.send(content: message, completion: .contentProcessed { [weak self] _ in
            self?.forget(connection)
            connection.cancel()
        })
    }

    private func sendEventStream(headers: [String: String],
                                 body: Data,
                                 on connection: NWConnection) {
        var headers = headers
        guard !body.isEmpty else {
            send(.http(status: 500, headers: headers,
                       body: Data("empty MCP SSE response body".utf8)),
                 on: connection)
            return
        }
        countAccessControlHeaders(headers)
        lock.lock()
        eventStreamResponses += 1
        if headers["Content-Type"]?.lowercased().hasPrefix("text/event-stream") == true {
            eventStreamContentTypes += 1
        }
        lock.unlock()

        var firstMessage = Data(responseHead(status: 200,
                                            headers: &headers,
                                            bodyLength: body.count).utf8)
        let split = min(max(1, body.count / 2), body.count - 1)
        if split > 0 {
            firstMessage.append(contentsOf: body.prefix(split))
            let tail = Data(body.dropFirst(split))
            lock.lock()
            eventStreamBodySends += 2
            eventStreamSplits += 1
            lock.unlock()
            connection.send(content: firstMessage, completion: .contentProcessed { _ in })
            connection.send(content: tail, completion: .contentProcessed { [weak self] _ in
                self?.forget(connection)
                connection.cancel()
            })
            return
        }
        firstMessage.append(body)
        lock.lock()
        eventStreamBodySends += 1
        lock.unlock()
        connection.send(content: firstMessage, completion: .contentProcessed { [weak self] _ in
            self?.forget(connection)
            connection.cancel()
        })
    }

    private func responseHead(status: Int,
                              headers: inout [String: String],
                              bodyLength: Int) -> String {
        headers["Connection"] = "close"
        if status != 204 {
            headers["Content-Length"] = String(bodyLength)
            if headers["Content-Type"] == nil {
                headers["Content-Type"] = "application/json"
            }
        }
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return text
    }

    private func countAccessControlHeaders(_ headers: [String: String]) {
        let count = headers.keys.filter {
            $0.lowercased().hasPrefix("access-control-")
        }.count
        guard count > 0 else { return }
        lock.lock()
        corsHeaders += count
        lock.unlock()
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

// MARK: - MCP responder

/// The fixture's server state: authenticated JSON-RPC answers, the
/// `event: message` framing and bounded observation counters. It never exposes
/// a raw header, query, token or tool argument through ``diagnostics``.
private final class CapabilityMCPSSEResponder: @unchecked Sendable {
    let endpointPath = "/mcp"
    let sessionID: String
    let hostAuthorization: String
    let envAuthorization: String
    let modelKey: String
    let modelAuthorization: String

    private let lock = NSLock()
    private var getCount = 0
    private var getAuthorizedCount = 0
    private var deleteCount = 0
    private var deleteAuthorizedCount = 0
    private var postCount = 0
    private var postAuthorizedCount = 0
    private var optionsCount = 0
    private var authorizedRequestCount = 0
    private var unauthorizedCount = 0
    private var notificationCount = 0
    private var notificationNoContentCountStorage = 0
    private var sseEventCountStorage = 0
    private var replyIDMismatchCountStorage = 0
    private var parseFailureCountStorage = 0
    private var sawEnv = false
    private var sawModel = false
    private var sawHost = false
    private var methods: [String] = []
    private var calls: [(name: String, message: String)] = []

    init(nonce: String, modelKey: String) {
        self.sessionID = "mcp-sse-session-\(nonce)"
        self.hostAuthorization = "Bearer pdsh-mcp-sse-host-\(nonce)"
        self.envAuthorization = "Bearer pdsh-mcp-sse-env-\(nonce)"
        self.modelKey = modelKey
        self.modelAuthorization = "Bearer \(modelKey)"
    }

    var requestMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return methods
    }

    var toolCalls: [(name: String, message: String)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var getRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return getCount
    }

    var authorizedGetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return getAuthorizedCount
    }

    var deleteRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deleteCount
    }

    var authorizedDeleteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deleteAuthorizedCount
    }

    var postRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return postCount
    }

    var authorizedPostCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return postAuthorizedCount
    }

    var authenticatedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authorizedRequestCount
    }

    var unauthorizedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unauthorizedCount
    }

    var notificationNoContentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return notificationNoContentCountStorage
    }

    var sseEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sseEventCountStorage
    }

    var replyIDMismatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return replyIDMismatchCountStorage
    }

    var parseFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parseFailureCountStorage
    }

    var sawEnvAuthorization: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawEnv
    }

    var sawModelCredential: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawModel
    }

    var sawHostAuthorization: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawHost
    }

    var diagnostics: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "mcp_transport": "streamable-http",
            "mcp_response_mode": "text/event-stream",
            "get_requests": getCount,
            "get_authorized": getAuthorizedCount,
            "delete_requests": deleteCount,
            "delete_authorized": deleteAuthorizedCount,
            "post_requests": postCount,
            "post_authorized": postAuthorizedCount,
            "options_requests": optionsCount,
            "authenticated_requests": authorizedRequestCount,
            "notifications": notificationCount,
            "notification_204": notificationNoContentCountStorage,
            "sse_events": sseEventCountStorage,
            "sse_reply_id_mismatches": replyIDMismatchCountStorage,
            "sse_parse_failures": parseFailureCountStorage,
            "unauthorized_requests": unauthorizedCount,
            "host_authorization_seen": sawHost,
            "env_authorization_seen": sawEnv,
            "model_credential_seen": sawModel,
            "rpc_methods": methods.joined(separator: ","),
            "tool_call_count": calls.count,
            "echo_call_count": calls.filter { $0.name == "echo" }.count,
        ]
    }

    func handle(_ request: CapabilityHTTPRequest) -> CapabilityMCPSSEResponse {
        let components = URLComponents(string: request.path)
        let path = components?.path ?? request.path
        let authorization = request.headers["authorization"] ?? ""
        let apiKey = request.headers["x-api-key"] ?? ""
        let envSeen = authorization == envAuthorization
        let modelSeen = authorization == modelAuthorization
            || (!apiKey.isEmpty && apiKey == modelKey)
        let hostSeen = authorization == hostAuthorization

        switch request.method {
        case "GET":
            let authorized = record(method: "GET", hostSeen: hostSeen,
                                    envSeen: envSeen, modelSeen: modelSeen)
            guard authorized else { return .http(status: 401, headers: [:], body: Data()) }
            guard path == endpointPath else {
                return .http(status: 404, headers: [:], body: Data())
            }
            // Existing Streamable HTTP fixture protocol: this server does not
            // offer a long-lived GET event feed. A 405 is the protocol answer,
            // not a fallback to the retired Legacy endpoint-event transport.
            return .http(status: 405,
                         headers: ["Allow": "POST, DELETE"],
                         body: Data())

        case "DELETE":
            let authorized = record(method: "DELETE", hostSeen: hostSeen,
                                    envSeen: envSeen, modelSeen: modelSeen)
            guard authorized else { return .http(status: 401, headers: [:], body: Data()) }
            guard path == endpointPath else {
                return .http(status: 404, headers: [:], body: Data())
            }
            return .http(status: 200,
                         headers: ["mcp-session-id": sessionID],
                         body: Data())

        case "OPTIONS":
            let authorized = record(method: "OPTIONS", hostSeen: hostSeen,
                                    envSeen: envSeen, modelSeen: modelSeen)
            guard authorized else { return .http(status: 401, headers: [:], body: Data()) }
            // No Access-Control-* headers are added. A browser preflight that
            // really needs CORS fails here instead of being loosened.
            return .http(status: 204, headers: [:], body: Data())

        case "POST":
            let authorized = record(method: "POST", hostSeen: hostSeen,
                                    envSeen: envSeen, modelSeen: modelSeen)
            guard authorized else { return .http(status: 401, headers: [:], body: Data()) }
            guard path == endpointPath else {
                return .http(status: 404, headers: [:], body: Data())
            }
            return handlePost(request)

        default:
            return .http(status: 405,
                         headers: ["Allow": "POST, GET, DELETE, OPTIONS"],
                         body: Data())
        }
    }

    private func record(method: String, hostSeen: Bool,
                        envSeen: Bool, modelSeen: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch method {
        case "GET": getCount += 1
        case "DELETE": deleteCount += 1
        case "POST": postCount += 1
        case "OPTIONS": optionsCount += 1
        default: break
        }
        if envSeen { sawEnv = true }
        if modelSeen { sawModel = true }
        guard hostSeen, !envSeen, !modelSeen else {
            unauthorizedCount += 1
            return false
        }
        sawHost = true
        authorizedRequestCount += 1
        switch method {
        case "GET": getAuthorizedCount += 1
        case "DELETE": deleteAuthorizedCount += 1
        case "POST": postAuthorizedCount += 1
        default: break
        }
        return true
    }

    private func handlePost(_ request: CapabilityHTTPRequest) -> CapabilityMCPSSEResponse {
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) else {
            lock.lock()
            parseFailureCountStorage += 1
            lock.unlock()
            return .http(status: 400, headers: [:], body: Data())
        }
        let batch = parsed as? [Any]
        let messages = batch ?? [parsed]
        var replies: [Any] = []
        var notifications = 0
        for case let message as [String: Any] in messages {
            let method = message["method"] as? String
            if let method {
                lock.lock()
                methods.append(method)
                lock.unlock()
            }
            guard let id = message["id"] else {
                notifications += 1
                continue
            }
            guard let reply = answer(message) else { continue }
            let replyID = (reply as? [String: Any])?["id"]
            if !Self.sameJSONID(id, replyID) {
                lock.lock()
                replyIDMismatchCountStorage += 1
                lock.unlock()
            }
            replies.append(reply)
        }

        lock.lock()
        notificationCount += notifications
        lock.unlock()

        guard !replies.isEmpty else {
            lock.lock()
            notificationNoContentCountStorage += notifications
            lock.unlock()
            return .http(status: 204,
                         headers: ["mcp-session-id": sessionID],
                         body: Data())
        }

        var body = ""
        for reply in replies {
            guard let data = try? JSONSerialization.data(withJSONObject: reply,
                                                         options: [.sortedKeys]) else {
                continue
            }
            body += "event: message\n"
            body += "data: \(String(decoding: data, as: UTF8.self))\n\n"
            lock.lock()
            sseEventCountStorage += 1
            lock.unlock()
        }
        return .eventStream(
            headers: [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "mcp-session-id": sessionID,
            ],
            body: Data(body.utf8))
    }

    // MARK: JSON-RPC

    private func answer(_ message: [String: Any]) -> Any? {
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String ?? "" {
        case "server/discover":
            // The current SDK probes with server/discover and falls back to the
            // legacy initialize handshake on a JSON-RPC method-not-found error.
            return failure(id: id, code: -32601,
                           message: "method not found: server/discover")
        case "initialize":
            let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
            let requested = params["protocolVersion"] as? String ?? ""
            let chosen = versions.contains(requested) ? requested : versions[0]
            return reply(id: id, result: [
                "protocolVersion": chosen,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "phone-mcp-sse-fixture", "version": "0.1.0"],
            ])
        case "ping":
            return reply(id: id, result: [String: Any]())
        case "tools/list":
            return reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let text = arguments["message"] as? String ?? ""
            lock.lock()
            calls.append((name: name, message: text))
            lock.unlock()
            if name == "ping" {
                return reply(id: id, result: [
                    "content": [["type": "text", "text": "pong"]],
                ])
            }
            if name == "echo" {
                return reply(id: id, result: [
                    "content": [["type": "text", "text": "echo:\(text)"]],
                ])
            }
            return failure(id: id, code: -32602, message: "unknown tool: \(name)")
        default:
            return failure(id: id, code: -32601,
                           message: "method not found: \(message["method"] as? String ?? "")")
        }
    }

    private func reply(id: Any, result: Any) -> Any {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func failure(id: Any, code: Int, message: String) -> Any {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// Compare two JSON-RPC ids by their serialized JSON value. The fixture
    /// answers with the same id object it received; this counter catches a
    /// future change that reuses or drops an id.
    private static func sameJSONID(_ lhs: Any, _ rhs: Any?) -> Bool {
        guard let rhs else { return false }
        guard let left = try? JSONSerialization.data(withJSONObject: lhs,
                                                     options: [.sortedKeys, .fragmentsAllowed]),
              let right = try? JSONSerialization.data(withJSONObject: rhs,
                                                      options: [.sortedKeys, .fragmentsAllowed]) else {
            return false
        }
        return left == right
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "ping",
            "description": "Return a fixed pong value.",
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "echo",
            "description": "Echo a caller-provided message.",
            "inputSchema": [
                "type": "object",
                "properties": ["message": ["type": "string"]],
                "required": ["message"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true],
        ],
    ]
}

// MARK: - Fixture

/// Local Streamable HTTP MCP server that answers id-bearing POSTs with
/// `text/event-stream`, using independent host/env/model dummy values.
final class CapabilityMCPSSEFixture: @unchecked Sendable {
    let nonce: String
    let hostTokenValue: String
    let envTokenValue: String
    private let responder: CapabilityMCPSSEResponder
    private let server: CapabilityMCPSSEServer
    private(set) var url: URL?

    /// - Parameters:
    ///   - nonce: unique run tag used for the fixture's dummy values only.
    ///   - forbiddenModelKey: the model-gateway dummy key that must never reach
    ///     the MCP server. It is compared in memory and never written to a report.
    init(nonce: String, forbiddenModelKey: String) {
        self.nonce = nonce
        self.hostTokenValue = "pdsh-mcp-sse-host-\(nonce)"
        self.envTokenValue = "pdsh-mcp-sse-env-\(nonce)"
        let responder = CapabilityMCPSSEResponder(nonce: nonce,
                                                  modelKey: forbiddenModelKey)
        let server = CapabilityMCPSSEServer()
        self.responder = responder
        self.server = server
        server.handler = { [weak responder] request in
            guard let responder else {
                return .http(status: 500, headers: [:], body: Data())
            }
            return responder.handle(request)
        }
    }

    /// The Worker environment dummy value (`Authorization` source for
    /// `headersFromEnv`). It is intentionally different from the host value.
    var envAuthorizationValue: String { "Bearer \(envTokenValue)" }

    @discardableResult
    func start() throws -> URL {
        let port = try server.start()
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            throw CapabilityFixtureError.listener("invalid MCP SSE-response loopback URL")
        }
        self.url = url
        return url
    }

    func stop() {
        server.stop()
    }

    var requestMethods: [String] { responder.requestMethods }
    var toolCalls: [(name: String, message: String)] { responder.toolCalls }
    var getRequestCount: Int { responder.getRequestCount }
    var authorizedGetCount: Int { responder.authorizedGetCount }
    var deleteRequestCount: Int { responder.deleteRequestCount }
    var authorizedDeleteCount: Int { responder.authorizedDeleteCount }
    var postRequestCount: Int { responder.postRequestCount }
    var authorizedPostCount: Int { responder.authorizedPostCount }
    var authenticatedRequestCount: Int { responder.authenticatedRequestCount }
    var unauthorizedRequestCount: Int { responder.unauthorizedRequestCount }
    var notificationNoContentCount: Int { responder.notificationNoContentCount }
    var sseEventCount: Int { responder.sseEventCount }
    var replyIDMismatchCount: Int { responder.replyIDMismatchCount }
    var parseFailureCount: Int { responder.parseFailureCount }
    var sseResponseCount: Int { server.sseResponseCount }
    var sseContentTypeResponseCount: Int { server.sseContentTypeResponseCount }
    var sseBodySendCount: Int { server.sseBodySendCount }
    var sseSplitResponseCount: Int { server.sseSplitResponseCount }
    var accessControlHeaderCount: Int { server.accessControlHeaderCount }
    var sawEnvAuthorization: Bool { responder.sawEnvAuthorization }
    var sawModelCredential: Bool { responder.sawModelCredential }
    var sawHostAuthorization: Bool { responder.sawHostAuthorization }

    var diagnostics: [String: Any] {
        var value = responder.diagnostics
        value["sse_responses"] = server.sseResponseCount
        value["sse_content_type_responses"] = server.sseContentTypeResponseCount
        value["sse_body_sends"] = server.sseBodySendCount
        value["sse_split_responses"] = server.sseSplitResponseCount
        value["cors_headers_sent"] = server.accessControlHeaderCount
        return value
    }
}

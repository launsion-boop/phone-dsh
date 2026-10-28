// SPDX-License-Identifier: MIT
// PhoneDSHAgentCore: the wire of a self-hosted DeepSeek Harness `dsh web`
// Remote server.
//
// Authentication: `dsh web` prints a URL with a one-time launch token. A
// `GET /?token=<token>` answers 303 with an HttpOnly session cookie bound to
// the request authority (`host:port`); every later request carries that
// cookie. There is no bearer header. The server only accepts loopback (or
// explicitly trusted) Host headers, and an Origin header, when present, must
// equal the Host — so this client sends no Origin.
//
// Unary calls: `POST /api/<namespace>/<method>` with
// `{"type":"client-request","rpcId","method","payload":{"args":{...}}}`,
// answered by `{"type":"server-response","rpcId","result":{"ok",...}}`.
// Streams: one WebSocket at `/api/remote.mux` multiplexing logical streams
// (`open` / `item` / `end` / `cancel`, and `item` / `error` / `end` back).

import Foundation

/// Unary calls and stream connections to a `dsh web` server. The adapter is
/// written against this seam so tests can replay recorded frames.
public protocol DSHRemoteTransport: Sendable {
    /// Calls `endpoint` (`session/create`) with `args` and returns `result.value`.
    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue
    /// Opens one `/api/remote.mux` WebSocket.
    func openMux() async throws -> any DSHMuxConnection
    /// A stream was rejected with 401: forget the session cookie so the next
    /// call exchanges the launch token again.
    func authenticationFailed() async
}

public extension DSHRemoteTransport {
    func authenticationFailed() async {}
}

public protocol DSHMuxConnection: Sendable {
    func send(_ frame: JSONValue) async throws
    /// The next frame, or nil once the socket closed.
    func receive() async throws -> JSONValue?
    func close() async
}

/// Remote errors carried in `result.error.code`.
public struct DSHRemoteError: Error, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var providerError: ProviderError {
        switch code {
        case "session/not-found", "subagent/not-found", "workspace/not-found":
            return .invalidRequest("session_not_found")
        case "session/conflict", "agent-preset/conflict", "session/writer-held", "session/agent-busy":
            return .conflict("\(code): \(message)")
        case "session/steer-unavailable":
            return .invalidRequest("\(code): \(message)")
        case "gateway/cancelled":
            return .cancelled
        case "gateway/internal", "gateway/service-unavailable", "gateway/invocation-unavailable",
             "gateway/method-unavailable", "session/model-unavailable":
            return .unavailable(retryAfter: nil)
        default:
            return .invalidRequest("\(code): \(message)")
        }
    }
}

/// `DSHRemoteTransport` over URLSession.
public actor DSHWebTransport: DSHRemoteTransport {
    public let baseURL: URL
    public let credentialScope: CredentialScope
    private let credentials: any CredentialProvider
    private let session: URLSession
    private var cookie: String?
    private var credential: Credential?

    /// - Parameters:
    ///   - baseURL: the `dsh web` origin, for example `http://127.0.0.1:3080`.
    ///   - credentialScope: where `credentials` serves the launch token
    ///     (`Credential.value`); its kind is ignored.
    public init(baseURL: URL,
                credentials: any CredentialProvider,
                credentialScope: CredentialScope = CredentialScope(service: "dsh-remote"),
                session: URLSession = URLSession(configuration: .ephemeral)) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.credentialScope = credentialScope
        self.session = session
    }

    public func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        for attempt in 1...2 {
            let cookie = try await sessionCookie()
            var request = URLRequest(url: apiURL(endpoint))
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            let rpcID = UUID().uuidString.lowercased()
            request.httpBody = try JSONValue.object([
                "type": .string("client-request"),
                "rpcId": .string(rpcID),
                "method": .string(endpoint),
                "payload": .object(["args": args]),
            ]).encoded()
            let (data, response) = try await data(for: request)
            switch response.statusCode {
            case 200:
                return try Self.unwrap(data, rpcID: rpcID)
            case 401 where attempt == 1:
                self.cookie = nil   // expired cookie or a restarted server
                continue
            case 401:
                if let credential { await credentials.invalidate(credential, for: credentialScope) }
                throw ProviderError.unauthorized("dsh web rejected the session cookie")
            case 403:
                throw ProviderError.unauthorized("dsh web refused the Host/Origin of this client (trustedHosts)")
            case 413:
                throw ProviderError.invalidRequest("request body too large")
            default:
                throw HTTPErrorMapping.providerError(status: response.statusCode, body: data,
                                                     headers: response.allHeaderFields)
            }
        }
        throw ProviderError.unauthorized("dsh web authentication failed")
    }

    public func openMux() async throws -> any DSHMuxConnection {
        let cookie = try await sessionCookie()
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = Self.basePath(baseURL) + "/api/remote.mux"
        var request = URLRequest(url: components.url!)
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        task.resume()
        return DSHWebSocketMux(task: task)
    }

    public func authenticationFailed() async {
        cookie = nil
    }

    /// Exchanges the launch token for the session cookie (once per cookie).
    private func sessionCookie() async throws -> String {
        if let cookie { return cookie }
        let credential = try await credentials.credential(for: credentialScope)
        self.credential = credential
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = Self.basePath(baseURL) + "/"
        components.queryItems = [URLQueryItem(name: "token", value: credential.value)]
        var request = URLRequest(url: components.url!)
        request.httpShouldHandleCookies = false
        let (_, response) = try await data(for: request, followRedirects: false)
        guard response.statusCode == 303,
              let setCookie = response.value(forHTTPHeaderField: "Set-Cookie"),
              let pair = setCookie.split(separator: ";").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
              pair.contains("=") else {
            await credentials.invalidate(credential, for: credentialScope)
            throw ProviderError.unauthorized("dsh web did not accept the launch token (HTTP \(response.statusCode))")
        }
        cookie = pair
        return pair
    }

    private func apiURL(_ endpoint: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = Self.basePath(baseURL) + "/api/" + endpoint
        return components.url!
    }

    private static func basePath(_ url: URL) -> String {
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func data(for request: URLRequest, followRedirects: Bool = true) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(
                for: request, delegate: followRedirects ? nil : NoRedirects.shared)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse("not an HTTP response")
            }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unavailable(retryAfter: nil)
        }
    }

    static func unwrap(_ data: Data, rpcID: String) throws -> JSONValue {
        guard let envelope = try? JSONValue.parse(data),
              envelope["type"]?.stringValue == "server-response" else {
            throw ProviderError.invalidResponse("not a server-response envelope")
        }
        guard envelope["rpcId"]?.stringValue == rpcID else {
            throw ProviderError.invalidResponse("rpcId mismatch")
        }
        guard let result = envelope["result"] else { throw ProviderError.invalidResponse("no result") }
        if result["ok"]?.boolValue == true { return result["value"] ?? .null }
        throw DSHRemoteError(code: result["error"]?["code"]?.stringValue ?? "unknown",
                             message: result["error"]?["message"]?.stringValue ?? "")
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// One `/api/remote.mux` WebSocket.
final class DSHWebSocketMux: DSHMuxConnection, @unchecked Sendable {
    // @unchecked: URLSessionWebSocketTask is thread-safe; the reference never changes.
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ frame: JSONValue) async throws {
        let text = String(decoding: try frame.encoded(), as: UTF8.self)
        do {
            try await task.send(.string(text))
        } catch {
            throw ProviderError.unavailable(retryAfter: nil)
        }
    }

    func receive() async throws -> JSONValue? {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            if (task.response as? HTTPURLResponse)?.statusCode == 401 {
                throw ProviderError.unauthorized("dsh web rejected the stream cookie")
            }
            return nil
        }
        switch message {
        case .string(let text): return try? JSONValue.parse(Data(text.utf8))
        case .data(let data): return try? JSONValue.parse(data)
        @unknown default: return nil
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

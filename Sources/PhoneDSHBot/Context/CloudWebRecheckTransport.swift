// SPDX-License-Identifier: MIT

import Foundation

/// Production `BotWebRecheckTransport` for public web/connector sources over
/// the existing cloud `/v1/web/fetch` endpoint.
///
/// The phone already authorizes cloud web use through its signed-in account;
/// this transport continues that path instead of opening a second host socket
/// or adding a new endpoint. The cloud validates the public target, performs
/// the fetch and returns `{content,title}`; it never receives the Bot prompt or
/// memory. This adapter keeps only the content digest needed by G-1 and drops
/// the body immediately. No raw content is logged or stored.
public struct CloudWebRecheckTransport: BotWebRecheckTransport {
    public struct Configuration: Sendable, Equatable {
        public var baseURL: URL
        public var requestTimeoutSeconds: TimeInterval
        public var maximumResponseBytes: Int

        public init(baseURL: URL, requestTimeoutSeconds: TimeInterval = 15,
                    maximumResponseBytes: Int = 1_048_576) {
            self.baseURL = baseURL
            self.requestTimeoutSeconds = max(1, requestTimeoutSeconds)
            self.maximumResponseBytes = max(4_096, maximumResponseBytes)
        }
    }

    private let configuration: Configuration
    private let tokenProvider: @Sendable () async throws -> String?
    private let session: URLSession

    public init(configuration: Configuration,
                tokenProvider: @escaping @Sendable () async throws -> String?,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        let copy = sessionConfiguration.copy() as? URLSessionConfiguration ?? .ephemeral
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.urlCache = nil
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        copy.timeoutIntervalForResource = max(configuration.requestTimeoutSeconds, 30)
        session = URLSession(configuration: copy)
    }

    public func perform(_ request: BotWebRecheckHTTPRequest)
        async throws -> BotWebRecheckHTTPResponse {
        guard request.method.uppercased() == "GET" else {
            throw BotWebRecheckTransportError.invalidResponse
        }
        let endpoint = configuration.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("web")
            .appendingPathComponent("fetch")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(request.timeoutMilliseconds) / 1_000
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let token: String
        do {
            guard let value = try await tokenProvider(), !value.isEmpty else {
                throw BotWebRecheckTransportError.denied(code: "cloud-unauthenticated")
            }
            token = value
        } catch let error as BotWebRecheckTransportError {
            throw error
        } catch {
            throw BotWebRecheckTransportError.unavailable(code: "cloud-token-unavailable")
        }
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let payload = ["url": request.url.absoluteString]
        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw BotWebRecheckTransportError.invalidResponse
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw BotWebRecheckTransportError.unavailable(code: "cancelled")
        } catch {
            throw BotWebRecheckTransportError.unavailable(code: "cloud-transport")
        }
        guard let http = response as? HTTPURLResponse else {
            throw BotWebRecheckTransportError.invalidResponse
        }
        // A redirected cloud endpoint would change the resource identity the
        // caller approved; do not accept content from a different final URL.
        if let finalURL = http.url,
           finalURL.host != endpoint.host || finalURL.path != endpoint.path {
            throw BotWebRecheckTransportError.unavailable(code: "cloud-redirect")
        }
        guard data.count <= min(request.maximumBodyBytes, configuration.maximumResponseBytes) else {
            throw BotWebRecheckTransportError.unavailable(code: "content-too-large")
        }
        switch http.statusCode {
        case 200:
            break
        case 400, 401, 402, 403:
            throw BotWebRecheckTransportError.denied(code: "cloud-http-\(http.statusCode)")
        case 413:
            throw BotWebRecheckTransportError.unavailable(code: "content-too-large")
        case 429, 500...599:
            throw BotWebRecheckTransportError.unavailable(code: "cloud-http-\(http.statusCode)")
        default:
            throw BotWebRecheckTransportError.unavailable(code: "cloud-http-\(http.statusCode)")
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              let content = object["content"] as? String,
              !content.isEmpty else {
            throw BotWebRecheckTransportError.unavailable(code: "cloud-invalid-response")
        }
        let body = Data(content.utf8)
        guard body.count <= min(request.maximumBodyBytes, configuration.maximumResponseBytes) else {
            throw BotWebRecheckTransportError.unavailable(code: "content-too-large")
        }
        // The rechecker hashes this body and keeps only the `sha256:` digest.
        // `Date` is the cloud's observation time; the rechecker uses it when
        // present instead of pretending the local clock observed the source.
        var headers = ["content-type": "text/markdown; charset=utf-8"]
        if let date = http.value(forHTTPHeaderField: "Date") {
            headers["date"] = date
        }
        return BotWebRecheckHTTPResponse(
            status: 200, headers: headers, body: body, finalURL: nil)
    }
}

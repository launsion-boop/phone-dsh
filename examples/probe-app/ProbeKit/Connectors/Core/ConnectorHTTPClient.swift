// SPDX-License-Identifier: MIT

import Foundation

public struct ConnectorHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String] = [:], data: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

public protocol ConnectorHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ConnectorHTTPResponse
}

public enum ConnectorHTTPError: Error, Equatable, Sendable {
    case invalidHost
    case invalidRequest
    case missingCredential
    case requestTooLarge
    case responseTooLarge
    case networkUnavailable
    case invalidResponse

    public var code: String {
        switch self {
        case .invalidHost: return "invalid_host"
        case .invalidRequest: return "invalid_request"
        case .missingCredential: return "not_configured"
        case .requestTooLarge: return "request_too_large"
        case .responseTooLarge: return "response_too_large"
        case .networkUnavailable: return "network_unavailable"
        case .invalidResponse: return "invalid_response"
        }
    }

    public var message: String {
        switch self {
        case .invalidHost: return "连接器请求目标不在允许列表中"
        case .invalidRequest: return "连接器请求无效"
        case .missingCredential: return "连接器尚未配置凭据"
        case .requestTooLarge: return "连接器请求超过大小限制"
        case .responseTooLarge: return "连接器响应超过大小限制"
        case .networkUnavailable: return "连接器网络请求失败"
        case .invalidResponse: return "连接器返回了无效响应"
        }
    }
}

public struct ConnectorHTTPLimits: Sendable {
    public var maximumRequestBytes: Int
    public var maximumResponseBytes: Int

    public init(maximumRequestBytes: Int = 256 * 1024,
                maximumResponseBytes: Int = 1024 * 1024) {
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }
}

public final class URLSessionConnectorHTTPTransport: ConnectorHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let limits: ConnectorHTTPLimits

    public init(session: URLSession = .shared, limits: ConnectorHTTPLimits = ConnectorHTTPLimits()) {
        self.session = session
        self.limits = limits
    }

    public func send(_ request: URLRequest) async throws -> ConnectorHTTPResponse {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ConnectorHTTPError.invalidResponse }
            guard http.url?.host?.lowercased() == request.url?.host?.lowercased(),
                  http.url?.scheme?.lowercased() == "https" else { throw ConnectorHTTPError.invalidHost }
            var data = Data()
            for try await byte in bytes {
                if data.count >= limits.maximumResponseBytes { throw ConnectorHTTPError.responseTooLarge }
                data.append(byte)
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
            return ConnectorHTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
        } catch let error as ConnectorHTTPError {
            throw error
        } catch {
            throw ConnectorHTTPError.networkUnavailable
        }
    }
}

public struct ConnectorHTTPClient: Sendable {
    public let host: String
    public let allowedHosts: Set<String>
    private let transport: any ConnectorHTTPTransport
    private let credentials: any ConnectorCredentialStore
    private let limits: ConnectorHTTPLimits

    public init(host: String,
                allowedHosts: Set<String>,
                transport: any ConnectorHTTPTransport,
                credentials: any ConnectorCredentialStore,
                limits: ConnectorHTTPLimits = ConnectorHTTPLimits()) {
        self.host = host.lowercased()
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.transport = transport
        self.credentials = credentials
        self.limits = limits
    }

    public func request(path: String,
                        method: String = "GET",
                        query: [URLQueryItem] = [],
                        body: Data? = nil,
                        credentialRef: String,
                        additionalHeaders: [String: String] = [:]) async throws -> ConnectorHTTPResponse {
        guard allowedHosts.contains(host), !path.contains("://"), !path.contains("..") else {
            throw ConnectorHTTPError.invalidHost
        }
        if let body, body.count > limits.maximumRequestBytes { throw ConnectorHTTPError.requestTooLarge }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path.hasPrefix("/") ? path : "/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.host?.lowercased() == host,
              url.user == nil, url.password == nil else { throw ConnectorHTTPError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in additionalHeaders where name.lowercased() != "authorization" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let authorized = try credentials.withCredential(for: credentialRef) { credential in
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            return request
        }
        guard let authorized else { throw ConnectorHTTPError.missingCredential }
        let response = try await transport.send(authorized)
        guard response.data.count <= limits.maximumResponseBytes else {
            throw ConnectorHTTPError.responseTooLarge
        }
        return response
    }
}

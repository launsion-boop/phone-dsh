// SPDX-License-Identifier: MIT

import Foundation

public struct GmailHTTPRequest: Sendable, Equatable {
    public var method: String
    public var host: String
    public var path: String
    public var query: [String: String]
    public var repeatedQuery: [String: [String]]
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", host: String = "gmail.googleapis.com", path: String,
                query: [String: String] = [:], repeatedQuery: [String: [String]] = [:],
                headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.host = host
        self.path = path
        self.query = query
        self.repeatedQuery = repeatedQuery
        self.headers = headers
        self.body = body
    }

    public func url() throws -> URL {
        guard host == "gmail.googleapis.com" || host == "oauth2.googleapis.com",
              path.hasPrefix("/"), !path.contains("..") else {
            throw GmailError.invalidArguments("请求地址不在允许范围内")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        for name in repeatedQuery.keys.sorted() {
            components.queryItems?.append(contentsOf: (repeatedQuery[name] ?? []).map {
                URLQueryItem(name: name, value: $0)
            })
        }
        guard let url = components.url else { throw GmailError.invalidArguments("请求地址无效") }
        return url
    }
}

public struct GmailHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol GmailHTTPTransport: Sendable {
    func send(_ request: GmailHTTPRequest) async throws -> GmailHTTPResponse
}

public final class GmailURLSessionTransport: GmailHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: GmailRedirectDelegate(), delegateQueue: nil)
    }

    public func send(_ request: GmailHTTPRequest) async throws -> GmailHTTPResponse {
        guard (request.body?.count ?? 0) <= GmailLimits.maximumResponseBytes else {
            throw GmailError.responseTooLarge
        }
        var urlRequest = URLRequest(url: try request.url(), cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: 20)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse,
                  http.url?.host == request.host else { throw GmailError.invalidResponse }
            if http.expectedContentLength > Int64(GmailLimits.maximumResponseBytes) {
                throw GmailError.responseTooLarge
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > GmailLimits.maximumResponseBytes { throw GmailError.responseTooLarge }
            }
            return GmailHTTPResponse(statusCode: http.statusCode, data: data)
        } catch let error as GmailError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut { throw GmailError.timeout }
            throw GmailError.transport
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GmailError.transport
        }
    }
}

private final class GmailRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

public struct GmailEndpointRecord: Codable, Sendable, Equatable {
    public let method: String
    public let host: String
    public let path: String

    public init(method: String, host: String, path: String) {
        self.method = method
        self.host = host
        self.path = path
    }
}

public actor GmailEndpointAudit {
    private var values: [GmailEndpointRecord] = []

    public init() {}

    public func records() -> [GmailEndpointRecord] { values }

    fileprivate func record(_ request: GmailHTTPRequest) {
        values.append(GmailEndpointRecord(method: request.method, host: request.host, path: request.path))
    }
}

public struct GmailAuditedTransport: GmailHTTPTransport {
    private let base: any GmailHTTPTransport
    private let audit: GmailEndpointAudit

    public init(base: any GmailHTTPTransport, audit: GmailEndpointAudit) {
        self.base = base
        self.audit = audit
    }

    public func send(_ request: GmailHTTPRequest) async throws -> GmailHTTPResponse {
        await audit.record(request)
        return try await base.send(request)
    }
}

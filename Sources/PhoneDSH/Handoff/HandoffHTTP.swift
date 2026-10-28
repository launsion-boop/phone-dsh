// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: handoff HTTP transport.
//
// PLAN §2.5 (D15) and spec/v1/handoff.md §1/§6. The client talks to
// the remote DSH host over TLS; this file keeps the HTTP shape (request body,
// response body, redirect policy) behind a small protocol so the tests can run
// the four endpoints in-process while production uses URLSession. TLS
// certificate validation, ATS and redirect rejection are URLSession behaviour;
// the client rejects a non-https endpoint before any request is built. The
// URLSession path is compiled and used on macOS but has not been run on an
// iPhone in this worktree: on-device TLS, background suspension and the
// temporary-file lifetime below are NOT_VERIFIED.

import Foundation

/// Body of one handoff request.
public enum HandoffHTTPBody: Sendable {
    /// No body.
    case empty
    /// An in-memory body (the JSON endpoints).
    case data(Data)
    /// `prefix` followed by the bytes of `payloadFile`, streamed from disk.
    /// Used for the snapshot and segments frames so a 272 MiB tar is never
    /// copied into one `Data`.
    case framed(prefix: Data, payloadFile: URL)

    /// Total body length when it can be determined synchronously.
    public var byteCount: Int {
        switch self {
        case .empty:
            return 0
        case .data(let data):
            return data.count
        case .framed(let prefix, let url):
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            return prefix.count + size
        }
    }

    /// Materializes the body. Only the in-process simulator and the tests use
    /// this; the URLSession transport streams `.framed` from its file instead.
    public func materializedData() throws -> Data {
        switch self {
        case .empty:
            return Data()
        case .data(let data):
            return data
        case .framed(let prefix, let url):
            var data = Data()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            data.reserveCapacity(prefix.count + size)
            data.append(prefix)
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url)
            } catch {
                throw HandoffError.badRequest("handoff payload file is unreadable")
            }
            defer { try? handle.close() }
            while true {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: 256 * 1024)
                } catch {
                    throw HandoffError.badRequest("handoff payload file is unreadable")
                }
                guard let chunk, !chunk.isEmpty else { break }
                data.append(chunk)
            }
            return data
        }
    }
}

/// One handoff HTTP request after the client built the URL, headers and body.
public struct HandoffHTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: HandoffHTTPBody

    public init(method: String, url: URL, headers: [String: String] = [:],
                body: HandoffHTTPBody = .empty) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// One complete handoff HTTP response.
public struct HandoffHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var bodyData: Data

    public init(status: Int, headers: [String: String] = [:], bodyData: Data = Data()) {
        self.status = status
        self.headers = headers
        self.bodyData = bodyData
    }

    /// Header lookup with the HTTP case-insensitive semantics.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        for (key, value) in headers where key.lowercased() == wanted {
            return value
        }
        return nil
    }
}

/// A response body already on disk. `cleanup()` removes the temporary file;
/// the caller owns it once ``HandoffHTTPTransport/download(_:)`` returns.
public struct HandoffHTTPDownload: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var bodyURL: URL
    public var removeWhenDone: Bool

    public init(status: Int, headers: [String: String], bodyURL: URL,
                removeWhenDone: Bool = true) {
        self.status = status
        self.headers = headers
        self.bodyURL = bodyURL
        self.removeWhenDone = removeWhenDone
    }

    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        for (key, value) in headers where key.lowercased() == wanted {
            return value
        }
        return nil
    }

    public func cleanup() {
        guard removeWhenDone else { return }
        try? FileManager.default.removeItem(at: bodyURL)
    }
}

/// Transport seam of ``HandoffClient``. The remote simulator implements it
/// in-process; production uses ``URLSessionHandoffTransport``.
public protocol HandoffHTTPTransport: Sendable {
    func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse
    /// Downloads a potentially large body (the reclaim frame) to a file.
    func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload
}

extension HandoffHTTPTransport {
    /// Default streaming download: uses ``send(_:)`` and writes the body to a
    /// temporary file. Transports that can stream natively override this.
    public func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        let response = try await send(request)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-handoff-response-\(UUID().uuidString)")
        do {
            try response.bodyData.write(to: url, options: .atomic)
        } catch {
            throw HandoffError.transport("cannot buffer the handoff response")
        }
        return HandoffHTTPDownload(status: response.status,
                                   headers: response.headers,
                                   bodyURL: url)
    }
}

// MARK: - TLS transport

/// URLSession-backed transport. Every request must be `https`; redirects are
/// rejected (handoff.md §6) and no URL cache or cookie jar is kept so a
/// reclaim payload cannot linger in a shared cache.
public final class URLSessionHandoffTransport: HandoffHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let delegate = HandoffRedirectRejectingDelegate()
        self.session = URLSession(configuration: configuration,
                                  delegate: delegate,
                                  delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPResponse {
        let urlRequest = try makeRequest(request)
        switch request.body {
        case .framed(let prefix, let payloadFile):
            let temporary = try materialize(prefix: prefix, payloadFile: payloadFile)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let (data, response) = try await session.upload(for: urlRequest,
                                                                fromFile: temporary)
                return try Self.makeResponse(data: data, response: response)
            } catch let error as HandoffError {
                throw error
            } catch {
                throw HandoffError.transport(Self.describe(error))
            }
        case .empty, .data:
            do {
                let (data, response) = try await session.data(for: urlRequest)
                return try Self.makeResponse(data: data, response: response)
            } catch let error as HandoffError {
                throw error
            } catch {
                throw HandoffError.transport(Self.describe(error))
            }
        }
    }

    public func download(_ request: HandoffHTTPRequest) async throws -> HandoffHTTPDownload {
        let urlRequest = try makeRequest(request)
        do {
            let (url, response) = try await session.download(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw HandoffError.transport("the handoff response is not HTTP")
            }
            return HandoffHTTPDownload(status: http.statusCode,
                                       headers: Self.headers(of: http),
                                       bodyURL: url)
        } catch let error as HandoffError {
            throw error
        } catch {
            throw HandoffError.transport(Self.describe(error))
        }
    }

    private func makeRequest(_ request: HandoffHTTPRequest) throws -> URLRequest {
        guard request.url.scheme?.lowercased() == "https" else {
            throw HandoffError.cleartextEndpoint
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if case .data(let data) = request.body {
            urlRequest.httpBody = data
        }
        return urlRequest
    }

    /// Writes `prefix + payloadFile` into a temporary file. The tar bytes are
    /// copied in bounded chunks, so the upload path never holds the whole
    /// snapshot in memory.
    private func materialize(prefix: Data, payloadFile: URL) throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-handoff-upload-\(UUID().uuidString)")
        guard let handle = FileHandle(forWritingAtPath: temporary.path)
            ?? Self.createFile(temporary) else {
            throw HandoffError.transport("cannot create the handoff upload body")
        }
        do {
            try handle.write(contentsOf: prefix)
            let source: FileHandle
            do {
                source = try FileHandle(forReadingFrom: payloadFile)
            } catch {
                throw HandoffError.transport("cannot read the handoff payload")
            }
            defer { try? source.close() }
            while true {
                let chunk: Data?
                do {
                    chunk = try source.read(upToCount: 256 * 1024)
                } catch {
                    throw HandoffError.transport("cannot read the handoff payload")
                }
                guard let chunk, !chunk.isEmpty else { break }
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
            return temporary
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            if let handoff = error as? HandoffError { throw handoff }
            throw HandoffError.transport("cannot write the handoff upload body")
        }
    }

    private static func createFile(_ url: URL) -> FileHandle? {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            return nil
        }
        return FileHandle(forWritingAtPath: url.path)
    }

    private static func makeResponse(data: Data, response: URLResponse) throws
        -> HandoffHTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            throw HandoffError.transport("the handoff response is not HTTP")
        }
        return HandoffHTTPResponse(status: http.statusCode,
                                   headers: headers(of: http),
                                   bodyData: data)
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let key = name as? String else { continue }
            result[key] = String(describing: value)
        }
        return result
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLSession error \(urlError.code.rawValue)"
        }
        return "URLSession request failed"
    }
}

/// Rejects every redirect: a redirect is a state change the phone must not
/// follow (handoff.md §6).
private final class HandoffRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

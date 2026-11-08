// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit

public enum LANDeviceTaskInboxError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidCredential, invalidResponse, unauthorized, unavailable, conflict, overflow
}

private final class NoTaskRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The caller must obtain an explicit task grant for the selected authenticated device.
public final class LANDeviceTaskInbox: DeviceTaskInbox, @unchecked Sendable {
    /// This identifier may be trusted only after the TLS endpoint has
    /// authenticated and accepted the user's credential.
    public let deviceID: String
    private let tasksURL: URL
    private let credential: String
    private let session: URLSession

    public convenience init(mcpURL: URL, authorization: String) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        try self.init(mcpURL: mcpURL, authorization: authorization, session: URLSession(configuration: configuration, delegate: NoTaskRedirects(), delegateQueue: nil))
    }

    init(mcpURL: URL, authorization: String, session: URLSession) throws {
        guard var parts = URLComponents(url: mcpURL, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.path == "/mcp", parts.query == nil, parts.fragment == nil else { throw LANDeviceTaskInboxError.invalidEndpoint }
        guard authorization.hasPrefix("Bearer "), (8...519).contains(authorization.utf8.count),
              authorization.utf8.dropFirst(7).allSatisfy({ (33...126).contains($0) }) else { throw LANDeviceTaskInboxError.invalidCredential }
        parts.path = "/tasks"
        guard let url = parts.url else { throw LANDeviceTaskInboxError.invalidEndpoint }
        self.deviceID = "lan:" + SHA256.hash(data: Data(mcpURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        self.tasksURL = url
        self.credential = authorization
        self.session = session
    }

    public func tasks() -> AsyncThrowingStream<DeviceTask, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: tasksURL)
                    request.setValue(credential, forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.check(response, terminal: false)
                    guard let http = response as? HTTPURLResponse,
                          http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
                        throw LANDeviceTaskInboxError.invalidResponse
                    }
                    var parser = TaskSSEParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let value = try parser.push(byte) {
                            switch continuation.yield(value) {
                            case .enqueued:
                                continuation.finish()
                                return
                            case .dropped: throw LANDeviceTaskInboxError.overflow
                            case .terminated: return
                            @unknown default: throw LANDeviceTaskInboxError.overflow
                            }
                        }
                    }
                    throw LANDeviceTaskInboxError.unavailable
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func accept(id: String) async throws {
        try await post(id: id, action: "accept", body: Data("{}".utf8), terminal: false)
    }

    public func report(id: String, outcome: DeviceTaskOutcome) async throws {
        guard outcome.isTransportSafe else { throw LANDeviceTaskInboxError.invalidResponse }
        let body: [String: Any]
        let action: String
        switch outcome {
        case .completed(let output, let truncated):
            action = "complete"; body = ["output": output, "truncated": truncated]
        case .failed(let kind, let message):
            action = "fail"; body = ["failure": ["kind": kind.rawValue, "message": message]]
        }
        try await post(id: id, action: action, body: JSONSerialization.data(withJSONObject: body), terminal: true)
    }

    private func post(id: String, action: String, body: Data, terminal: Bool) async throws {
        guard DeviceTask.validID(id) else { throw DeviceTaskError.invalidTask }
        let url = tasksURL.appendingPathComponent(id).appendingPathComponent(action)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credential, forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response, terminal: terminal)
        var count = 0
        for try await _ in bytes {
            count += 1
            guard count <= 65536 else { throw LANDeviceTaskInboxError.invalidResponse }
        }
    }

    private static func check(_ response: URLResponse, terminal: Bool) throws {
        guard let response = response as? HTTPURLResponse else { throw LANDeviceTaskInboxError.invalidResponse }
        switch response.statusCode {
        case 200, 204: return
        case 409 where terminal: return
        case 401, 403: throw LANDeviceTaskInboxError.unauthorized
        case 409, 422: throw LANDeviceTaskInboxError.conflict
        default: throw LANDeviceTaskInboxError.unavailable
        }
    }
}

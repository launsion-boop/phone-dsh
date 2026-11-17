// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSH: phone task queue HTTP client (phone side).
//
// spec/v1/cloud-tasks.md §2 and §5 over an injected transport. Requests go to
// the cloud origin only, carry `Authorization: Bearer <tono access token>` and
// follow tono-account.md §5 for 401 `credential_expired` / 503
// `identity_unavailable`, decided by the gateway's `TonoCloudResponsePolicy`
// (the same judge the model traffic uses) rather than a second copy.

import Foundation
import PhoneDSHGateway

/// One HTTP exchange with the cloud origin. Throwing means no answer.
public protocol CloudTaskTransport: Sendable {
    func send(_ request: URLRequest) async throws -> TonoAccountProtocol.Answer
}

/// `URLSession` transport: ephemeral, no cookies or cache, no redirects (the
/// bearer token is never replayed to another host), bounded response body.
public final class URLSessionCloudTaskTransport: CloudTaskTransport, @unchecked Sendable {
    /// 16 tasks of 16400 sealed bytes are about 360 KiB of base64url.
    public static let maximumBodyBytes = 1024 * 1024
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: URLRequest) async throws -> TonoAccountProtocol.Answer {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard data.count <= Self.maximumBodyBytes else { throw URLError(.dataLengthExceedsMaximum) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return TonoAccountProtocol.Answer(status: http.statusCode, headers: headers, body: data)
    }

    private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// Why a call produced no usable answer.
public enum CloudTaskClientError: Error, Equatable, Sendable {
    /// No account is signed in; nothing was sent.
    case signedOut
    /// Signed in, but no access token could be obtained; nothing was sent.
    case credentialUnavailable
    /// The transport gave no answer.
    case transport
    /// `404`: this cloud does not serve the route (an older deployment), or it
    /// does not know this device for this account.
    case notFound
    /// Any other refusal, with the contract's error `code` when the body carried one.
    case http(status: Int, code: String?)
    /// A success status whose body lacks a member the contract names, or has it with another type.
    case malformedResponse
    /// The body to send would break the contract; nothing was sent.
    case invalidRequest
}

/// The four phone-side calls.
public struct CloudTaskClient: Sendable {
    private let transport: any CloudTaskTransport
    private let tokens: any TonoAccessTokenSource
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let policy = TonoCloudResponsePolicy.production

    /// - Parameters:
    ///   - tokens: production passes `TonoAccountSession.shared`.
    ///   - sleep: the §5 `Retry-After` wait; tests record it instead of waiting.
    public init(transport: any CloudTaskTransport,
                tokens: any TonoAccessTokenSource,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }) {
        self.transport = transport
        self.tokens = tokens
        self.sleep = sleep
    }

    /// `PUT /v1/phone/devices/{device_id}`.
    public func register(deviceID: String, _ registration: CloudTaskDeviceRegistration) async throws -> CloudTaskDeviceAck {
        guard CloudTaskJSON.isDeviceID(deviceID), let body = try? registration.encoded() else {
            throw CloudTaskClientError.invalidRequest
        }
        let answer = try await exchange("PUT", "/v1/phone/devices/\(deviceID)", body: body)
        guard answer.status == 200 else { throw Self.refusal(answer) }
        guard let ack = try? CloudTaskDeviceAck.decode(answer.body) else { throw CloudTaskClientError.malformedResponse }
        return ack
    }

    /// `DELETE /v1/phone/devices/{device_id}`; repeating it is fine.
    public func unregister(deviceID: String) async throws {
        guard CloudTaskJSON.isDeviceID(deviceID) else { throw CloudTaskClientError.invalidRequest }
        let answer = try await exchange("DELETE", "/v1/phone/devices/\(deviceID)", body: nil)
        guard answer.status == 204 else { throw Self.refusal(answer) }
    }

    /// `GET /v1/phone/tasks/pull`. Values outside the contract's ranges are clamped here too.
    public func pull(deviceID: String, limit: Int = CloudTasks.batchMax, leaseSeconds: Int = 300,
                     waitSeconds: Int = 0) async throws -> CloudTaskPullResponse {
        guard CloudTaskJSON.isDeviceID(deviceID) else { throw CloudTaskClientError.invalidRequest }
        let wait = min(max(waitSeconds, 0), 60)
        let query = "device_id=\(deviceID)&limit=\(min(max(limit, 1), CloudTasks.batchMax))"
            + "&lease_s=\(min(max(leaseSeconds, 5), 900))&wait_s=\(wait)"
        let answer = try await exchange("GET", "/v1/phone/tasks/pull?\(query)", body: nil, extraTimeout: TimeInterval(wait))
        guard answer.status == 200 else { throw Self.refusal(answer) }
        guard let pulled = try? CloudTaskPullResponse.decode(answer.body) else { throw CloudTaskClientError.malformedResponse }
        return pulled
    }

    /// `POST /v1/phone/tasks/ack`; the results come back in request order.
    public func acknowledge(_ batch: CloudTaskAckBatch) async throws -> CloudTaskAckResponse {
        guard let body = try? batch.encoded() else { throw CloudTaskClientError.invalidRequest }
        let answer = try await exchange("POST", "/v1/phone/tasks/ack", body: body)
        guard answer.status == 200 else { throw Self.refusal(answer) }
        guard let response = try? CloudTaskAckResponse.decode(answer.body),
              response.results.count == batch.acks.count,
              zip(response.results, batch.acks).allSatisfy({ $0.taskID == $1.taskID }) else {
            throw CloudTaskClientError.malformedResponse
        }
        return response
    }

    // MARK: -

    static func refusal(_ answer: TonoAccountProtocol.Answer) -> CloudTaskClientError {
        if answer.status == 404 { return .notFound }
        return .http(status: answer.status, code: CloudTaskErrorBody.decode(answer.body)?.code)
    }

    /// One request with the tono-account §5 re-sends: at most one after
    /// `credential_expired` (only with a different token), at most two after
    /// `identity_unavailable`. Everything else is returned as answered.
    private func exchange(_ method: String, _ pathAndQuery: String, body: Data?,
                          extraTimeout: TimeInterval = 0) async throws -> TonoAccountProtocol.Answer {
        guard let url = URL(string: pathAndQuery, relativeTo: CloudTasks.origin)?.absoluteURL else {
            throw CloudTaskClientError.invalidRequest
        }
        var token = try await currentToken()
        var credentialResends = 0
        var identityResends = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            if extraTimeout > 0 { request.timeoutInterval = 20 + extraTimeout }
            let answer: TonoAccountProtocol.Answer
            do { answer = try await transport.send(request) } catch { throw CloudTaskClientError.transport }
            switch policy.decide(url: url, status: answer.status, headers: answer.headers, body: answer.body) {
            case .refreshRetry where credentialResends < TonoCloudResponsePolicy.credentialRetryMax:
                credentialResends += 1
                await tokens.invalidate(accessToken: token)
                guard let fresh = try? await tokens.accessToken(), fresh != token else { return answer }
                token = fresh
            case .retryAfter(let seconds) where identityResends < TonoCloudResponsePolicy.identityRetryMax:
                identityResends += 1
                await sleep(seconds)
            default:
                return answer
            }
        }
    }

    private func currentToken() async throws -> String {
        let token: String?
        do { token = try await tokens.accessToken() } catch { throw CloudTaskClientError.credentialUnavailable }
        guard let token else { throw CloudTaskClientError.signedOut }
        return token
    }
}

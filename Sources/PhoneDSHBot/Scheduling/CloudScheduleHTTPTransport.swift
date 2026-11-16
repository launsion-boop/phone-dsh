// SPDX-License-Identifier: MIT
//
// Frozen-contract `URLSession` transport (`spec/cloud/v1`, G-3B). Message
// bodies are the closed `bot-cloud-*` shapes; this file never logs the bearer
// token or a response body. `occurrence_at_ms` is the only occurrence time
// representation; the client never sends ISO variants.

import Foundation

public struct CloudScheduleHTTPConfiguration: Sendable, Equatable {
    public var baseURL: URL
    public var requestTimeoutSeconds: TimeInterval
    public var pollTimeoutGraceSeconds: TimeInterval
    public var maxResponseBytes: Int

    public init(baseURL: URL, requestTimeoutSeconds: TimeInterval = 15,
                pollTimeoutGraceSeconds: TimeInterval = 10,
                maxResponseBytes: Int = 1_048_576) {
        self.baseURL = baseURL
        self.requestTimeoutSeconds = max(1, requestTimeoutSeconds)
        self.pollTimeoutGraceSeconds = max(1, pollTimeoutGraceSeconds)
        self.maxResponseBytes = max(1_024, maxResponseBytes)
    }
}

public final class CloudScheduleHTTPTransport: CloudScheduleTransport, @unchecked Sendable {
    private let configuration: CloudScheduleHTTPConfiguration
    private let tokenProvider: @Sendable () async throws -> String?
    private let session: URLSession

    public init(configuration: CloudScheduleHTTPConfiguration,
                tokenProvider: @escaping @Sendable () async throws -> String?,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        let sessionConfiguration = sessionConfiguration
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = max(
            configuration.requestTimeoutSeconds, 30)
        sessionConfiguration.httpAdditionalHeaders = ["Accept": "application/json"]
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func sync(_ request: CloudScheduleSyncRequest) async throws -> CloudScheduleSyncResponse {
        var accepted: [CloudScheduleRegistration] = []
        var removedAccepted: [String] = []
        var removedRevisions: [String: Int64] = [:]
        var rejected: [CloudScheduleSyncRejection] = []
        var serverTimeMS: Int64 = 0
        for registration in request.registrations {
            let body = CloudScheduleWire.ScheduleRequest(
                op: registration.operation,
                deviceID: request.deviceID, botID: registration.botID,
                routineID: registration.routineID, revision: registration.revision,
                enabled: true, schedule: CloudScheduleWire.spec(from: registration.schedule),
                catchUp: registration.catchUp,
                authorizationRef: registration.authorizationRef)
            do {
                let data = try await send(
                    path: "/v1/bot/wake/schedule",
                    method: "PUT", query: [], body: try CloudScheduleWire.encoder().encode(body),
                    timeout: configuration.requestTimeoutSeconds)
                _ = try decode(CloudScheduleWire.ScheduleResponse.self, data)
                serverTimeMS = max(serverTimeMS, responseDateMS)
                accepted.append(registration)
            } catch let error as CloudScheduleTransportError {
                if isRevisionConflict(error) {
                    rejected.append(CloudScheduleSyncRejection(
                        routineID: registration.routineID, code: "revision_conflict",
                        currentRevision: currentRevision(from: error)))
                    continue
                }
                throw error
            }
        }
        for removal in request.removed {
            let query = [
                URLQueryItem(name: "device_id", value: request.deviceID),
                URLQueryItem(name: "routine_id", value: removal.routineID),
                URLQueryItem(name: "expected_revision", value: String(removal.revision)),
            ]
            do {
                let data = try await send(
                    path: "/v1/bot/wake/schedule",
                    method: "DELETE", query: query, body: nil,
                    timeout: configuration.requestTimeoutSeconds)
                let response = try decode(CloudScheduleWire.ScheduleResponse.self, data)
                serverTimeMS = max(serverTimeMS, responseDateMS)
                removedAccepted.append(removal.routineID)
                removedRevisions[removal.routineID] = response.revision
            } catch let error as CloudScheduleTransportError {
                if isRevisionConflict(error) {
                    rejected.append(CloudScheduleSyncRejection(
                        routineID: removal.routineID, code: "revision_conflict",
                        currentRevision: currentRevision(from: error)))
                    continue
                }
                throw error
            }
        }
        return CloudScheduleSyncResponse(
            serverTimeMS: serverTimeMS, accepted: accepted,
            removedAccepted: removedAccepted, removedRevisions: removedRevisions,
            rejected: rejected)
    }

    public func poll(_ request: CloudSchedulePollRequest) async throws -> CloudSchedulePollResponse {
        var query = [
            URLQueryItem(name: "device_id", value: request.deviceID),
            URLQueryItem(name: "bot_id", value: request.botID),
            URLQueryItem(name: "limit", value: String(request.limit)),
            URLQueryItem(name: "lease_s", value: String(request.leaseSeconds)),
        ]
        query.append(URLQueryItem(name: "wait_s", value: "0"))
        let data = try await send(
            path: "/v1/bot/wake/poll", method: "GET", query: query, body: nil,
            timeout: configuration.requestTimeoutSeconds + configuration.pollTimeoutGraceSeconds)
        let response = try decode(CloudScheduleWire.PollResponse.self, data)
        return CloudSchedulePollResponse(
            serverTimeMS: response.serverTimeMS > 0 ? response.serverTimeMS : responseDateMS,
            events: response.events.map { CloudScheduleWire.event(from: $0) })
    }

    public func acknowledge(_ request: CloudScheduleReceiptRequest) async throws -> CloudScheduleReceiptResponse {
        let receipt = CloudScheduleWire.AckReceipt(
            receiptID: request.receiptID, occurrenceKey: request.occurrenceKey,
            outcome: request.outcome.rawValue, reason: request.reason?.rawValue,
            completedAtMS: request.completedAtMS, localRunID: request.localRunID)
        let body = CloudScheduleWire.AckRequest(
            deviceID: request.deviceID, eventID: request.eventID, receipt: receipt)
        let data = try await send(
            path: "/v1/bot/wake/ack",
            method: "POST", query: [], body: try CloudScheduleWire.encoder().encode(body),
            timeout: configuration.requestTimeoutSeconds)
        let response = try decode(CloudScheduleWire.AckResponse.self, data)
        return CloudScheduleReceiptResponse(
            accepted: response.accepted, duplicate: response.duplicate,
            state: response.state)
    }

    public func reconcile(_ request: CloudScheduleReconcileRequest) async throws -> CloudScheduleReconcileResponse {
        let query = [
            URLQueryItem(name: "device_id", value: request.deviceID),
            URLQueryItem(name: "since_ms", value: String(request.sinceMS)),
            URLQueryItem(name: "limit", value: String(request.limit)),
            URLQueryItem(name: "cursor_ms", value: String(request.sinceMS)),
            URLQueryItem(name: "include_terminal",
                         value: request.includeTerminal ? "true" : "false"),
        ]
        let data = try await send(
            path: "/v1/bot/wake/reconcile", method: "GET", query: query, body: nil,
            timeout: configuration.requestTimeoutSeconds)
        let response = try decode(CloudScheduleWire.ReconcileResponse.self, data)
        return CloudScheduleReconcileResponse(
            serverTimeMS: response.serverTimeMS > 0 ? response.serverTimeMS : responseDateMS,
            events: response.events.map { CloudScheduleWire.event(from: $0) },
            nextCursorMS: response.nextCursorMS)
    }

    public func cancelRoutine(_ request: CloudScheduleCancelRequest) async throws {
        let query = [
            URLQueryItem(name: "device_id", value: request.deviceID),
            URLQueryItem(name: "routine_id", value: request.routineID),
            URLQueryItem(name: "expected_revision", value: String(request.expectedRevision)),
        ]
        _ = try await send(
            path: "/v1/bot/wake/schedule",
            method: "DELETE", query: query, body: nil,
            timeout: configuration.requestTimeoutSeconds)
    }

    public func cancelEvent(_ request: CloudScheduleEventCancelRequest) async throws {
        let body = try CloudScheduleWire.encoder().encode(
            ["device_id": request.deviceID, "reason": request.reason])
        _ = try await send(
            path: "/v1/bot/wake/events/\(escaped(request.eventID))/cancel",
            method: "POST", query: [], body: body,
            timeout: configuration.requestTimeoutSeconds)
    }

    // MARK: - HTTP

    /// Last response's `Date` header in epoch ms. The frozen responses carry
    /// `server_time_ms`; the header is only a fallback when a test stub or a
    /// proxy strips the body field.
    private var responseDateMS: Int64 { dateMS }

    private var dateMS: Int64 = 0

    private func send(path: String, method: String, query: [URLQueryItem],
                      body: Data?, timeout: TimeInterval) async throws -> Data {
        guard var components = URLComponents(url: configuration.baseURL,
                                             resolvingAgainstBaseURL: false) else {
            throw CloudScheduleTransportError.transport("invalid_base_url")
        }
        let basePath = configuration.baseURL.path.hasSuffix("/")
            ? String(configuration.baseURL.path.dropLast()) : configuration.baseURL.path
        components.path = basePath + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw CloudScheduleTransportError.transport("invalid_url")
        }
        var token = try await currentToken()
        var refreshedOnce = false
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = body

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CloudScheduleTransportError.cancelled
            } catch {
                throw CloudScheduleTransportError.transport("network")
            }
            guard let http = response as? HTTPURLResponse else {
                throw CloudScheduleTransportError.transport("not_http")
            }
            dateMS = Self.dateMilliseconds(http.value(forHTTPHeaderField: "Date"))
            guard data.count <= configuration.maxResponseBytes else {
                throw CloudScheduleTransportError.transport("response_too_large")
            }
            if (200...299).contains(http.statusCode) { return data }

            // One explicit token refresh + replay on 401. The frozen endpoints
            // are idempotent (schedule revision, same receipt id), so a replay
            // cannot duplicate a run or a receipt. A second 401 is terminal for
            // the client until the host says the account signed in again.
            if http.statusCode == 401, !refreshedOnce {
                refreshedOnce = true
                guard let refreshed = try await tokenProvider(), !refreshed.isEmpty else {
                    throw CloudScheduleTransportError.unauthenticated
                }
                if refreshed != token {
                    token = refreshed
                    continue
                }
                throw CloudScheduleTransportError.unauthenticated
            }
            let error = try? CloudScheduleWire.decoder().decode(
                CloudScheduleWire.ErrorBody.self, from: data)
            switch http.statusCode {
            case 401: throw CloudScheduleTransportError.unauthenticated
            case 403: throw CloudScheduleTransportError.forbidden
            case 404: throw CloudScheduleTransportError.notFound
            case 409:
                throw CloudScheduleTransportError.conflict(
                    code: error?.code ?? "conflict", currentRevision: error?.revision)
            case 429:
                throw CloudScheduleTransportError.rateLimited(
                    retryAfterMS: error?.retryAfterMS ?? retryAfter(from: http))
            case 400...499:
                throw CloudScheduleTransportError.invalidRequest(
                    code: error?.code ?? "invalid_request")
            default:
                throw CloudScheduleTransportError.server(
                    retryable: error?.retryable ?? true,
                    retryAfterMS: error?.retryAfterMS ?? retryAfter(from: http))
            }
        }
    }

    private func currentToken() async throws -> String {
        guard let token = try await tokenProvider(), !token.isEmpty else {
            throw CloudScheduleTransportError.unauthenticated
        }
        return token
    }

    /// The frozen wire error code is `revision-conflict` (hyphen); early SC
    /// builds used `revision_conflict`. Accept both at the transport edge and
    /// normalize the rejection to one client-side code.
    private func isRevisionConflict(_ error: CloudScheduleTransportError) -> Bool {
        guard case .conflict(let code, _) = error else { return false }
        return code == "revision-conflict" || code == "revision_conflict"
    }

    private func currentRevision(from error: CloudScheduleTransportError) -> Int64? {
        guard case .conflict(_, let currentRevision) = error else { return nil }
        return currentRevision
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try CloudScheduleWire.decoder().decode(type, from: data)
        } catch {
            throw CloudScheduleTransportError.transport("decode")
        }
    }

    private func retryAfter(from response: HTTPURLResponse) -> Int64? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int64(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(0, seconds) * 1000
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func dateMilliseconds(_ raw: String?) -> Int64 {
        guard let raw else { return 0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

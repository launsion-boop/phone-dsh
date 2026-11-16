// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Real `URLSession` + `URLProtocol` stub tests for the frozen cloud transport:
/// request shape, response decoding, status/error mapping. They do not need a
/// running cloud service; E's integration test covers the real local server.
final class CloudScheduleHTTPTransportTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:18080")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeTransport(token: String? = "token-1") -> CloudScheduleHTTPTransport {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        return CloudScheduleHTTPTransport(
            configuration: CloudScheduleHTTPConfiguration(baseURL: baseURL),
            tokenProvider: { token },
            sessionConfiguration: sessionConfiguration)
    }

    private func respond(status: Int, json: String,
                         headers: [String: String] = ["Content-Type": "application/json"]) {
        StubURLProtocol.handler = { request in
            StubURLProtocol.record(request)
            return (status, headers, Data(json.utf8))
        }
    }

    private let scheduleResponseJSON = """
    {"schema":"bot-cloud-schedule-response/v1","schedule_id":"sched-1",
     "revision":7,"next_due_at_ms":1763000000000}
    """

    func testPutCarriesOnlyIdsRevisionAndTiming() async throws {
        respond(status: 200, json: scheduleResponseJSON)
        let registration = CloudScheduleRegistration(
            routineID: "digest", botID: "bot-a", revision: 7, enabled: true,
            schedule: CloudScheduleSpec(kind: .interval, intervalMinutes: 30,
                                        timezone: "Asia/Taipei"),
            authorizationRef: "record://event/1")
        let response = try await makeTransport().sync(CloudScheduleSyncRequest(
            deviceID: "device-a", botID: "bot-a", registrations: [registration]))
        XCTAssertEqual(response.accepted.map(\.routineID), ["digest"])

        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/bot/wake/schedule")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        let body = try XCTUnwrap(request.httpBodyData)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["schema"] as? String, "bot-cloud-schedule-request/v1")
        XCTAssertEqual(json["op"] as? String, "register")
        XCTAssertEqual(json["bot_id"] as? String, "bot-a")
        XCTAssertEqual(json["device_id"] as? String, "device-a")
        XCTAssertEqual(json["routine_id"] as? String, "digest")
        XCTAssertEqual(json["revision"] as? Int64, 7)
        XCTAssertEqual(json["catch_up"] as? String, "latest")
        XCTAssertEqual(json["authorization_ref"] as? String, "record://event/1")
        let schedule = try XCTUnwrap(json["schedule"] as? [String: Any])
        XCTAssertEqual(schedule["kind"] as? String, "interval")
        XCTAssertEqual(schedule["interval_minutes"] as? Int, 30)
        XCTAssertEqual(schedule["timezone"] as? String, "Asia/Taipei")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("prompt"))
        XCTAssertFalse(text.contains("SECRET"))
    }

    func testDeleteUsesTheScheduleResponseAndQuery() async throws {
        respond(status: 200, json: """
        {"schema":"bot-cloud-schedule-response/v1","schedule_id":"sched-1",
         "revision":9,"next_due_at_ms":null}
        """)
        let response = try await makeTransport().sync(CloudScheduleSyncRequest(
            deviceID: "device-a", botID: "bot-a",
            removed: [CloudScheduleRemoval(routineID: "digest", revision: 9)]))
        XCTAssertEqual(response.removedAccepted, ["digest"])
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/bot/wake/schedule")
        let query = URLComponents(url: try XCTUnwrap(request.url),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "routine_id" })?.value, "digest")
        XCTAssertEqual(query.first(where: { $0.name == "expected_revision" })?.value, "9")
        XCTAssertEqual(query.first(where: { $0.name == "device_id" })?.value, "device-a")
    }

    func testPollDecodesEventsLeaseAndServerTime() async throws {
        respond(status: 200, json: """
        {"schema":"bot-cloud-poll-response/v1","server_time_ms":1762990000000,
         "events":[{"event_id":"evt-1","device_id":"device-a","bot_id":"bot-a",
                    "routine_id":"digest","occurrence_key":"abc",
                    "occurrence_at_ms":1762990100000,"scheduled_for_ms":1762990100000,
                    "schedule_revision":7,
                    "lease":{"lease_id":"lease-1","attempt":2,
                             "expires_at_ms":1762990700000}}]}
        """)
        let response = try await makeTransport().poll(CloudSchedulePollRequest(
            deviceID: "device-a", botID: "bot-a", limit: 16, leaseSeconds: 660))
        XCTAssertEqual(response.serverTimeMS, 1762990000000)
        let event = try XCTUnwrap(response.events.first)
        XCTAssertEqual(event.eventID, "evt-1")
        XCTAssertEqual(event.deviceID, "device-a")
        XCTAssertEqual(event.occurrenceKey, "abc")
        XCTAssertEqual(event.occurrenceAtMS, 1762990100000)
        XCTAssertEqual(event.scheduleRevision, 7)
        XCTAssertEqual(event.lease.leaseID, "lease-1")
        XCTAssertEqual(event.lease.attempt, 2)
        XCTAssertEqual(event.lease.expiresAtMS, 1762990700000)

        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/bot/wake/poll")
        let query = URLComponents(url: try XCTUnwrap(request.url),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "device_id" })?.value, "device-a")
        XCTAssertEqual(query.first(where: { $0.name == "bot_id" })?.value, "bot-a")
        XCTAssertEqual(query.first(where: { $0.name == "limit" })?.value, "16")
        XCTAssertEqual(query.first(where: { $0.name == "lease_s" })?.value, "660")
    }

    func testAckUsesFrozenEnvelopeAndDecodesResponse() async throws {
        respond(status: 200, json: """
        {"schema":"bot-cloud-ack-response/v1","accepted":true,"duplicate":false,
         "state":"terminal","server_time_ms":1762990000000}
        """)
        let response = try await makeTransport().acknowledge(CloudScheduleReceiptRequest(
            deviceID: "device-a", eventID: "evt-1", receiptID: "r-1",
            occurrenceKey: String(repeating: "a1", count: 32), outcome: .unknown,
            reason: .needsReconciliation, completedAtMS: 1762990005000,
            localRunID: "cloud-" + String(repeating: "a1", count: 32)))
        XCTAssertEqual(response.accepted, true)
        XCTAssertEqual(response.duplicate, false)
        XCTAssertEqual(response.state, "terminal")

        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/bot/wake/ack")
        let body = try XCTUnwrap(request.httpBodyData)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["schema"] as? String, "bot-cloud-ack/v1")
        XCTAssertEqual(json["device_id"] as? String, "device-a")
        XCTAssertEqual(json["event_id"] as? String, "evt-1")
        let receipt = try XCTUnwrap(json["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["receipt_id"] as? String, "r-1")
        XCTAssertEqual(receipt["outcome"] as? String, "unknown")
        XCTAssertEqual(receipt["reason"] as? String, "needs_reconciliation")
        XCTAssertEqual(receipt["completed_at_ms"] as? Int64, 1762990005000)
        XCTAssertEqual(receipt["local_run_id"] as? String,
                       "cloud-" + String(repeating: "a1", count: 32))
    }

    func testTerminalConflictMapsToConflict() async {
        respond(status: 409, json: """
        {"schema":"bot-cloud-error/v1","code":"event_terminal","state":"terminal",
         "server_time_ms":1762990000000}
        """)
        do {
            _ = try await makeTransport().acknowledge(CloudScheduleReceiptRequest(
                deviceID: "device-a", eventID: "evt-1", receiptID: "r-1",
                occurrenceKey: String(repeating: "a1", count: 32), outcome: .delivered,
                reason: nil, completedAtMS: 1762990005000,
                localRunID: "cloud-" + String(repeating: "a1", count: 32)))
            XCTFail("expected conflict")
        } catch let error as CloudScheduleTransportError {
            XCTAssertEqual(error, .conflict(code: "event_terminal", currentRevision: nil))
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnauthenticatedAndMissingTokenAreNotRetried() async {
        respond(status: 401, json: """
        {"schema":"bot-cloud-error/v1","code":"unauthenticated","server_time_ms":1}
        """)
        do {
            _ = try await makeTransport(token: "expired").poll(CloudSchedulePollRequest(
                deviceID: "device-a", botID: "bot-a", limit: 1, leaseSeconds: 5))
            XCTFail("expected unauthenticated")
        } catch let error as CloudScheduleTransportError {
            XCTAssertEqual(error, .unauthenticated)
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        do {
            _ = try await makeTransport(token: nil).poll(CloudSchedulePollRequest(
                deviceID: "device-a", botID: "bot-a", limit: 1, leaseSeconds: 5))
            XCTFail("expected unauthenticated without a token")
        } catch let error as CloudScheduleTransportError {
            XCTAssertEqual(error, .unauthenticated)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRateLimitedCarriesRetryAfter() async {
        respond(status: 429, json: """
        {"schema":"bot-cloud-error/v1","code":"rate_limited","server_time_ms":1}
        """, headers: ["Content-Type": "application/json", "Retry-After": "3"])
        do {
            _ = try await makeTransport().poll(CloudSchedulePollRequest(
                deviceID: "device-a", botID: "bot-a", limit: 1, leaseSeconds: 5))
            XCTFail("expected rate limited")
        } catch let error as CloudScheduleTransportError {
            XCTAssertEqual(error, .rateLimited(retryAfterMS: 3000))
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMalformedBodyIsATransportFailure() async {
        respond(status: 200, json: #"{"schema":"bot-cloud-poll-response/v1"}"#)
        do {
            _ = try await makeTransport().poll(CloudSchedulePollRequest(
                deviceID: "device-a", botID: "bot-a", limit: 1, leaseSeconds: 5))
            XCTFail("expected decode failure")
        } catch let error as CloudScheduleTransportError {
            XCTAssertEqual(error, .transport("decode"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReconcileDecodesCursorAndEvents() async throws {
        respond(status: 200, json: """
        {"schema":"bot-cloud-reconcile-response/v1","server_time_ms":1762990000000,
         "events":[{"event_id":"evt-1","device_id":"device-a","bot_id":"bot-a",
                    "routine_id":"digest","occurrence_key":"abc",
                    "occurrence_at_ms":1762990100000,"scheduled_for_ms":1762990100000,
                    "schedule_revision":7,
                    "lease":{"lease_id":"lease-2","attempt":2,
                             "expires_at_ms":1762990600000}}],
         "next_cursor_ms":1762990200000}
        """)
        let response = try await makeTransport().reconcile(CloudScheduleReconcileRequest(
            deviceID: "device-a", sinceMS: 0, limit: 16))
        XCTAssertEqual(response.nextCursorMS, 1762990200000)
        XCTAssertEqual(response.serverTimeMS, 1762990000000)
        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events.first?.lease.leaseID, "lease-2")

        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/bot/wake/reconcile")
        let query = URLComponents(url: try XCTUnwrap(request.url),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "since_ms" })?.value, "0")
        XCTAssertEqual(query.first(where: { $0.name == "include_terminal" })?.value, "false")
    }
}

/// Minimal `URLProtocol` stub. Test methods in one XCTestCase run serially, so
/// one handler is enough; the lock only protects against URLSession's loader
/// threads.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        recorded = []
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// `URLSession` moves an in-memory body into `httpBodyStream`; tests read
    /// whichever the request currently exposes.
    var httpBodyData: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

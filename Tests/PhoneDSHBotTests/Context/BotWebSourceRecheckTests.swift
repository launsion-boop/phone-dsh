// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Network
import XCTest
@testable import PhoneDSHBot

// MARK: - Test-only HTTP/1.1 server

struct RecheckServerRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
}

struct RecheckServerResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
    var delaySeconds: TimeInterval = 0
}

private final class RecheckServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (RecheckServerRequest) -> RecheckServerResponse
    private var seen: [RecheckServerRequest] = []

    init(handler: @escaping @Sendable (RecheckServerRequest) -> RecheckServerResponse) {
        self.handler = handler
    }

    func setHandler(_ next: @escaping @Sendable (RecheckServerRequest) -> RecheckServerResponse) {
        lock.lock(); defer { lock.unlock() }
        handler = next
    }

    func handle(_ request: RecheckServerRequest) -> RecheckServerResponse {
        lock.lock()
        seen.append(request)
        let handler = handler
        lock.unlock()
        return handler(request)
    }

    var requests: [RecheckServerRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }
}

private final class RecheckOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

final class LocalRecheckServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pdsh.recheck.test-server")
    private let listener: NWListener
    private let state: RecheckServerState
    private(set) var port: UInt16 = 0

    init(handler: @escaping @Sendable (RecheckServerRequest) -> RecheckServerResponse) throws {
        state = RecheckServerState(handler: handler)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var requests: [RecheckServerRequest] { state.requests }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let once = RecheckOnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener.port?.rawValue ?? 0
                    if once.claim() { continuation.resume(returning: self.baseURL) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func setHandler(_ next: @escaping @Sendable (RecheckServerRequest) -> RecheckServerResponse) {
        state.setHandler(next)
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: buffer[..<end.lowerBound])
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: Data) {
        guard let text = String(data: head, encoding: .utf8) else {
            connection.cancel(); return
        }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { connection.cancel(); return }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { connection.cancel(); return }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let request = RecheckServerRequest(
            method: requestLine[0].uppercased(),
            path: String(requestLine[1]),
            headers: headers)
        let response = state.handle(request)
        if response.delaySeconds > 0 {
            Thread.sleep(forTimeInterval: response.delaySeconds)
        }
        var allHeaders = response.headers
        allHeaders["Content-Length"] = String(response.body.count)
        allHeaders["Connection"] = "close"
        var headText = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            headText += "\(name): \(value)\r\n"
        }
        headText += "\r\n"
        var payload = Data(headText.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 203: return "Non-Authoritative Information"
        case 204: return "No Content"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

// MARK: - Test transport over URLSession

struct URLSessionRecheckTransport: BotWebRecheckTransport {
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        session = URLSession(configuration: configuration)
    }

    func perform(_ request: BotWebRecheckHTTPRequest) async throws -> BotWebRecheckHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = TimeInterval(request.timeoutMilliseconds) / 1_000
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw BotWebRecheckTransportError.invalidResponse
            }
            if data.count > request.maximumBodyBytes {
                throw BotWebRecheckTransportError.unavailable(code: "body-too-large")
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                headers[String(describing: name).lowercased()] = String(describing: value)
            }
            return BotWebRecheckHTTPResponse(
                status: http.statusCode, headers: headers, body: data,
                finalURL: http.url)
        } catch let error as BotWebRecheckTransportError {
            throw error
        } catch {
            throw BotWebRecheckTransportError.unavailable(code: "transport")
        }
    }
}


private struct ScriptedRecheckTransport: BotWebRecheckTransport {
    enum Behavior: Sendable {
        case failure(BotWebRecheckTransportError)
        case hang
        case cancel
    }

    let behavior: Behavior

    func perform(_ request: BotWebRecheckHTTPRequest) async throws -> BotWebRecheckHTTPResponse {
        switch behavior {
        case .failure(let error): throw error
        case .hang:
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw BotWebRecheckTransportError.unavailable(code: "unexpected")
        case .cancel: throw CancellationError()
        }
    }
}

// MARK: - Tests

final class BotWebSourceRecheckTests: XCTestCase {
    private func identity(_ url: URL, kind: BotWebResourceKind = .webURL) -> BotWebResourceIdentity {
        BotWebResourceIdentity(kind: kind, url: url.absoluteString, owner: "bot-a", scope: "grant-7")
    }

    private func rechecker(now: Int64 = 1_760_000_000_000)
        -> BotWebSourceRechecker {
        BotWebSourceRechecker(transport: URLSessionRecheckTransport(), now: { now })
    }

    func testETagChangeIsObservedOnTheSameIdentity() async throws {
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(
                status: 200,
                headers: ["ETag": "\"v1\"", "Content-Type": "text/plain"],
                body: Data("first".utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("/doc")
        let first = await rechecker().recheck(BotWebRecheckRequest(resource: identity(url)))
        guard case let .observed(current, previous, status) = first else {
            return XCTFail("expected first observation, got \(first)")
        }
        XCTAssertNil(previous)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(current.basis, .etag)
        XCTAssertEqual(current.value, "etag:\"v1\"")

        server.setHandler { _ in
            RecheckServerResponse(
                status: 200,
                headers: ["ETag": "\"v2\""],
                body: Data("second".utf8))
        }
        let second = await rechecker(now: 1_760_000_001_000).recheck(
            BotWebRecheckRequest(resource: identity(url), baseline: current))
        guard case let .changed(previousValue, currentValue) = second else {
            return XCTFail("expected changed, got \(second)")
        }
        XCTAssertEqual(previousValue, current)
        XCTAssertEqual(currentValue.value, "etag:\"v2\"")
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(server.requests[1].headers["if-none-match"], "\"v1\"",
                       "the producer must send the previous ETag as If-None-Match")
        XCTAssertNil(server.requests[1].headers["authorization"],
                     "the rechecker must not add credentials")
    }

    func testConditionalNotModifiedYieldsUnchanged() async throws {
        let server = try LocalRecheckServer { request in
            if request.headers["if-none-match"] == "\"v1\"" {
                return RecheckServerResponse(status: 304, headers: [:], body: Data())
            }
            return RecheckServerResponse(status: 200, headers: ["ETag": "\"v1\""],
                                         body: Data("body".utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("/cached")
        let baseline = BotWebRevision(basis: .etag, value: "etag:\"v1\"",
                                      observedAtMS: 1_760_000_000_000)
        let outcome = await rechecker(now: 1_760_000_002_000).recheck(
            BotWebRecheckRequest(resource: identity(url), baseline: baseline))
        guard case let .unchanged(current) = outcome else {
            return XCTFail("expected unchanged, got \(outcome)")
        }
        XCTAssertEqual(current.basis, .etag)
        XCTAssertEqual(current.value, "etag:\"v1\"")
        XCTAssertEqual(current.observedAtMS, 1_760_000_002_000)
        XCTAssertEqual(server.requests.first?.headers["if-none-match"], "\"v1\"")
    }

    func testLastModifiedChangeIsObserved() async throws {
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(
                status: 200,
                headers: ["Last-Modified": "Wed, 12 Nov 2025 08:00:00 GMT"],
                body: Data("body".utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("/last-modified")
        let first = await rechecker().recheck(BotWebRecheckRequest(resource: identity(url)))
        guard case let .observed(current, _, _) = first else {
            return XCTFail("expected observed, got \(first)")
        }
        XCTAssertEqual(current.basis, .lastModified)
        XCTAssertEqual(current.value, "last-modified:Wed, 12 Nov 2025 08:00:00 GMT")

        server.setHandler { _ in
            RecheckServerResponse(
                status: 200,
                headers: ["Last-Modified": "Thu, 13 Nov 2025 09:30:00 GMT"],
                body: Data("body".utf8))
        }
        let second = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(url), baseline: current))
        guard case let .changed(_, updated) = second else {
            return XCTFail("expected changed, got \(second)")
        }
        XCTAssertEqual(updated.basis, .lastModified)
        XCTAssertEqual(updated.value, "last-modified:Thu, 13 Nov 2025 09:30:00 GMT")
        XCTAssertEqual(server.requests[1].headers["if-modified-since"],
                       "Wed, 12 Nov 2025 08:00:00 GMT")
    }

    func testContentDigestFallbackDetectsRealBodyChange() async throws {
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(status: 200, headers: [:], body: Data("alpha".utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("/digest")
        let first = await rechecker().recheck(BotWebRecheckRequest(resource: identity(url)))
        guard case let .observed(current, _, _) = first else {
            return XCTFail("expected observed, got \(first)")
        }
        XCTAssertEqual(current.basis, .contentSHA256)
        XCTAssertTrue(current.value.hasPrefix("sha256:"))
        XCTAssertEqual(current.value.unicodeScalars.count, 7 + 64)

        server.setHandler { _ in
            RecheckServerResponse(status: 200, headers: [:], body: Data("beta".utf8))
        }
        let changed = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(url), baseline: current))
        guard case let .changed(_, updated) = changed else {
            return XCTFail("expected changed, got \(changed)")
        }
        XCTAssertNotEqual(updated.value, current.value)

        let same = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(url), baseline: updated))
        guard case .unchanged = same else {
            return XCTFail("expected unchanged for the same body, got \(same)")
        }
    }


    func testContentDigestNormalizesLineEndingsAndOuterWhitespace() async throws {
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(status: 200, headers: [:],
                                  body: Data("  alpha\r\nbeta\r\n".utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("/normalized")
        let normalized = "alpha\nbeta"
        let baseline = BotWebRevision(
            basis: .contentSHA256,
            value: "sha256:" + BotWebSourceRechecker.sha256(Data(normalized.utf8)),
            observedAtMS: 1_760_000_000_000)
        let same = await rechecker().recheck(BotWebRecheckRequest(
            resource: identity(url), baseline: baseline))
        guard case .unchanged = same else {
            return XCTFail("CRLF/outer whitespace must normalize to the same version: \(same)")
        }

        server.setHandler { _ in
            RecheckServerResponse(status: 200, headers: [:],
                                  body: Data("alpha\nbeta".utf8))
        }
        let changed = await rechecker().recheck(BotWebRecheckRequest(
            resource: identity(url), baseline: baseline))
        guard case .unchanged = changed else {
            return XCTFail("bare LF is the same normalized text, got \(changed)")
        }

        server.setHandler { _ in
            RecheckServerResponse(status: 200, headers: [:],
                                  body: Data("alpha beta".utf8))
        }
        let realChange = await rechecker().recheck(BotWebRecheckRequest(
            resource: identity(url), baseline: baseline))
        guard case .changed = realChange else {
            return XCTFail("a real content change must be changed, got \(realChange)")
        }
    }

    func testWebProvenanceAdapterMapsSameAndChanged() async throws {
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(status: 200, headers: [:], body: Data("alpha".utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("/adapter")
        let lane = BotResourceIdentity(kind: .webURL, key: url.absoluteString, owner: "bot-a")
        let normalized = "alpha"
        let known = BotProvenanceSourceVersion.known(
            basis: .contentSHA256,
            value: "sha256:" + BotWebSourceRechecker.sha256(Data(normalized.utf8)),
            observedAtMS: 1_760_000_000_000,
            basisRef: nil, subject: .recordText)
        let adapter = BotWebProvenanceRecheckAdapter(
            transport: URLSessionRecheckTransport())
        let same = await adapter.recheck(resource: lane, baseline: known, botID: "bot-a")
        guard case .same = same else {
            return XCTFail("expected same, got \(same)")
        }
        server.setHandler { _ in
            RecheckServerResponse(status: 200, headers: [:], body: Data("beta".utf8))
        }
        let changed = await adapter.recheck(resource: lane, baseline: known, botID: "bot-a")
        guard case let .changed(version, _) = changed else {
            return XCTFail("expected changed, got \(changed)")
        }
        XCTAssertEqual(version.knownValue?.prefix(7), "sha256:")
        XCTAssertEqual(version.subject, .recordText)
    }

    func testDifferentBasisIsReportedAsMismatchNotChanged() async throws {
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(status: 200, headers: [:], body: Data("alpha".utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("/basis")
        let baseline = BotWebRevision(basis: .etag, value: "etag:\"old\"",
                                      observedAtMS: 1_760_000_000_000)
        let outcome = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(url), baseline: baseline))
        guard case let .basisMismatch(previous, current) = outcome else {
            return XCTFail("expected basisMismatch, got \(outcome)")
        }
        XCTAssertEqual(previous.basis, .etag)
        XCTAssertEqual(current.basis, .contentSHA256)
    }

    func testWebDigestNormalizesLineEndingsAndUsesCloudDate() async throws {
        var body = " \n alpha\r\nbeta \n"
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(
                status: 200,
                headers: ["Date": "Wed, 12 Nov 2025 08:00:00 GMT"],
                body: Data(body.utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("/normalized")
        let first = await rechecker().recheck(BotWebRecheckRequest(resource: identity(url)))
        guard case let .observed(current, _, _) = first else {
            return XCTFail("expected observed, got \(first)")
        }
        XCTAssertEqual(current.basis, .contentSHA256)
        let expected = "alpha\nbeta"
        let digest = SHA256.hash(data: Data(expected.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(current.value, "sha256:\(digest)")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = try XCTUnwrap(formatter.date(from: "Wed, 12 Nov 2025 08:00:00 GMT"))
        XCTAssertEqual(current.observedAtMS,
                       Int64((date.timeIntervalSince1970 * 1_000).rounded()))

        body = "alpha\nbeta"
        let second = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(url), baseline: current))
        guard case .unchanged = second else {
            return XCTFail("normalized equal content must be unchanged, got \(second)")
        }
    }

    func testDeniedAndUnavailableStatuses() async throws {
        let server = try LocalRecheckServer { request in
            switch request.path {
            case "/denied":
                return RecheckServerResponse(status: 403, headers: [:], body: Data())
            case "/missing":
                return RecheckServerResponse(status: 404, headers: [:], body: Data())
            default:
                return RecheckServerResponse(status: 503, headers: [:], body: Data())
            }
        }
        let base = try await server.start()
        defer { server.stop() }

        let denied = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(base.appendingPathComponent("/denied"))))
        guard case let .denied(code, status) = denied else {
            return XCTFail("expected denied, got \(denied)")
        }
        XCTAssertEqual(code, .refreshDenied)
        XCTAssertEqual(status, 403)

        let missing = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(base.appendingPathComponent("/missing"))))
        guard case .unavailable(.refreshUnavailable) = missing else {
            return XCTFail("expected unavailable, got \(missing)")
        }

        let failed = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(base.appendingPathComponent("/failed"))))
        guard case .unavailable(.refreshUnavailable) = failed else {
            return XCTFail("expected unavailable, got \(failed)")
        }
    }

    func testConnectionFailureIsRefreshUnavailable() async throws {
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(status: 200, headers: [:], body: Data())
        }
        let base = try await server.start()
        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let outcome = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(base.appendingPathComponent("/gone"))))
        guard case .unavailable(.refreshUnavailable) = outcome else {
            return XCTFail("expected unavailable, got \(outcome)")
        }
    }

    func testRedirectAndOversizedBodyAreNotCurrent() async throws {
        let server = try LocalRecheckServer { request in
            if request.path == "/redirect" {
                return RecheckServerResponse(
                    status: 302, headers: ["Location": "http://127.0.0.1:1/other"],
                    body: Data())
            }
            return RecheckServerResponse(
                status: 200, headers: [:], body: Data(repeating: 0x61, count: 8_192))
        }
        let base = try await server.start()
        defer { server.stop() }

        let redirect = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(base.appendingPathComponent("/redirect"))))
        guard case .unavailable(.refreshUnavailable) = redirect else {
            return XCTFail("expected unavailable for a redirect, got \(redirect)")
        }

        var limited = BotWebRecheckRequest(
            resource: identity(base.appendingPathComponent("/large")))
        limited.maximumBodyBytes = 4_096
        let oversized = await rechecker().recheck(limited)
        guard case .unavailable(.refreshUnavailable) = oversized else {
            return XCTFail("expected unavailable for oversized body, got \(oversized)")
        }
        XCTAssertEqual(server.requests.count, 2)
    }

    func testInvalidIdentityAndBoundsAreNotPerformed() async {
        let rechecker = BotWebSourceRechecker(transport: UnavailableBotWebRecheckTransport())
        for url in ["ftp://example.com/a", "https://user:pass@example.com/a", "", "not-a-url"] {
            let outcome = await rechecker.recheck(
                BotWebRecheckRequest(resource: BotWebResourceIdentity(kind: .webURL, url: url)))
            guard case .notPerformed(.noResourceIdentity) = outcome else {
                return XCTFail("expected noResourceIdentity for \(url), got \(outcome)")
            }
        }
        var badTimeout = BotWebRecheckRequest(
            resource: BotWebResourceIdentity(kind: .webURL, url: "https://example.com/a"))
        badTimeout.timeoutMilliseconds = 10
        guard case .notPerformed(.refreshNotPerformed) = await rechecker.recheck(badTimeout) else {
            return XCTFail("expected refreshNotPerformed for an out-of-range deadline")
        }
    }


    func testTransportDeniedUnavailableTimeoutAndCancellationAreNotCurrent() async {
        let resource = BotWebResourceIdentity(
            kind: .webURL, url: "https://example.com/source", owner: "bot-a", scope: "grant-7")
        let request = BotWebRecheckRequest(resource: resource, timeoutMilliseconds: 100)

        let denied = await BotWebSourceRechecker(
            transport: ScriptedRecheckTransport(behavior: .failure(.denied(code: "host_not_allowed")))
        ).recheck(request)
        guard case .denied(.refreshDenied, nil) = denied else {
            return XCTFail("host policy denial must map to refresh-denied, got \(denied)")
        }

        let unavailable = await BotWebSourceRechecker(
            transport: ScriptedRecheckTransport(behavior: .failure(.unavailable(code: "timeout")))
        ).recheck(request)
        guard case .unavailable(.refreshUnavailable) = unavailable else {
            return XCTFail("transport failure must map to refresh-unavailable, got \(unavailable)")
        }

        let startedAt = Date()
        let timedOut = await BotWebSourceRechecker(
            transport: ScriptedRecheckTransport(behavior: .hang)
        ).recheck(request)
        guard case .unavailable(.refreshUnavailable) = timedOut else {
            return XCTFail("a hanging transport must map to refresh-unavailable, got \(timedOut)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0,
                          "the recheck deadline must bound the provider")

        let cancelled = await BotWebSourceRechecker(
            transport: ScriptedRecheckTransport(behavior: .cancel)
        ).recheck(request)
        guard case .cancelled = cancelled else {
            return XCTFail("cancellation must not be treated as current, got \(cancelled)")
        }
    }

    func testConnectorUsesTheSameProducer() async throws {
        let server = try LocalRecheckServer { request in
            RecheckServerResponse(status: 200,
                                  headers: ["ETag": request.headers["if-none-match"] == "\"c1\"" ? "\"c1\"" : "\"c2\""],
                                  body: Data("connector".utf8))
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("/connector")
        let first = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(url, kind: .connector)))
        guard case let .observed(current, _, _) = first else {
            return XCTFail("expected observed, got \(first)")
        }
        XCTAssertEqual(current.basis, .etag)
        let second = await rechecker().recheck(
            BotWebRecheckRequest(resource: identity(url, kind: .connector), baseline: current))
        guard case .unchanged = second else {
            return XCTFail("expected unchanged for the conditional connector request, got \(second)")
        }
        XCTAssertEqual(server.requests.first?.headers["if-none-match"], nil,
                       "the first observation has no baseline")
        XCTAssertEqual(server.requests.last?.headers["if-none-match"], "\"c2\"")
    }
}

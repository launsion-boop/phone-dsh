// SPDX-License-Identifier: MIT
// PhoneDSHLoopback /v1/http egress classification regression (ENG-04).
//
// G2-C09/G2-C10 exposed two gaps in the egress contract: every pre-response
// failure was answered with one generic `upstream_failed` body and the target
// host never appeared anywhere in the answer, so a Worker (and the catalog
// runner reading transcripts) could not tell a denied host from DNS, TLS, a
// timeout, an exhausted upstream status or a truncated body. ENG-04 makes the
// `/v1/http` writer answer with the closed `HTTPEgressFailureClass` taxonomy
// and a JSON envelope `{"error":..., "xl_error":{"code","host","detail"}}`.
//
// These tests pin one assertion per class plus the cross-module `NSError`
// seam the gateway uses (reason code in `NSLocalizedFailureReasonErrorKey`,
// the URL error in `NSUnderlyingErrorKey`). They also prove the body never
// echoes a request credential, a URL userinfo or a query token.

import Foundation
import XCTest
import PhoneDSHLoopback

// MARK: - Fixtures

/// Error shape of a structured egress failure, mirroring the gateway bridge:
/// a stable code in the standard failure-reason slot plus optional bridged
/// `NSError` identities.
enum ClassifiedFixtureError: Error, CustomNSError, LocalizedError {
    case structured(reason: String, message: String, underlying: NSError?)

    static var errorDomain: String { "Fixture.ClassifiedEgressError" }

    var errorCode: Int { 1 }

    var errorDescription: String? {
        guard case .structured(_, let message, _) = self else { return nil }
        return message
    }

    var errorUserInfo: [String: Any] {
        guard case .structured(let reason, let message, let underlying) = self else { return [:] }
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: message,
            NSLocalizedFailureReasonErrorKey: reason,
        ]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return info
    }
}

/// Writes a response head and part of a chunked body, then fails the stream.
/// This is the "upstream connection died mid-body" case: the head is already
/// on the wire, so the writer can only truncate the chunked framing and record
/// the transport classification.
final class InterruptedStreamHTTPEgress: HTTPEgress, @unchecked Sendable {
    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(HTTPEgressChunk(
                status: 200,
                headers: ["content-type": "application/octet-stream"],
                body: Data("partial-body".utf8),
                isFinal: false))
            continuation.finish(throwing: ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "the upstream connection was lost mid-body",
                underlying: urlError(NSURLErrorNetworkConnectionLost)))
        }
    }
}

/// Throws one fixed error so the writer's answer can be inspected over HTTP.
final class ClassifiedFailureHTTPEgress: HTTPEgress, @unchecked Sendable {
    let error: any Error

    init(_ error: any Error) {
        self.error = error
    }

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}

private func urlError(_ code: Int) -> NSError {
    NSError(domain: NSURLErrorDomain, code: code,
            userInfo: [NSLocalizedDescriptionKey: "the URL loading system failed (\(code))"])
}

// MARK: - Tests

final class LoopbackEgressClassificationTests: XCTestCase {
    /// The Worker-facing taxonomy is closed and stable: exactly the seven
    /// codes the contract names. A future refactor must update this test
    /// intentionally, never silently.
    func testTaxonomyIsTheClosedSevenClassSet() {
        XCTAssertEqual(
            Set(HTTPEgressFailureClass.allCases.map(\.rawValue)),
            ["host_not_allowed", "dns_failed", "tls_failed", "connect_timeout",
             "upstream_status", "body_too_large", "transport_failed"])
    }

    /// One classification assertion per failure class: code, attributed host,
    /// HTTP status and the `xl_error` body member.
    func testEveryFailureClassIsClassifiedWithCodeAndHost() throws {
        let cases: [(name: String, error: any Error,
                     expected: HTTPEgressFailureClass, status: Int)] = [
            ("host not allowed",
             ClassifiedFixtureError.structured(
                reason: "host_not_allowed",
                message: "upstream host is not allowed: cdn.example.test",
                underlying: nil),
             .hostNotAllowed, 403),
            ("dns",
             ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "A server with the specified hostname could not be found.",
                underlying: urlError(NSURLErrorDNSLookupFailed)),
             .dnsFailed, 502),
            ("tls",
             ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "An SSL error has occurred and a secure connection to the server cannot be made.",
                underlying: urlError(NSURLErrorSecureConnectionFailed)),
             .tlsFailed, 502),
            ("connect timeout",
             ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "The request timed out.",
                underlying: urlError(NSURLErrorTimedOut)),
             .connectTimeout, 504),
            ("upstream status",
             ClassifiedFixtureError.structured(
                reason: "upstream_status",
                message: "upstream api.example.test answered HTTP 503",
                underlying: nil),
             .upstreamStatus, 502),
            ("body too large",
             ClassifiedFixtureError.structured(
                reason: "body_too_large",
                message: "the upstream response exceeded the host body budget",
                underlying: urlError(NSURLErrorDataLengthExceedsMaximum)),
             .bodyTooLarge, 502),
            ("transport",
             ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "The network connection was lost.",
                underlying: urlError(NSURLErrorNetworkConnectionLost)),
             .transportFailed, 502),
        ]

        for item in cases {
            // Assemble the secret-bearing target from parts so the source
            // line itself stays free of an e-mail-looking userinfo.
            let userinfo = "user:secret-password"
            let target = "https://" + userinfo + "@cdn.example.test:443/repo/file"
                + "?access_token=secret-query-token"
            let failure = HTTPEgressFailure(error: item.error, target: target)
            XCTAssertEqual(failure.classification, item.expected,
                           "\(item.name): classification")
            XCTAssertEqual(failure.status, item.status, "\(item.name): status")
            XCTAssertEqual(failure.host, "cdn.example.test",
                           "\(item.name): host must be attributed without userinfo/path")

            let body = try XCTUnwrap(JSONSerialization.jsonObject(
                with: failure.encodedBody()) as? [String: Any])
            let xlError = try XCTUnwrap(body["xl_error"] as? [String: Any],
                                        "\(item.name): xl_error member missing")
            XCTAssertEqual(xlError["code"] as? String, item.expected.rawValue,
                           "\(item.name): xl_error.code")
            XCTAssertEqual(xlError["host"] as? String, "cdn.example.test",
                           "\(item.name): xl_error.host")
            XCTAssertNotNil(xlError["detail"] as? String,
                            "\(item.name): xl_error.detail")

            // G2-FIX-32's spec/exec-bridge-v1 envelope stays intact.
            let legacyError = try XCTUnwrap(body["error"] as? [String: Any],
                                            "\(item.name): error envelope missing")
            XCTAssertNotNil(legacyError["code"] as? String)

            // No credential, URL userinfo or query value may leak.
            let text = String(decoding: failure.encodedBody(), as: UTF8.self)
            XCTAssertFalse(text.contains("secret-password"), "\(item.name): userinfo leaked")
            XCTAssertFalse(text.contains("secret-query-token"), "\(item.name): query leaked")
            XCTAssertFalse(text.contains("/repo/file"), "\(item.name): path leaked")
        }
    }

    /// The explicit structured value keeps its G2-FIX-32 status while the
    /// taxonomy chooses the class; `credential_unavailable` folds into the
    /// generic transport class but its specific code survives.
    func testSpecificStableCodeSurvivesBesideTheClass() throws {
        let failure = HTTPEgressFailure(
            status: 502, code: "credential_unavailable",
            message: "no credential is configured for the upstream host")
        XCTAssertEqual(failure.classification, .transportFailed)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: failure.encodedBody()) as? [String: Any])
        let xlError = try XCTUnwrap(body["xl_error"] as? [String: Any])
        XCTAssertEqual(xlError["code"] as? String, "transport_failed")
        let error = try XCTUnwrap(body["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "credential_unavailable")
    }

    // MARK: Server integration

    private func startServer(egress: any HTTPEgress) async throws
        -> (server: LoopbackServer, client: TestHTTPClient) {
        let server = LoopbackServer(routes: LoopbackRoutes(httpEgress: egress))
        let endpoint = try await server.start()
        addTeardownBlock {
            await server.stop()
        }
        return (server, TestHTTPClient(endpoint: endpoint))
    }

    private func send(_ client: TestHTTPClient, target: String,
                      upstreamAuthorization: String? = nil) async throws
        -> (HTTPURLResponse, [String: Any]) {
        var headers = ["X-PDSH-Target-URL": target, "X-PDSH-Target-Method": "GET"]
        if let upstreamAuthorization {
            headers["X-PDSH-Upstream-Authorization"] = upstreamAuthorization
        }
        let (http, data) = try await client.send(
            "POST", "/v1/http", headers: headers)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (http, object)
    }

    /// The writer's single mapping point answers 504 for a connect timeout and
    /// 502 for DNS/upstream-status failures, and each body names the code and
    /// the attributed host.
    func testWriterAnswersClassifiedStatusAndHostEndToEnd() async throws {
        // `X-PDSH-Proxy-Error` keeps the G2-FIX-32 stable reason code; the
        // taxonomy lives in `xl_error.code` (and the run-log `class=` field).
        let cases: [(path: String, error: any Error, status: Int,
                     stableCode: String, classCode: String)] = [
            ("/host",
             ClassifiedFixtureError.structured(
                reason: "host_not_allowed",
                message: "upstream host is not allowed: cdn.example.test",
                underlying: nil),
             403, "host_not_allowed", "host_not_allowed"),
            ("/dns",
             ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "A server with the specified hostname could not be found.",
                underlying: urlError(NSURLErrorCannotFindHost)),
             502, "transport_failure", "dns_failed"),
            ("/tls",
             ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "An SSL error has occurred and a secure connection to the server cannot be made.",
                underlying: urlError(NSURLErrorSecureConnectionFailed)),
             502, "transport_failure", "tls_failed"),
            ("/timeout",
             ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "The request timed out.",
                underlying: urlError(NSURLErrorTimedOut)),
             504, "transport_failure", "connect_timeout"),
            ("/upstream",
             ClassifiedFixtureError.structured(
                reason: "upstream_status",
                message: "upstream cdn.example.test answered HTTP 503",
                underlying: nil),
             502, "upstream_status", "upstream_status"),
            ("/transport",
             ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "The network connection was lost.",
                underlying: urlError(NSURLErrorNetworkConnectionLost)),
             502, "transport_failure", "transport_failed"),
            ("/too-large",
             ClassifiedFixtureError.structured(
                reason: "body_too_large",
                message: "the upstream response exceeded the host body budget",
                underlying: urlError(NSURLErrorDataLengthExceedsMaximum)),
             502, "body_too_large", "body_too_large"),
        ]

        for item in cases {
            let (_, client) = try await startServer(
                egress: ClassifiedFailureHTTPEgress(item.error))
            let (http, object) = try await send(
                client, target: "https://cdn.example.test" + item.path)
            XCTAssertEqual(http.statusCode, item.status, item.classCode)
            XCTAssertEqual(http.value(forHTTPHeaderField: "X-PDSH-Proxy-Error"),
                           item.stableCode,
                           "\(item.classCode): the header keeps the stable cause code")
            let xlError = try XCTUnwrap(object["xl_error"] as? [String: Any])
            XCTAssertEqual(xlError["code"] as? String, item.classCode)
            XCTAssertEqual(xlError["host"] as? String, "cdn.example.test")
        }
    }

    /// A chunked response interrupted after the head must not be presented as
    /// a complete body; the cause classifies as `transport_failed`.
    func testChunkedStreamInterruptionIsATransportFailure() async throws {
        let (server, _) = try await startServer(egress: InterruptedStreamHTTPEgress())
        let endpoint = await server.endpoint
        let unwrapped = try XCTUnwrap(endpoint)
        let port = try XCTUnwrap(UInt16(exactly: unwrapped.baseURL.port ?? 0))
        let tcp = RawTCPClient(port: port)
        addTeardownBlock { tcp.close() }
        try await tcp.connect()
        var request = Data("POST /v1/http HTTP/1.1\r\n".utf8)
        request.append(Data("Host: 127.0.0.1:\(port)\r\n".utf8))
        request.append(Data("Authorization: Bearer \(unwrapped.token)\r\n".utf8))
        request.append(Data("X-PDSH-Target-URL: https://cdn.example.test/big.bin\r\n".utf8))
        request.append(Data("X-PDSH-Target-Method: GET\r\n".utf8))
        request.append(Data("Content-Length: 0\r\n".utf8))
        request.append(Data("Connection: close\r\n\r\n".utf8))
        try await tcp.send(request)

        let head = String(decoding: try await tcp.readUntil(Data("\r\n\r\n".utf8)),
                          as: UTF8.self)
        XCTAssertTrue(head.contains("200"), head)
        XCTAssertTrue(head.lowercased().contains("transfer-encoding: chunked"), head)
        // The partial chunk is on the wire, but the terminating chunk must
        // never arrive: the writer drops the connection on the interruption.
        do {
            _ = try await tcp.readUntil(Data("0\r\n\r\n".utf8), timeout: 1)
            XCTFail("a truncated chunked body must not be terminated as complete")
        } catch {
            // Expected: no terminating chunk.
        }

        let error = ClassifiedFixtureError.structured(
            reason: "transport_failure",
            message: "the upstream connection was lost mid-body",
            underlying: urlError(NSURLErrorNetworkConnectionLost))
        let failure = HTTPEgressFailure(error: error,
                                        target: "https://cdn.example.test/big.bin")
        XCTAssertEqual(failure.classification, .transportFailed)
        XCTAssertEqual(failure.status, 502)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: failure.encodedBody()) as? [String: Any])
        let xlError = try XCTUnwrap(body["xl_error"] as? [String: Any])
        XCTAssertEqual(xlError["code"] as? String, "transport_failed")
        XCTAssertEqual(xlError["host"] as? String, "cdn.example.test")
    }

    /// A request credential travelling in either allowed header never appears
    /// in the proxy answer.
    func testAnswerNeverEchoesRequestCredentials() async throws {
        let error = ClassifiedFixtureError.structured(
            reason: "transport_failure",
            message: "The network connection was lost.",
            underlying: urlError(NSURLErrorNetworkConnectionLost))
        let (_, client) = try await startServer(egress: ClassifiedFailureHTTPEgress(error))
        let (http, object) = try await send(
            client, target: "https://cdn.example.test/file",
            upstreamAuthorization: "Bearer upstream-secret-token")
        XCTAssertEqual(http.statusCode, 502)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object,
                                                               options: [.sortedKeys]),
                          as: UTF8.self)
        XCTAssertFalse(text.contains("upstream-secret-token"), text)
        XCTAssertFalse(text.contains("authorization"), text.lowercased())
        XCTAssertFalse(text.contains(client.endpoint.token), "the loopback token leaked")
    }

    /// Defence in depth: a producer message that embeds URL userinfo or a
    /// bearer-shaped token is redacted before it reaches `detail`.
    func testProducerMessageCredentialsAreRedacted() throws {
        let userinfo = "user:secret-password"
        let bearer = "Bearer " + String(repeating: "a", count: 32)
        let message = "failed https://" + userinfo + "@cdn.example.test/x with " + bearer
        let error = ClassifiedFixtureError.structured(
            reason: "transport_failure", message: message, underlying: nil)
        let failure = HTTPEgressFailure(error: error, target: "https://cdn.example.test/x")
        let text = String(decoding: failure.encodedBody(), as: UTF8.self)
        XCTAssertFalse(text.contains("secret-password"), text)
        XCTAssertFalse(text.contains(String(repeating: "a", count: 32)), text)
        XCTAssertTrue(text.contains("<redacted>"), text)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: failure.encodedBody()) as? [String: Any])
        let xlError = try XCTUnwrap(body["xl_error"] as? [String: Any])
        XCTAssertEqual(xlError["host"] as? String, "cdn.example.test")
    }

    /// A typed failure thrown directly by an `HTTPEgress` still gets the host
    /// attributed by the writer, so the curl shim can say which host failed.
    func testTypedFailureGetsHostAttributedByTheWriter() async throws {
        let typed = HTTPEgressFailure(
            status: 502, code: "transport_failure",
            message: "the upstream reset the stream")
        let (_, client) = try await startServer(egress: ClassifiedFailureHTTPEgress(typed))
        let (http, object) = try await send(
            client, target: "https://raw.githubusercontent.com/torvalds/linux/master/README")
        XCTAssertEqual(http.statusCode, 502)
        let xlError = try XCTUnwrap(object["xl_error"] as? [String: Any])
        XCTAssertEqual(xlError["code"] as? String, "transport_failed")
        XCTAssertEqual(xlError["host"] as? String, "raw.githubusercontent.com")
    }

    /// The run-log line names the same class and host as the response, so a G2
    /// rerun can attribute the failure without reading the Worker's saved body.
    func testDiagnosticLineCarriesClassAndHost() {
        let failure = HTTPEgressFailure(
            error: ClassifiedFixtureError.structured(
                reason: "transport_failure",
                message: "The request timed out.",
                underlying: urlError(NSURLErrorTimedOut)),
            target: "https://cdn.example.test/file")
        XCTAssertEqual(failure.classification, .connectTimeout)
        let line = failure.diagnosticLine(target: "https://cdn.example.test/file")
        XCTAssertTrue(line.contains("status=504"), line)
        XCTAssertTrue(line.contains("class=connect_timeout"), line)
        XCTAssertTrue(line.contains("host=cdn.example.test"), line)
        XCTAssertFalse(line.lowercased().contains("authorization"), line)

        let userinfo = "user:secret-password"
        let secretLine = failure.diagnosticLine(
            target: "https://" + userinfo + "@cdn.example.test/file"
                + "?access_token=secret-query-token")
        XCTAssertFalse(secretLine.contains("secret-password"), secretLine)
        XCTAssertFalse(secretLine.contains("secret-query-token"), secretLine)
        XCTAssertTrue(secretLine.contains("target=https://cdn.example.test/file"), secretLine)
    }
}

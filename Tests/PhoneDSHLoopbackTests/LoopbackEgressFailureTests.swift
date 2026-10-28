// SPDX-License-Identifier: MIT
// PhoneDSHLoopback /v1/http egress failure regression (G2-FIX-32).
//
// The response writer used to fold every thrown egress error into one generic
// 502 `upstream_failed` body. These tests pin the opposite contract: the HTTP
// status, the machine-readable code, the message and the originating error
// identity of an egress failure are all visible to the Worker (and to the run
// log), so a denied host, a missing credential and a transport failure are
// distinguishable. The fixture errors reproduce the `NSError` shape the model
// gateway's structured errors bridge to: the stable reason token travels in
// `NSLocalizedFailureReasonErrorKey` and a transport cause in
// `NSUnderlyingErrorKey` (both Foundation keys, the cross-module seam).
//
// Before the fix every case below produced the same 84-byte body and no
// `X-PDSH-Proxy-Error` header, so the distinct-cause assertions fail.

import Foundation
import XCTest
import PhoneDSHLoopback

// MARK: - Fixtures

/// Error shape of a structured egress failure: a stable code in the standard
/// failure-reason slot plus optional bridged `NSError` identities.
enum FixtureEgressError: Error, CustomNSError, LocalizedError {
    case hostNotAllowed(host: String)
    case credentialUnavailable
    case transportFailure(reason: String, domain: String, code: Int)

    static var errorDomain: String { "Fixture.ModelGatewayError" }

    var errorCode: Int {
        switch self {
        case .hostNotAllowed: return 1
        case .credentialUnavailable: return 3
        case .transportFailure: return 6
        }
    }

    var errorDescription: String? {
        switch self {
        case .hostNotAllowed(let host):
            return "upstream host is not allowed: \(host)"
        case .credentialUnavailable:
            return "no credential is configured for the upstream host"
        case .transportFailure(let reason, let domain, let code):
            return "upstream transport failed: \(reason) (\(domain) \(code))"
        }
    }

    /// Stable machine code, the value `X-PDSH-Proxy-Error` and `error.code` take.
    var structuredCode: String {
        switch self {
        case .hostNotAllowed: return "host_not_allowed"
        case .credentialUnavailable: return "credential_unavailable"
        case .transportFailure: return "transport_failure"
        }
    }

    var errorUserInfo: [String: Any] {
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: errorDescription ?? structuredCode,
            NSLocalizedFailureReasonErrorKey: structuredCode,
        ]
        if case .transportFailure(let reason, let domain, let code) = self {
            info[NSUnderlyingErrorKey] = NSError(
                domain: domain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return info
    }
}

/// Fails the egress for the URL's last path component, so one server covers
/// every cause.
final class ScriptedFailureHTTPEgress: HTTPEgress, @unchecked Sendable {
    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        let failure: FixtureEgressError
        switch request.url.lastPathComponent {
        case "host-not-allowed":
            failure = .hostNotAllowed(host: "cdn.example.test")
        case "credential-unavailable":
            failure = .credentialUnavailable
        case "transport-failure":
            failure = .transportFailure(reason: "The Internet connection appears to be offline.",
                                        domain: NSURLErrorDomain,
                                        code: NSURLErrorNotConnectedToInternet)
        default:
            failure = .hostNotAllowed(host: "unknown")
        }
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: failure)
        }
    }
}

/// Fails with the public structured failure type directly.
final class TypedFailureHTTPEgress: HTTPEgress, @unchecked Sendable {
    let failure: HTTPEgressFailure

    init(failure: HTTPEgressFailure) {
        self.failure = failure
    }

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: failure)
        }
    }
}

/// Ends without ever yielding a response head.
final class EmptyHTTPEgress: HTTPEgress, @unchecked Sendable {
    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

// MARK: - Tests

final class LoopbackEgressFailureTests: XCTestCase {
    private func startServer(egress: any HTTPEgress) async throws
        -> (server: LoopbackServer, client: TestHTTPClient) {
        let server = LoopbackServer(routes: LoopbackRoutes(httpEgress: egress))
        let endpoint = try await server.start()
        addTeardownBlock {
            await server.stop()
        }
        return (server, TestHTTPClient(endpoint: endpoint))
    }

    private func send(_ client: TestHTTPClient, targetSuffix: String) async throws
        -> (HTTPURLResponse, [String: Any]) {
        let (http, data) = try await client.send(
            "POST", "/v1/http",
            headers: ["X-PDSH-Target-URL": "https://example.test" + targetSuffix,
                      "X-PDSH-Target-Method": "GET"])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = try XCTUnwrap(object?["error"] as? [String: Any],
                                  "the body is not the spec/exec-bridge-v1 §1 error envelope")
        return (http, error)
    }

    /// The core G2-FIX-32 regression: three different egress causes must not
    /// collapse into one generic 502 body.
    func testDistinctEgressCausesAreDistinguishable() async throws {
        let (_, client) = try await startServer(egress: ScriptedFailureHTTPEgress())
        let cases = [
            (path: "/host-not-allowed", status: 403, code: "host_not_allowed",
             message: "upstream host is not allowed: cdn.example.test"),
            (path: "/credential-unavailable", status: 502, code: "credential_unavailable",
             message: "no credential is configured for the upstream host"),
            (path: "/transport-failure", status: 502, code: "transport_failure",
             message: "The Internet connection appears to be offline."),
        ]

        var bodies: Set<Data> = []
        for item in cases {
            let (http, error) = try await send(client, targetSuffix: item.path)
            XCTAssertEqual(http.statusCode, item.status,
                           "\(item.code) must use its own HTTP status")
            XCTAssertEqual(http.value(forHTTPHeaderField: "X-PDSH-Proxy-Error"), item.code,
                           "\(item.code) must travel in X-PDSH-Proxy-Error")
            XCTAssertEqual(error["code"] as? String, item.code,
                           "the body code must name the cause")
            let message = try XCTUnwrap(error["message"] as? String)
            XCTAssertTrue(message.contains(item.message),
                          "\(item.code) message must carry its cause, got: \(message)")
            let details = try XCTUnwrap(error["details"] as? [String: Any],
                                        "\(item.code) must carry the source identity")
            XCTAssertEqual(details["source_domain"] as? String, "Fixture.ModelGatewayError")
            XCTAssertEqual(details["source_code"] as? Int, FixtureEgressError.code(for: item.code))
        }

        // Collect the raw bodies again to prove they differ from one another.
        for item in cases {
            let (_, data) = try await client.send(
                "POST", "/v1/http",
                headers: ["X-PDSH-Target-URL": "https://example.test" + item.path,
                          "X-PDSH-Target-Method": "GET"])
            bodies.insert(data)
        }
        XCTAssertEqual(bodies.count, cases.count,
                       "each egress cause must produce a distinct response body")
    }

    /// A transport failure carries the underlying error domain and code; a
    /// denied host does not pretend to have one.
    func testTransportFailureCarriesUnderlyingDomainAndCode() async throws {
        let (_, client) = try await startServer(egress: ScriptedFailureHTTPEgress())
        let (_, error) = try await send(client, targetSuffix: "/transport-failure")
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        XCTAssertEqual(details["underlying_domain"] as? String, NSURLErrorDomain)
        XCTAssertEqual(details["underlying_code"] as? Int, NSURLErrorNotConnectedToInternet)

        let (_, hostError) = try await send(client, targetSuffix: "/host-not-allowed")
        let hostDetails = try XCTUnwrap(hostError["details"] as? [String: Any])
        XCTAssertNil(hostDetails["underlying_domain"],
                     "a pre-flight failure has no transport cause to report")
    }

    /// An `HTTPEgress` may throw the structured failure type directly; the
    /// writer preserves every field.
    func testTypedEgressFailureControlsTheResponse() async throws {
        let failure = HTTPEgressFailure(
            status: 429,
            code: "rate_limited",
            message: "the upstream asked the caller to slow down",
            source: .init(domain: "Fixture.Upstream", code: 11),
            underlying: .init(domain: NSURLErrorDomain,
                              code: NSURLErrorTimedOut))
        let (_, client) = try await startServer(
            egress: TypedFailureHTTPEgress(failure: failure))
        let (http, error) = try await send(client, targetSuffix: "/anything")
        XCTAssertEqual(http.statusCode, 429)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-PDSH-Proxy-Error"), "rate_limited")
        XCTAssertEqual(error["code"] as? String, "rate_limited")
        XCTAssertEqual(error["message"] as? String, failure.message)
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        XCTAssertEqual(details["source_domain"] as? String, "Fixture.Upstream")
        XCTAssertEqual(details["source_code"] as? Int, 11)
        XCTAssertEqual(details["underlying_domain"] as? String, NSURLErrorDomain)
        XCTAssertEqual(details["underlying_code"] as? Int, NSURLErrorTimedOut)
    }

    /// An error with no structured code still carries its bridged identity, so
    /// an unknown `HTTPEgress` implementation is diagnosable too.
    func testUnstructuredErrorStillCarriesSourceIdentity() async throws {
        let (_, client) = try await startServer(egress: FailingHTTPEgress())
        let (http, error) = try await send(client, targetSuffix: "/anything")
        XCTAssertEqual(http.statusCode, 502)
        XCTAssertEqual(error["code"] as? String, "upstream_failed")
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        let domain = try XCTUnwrap(details["source_domain"] as? String)
        XCTAssertTrue(domain.hasSuffix(".LoopbackError"),
                      "the producing error's NSError domain must survive, got: \(domain)")
        XCTAssertNotNil(details["source_code"],
                        "the bridged NSError code must survive for attribution")
    }

    /// A stream that ends before the response head is an egress contract
    /// violation, not a generic upstream failure.
    func testEgressStreamWithoutResponseHeadIsStructured() async throws {
        let (_, client) = try await startServer(egress: EmptyHTTPEgress())
        let (http, error) = try await send(client, targetSuffix: "/anything")
        XCTAssertEqual(http.statusCode, 502)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-PDSH-Proxy-Error"), "egress_no_response")
        XCTAssertEqual(error["code"] as? String, "egress_no_response")
    }

    /// The one-line run-log diagnostic names the same cause, target and bridged
    /// identities as the response, so a G2 rerun can attribute a failed fetch
    /// from the host's run log alone (G2-FIX-32). It must never include request
    /// headers (the gateway credential is not part of this error).
    func testDiagnosticLineCarriesCauseTargetAndUnderlyingIdentity() {
        let transport = HTTPEgressFailure(error: FixtureEgressError.transportFailure(
            reason: "The Internet connection appears to be offline.",
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet))
        let line = transport.diagnosticLine(
            target: "https://cdn.example.test/repo/README.md")
        XCTAssertTrue(line.contains("target=https://cdn.example.test/repo/README.md"),
                      line)
        XCTAssertTrue(line.contains("status=502"), line)
        XCTAssertTrue(line.contains("code=transport_failure"), line)
        XCTAssertTrue(line.contains("source=Fixture.ModelGatewayError/6"), line)
        XCTAssertTrue(line.contains(
            "underlying=NSURLErrorDomain/\(NSURLErrorNotConnectedToInternet)"), line)
        XCTAssertTrue(line.contains("offline"), line)
        XCTAssertFalse(line.lowercased().contains("authorization"), line)

        let denied = HTTPEgressFailure(error: FixtureEgressError.hostNotAllowed(
            host: "cdn.example.test"))
        let deniedLine = denied.diagnosticLine(target: "https://cdn.example.test/")
        XCTAssertTrue(deniedLine.contains("status=403"), deniedLine)
        XCTAssertTrue(deniedLine.contains("code=host_not_allowed"), deniedLine)
        XCTAssertTrue(deniedLine.contains("cdn.example.test"), deniedLine)
        XCTAssertFalse(deniedLine.contains("underlying="),
                       "a pre-flight failure has no transport cause: \(deniedLine)")
    }
}

private extension FixtureEgressError {
    static func code(for structuredCode: String) -> Int {
        switch structuredCode {
        case "host_not_allowed": return 1
        case "credential_unavailable": return 3
        case "transport_failure": return 6
        default: return 0
        }
    }
}

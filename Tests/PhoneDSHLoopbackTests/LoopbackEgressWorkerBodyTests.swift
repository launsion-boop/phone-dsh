// SPDX-License-Identifier: MIT
// PhoneDSHLoopback /v1/http Worker-facing failure body (ENG-04).
//
// The Worker shell's `curl` shim keeps real-curl semantics: without `-f` a
// non-2xx answer exits 0 and the response body is written to the `-o` target.
// The body is therefore the only diagnostic a model can read after a failed
// egress. The amended ENG-04 acceptance is exactly that contract: every
// pre-head egress failure must answer 502/504 (403 only when the origin denies
// the host, spec/exec-bridge-v1 §6) and the bytes curl writes to its output
// file must be the structured envelope
//
//   `{"error":{...},"xl_error":{"code","host","detail"}}`
//
// with one of the seven taxonomy classes in `xl_error.code` and the failed
// upstream host in `xl_error.host`. G2-C09 showed the opposite: a generic
// 84-byte body that told the model nothing, which it then presented as a
// successful download.
//
// The fixture errors reproduce the `NSError` bridge of the gateway's
// `ModelGatewayError` (stable reason code in NSLocalizedFailureReasonErrorKey,
// transport identity in NSUnderlyingErrorKey), so each case walks the same
// seam a real G2 run walks. Before ENG-04 the same assertions fail because the
// `xl_error` member does not exist.

import Foundation
import XCTest
import PhoneDSHLoopback

// MARK: - Fixtures

/// `NSError` shape the gateway's structured errors bridge to.
private enum WorkerBodyGatewayError: Error, CustomNSError, LocalizedError {
    case structured(reason: String, message: String, underlying: NSError?)

    static var errorDomain: String { "Fixture.ModelGatewayError" }

    var errorCode: Int { 1 }

    var errorDescription: String? {
        guard case .structured(_, let message, _) = self else { return nil }
        return message
    }

    var errorUserInfo: [String: Any] {
        guard case .structured(let reason, let message, let underlying) = self else {
            return [:]
        }
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: message,
            NSLocalizedFailureReasonErrorKey: reason,
        ]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return info
    }
}

/// Selects one gateway failure by the target URL's last path component, and
/// models the "stream ended before a response head" case too.
private final class WorkerBodyScriptedEgress: HTTPEgress, @unchecked Sendable {
    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        let path = request.url.lastPathComponent
        return AsyncThrowingStream { continuation in
            if path == "no-head" {
                continuation.finish()
            } else {
                continuation.finish(throwing: Self.failure(for: path))
            }
        }
    }

    private static func failure(for path: String) -> WorkerBodyGatewayError {
        switch path {
        case "host-not-allowed":
            return .structured(
                reason: "host_not_allowed",
                message: "upstream host is not allowed: raw.githubusercontent.com",
                underlying: nil)
        case "dns":
            return .structured(
                reason: "transport_failure",
                message: "A server with the specified hostname could not be found.",
                underlying: urlError(NSURLErrorCannotFindHost))
        case "tls":
            return .structured(
                reason: "transport_failure",
                message: "An SSL error has occurred and a secure connection to the server cannot be made.",
                underlying: urlError(NSURLErrorSecureConnectionFailed))
        case "timeout":
            return .structured(
                reason: "transport_failure",
                message: "The request timed out.",
                underlying: urlError(NSURLErrorTimedOut))
        case "upstream-status":
            return .structured(
                reason: "upstream_status",
                message: "upstream raw.githubusercontent.com answered HTTP 503",
                underlying: nil)
        case "body-too-large":
            return .structured(
                reason: "body_too_large",
                message: "the upstream response exceeded the host body budget",
                underlying: urlError(NSURLErrorDataLengthExceedsMaximum))
        case "transport":
            return .structured(
                reason: "transport_failure",
                message: "The network connection was lost.",
                underlying: urlError(NSURLErrorNetworkConnectionLost))
        default:
            return .structured(reason: "transport_failure",
                               message: "unscripted failure", underlying: nil)
        }
    }

    private static func urlError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "the URL loading system failed (\(code))"])
    }
}

// MARK: - Tests

final class LoopbackEgressWorkerBodyTests: XCTestCase {
    private func startServer(egress: any HTTPEgress) async throws
        -> (server: LoopbackServer, client: TestHTTPClient) {
        let server = LoopbackServer(routes: LoopbackRoutes(httpEgress: egress))
        let endpoint = try await server.start()
        addTeardownBlock {
            await server.stop()
        }
        return (server, TestHTTPClient(endpoint: endpoint))
    }

    private func fetchThroughLoopback(_ client: TestHTTPClient,
                                      target: String) async throws
        -> (HTTPURLResponse, Data) {
        try await client.send(
            "POST", "/v1/http",
            headers: ["X-PDSH-Target-URL": target, "X-PDSH-Target-Method": "GET"])
    }

    /// The Worker-visible contract: the response is non-2xx, so real curl
    /// reports the failure (exit 22 with `-f`; exit 0 and a body written to
    /// `-o` without `-f`), and the bytes at that `-o` target are the structured
    /// reason envelope with the taxonomy class and the upstream host.
    func testCurlOutputFileForAFailedEgressCarriesTheStructuredReason() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { removeTemporaryDirectory(directory) }
        let (_, client) = try await startServer(egress: WorkerBodyScriptedEgress())

        // status, xl_error.code, legacy error.code, proxy-error header
        let cases: [(path: String, status: Int, classCode: String, stableCode: String)] = [
            ("host-not-allowed", 403, "host_not_allowed", "host_not_allowed"),
            ("dns", 502, "dns_failed", "transport_failure"),
            ("tls", 502, "tls_failed", "transport_failure"),
            ("timeout", 504, "connect_timeout", "transport_failure"),
            ("upstream-status", 502, "upstream_status", "upstream_status"),
            ("body-too-large", 502, "body_too_large", "body_too_large"),
            ("transport", 502, "transport_failed", "transport_failure"),
            ("no-head", 502, "transport_failed", "egress_no_response"),
        ]

        for (index, item) in cases.enumerated() {
            let host = "raw.githubusercontent.com"
            let (http, data) = try await fetchThroughLoopback(
                client, target: "https://" + host + "/torvalds/linux/" + item.path)

            // The status is what makes curl fail (`-f`) or keep the body
            // (`-o`); either way it must never look like a 2xx success.
            XCTAssertEqual(http.statusCode, item.status, item.path)
            XCTAssertFalse((200...299).contains(http.statusCode), item.path)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"),
                           "application/json; charset=utf-8", item.path)
            XCTAssertEqual(http.value(forHTTPHeaderField: "X-PDSH-Proxy-Error"),
                           item.stableCode, item.path)

            // Exactly the worker-visible artifact: real curl writes the body
            // bytes to the `-o` target, so read them back from a file.
            let outputFile = directory.appendingPathComponent("curl-out-\(index).json")
            try data.write(to: outputFile)
            let written = try Data(contentsOf: outputFile)
            XCTAssertEqual(written, data, item.path)

            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: written) as? [String: Any],
                "\(item.path): the -o target must contain the JSON failure envelope")
            let xlError = try XCTUnwrap(
                object["xl_error"] as? [String: Any],
                "\(item.path): the -o target must carry the structured reason")
            XCTAssertEqual(Set(xlError.keys), ["code", "host", "detail"], item.path)
            XCTAssertEqual(xlError["code"] as? String, item.classCode,
                           "\(item.path): taxonomy class")
            XCTAssertEqual(xlError["host"] as? String, host,
                           "\(item.path): the failed upstream host")
            let detail = try XCTUnwrap(xlError["detail"] as? String, item.path)
            XCTAssertFalse(detail.isEmpty, "\(item.path): the model must get a reason")

            // G2-FIX-32's spec/exec-bridge-v1 envelope and header stay intact.
            let legacy = try XCTUnwrap(object["error"] as? [String: Any], item.path)
            XCTAssertEqual(legacy["code"] as? String, item.stableCode, item.path)
            XCTAssertNotNil(legacy["message"] as? String, item.path)

            // The file the model reads must never contain a credential, the
            // loopback bearer or the request path/query.
            let text = String(decoding: written, as: UTF8.self)
            XCTAssertFalse(text.contains(client.endpoint.token),
                           "\(item.path): loopback token leaked")
            XCTAssertFalse(text.contains("Bearer "), "\(item.path): credential leaked")
            XCTAssertFalse(text.contains("/torvalds/linux/"),
                           "\(item.path): request path leaked")
        }
    }

    /// The G2-C09 shape in particular: the egress stream ends before a head, so
    /// the model has no upstream response to blame. The answer still names the
    /// host and a taxonomy class instead of the old `upstream_failed`-with-no-
    /// reason body.
    func testEgressWithoutAResponseHeadNamesTheHostInTheOutputFile() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { removeTemporaryDirectory(directory) }
        let (_, client) = try await startServer(egress: WorkerBodyScriptedEgress())

        let (http, data) = try await fetchThroughLoopback(
            client, target: "https://raw.githubusercontent.com/torvalds/linux/no-head")
        XCTAssertEqual(http.statusCode, 502)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-PDSH-Proxy-Error"),
                       "egress_no_response")

        let outputFile = directory.appendingPathComponent("linux-readme.md")
        try data.write(to: outputFile)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: outputFile))
                as? [String: Any])
        let xlError = try XCTUnwrap(object["xl_error"] as? [String: Any])
        XCTAssertEqual(xlError["code"] as? String, "transport_failed")
        XCTAssertEqual(xlError["host"] as? String, "raw.githubusercontent.com")
        XCTAssertEqual(object["error"].flatMap { $0 as? [String: Any] }?["code"] as? String,
                       "egress_no_response")
    }
}

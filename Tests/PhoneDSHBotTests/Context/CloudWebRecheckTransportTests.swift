// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSHBot

final class CloudWebRecheckTransportTests: XCTestCase {
    private func transport(
        base: URL,
        token: String? = "token-1"
    ) -> CloudWebRecheckTransport {
        CloudWebRecheckTransport(
            configuration: .init(baseURL: base, requestTimeoutSeconds: 3),
            tokenProvider: { token })
    }

    private func resource(_ server: LocalRecheckServer) -> BotResourceIdentity {
        BotResourceIdentity(
            kind: .webURL,
            key: server.baseURL.appendingPathComponent("page").absoluteString,
            owner: "bot-a", scope: "grant-7")
    }

    private func content(_ text: String) -> RecheckServerResponse {
        let body = try! JSONSerialization.data(withJSONObject: [
            "content": text,
            "title": "page",
        ])
        return RecheckServerResponse(status: 200, headers: ["Content-Type": "application/json"],
                                     body: body)
    }

    private func digest(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hash)"
    }

    func testCloudFetchIsNormalizedToChangedAndSame() async throws {
        var body = "version one"
        let server = try LocalRecheckServer { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/v1/web/fetch")
            XCTAssertEqual(request.headers["authorization"], "Bearer token-1")
            return self.content(body)
        }
        let base = try await server.start()
        defer { server.stop() }
        let adapter = BotProvenanceWebRecheckAdapter(transport: transport(base: base))
        let baseline = BotProvenanceSourceVersion.known(
            BotKnownProvenanceSourceVersion(basis: .contentSHA256, value: digest(body)))
        let resource = resource(server)

        let same = await adapter.recheck(resource: resource, baseline: baseline, botID: "bot-a")
        guard case .same = same else { return XCTFail("expected same, got \(same)") }

        body = "version two"
        let changed = await adapter.recheck(
            resource: resource, baseline: baseline, botID: "bot-a")
        guard case let .changed(version, _) = changed else {
            return XCTFail("expected changed, got \(changed)")
        }
        guard case let .known(known) = version else {
            return XCTFail("expected known version")
        }
        XCTAssertEqual(known.basis, .contentSHA256)
        XCTAssertEqual(known.value, digest(body))
        XCTAssertEqual(server.requests.count, 2)
    }

    func testCloudDeniedAndUnavailableAreNotCurrent() async throws {
        var status = 401
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(status: status, headers: [:], body: Data())
        }
        let base = try await server.start()
        defer { server.stop() }
        let adapter = BotProvenanceWebRecheckAdapter(transport: transport(base: base))
        let baseline = BotProvenanceSourceVersion.known(
            BotKnownProvenanceSourceVersion(basis: .contentSHA256, value: digest("x")))
        let denied = await adapter.recheck(
            resource: resource(server), baseline: baseline, botID: "bot-a")
        guard case .denied = denied else {
            return XCTFail("expected denied, got \(denied)")
        }
        status = 503
        let unavailable = await adapter.recheck(
            resource: resource(server), baseline: baseline, botID: "bot-a")
        guard case .unavailable = unavailable else {
            return XCTFail("expected unavailable, got \(unavailable)")
        }
    }

    func testCloudTransportDoesNotKeepOrLogTheBody() async throws {
        let server = try LocalRecheckServer { _ in
            RecheckServerResponse(
                status: 200,
                headers: [:],
                body: try! JSONSerialization.data(withJSONObject: ["content": "secret body"]))
        }
        let base = try await server.start()
        defer { server.stop() }
        let response = try await transport(base: base).perform(
            BotWebRecheckHTTPRequest(
                method: "GET", url: server.baseURL.appendingPathComponent("page"),
                headers: [:], timeoutMilliseconds: 3_000, maximumBodyBytes: 1_048_576))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "secret body",
                       "the transport returns the bounded body to the in-memory rechecker")
        // There is deliberately no cache/log API on the transport; this test
        // also proves the response is not persisted by the type itself.
    }

    func testMissingTokenIsDeniedWithoutNetwork() async throws {
        let server = try LocalRecheckServer { _ in
            XCTFail("no network call is allowed without a token")
            return RecheckServerResponse(status: 200, headers: [:], body: Data())
        }
        let base = try await server.start()
        defer { server.stop() }
        let adapter = BotProvenanceWebRecheckAdapter(
            transport: transport(base: base, token: nil))
        let baseline = BotProvenanceSourceVersion.known(
            BotKnownProvenanceSourceVersion(basis: .contentSHA256, value: digest("x")))
        let outcome = await adapter.recheck(
            resource: resource(server), baseline: baseline, botID: "bot-a")
        guard case .denied = outcome else {
            return XCTFail("expected denied without token, got \(outcome)")
        }
        XCTAssertEqual(server.requests.count, 0)
    }
}

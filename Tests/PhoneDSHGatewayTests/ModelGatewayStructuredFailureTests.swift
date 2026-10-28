// SPDX-License-Identifier: MIT
// PhoneDSHGateway structured failure regression (G2-FIX-32).
//
// `/v1/http` can only explain an egress failure through the error the gateway
// stream throws: the loopback layer has no other channel. A Swift error
// bridges to `NSError`, so the bridge is the contract the writer reads: the
// stable cause code must travel in `NSLocalizedFailureReasonErrorKey` and a
// transport cause in `NSUnderlyingErrorKey`. Before the fix every gateway
// error bridged to code 0 with an empty `userInfo`, so the three causes the
// Worker cares about were indistinguishable and the underlying URLSession
// error was discarded by `UpstreamAttemptEvent.finished(failed:)`.
//
// These tests use only the pre-existing public surface so they compile and
// fail on assertions before the fix.

import Foundation
import XCTest
import PhoneDSHGateway
import PhoneDSHAgentCore

final class ModelGatewayStructuredFailureTests: XCTestCase {
    private func makeGateway(server: MockUpstreamServer,
                             allowedHosts: Set<String>? = nil,
                             credentialValue: String? = "test-credential",
                             clock: ManualGatewayClock = ManualGatewayClock())
        throws -> ModelGateway {
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: allowedHosts ?? ["127.0.0.1:\(server.port)"],
            responseLogQuotaBytes: 1_000_000,
            backoff: ModelGatewayBackoffPolicy(initialDelay: 0,
                                               multiplier: 2,
                                               maximumDelay: 60,
                                               jitterFraction: 0,
                                               maximumAttempts: 2),
            upstreamRequestTimeout: 5)
        let providers: any CredentialProvider = credentialValue.map {
            makeBearerProvider(host: "127.0.0.1", value: $0)
        } ?? StaticCredentialProvider([:])
        let gateway = ModelGateway(configuration: configuration,
                                   credentialProvider: providers,
                                   clock: clock)
        addTeardownBlock {
            await gateway.shutdown()
        }
        return gateway
    }

    private func request(port: UInt16) -> GatewayRequest {
        GatewayRequest(method: "GET",
                       url: URL(string: "http://127.0.0.1:\(port)/v1/models")!,
                       headers: ["accept": "application/json"])
    }

    private func bridged(_ error: Error) -> NSError {
        error as NSError
    }

    private func reason(_ error: Error) -> String? {
        bridged(error).userInfo[NSLocalizedFailureReasonErrorKey] as? String
    }

    /// The three pre-response failures must expose distinct, stable causes.
    func testHostCredentialAndTransportFailuresAreDistinguishable() async throws {
        let server = try MockUpstreamServer { _ in .abort(partial: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }

        // 1. Host not on the allow-list.
        let deniedGateway = try makeGateway(server: server, allowedHosts: ["api.example.invalid"])
        let denied = try await expectGatewayFailure(deniedGateway.handle(request(port: server.port)))
        XCTAssertEqual(denied as? ModelGatewayError, .hostNotAllowed("127.0.0.1"))

        // 2. Allow-listed host without a credential.
        let credentialGateway = try makeGateway(server: server, credentialValue: nil)
        let missing = try await expectGatewayFailure(
            credentialGateway.handle(request(port: server.port)))
        XCTAssertEqual(missing as? ModelGatewayError, .credentialUnavailable)

        // 3. The upstream transport aborts before any response byte.
        let transportGateway = try makeGateway(server: server)
        let transport = try await expectGatewayFailure(
            transportGateway.handle(request(port: server.port)))
        XCTAssertTrue(transport is ModelGatewayError)

        // The bridged NSError identities must all be distinct.
        let codes = [bridged(denied).code, bridged(missing).code, bridged(transport).code]
        XCTAssertEqual(Set(codes).count, 3,
                       "each cause needs its own bridged NSError code, got \(codes)")
        for error in [denied, missing, transport] {
            XCTAssertEqual(bridged(error).domain, "PhoneDSHGateway.ModelGatewayError")
            XCTAssertNotNil(reason(error),
                            "the stable cause code must travel in NSLocalizedFailureReasonErrorKey")
        }
        XCTAssertEqual(reason(denied), "host_not_allowed")
        XCTAssertEqual(reason(missing), "credential_unavailable")
        XCTAssertEqual(reason(transport), "transport_failure")

        // Messages must name the cause and stay distinct.
        let descriptions = [denied, missing, transport].compactMap {
            ($0 as? LocalizedError)?.errorDescription
        }
        XCTAssertEqual(descriptions.count, 3)
        XCTAssertEqual(Set(descriptions).count, 3)
        let deniedDescription = try XCTUnwrap((denied as? LocalizedError)?.errorDescription)
        XCTAssertTrue(deniedDescription.contains("127.0.0.1"),
                      "the denied host must be named, got: \(deniedDescription)")
        let transportDescription = try XCTUnwrap((transport as? LocalizedError)?.errorDescription)
        XCTAssertTrue(transportDescription.contains(NSURLErrorDomain)
                        || transportDescription.contains("transport"),
                      "the transport message must carry the underlying identity, got: "
                        + transportDescription)
    }

    /// A transport failure must keep the URLSession error domain and code that
    /// the old `finished(failed:)` event discarded.
    func testTransportFailureKeepsUnderlyingURLSessionIdentity() async throws {
        let server = try MockUpstreamServer { _ in .abort(partial: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let gateway = try makeGateway(server: server)

        let error = try await expectGatewayFailure(gateway.handle(request(port: server.port)))
        let underlying = bridged(error).userInfo[NSUnderlyingErrorKey] as? NSError
        let cause = try XCTUnwrap(underlying,
                                  "the transport failure must carry NSUnderlyingErrorKey")
        XCTAssertEqual(cause.domain, NSURLErrorDomain)
        XCTAssertNotEqual(cause.code, 0, "the URLSession code must survive the bridge")
    }
}

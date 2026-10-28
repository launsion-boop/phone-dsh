// SPDX-License-Identifier: MIT
// Handoff protocol, limits and credential tests (spec/v1/handoff.md).

import XCTest
import PhoneDSH
import PhoneDSHWire
import PhoneDSHAgentCore

final class HandoffProtocolTests: XCTestCase {
    // MARK: - Binary frame (§3)

    func testFrameRoundTrip() throws {
        let metadata = Data("{\"generation\":1}".utf8)
        let payload = Data([0x00, 0x01, 0xFE, 0xFF])
        let frame = try HandoffFrameCodec.encode(metadata: metadata, payload: payload)
        XCTAssertEqual(frame.count, 4 + metadata.count + payload.count)
        let decoded = try HandoffFrameCodec.decode(frame)
        XCTAssertEqual(decoded.metadata, metadata)
        XCTAssertEqual(decoded.payload, payload)
        let prefix = try HandoffFrameCodec.prefix(metadata: metadata)
        XCTAssertEqual(prefix, frame.prefix(4 + metadata.count))
    }

    func testFrameRejectsInvalidMetadataLengths() {
        XCTAssertThrowsError(try HandoffFrameCodec.encode(metadata: Data(),
                                                          payload: Data())) { error in
            XCTAssertEqual(error as? HandoffError,
                           .badRequest("meta_len 0 is outside 1...65536"))
        }
        var tooLong = Data()
        tooLong.append(0)
        tooLong.append(0)
        tooLong.append(1)
        tooLong.append(0)
        tooLong.append(0)
        XCTAssertThrowsError(try HandoffFrameCodec.decode(tooLong))
    }

    func testFrameRejectsTruncatedMetadata() {
        var frame = Data([0x00, 0x00, 0x00, 0x10])
        frame.append(Data("{}".utf8))
        XCTAssertThrowsError(try HandoffFrameCodec.decode(frame)) { error in
            XCTAssertEqual(error as? HandoffError,
                           .badRequest("handoff frame metadata is truncated"))
        }
    }

    // MARK: - Metadata (§3–§5)

    func testSnapshotMetadataCanonicalJSON() throws {
        let hash = String(repeating: "ab", count: 32)
        let metadata = HandoffSnapshotMetadata(generation: 1,
                                               materializedUptoMseq: 2,
                                               walSeq: 3,
                                               payloadBytes: 4,
                                               payloadSha256: hash)
        let data = try CanonicalJSON.encode(metadata)
        let expected = "{\"generation\":1,\"materialized_upto_mseq\":2,"
            + "\"payload_bytes\":4,\"payload_sha256\":\"\(hash)\",\"wal_seq\":3}"
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
        let decoded = try JSONDecoder().decode(HandoffSnapshotMetadata.self, from: data)
        XCTAssertEqual(decoded, metadata)
    }

    func testSnapshotMetadataRejectsBaseAboveTarget() {
        let metadata = HandoffSnapshotMetadata(
            generation: 1, materializedUptoMseq: 5, walSeq: 4,
            payloadBytes: 0, payloadSha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try metadata.validate())
    }

    func testSegmentDescriptorValidation() {
        let valid = HandoffSegmentDescriptor(file: "wal/00000001.000000.xlwal",
                                             firstMseq: 1, lastMseq: 2,
                                             bytes: 100)
        XCTAssertNoThrow(try valid.validate())
        let badName = HandoffSegmentDescriptor(file: "wal/1.0.xlwal",
                                               firstMseq: 1, lastMseq: 2,
                                               bytes: 100)
        XCTAssertThrowsError(try badName.validate())
        let badRange = HandoffSegmentDescriptor(file: "wal/00000001.000000.xlwal",
                                                firstMseq: 3, lastMseq: 2,
                                                bytes: 100)
        XCTAssertThrowsError(try badRange.validate())
        let tooLarge = HandoffSegmentDescriptor(file: "wal/00000001.000000.xlwal",
                                                firstMseq: 1, lastMseq: 2,
                                                bytes: UInt64(HandoffLimits.maximumSegmentFileBytes + 1))
        XCTAssertThrowsError(try tooLarge.validate())
        XCTAssertTrue(HandoffSegmentDescriptor.isValidFileName("wal/99999999.999999.xlwal"))
        XCTAssertFalse(HandoffSegmentDescriptor.isValidFileName("wal/00000001.000000.tar"))
    }

    func testSegmentsResponseAdmissionMustMatchApplied() throws {
        let response = HandoffSegmentsResponse(baseMseq: 0, appliedMseq: 1,
                                               walSeq: 2, admission: .open)
        XCTAssertThrowsError(try response.validate(expectedBase: 0, expectedWalSeq: 2))
        let closed = HandoffSegmentsResponse(baseMseq: 0, appliedMseq: 1,
                                             walSeq: 2, admission: .closed)
        XCTAssertNoThrow(try closed.validate(expectedBase: 0, expectedWalSeq: 2))
    }

    func testFenceResponseValidation() throws {
        let token = String(repeating: "0f", count: 16)
        let response = HandoffFenceResponse(
            fence: Fence(owner: "remote", generation: 1, walSeq: 9),
            reclaimToken: token)
        XCTAssertNoThrow(try response.validate(expectedGeneration: 0, walSeq: 9))
        XCTAssertThrowsError(try response.validate(expectedGeneration: 1, walSeq: 9))
        let badToken = HandoffFenceResponse(
            fence: Fence(owner: "remote", generation: 1, walSeq: 9),
            reclaimToken: "not-hex")
        XCTAssertThrowsError(try badToken.validate(expectedGeneration: 0, walSeq: 9))
    }

    // MARK: - Errors (§6)

    func testErrorEnvelopeDecodesAllSchemaFields() throws {
        let json = Data("""
        {"error":{"code":"segments_gap","message":"missing mseq",\
        "applied_mseq":2,"expected_mseq":3,"generation":1}}
        """.utf8)
        let envelope = try JSONDecoder().decode(HandoffErrorEnvelope.self, from: json)
        XCTAssertEqual(envelope.error.code, "segments_gap")
        XCTAssertEqual(envelope.error.appliedMseq, 2)
        XCTAssertEqual(envelope.error.expectedMseq, 3)
        XCTAssertEqual(envelope.error.generation, 1)
    }

    func testRetryClassification() {
        XCTAssertTrue(HandoffError.transport("x").isRetryable)
        XCTAssertTrue(HandoffError.internalFailure("HTTP 503").isRetryable)
        XCTAssertFalse(HandoffError.segmentsGap.isRetryable)
        XCTAssertFalse(HandoffError.unauthorized.isRetryable)
        let policy = HandoffRetryPolicy(maximumAttempts: 4, baseDelay: 0.1,
                                        maximumDelay: 0.3)
        XCTAssertEqual(policy.delay(beforeAttempt: 1), 0)
        XCTAssertEqual(policy.delay(beforeAttempt: 2), 0.1, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(beforeAttempt: 3), 0.2, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(beforeAttempt: 4), 0.3, accuracy: 0.0001)
    }

    // MARK: - TLS and credentials (§1/§6)

    func testClientRejectsCleartextEndpoint() throws {
        let transport = CountingHandoffTransport()
        let endpoint = try XCTUnwrap(URL(string: "http://remote.invalid"))
        XCTAssertThrowsError(try HandoffClient(
            configuration: HandoffClientConfiguration(endpoint: endpoint),
            transport: transport,
            credentialProvider: HandoffTestCredentials.provider())) { error in
            XCTAssertEqual(error as? HandoffError, .cleartextEndpoint)
        }
    }

    func testClientRejectsURLCredentialsQueryAndFragment() throws {
        let transport = CountingHandoffTransport()
        var credentialComponents = try XCTUnwrap(
            URLComponents(string: "https://remote.invalid/base"))
        credentialComponents.user = "user"
        credentialComponents.password = "password"
        let credentialEndpoint = try XCTUnwrap(credentialComponents.url)
        let queryEndpoint = try XCTUnwrap(
            URL(string: "https://remote.invalid/base?access_token=secret"))
        let fragmentEndpoint = try XCTUnwrap(
            URL(string: "https://remote.invalid/base#secret"))
        let endpoints = [credentialEndpoint, queryEndpoint, fragmentEndpoint]
        for endpoint in endpoints {
            XCTAssertThrowsError(try HandoffClient(
                configuration: HandoffClientConfiguration(endpoint: endpoint),
                transport: transport,
                credentialProvider: HandoffTestCredentials.provider())) { error in
                guard case HandoffError.invalidEndpoint = error else {
                    return XCTFail(
                        "expected invalidEndpoint for \(endpoint.absoluteString), got \(error)")
                }
            }
        }
        XCTAssertEqual(transport.callCount, 0,
                       "an invalid endpoint must be refused before any request")
    }

    func testClientAcceptsHTTPSBasePathWithoutCredentials() throws {
        let transport = CountingHandoffTransport()
        let endpoint = try XCTUnwrap(URL(string: "https://remote.invalid/team/dsh"))
        let client = try HandoffClient(
            configuration: HandoffClientConfiguration(endpoint: endpoint),
            transport: transport,
            credentialProvider: HandoffTestCredentials.provider())
        XCTAssertEqual(client.configuration.endpoint.path, "/team/dsh")
        XCTAssertEqual(client.configuration.endpoint.absoluteString,
                       "https://remote.invalid/team/dsh")
    }

    func testClientWithoutBearerCredentialNeverCallsTransport() async throws {
        let transport = CountingHandoffTransport()
        let endpoint = try XCTUnwrap(URL(string: "https://remote.invalid"))
        let client = try HandoffClient(
            configuration: HandoffClientConfiguration(endpoint: endpoint),
            transport: transport,
            credentialProvider: StaticCredentialProvider([:]))
        do {
            _ = try await client.fence(expectedGeneration: 0, walSeq: 0)
            XCTFail("a missing Bearer credential must fail")
        } catch {
            XCTAssertEqual(error as? HandoffError, .unauthorized)
        }
        XCTAssertEqual(transport.callCount, 0)
    }

    func testClientRejectsMalformedReclaimTokenWithoutTransport() async throws {
        let transport = CountingHandoffTransport()
        let client = try makeHandoffClient(transport: transport)
        do {
            _ = try await client.reclaim(token: "short")
            XCTFail("a malformed reclaim token must fail")
        } catch {
            XCTAssertEqual(error as? HandoffError, .unauthorized)
        }
        XCTAssertEqual(transport.callCount, 0)
    }
}

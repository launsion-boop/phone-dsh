// SPDX-License-Identifier: MIT
// ModelGateway behaviour tests against a Network.framework HTTP/1.1 upstream:
// credential injection, streaming, response-log replay, retries and metrics.

import Foundation
import XCTest
import PhoneDSHGateway
import PhoneDSHAgentCore

final class ModelGatewayTests: XCTestCase {
    // MARK: - Fixtures

    private func makeGateway(server: MockUpstreamServer,
                             clock: ManualGatewayClock = ManualGatewayClock(),
                             allowedHosts: Set<String>? = nil,
                             credentialValue: String? = "test-credential",
                             providers overrideProviders: (any CredentialProvider)? = nil,
                             quota: Int = 1_000_000,
                             receipts: GatewayReceiptRecorder? = nil,
                             responseLog overrideLog: (any ResponseLogging)? = nil) throws
        -> (gateway: ModelGateway, log: ResponseLog, root: URL) {
        let root = try makeTemporaryDirectory()
        let log = try ResponseLog(root: root, quotaBytes: quota)
        let activeLog: any ResponseLogging
        if let overrideLog {
            activeLog = overrideLog
        } else {
            activeLog = log
        }
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: allowedHosts ?? ["127.0.0.1:\(server.port)"],
            // The same helper the probe app and scenario runner use.
            replaySafeModelEndpoints: ModelGatewayConfiguration.standardModelEndpoints(
                baseURL: URL(string: "http://127.0.0.1:\(server.port)")!),
            responseLogQuotaBytes: quota,
            responseLogHeaderNames: ["accept", "content-type"],
            backoff: ModelGatewayBackoffPolicy(initialDelay: 1,
                                               multiplier: 2,
                                               maximumDelay: 60,
                                               jitterFraction: 0,
                                               maximumAttempts: 5),
            upstreamRequestTimeout: 5)
        let providers: any CredentialProvider = overrideProviders ?? credentialValue.map {
            makeBearerProvider(host: "127.0.0.1", value: $0)
        } ?? StaticCredentialProvider([:])
        let gateway = ModelGateway(configuration: configuration,
                                   credentialProvider: providers,
                                   responseLog: activeLog,
                                   responseOutcomeHandler: receipts.map { recorder in
                                       { recorder.record($0) }
                                   },
                                   clock: clock)
        addTeardownBlock {
            await gateway.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        return (gateway, log, root)
    }

    private func makeRequest(port: UInt16,
                             path: String = "/v1/chat/completions",
                             method: String = "POST",
                             headers: [String: String]? = nil,
                             body: Data = Data(#"{"model":"m","messages":[]}"#.utf8)) -> GatewayRequest {
        GatewayRequest(method: method,
                       url: URL(string: "http://127.0.0.1:\(port)\(path)")!,
                       headers: headers ?? ["content-type": "application/json",
                                            "accept": "text/event-stream"],
                       body: body)
    }

    private func responseKey(_ request: GatewayRequest,
                             allowList: Set<String> = ["accept", "content-type"]) -> String {
        ResponseLog.cacheKey(method: request.method,
                             url: request.url,
                             headers: request.headers,
                             body: request.body,
                             headerAllowList: allowList)
    }

    private func waitForReceipts(_ recorder: GatewayReceiptRecorder,
                                 count: Int,
                                 timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while recorder.receipts.count < count {
            if Date() >= deadline { throw GatewayTestError.timedOut }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func commitResponse(_ log: ResponseLog,
                                key: String,
                                status: Int = 200,
                                headers: [String: String] = ["content-type": "text/event-stream"],
                                body: Data) async throws {
        let requestID = UUID().uuidString
        try await log.begin(requestID: requestID, key: key, status: status, headers: headers)
        try await log.append(ResponseLogEntry(requestID: requestID,
                                              sequence: 0,
                                              body: body,
                                              isFinal: true))
        _ = try await log.finish(requestID: requestID)
    }

    // MARK: - Credentials and request shaping

    func testCredentialInjectedAndWorkerAuthorizationDropped() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: ["content-type": "application/json"], body: Data("{}".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)

        let request = makeRequest(port: server.port, headers: [
            "authorization": "Bearer worker-value",
            "x-pdsh-upstream-authorization": "Bearer worker-value-2",
            "x-pdsh-target-url": "http://example.invalid/other",
            "x-api-key": "keep-value",
            "content-type": "application/json",
        ])
        let response = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertEqual(response.status, 200)

        let observed = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(observed.headers["authorization"], "Bearer test-credential")
        XCTAssertEqual(observed.headers["x-api-key"], "keep-value")
        XCTAssertNil(observed.headers["x-pdsh-upstream-authorization"])
        XCTAssertNil(observed.headers["x-pdsh-target-url"])
        XCTAssertEqual(gateway.metrics().workerCredentialsDropped, 1,
                       "the dropped Worker credential is reported, not silent")
    }

    func testWorkerCookieDoesNotReachUpstreamWithoutHostCookieCredential() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let provider = StaticCredentialProvider([
            CredentialScope(service: "127.0.0.1"): .none,
        ])
        let (gateway, _, _) = try makeGateway(server: server, providers: provider)

        let request = makeRequest(port: server.port, headers: [
            "cookie": "xl_launch_token=worker-channel-secret",
            "referer": "http://127.0.0.1/?token=worker-channel-secret",
            "content-type": "application/json",
        ])
        _ = try await collectGatewayResponse(gateway.handle(request))

        let observed = try XCTUnwrap(server.requests.first)
        XCTAssertNil(observed.headers["cookie"], "a Worker Cookie header must be dropped")
        XCTAssertNil(observed.headers["referer"], "a Worker Referer must be dropped")
    }

    func testHostCookieCredentialIsAppliedAfterWorkerCookieIsDropped() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let provider = StaticCredentialProvider([
            CredentialScope(service: "127.0.0.1"): Credential(
                kind: .apiKey(header: "Cookie"), value: "host-session=authorized"),
        ])
        let (gateway, _, _) = try makeGateway(server: server, providers: provider)

        let request = makeRequest(port: server.port, headers: [
            "Cookie": "xl_launch_token=worker-channel-secret",
            "content-type": "application/json",
        ])
        _ = try await collectGatewayResponse(gateway.handle(request))

        let observed = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(observed.headers["cookie"], "host-session=authorized",
                       "the host's explicit credential must remain authoritative")
    }

    func testUpstreamCookiesAreNotReturnedOrStoredForReplay() async throws {
        let upstreamCookie = "upstream-session-\(UUID().uuidString)"
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [
                "content-type": "application/json",
                "set-cookie": "session=\(upstreamCookie); Path=/",
                "set-cookie2": "legacy=\(upstreamCookie)",
                "clear-site-data": "\"cookies\", \"storage\", \"cache\"",
            ], body: Data(#"{"answer":1}"#.utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, root) = try makeGateway(server: server)
        gateway.openReplayWindow()
        let request = makeRequest(port: server.port)

        let live = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertNil(live.headers["set-cookie"])
        XCTAssertNil(live.headers["set-cookie2"])
        XCTAssertNil(live.headers["clear-site-data"])
        let replayed = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertNil(replayed.headers["set-cookie"])
        XCTAssertNil(replayed.headers["set-cookie2"])
        XCTAssertNil(replayed.headers["clear-site-data"])
        XCTAssertEqual(server.requestCount, 1, "the second response must come from the log")
        XCTAssertEqual(try filesContaining(upstreamCookie, under: root), [],
                       "upstream cookie values must not enter response-log files")
        XCTAssertEqual(try filesContaining("clear-site-data", under: root), [],
                       "site-data directives must not enter response-log files")
    }

    func testMethodPathAndBodyAreForwarded() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)

        let body = Data(#"{"model":"m","stream":true}"#.utf8)
        let request = makeRequest(port: server.port, path: "/v1/responses", method: "PUT", body: body)
        _ = try await collectGatewayResponse(gateway.handle(request))

        let observed = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(observed.method, "PUT")
        XCTAssertEqual(observed.path, "/v1/responses")
        XCTAssertEqual(observed.body, body)
        XCTAssertEqual(observed.headers["content-length"], String(body.count))
        XCTAssertEqual(observed.headers["host"], "127.0.0.1:\(server.port)")
    }

    func testDisallowedHostIsRejectedWithoutContactingUpstream() async throws {
        let server = try MockUpstreamServer { _ in .full(status: 200, headers: [:], body: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server,
                                              allowedHosts: ["api.example.invalid"])

        let error = try await expectGatewayFailure(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(error as? ModelGatewayError, .hostNotAllowed("127.0.0.1"))
        XCTAssertEqual(server.requestCount, 0)
    }

    func testEmptyAllowListRejectsEveryHost() async throws {
        let server = try MockUpstreamServer { _ in .full(status: 200, headers: [:], body: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server, allowedHosts: [])

        let error = try await expectGatewayFailure(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(error as? ModelGatewayError, .hostNotAllowed("127.0.0.1"))
        XCTAssertEqual(server.requestCount, 0)
    }

    func testMissingCredentialFailsBeforeUpstreamContact() async throws {
        let server = try MockUpstreamServer { _ in .full(status: 200, headers: [:], body: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server, credentialValue: nil)

        let error = try await expectGatewayFailure(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(error as? ModelGatewayError, .credentialUnavailable)
        XCTAssertEqual(server.requestCount, 0)
    }

    /// spec/exec-bridge-v1 §6 relays a harness `Authorization` as
    /// `X-PDSH-Upstream-Authorization`. PLAN's security decision makes the host
    /// provider authoritative, so that value must not be promoted when the
    /// provider has no credential; the failure is loud and the drop counted.
    func testRelayedUpstreamAuthorizationCannotSubstituteForHostCredential() async throws {
        let server = try MockUpstreamServer { _ in .full(status: 200, headers: [:], body: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server, credentialValue: nil)

        let request = makeRequest(port: server.port, headers: [
            "authorization": "Bearer worker-value",
            "x-pdsh-upstream-authorization": "Bearer worker-value-2",
            "content-type": "application/json",
        ])
        let error = try await expectGatewayFailure(gateway.handle(request))
        XCTAssertEqual(error as? ModelGatewayError, .credentialUnavailable)
        XCTAssertEqual(server.requestCount, 0, "a Worker credential must never reach the upstream")
        XCTAssertEqual(gateway.metrics().workerCredentialsDropped, 1)
    }

    // MARK: - Streaming

    func testSSEChunksAreStreamedInOrderWithoutBuffering() async throws {
        let chunks = [
            Data("data: one\n\n".utf8),
            Data("data: two\n\n".utf8),
            Data("data: three\n\n".utf8),
            Data("data: [DONE]\n\n".utf8),
        ]
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200,
                     headers: ["content-type": "text/event-stream"],
                     chunks: chunks,
                     delay: 0.1)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)

        let start = Date()
        var arrivalTimes: [Date] = []
        var body = Data()
        var status: Int?
        for try await chunk in gateway.handle(makeRequest(port: server.port)) {
            arrivalTimes.append(Date())
            if let chunkStatus = chunk.status {
                status = chunkStatus
            }
            body.append(chunk.body)
        }

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, chunks.reduce(Data(), +))
        let first = try XCTUnwrap(arrivalTimes.first)
        let last = try XCTUnwrap(arrivalTimes.last)
        // The head is forwarded before the upstream finishes sending chunks;
        // the last four arrive about 300 ms apart from the head.
        XCTAssertLessThan(first.timeIntervalSince(start), 0.2)
        XCTAssertGreaterThanOrEqual(last.timeIntervalSince(first), 0.2)
        XCTAssertGreaterThanOrEqual(arrivalTimes.count, 3)
    }

    // MARK: - Response log replay

    func testReplayWindowOpenServesFromLogWithoutUpstreamContact() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: Data(#"{"answer":1}"#.utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)
        gateway.openReplayWindow()

        let request = makeRequest(port: server.port)
        let live = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertNil(live.headers["x-pdsh-replayed"])

        let replayed = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(replayed.status, 200)
        XCTAssertEqual(replayed.body, live.body)
        XCTAssertEqual(replayed.headers["x-pdsh-replayed"], "1")
        XCTAssertEqual(replayed.headers["cache-control"], "no-store")
        XCTAssertEqual(gateway.metrics().replayHits, 1)
    }

    func testResumeServesTheLoggedSuffixWithoutContactingTheUpstream() async throws {
        // A downstream consumer that stopped pulling (a suspended WKWebView
        // page) asks the gateway to resume its body at the byte offset it had
        // already delivered. The host owns the complete body, so the suffix
        // comes from the response log and the upstream is never contacted
        // twice. Before the fix the gateway ignored the resume header and
        // re-fetched the whole body from the upstream.
        let body = Data((0..<4_000).map { UInt8($0 % 251) })
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/event-stream"],
                  body: body)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, log, _) = try makeGateway(server: server)

        let original = makeRequest(port: server.port)
        let recorded = try await collectGatewayResponse(gateway.handle(original))
        XCTAssertEqual(recorded.body, body)
        let committed = await log.replay(key: responseKey(original))
        XCTAssertNotNil(committed)
        XCTAssertEqual(server.requestCount, 1)

        var resume = original
        resume.headers[GatewayRequest.resumeFromHeader] = "1500"
        let resumed = try await collectGatewayResponse(gateway.handle(resume))
        XCTAssertEqual(resumed.status, 200)
        XCTAssertEqual(resumed.headers[GatewayRequest.resumedHeader], "1")
        XCTAssertEqual(resumed.body, Data(body.dropFirst(1_500)))
        XCTAssertEqual(server.requestCount, 1, "a resume must be served from the response log")
        let metrics = gateway.metrics()
        XCTAssertEqual(metrics.resumeHits, 1)
        XCTAssertEqual(metrics.resumeBytes, body.count - 1_500)
        XCTAssertEqual(metrics.resumeMisses, 0)
    }

    func testResumeForACommittedResponseWaitsForTheLog() async throws {
        // A resume can arrive while the gateway is still recording the
        // upstream body (the consumer aborted first). The request waits for
        // the commit instead of failing or re-contacting the upstream.
        let body = Data("0123456789".utf8)
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200,
                     headers: ["content-type": "text/event-stream"],
                     chunks: [Data(body.prefix(4)), Data(body.dropFirst(4))],
                     delay: 0.3)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, log, _) = try makeGateway(server: server)
        let original = makeRequest(port: server.port)
        // Read only the first body chunk, then abandon the stream: the
        // gateway keeps recording the rest by design.
        var iterator = gateway.handle(original).makeAsyncIterator()
        _ = try await iterator.next() // head
        _ = try await iterator.next() // first body chunk
        // The recording is still pending at this instant.
        let pending = await log.replay(key: responseKey(original))
        XCTAssertNil(pending)

        var resume = original
        resume.headers[GatewayRequest.resumeFromHeader] = "4"
        let resumed = try await collectGatewayResponse(gateway.handle(resume), timeout: 5)
        XCTAssertEqual(resumed.headers[GatewayRequest.resumedHeader], "1")
        XCTAssertEqual(resumed.body, Data(body.dropFirst(4)))
        XCTAssertEqual(server.requestCount, 1)
    }

    func testDownstreamCancellationStillCommitsTheBodyForAResume() async throws {
        // The Worker's fetch is abandoned mid-body (a suspended page). The
        // gateway must keep receiving and committing the upstream body, so the
        // later resume can serve the suffix from disk.
        let chunks = [Data("first chunk".utf8), Data("second chunk".utf8), Data("[DONE]".utf8)]
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200, headers: ["content-type": "text/event-stream"],
                     chunks: chunks, delay: 0.2)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, log, _) = try makeGateway(server: server)
        let original = makeRequest(port: server.port)
        var stream: AsyncThrowingStream<GatewayResponseChunk, Error>? = gateway.handle(original)
        var iterator = stream?.makeAsyncIterator()
        _ = try await iterator?.next() // head
        _ = try await iterator?.next() // first body chunk
        iterator = nil
        stream = nil // abandon the downstream stream; the upstream keeps running
        let key = responseKey(original)
        var committed: ResponseLogReplay?
        let deadline = Date().addingTimeInterval(5)
        repeat {
            committed = await log.replay(key: key)
            if committed != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        let replay = try XCTUnwrap(committed)
        XCTAssertEqual(replay.body, chunks.reduce(Data(), +))

        var resume = original
        resume.headers[GatewayRequest.resumeFromHeader] = "11"
        let resumed = try await collectGatewayResponse(gateway.handle(resume))
        XCTAssertEqual(resumed.body, Data(replay.body.dropFirst(11)))
        XCTAssertEqual(server.requestCount, 1)
    }

    func testReplayWindowClosedAlwaysContactsUpstream() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            let attempt = counter.next()
            return .full(status: 200, headers: [:], body: Data("body-\(attempt)".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)

        let request = makeRequest(port: server.port)
        let first = try await collectGatewayResponse(gateway.handle(request))
        let second = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertEqual(first.body, Data("body-1".utf8))
        XCTAssertEqual(second.body, Data("body-2".utf8))
        XCTAssertNil(second.headers["x-pdsh-replayed"])
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(gateway.metrics().replayHits, 0)
    }

    /// Malformed, negative, empty and overflowing resume offsets are never a
    /// fresh request. In a closed window the old two-state parser silently
    /// contacted the upstream; in an open window it replayed the committed
    /// body and counted a delivery. Both are rejected before either happens.
    func testInvalidResumeHeaderIsRejectedWithoutUpstreamOrDelivery() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/event-stream"],
                  body: Data("upstream-must-not-run".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let recorder = GatewayReceiptRecorder()
        let (gateway, log, _) = try makeGateway(server: server, receipts: recorder)
        let request = makeRequest(port: server.port)
        let key = responseKey(request)
        try await commitResponse(log, key: key, body: Data("committed-body".utf8))
        let beforeResult = await log.receipt(key: key)
        let before = try XCTUnwrap(beforeResult)
        XCTAssertEqual(before.deliveryCount, 0)

        let invalidValues = ["", "abc", "-1", "999999999999999999999999999999"]
        for replayOpen in [false, true] {
            gateway.setReplayWindow(open: replayOpen)
            for value in invalidValues {
                var invalid = request
                invalid.headers[GatewayRequest.resumeFromHeader] = value
                let error = try await expectGatewayFailure(gateway.handle(invalid), timeout: 2)
                guard let gatewayError = error as? ModelGatewayError else {
                    XCTFail("expected a structured gateway error for \(value.debugDescription)")
                    continue
                }
                guard case .invalidRequest = gatewayError else {
                    XCTFail("invalid resume header must be invalidRequest, got \(gatewayError)")
                    continue
                }
                XCTAssertTrue(recorder.receipts.isEmpty)
                XCTAssertEqual(server.requestCount, 0,
                               "an invalid resume must be rejected before an upstream attempt")
                let afterResult = await log.receipt(key: key)
                let after = try XCTUnwrap(afterResult)
                XCTAssertEqual(after.lastUsed, before.lastUsed)
                XCTAssertEqual(after.deliveryCount, before.deliveryCount)
            }

            var duplicate = request
            duplicate.headers["X-PDSH-Resume-From"] = "4"
            duplicate.headers[GatewayRequest.resumeFromHeader] = "4"
            let duplicateError = try await expectGatewayFailure(gateway.handle(duplicate), timeout: 2)
            guard let duplicateGatewayError = duplicateError as? ModelGatewayError else {
                XCTFail("expected a structured error for a duplicate logical header")
                continue
            }
            guard case .invalidRequest = duplicateGatewayError else {
                XCTFail("two differently-cased resume headers must be rejected conservatively")
                continue
            }
            XCTAssertTrue(recorder.receipts.isEmpty)
            XCTAssertEqual(server.requestCount, 0)
        }
        XCTAssertEqual(gateway.metrics().replayHits, 0)
        XCTAssertEqual(gateway.metrics().resumeHits, 0)
    }

    /// A valid but past-the-end offset is rejected by the response log before
    /// it counts a delivery; a valid in-range offset still serves the suffix.
    func testOutOfRangeResumeDoesNotCountADeliveryAndValidOffsetStillWorks() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/event-stream"],
                  body: Data("upstream-must-not-run".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let recorder = GatewayReceiptRecorder()
        let (gateway, log, _) = try makeGateway(server: server, receipts: recorder)
        let request = makeRequest(port: server.port)
        let key = responseKey(request)
        let body = Data("0123456789".utf8)
        try await commitResponse(log, key: key, body: body)
        let beforeResult = await log.receipt(key: key)
        let before = try XCTUnwrap(beforeResult)

        var outOfRange = request
        outOfRange.headers[GatewayRequest.resumeFromHeader] = "11"
        let error = try await expectGatewayFailure(gateway.handle(outOfRange), timeout: 2)
        guard let gatewayError = error as? ModelGatewayError,
              case .invalidRequest = gatewayError else {
            XCTFail("an offset past the committed body must be invalidRequest")
            return
        }
        let afterRejectionResult = await log.receipt(key: key)
        let afterRejection = try XCTUnwrap(afterRejectionResult)
        XCTAssertEqual(afterRejection.lastUsed, before.lastUsed)
        XCTAssertEqual(afterRejection.deliveryCount, before.deliveryCount)
        XCTAssertTrue(recorder.receipts.isEmpty)
        XCTAssertEqual(server.requestCount, 0)

        var valid = request
        valid.headers[GatewayRequest.resumeFromHeader] = "4"
        let resumed = try await collectGatewayResponse(gateway.handle(valid), timeout: 2)
        XCTAssertEqual(resumed.body, Data(body.dropFirst(4)))
        XCTAssertEqual(resumed.headers[GatewayRequest.resumedHeader], "1")
        let afterAcceptanceResult = await log.receipt(key: key)
        let afterAcceptance = try XCTUnwrap(afterAcceptanceResult)
        XCTAssertEqual(afterAcceptance.deliveryCount, 1)
        XCTAssertGreaterThan(afterAcceptance.lastUsed, 0)
        XCTAssertEqual(server.requestCount, 0,
                       "the valid resume is served from the log, not the upstream")
    }

    func testReplayDistinguishesJSONBodyOrder() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("response-\(counter.next())".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)
        gateway.openReplayWindow()

        let first = makeRequest(port: server.port,
                                body: Data(#"{"b":2,"a":1}"#.utf8))
        let equivalent = makeRequest(port: server.port,
                                     body: Data(#"{ "a" : 1, "b" : 2 }"#.utf8))
        _ = try await collectGatewayResponse(gateway.handle(first))
        let replayed = try await collectGatewayResponse(gateway.handle(equivalent))
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(replayed.headers["x-pdsh-replayed"], "1")
        XCTAssertEqual(replayed.body, Data("response-1".utf8))
    }

    func testDownstreamCancellationKeepsUpstreamAndRecordsFullResponse() async throws {
        let chunks = [
            Data("one".utf8),
            Data("two".utf8),
            Data("three".utf8),
            Data("four".utf8),
        ]
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200,
                     headers: ["content-type": "text/plain"],
                     chunks: chunks,
                     delay: 0.1)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, log, _) = try makeGateway(server: server)

        let request = makeRequest(port: server.port, method: "GET", body: Data())
        let consumer = Task {
            var seen = 0
            for try await _ in gateway.handle(request) {
                seen += 1
                if seen == 2 {
                    return
                }
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        consumer.cancel()
        _ = try? await consumer.value

        let key = responseKey(request)
        var recorded: ResponseLogReplay?
        for _ in 0..<60 {
            recorded = await log.replay(key: key)
            if recorded != nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let replay = try XCTUnwrap(recorded)
        XCTAssertEqual(replay.body, chunks.reduce(Data(), +))
        XCTAssertEqual(server.requestCount, 1)

        gateway.openReplayWindow()
        let replayed = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertEqual(replayed.body, chunks.reduce(Data(), +))
        XCTAssertEqual(replayed.headers["x-pdsh-replayed"], "1")
        XCTAssertEqual(server.requestCount, 1)
    }

    // MARK: - Bounded terminal outcome receipts (G2-FIX-73/113)

    func testReplayHitEmitsOneReplayedReceipt() async throws {
        let body = Data(#"{"answer":1}"#.utf8)
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: body)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let recorder = GatewayReceiptRecorder()
        let (gateway, _, _) = try makeGateway(server: server, receipts: recorder)
        gateway.openReplayWindow()

        let request = makeRequest(port: server.port)
        _ = try await collectGatewayResponse(gateway.handle(request))
        _ = try await collectGatewayResponse(gateway.handle(request))

        try await waitForReceipts(recorder, count: 2)
        let receipts = recorder.receipts
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts[0].disposition, .committed)
        XCTAssertEqual(receipts[0].key, responseKey(request))
        XCTAssertEqual(receipts[0].status, 200)
        XCTAssertEqual(receipts[0].bodyBytes, body.count)
        XCTAssertEqual(receipts[1].disposition, .replayed)
        XCTAssertEqual(receipts[1].key, responseKey(request))
        XCTAssertEqual(receipts[1].status, 200)
        XCTAssertEqual(receipts[1].bodyBytes, body.count)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testResumeHitEmitsOneResumedReceipt() async throws {
        let body = Data((0..<2_000).map { UInt8($0 % 251) })
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "text/event-stream"],
                  body: body)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let recorder = GatewayReceiptRecorder()
        let (gateway, _, _) = try makeGateway(server: server, receipts: recorder)

        let original = makeRequest(port: server.port)
        _ = try await collectGatewayResponse(gateway.handle(original))
        var resume = original
        resume.headers[GatewayRequest.resumeFromHeader] = "700"
        let resumed = try await collectGatewayResponse(gateway.handle(resume))
        XCTAssertEqual(resumed.body, Data(body.dropFirst(700)))

        try await waitForReceipts(recorder, count: 2)
        let receipts = recorder.receipts
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(receipts[0].disposition, .committed)
        XCTAssertEqual(receipts[1].disposition, .resumed)
        XCTAssertEqual(receipts[1].key, responseKey(original))
        XCTAssertEqual(receipts[1].status, 200)
        XCTAssertEqual(receipts[1].bodyBytes, body.count)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testDownstreamCancellationEmitsOneCommittedReceipt() async throws {
        let chunks = [Data("one".utf8), Data("two".utf8), Data("three".utf8)]
        let server = try MockUpstreamServer { _ in
            .chunked(status: 200,
                     headers: ["content-type": "text/event-stream"],
                     chunks: chunks,
                     delay: 0.2)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let recorder = GatewayReceiptRecorder()
        let (gateway, _, _) = try makeGateway(server: server, receipts: recorder)

        let request = makeRequest(port: server.port)
        var stream: AsyncThrowingStream<GatewayResponseChunk, Error>? = gateway.handle(request)
        var iterator = stream?.makeAsyncIterator()
        _ = try await iterator?.next() // head
        _ = try await iterator?.next() // first body chunk
        iterator = nil
        stream = nil // abandon the downstream stream; the upstream keeps running

        try await waitForReceipts(recorder, count: 1)
        let receipts = recorder.receipts
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].disposition, .committed)
        XCTAssertEqual(receipts[0].key, responseKey(request))
        XCTAssertEqual(receipts[0].status, 200)
        XCTAssertEqual(receipts[0].bodyBytes, chunks.reduce(0) { $0 + $1.count })
        XCTAssertEqual(server.requestCount, 1)

        // Give a duplicate-emitting bug a chance to surface.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.receipts.count, 1,
                       "the cancelled downstream still commits exactly one outcome")
    }

    /// `finish` writes the entry before evicting it. A single response larger
    /// than the whole quota is therefore delivered to the caller but not
    /// retained, and the host must not publish a `committed` terminal outcome
    /// for a key that cannot be replayed.
    func testDroppedOversizedCommitEmitsNoReceipt() async throws {
        let body = Data(repeating: 0x61, count: 1_000)
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: body)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let recorder = GatewayReceiptRecorder()
        let (gateway, log, _) = try makeGateway(server: server,
                                                quota: 100,
                                                receipts: recorder)
        let request = makeRequest(port: server.port)

        let response = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, body)
        let replay = await log.replay(key: responseKey(request))
        XCTAssertNil(replay,
                     "the oversized commit was evicted and is not replayable")

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(recorder.receipts.isEmpty,
                      "a dropped commit must not be reported as committed")
        XCTAssertEqual(server.requestCount, 1)
    }

    /// The old gateway called `finish` and then `receipt(key:)` as two actor
    /// hops; another finish could evict the entry in between and the fallback
    /// still emitted a `committed` receipt for a missing key. The scripted log
    /// returns nil from the atomic finish and a (stale) receipt from the
    /// separate lookup, so this regression fails if the gateway takes that
    /// second hop again.
    func testConcurrentFinishEvictionEmitsNoReceipt() async throws {
        let body = Data("raced".utf8)
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: body)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let recorder = GatewayReceiptRecorder()
        let losingLog = LosingRaceResponseLog()
        let (gateway, _, _) = try makeGateway(server: server,
                                              receipts: recorder,
                                              responseLog: losingLog)
        let request = makeRequest(port: server.port)

        let response = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, body)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(recorder.receipts.isEmpty,
                      "a commit evicted by a concurrent finish is not a terminal outcome")
        let lookups = await losingLog.receiptLookupCount()
        XCTAssertEqual(lookups, 0,
                       "the gateway must rely on the atomic finish result, not a racing lookup")
        XCTAssertEqual(server.requestCount, 1)
    }

    /// A successful `finish` receipt is the whole commit contract. A stale or
    /// concurrent `receipt(key:)` lookup must not be consulted at all; the
    /// gateway emits exactly the receipt returned by `finish`.
    func testCommittedReceiptComesFromFinishWithoutASecondLookup() async throws {
        let body = Data("raced".utf8)
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json"],
                  body: body)
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let recorder = GatewayReceiptRecorder()
        let commitOnlyLog = CommitReceiptResponseLog()
        let (gateway, _, _) = try makeGateway(server: server,
                                              receipts: recorder,
                                              responseLog: commitOnlyLog)
        let request = makeRequest(port: server.port)

        let response = try await collectGatewayResponse(gateway.handle(request))
        XCTAssertEqual(response.body, body)
        try await waitForReceipts(recorder, count: 1)
        XCTAssertEqual(recorder.receipts.map(\.disposition), [.committed])
        let committed = try XCTUnwrap(recorder.receipts.first)
        XCTAssertEqual(committed.bodyBytes, body.count)
        let lookups = await commitOnlyLog.receiptLookupCount()
        XCTAssertEqual(lookups, 0,
                       "a retained finish receipt must not be re-queried")
        XCTAssertEqual(server.requestCount, 1)
    }

    func testTruncatedStreamIsNotRecordedAndNotRetried() async throws {
        let partial = Data(("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n"
            + "content-length: 100\r\nconnection: close\r\n\r\ndata: hello\n\n").utf8)
        let server = try MockUpstreamServer { _ in .abort(partial: partial) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, log, _) = try makeGateway(server: server)

        let request = makeRequest(port: server.port)
        let error = try await expectGatewayFailure(gateway.handle(request))
        XCTAssertTrue(error is ModelGatewayError)
        XCTAssertEqual(server.requestCount, 1)
        let key = responseKey(request)
        let replay = await log.replay(key: key)
        XCTAssertNil(replay)
    }

    // MARK: - Retries

    func testRetryOn500Then200WithBackoffDelay() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            counter.next() == 1
                ? .full(status: 500, headers: [:], body: Data("err".utf8))
                : .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let clock = ManualGatewayClock()
        let (gateway, _, _) = try makeGateway(server: server, clock: clock)

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("ok".utf8))
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(clock.sleeps, [1])
        XCTAssertEqual(gateway.metrics().retries, 1)
    }

    func testRetryOn429HonoursRetryAfterSeconds() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            counter.next() == 1
                ? .full(status: 429, headers: ["retry-after": "2"], body: Data("slow".utf8))
                : .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let clock = ManualGatewayClock()
        let (gateway, _, _) = try makeGateway(server: server, clock: clock)

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(clock.sleeps, [2])
    }

    func testRetryAfterHTTPDateUsesInjectedClock() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            if counter.next() == 1 {
                return .full(status: 429,
                             headers: ["retry-after": httpDate(now.addingTimeInterval(4))],
                             body: Data())
            }
            return .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let clock = ManualGatewayClock(now: now)
        let (gateway, _, _) = try makeGateway(server: server, clock: clock)

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(clock.sleeps.count, 1)
        XCTAssertEqual(clock.sleeps.first ?? 0, 4, accuracy: 0.5)
    }

    func testExponentialBackoffStopsAtFiveAttempts() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 500, headers: [:], body: Data("err".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let clock = ManualGatewayClock()
        let (gateway, _, _) = try makeGateway(server: server, clock: clock)

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(response.body, Data("err".utf8))
        XCTAssertEqual(server.requestCount, 5)
        XCTAssertEqual(clock.sleeps, [1, 2, 4, 8])
        XCTAssertEqual(gateway.metrics().retries, 4)
    }

    func testNonRetryable4xxIsForwardedWithoutRetry() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            counter.next() == 1
                ? .full(status: 400, headers: [:], body: Data("bad".utf8))
                : .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let clock = ManualGatewayClock()
        let (gateway, _, _) = try makeGateway(server: server, clock: clock)

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(response.body, Data("bad".utf8))
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertTrue(clock.sleeps.isEmpty)
        XCTAssertEqual(gateway.metrics().retries, 0)
    }

    func testTransportErrorBeforeFirstByteIsRetried() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            counter.next() == 1
                ? .abort(partial: Data())
                : .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let clock = ManualGatewayClock()
        let (gateway, _, _) = try makeGateway(server: server, clock: clock)

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(clock.sleeps, [1])
    }

    func testBusinessPostIsNotRetriedAfterUpstreamAcceptedThenDisconnected() async throws {
        let submittedBody = Data(#"{"operation":"charge","amount":5}"#.utf8)
        let server = try MockUpstreamServer { _ in .abort(partial: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let clock = ManualGatewayClock()
        let (gateway, _, _) = try makeGateway(server: server, clock: clock)

        let error = try await expectGatewayFailure(gateway.handle(
            makeRequest(port: server.port, path: "/v1/payments", body: submittedBody)))
        XCTAssertTrue(error is ModelGatewayError)
        XCTAssertEqual(server.requestCount, 1,
                       "the POST reached the upstream; an uncertain outcome must not be replayed")
        XCTAssertEqual(server.requests.first?.body, submittedBody)
        XCTAssertTrue(clock.sleeps.isEmpty)
        XCTAssertEqual(gateway.metrics().retries, 0)
    }

    func testBusinessPostOnModelHostDoesNotRetryA500() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            counter.next() == 1
                ? .full(status: 500, headers: [:], body: Data("failed".utf8))
                : .full(status: 200, headers: [:], body: Data("duplicated".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let clock = ManualGatewayClock()
        let (gateway, _, _) = try makeGateway(server: server, clock: clock)

        let response = try await collectGatewayResponse(gateway.handle(
            makeRequest(port: server.port,
                        path: "/v1/payments",
                        headers: ["content-type": "application/json",
                                  "idempotency-key": "caller-supplied"])))
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testCrossOriginRedirectDoesNotForwardCustomCredential() async throws {
        let destination = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("should not receive key".utf8))
        }
        _ = try await destination.start()
        let source = try MockUpstreamServer { _ in
            .full(status: 302,
                  headers: ["location": "http://127.0.0.1:\(destination.port)/final"],
                  body: Data())
        }
        _ = try await source.start()
        addTeardownBlock {
            source.stop()
            destination.stop()
        }
        let config = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["127.0.0.1:\(source.port)", "127.0.0.1:\(destination.port)"],
            backoff: ModelGatewayBackoffPolicy(maximumAttempts: 1),
            upstreamRequestTimeout: 5)
        let provider = StaticCredentialProvider([
            CredentialScope(service: "127.0.0.1"): Credential(
                kind: .apiKey(header: "X-Api-Key"), value: "custom-secret")
        ])
        let gateway = ModelGateway(configuration: config, credentialProvider: provider)
        addTeardownBlock {
            await gateway.shutdown()
        }

        let response = try await collectGatewayResponse(gateway.handle(
            makeRequest(port: source.port, path: "/start")))
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(source.requests.first?.headers["x-api-key"], "custom-secret")
        XCTAssertEqual(destination.requestCount, 0,
                       "an allow-listed different origin must never receive the credential")
    }

    // The former testSameOriginRedirectStillForwardsCredential asserted the
    // PR #1-era policy (same origin, any path, still re-forwards the host
    // credential). The native-integration delivery replaced it with the
    // stricter credential-scope contract: a credentialed redirect is only
    // followed inside the exact scope it was resolved for. The same
    // host/different-path case is covered below by
    // testCredentialRedirectToSameHostDifferentPathIsReturnedNotFollowed and
    // testCredentialRedirectOnTheSameScopeIsStillFollowed.

    func testAnonymousCrossOriginRedirectStillFollowsAllowListedTarget() async throws {
        let destination = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("anonymous".utf8))
        }
        _ = try await destination.start()
        let source = try MockUpstreamServer { _ in
            .full(status: 302,
                  headers: ["location": "http://127.0.0.1:\(destination.port)/final"],
                  body: Data())
        }
        _ = try await source.start()
        addTeardownBlock {
            source.stop()
            destination.stop()
        }
        let config = ModelGatewayConfiguration(
            allowedUpstreamHosts: ["127.0.0.1:\(source.port)", "127.0.0.1:\(destination.port)"],
            backoff: ModelGatewayBackoffPolicy(maximumAttempts: 1),
            upstreamRequestTimeout: 5)
        let provider = StaticCredentialProvider([
            CredentialScope(service: "127.0.0.1"): .none
        ])
        let gateway = ModelGateway(configuration: config, credentialProvider: provider)
        addTeardownBlock { await gateway.shutdown() }

        let response = try await collectGatewayResponse(gateway.handle(
            makeRequest(port: source.port, path: "/start")))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("anonymous".utf8))
        XCTAssertEqual(destination.requestCount, 1)
    }

    func testTransportErrorAfterHeadIsNotRetried() async throws {
        let partialHead = Data(("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n"
            + "content-length: 100\r\nconnection: close\r\n\r\ndata: hello\n\n").utf8)
        let server = try MockUpstreamServer { _ in .abort(partial: partialHead) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let clock = ManualGatewayClock()
        let (gateway, _, _) = try makeGateway(server: server, clock: clock)

        let error = try await expectGatewayFailure(gateway.handle(makeRequest(port: server.port)))
        XCTAssertTrue(error is ModelGatewayError)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    // MARK: - Metrics and lifecycle

    func testMetricsCountBytesRetriesAndSettleInFlight() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { _ in
            counter.next() == 1
                ? .full(status: 503, headers: [:], body: Data("err".utf8))
                : .full(status: 200, headers: [:], body: Data("hello".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)
        let request = makeRequest(port: server.port, body: Data("12345".utf8))

        _ = try await collectGatewayResponse(gateway.handle(request))
        var metrics = gateway.metrics()
        for _ in 0..<40 where metrics.inFlight != 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
            metrics = gateway.metrics()
        }
        XCTAssertEqual(metrics.inFlight, 0)
        XCTAssertEqual(metrics.bytesUp, 10)
        XCTAssertEqual(metrics.bytesDown, 5)
        XCTAssertEqual(metrics.retries, 1)
        XCTAssertEqual(metrics.replayHits, 0)
    }

    func testConnectionReuseFlagIsCollectedFromTaskMetrics() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)

        _ = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        var reused = gateway.metrics().connectionReused
        for _ in 0..<40 where reused == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            reused = gateway.metrics().connectionReused
        }
        XCTAssertNotNil(reused)
    }

    func testPrewarmContactsEachAllowedHost() async throws {
        let first = try MockUpstreamServer { _ in
            .full(status: 204, headers: [:], body: Data())
        }
        let second = try MockUpstreamServer { _ in
            .full(status: 204, headers: [:], body: Data())
        }
        _ = try await first.start()
        _ = try await second.start()
        addTeardownBlock {
            first.stop()
            second.stop()
        }
        let (gateway, _, _) = try makeGateway(
            server: first,
            allowedHosts: ["127.0.0.1:\(first.port)", "127.0.0.1:\(second.port)"])

        await gateway.prewarm()
        for server in [first, second] {
            var requests: [MockHTTPRequest] = []
            for _ in 0..<80 where requests.isEmpty {
                try await Task.sleep(nanoseconds: 25_000_000)
                requests = server.requests
            }
            let request = try XCTUnwrap(requests.first,
                                        "prewarm() must open a connection to every allowed host")
            XCTAssertEqual(request.method, "HEAD")
            XCTAssertEqual(request.path, "/")
        }
    }

    /// Scans the committed response-log bytes, not just error descriptions: the
    /// host credential and the Worker's own Authorization must never reach
    /// `response-log/` (entry metadata, bodies or the index).
    func testResponseLogOnDiskNeverContainsCredentials() async throws {
        let credential = "gateway-secret-\(UUID().uuidString)"
        let workerAuthorization = "worker-secret-\(UUID().uuidString)"
        let server = try MockUpstreamServer { _ in
            .full(status: 200,
                  headers: ["content-type": "application/json", "x-request-id": "req-1"],
                  body: Data(#"{"answer":"ok"}"#.utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, log, root) = try makeGateway(server: server,
                                                   credentialValue: credential)

        let request = makeRequest(port: server.port, headers: [
            "authorization": "Bearer \(workerAuthorization)",
            "x-pdsh-upstream-authorization": "Bearer \(workerAuthorization)",
            "content-type": "application/json",
            "accept": "text/event-stream",
        ])
        _ = try await collectGatewayResponse(gateway.handle(request))

        let key = responseKey(request)
        var recorded: ResponseLogReplay?
        for _ in 0..<40 {
            recorded = await log.replay(key: key)
            if recorded != nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(recorded, "the response must be committed before scanning the log")

        let logDirectory = root.appendingPathComponent("response-log", isDirectory: true)
        let files = try regularFiles(under: logDirectory)
        XCTAssertFalse(files.isEmpty, "the scan must cover real response-log files")
        XCTAssertEqual(try filesContaining(credential, under: logDirectory), [])
        XCTAssertEqual(try filesContaining(workerAuthorization, under: logDirectory), [])
    }

    func testCredentialNeverAppearsInErrorDescription() async throws {
        let server = try MockUpstreamServer { _ in .full(status: 200, headers: [:], body: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let secret = "supersecretvalue"
        let (gateway, _, _) = try makeGateway(
            server: server,
            providers: SecretBearingCredentialProvider(secret: secret))

        let error = try await expectGatewayFailure(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(error as? ModelGatewayError, .credentialUnavailable)
        let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        XCTAssertFalse(description.contains(secret))
        XCTAssertEqual(server.requestCount, 0)
    }

    func testRedirectOutsideAllowListIsReturnedNotFollowed() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 302,
                  headers: ["location": "http://127.0.0.1:9/elsewhere"],
                  body: Data())
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testCredentialRedirectToSameHostDifferentPathIsReturnedNotFollowed() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 307,
                  headers: ["location": "/mcp"],
                  body: Data())
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(
            server: server,
            providers: StaticCredentialProvider([
                CredentialScope(service: "127.0.0.1"):
                    Credential(kind: .apiKey(header: "x-api-key"), value: "model-credential"),
            ]))

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 307,
                       "the original 3xx must be returned instead of redirecting with the credential")
        XCTAssertEqual(server.requestCount, 1,
                       "the same-host MCP path must never receive the model credential")
        XCTAssertEqual(server.requests.first?.headers["x-api-key"], "model-credential")
    }

    func testCredentialRedirectToAnAllowedEgressHostIsReturnedNotFollowed() async throws {
        let egress = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("unexpected".utf8))
        }
        let egressPort = try await egress.start()
        addTeardownBlock { egress.stop() }

        let target = "http://localhost:\(egressPort)/mcp"
        let model = try MockUpstreamServer { _ in
            .full(status: 302, headers: ["location": target], body: Data())
        }
        _ = try await model.start()
        addTeardownBlock { model.stop() }
        let (gateway, _, _) = try makeGateway(
            server: model,
            allowedHosts: ["127.0.0.1:\(model.port)", "localhost:\(egressPort)"])

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: model.port)))
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(model.requestCount, 1)
        XCTAssertEqual(egress.requestCount, 0,
                       "another allow-listed host must not receive the model credential by redirect")
    }

    func testCredentialRedirectToSameHostDifferentPortIsReturnedNotFollowed() async throws {
        let target = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("unexpected".utf8))
        }
        let targetPort = try await target.start()
        addTeardownBlock { target.stop() }

        let model = try MockUpstreamServer { _ in
            .full(status: 307,
                  headers: ["location": "http://127.0.0.1:\(targetPort)/v1/chat/completions"],
                  body: Data())
        }
        _ = try await model.start()
        addTeardownBlock { model.stop() }
        let (gateway, _, _) = try makeGateway(
            server: model,
            allowedHosts: ["127.0.0.1:\(model.port)", "127.0.0.1:\(targetPort)"])

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: model.port)))
        XCTAssertEqual(response.status, 307,
                       "a different port must return the 3xx instead of reusing the credential")
        XCTAssertEqual(model.requestCount, 1)
        XCTAssertEqual(target.requestCount, 0,
                       "the same host on another port must not receive the model credential")
        XCTAssertEqual(model.requests.first?.headers["authorization"], "Bearer test-credential")
    }

    func testCredentialRedirectOnTheSameScopeIsStillFollowed() async throws {
        let counter = LockedCounter()
        let server = try MockUpstreamServer { request in
            if counter.next() == 1 {
                return .full(status: 307,
                             headers: ["location": request.path],
                             body: Data())
            }
            return .full(status: 200,
                         headers: ["content-type": "application/json"],
                         body: Data("{}".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)

        let response = try await collectGatewayResponse(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(server.requests.map { $0.headers["authorization"] },
                       ["Bearer test-credential", "Bearer test-credential"])
    }

    func testShutdownIsIdempotent() async throws {
        let server = try MockUpstreamServer { _ in .full(status: 200, headers: [:], body: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)
        await gateway.shutdown()
        await gateway.shutdown()
    }

    func testGatewayEgressAdapterBridgesToTheGateway() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: ["content-type": "application/json"], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)
        let adapter = GatewayEgressAdapter(gateway: gateway)

        let response = try await collectGatewayResponse(
            adapter.handler(makeRequest(port: server.port)))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("ok".utf8))
        XCTAssertEqual(server.requestCount, 1)
    }

    func testRequestsAfterShutdownFailWithoutUpstreamContact() async throws {
        let server = try MockUpstreamServer { _ in .full(status: 200, headers: [:], body: Data()) }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)
        await gateway.shutdown()

        let error = try await expectGatewayFailure(gateway.handle(makeRequest(port: server.port)))
        XCTAssertEqual(error as? ModelGatewayError, .shuttingDown)
        XCTAssertEqual(server.requestCount, 0)
    }

    func testConcurrentRequestsAllComplete() async throws {
        let server = try MockUpstreamServer { _ in
            .full(status: 200, headers: [:], body: Data("ok".utf8))
        }
        _ = try await server.start()
        addTeardownBlock { server.stop() }
        let (gateway, _, _) = try makeGateway(server: server)
        let port = server.port

        let responses = try await withThrowingTaskGroup(of: CollectedGatewayResponse.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let request = GatewayRequest(
                        method: "POST",
                        url: URL(string: "http://127.0.0.1:\(port)/v1/chat")!,
                        headers: ["content-type": "application/json"],
                        body: Data("request-\(index)".utf8))
                    return try await collectGatewayResponse(gateway.handle(request))
                }
            }
            var collected: [CollectedGatewayResponse] = []
            for try await response in group {
                collected.append(response)
            }
            return collected
        }
        XCTAssertEqual(responses.count, 6)
        XCTAssertTrue(responses.allSatisfy { $0.status == 200 && $0.body == Data("ok".utf8) })
        XCTAssertEqual(server.requestCount, 6)
        var metrics = gateway.metrics()
        for _ in 0..<40 where metrics.inFlight != 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
            metrics = gateway.metrics()
        }
        XCTAssertEqual(metrics.inFlight, 0)
    }
}

// MARK: - Scripted response log

/// Simulates a concurrent finish that evicts the just-committed entry before
/// the gateway can observe it. `finish` is the atomic API and returns `nil`;
/// `receipt(key:)` still returns a stale record so a regression back to the
/// two-hop lookup is observable.
private actor LosingRaceResponseLog: ResponseLogging {
    private var lookups = 0

    func begin(requestID: String, key: String, status: Int,
               headers: [String: String]) async throws {}

    func append(_ entry: ResponseLogEntry) async throws {}

    func finish(requestID: String) async throws -> ResponseLogReceipt? {
        return nil
    }

    func abort(requestID: String) async {}

    func replay(key: String) async -> ResponseLogReplay? {
        return nil
    }

    func replay(key: String, offset: Int) async -> ResponseLogResumeOutcome {
        .missing
    }

    func receipt(key: String) async -> ResponseLogReceipt? {
        lookups += 1
        return ResponseLogReceipt(key: key,
                                  status: 200,
                                  bodyBytes: 5,
                                  lastUsed: 1,
                                  deliveryCount: 1)
    }

    func totalBytes() async -> Int {
        0
    }

    func receiptLookupCount() -> Int {
        lookups
    }
}

/// Returns a retained receipt from `finish`, but `receipt(key:)` would return
/// nil. The gateway must trust the atomic finish result and never look up the
/// key a second time.
private actor CommitReceiptResponseLog: ResponseLogging {
    private var keys: [String: String] = [:]
    private var lookups = 0

    func begin(requestID: String, key: String, status: Int,
               headers: [String: String]) async throws {
        keys[requestID] = key
    }

    func append(_ entry: ResponseLogEntry) async throws {}

    func finish(requestID: String) async throws -> ResponseLogReceipt? {
        guard let key = keys.removeValue(forKey: requestID) else { return nil }
        return ResponseLogReceipt(key: key,
                                  status: 200,
                                  bodyBytes: 5,
                                  lastUsed: 0,
                                  deliveryCount: 0)
    }

    func abort(requestID: String) async {
        keys.removeValue(forKey: requestID)
    }

    func replay(key: String) async -> ResponseLogReplay? {
        return nil
    }

    func replay(key: String, offset: Int) async -> ResponseLogResumeOutcome {
        .missing
    }

    func receipt(key: String) async -> ResponseLogReceipt? {
        lookups += 1
        return nil
    }

    func totalBytes() async -> Int {
        0
    }

    func receiptLookupCount() -> Int {
        lookups
    }
}

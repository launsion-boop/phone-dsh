// SPDX-License-Identifier: MIT
// RelayDSHTransport integration over an in-memory relay/PC: unary calls,
// chunked results, mux streams, cancel, §7 disconnect retry classes, relay
// offline and shared `$events` session.

import Foundation
import XCTest
@testable import PhoneDSHPCLink
import PhoneDSHAgentCore

final class RelayDSHTransportTests: XCTestCase {
    override func tearDown() async throws {
        await PCLinkTestTracker.stopAll()
        try await super.tearDown()
    }

    func testUnaryCall() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setResult(.object(["items": .array([.string("one")])]))
        let result = try await fixture.transport.call("session/list", args: .object(["_request": .object([:])]))
        XCTAssertEqual(result["items"]?.arrayValue?.first?.stringValue, "one")
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].endpoint, "session/list")
        XCTAssertEqual(calls[0].args, .object(["_request": .object([:])]))
        let sessions = await fixture.server.sessionIDs
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(calls[0].sid, sessions[0])
    }

    func testChunkedUnaryResultIsReassembled() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setResult(.object([
            "items": .array((0..<40).map { .object(["n": .int(Int64($0)), "text": .string("abcdef")]) }),
        ]))
        await fixture.server.setPolicy(.chunkedResult, for: "session/page")
        let result = try await fixture.transport.call("session/page", args: .object(["request": .object([:])]))
        XCTAssertEqual(result["items"]?.arrayValue?.count, 40)
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testMuxStreamItemsAndEnd() async throws {
        let fixture = try await PCLinkTestFixture.make()
        let mux = try await fixture.transport.openMux()
        try await mux.send(.object([
            "type": .string("open"), "streamId": .string("follow"),
            "endpoint": .string("session/follow"),
            "payload": .object(["args": .object([
                "request": .object(["address": .object(["kind": .string("session"),
                                                        "sessionId": .string("session-1")]),
                                    "maxMessages": .number(1)]),
            ])]),
        ]))
        let first = try await mux.receive()
        XCTAssertEqual(first?["type"]?.stringValue, "item")
        XCTAssertEqual(first?["streamId"]?.stringValue, "follow")
        XCTAssertEqual(first?["value"]?["type"]?.stringValue, "snapshot")
        let second = try await mux.receive()
        XCTAssertEqual(second?["type"]?.stringValue, "end")
        await mux.close()
        let opens = await fixture.server.opens
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(opens[0].endpoint, "session/follow")
        XCTAssertEqual(first?["streamId"]?.stringValue, "follow",
                       "the client maps the wire id back to the mux-local id")
        XCTAssertNotEqual(opens[0].streamId, "follow",
                          "the mux-local id must never be the wire streamId")
    }

    func testMuxChunkedItemIsReassembled() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setStreamPolicy(.chunkedThenEnd, for: "session/follow")
        let mux = try await fixture.transport.openMux()
        try await mux.send(.object([
            "type": .string("open"), "streamId": .string("follow"),
            "endpoint": .string("session/follow"),
            "payload": .object(["args": .object([:])]),
        ]))
        let item = try await mux.receive()
        XCTAssertEqual(item?["type"]?.stringValue, "item")
        XCTAssertEqual(item?["value"]?["type"]?.stringValue, "snapshot")
        let ending = try await mux.receive()
        XCTAssertEqual(ending?["type"]?.stringValue, "end")
        await mux.close()
    }

    func testMuxCancelReachesPCAndEndsStream() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setStreamPolicy(.awaitCancelThenEnd, for: "session/follow")
        let mux = try await fixture.transport.openMux()
        try await mux.send(.object([
            "type": .string("open"), "streamId": .string("follow"),
            "endpoint": .string("session/follow"),
            "payload": .object(["args": .object([:])]),
        ]))
        let first = try await mux.receive()
        XCTAssertEqual(first?["type"]?.stringValue, "item")
        try await mux.send(.object(["type": .string("cancel"), "streamId": .string("follow")]))
        let end = try await mux.receive()
        XCTAssertEqual(end?["type"]?.stringValue, "end")
        let opens = await fixture.server.opens
        let cancels = await fixture.server.cancels
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(cancels, [opens[0].streamId],
                       "the cancel carries the same session wire id as the open")
        await mux.close()
    }

    func testReadCallRetriesAfterDisconnect() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setPolicy(.dropFirst, for: "session/list")
        await fixture.server.setResult(.object(["items": .array([.string("after-retry")])]))
        let result = try await fixture.transport.call("session/list",
                                                      args: .object(["_request": .object([:])]))
        XCTAssertEqual(result["items"]?.arrayValue?.first?.stringValue, "after-retry")
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotEqual(calls[0].id, calls[1].id, "a read retry gets a fresh correlation id")
        let handshakes = await fixture.server.handshakes
        XCTAssertEqual(handshakes, 2)
    }

    func testIdempotentRetryKeepsDSHArguments() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setPolicy(.dropFirst, for: "session/prompt")
        let args: JSONValue = .object(["request": .object([
            "requestId": .string("req-1"),
            "sessionId": .string("s-1"),
            "mode": .string("queue"),
            "content": .array([.object(["type": .string("text"), "text": .string("hello")])]),
        ])])
        _ = try await fixture.transport.call("session/prompt", args: args)
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].args, calls[1].args)
        XCTAssertNotEqual(calls[0].id, calls[1].id)
        XCTAssertEqual(calls[0].args["request"]?["requestId"]?.stringValue, "req-1")
    }

    func testUnsafeCallBecomesUnknownOutcomeAndIsNotResent() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setPolicy(.dropFirst, for: "session/create")
        do {
            _ = try await fixture.transport.call("session/create",
                                                 args: .object(["request": .object([:])]))
            XCTFail("unsafe call should throw")
        } catch let error as PCLinkUnknownOutcome {
            XCTAssertEqual(error.endpoint, "session/create")
            XCTAssertEqual(error.code, "unknown_outcome")
        }
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 1, "an unsafe call is never resent")
    }

    func testRelayOfflineForSentUnsafeCallIsUnknownOutcome() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setPolicy(.relayOfflineFirst, for: "session/create")
        do {
            _ = try await fixture.transport.call("session/create",
                                                 args: .object(["request": .object([:])]))
            XCTFail("relay.offline should fail the call")
        } catch let error as PCLinkUnknownOutcome {
            XCTAssertEqual(error.endpoint, "session/create")
            XCTAssertEqual(error.code, "unknown_outcome")
        }
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 1, "an unsafe call is never resent")
    }

    /// When the relay echoes the exact `id`, that frame was definitively not
    /// delivered and unsafe may surface `peer_offline` instead.
    func testRelayOfflineWithCorrelationIDIsPeerOffline() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setPolicy(.relayOfflineWithIDFirst, for: "session/create")
        do {
            _ = try await fixture.transport.call("session/create",
                                                 args: .object(["request": .object([:])]))
            XCTFail("relay.offline should fail the call")
        } catch let error as ProviderError {
            switch error {
            case .unavailable: break
            default: XCTFail("expected unavailable/peer_offline, got \(error)")
            }
        }
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testEventsAndResultShareOneSession() async throws {
        let fixture = try await PCLinkTestFixture.make()
        let mux = try await fixture.transport.openMux()
        try await mux.send(.object([
            "type": .string("open"), "streamId": .string("events"),
            "endpoint": .string("$events"),
            "payload": .object(["args": .object([:])]),
        ]))
        _ = try await mux.receive()
        _ = try await mux.receive()
        _ = try await fixture.transport.call("session/prompt", args: .object(["request": .object([
            "requestId": .string("req-2"), "sessionId": .string("s-1"),
        ])]))
        _ = try await fixture.transport.call("$events/result", args: .object([
            "clientId": .string("client-1"), "eventId": .string("event-1"),
            "outcome": .object(["kind": .string("next")]),
        ]))
        let calls = await fixture.server.calls
        let sessions = await fixture.server.sessionIDs
        XCTAssertEqual(sessions.count, 1, "the transport must not re-handshake per call")
        XCTAssertEqual(Set(calls.map(\.sid)).count, 1)
        XCTAssertEqual(calls.map(\.endpoint), ["session/prompt", "$events/result"])
        XCTAssertEqual(calls[1].args["clientId"]?.stringValue, "client-1")
        await mux.close()
    }

    func testPeerHelloExposesDshAndAppMetadataInRange() async throws {
        let fixture = try await PCLinkTestFixture.make()
        try await fixture.client.connectAndWait()
        let status = await fixture.client.status()
        XCTAssertNil(status.versionWarning)
        XCTAssertEqual(status.peerDshVersion, "0.2.2-rc.1")
        XCTAssertEqual(status.peerAppName, "dsh-pclink")
        XCTAssertEqual(status.peerAppVersion, "0.1.0")
        // The same verified metadata survives an ordinary status read while the
        // session stays usable (the App's connected-computer page reads it).
        let value = try await fixture.transport.call("session/list",
                                                     args: .object(["_request": .object([:])]))
        XCTAssertNotNil(value.objectValue)
        let afterCall = await fixture.client.status()
        XCTAssertEqual(afterCall.peerDshVersion, "0.2.2-rc.1")
    }

    func testOutOfRangeDSHVersionIsOnlyAWarning() async throws {
        let fixture = try await PCLinkTestFixture.make { server in
            await server.setDSHVersion("0.3.0")
        }
        try await fixture.client.connectAndWait()
        let status = await fixture.client.status()
        XCTAssertEqual(status.versionWarning?.dshVersion, "0.3.0")
        XCTAssertEqual(status.peerDshVersion, "0.3.0")
        XCTAssertEqual(status.peerAppName, "dsh-pclink")
        XCTAssertEqual(status.peerAppVersion, "0.1.0")
        if case .versionWarning(let warning) = status.state {
            XCTAssertEqual(warning.dshVersion, "0.3.0")
        } else {
            XCTFail("expected the version-warning state, got \(status.state)")
        }
        // The session is still usable; the range check is a banner, not a block.
        let value = try await fixture.transport.call("session/list",
                                                     args: .object(["_request": .object([:])]))
        XCTAssertNotNil(value.objectValue)
    }

    func testSignedUnpairedRejectKeepsRecordAndPrompts() async throws {
        let fixture = try await PCLinkTestFixture.make { server in
            await server.setRejectUnpaired(true)
        }
        do {
            _ = try await fixture.transport.call("session/list",
                                                 args: .object(["_request": .object([:])]))
            XCTFail("the signed unpaired reject must fail the handshake")
        } catch let error as ProviderError {
            switch error {
            case .invalidRequest(let message): XCTAssertTrue(message.contains("unpaired"))
            default: XCTFail("expected invalidRequest/unpaired, got \(error)")
            }
        }
        let status = await fixture.client.status()
        XCTAssertNotNil(status.record, "the phone record is never deleted automatically")
        XCTAssertEqual(status.pcUnpairedPrompt?.record.peerMachineId, fixture.pcIdentity.machineId)
        XCTAssertEqual(status.pcUnpairedPrompt?.code, "unpaired")
        if case .offline(.unpairedPrompt) = status.state {
            // expected
        } else {
            XCTFail("expected the unpaired prompt state, got \(status.state)")
        }
        // An unauthenticated/unpaired reject never auto-pairs or deletes.
        let record = await fixture.client.status().record
        XCTAssertEqual(record?.peerMachineId, fixture.pcIdentity.machineId)
    }

    func testPairedNoticeIsDecodedAndDelivered() async throws {
        let fixture = try await PCLinkTestFixture.make()
        let notices = await fixture.client.noticeStream()
        var iterator = notices.makeAsyncIterator()
        await fixture.server.queueNotice()
        _ = try await fixture.transport.call("session/list",
                                             args: .object(["_request": .object([:])]))
        let notice = await withTaskGroup(of: PCLinkNotice?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
        XCTAssertEqual(notice?.kind, "paired")
        XCTAssertEqual(notice?.name, "Other iPhone")
        XCTAssertEqual(notice?.fingerprint, "gewr-a3lz-quax")
        let status = await fixture.client.status()
        XCTAssertEqual(status.lastNotice, notice)
    }

    func testForbiddenAdminPrefixIsNotForwarded() async throws {
        let fixture = try await PCLinkTestFixture.make()
        do {
            _ = try await fixture.transport.call("pclink.admin/status", args: .object([:]))
            XCTFail("remote admin call must be forbidden")
        } catch let error as DSHRemoteError {
            XCTAssertEqual(error.code, "forbidden")
        }
        let calls = await fixture.server.calls
        XCTAssertTrue(calls.isEmpty, "the forbidden prefix must never reach the PC")
    }

    // MARK: - §6.2 session-unique wire stream ids

    func testWireStreamIDsAreSessionUniqueAcrossMuxesAndSessions() async throws {
        let fixture = try await PCLinkTestFixture.make()
        let firstMux = try await fixture.transport.openMux()
        try await firstMux.send(.object([
            "type": .string("open"), "streamId": .string("events"),
            "endpoint": .string("$events"),
            "payload": .object(["args": .object([:])]),
        ]))
        _ = try await firstMux.receive()
        _ = try await firstMux.receive()
        try await firstMux.send(.object([
            "type": .string("open"), "streamId": .string("follow"),
            "endpoint": .string("session/follow"),
            "payload": .object(["args": .object([
                "request": .object(["address": .object(["kind": .string("session"),
                                                         "sessionId": .string("session-1")])]),
            ])]),
        ]))
        let firstItem = try await firstMux.receive()
        XCTAssertEqual(firstItem?["streamId"]?.stringValue, "follow")
        _ = try await firstMux.receive()
        await firstMux.close()

        // A second mux in the same E2E session reuses the local ids
        // (`events`/`follow`); the wire ids must still be new.
        let secondMux = try await fixture.transport.openMux()
        try await secondMux.send(.object([
            "type": .string("open"), "streamId": .string("follow"),
            "endpoint": .string("session/follow"),
            "payload": .object(["args": .object([
                "request": .object(["address": .object(["kind": .string("session"),
                                                         "sessionId": .string("session-2")])]),
            ])]),
        ]))
        let secondItem = try await secondMux.receive()
        XCTAssertEqual(secondItem?["streamId"]?.stringValue, "follow")
        _ = try await secondMux.receive()
        await secondMux.close()

        let opens = await fixture.server.opens
        XCTAssertEqual(opens.count, 3)
        XCTAssertEqual(Set(opens.map(\.streamId)).count, opens.count,
                       "every open uses a different session wire id")
        XCTAssertFalse(opens.contains { $0.streamId == "events" || $0.streamId == "follow" },
                       "mux-local ids are never sent on the wire")
        let reused = await fixture.server.reusedStreamIDs
        XCTAssertTrue(reused.isEmpty, "the PC rejected a reused streamId: \(reused)")
    }

    // MARK: - §5.4 single-writer sequence order

    func testConcurrentCallsKeepWireSeqStrictlyIncreasing() async throws {
        let fixture = try await PCLinkTestFixture.make(clientSendHook: { text in
            // Reorder the sends if the client lets two socket.send calls
            // overlap: even-seq frames arrive late.
            guard let frame = try? PCLinkJSONParser.parseObject(Data(text.utf8)),
                  frame["type"]?.stringValue == "e2e",
                  let seq = frame["seq"]?.intValue else { return }
            if seq % 2 == 0 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        })
        let args: PCLinkJSON = .object(["_request": .object([:])])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<48 {
                group.addTask {
                    _ = try await fixture.transport.call("session/list", args: args.jsonValue)
                }
            }
            try await group.waitForAll()
        }
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 48)
        let sawOutOfOrder = await fixture.server.sawOutOfOrderSeq
        XCTAssertFalse(sawOutOfOrder, "the phone sent seq out of wire order")
        let seqs = await fixture.server.receivedSeqs
        XCTAssertEqual(seqs, (0..<Int64(seqs.count)).map { $0 },
                       "seq must be contiguous and strictly increasing")
    }

    // MARK: - §5.6 capability intersection

    func testNoCapabilityIntersectionClosesVersionUnsupportedAndDoesNotRetry() async throws {
        let fixture = try await PCLinkTestFixture.make { server in
            await server.setCaps(["workspace/1"])
        }
        do {
            try await fixture.client.connectAndWait()
            XCTFail("a missing workspace/1 + suite intersection must fail")
        } catch let error as PCLinkError {
            XCTAssertEqual(error.code, "version_unsupported")
        }
        // Give the close frame a chance to reach the fake PC.
        try await Task.sleep(nanoseconds: 200_000_000)
        let status = await fixture.client.status()
        XCTAssertEqual(status.state, .offline(.versionUnsupported))
        let closeCodes = await fixture.server.receivedCloseCodes
        XCTAssertTrue(closeCodes.contains("version_unsupported"),
                      "the phone must send session.close{version_unsupported}")
        let connections = await fixture.server.connections
        XCTAssertEqual(connections, 1, "version_unsupported must not reconnect")
        try await Task.sleep(nanoseconds: 300_000_000)
        let after = await fixture.server.connections
        XCTAssertEqual(after, 1, "version_unsupported is terminal (no retry)")
    }

    // MARK: - §9.1 rate_limited reconnect

    func testRateLimitedTearsDownWaitsRetryAfterAndReconnects() async throws {
        let fixture = try await PCLinkTestFixture.make { server in
            await server.setPolicy(.rateLimitedFirst(retryAfterMs: 200), for: "session/list")
        }
        let start = Date()
        // Bound the old-code failure mode (rate_limited was ignored, so the
        // call never returned) instead of letting the whole suite hang.
        let result = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await fixture.transport.call("session/list",
                                                 args: .object(["_request": .object([:])]))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw PCLinkError.unavailable("rate-limited call did not reconnect")
            }
            guard let value = try await group.next() else {
                throw PCLinkError.unavailable("rate-limited call did not reconnect")
            }
            group.cancelAll()
            return value
        }
        XCTAssertNotNil(result.objectValue)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15,
                                    "the client must wait retryAfterMs before reconnecting")
        let calls = await fixture.server.calls
        XCTAssertEqual(calls.count, 2, "the read call is retried after a temporary rate limit")
        let handshakes = await fixture.server.handshakes
        XCTAssertEqual(handshakes, 2, "rate_limited tears the E2E session down")
    }

    // MARK: - stop/start lifecycle

    func testStopWaitsForOldLoopAndStartIsIdempotent() async throws {
        let fixture = try await PCLinkTestFixture.make()
        try await fixture.client.start()
        try await fixture.client.start()
        let onlineAfterDoubleStart = await waitOnline(fixture.client)
        XCTAssertTrue(onlineAfterDoubleStart)
        let initial = await fixture.server.connections
        XCTAssertEqual(initial, 1, "start() is idempotent while the loop is alive")

        for _ in 0..<4 {
            await fixture.client.stop()
            try await fixture.client.start()
            let onlineAfterRestart = await waitOnline(fixture.client)
            XCTAssertTrue(onlineAfterRestart)
        }
        await fixture.client.stop()
        try await Task.sleep(nanoseconds: 250_000_000)
        let connections = await fixture.server.connections
        XCTAssertEqual(connections, 5,
                       "one connection per start, and no old loop woke up after stop")
    }

    // MARK: - §2.3/§6.2/§5.4 small conformance regressions

    func testRpcResultWithUnknownMemberIsBadFrame() async throws {
        let fixture = try await PCLinkTestFixture.make { server in
            await server.setPolicy(.unknownResultMember, for: "session/list")
        }
        do {
            _ = try await fixture.transport.call("session/list",
                                                 args: .object(["_request": .object([:])]))
            XCTFail("an unknown member of a PCLink object is bad_frame")
        } catch let error as ProviderError {
            switch error {
            case .invalidResponse(let message):
                XCTAssertTrue(message.contains("bad_frame"), message)
            default:
                XCTFail("expected invalidResponse/bad_frame, got \(error)")
            }
        }
    }

    func testOversizedStreamChunkSendsCancel() async throws {
        let fixture = try await PCLinkTestFixture.make { server in
            await server.setStreamPolicy(.oversizeChunkThenEnd, for: "session/follow")
        }
        let mux = try await fixture.transport.openMux()
        try await mux.send(.object([
            "type": .string("open"), "streamId": .string("follow"),
            "endpoint": .string("session/follow"),
            "payload": .object(["args": .object([:])]),
        ]))
        let error = try await mux.receive()
        XCTAssertEqual(error?["type"]?.stringValue, "error")
        XCTAssertEqual(error?["error"]?["code"]?.stringValue, "frame_too_large")
        let opens = await fixture.server.opens
        XCTAssertEqual(opens.count, 1)
        let wireID = opens[0].streamId
        var sentCancel = false
        for _ in 0..<50 {
            let cancels = await fixture.server.cancels
            if cancels.contains(wireID) { sentCancel = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(sentCancel, "the phone must send rpc.stream.cancel for the over-limit stream")
        await mux.close()
    }

    func testCloseMuxClearsPartialChunkBufferByWireKey() async throws {
        let fixture = try await PCLinkTestFixture.make { server in
            await server.setStreamPolicy(.partialChunkThenAwaitCancel, for: "session/follow")
        }
        let mux = try await fixture.transport.openMux()
        try await mux.send(.object([
            "type": .string("open"), "streamId": .string("follow"),
            "endpoint": .string("session/follow"),
            "payload": .object(["args": .object([:])]),
        ]))
        var pending = false
        for _ in 0..<50 {
            let keys = await fixture.client.pendingStreamChunkIDs
            if !keys.isEmpty { pending = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(pending, "the partial chunk should be buffered")
        await mux.close()
        let after = await fixture.client.pendingStreamChunkIDs
        XCTAssertTrue(after.isEmpty, "closeMux must remove each stream's chunk buffer")
    }

    func testAEADFailureMapsToAuthFailed() async throws {
        let fixture = try await PCLinkTestFixture.make { server in
            await server.setPolicy(.corruptAEAD, for: "session/list")
        }
        do {
            _ = try await fixture.transport.call("session/list",
                                                 args: .object(["_request": .object([:])]))
            XCTFail("a bad AEAD tag must fail the session")
        } catch let error as ProviderError {
            switch error {
            case .invalidRequest(let message):
                XCTAssertTrue(message.contains("auth_failed"), message)
            default:
                XCTFail("expected invalidRequest/auth_failed, got \(error)")
            }
        }
    }


    func testForegroundResumedReplacesTheSuspendedConnection() async throws {
        let fixture = try await PCLinkTestFixture.make()
        let online = await waitOnline(fixture.client)
        XCTAssertTrue(online)
        let before = await fixture.server.connections
        await fixture.client.foregroundResumed()
        let onlineAgain = await waitOnline(fixture.client)
        XCTAssertTrue(onlineAgain, "the foreground wake must re-handshake")
        let after = await fixture.server.connections
        XCTAssertEqual(after, before + 1,
                       "foreground replaces the old relay connection exactly once")
        _ = try await fixture.transport.call("session/list",
                                             args: .object(["_request": .object([:])]))
    }
    private func waitOnline(_ client: PCLinkClient,
                            timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await client.currentState().isOnline { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}

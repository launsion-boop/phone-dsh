// SPDX-License-Identifier: MIT
// RelayDSHTransport integration over an in-memory relay/PC: unary calls,
// chunked results, mux streams, cancel, §7 disconnect retry classes, relay
// offline and shared `$events` session.

import Foundation
import XCTest
@testable import PhoneDSHPCLink
import PhoneDSHAgentCore

final class RelayDSHTransportTests: XCTestCase {
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
        let cancels = await fixture.server.cancels
        XCTAssertEqual(cancels, ["follow"])
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

    func testRelayOfflineMapsToPeerOffline() async throws {
        let fixture = try await PCLinkTestFixture.make()
        await fixture.server.setPolicy(.relayOfflineFirst, for: "session/create")
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
        XCTAssertEqual(calls.count, 1, "relay.offline means the frame was not delivered; unsafe is not retried")
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
}

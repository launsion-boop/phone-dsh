// SPDX-License-Identifier: MIT
// PhoneDSHLoopback WebSocket tests: RFC 6455 handshake, echo latency,
// fragmentation, ping/pong, masking and channel-level validation over a real
// URLSessionWebSocketTask / raw TCP client. No @MainActor.

import Foundation
import XCTest
import PhoneDSHWire
import PhoneDSHLoopback
import PhoneDSHAgentCore

final class WebSocketTests: XCTestCase {
    private func startEchoServer() async throws -> (LoopbackServer, TestHTTPClient) {
        let server = LoopbackServer(websocketHandler: { websocket in
            do {
                while let message = try await websocket.receive() {
                    switch message {
                    case .binary(let data):
                        try await websocket.send(binary: data)
                    case .text(let text):
                        try await websocket.send(text: text)
                    }
                }
            } catch {
                // The peer closed or violated the protocol; nothing to do.
            }
        })
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }
        return (server, TestHTTPClient(endpoint: endpoint))
    }

    private func startChannelServer(
        state: ChannelHostState,
        routes: LoopbackRoutes = LoopbackRoutes(),
        handlerFactory: (@Sendable (any ChannelOutbound) -> any ChannelHandling)? = nil
    ) async throws -> TestWebSocketClient {
        let server = LoopbackServer(
            routes: routes,
            channelStateProvider: { state },
            channelHandlerFactory: handlerFactory)
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }
        let client = TestWebSocketClient(endpoint: endpoint)
        client.connect()
        addTeardownBlock { client.close() }
        return client
    }

    private func sendHello(_ client: TestWebSocketClient, state: ChannelHostState,
                           lastMseq: UInt64, generation: UInt64? = nil,
                           owner: String? = nil) async throws -> HelloPayload {
        let hello = try workerHelloPayload(state: state, lastMseq: lastMseq,
                                           generation: generation, owner: owner)
        try await client.send(try encodeJSONFrame(.hello, seq: 1, value: hello))
        let frame = try await client.receiveFrame(timeout: 5)
        XCTAssertEqual(frame.type, .hello)
        XCTAssertEqual(frame.seq, 1)
        return try JSONDecoder().decode(HelloPayload.self, from: frame.payload)
    }

    private func errorPayload(_ frame: Frame) throws -> ErrorPayload {
        XCTAssertEqual(frame.type, .error)
        return try JSONDecoder().decode(ErrorPayload.self, from: frame.payload)
    }

    // MARK: - Raw WebSocket server behavior

    func testHandshakeAndBinaryEcho() async throws {
        let (_, client) = try await startEchoServer()
        let websocket = TestWebSocketClient(endpoint: client.endpoint)
        websocket.connect()
        addTeardownBlock { websocket.close() }
        try await websocket.send(Data("hello".utf8))
        let echoed = try await websocket.receiveBinary()
        XCTAssertEqual(echoed, Data("hello".utf8))
        try await websocket.send(Data([0, 1, 2, 255]))
        let echoedBroadcast = try await websocket.receiveBinary()
        XCTAssertEqual(echoedBroadcast, Data([0, 1, 2, 255]))
    }

    func testRawHandshakeUsesRFC6455SampleAcceptValue() async throws {
        // RFC 6455 §1.3 fixes the accept value for the sample key, so the raw
        // client can check the SHA-1+GUID computation directly (not only
        // indirectly through URLSessionWebSocketTask's own validation).
        let (_, client) = try await startEchoServer()
        let raw = RawWebSocketClient(endpoint: client.endpoint)
        addTeardownBlock { raw.close() }
        let handshake = try await raw.connectAndHandshake(key: rfc6455SampleKey)
        XCTAssertEqual(handshake.status, 101)
        XCTAssertEqual(handshake.header("upgrade")?.lowercased(), "websocket")
        XCTAssertEqual(handshake.header("sec-websocket-accept"), rfc6455SampleAccept)
    }

    func testThousandEchoFramesWithLatencyPercentiles() async throws {
        let (_, client) = try await startEchoServer()
        let websocket = TestWebSocketClient(endpoint: client.endpoint)
        websocket.connect()
        addTeardownBlock { websocket.close() }
        var samples: [Double] = []
        samples.reserveCapacity(1000)
        for index in 0..<1000 {
            let payload = Data([UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)])
            let start = Date()
            try await websocket.send(payload)
            let echoed = try await websocket.receiveBinary()
            samples.append(Date().timeIntervalSince(start) * 1000)
            XCTAssertEqual(echoed, payload)
        }
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print("PhoneDSHLoopback WebSocket echo: p50=\(p50) ms p95=\(p95) ms (target p95 < 5 ms)")
        XCTAssertEqual(samples.count, 1000)
    }

    func testFragmentedMessageIsReassembled() async throws {
        let (_, client) = try await startEchoServer()
        let raw = RawWebSocketClient(endpoint: client.endpoint)
        addTeardownBlock { raw.close() }
        let handshake = try await raw.connectAndHandshake()
        XCTAssertEqual(handshake.status, 101)
        try await raw.sendFrame(fin: false, opcode: 0x2, payload: Data("frag".utf8))
        try await raw.sendFrame(fin: false, opcode: 0x0, payload: Data("ment".utf8))
        try await raw.sendFrame(fin: true, opcode: 0x0, payload: Data("ed".utf8))
        let echoed = try await raw.receiveFrame()
        XCTAssertEqual(echoed.opcode, 0x2)
        XCTAssertTrue(echoed.fin)
        XCTAssertEqual(echoed.payload, Data("fragmented".utf8))
    }

    func testPingIsAnsweredWithPong() async throws {
        let (_, client) = try await startEchoServer()
        let raw = RawWebSocketClient(endpoint: client.endpoint)
        addTeardownBlock { raw.close() }
        let handshake = try await raw.connectAndHandshake()
        XCTAssertEqual(handshake.status, 101)
        try await raw.sendFrame(fin: true, opcode: 0x9, payload: Data("hi".utf8))
        let pong = try await raw.receiveFrame()
        XCTAssertEqual(pong.opcode, 0xA)
        XCTAssertEqual(pong.payload, Data("hi".utf8))
    }

    func testUnmaskedClientFrameIsProtocolError() async throws {
        let (_, client) = try await startEchoServer()
        let raw = RawWebSocketClient(endpoint: client.endpoint)
        addTeardownBlock { raw.close() }
        let handshake = try await raw.connectAndHandshake()
        XCTAssertEqual(handshake.status, 101)
        try await raw.sendFrame(fin: true, opcode: 0x2, payload: Data("x".utf8), masked: false)
        let close = try await raw.receiveFrame()
        XCTAssertEqual(close.opcode, 0x8)
        let code = (Int(close.payload[close.payload.startIndex]) << 8)
            | Int(close.payload[close.payload.index(after: close.payload.startIndex)])
        XCTAssertEqual(code, 1002)
    }

    // MARK: - Ordered channel over WebSocket

    func testChannelHelloOverWebSocket() async throws {
        let state = ChannelHostState(ackedMseq: 41, durableMseq: 40)
        let client = try await startChannelServer(state: state)
        let hostHello = try await sendHello(client, state: state, lastMseq: 41)
        XCTAssertEqual(hostHello.role, .host)
        XCTAssertEqual(hostHello.proto, 1)
        XCTAssertEqual(hostHello.nextMseq, 42)
        XCTAssertEqual(hostHello.ackedMseq, 41)
        XCTAssertEqual(hostHello.durableMseq, 40)
        XCTAssertTrue(hostHello.caps.contains("channel/1"))
        XCTAssertTrue(hostHello.caps.contains("wal/1"))
        XCTAssertTrue(hostHello.caps.contains("exec/1"))
    }

    func testStaleFenceIsRejectedWithFenceStale() async throws {
        let state = ChannelHostState(fence: Fence(owner: "phone", generation: 3, walSeq: 1))
        let client = try await startChannelServer(state: state)
        _ = try await sendHello(client, state: state, lastMseq: 0, generation: 2)
        let error = try errorPayload(try await client.receiveFrame(timeout: 5))
        XCTAssertEqual(error.code, .fenceStale)
    }

    func testWrongFenceOwnerIsRejected() async throws {
        let state = ChannelHostState(fence: Fence(owner: "phone", generation: 3, walSeq: 1))
        let client = try await startChannelServer(state: state)
        _ = try await sendHello(client, state: state, lastMseq: 0, owner: "other")
        let error = try errorPayload(try await client.receiveFrame(timeout: 5))
        XCTAssertEqual(error.code, .fenceStale)
    }

    func testOutOfOrderSeqIsRejectedWithBadSeq() async throws {
        let state = ChannelHostState()
        let client = try await startChannelServer(state: state)
        _ = try await sendHello(client, state: state, lastMseq: 0)
        let console = ConsolePayload(level: .info, text: "skip a seq")
        try await client.send(try encodeJSONFrame(.console, seq: 3, value: console))
        let error = try errorPayload(try await client.receiveFrame(timeout: 5))
        XCTAssertEqual(error.code, .badSeq)
    }

    func testFirstFrameNotHelloIsProtoMismatch() async throws {
        let state = ChannelHostState()
        let client = try await startChannelServer(state: state)
        let first = try await client.receiveFrame(timeout: 5)
        XCTAssertEqual(first.type, .hello)
        let console = ConsolePayload(level: .info, text: "first")
        try await client.send(try encodeJSONFrame(.console, seq: 1, value: console))
        let error = try errorPayload(try await client.receiveFrame(timeout: 5))
        XCTAssertEqual(error.code, .protoMismatch)
    }

    func testReconnectResendsUnackedMutationExactlyOnce() async throws {
        let state = ChannelHostState(ackedMseq: 41, durableMseq: 40)
        let log = RecordingWorkspaceLog(nextMseq: 42)
        let recorder = RecordingChannelHandler(workspaceLog: log)
        let factory: @Sendable (any ChannelOutbound) -> any ChannelHandling = { _ in recorder }
        let server = LoopbackServer(routes: LoopbackRoutes(workspaceLog: log),
                                    channelStateProvider: { state },
                                    channelHandlerFactory: factory)
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }

        // First connection attaches, then dies before anything was appended.
        let first = TestWebSocketClient(endpoint: endpoint)
        first.connect()
        _ = try await sendHello(first, state: state, lastMseq: 42)
        first.close()
        _ = await waitUntil { (await recorder.hellosCount) == 1 }

        // Reconnect: the host still advertises acked_mseq = 41, so mseq 42 is
        // the expected unacknowledged mutation.
        let second = TestWebSocketClient(endpoint: endpoint)
        second.connect()
        addTeardownBlock { second.close() }
        _ = try await sendHello(second, state: state, lastMseq: 42)
        let mutation = VfsMutationBody(op: .write, mode: 0o644,
                                       mflags: [.entryChanged],
                                       path: "/dsh/workspace/notes.txt",
                                       data: Data("hello\n".utf8))
        let payload = try VfsMutationPayload.encode(mseq: 42, body: mutation)
        try await second.send(try encodedFrame(.vfsMutation, seq: 2, payload: payload))
        let ackFrame = try await second.receiveFrame(timeout: 5)
        XCTAssertEqual(ackFrame.type, .vfsAck)
        let ack = try VfsAckBody.decode(ackFrame.payload)
        XCTAssertEqual(ack.level, .write)
        XCTAssertEqual(ack.uptoMseq, 42)

        // The same mseq again on the same connection is BAD_MSEQ.
        try await second.send(try encodedFrame(.vfsMutation, seq: 3, payload: payload))
        let error = try errorPayload(try await second.receiveFrame(timeout: 5))
        XCTAssertEqual(error.code, .badMseq)
        let mutationCount = await recorder.mutationCount
        XCTAssertEqual(mutationCount, 1)
    }

    func testReconnectResendsJournalRecordsAgainstPersistedHighWater() async throws {
        // D2/channel.md §9.3 over the real WebSocket path: a new connection may
        // re-send journal records it never saw acked; the host deduplicates by
        // (session_id, jseq) against the persisted mark, not a connection
        // counter, and a duplicate is acked again without being re-appended.
        let state = ChannelHostState()
        let journal = CountingJournalLog()
        let server = LoopbackServer(routes: LoopbackRoutes(journalLog: journal),
                                    channelStateProvider: { state })
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }

        let first = TestWebSocketClient(endpoint: endpoint)
        first.connect()
        addTeardownBlock { first.close() }
        _ = try await sendHello(first, state: state, lastMseq: 0)
        let one = JournalBody(jseq: 1, sessionID: "session-1",
                              record: Data("one".utf8))
        try await first.send(try encodedFrame(.journal, seq: 2, payload: try one.encoded()))
        let firstAck = try JournalAckBody.decode(
            try await first.receiveFrame(timeout: 5).payload)
        XCTAssertEqual(firstAck.uptoJseq, 1)
        let storedBefore = await journal.storedAppends
        XCTAssertEqual(storedBefore, 1)
        first.close()

        let second = TestWebSocketClient(endpoint: endpoint)
        second.connect()
        addTeardownBlock { second.close() }
        _ = try await sendHello(second, state: state, lastMseq: 0)
        // Re-send jseq 1 (already persisted): acknowledged again, not appended.
        try await second.send(try encodedFrame(.journal, seq: 2, payload: try one.encoded()))
        let duplicateAck = try JournalAckBody.decode(
            try await second.receiveFrame(timeout: 5).payload)
        XCTAssertEqual(duplicateAck.uptoJseq, 1)
        let storedAfterDuplicate = await journal.storedAppends
        XCTAssertEqual(storedAfterDuplicate, storedBefore)
        // A new record continues from the persisted high-water mark.
        let two = JournalBody(jseq: 2, sessionID: "session-1",
                              record: Data("two".utf8))
        try await second.send(try encodedFrame(.journal, seq: 3, payload: try two.encoded()))
        let nextAck = try JournalAckBody.decode(
            try await second.receiveFrame(timeout: 5).payload)
        XCTAssertEqual(nextAck.uptoJseq, 2)
        let highest = await journal.highestJseq(sessionID: "session-1")
        XCTAssertEqual(highest, 2)
    }

    func testAppendBaseMismatchSendsVFSResyncOverWebSocket() async throws {
        // End-to-end channel path for channel.md §8: the workspace log reports
        // a base mismatch for an appended mutation (the W1-LOG materializer
        // owns detection) and the ordered channel answers with 0x13.
        let path = "/dsh/workspace/append.txt"
        let state = ChannelHostState(ackedMseq: 0, durableMseq: 0)
        let log = RecordingWorkspaceLog(nextMseq: 1, mismatchPaths: [path])
        let client = try await startChannelServer(
            state: state,
            routes: LoopbackRoutes(workspaceLog: log))
        _ = try await sendHello(client, state: state, lastMseq: 0)
        let mutation = VfsMutationBody(op: .write, mode: 0o644,
                                       mflags: [.entryChanged, .appended],
                                       appendFrom: 4, path: path,
                                       data: Data("tail".utf8))
        try await client.send(try encodedFrame(
            .vfsMutation, seq: 2,
            payload: try VfsMutationPayload.encode(mseq: 1, body: mutation)))
        var resync: VfsResyncBody?
        for _ in 0..<3 {
            let frame = try await client.receiveFrame(timeout: 5)
            if frame.type == .vfsResync {
                resync = try VfsResyncBody.decode(frame.payload)
                break
            }
        }
        XCTAssertEqual(resync?.path, path)
        let logged = await log.mutations
        XCTAssertEqual(logged.count, 1)
    }

    func testBadMutationPathsAreRejected() async throws {
        for path in ["/dshfoobar", "/dsh/tmp/x", "/dsh", "/dsh/home"] {
            let state = ChannelHostState()
            let client = try await startChannelServer(state: state)
            _ = try await sendHello(client, state: state, lastMseq: 0)
            let payload = rawMutationPayload(mseq: 1, path: path, data: Data("x".utf8))
            try await client.send(try encodedFrame(.vfsMutation, seq: 2, payload: payload))
            let error = try errorPayload(try await client.receiveFrame(timeout: 5))
            XCTAssertEqual(error.code, .badPath, "path \(path)")
        }
    }

    func testSixteenMiBFrameLimitIsEnforced() async throws {
        let state = ChannelHostState()
        let client = try await startChannelServer(state: state)
        _ = try await sendHello(client, state: state, lastMseq: 0)
        let header = rawFrameHeader(type: 0x10, seq: 2,
                                    length: UInt32(16 * 1024 * 1024 + 1))
        try await client.send(header)
        let error = try errorPayload(try await client.receiveFrame(timeout: 5))
        XCTAssertEqual(error.code, .badPayload)
    }

    func testSecondHelloIsProtoMismatch() async throws {
        let state = ChannelHostState()
        let client = try await startChannelServer(state: state)
        _ = try await sendHello(client, state: state, lastMseq: 0)
        let hello = try workerHelloPayload(state: state, lastMseq: 0)
        try await client.send(try encodeJSONFrame(.hello, seq: 2, value: hello))
        let error = try errorPayload(try await client.receiveFrame(timeout: 5))
        XCTAssertEqual(error.code, .protoMismatch)
    }
}

// Counting helpers kept in the test target to keep the recording actor small.
extension RecordingChannelHandler {
    var hellosCount: Int { hellos.count }
    var mutationCount: Int { mutations.count }
}

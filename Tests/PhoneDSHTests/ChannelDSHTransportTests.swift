// SPDX-License-Identifier: MIT
// DSHRemoteTransport contract tests over the ordered-channel seam.
//
// These tests do not need WebKit or a listener: a scripted PhoneDSHChannel
// stands in for one ChannelServer connection and records every API_REQ head
// and body, so the envelope mapping, streaming response, retry and remote.mux
// semantics are deterministic.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHLoopback
import PhoneDSHWire

final class ChannelDSHTransportTests: XCTestCase {
    private static func responseEvents(status: Int = 200, body: Data,
                                       reqID: UInt32 = 1) -> [ChannelAPIEvent] {
        [.response(reqID: reqID, status: status,
                   headers: ["content-type": "application/json"], body: body),
         .end(reqID: reqID)]
    }

    private static func serverResponse(rpcID: String, value: JSONValue) -> Data {
        (try? JSONValue.object([
            "type": .string("server-response"),
            "rpcId": .string(rpcID),
            "result": .object(["ok": .bool(true), "value": value]),
        ]).encoded()) ?? Data()
    }

    private func requestEnvelope(_ body: Data) -> JSONValue? {
        try? JSONValue.parse(body)
    }

    func testUnaryCallSendsClientRequestAndUnwrapsValue() async throws {
        let channel = FakeChannel { _, body in
            let envelope = (try? JSONValue.parse(body))
            let rpcID = envelope?["rpcId"]?.testString ?? ""
            let data = (try? JSONValue.object([
                "type": .string("server-response"),
                "rpcId": .string(rpcID),
                "result": .object(["ok": .bool(true),
                                   "value": .object(["sessionId": .string("s-1")])]),
            ]).encoded()) ?? Data()
            return [.response(reqID: 1, status: 200,
                              headers: ["content-type": "application/json"], body: data),
                    .end(reqID: 1)]
        }
        let transport = ChannelDSHTransport(channelProvider: { _ in channel })
        let args = JSONValue.object(["request": .object(["cwd": .string("/dsh/workspace")])])
        let value = try await transport.call("session/create", args: args)
        XCTAssertEqual(value["sessionId"]?.testString, "s-1")

        let request = try XCTUnwrap(channel.requests.first)
        XCTAssertEqual(request.head.method, "POST")
        XCTAssertEqual(request.head.path, "/api/session/create")
        XCTAssertEqual(request.head.headers["content-type"], "application/json")
        let envelope = try XCTUnwrap(requestEnvelope(request.body))
        XCTAssertEqual(envelope["type"]?.testString, "client-request")
        XCTAssertEqual(envelope["method"]?.testString, "session/create")
        XCTAssertNotNil(envelope["payload"]?["args"])
        XCTAssertEqual(envelope["payload"]?["args"], args)
        XCTAssertEqual(envelope["rpcId"]?.testString?.count, 36)
    }

    func testUnaryCallPropagatesRemoteError() async throws {
        let channel = FakeChannel { _, body in
            let envelope = (try? JSONValue.parse(body))
            let rpcID = envelope?["rpcId"]?.testString ?? ""
            let data = (try? JSONValue.object([
                "type": .string("server-response"),
                "rpcId": .string(rpcID),
                "result": .object([
                    "ok": .bool(false),
                    "error": .object(["code": .string("session/not-found"),
                                      "message": .string("gone")]),
                ]),
            ]).encoded()) ?? Data()
            return [.response(reqID: 1, status: 200,
                              headers: ["content-type": "application/json"], body: data),
                    .end(reqID: 1)]
        }
        let transport = ChannelDSHTransport(channelProvider: { _ in channel })
        do {
            _ = try await transport.call("session/cancel", args: JSONValue.object([:]))
            XCTFail("expected a remote error")
        } catch let error as DSHRemoteError {
            XCTAssertEqual(error.code, "session/not-found")
            XCTAssertEqual(error.message, "gone")
        }
    }

    func testUnaryCallReissuesAfterConnectionClosed() async throws {
        let first = FakeChannel { _, _ in
            [.abort(reqID: 1, reason: "connection_closed")]
        }
        let second = FakeChannel { _, body in
            let rpcID = (try? JSONValue.parse(body))?["rpcId"]?.testString ?? ""
            return Self.responseEvents(body: Self.serverResponse(rpcID: rpcID,
                                                                 value: .object(["ok": .bool(true)])))
        }
        let queue = ChannelQueue([first, second])
        let transport = ChannelDSHTransport(
            channelProvider: { excluding in try await queue.next(excluding: excluding) },
            configuration: .init(maximumAttempts: 3))
        let value = try await transport.call("session/create", args: JSONValue.object([:]))
        XCTAssertEqual(value["ok"]?.testBool, true)
        XCTAssertEqual(first.requests.count, 1)
        XCTAssertEqual(second.requests.count, 1)
        XCTAssertEqual(first.requests.first?.body, second.requests.first?.body)
        let exclusions = await queue.exclusions()
        XCTAssertTrue(exclusions.contains([first.id]))
    }

    func testUnaryCallStopsAfterMaximumAttempts() async throws {
        let first = FakeChannel { _, _ in [.abort(reqID: 1, reason: "connection_closed")] }
        let second = FakeChannel { _, _ in [.abort(reqID: 1, reason: "connection_closed")] }
        let queue = ChannelQueue([first, second])
        let transport = ChannelDSHTransport(
            channelProvider: { excluding in try await queue.next(excluding: excluding) },
            configuration: .init(maximumAttempts: 2))
        do {
            _ = try await transport.call("session/create", args: JSONValue.object([:]))
            XCTFail("expected channelUnavailable")
        } catch let error as PhoneDSHError {
            XCTAssertEqual(error, .channelUnavailable)
        }
        XCTAssertEqual(first.requests.count, 1)
        XCTAssertEqual(second.requests.count, 1)
    }

    func testUnauthorizedResponseIsProviderUnauthorized() async throws {
        let channel = FakeChannel { _, _ in
            [.response(reqID: 1, status: 401, headers: [:], body: Data()),
             .end(reqID: 1)]
        }
        let transport = ChannelDSHTransport(channelProvider: { _ in channel })
        do {
            _ = try await transport.call("session/create", args: JSONValue.object([:]))
            XCTFail("expected unauthorized")
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMuxSendUsesMuxHeadersAndFrameBody() async throws {
        let channel = FakeChannel { _, _ in
            [.response(reqID: 1, status: 204, headers: [:], body: Data()),
             .end(reqID: 1)]
        }
        let transport = ChannelDSHTransport(channelProvider: { _ in channel })
        let mux = try await transport.openMux()
        let frame = JSONValue.object([
            "type": .string("open"),
            "streamId": .string("follow"),
        ])
        try await mux.send(frame)
        let request = try XCTUnwrap(channel.requests.first)
        XCTAssertEqual(request.head.path, PhoneDSHMuxProtocol.path)
        XCTAssertEqual(request.head.headers[PhoneDSHMuxProtocol.operationHeader],
                       PhoneDSHMuxProtocol.sendOperation)
        let muxID = try XCTUnwrap(request.head.headers[PhoneDSHMuxProtocol.muxIDHeader])
        XCTAssertEqual(muxID.count, 32)
        XCTAssertTrue(muxID.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        let decoded = try JSONValue.parse(request.body)
        XCTAssertEqual(decoded, frame)
        await mux.close()
    }

    func testMuxReceiveStreamsNewlineDelimitedFrames() async throws {
        let first = JSONValue.object(["type": .string("item"), "streamId": .string("events")])
        let second = JSONValue.object(["type": .string("end"), "streamId": .string("events")])
        var chunk = try first.encoded()
        chunk.append(0x0A)
        chunk.append(try second.encoded())
        chunk.append(0x0A)
        let channel = FakeChannel { _, _ in
            [.response(reqID: 1, status: 200,
                       headers: ["content-type": PhoneDSHMuxProtocol.ndjsonContentType],
                       body: chunk),
             .end(reqID: 1)]
        }
        let transport = ChannelDSHTransport(channelProvider: { _ in channel })
        let mux = try await transport.openMux()
        let one = try await mux.receive()
        let two = try await mux.receive()
        let three = try await mux.receive()
        XCTAssertEqual(one, first)
        XCTAssertEqual(two, second)
        XCTAssertNil(three)
        await mux.close()
    }

    func testMuxReceiveReturnsNilOnConnectionClosed() async throws {
        let channel = FakeChannel { _, _ in
            [.abort(reqID: 1, reason: "connection_closed")]
        }
        let transport = ChannelDSHTransport(channelProvider: { _ in channel })
        let mux = try await transport.openMux()
        let frame = try await mux.receive()
        XCTAssertNil(frame)
    }

    func testMuxCloseSendsCloseOperation() async throws {
        let channel = FakeChannel { _, _ in
            [.response(reqID: 1, status: 204, headers: [:], body: Data()),
             .end(reqID: 1)]
        }
        let transport = ChannelDSHTransport(channelProvider: { _ in channel })
        let mux = try await transport.openMux()
        await mux.close()
        try await waitUntil {
            channel.requests.contains {
                $0.head.headers[PhoneDSHMuxProtocol.operationHeader]
                    == PhoneDSHMuxProtocol.closeOperation
            }
        }
    }

    func testOpenMuxFailsWhenNoChannelIsAvailable() async throws {
        struct NoChannel: Error {}
        let transport = ChannelDSHTransport(channelProvider: { _ in throw NoChannel() })
        do {
            _ = try await transport.openMux()
            XCTFail("expected unavailable")
        } catch let error as ProviderError {
            guard case .unavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAuthenticationFailedIsANoOp() async {
        let transport = ChannelDSHTransport(channelProvider: { _ in
            FakeChannel { _, _ in [] }
        })
        await transport.authenticationFailed()
    }

    func testChannelRequestsCarryNoCookieOrLaunchToken() async throws {
        let channel = FakeChannel { _, body in
            let rpcID = (try? JSONValue.parse(body))?["rpcId"]?.testString ?? ""
            return Self.responseEvents(body: Self.serverResponse(
                rpcID: rpcID, value: .object(["ok": .bool(true)])))
        }
        let transport = ChannelDSHTransport(channelProvider: { _ in channel })
        _ = try await transport.call("session/create", args: JSONValue.object([:]))
        let mux = try await transport.openMux()
        try await mux.send(JSONValue.object(["type": .string("ping")]))
        await mux.close()

        XCTAssertFalse(channel.requests.isEmpty)
        for request in channel.requests {
            let names = Set(request.head.headers.keys.map { $0.lowercased() })
            XCTAssertFalse(names.contains("cookie"))
            XCTAssertFalse(names.contains("authorization"))
            XCTAssertFalse(names.contains("x-pdsh-launch-token"))
            XCTAssertFalse(names.contains("set-cookie"))
        }
        // D23/W1-MUX: the documented mux headers are unchanged.
        let send = try XCTUnwrap(channel.requests.first {
            $0.head.headers[PhoneDSHMuxProtocol.operationHeader]
                == PhoneDSHMuxProtocol.sendOperation
        })
        XCTAssertEqual(send.head.path, PhoneDSHMuxProtocol.path)
        XCTAssertEqual(send.head.headers[PhoneDSHMuxProtocol.muxIDHeader]?.count, 32)
        XCTAssertEqual(send.head.headers[PhoneDSHMuxProtocol.contentTypeHeader],
                       PhoneDSHMuxProtocol.jsonContentType)
    }
}

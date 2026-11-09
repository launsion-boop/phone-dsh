// SPDX-License-Identifier: MIT
// Regression for the sunk session-history reader: it must send the DSH
// 0.2.2-rc.1 gateway-legal argument shapes, not the old App shapes.

import Foundation
import PhoneDSHAgentCore
import ProbeKit
import XCTest

private actor FakeHistoryMux: DSHMuxConnection {
    private(set) var sent: [JSONValue] = []
    private var queued: [JSONValue] = []
    private let snapshot: JSONValue

    init(snapshot: JSONValue) {
        self.snapshot = snapshot
    }

    func send(_ frame: JSONValue) async throws {
        sent.append(frame)
        guard frame["endpoint"]?.stringValue == "session/follow",
              let streamID = frame["streamId"]?.stringValue else { return }
        queued.append(.object([
            "streamId": .string(streamID),
            "type": .string("item"),
            "value": snapshot,
        ]))
    }

    func receive() async throws -> JSONValue? {
        queued.isEmpty ? nil : queued.removeFirst()
    }

    func close() async {}
}

private actor FakeHistoryTransport: DSHRemoteTransport {
    private let mux: FakeHistoryMux
    private let responses: [String: JSONValue]
    private let failing: Set<String>
    private var calls: [(String, JSONValue)] = []

    init(mux: FakeHistoryMux, responses: [String: JSONValue], failing: Set<String> = []) {
        self.mux = mux
        self.responses = responses
        self.failing = failing
    }

    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        calls.append((endpoint, args))
        if failing.contains(endpoint) { throw FakeHistoryError.injected }
        return responses[endpoint] ?? .object([:])
    }

    func openMux() async throws -> any DSHMuxConnection { mux }

    func recordedCalls() -> [(String, JSONValue)] { calls }
}

private enum FakeHistoryError: Error, Equatable { case injected }

@MainActor
final class ProbeKitHistoryTests: XCTestCase {
    private let snapshot: JSONValue = .object([
        "type": .string("snapshot"),
        "cursor": .number(3),
        "projections": .object(["values": .object(["inbox": .object([:])])]),
    ])

    private func records() -> JSONValue {
        .array([
            .object([
                "seq": .number(1), "type": .string("turn/start"),
                "time": .number(1_700_000_000_000),
                "data": .object(["turn": .number(1)]),
            ]),
            .object([
                "seq": .number(2), "type": .string("user/message"),
                "time": .number(1_700_000_001_000),
                "data": .object(["turn": .number(1), "content": .array([
                    .object(["type": .string("text"), "text": .string("只回复 OK")]),
                ])]),
            ]),
            .object([
                "seq": .number(3), "type": .string("turn/end"),
                "time": .number(1_700_000_002_000),
                "data": .object(["turn": .number(1), "reason": .object([
                    "kind": .string("completed"),
                ])]),
            ]),
        ])
    }

    func testLoadSendsGatewayLegalWireShapesAndProjectsRawRecords() async throws {
        let mux = FakeHistoryMux(snapshot: snapshot)
        let transport = FakeHistoryTransport(mux: mux, responses: [
            "session/page": .object([
                "records": .array(records().arrayValue?.map { .object(["event": $0]) } ?? []),
                "hasMore": .bool(false),
            ]),
            "session/list": .object(["items": .array([
                .object(["sessionId": .string("session-a"), "running": .bool(true)]),
            ])]),
        ])

        let history = try await SessionHistoryReader.load(sessionID: "session-a", transport: transport)

        XCTAssertEqual(history.cursor, 3)
        XCTAssertEqual(history.throughSeq, 3)
        XCTAssertEqual(history.after, 31)
        XCTAssertEqual(history.records.count, 3)
        XCTAssertEqual(history.running, true)
        XCTAssertFalse(history.inferredTurnRunning)
        XCTAssertEqual(history.turnFacts.starts.count, 1)
        XCTAssertEqual(history.turnFacts.endReasons[1], "completed")
        XCTAssertTrue(history.diagnostics.isEmpty)

        let sent = await mux.sent
        let open = try XCTUnwrap(sent.first)
        XCTAssertEqual(open["endpoint"]?.stringValue, "session/follow")
        let request = try XCTUnwrap(open["payload"]?["args"]?["request"])
        XCTAssertNil(request["assistantStream"], "the pin accepts only literal true; the reader must omit it")
        XCTAssertEqual(request["maxMessages"]?.intValue, 1)

        let calls = await transport.recordedCalls()
        let list = try XCTUnwrap(calls.first { $0.0 == "session/list" })
        XCTAssertEqual(list.1, .object(["_request": .object([:])]),
                       "session/list must carry the reserved _request member")
        XCTAssertEqual(list.1.objectValue?.keys.sorted(), ["_request"])
        let page = try XCTUnwrap(calls.first { $0.0 == "session/page" })
        XCTAssertEqual(page.1["request"]?["address"]?["sessionId"]?.stringValue, "session-a")
    }

    func testOptionalRunningProbeFailureKeepsInferredStateAndLogs() async throws {
        let mux = FakeHistoryMux(snapshot: .object([
            "type": .string("snapshot"), "cursor": .number(2),
        ]))
        let transport = FakeHistoryTransport(
            mux: mux,
            responses: ["session/page": .object([
                "records": .array(records().arrayValue?.map { .object(["event": $0]) } ?? []),
            ])],
            failing: ["session/list"])

        let history = try await SessionHistoryReader.load(sessionID: "session-a", transport: transport)

        XCTAssertNil(history.running, "a failed optional probe keeps the previous fallback")
        XCTAssertFalse(history.inferredTurnRunning)
        XCTAssertEqual(history.turnFacts.endReasons[1], "completed")
        XCTAssertEqual(history.diagnostics.count, 1)
        XCTAssertTrue(history.diagnostics[0].contains("session/list"))
    }

    func testRequireRunningStateFailsWhenListCannotConfirm() async throws {
        let mux = FakeHistoryMux(snapshot: snapshot)
        let transport = FakeHistoryTransport(mux: mux, responses: [
            "session/list": .object(["items": .array([])]),
        ])

        do {
            _ = try await SessionHistoryReader.load(
                sessionID: "session-a", transport: transport, requireRunningState: true)
            XCTFail("an authoritative running state is required on this path")
        } catch let error as ProviderError {
            guard case .invalidResponse(let message) = error else {
                XCTFail("expected an invalidResponse for a missing authoritative state, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("running state"))
        }
    }

    func testFollowCursorUsesNoAssistantStreamMember() async throws {
        let mux = FakeHistoryMux(snapshot: snapshot)
        let transport = FakeHistoryTransport(mux: mux, responses: [:])

        let cursor = try await SessionHistoryReader.followCursor(sessionID: "session-a", transport: transport)

        XCTAssertEqual(cursor, 3)
        let sent = await mux.sent
        XCTAssertNil(sent.first?["payload"]?["args"]?["request"]?["assistantStream"])
    }
}

@MainActor
final class ProbeKitManagementTests: XCTestCase {
    func testDecodeSessionsUsesProjectionThenHintThenDefaultName() {
        let value: JSONValue = .object(["items": .array([
            .object([
                "sessionId": .string("projected"),
                "updatedAt": .number(2_000),
                "projections": .object(["values": .object(["title": .string("Host title")])]),
            ]),
            .object(["sessionId": .string("hinted"), "updatedAt": .number(1_000)]),
            .object(["sessionId": .string("blank"), "updatedAt": .number(500), "blank": .bool(true)]),
            .object(["sessionId": .string("plain"), "updatedAt": .number(400)]),
        ])])

        let sessions = ManagementDecoding.decodeSessions(
            value, titleHint: { $0 == "hinted" ? "Local hint" : nil })

        XCTAssertEqual(sessions.map(\.id), ["projected", "hinted", "blank", "plain"])
        XCTAssertEqual(sessions[0].title, "Host title")
        XCTAssertEqual(sessions[1].title, "Local hint")
        XCTAssertEqual(sessions[2].title, ManagementDecoding.newSessionName)
        XCTAssertEqual(sessions[3].title, ManagementDecoding.untitledSessionName)
        XCTAssertFalse(sessions[3].running)
    }

    func testDecodeWorkspaceKeepsAppPolicyOutsideTheLibraryDecoder() {
        let value: JSONValue = .object([
            "workspaceId": .string("w1"),
            "title": .string("Workspace"),
            "path": .string("/dsh/workspace"),
            "sessionIds": .array([.string("keep"), .string("bot")]),
        ])

        let plain = ManagementDecoding.decodeWorkspace(value)
        XCTAssertEqual(plain?.sessionIDs, ["keep", "bot"])

        let filtered = ManagementDecoding.decodeWorkspace(value, isExcludedSessionID: { $0 == "bot" })
        XCTAssertEqual(filtered?.sessionIDs, ["keep"])
    }

    func testBackendIDStorageScopeIsStable() {
        XCTAssertEqual(BackendID.phone.storageScope, "phone")
        XCTAssertEqual(BackendID.pc(machineId: "abc").storageScope, "pc:abc")
    }
}

@MainActor
final class ProbeKitBackendTests: XCTestCase {
    func testPhoneBackendDelegatesTransportAndCapabilities() async throws {
        let transport = FakeHistoryTransport(
            mux: FakeHistoryMux(snapshot: .object(["type": .string("snapshot"), "cursor": .number(0)])),
            responses: [:])
        let backend = PhoneWorkspaceBackend(
            displayName: "Test phone",
            lifecycle: PhoneWorkspaceBackendLifecycle(
                pause: {}, resume: {}, startKeepAlive: {}, stopKeepAlive: {}),
            transport: { transport },
            harness: { throw FakeHistoryError.injected })

        XCTAssertEqual(backend.id, .phone)
        XCTAssertEqual(backend.displayName, "Test phone")
        XCTAssertTrue(backend.capabilities.phoneOnlyEndpoints)
        XCTAssertTrue(backend.capabilities.supportsHostLifecycle)
        XCTAssertTrue(backend.capabilities.localFilePreview)
        XCTAssertTrue(backend.lifecycle.supportsHostPause)
        XCTAssertTrue(backend.lifecycle.supportsKeepAlive)

        let returned = try await backend.transport()
        XCTAssertTrue(returned is FakeHistoryTransport)

        do {
            _ = try await backend.harness()
            XCTFail("the injected harness failure must surface")
        } catch let error as FakeHistoryError {
            XCTAssertEqual(error, .injected)
        }
    }
}

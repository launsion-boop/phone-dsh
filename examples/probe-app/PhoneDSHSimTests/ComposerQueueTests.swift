// SPDX-License-Identifier: MIT
// Composer queue merge/filter/store regression tests.
//
// These exercise the exact production store used by `ChatPage`: durable
// `inbox["next-turn"]` rows, local rows keyed by `source.rpcId`, refresh after
// success/failure and the silent steer convergence codes.

import Foundation
import PhoneDSHAgentCore
import ProbeKit
import XCTest

@MainActor
final class ComposerQueueTests: XCTestCase {
    // MARK: - Pairing

    func testDurableEchoRetiresLocalLineAndKeepsInboxIdentity() {
        let durable = [item(id: "inbox-1", requestID: "rpc-1", text: "run tests")]
        let local = [line(id: "local-1", requestID: "rpc-1", text: "run tests")]

        let rows = ComposerQueue.rows(durable: durable, local: local,
                                      acknowledgedRequestIDs: ["rpc-1"], running: true)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "durable:inbox-1")
        XCTAssertEqual(rows[0].item?.id, "inbox-1", "the durable inbox id drives updateQueue")
        XCTAssertEqual(rows[0].item?.requestID, "rpc-1")
        XCTAssertTrue(rows[0].editable)
        XCTAssertTrue(rows[0].canSteer)
    }

    func testIdenticalTextFromDifferentRequestsStaysTwoRows() {
        let durable = [item(id: "inbox-1", requestID: "rpc-1", text: "same words")]
        let local = [line(id: "local-2", requestID: "rpc-2", text: "same words")]

        let rows = ComposerQueue.rows(durable: durable, local: local,
                                      acknowledgedRequestIDs: [], running: false)

        XCTAssertEqual(rows.count, 2, "pairing by text would wrongly collapse two submissions")
        XCTAssertEqual(rows[0].item?.id, "inbox-1")
        XCTAssertNil(rows[1].item, "the second local line has not landed yet")
        XCTAssertFalse(rows[1].editable)
        XCTAssertFalse(rows[1].canSteer)
    }

    func testMergeIgnoresNextStepDurablesEvenIfPassedDirectly() {
        let rows = ComposerQueue.rows(durable: [item(id: "step-1", requestID: "rpc-step",
                                                      text: "being consumed", lane: "next-step")],
                                      local: [], acknowledgedRequestIDs: [], running: true)
        XCTAssertTrue(rows.isEmpty,
                      "next-step belongs to the transcript, not the composer dock")
    }

    func testConsumedDurableRowDoesNotResurrectItsLocalLine() {
        let local = [line(id: "local-1", requestID: "rpc-1", text: "run tests")]

        let rows = ComposerQueue.rows(durable: [], local: local,
                                      acknowledgedRequestIDs: ["rpc-1"], running: true)

        XCTAssertTrue(rows.isEmpty, "the rpcId was echoed and then claimed; no ghost row")
    }

    func testTurnEndKeepsDurableRowsWhileLocalLabelsDisappear() {
        let durable = [item(id: "inbox-2", requestID: "rpc-2", text: "still queued")]
        let localAfterTurnEnd: [ComposerQueue.LocalLine] = []

        let rows = ComposerQueue.rows(durable: durable, local: localAfterTurnEnd,
                                      acknowledgedRequestIDs: ["rpc-2"], running: false)

        XCTAssertEqual(rows.map(\.item?.id), ["inbox-2"],
                       "clearing local labels must not clear the server queue")
        XCTAssertFalse(rows[0].canSteer, "idle turns cannot steer")
    }

    // MARK: - Projection decoding / refresh

    func testRefreshReadsOnlyNextTurnAndKeepsTextMetadata() async {
        let transport = QueueTransport(projections: projections(
            nextTurn: [
                inboxItem(id: "q1", requestID: "r1", text: "first"),
                inboxItem(id: "q2", requestID: "r2", text: "with image", image: true),
            ],
            nextStep: [inboxItem(id: "step-1", requestID: "r3", text: "being consumed")]))
        let store = ComposerQueueStore()
        store.prepare(for: "session")

        let refreshed = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(refreshed)

        let rows = store.rows(for: "session", local: [], running: true)
        XCTAssertEqual(rows.map(\.item?.id), ["q1", "q2"],
                       "next-step entries belong to the transcript/steering path, not the dock")
        XCTAssertTrue(rows[0].editable)
        XCTAssertFalse(rows[1].editable, "image entries cannot be edited as text")
        XCTAssertEqual(rows[1].item?.isPlainText, false)
    }

    func testRefreshSurfacesPersistentRowForAnUnpairedLocalLine() async {
        let transport = QueueTransport(projections: projections(nextTurn: []))
        let store = ComposerQueueStore()
        store.prepare(for: "session")
        let local = [line(id: "local-1", requestID: "rpc-1", text: "run tests")]

        let before = store.rows(for: "session", local: local, running: false)
        XCTAssertEqual(before.count, 1)
        XCTAssertNil(before[0].item, "phase (a): not durable yet")

        await transport.setProjections(projections(nextTurn: [
            inboxItem(id: "inbox-1", requestID: "rpc-1", text: "run tests"),
        ]))
        let refreshed = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(refreshed)

        let after = store.rows(for: "session", local: local, running: false)
        XCTAssertEqual(after.map(\.item?.id), ["inbox-1"])
        XCTAssertEqual(after.count, 1, "the local line is retired by its request id")
    }

    func testConsumedEntryDisappearsAfterRefresh() async {
        let transport = QueueTransport(projections: projections(nextTurn: [
            inboxItem(id: "q1", requestID: "r1", text: "first"),
            inboxItem(id: "q2", requestID: "r2", text: "second"),
        ]))
        let store = ComposerQueueStore()
        store.prepare(for: "session")
        let firstRefresh = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(firstRefresh)
        XCTAssertEqual(store.rows(for: "session", local: [], running: true).count, 2)

        await transport.setProjections(projections(nextTurn: [
            inboxItem(id: "q2", requestID: "r2", text: "second"),
        ]))
        let secondRefresh = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(secondRefresh)
        XCTAssertEqual(store.rows(for: "session", local: [], running: true).map(\.item?.id), ["q2"])

        await transport.setProjections(projections(nextTurn: []))
        let finalRefresh = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(finalRefresh)
        XCTAssertTrue(store.rows(for: "session", local: [], running: true).isEmpty)
    }

    func testInFlightSessionChangeIsNeverOverwrittenByTheOldQueue() async {
        let transport = QueueTransport(projections: projections(nextTurn: [
            inboxItem(id: "old", requestID: "rpc-old", text: "old session"),
        ]))
        let store = ComposerQueueStore()
        store.prepare(for: "session-a")

        let refreshed = await store.refresh(sessionID: "session-b", using: transport)
        XCTAssertFalse(refreshed, "a stale refresh must not switch the store to another session")
        XCTAssertEqual(store.sessionID, "session-a")
        XCTAssertTrue(store.items.isEmpty)
        let projectionCalls = await transport.projectionCalls
        XCTAssertEqual(projectionCalls, 0)

        let removed = await store.perform(.remove,
                                          on: item(id: "old", requestID: "rpc-old", text: "old session"),
                                          sessionID: "session-b", using: transport)
        XCTAssertFalse(removed.succeeded)
        XCTAssertNil(removed.visibleError, "a cross-session action is dropped without a notice")
        let sent = await transport.lastCall(to: "session/updateQueue")
        XCTAssertNil(sent, "a cross-session action must not reach updateQueue")
        XCTAssertEqual(store.sessionID, "session-a")
    }

    // MARK: - Actions and failures

    func testRemoveSendsInboxIDThenRefreshesTheConsumedRowAway() async {
        let transport = QueueTransport(projections: projections(nextTurn: [
            inboxItem(id: "inbox-1", requestID: "rpc-1", text: "run tests"),
        ]))
        let store = ComposerQueueStore()
        store.prepare(for: "session")
        let refreshed = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(refreshed)
        await transport.succeedUpdate(projectionsAfter: projections(nextTurn: []))

        let result = await store.perform(.remove, on: store.items[0], sessionID: "session",
                                         using: transport)

        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.visibleError)
        XCTAssertTrue(store.rows(for: "session", local: [], running: true).isEmpty)
        let call = await transport.lastCall(to: "session/updateQueue")
        XCTAssertEqual(call?["request"]?["sessionId"]?.stringValue, "session")
        XCTAssertEqual(call?["request"]?["itemId"]?.stringValue, "inbox-1")
        XCTAssertEqual(call?["request"]?["action"]?["kind"]?.stringValue, "remove")
    }

    func testEditSendsTextContent() async {
        let transport = QueueTransport(projections: projections(nextTurn: [
            inboxItem(id: "inbox-1", requestID: "rpc-1", text: "old"),
        ]))
        let store = ComposerQueueStore()
        store.prepare(for: "session")
        let refreshed = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(refreshed)
        await transport.succeedUpdate(projectionsAfter: projections(nextTurn: [
            inboxItem(id: "inbox-1", requestID: "rpc-1", text: "new"),
        ]))

        let result = await store.perform(.edit("new"), on: store.items[0], sessionID: "session",
                                         using: transport)

        XCTAssertTrue(result.succeeded)
        let call = await transport.lastCall(to: "session/updateQueue")
        XCTAssertEqual(call?["request"]?["action"]?["kind"]?.stringValue, "edit")
        XCTAssertEqual(call?["request"]?["action"]?["content"]?.arrayValue?[0]["type"]?.stringValue, "text")
        XCTAssertEqual(call?["request"]?["action"]?["content"]?.arrayValue?[0]["text"]?.stringValue, "new")
        XCTAssertEqual(store.items.first?.text, "new")
    }

    func testNotFoundRemoveDropsGhostRowAndShowsFailure() async {
        let transport = QueueTransport(projections: projections(nextTurn: [
            inboxItem(id: "inbox-1", requestID: "rpc-1", text: "claimed"),
        ]))
        let store = ComposerQueueStore()
        store.prepare(for: "session")
        let refreshed = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(refreshed)
        // The entry was already claimed, so a later projection is empty; make
        // that follow-up refresh fail to prove the local removal happens first.
        await transport.setProjections(projections(nextTurn: []))
        await transport.failProjections(DSHRemoteError(code: "gateway/http-503", message: "offline"))
        await transport.failUpdate(DSHRemoteError(code: "session/queue-item-not-found",
                                                  message: "already claimed"))

        let result = await store.perform(.remove, on: store.items[0], sessionID: "session",
                                         using: transport)

        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.visibleError, "edit/remove failures must reach the chat page")
        XCTAssertEqual(result.visibleError, store.lastError)
        XCTAssertEqual(result.visibleError, "删除排队消息失败：这条消息已经不在队列里了")
        XCTAssertTrue(store.items.isEmpty, "the consumed row is removed even when that refresh fails")
        XCTAssertTrue(store.rows(for: "session", local: [], running: true).isEmpty)

        await transport.failProjections(nil)
        let recovered = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(recovered)
        XCTAssertTrue(store.items.isEmpty, "a later successful refresh must not resurrect the ghost")
    }

    func testEditFailureIsVisibleAndKeepsTheRow() async {
        let transport = QueueTransport(projections: projections(nextTurn: [
            inboxItem(id: "inbox-1", requestID: "rpc-1", text: "with image", image: true),
        ]))
        let store = ComposerQueueStore()
        store.prepare(for: "session")
        let refreshed = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(refreshed)
        await transport.failUpdate(DSHRemoteError(code: "session/attachment-invalid",
                                                  message: "content is not text"))

        let result = await store.perform(.edit("new"), on: store.items[0], sessionID: "session",
                                         using: transport)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.visibleError, "编辑排队消息失败：包含非文本内容，不能编辑")
        XCTAssertEqual(store.items.map(\.id), ["inbox-1"], "a failed edit leaves the entry queued")
    }

    func testBothSteerConvergenceCodesAreSilentButEditAndRemoveAreNot() {
        for code in ["session/steer-unavailable", "session/queue-item-not-found"] {
            let error = DSHRemoteError(code: code, message: "gone")
            XCTAssertTrue(ComposerQueue.isSilentSteerFailure(.steer, error: error))
            XCTAssertFalse(ComposerQueue.isSilentSteerFailure(.edit("new"), error: error))
            XCTAssertFalse(ComposerQueue.isSilentSteerFailure(.remove, error: error))
        }
    }

    func testSteerConvergenceCodesAreSilentButRefreshStillRuns() async {
        let transport = QueueTransport(projections: projections(nextTurn: [
            inboxItem(id: "inbox-1", requestID: "rpc-1", text: "queued"),
        ]))
        let store = ComposerQueueStore()
        store.prepare(for: "session")
        let refreshed = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(refreshed)
        await transport.failUpdate(DSHRemoteError(code: "session/steer-unavailable",
                                                  message: "turn ended"))
        let before = await transport.projectionCalls

        let result = await store.perform(.steer, on: store.items[0], sessionID: "session",
                                         using: transport)

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.visibleError, "steer-unavailable converges silently like official QueueDock")
        XCTAssertNil(store.lastError)
        let after = await transport.projectionCalls
        XCTAssertEqual(after, before + 1, "a failed action still re-reads the inbox")
        XCTAssertEqual(store.items.map(\.id), ["inbox-1"], "the still-queued row remains")
    }

    func testSteerNotFoundConvergesSilentlyAndRemovesTheClaimedRow() async {
        let transport = QueueTransport(projections: projections(nextTurn: [
            inboxItem(id: "inbox-1", requestID: "rpc-1", text: "claimed"),
        ]))
        let store = ComposerQueueStore()
        store.prepare(for: "session")
        let refreshed = await store.refresh(sessionID: "session", using: transport)
        XCTAssertTrue(refreshed)
        await transport.setProjections(projections(nextTurn: []))
        await transport.failUpdate(DSHRemoteError(code: "session/queue-item-not-found",
                                                  message: "already claimed"))

        let result = await store.perform(.steer, on: store.items[0], sessionID: "session",
                                         using: transport)

        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.visibleError, "a claimed steer converges silently")
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.items.isEmpty, "the claimed row must not linger")
    }
}

// MARK: - Fixtures

private enum ComposerQueueTestError: Error {
    case noMux
}

private actor QueueTransport: DSHRemoteTransport {
    private enum Update {
        case success(JSONValue?)
        case failure(DSHRemoteError)
    }

    private var projections: JSONValue
    private var projectionsFailure: DSHRemoteError?
    private var update: Update = .success(nil)
    private var calls: [(endpoint: String, args: JSONValue)] = []
    private(set) var projectionCalls = 0

    init(projections: JSONValue) {
        self.projections = projections
    }

    func setProjections(_ value: JSONValue) {
        projections = value
    }

    func succeedUpdate(projectionsAfter: JSONValue?) {
        update = .success(projectionsAfter)
    }

    func failProjections(_ error: DSHRemoteError?) {
        projectionsFailure = error
    }

    func failUpdate(_ error: DSHRemoteError) {
        update = .failure(error)
    }

    func lastCall(to endpoint: String) -> JSONValue? {
        calls.last(where: { $0.endpoint == endpoint })?.args
    }

    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        calls.append((endpoint, args))
        switch endpoint {
        case "session/projections":
            projectionCalls += 1
            if let projectionsFailure { throw projectionsFailure }
            return projections
        case "session/updateQueue":
            switch update {
            case .success(let after):
                if let after { projections = after }
                return .object(["ok": .bool(true)])
            case .failure(let error):
                throw error
            }
        default:
            return .object([:])
        }
    }

    func openMux() async throws -> any DSHMuxConnection {
        throw ComposerQueueTestError.noMux
    }
}

@MainActor
private func projections(nextTurn: [JSONValue], nextStep: [JSONValue] = []) -> JSONValue {
    .object(["values": .object(["inbox": .object([
        "next-turn": .array(nextTurn),
        "next-step": .array(nextStep),
    ])])])
}

private func inboxItem(id: String, requestID: String?, text: String,
                       image: Bool = false) -> JSONValue {
    var content: [JSONValue] = [
        .object(["type": .string("text"), "text": .string(text)]),
    ]
    if image {
        content.append(.object(["type": .string("image"), "name": .string("photo.png"),
                                "mediaType": .string("image/png"), "path": .string("/images/photo.png")]))
    }
    var source: [String: JSONValue] = ["kind": .string("user")]
    if let requestID { source["rpcId"] = .string(requestID) }
    return .object([
        "id": .string(id),
        "content": .array(content),
        "source": .object(source),
    ])
}

@MainActor
private func item(id: String, requestID: String?, text: String,
                  lane: String = "next-turn") -> ComposerQueue.Item {
    ComposerQueue.Item(id: id, sessionID: "session", lane: lane, text: text,
                       isPlainText: true, requestID: requestID)
}

@MainActor
private func line(id: String, requestID: String?, text: String,
                  state: ComposerQueue.State = .queued) -> ComposerQueue.LocalLine {
    ComposerQueue.LocalLine(id: id, text: text, state: state, requestID: requestID)
}

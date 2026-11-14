// SPDX-License-Identifier: MIT
import PhoneDSHAgentCore
import Observation
import XCTest
@testable import PhoneDSHProbe

/// Hosted tests also run on a simulator. Exercise ChatModel.handle, not a
/// second implementation of the accumulator that could hide caller bugs.
@MainActor
final class ChatStreamingBoundaryTests: XCTestCase {
    private final class ChangeFlag: @unchecked Sendable {
        // Observation calls onChange synchronously inside this MainActor test.
        var changed = false
    }

    private func send(_ kind: HarnessEvent.Kind, to model: ChatModel) {
        model.debugHandleHarnessEvent(HarnessEvent(seq: nil, time: Date(), kind: kind))
    }

    func testAssistantBurstWaitsForOneDisplayFlush() {
        let model = ChatModel()
        send(.assistantDelta(text: "start"), to: model)
        let revision = model.itemsRevision
        for _ in 0..<500 { send(.assistantDelta(text: "中🙂"), to: model) }
        XCTAssertEqual(model.itemsRevision, revision,
                       "token delivery must not bypass the display timer")
        XCTAssertEqual(model.items.last?.text, "")
        model.flushStreamingText()
        XCTAssertEqual(model.items.last?.text, "start" + String(repeating: "中🙂", count: 500))
        XCTAssertTrue(model.items.last?.streaming == true)
        print("STREAM-PERF assistant burst=501 publishes=\(model.itemsRevision - revision)")
    }

    func testReasoningTransitionFlushesOnceThenAssistantCoalesces() {
        let model = ChatModel()
        send(.reasoningDelta(text: "think"), to: model)
        send(.reasoningDelta(text: " first"), to: model)
        send(.assistantDelta(text: "answer"), to: model)
        XCTAssertEqual(model.items.first?.text, "think first")
        XCTAssertFalse(model.items.first?.streaming ?? true)
        let revision = model.itemsRevision
        send(.assistantDelta(text: " continues"), to: model)
        XCTAssertEqual(model.itemsRevision, revision)
        model.flushStreamingText()
        XCTAssertEqual(model.items.last?.text, "answer continues")
    }

    func testToolBoundaryFlushesTextInOrder() {
        let model = ChatModel()
        send(.assistantDelta(text: "before "), to: model)
        send(.assistantDelta(text: "tool"), to: model)
        send(.toolCall(callID: "call-1", name: "bash", arguments: .object([:])), to: model)
        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.items.first?.text, "before tool")
        XCTAssertFalse(model.items.first?.streaming ?? true)
        XCTAssertEqual(model.items.last?.callID, "call-1")
    }

    func testStreamingDoesNotInvalidateUnchangedComposerQueue() {
        for state in ["empty", "已排队", "已并入当前任务"] {
            let model = ChatModel()
            if state != "empty" {
                model.debugInstallPreviewState(failedItemID: nil, error: nil, queue: ["input": state])
            }
            send(.assistantDelta(text: "a"), to: model)
            let flag = ChangeFlag()
            withObservationTracking {
                _ = model.queueLineOrder
                _ = model.queueLines
            } onChange: { flag.changed = true }
            send(.assistantDelta(text: "b"), to: model)
            XCTAssertFalse(flag.changed, "unchanged \(state) queue must not invalidate the composer per token")
            model.flushStreamingText()
        }
    }

    func testFirstActivityClearsSendingButPreservesQueuedInput() {
        let model = ChatModel()
        model.debugInstallPreviewState(failedItemID: nil, error: nil,
                                       queue: ["sent": "发送中…", "next": "已排队"])
        send(.assistantDelta(text: "a"), to: model)
        XCTAssertNil(model.queueLines["sent"])
        XCTAssertEqual(model.queueLines["next"], .queued)
        XCTAssertEqual(model.queueLineOrder, ["next"])
        model.flushStreamingText()
    }

    func testDurableMessageReplacesPendingDraftWithoutDuplication() {
        let model = ChatModel()
        send(.assistantDelta(text: "partial"), to: model)
        send(.assistantDelta(text: " draft"), to: model)
        send(.assistantMessage(text: "authoritative answer"), to: model)
        model.flushStreamingText()
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.last?.text, "authoritative answer")
        XCTAssertFalse(model.items.last?.streaming ?? true)
    }
}

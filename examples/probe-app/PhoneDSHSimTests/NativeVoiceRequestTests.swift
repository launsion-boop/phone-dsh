// SPDX-License-Identifier: MIT
import XCTest
import ProbeKit
import PhoneDSHAgentCore

final class NativeVoiceRequestTests: XCTestCase {
    func testWakeIdentityIsStableAndUnique() {
        let request = NativeVoiceRequest(sessionID: "wake-session")
        XCTAssertTrue(SendOutbox.isValidRpcId(request.rpcID))
        XCTAssertEqual(request.sessionID, "wake-session")
        XCTAssertNotEqual(request.rpcID, NativeVoiceRequest(sessionID: "wake-session").rpcID)
    }

    func testOnlyExactAuthoritativeRequestAndCompletedTurnCanSpeak() {
        let request = NativeVoiceRequest(sessionID: "a")
        var input = ChatItem(kind: .user, title: "", text: "same text")
        input.promptRequestID = request.rpcID
        input.turn = 3
        var reply = ChatItem(kind: .assistant, title: "", text: "correct reply")
        reply.turn = 3
        XCTAssertEqual(resolve(request, [input, reply], ended: [3]), .queued)
        input.promptJournalSeq = 4
        XCTAssertEqual(resolve(request, [input, reply]), .running)
        XCTAssertEqual(resolve(request, [input, reply], ended: [3]), .completed("correct reply"))
        XCTAssertEqual(resolve(request, [input, reply], ended: [3], failed: [3]), .failed)
        input.promptRequestID = "another-request-with-identical-text"
        XCTAssertEqual(resolve(request, [input, reply], ended: [3]), .queued)
    }

    func testUnrelatedTurnAndStreamingOrInterruptedTextAreNeverSpoken() {
        let request = NativeVoiceRequest(sessionID: "a")
        var input = ChatItem(kind: .user, title: "", text: "ask")
        input.promptRequestID = request.rpcID
        input.promptJournalSeq = 4
        input.turn = 3
        var wrong = ChatItem(kind: .assistant, title: "", text: "wrong turn")
        wrong.turn = 4
        var draft = ChatItem(kind: .assistant, title: "", text: "draft")
        draft.turn = 3
        draft.streaming = true
        XCTAssertEqual(resolve(request, [input, wrong, draft], ended: [3, 4]), .completed(""))
        draft.streaming = false
        draft.isInterruptedDraft = true
        XCTAssertEqual(resolve(request, [input, draft], ended: [3]), .completed(""))
        input.turn = nil
        XCTAssertEqual(resolve(request, [input, wrong], ended: [4]), .queued)
    }

    func testRealProjectorBindsOptimisticInputToAuthoritativeTurn() {
        let request = NativeVoiceRequest(sessionID: "a")
        var input = ChatItem(kind: .user, title: "", text: "ask")
        input.promptRequestID = request.rpcID
        var rows = [input]
        let event = HarnessEvent(seq: 10, time: Date(), kind: .userMessage(text: "ask", source: "user"), toolResultDetail: nil,
            userMessageData: .object([
                "source": .object(["kind": .string("user"), "rpcId": .string(request.rpcID)]),
                "content": .array([.object(["type": .string("text"), "text": .string("ask")])])
            ]))
        NativeTranscriptProjector.acknowledgeInput(event, sessionID: "a", in: &rows, openTurn: 7)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].turn, 7)
        XCTAssertNotNil(rows[0].promptJournalSeq)
        XCTAssertEqual(resolve(request, rows), .running)
    }

    func testHistoryUsesObservedTurnBoundariesAndNeverGuessesMissingBoundary() {
        let request = NativeVoiceRequest(sessionID: "a")
        let prompt: JSONValue = .object([
            "type": .string("user/message"), "seq": .number(2),
            "data": .object([
                "source": .object(["kind": .string("user"), "rpcId": .string(request.rpcID)]),
                "content": .array([.object(["type": .string("text"), "text": .string("ask")])])
            ])
        ])
        let start: JSONValue = .object(["type": .string("turn/start"), "seq": .number(1),
                                       "data": .object(["turn": .number(7)])])
        let end: JSONValue = .object(["type": .string("turn/end"), "seq": .number(3),
                                     "data": .object(["turn": .number(7)])])
        XCTAssertEqual(NativeTranscriptProjector.items(from: [start, prompt], sessionID: "a").first?.turn, 7)
        XCTAssertNil(NativeTranscriptProjector.items(from: [prompt], sessionID: "a").first?.turn)
        XCTAssertNil(NativeTranscriptProjector.items(from: [start, end, prompt], sessionID: "a").first?.turn)
    }

    func testVoiceAdmissionRetainsWakeDestinationAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = NativeVoiceRequest(sessionID: "wake-session")
        let queue = SendOutbox(directory: root)
        _ = try await queue.enqueue(sessionID: request.sessionID, text: "voice", rpcId: request.rpcID)
        _ = try await queue.markSubmitting(rpcId: request.rpcID)
        _ = try await queue.markOutcomeUnknown(rpcId: request.rpcID, lastError: "interrupted")
        let reopened = SendOutbox(directory: root)
        let saved = await reopened.entry(rpcId: request.rpcID)
        XCTAssertEqual(saved?.sessionId, "wake-session")
        XCTAssertEqual(saved?.state, .outcomeUnknown)
        do {
            _ = try await reopened.markSubmitting(rpcId: request.rpcID)
            XCTFail("An ambiguous request must not be resubmitted without readback")
        } catch { }
    }

    private func resolve(_ request: NativeVoiceRequest, _ rows: [ChatItem],
                         ended: Set<Int> = [], failed: Set<Int> = []) -> NativeVoiceProgress {
        NativeVoiceProgress.resolve(request: request, items: rows, endedTurns: ended, failedTurns: failed)
    }
}

// SPDX-License-Identifier: MIT
// phone-dsh — probe chat reply and terminal-resource regression tests.

import Foundation
import PhoneDSHAgentCore
import ProbeKit
import XCTest

@MainActor
final class ChatWorkflowTests: XCTestCase {
    func testQuestionReplySuccessCarriesRequestIDAndAnswerThenClearsRequest() async {
        let delivery = ReplyDelivery()
        delivery.present("question-7")
        var sent: [HarnessCommand] = []

        let accepted = await delivery.send(requestID: "question-7") {
            sent.append(.questionResponse(requestID: "question-7", answer: "Use the CSV file"))
        }

        XCTAssertTrue(accepted)
        XCTAssertEqual(sent, [.questionResponse(requestID: "question-7", answer: "Use the CSV file")])
        delivery.complete(ifMatching: "question-7")
        XCTAssertNil(delivery.requestID)
        XCTAssertNil(delivery.errorMessage)
        XCTAssertFalse(delivery.present("question-7"), "a replayed request must not reopen an answered question")
        let duplicate = await delivery.send(requestID: "question-7") { sent.append(.questionResponse(requestID: "question-7", answer: "again")) }
        XCTAssertFalse(duplicate)
        XCTAssertEqual(sent.count, 1)
    }

    func testFailedReplyRemainsRetryableAndReportsFailure() async {
        enum StubError: Error { case unavailable }
        let delivery = ReplyDelivery()
        delivery.present("permission-4")

        let first = await delivery.send(requestID: "permission-4") {
            throw StubError.unavailable
        }

        XCTAssertFalse(first)
        XCTAssertEqual(delivery.requestID, "permission-4")
        XCTAssertFalse(delivery.isSending)
        XCTAssertNotNil(delivery.errorMessage)

        var sent: [HarnessCommand] = []
        let retry = await delivery.send(requestID: "permission-4") {
            sent.append(.permissionResponse(requestID: "permission-4", decision: .deny))
        }
        XCTAssertTrue(retry)
        XCTAssertEqual(sent, [.permissionResponse(requestID: "permission-4", decision: .deny)])
    }

    func testNextQuestionArrivingBeforeReplyAckDoesNotReopenTheAnsweredQuestion() async {
        let delivery = ReplyDelivery()
        delivery.present("question-old")
        let accepted = await delivery.send(requestID: "question-old") {
            XCTAssertTrue(delivery.present("question-next"))
        }
        XCTAssertTrue(accepted)
        delivery.complete(ifMatching: "question-old")
        XCTAssertEqual(delivery.requestID, "question-next")
        XCTAssertFalse(delivery.present("question-old"))
        XCTAssertEqual(delivery.requestID, "question-next")
    }

    func testConcurrentReplyAttemptIsNotSentTwice() async {
        let delivery = ReplyDelivery()
        delivery.present("question-9")
        var sends = 0

        let first = Task { @MainActor in
            await delivery.send(requestID: "question-9") {
                sends += 1
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        await Task.yield()
        let duplicate = await delivery.send(requestID: "question-9") { sends += 1 }

        XCTAssertFalse(duplicate)
        let accepted = await first.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(sends, 1)
    }

    func testTerminalCleanupStopsEveryResourceAndParksOnlyWhenNeeded() async {
        var actions: [String] = []
        await TurnResourceCleanup.finish(
            shouldPark: true,
            stopHeartbeat: { actions.append("heartbeat") },
            stopPageAudio: { actions.append("page-audio") },
            stopNativeAudio: { actions.append("native-audio") },
            endBackgroundTask: { actions.append("background-task") },
            park: { actions.append("park") })
        XCTAssertEqual(actions, ["heartbeat", "page-audio", "native-audio", "park", "background-task"])

        actions.removeAll()
        await TurnResourceCleanup.finish(
            shouldPark: false,
            stopHeartbeat: { actions.append("heartbeat") },
            stopPageAudio: { actions.append("page-audio") },
            stopNativeAudio: { actions.append("native-audio") },
            endBackgroundTask: { actions.append("background-task") },
            park: { actions.append("park") })
        XCTAssertEqual(actions, ["heartbeat", "page-audio", "native-audio", "background-task"])
    }
}

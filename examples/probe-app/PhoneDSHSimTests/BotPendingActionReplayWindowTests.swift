// SPDX-License-Identifier: MIT

import PhoneDSHBot
import XCTest

/// Real-device regression: Bot sends written while the engine was absent stayed 「待发送，引擎就绪后
/// 自动发出」 forever because unit-start replay was switched off. Replay is back, bounded to recent
/// chat sends (store.md §10.5, PC-20261122-bot-queued-send-replay), so a stale row never fires.
final class BotPendingActionReplayWindowTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000

    private func record(_ nonce: String, kind: BotUserActionKind = .chat, ageMS: Int64) -> BotPendingActionRecord {
        BotPendingActionRecord(
            action: BotUserAction(nonce: nonce, botID: "main", kind: kind, text: kind == .chat ? "hi" : nil),
            createdAtMS: now - ageMS, attempts: 1)
    }

    func testARecentChatSendIsReplayed() {
        let out = BotPendingActionReplayWindow.replayable([record("a", ageMS: 5_000)], nowMS: now)
        XCTAssertEqual(out.map(\.nonce), ["a"])
    }

    func testTheWindowEdgeIsInclusiveAndOneMoreMillisecondIsNot() {
        let edge = BotPendingActionReplayWindow.maxAgeMilliseconds
        let out = BotPendingActionReplayWindow.replayable(
            [record("edge", ageMS: edge), record("old", ageMS: edge + 1)], nowMS: now)
        XCTAssertEqual(out.map(\.nonce), ["edge"])
    }

    func testAStaleChatRowNeverStartsATurn() {
        XCTAssertTrue(BotPendingActionReplayWindow.replayable(
            [record("days-old", ageMS: 3 * 86_400_000)], nowMS: now).isEmpty)
    }

    func testOnlyChatSendsAreReplayedAutomatically() {
        let out = BotPendingActionReplayWindow.replayable(
            [record("card", kind: .cardDismiss, ageMS: 1_000), record("stop", kind: .stopTask, ageMS: 1_000),
             record("chat", ageMS: 1_000)], nowMS: now)
        XCTAssertEqual(out.map(\.nonce), ["chat"])
    }

    func testStoreOrderIsKept() {
        let out = BotPendingActionReplayWindow.replayable(
            [record("first", ageMS: 3_000), record("second", ageMS: 2_000), record("third", ageMS: 1_000)], nowMS: now)
        XCTAssertEqual(out.map(\.nonce), ["first", "second", "third"])
    }
}

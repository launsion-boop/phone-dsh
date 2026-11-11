// SPDX-License-Identifier: MIT
// W2: only a level-2 JOURNAL_ACK advances the step-pruning watermark.

import XCTest
@testable import PhoneDSH
import PhoneDSHLog
import PhoneDSHWire

final class JournalDurabilityTrackerTests: XCTestCase {
    func testOnlyEpochFsyncAdvancesAndNeverLowersTheWatermark() async {
        let tracker = JournalDurabilityTracker()
        await tracker.record(JournalAck(level: .write, sessionID: "s", uptoJseq: 9))
        var value = await tracker.durableJseq(sessionID: "s")
        XCTAssertEqual(value, 0, "a level-1 ack is not durable")

        await tracker.record(JournalAck(level: .epochFsync, sessionID: "s", uptoJseq: 4))
        value = await tracker.durableJseq(sessionID: "s")
        XCTAssertEqual(value, 4)

        await tracker.record(JournalAck(level: .epochFsync, sessionID: "s", uptoJseq: 2))
        value = await tracker.durableJseq(sessionID: "s")
        XCTAssertEqual(value, 4, "a replayed ack never lowers the watermark")

        await tracker.record(JournalAck(level: .epochFsync, sessionID: "s", uptoJseq: 7))
        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot["s"], 7)
    }
}

// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class RowStreamingLimiterTests: XCTestCase {
    func testTenHertzLimitCoalescesOnlyInMemory() async {
        let limiter = BotStreamingRowLimiter()
        for index in 0..<BotStreamingRowLimiter.maximumUpdatesPerSecond {
            let emitted = await limiter.submit(RowTestSupport.row(id: "row-\(index)", seq: index), now: 10)
            XCTAssertEqual(emitted?.id, "row-\(index)")
        }
        let deferred = await limiter.submit(RowTestSupport.row(id: "overflow", text: "first"), now: 10.1)
        XCTAssertNil(deferred)
        let coalesced = await limiter.submit(RowTestSupport.row(id: "overflow", text: "latest"), now: 10.2)
        XCTAssertNil(coalesced)
        let pendingBeforeFlush = await limiter.pendingCount()
        XCTAssertEqual(pendingBeforeFlush, 1)
        let premature = await limiter.flush(now: 10.99)
        XCTAssertTrue(premature.isEmpty)

        let flushed = await limiter.flush(now: 11)
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].body["text"], .string("latest"))
        XCTAssertTrue(flushed[0].streaming)
        let pendingAfterFlush = await limiter.pendingCount()
        let visibleRows = await limiter.rows()
        XCTAssertEqual(pendingAfterFlush, 0)
        XCTAssertEqual(visibleRows.count, 11)

        await limiter.clear()
        let clearedRows = await limiter.rows()
        XCTAssertTrue(clearedRows.isEmpty)
    }

    func testRollingWindowNeverEmitsMoreThanTen() async {
        let limiter = BotStreamingRowLimiter()
        var emissions = 0
        for step in 0..<20 {
            let now = 100 + Double(step) * 0.05
            if await limiter.submit(RowTestSupport.row(id: "row", text: "delta-\(step)"), now: now) != nil {
                emissions += 1
            }
            let flushed = await limiter.flush(now: now)
            emissions += flushed.count
            XCTAssertLessThanOrEqual(emissions, BotStreamingRowLimiter.maximumUpdatesPerSecond,
                                     "the first one-second window must be bounded")
        }
        XCTAssertEqual(emissions, BotStreamingRowLimiter.maximumUpdatesPerSecond)
        let visibleRows = await limiter.rows()
        XCTAssertEqual(visibleRows.first?.body["text"], .string("delta-9"))

        let final = await limiter.flush(now: 102)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.body["text"], .string("delta-19"))
    }
}

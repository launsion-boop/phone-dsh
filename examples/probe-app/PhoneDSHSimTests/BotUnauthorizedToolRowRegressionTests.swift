// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore
import ProbeKit
import XCTest

/// Regression for the Bot chat hang after a session-level tool call was
/// rejected with `[identity-bridge] ... unauthorized`.
///
/// The real incident left the main thread inside SwiftUI
/// `LazySubviewPlacements.placeSubviews` for 1396 of 1409 samples. The lazy
/// transcript was carrying the same `ChatItem.id` twice: a re-attached live
/// observer replays the open turn, and the journal projection appends both
/// copies. `ForEach` requires unique ids. These tests drive the real live-turn
/// and process-row projections with the incident's event shapes.
final class BotUnauthorizedToolRowRegressionTests: XCTestCase {
    private func event(_ type: String, turn: Int = 1, seq: Int,
                       data: [String: JSONValue] = [:]) -> JSONValue {
        var values = data
        values["turn"] = .number(Double(turn))
        return .object([
            "type": .string(type),
            "seq": .number(Double(seq)),
            "time": .number(1_794_414_383_000 + Double(seq)),
            "data": .object(values),
        ])
    }

    private func unauthorizedError() -> String {
        "Error: [identity-bridge] App MCP did not accept the call registration: unauthorized"
    }

    private func result(seq: Int, callID: String) -> JSONValue {
        event("tool/result", seq: seq, data: [
            "message": .object([
                "toolCallId": .string(callID),
                "content": .array([
                    .object(["type": .string("text"), "text": .string(unauthorizedError())]),
                ]),
                "isError": .bool(true),
            ]),
        ])
    }

    /// The exact two failed same-name `bash` calls from `session.v4.jsonl`
    /// turn 3, then the model's final explanation and `turn/end`.
    private func unauthorizedRecords() -> [JSONValue] {
        [
            event("turn/start", seq: 1),
            event("tool/call", seq: 2, data: [
                "callId": .string("call_00_ET_wr4jkzhvcDcj1xS2qYcl4801"),
                "name": .string("bash"),
                "arguments": .string("{\"command\":\"echo probe-3\",\"description\":\"执行 echo 探测\"}"),
            ]),
            result(seq: 3, callID: "call_00_ET_wr4jkzhvcDcj1xS2qYcl4801"),
            event("tool/call", seq: 4, data: [
                "callId": .string("call_00_BqzN0GG1QnaRcG4D3A4K6934"),
                "name": .string("bash"),
                "arguments": .string("{\"command\":\"echo probe-3\",\"description\":\"重试 echo 探测\"}"),
            ]),
            result(seq: 5, callID: "call_00_BqzN0GG1QnaRcG4D3A4K6934"),
            event("assistant/message", seq: 6, data: [
                "message": .object([
                    "role": .string("assistant"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("probe-3 没有执行成功：两次尝试都报 unauthorized 错误。"),
                        ]),
                    ]),
                ]),
            ]),
            event("turn/end", seq: 7, data: ["reason": .object(["kind": .string("completed")])]),
        ]
    }

    private func toolIDs(_ process: BotTurnProcess) -> [String] {
        process.items.compactMap(\.callID)
    }

    private func segmentIDs(_ live: BotLiveTurn) -> [String] {
        live.segments.flatMap { segment -> [String] in
            guard case .tools(let ids) = segment else { return [] }
            return ids
        }
    }

    func testUnauthorizedTurnProjectsTwoUniqueToolRows() {
        let records = unauthorizedRecords()
        let processes = BotTurnProcessProjector.make(records: records)
        guard let process = processes[1] else {
            return XCTFail("turn 1 did not project a process row")
        }
        XCTAssertEqual(process.items.count, 2, "both failed calls must be visible")
        XCTAssertEqual(Set(process.items.map(\.id)).count, process.items.count,
                       "ForEach ids must be unique")
        XCTAssertEqual(toolIDs(process), [
            "call_00_ET_wr4jkzhvcDcj1xS2qYcl4801",
            "call_00_BqzN0GG1QnaRcG4D3A4K6934",
        ])
        XCTAssertTrue(process.items.allSatisfy { $0.toolState == .error },
                      "both unauthorized results must stay marked as failures")
        guard case .completed(let elapsed) = process.state else {
            return XCTFail("turn/end must close the process row as completed")
        }
        XCTAssertEqual(elapsed ?? 0, 0.006, accuracy: 0.001)
    }

    func testReplayedProcessRecordsDoNotDuplicateForEachIDs() {
        let records = unauthorizedRecords()
        // The observer re-attaches and replays the same journal seqs.
        let replayed = records + records
        let processes = BotTurnProcessProjector.make(records: replayed)
        guard let process = processes[1] else {
            return XCTFail("turn 1 did not project a process row")
        }
        XCTAssertEqual(process.items.count, 2, "a replay must not add tool rows")
        XCTAssertEqual(Set(process.items.map(\.id)).count, 2)
    }

    func testLiveTurnReplayKeepsOneSegmentAndUniqueToolRows() {
        let records = unauthorizedRecords()
        var live = BotLiveTurn()
        for record in records { live.apply(event: record) }
        XCTAssertEqual(live.tools.count, 2)
        XCTAssertEqual(segmentIDs(live), [
            "call_00_ET_wr4jkzhvcDcj1xS2qYcl4801",
            "call_00_BqzN0GG1QnaRcG4D3A4K6934",
        ])

        for record in records { live.apply(event: record) }
        XCTAssertEqual(live.tools.count, 2, "a replayed call must not duplicate the row")
        XCTAssertEqual(segmentIDs(live).count, 2, "a replayed call must not duplicate the segment id")
        XCTAssertEqual(Set(live.tools.map(\.id)).count, 2)

        let duplicated = live.tools(for: [
            "call_00_ET_wr4jkzhvcDcj1xS2qYcl4801",
            "call_00_ET_wr4jkzhvcDcj1xS2qYcl4801",
        ])
        XCTAssertEqual(duplicated.count, 1, "tools(for:) must not return one row twice")
    }

    func testToolRowIdentityDropsReplayedRows() {
        let records = unauthorizedRecords()
        let process = BotTurnProcessProjector.make(records: records)[1]
        guard let process else { return XCTFail("missing process") }
        let replayed = process.items + process.items
        let unique = NativeToolRowIdentity.unique(replayed)
        XCTAssertEqual(unique.count, process.items.count)
        XCTAssertEqual(Set(unique.map(\.id)).count, unique.count)
    }
}

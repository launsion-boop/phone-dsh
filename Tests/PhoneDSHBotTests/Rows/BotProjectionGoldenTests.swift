// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Runs `spec/bot/v1/golden/projection.phone.json` through the real session-log
/// parser, row projector, row history and streaming limiter.
final class BotProjectionGoldenTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try BotGoldenFixture.rawObject("projection.phone")
    }

    private func data(_ records: [String]) -> Data {
        Data(records.joined(separator: "\n").utf8)
    }

    private func decodeEvents(_ values: [Any]?) throws -> [BotEvent] {
        guard let values else { return [] }
        return try values.map { value in
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return try JSONDecoder().decode(BotEvent.self, from: data)
        }
    }

    private func row(_ value: Any?) throws -> BotRow {
        guard let value else { throw FixtureError.missing("row") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try JSONDecoder().decode(BotRow.self, from: data)
    }

    private func rows(_ value: Any?) throws -> [BotRow] {
        try (value as? [Any] ?? []).map { try row($0) }
    }

    private func batch(_ value: Any?) throws -> BotRowBatch {
        guard let object = value as? [String: Any] else { throw FixtureError.missing("batch") }
        return BotRowBatch(rows: try rows(object["rows"]),
                           deletes: object["deletes"] as? [String] ?? [],
                           cursor: (object["cursor"] as? NSNumber)?.intValue ?? -1,
                           reset: (object["reset"] as? NSNumber)?.boolValue ?? false)
    }

    private func project(_ vector: [String: Any]) throws -> BotRowProjectionSnapshot {
        let sessionID = vector["sessionID"] as? String ?? "gb-main"
        if let epochs = vector["epochs"] as? [[String: Any]] {
            let projections = try epochs.map { epoch -> BotSessionEpochProjection in
                let parsed = BotDSHSessionEvent.parseJSONL(data(epoch["records"] as? [String] ?? []))
                XCTAssertEqual(parsed.diagnostics.skippedRecordCount, 0, "\(epoch["sessionID"] ?? "")")
                return BotSessionEpochProjection(sessionID: epoch["sessionID"] as? String ?? "",
                                                 events: parsed.events)
            }
            return BotSessionLogProjector().project(
                botID: "main", epochs: projections,
                uiEvents: try decodeEvents(vector["uiEvents"] as? [Any]),
                heldRequestNonces: vector["heldRequestNonces"] as? [String: String] ?? [:])
        }
        let parsed = BotDSHSessionEvent.parseJSONL(data(vector["records"] as? [String] ?? []))
        XCTAssertEqual(parsed.diagnostics.skippedRecordCount, 0, "\(vector["name"] ?? "")")
        return BotSessionLogProjector().project(
            botID: "main", sessionID: sessionID, sessionEvents: parsed.events,
            uiEvents: try decodeEvents(vector["uiEvents"] as? [Any]),
            heldRequestNonces: vector["heldRequestNonces"] as? [String: String] ?? [:])
    }

    private func assertRows(_ actual: [BotRow], _ expected: [BotRow],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            var normalized = pair.0
            normalized.chatActionNonce = nil
            XCTAssertEqual(normalized, pair.1, "row[\(index)]", file: file, line: line)
        }
    }

    private func assertSnapshot(_ actual: BotRowProjectionSnapshot, _ expected: [String: Any],
                                label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.cursor, (expected["cursor"] as? NSNumber)?.intValue,
                       "\(label): cursor", file: file, line: line)
        do {
            try assertRows(actual.rows, try rows(expected["rows"]), file: file, line: line)
            try assertRows(actual.tombstones, try rows(expected["tombstones"]), file: file, line: line)
        } catch {
            XCTFail("\(label): \(error)", file: file, line: line)
        }
        if let nonces = expected["chatActionNonces"] as? [String: String] {
            var actualNonces: [String: String] = [:]
            for row in actual.rows {
                if let nonce = row.chatActionNonce { actualNonces[row.id] = nonce }
            }
            XCTAssertEqual(actualNonces, nonces, "\(label): chatActionNonces", file: file, line: line)
        }
        if let displays = expected["display"] as? [String: Any] {
            for row in actual.rows {
                guard let expected = displays[row.id] as? [String: Any] else {
                    XCTFail("\(label): missing display for \(row.id)", file: file, line: line)
                    continue
                }
                let projection = BotDisplayContract.project(row)
                XCTAssertEqual(projection.surface, expected["surface"] as? String,
                               "\(label): \(row.id) surface", file: file, line: line)
                XCTAssertEqual(projection.renderable, (expected["renderable"] as? NSNumber)?.boolValue,
                               "\(label): \(row.id) renderable", file: file, line: line)
                let wire = expected["wire"] as? [String: Any]
                XCTAssertEqual(projection.wire.kind, wire?["kind"] as? String,
                               "\(label): \(row.id) wire.kind", file: file, line: line)
                XCTAssertEqual(projection.wire.type, wire?["type"] as? String,
                               "\(label): \(row.id) wire.type", file: file, line: line)
            }
        }
    }

    // MARK: - DSH mapping

    func testDSHRecordMappingVectors() throws {
        let mapping = try XCTUnwrap((fixture()["valid"] as? [String: Any])?["dshMapping"] as? [[String: Any]])
        let valid = try XCTUnwrap(mapping)
        XCTAssertFalse(valid.isEmpty)
        for vector in valid {
            let label = vector["name"] as? String ?? "dsh"
            let snapshot = try project(vector)
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            assertSnapshot(snapshot, expected, label: label)
        }
    }

    func testUIRecordMappingVectors() throws {
        let mapping = try XCTUnwrap((fixture()["valid"] as? [String: Any])?["uiMapping"] as? [[String: Any]])
        let valid = try XCTUnwrap(mapping)
        XCTAssertFalse(valid.isEmpty)
        for vector in valid {
            let label = vector["name"] as? String ?? "ui"
            let snapshot = try project(vector)
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            assertSnapshot(snapshot, expected, label: label)
        }
    }

    func testInvalidRecordDiagnostics() throws {
        let invalid = try XCTUnwrap(fixture()["invalid"] as? [[String: Any]])
        XCTAssertFalse(invalid.isEmpty)
        for vector in invalid {
            let label = vector["name"] as? String ?? "invalid"
            let parsed = BotDSHSessionEvent.parseJSONL(data(vector["records"] as? [String] ?? []))
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
            let expectedSeqs = (expected["eventSeqs"] as? [Any] ?? []).compactMap {
                ($0 as? NSNumber)?.intValue
            }
            XCTAssertEqual(parsed.events.map(\.seq), expectedSeqs, "\(label): event seqs")
            let skipped = expected["skipped"] as? [[String: Any]] ?? []
            XCTAssertEqual(parsed.diagnostics.skipped.count, skipped.count, "\(label): skipped count")
            for (index, entry) in skipped.enumerated() where index < parsed.diagnostics.skipped.count {
                let actual = parsed.diagnostics.skipped[index]
                XCTAssertEqual(actual.lineNumber, (entry["lineNumber"] as? NSNumber)?.intValue,
                               "\(label): lineNumber[\(index)]")
                XCTAssertEqual(actual.seq, (entry["seq"] as? NSNumber)?.intValue,
                               "\(label): seq[\(index)]")
            }
        }
    }

    // MARK: - History

    func testHistoryAndCursorVectors() async throws {
        let cases = try XCTUnwrap((fixture()["valid"] as? [String: Any])?["history"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            let label = vector["name"] as? String ?? "history"
            let history = BotRowHistory()
            let steps = try XCTUnwrap(vector["steps"] as? [[String: Any]])
            for (index, step) in steps.enumerated() {
                if let rebuild = step["rebuild"] as? [String: Any] {
                    let parsed = BotDSHSessionEvent.parseJSONL(data(rebuild["records"] as? [String] ?? []))
                    XCTAssertEqual(parsed.diagnostics.skippedRecordCount, 0, "\(label)[\(index)]")
                    let actual = try await history.rebuild(
                        botID: "main", sessionID: rebuild["sessionID"] as? String ?? "gb-main",
                        sessionEvents: parsed.events,
                        uiEvents: try decodeEvents(rebuild["uiEvents"] as? [Any]))
                    try assertBatch(actual, try batch(step["expectBatch"]), label: "\(label)[\(index)]")
                } else if let cursor = (step["watchAfter"] as? NSNumber)?.intValue {
                    let actual = await history.watch(after: cursor)
                    try assertBatch(actual, try batch(step["expectBatch"]),
                                    label: "\(label).watch(\(cursor))")
                } else {
                    XCTFail("\(label)[\(index)]: unknown history step")
                }
            }
        }
    }

    private func assertBatch(_ actual: BotRowBatch, _ expected: BotRowBatch, label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.cursor, expected.cursor, "\(label): cursor", file: file, line: line)
        XCTAssertEqual(actual.deletes, expected.deletes, "\(label): deletes", file: file, line: line)
        XCTAssertEqual(actual.reset, expected.reset, "\(label): reset", file: file, line: line)
        assertRows(actual.rows, expected.rows, file: file, line: line)
    }

    // MARK: - Streaming

    func testStreamingLimiterVectors() async throws {
        let cases = try XCTUnwrap((fixture()["valid"] as? [String: Any])?["streaming"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            let label = vector["name"] as? String ?? "streaming"
            let limiter = BotStreamingRowLimiter()
            let steps = try XCTUnwrap(vector["steps"] as? [[String: Any]])
            for (index, step) in steps.enumerated() {
                if let submit = step["submit"] as? [String: Any] {
                    let now = (submit["now"] as? NSNumber)?.doubleValue ?? 0
                    let emitted = await limiter.submit(try row(submit["row"]), now: now)
                    if step["expectEmitted"] is NSNull {
                        XCTAssertNil(emitted, "\(label)[\(index)]: expected no emission")
                    } else {
                        let expected = try row(step["expectEmitted"])
                        XCTAssertEqual(emitted, expected, "\(label)[\(index)]: emitted")
                    }
                    if let flushed = step["expectFlush"] as? [Any] {
                        let actual = await limiter.flush(now: now)
                        assertRows(actual, try rows(flushed), file: #filePath, line: #line)
                    }
                } else if let flush = step["flush"] as? [String: Any] {
                    let now = (flush["now"] as? NSNumber)?.doubleValue ?? 0
                    let actual = await limiter.flush(now: now)
                    assertRows(actual, try rows(step["expectRows"]),
                               file: #filePath, line: #line)
                } else if let state = step["state"] as? [String: Any] {
                    if let expected = (state["pendingCount"] as? NSNumber)?.intValue {
                        let actual = await limiter.pendingCount()
                        XCTAssertEqual(actual, expected, "\(label)[\(index)]: pendingCount")
                    }
                    if let expected = (state["rowCount"] as? NSNumber)?.intValue {
                        let actual = await limiter.rows().count
                        XCTAssertEqual(actual, expected, "\(label)[\(index)]: rowCount")
                    }
                    if state["nextFlushAt"] is NSNull {
                        let actual = await limiter.nextFlushAt()
                        XCTAssertNil(actual, "\(label)[\(index)]: nextFlushAt")
                    }
                } else {
                    XCTFail("\(label)[\(index)]: unknown streaming step")
                }
            }
        }
    }
}

private enum FixtureError: Error, CustomStringConvertible {
    case missing(String)
    var description: String {
        switch self {
        case .missing(let name): return "missing fixture \(name)"
        }
    }
}

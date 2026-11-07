// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

enum RowTestSupport {
    struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    static func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = candidate.appendingPathComponent("spec/bot/v1/golden")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw FixtureError(description: "cannot locate Bot golden directory from #filePath")
    }

    static func golden(_ name: String) throws -> [String: Any] {
        let url = try repositoryRoot().appendingPathComponent("spec/bot/v1/golden/\(name).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw FixtureError(description: "\(name).json is not an object")
        }
        return dictionary
    }

    static func object(_ value: Any?, in fixture: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw FixtureError(description: "missing object in \(fixture)")
        }
        return object
    }

    static func array(_ value: Any?, in fixture: String) throws -> [[String: Any]] {
        guard let array = value as? [[String: Any]] else {
            throw FixtureError(description: "missing object array in \(fixture)")
        }
        return array
    }

    static func data(_ object: Any?) throws -> Data {
        guard let object else { throw FixtureError(description: "missing JSON value") }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any?) throws -> T {
        try JSONDecoder().decode(type, from: data(object))
    }

    static func assertEncoded<T: Encodable>(_ value: T, equals expected: Any?,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let actualData = try JSONEncoder().encode(value)
        let actualObject = try JSONSerialization.jsonObject(with: actualData)
        XCTAssertEqual(try data(actualObject), try data(expected), file: file, line: line)
    }

    static func row(id: String, seq: Int = 1, updatedSeq: Int = 0, text: String = "delta") -> BotRow {
        BotRow(id: id, botID: "main", seq: seq, updatedSeq: updatedSeq, kind: .sendMessage,
               role: "assistant", body: BotRowBody(type: .text, additionalProperties: ["text": .string(text)]),
               provenance: BotRowProvenance(eventIDs: [], trust: BotRowProvenance.model, tainted: false),
               streaming: true, createdAt: 1)
    }

    static func dshText(seq: Int, time: Int64, role: String, text: String, turn: Int? = nil,
                        surfaceOp: String? = "append") -> BotDSHSessionEvent {
        var data: [String: BotJSONValue] = [
            "role": .string(role),
            "message": .object([
                "role": .string(role),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])])
            ])
        ]
        if let surfaceOp { data["surfaceOp"] = .string(surfaceOp) }
        if let turn { data["turn"] = .number(Double(turn)) }
        return BotDSHSessionEvent(type: role == "user" ? "user/message" : "assistant/message",
                                  seq: seq, time: time, data: data)
    }

    static func uiEvent(type: String = "card.presented", id: String, commitSeq: Int, time: Int64,
                        data: [String: BotJSONValue]) -> BotEvent {
        BotEvent(type: type, eventId: id, commitSeq: commitSeq, time: time,
                 origin: .local(source: "card-bridge"), traceId: "trace-\(id)",
                 principal: BotPrincipal(botId: "main", sessionId: "main", kind: "chat"),
                 causationId: nil, correlationId: nil, data: .object(data))
    }

    static func progress(id: String, commitSeq: Int, time: Int64, percent: Int) -> BotEvent {
        uiEvent(id: id, commitSeq: commitSeq, time: time, data: [
            "card": .object([
                "cardType": .string("progress"),
                "cardKey": .string("report-1"),
                "title": .string("生成报告"),
                "state": .string(percent == 100 ? "done" : "running"),
                "percent": .number(Double(percent))
            ])
        ])
    }

    static func sorted(_ rows: [BotRow]) -> [BotRow] {
        rows.sorted { lhs, rhs in
            if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
            return lhs.id < rhs.id
        }
    }
}

actor RowActionPlannerDouble: BotUserActionPlanning {
    private(set) var actions: [BotUserAction] = []
    private(set) var trusts: [BotUserActionTrust] = []
    private var outcomes: [String: BotUserActionPlanOutcome] = [:]
    private var eventIDs: [String: String] = [:]
    var defaultEventID = "evt-2"

    func setOutcome(_ outcome: BotUserActionPlanOutcome, for nonce: String) {
        outcomes[nonce] = outcome
    }

    func clearOutcome(for nonce: String) {
        outcomes.removeValue(forKey: nonce)
    }

    func setEventID(_ eventID: String, for nonce: String) {
        eventIDs[nonce] = eventID
    }

    func setDefaultEventID(_ eventID: String) {
        defaultEventID = eventID
    }

    func plan(_ action: BotUserAction, trust: BotUserActionTrust) async throws -> BotUserActionPlanOutcome {
        actions.append(action)
        trusts.append(trust)
        if let outcome = outcomes[action.nonce] { return outcome }
        if action.kind == .approval, action.digest != "digest-1" {
            return .stale(reason: "digest_mismatch")
        }
        let eventID = eventIDs[action.nonce] ?? defaultEventID
        let type: String
        switch action.kind {
        case .chat: type = "conversation.user_message"
        case .approval: type = "approval.decided"
        case .stopTask: type = "task.stop_requested"
        case .cardAnswer: type = "card.answered"
        case .cardDismiss: type = "card.dismissed"
        }
        let event = BotEvent(
            type: type, eventId: eventID, time: 1_000, origin: .local(source: "user"),
            traceId: "trace-\(eventID)",
            principal: BotPrincipal(botId: action.botID, sessionId: "main", kind: "chat"),
            causationId: nil, correlationId: action.nonce,
            data: .object(["nonce": .string(action.nonce), "kind": .string(action.kind.rawValue)]))
        return .commit(BotUserActionPlan(event: event))
    }
}

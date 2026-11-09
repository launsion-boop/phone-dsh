// SPDX-License-Identifier: MIT
// Durable DSH session history: follow snapshot + page backfill -> raw records.
//
// This is the data half of the former `ChatModel.loadSessionHistory`. The App
// keeps the presentation half (compaction folding) because its wording belongs
// to the render layer; a second `WorkspaceBackend` can now read the same raw
// records and feed the same `NativeTranscriptProjector`.
//
// Wire shapes follow the DSH 0.2.2-rc.1 gateway contract:
//   * `session/list` carries the reserved `_request` member;
//   * `session/follow` omits `assistantStream` (the pin only accepts `true`);
//   * `session/page` carries `request.address` and the cursor bounds.

import Foundation
import PhoneDSHAgentCore

/// Durable turn/start + turn/end facts, kept beside (not inside) `ChatItem` so
/// history replay can draw the same closed-Turn control row as live events.
public struct SessionTurnFacts: Equatable, Sendable {
    public var starts: [Int: Date] = [:]
    public var endReasons: [Int: String] = [:]
    public var ends: [Int: Date] = [:]

    public init() {}
}

/// One read of a session's durable history: the raw journal records plus the
/// facts a presentation layer needs to place them.
public struct SessionHistorySnapshot {
    public var records: [JSONValue]
    public var cursor: Int
    public var after: UInt64?
    public var hasMore: Bool
    public var beforeSeq: Int?
    public var throughSeq: Int?
    public var inputReceipts: [String: Int]
    /// Authoritative `session/list.running` when it could be read.
    public var running: Bool?
    /// Fallback derived from `turn/start` / `turn/end` records.
    public var inferredTurnRunning: Bool
    public var turnFacts: SessionTurnFacts
    /// Failures that were deliberately swallowed (the caller decides whether
    /// to log them). `requireRunningState` throws instead of appending here.
    public var diagnostics: [String]

    public init(records: [JSONValue], cursor: Int, after: UInt64?, hasMore: Bool,
                beforeSeq: Int?, throughSeq: Int?, inputReceipts: [String: Int],
                running: Bool?, inferredTurnRunning: Bool,
                turnFacts: SessionTurnFacts, diagnostics: [String]) {
        self.records = records
        self.cursor = cursor
        self.after = after
        self.hasMore = hasMore
        self.beforeSeq = beforeSeq
        self.throughSeq = throughSeq
        self.inputReceipts = inputReceipts
        self.running = running
        self.inferredTurnRunning = inferredTurnRunning
        self.turnFacts = turnFacts
        self.diagnostics = diagnostics
    }
}

public enum SessionHistoryReader {
    /// Reads the follow opening snapshot and the newest message-aligned page,
    /// then walks backwards only for unresolved local input receipts.
    public static func load(sessionID: String,
                            transport: any DSHRemoteTransport,
                            requireRunningState: Bool = false,
                            pendingInputs: [ChatItem] = []) async throws -> SessionHistorySnapshot {
        let follow = try await followSnapshot(sessionID: sessionID, transport: transport)
        let cursor = follow.cursor

        var records: [JSONValue] = []
        var hasMore = false
        var beforeSeq: Int?
        var historyPage: JSONValue = .object([:])
        if cursor >= 0 {
            let page = try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(cursor)),
                "maxMessages": .number(60),
            ])]))
            records = (page["records"]?.arrayValue ?? []).compactMap { $0["event"] }
            hasMore = page["hasMore"]?.boolValue ?? false
            beforeSeq = records.compactMap { $0["seq"]?.intValue }.min()
            historyPage = page
        }
        let inputReceipts = try await NativeTranscriptProjector.inputReceipts(
            for: pendingInputs, historyPage: historyPage,
            inbox: follow.projections?["values"]?["inbox"]
        ) { before in
            try await transport.call("session/page", args: .object(["request": .object([
                "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(cursor)), "beforeSeq": .number(Double(before)),
                "maxMessages": .number(60),
            ])]))
        }
        let after = cursor >= 0
            ? UInt64(cursor + 1) * DSHEventMapper.partsPerEvent - 1
            : nil

        var running: Bool?
        var diagnostics: [String] = []
        if requireRunningState {
            let sessions = try await transport.call("session/list", args: .object(["_request": .object([:])]))
            guard let confirmed = sessions["items"]?.arrayValue?.first(where: {
                $0["sessionId"]?.stringValue == sessionID
            })?["running"]?.boolValue else {
                throw ProviderError.invalidResponse("session running state is unavailable")
            }
            running = confirmed
        } else {
            do {
                let sessions = try await transport.call("session/list", args: .object(["_request": .object([:])]))
                running = sessions["items"]?.arrayValue?.first(where: {
                    $0["sessionId"]?.stringValue == sessionID
                })?["running"]?.boolValue
            } catch {
                diagnostics.append("session/list running probe failed: \(error)")
            }
        }

        return SessionHistorySnapshot(
            records: records, cursor: cursor, after: after, hasMore: hasMore,
            beforeSeq: beforeSeq, throughSeq: cursor >= 0 ? cursor : nil,
            inputReceipts: inputReceipts, running: running,
            inferredTurnRunning: isTurnRunning(in: records),
            turnFacts: turnFacts(in: records), diagnostics: diagnostics)
    }

    /// Reads only the durable log cut a follow opening covers. Used by the
    /// trajectory/device readers that need a cursor but no page.
    public static func followCursor(sessionID: String,
                                    transport: any DSHRemoteTransport) async throws -> Int {
        try await followSnapshot(sessionID: sessionID, transport: transport).cursor
    }

    public static func turnFacts(in records: [JSONValue]) -> SessionTurnFacts {
        var facts = SessionTurnFacts()
        for event in records {
            guard let type = event["type"]?.stringValue else { continue }
            let data = event["data"] ?? .null
            guard let turn = data["turn"]?.intValue else { continue }
            let time = event["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
            switch type {
            case "turn/start":
                if let time { facts.starts[turn] = time }
            case "turn/end":
                if let time { facts.ends[turn] = time }
                facts.endReasons[turn] = data["reason"]?["kind"]?.stringValue ?? "completed"
            default:
                break
            }
        }
        return facts
    }

    public static func isTurnRunning(in records: [JSONValue]) -> Bool {
        var running = false
        for event in records {
            switch event["type"]?.stringValue {
            case "turn/start": running = true
            case "turn/end": running = false
            default: break
            }
        }
        return running
    }

    private struct FollowSnapshot {
        var cursor: Int
        var projections: JSONValue?
    }

    private static func followSnapshot(sessionID: String,
                                       transport: any DSHRemoteTransport) async throws -> FollowSnapshot {
        let mux = try await transport.openMux()
        let streamID = "phone-chat-history-\(UUID().uuidString)"
        do {
            try await mux.send(.object([
                "type": .string("open"),
                "streamId": .string(streamID),
                "endpoint": .string("session/follow"),
                "payload": .object(["args": .object(["request": .object([
                    "address": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                    "maxMessages": .number(1),
                ])])]),
            ]))
            let snapshot = try await receiveSnapshot(from: mux, streamID: streamID)
            guard let cursor = snapshot["cursor"]?.intValue else {
                throw ProviderError.invalidResponse("session/follow snapshot has no cursor")
            }
            await mux.close()
            return FollowSnapshot(cursor: cursor, projections: snapshot["projections"])
        } catch {
            await mux.close()
            throw error
        }
    }

    private static func receiveSnapshot(from mux: any DSHMuxConnection,
                                        streamID: String) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    guard let frame = try await mux.receive() else {
                        throw ProviderError.unavailable(retryAfter: nil)
                    }
                    guard frame["streamId"]?.stringValue == streamID else { continue }
                    switch frame["type"]?.stringValue {
                    case "error":
                        throw ProviderError.invalidResponse(
                            "session/follow failed: \(frame["error"]?["message"]?.stringValue ?? "unknown error")")
                    case "end":
                        throw ProviderError.invalidResponse("session/follow ended before its history cursor")
                    case "item":
                        let value = frame["value"] ?? .null
                        if value["type"]?.stringValue == "snapshot" {
                            guard value["cursor"]?.intValue != nil else {
                                throw ProviderError.invalidResponse("session/follow snapshot has no cursor")
                            }
                            return value
                        }
                    default:
                        continue
                    }
                }
                throw ProviderError.cancelled
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                await mux.close()
                throw ProviderError.unavailable(retryAfter: nil)
            }
            guard let snapshot = try await group.next() else {
                throw ProviderError.invalidResponse("session/follow did not publish a history cursor")
            }
            group.cancelAll()
            return snapshot
        }
    }
}

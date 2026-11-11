// SPDX-License-Identifier: MIT
// The Bot page's view of a turn's work, drawn the way the DSH session page
// draws it: tool calls as DSH tool rows under a "已完成，用时 …" process row,
// and a running turn as streamed text, live tool rows and the running clock.
// Both come from the Bot's own DSH session: finished turns from its session
// log, the running turn from the live frames the Bot runtime forwards.

#if canImport(ProbeKit)
import ProbeKit
#endif
import Foundation
import PhoneDSHAgentCore
import PhoneDSHBot

/// The tool steps of one finished turn, for the folded process row.
struct BotTurnProcess: Equatable {
    var turn: Int
    var items: [ChatItem]
    var startedAt: Date?
    var endedAt: Date?
    var endKind: String?

    var state: NativeTurnProcessState {
        let elapsed = startedAt.flatMap { start in endedAt.map { $0.timeIntervalSince(start) } }
        return NativeTurnProcessState.resolve(endReasonKind: endKind ?? "completed", elapsed: elapsed)
    }
}

enum BotTurnProcessProjector {
    /// Tool steps per turn from the session log's DSH events. Hidden
    /// interactions are skipped, and so are the tools the Bot already shows
    /// as cards (questions, next steps, approvals).
    static func make(records: [JSONValue]) -> [Int: BotTurnProcess] {
        var grouped: [Int: [JSONValue]] = [:]
        var started: [Int: Date] = [:]
        var ended: [Int: (time: Date?, kind: String?)] = [:]
        var hidden: Set<Int> = []
        var current: Int?
        for record in records {
            guard let type = record["type"]?.stringValue else { continue }
            let data = record["data"] ?? .null
            let time = record["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
            if type == "turn/start" {
                current = data["turn"]?.intValue ?? current
                if let current, let time { started[current] = time }
                continue
            }
            guard let turn = data["turn"]?.intValue ?? current else { continue }
            switch type {
            case "user/message":
                // Hidden turns carry a host-minted hidden rpcId; the message
                // text never decides visibility.
                let source = data["source"] ?? data["message"]?["source"]
                if BotTurnOrigin(rpcId: source?["rpcId"]?.stringValue).hidden {
                    hidden.insert(turn)
                }
            case "tool/call", "tool/result":
                grouped[turn, default: []].append(record)
            case "turn/end":
                grouped[turn, default: []].append(record)
                ended[turn] = (time, data["reason"]?["kind"]?.stringValue)
            default:
                break
            }
        }
        var result: [Int: BotTurnProcess] = [:]
        for (turn, turnRecords) in grouped where !hidden.contains(turn) {
            let items = processItems(turnRecords)
            guard !items.isEmpty else { continue }
            result[turn] = BotTurnProcess(turn: turn, items: items, startedAt: started[turn],
                                          endedAt: ended[turn]?.time, endKind: ended[turn]?.kind)
        }
        return result
    }

    /// DSH tool rows for these events, minus the tools shown as Bot cards.
    static func processItems(_ records: [JSONValue]) -> [ChatItem] {
        NativeTranscriptProjector.items(from: records, sessionID: "bot").filter(isProcessTool)
    }

    private static func isProcessTool(_ item: ChatItem) -> Bool {
        switch item.kind {
        case .toolCall, .toolResult: break
        default: return false
        }
        let bare = (item.toolName ?? "").components(separatedBy: "__").last ?? ""
        if bare == "ask_user" || bare == "show_next_steps" { return false }
        if bare.split(separator: ".").last == "RequestApproval" { return false }
        return BotDisplayContract.isToolCallVisible(named: bare)
    }
}

/// The running main-chat turn, rebuilt from live frames in arrival order:
/// committed text, groups of tool calls, then the text still streaming.
struct BotLiveTurn: Equatable {
    enum Segment: Equatable {
        case text(String)
        case tools([String])
    }

    var turn: Int?
    var startedAt: Date?
    var segments: [Segment] = []
    /// Text of the model attempt that is streaming now.
    var buffer = ""
    var records: [JSONValue] = []
    var tools: [ChatItem] = []
    var ended = false
    /// Row-projection polls since `turn/end`; the live view gives way to the
    /// durable rows once they carry this turn (or after a few polls).
    var pollsSinceEnd = 0

    mutating func apply(event: JSONValue) {
        guard let type = event["type"]?.stringValue else { return }
        let data = event["data"] ?? .null
        if turn == nil { turn = data["turn"]?.intValue }
        switch type {
        case "turn/start":
            startedAt = event["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
        case "step/start":
            buffer = ""
        case "assistant/message":
            let text = (data["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
            }.joined()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(text))
            }
            buffer = ""
        case "tool/call", "tool/result":
            records.append(event)
            tools = BotTurnProcessProjector.processItems(records)
            if type == "tool/call", let callID = data["callId"]?.stringValue,
               tools.contains(where: { $0.callID == callID }) {
                if case .tools(let ids)? = segments.last {
                    segments[segments.count - 1] = .tools(ids + [callID])
                } else {
                    segments.append(.tools([callID]))
                }
            }
        case "turn/end":
            records.append(event)
            tools = BotTurnProcessProjector.processItems(records)
            if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(buffer))
            }
            buffer = ""
            ended = true
        default:
            break
        }
    }

    func tools(for ids: [String]) -> [ChatItem] {
        ids.compactMap { id in tools.first(where: { $0.callID == id }) }
    }
}

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
    ///
    /// The same journal record can reach a live view twice: a resumed turn
    /// replays its frames and a late WAL poll can deliver the same event again.
    /// `ChatItem.id` is the record seq, so projecting a duplicate creates two
    /// rows with the same id; `ForEach` requires unique ids, and a duplicate id
    /// in a lazy transcript is what froze the Bot chat page in a layout loop.
    /// Deduplicate by the record's own seq before projecting.
    static func processItems(_ records: [JSONValue]) -> [ChatItem] {
        var seen: Set<Int> = []
        let unique = records.filter { record in
            guard let seq = record["seq"]?.intValue else { return true }
            return seen.insert(seq).inserted
        }
        // Defensive: two distinct records can still project to the same item
        // (a call and a result that did not correlate). Keep the first item in
        // transcript order so every downstream ForEach sees unique ids.
        var itemIDs: Set<String> = []
        return NativeTranscriptProjector.items(from: unique, sessionID: "bot")
            .filter(isProcessTool)
            .filter { itemIDs.insert($0.id).inserted }
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
    /// P26 §2.9: a successful content-card call with `final:true` closes the
    /// visible turn. Later text deltas and assistant messages are dropped
    /// here as well as in the host, so the live projection never shows the
    /// sentence the durable projection suppresses.
    private(set) var suppressesText = false
    /// Row-projection polls since `turn/end`; the live view gives way to the
    /// durable rows once they carry this turn (or after a few polls).
    var pollsSinceEnd = 0
    /// `tool/call` metadata needed to correlate the successful final card.
    private var toolFinals: [String: Bool] = [:]
    /// Journal seqs already folded into this live turn. A live observer can be
    /// re-attached across a park/resume, and the resumed stream replays the
    /// open turn from its first record; without this guard the replay appends
    /// duplicate segments and duplicate `ChatItem` ids.
    private var seenSeqs: Set<Int> = []

    mutating func apply(event: JSONValue) {
        guard let type = event["type"]?.stringValue else { return }
        if let seq = event["seq"]?.intValue, !seenSeqs.insert(seq).inserted { return }
        let data = event["data"] ?? .null
        if turn == nil { turn = data["turn"]?.intValue }
        switch type {
        case "turn/start":
            startedAt = event["time"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
            suppressesText = false
            toolFinals = [:]
        case "step/start":
            buffer = ""
        case "assistant/message":
            guard !suppressesText else {
                buffer = ""
                return
            }
            let text = (data["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
            }.joined()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(text))
            }
            buffer = ""
        case "tool/call":
            let callID = data["callId"]?.stringValue ?? ""
            let name = data["name"]?.stringValue ?? ""
            if !callID.isEmpty {
                if let arguments = data["arguments"],
                   Self.isFinalContentCard(name: name, arguments: arguments) {
                    toolFinals[callID] = true
                }
            }
            records.append(event)
            tools = BotTurnProcessProjector.processItems(records)
            if !callID.isEmpty, tools.contains(where: { $0.callID == callID }) {
                if case .tools(let ids)? = segments.last {
                    // A replay may deliver the call once per observer. Never
                    // put the same call id in the segment twice: `tools(for:)`
                    // would return the same ChatItem twice and the row's
                    // ForEach would see duplicate ids.
                    if !ids.contains(callID) {
                        segments[segments.count - 1] = .tools(ids + [callID])
                    }
                } else if !segments.contains(where: { segment in
                    if case .tools(let ids) = segment { return ids.contains(callID) }
                    return false
                }) {
                    segments.append(.tools([callID]))
                }
            }
        case "tool/result":
            let callID = data["message"]?["toolCallId"]?.stringValue
                ?? data["callId"]?.stringValue ?? ""
            let failed = data["message"]?["isError"]?.boolValue == true || data["error"] != nil
            if !failed, toolFinals[callID] == true {
                suppressesText = true
            }
            toolFinals.removeValue(forKey: callID)
            records.append(event)
            tools = BotTurnProcessProjector.processItems(records)
        case "turn/end":
            records.append(event)
            tools = BotTurnProcessProjector.processItems(records)
            if !suppressesText, !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(buffer))
            }
            buffer = ""
            ended = true
        default:
            break
        }
    }

    /// P26 §2.9 keeps `final` as input-only metadata. Parse the recorded
    /// `tool/call` arguments (DSH writes a JSON string; tests may use an
    /// object) and return true only for a boolean true on a content card.
    private static func isFinalContentCard(name: String, arguments: JSONValue) -> Bool {
        let bare = name.components(separatedBy: "__").last ?? name
        guard BotToolCatalog.contentCardNames.contains(bare) else { return false }
        let object: [String: JSONValue]?
        if case .object(let fields) = arguments {
            object = fields
        } else if let text = arguments.stringValue,
                  let parsed = try? JSONValue.parse(Data(text.utf8)),
                  case .object(let fields) = parsed {
            object = fields
        } else {
            object = nil
        }
        return object?["final"]?.boolValue == true
    }

    func tools(for ids: [String]) -> [ChatItem] {
        var seen: Set<String> = []
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return tools.first(where: { $0.callID == id })
        }
    }
}

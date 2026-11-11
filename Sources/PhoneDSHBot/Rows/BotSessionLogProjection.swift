// SPDX-License-Identifier: MIT

import Foundation

/// A DSH surface placement marker (`SurfaceOp` in the pinned DSH session
/// format). DSH v3/v4 writes exactly two shapes:
///
/// - `"append"` — the event joined the model-visible surface at its own log
///   position.
/// - `{"op":"replace","startSeq":<int>,"endSeq":<int>}` — the event replaced an
///   inclusive surface range. Compaction checkpoints and system-prompt head
///   replacements both use this shape.
///
/// Released v0–v2 logs spelled the endpoints `start`/`end`; the v2→v3
/// migration canonicalises them before v3 admission, so this decoder only
/// accepts the canonical v3/v4 object. Anything else is an invalid record and
/// is reported through ``BotDSHSessionLogDiagnostics``.
public enum BotDSHSurfaceOp: Sendable, Equatable {
    case append
    case replace(startSeq: Int, endSeq: Int)

    /// The wire operation name (`append` or `replace`).
    public var op: String {
        switch self {
        case .append: return "append"
        case .replace: return "replace"
        }
    }

    /// The replaced inclusive surface range, or `nil` for an append.
    public var range: ClosedRange<Int>? {
        guard case .replace(let startSeq, let endSeq) = self else { return nil }
        return startSeq...endSeq
    }

    /// Failable decode from an already-parsed JSON value. Used for the legacy
    /// `data.surfaceOp` fallback as well as the envelope decoder.
    public init?(jsonValue: BotJSONValue?) {
        guard let jsonValue else { return nil }
        switch jsonValue {
        case .string("append"):
            self = .append
        case .object(let object):
            guard object.count == 3,
                  stringValue(object["op"]) == "replace",
                  let startSeq = intValue(object["startSeq"]),
                  let endSeq = intValue(object["endSeq"]),
                  startSeq >= 0, endSeq >= startSeq else { return nil }
            self = .replace(startSeq: startSeq, endSeq: endSeq)
        default:
            return nil
        }
    }
}

extension BotDSHSurfaceOp: Codable {
    private enum CodingKeys: String, CodingKey {
        case op, startSeq, endSeq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(BotJSONValue.self)
        guard let op = BotDSHSurfaceOp(jsonValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid DSH surfaceOp")
        }
        self = op
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .append:
            var container = encoder.singleValueContainer()
            try container.encode("append")
        case .replace(let startSeq, let endSeq):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("replace", forKey: .op)
            try container.encode(startSeq, forKey: .startSeq)
            try container.encode(endSeq, forKey: .endSeq)
        }
    }
}

/// One session-log record that could not be decoded and was skipped.
public struct BotDSHSessionLogSkippedRecord: Sendable, Equatable {
    /// 1-based physical line number in the JSONL file.
    public var lineNumber: Int
    /// The record's `seq` when the surrounding JSON was still readable.
    public var seq: Int?

    public init(lineNumber: Int, seq: Int?) {
        self.lineNumber = lineNumber
        self.seq = seq
    }
}

/// Read-only diagnostics for a session-log parse. A damaged record never makes
/// the whole log unreadable: it is skipped and recorded here.
public struct BotDSHSessionLogDiagnostics: Sendable, Equatable {
    public private(set) var skipped: [BotDSHSessionLogSkippedRecord]

    public static let empty = BotDSHSessionLogDiagnostics()

    public init(skipped: [BotDSHSessionLogSkippedRecord] = []) {
        self.skipped = skipped
    }

    /// Number of records skipped while parsing the log.
    public var skippedRecordCount: Int { skipped.count }

    /// `seq` values of the skipped records whose JSON still exposed one.
    public var skippedSeqs: [Int] { skipped.compactMap(\.seq) }
}

/// Result of parsing one DSH session JSONL file. The events are usable even
/// when ``diagnostics`` reports skipped records.
public struct BotDSHSessionLogParseResult: Sendable, Equatable {
    public var events: [BotDSHSessionEvent]
    public var diagnostics: BotDSHSessionLogDiagnostics

    public init(events: [BotDSHSessionEvent],
                diagnostics: BotDSHSessionLogDiagnostics = .empty) {
        self.events = events
        self.diagnostics = diagnostics
    }
}

public struct BotDSHSessionEvent: Codable, Sendable, Equatable {
    public var type: String
    public var seq: Int
    public var time: Int64
    public var data: [String: BotJSONValue]
    public var surfaceOp: BotDSHSurfaceOp?
    public var eventID: String?

    public init(type: String, seq: Int, time: Int64, data: [String: BotJSONValue] = [:],
                surfaceOp: BotDSHSurfaceOp? = nil, eventID: String? = nil) {
        self.type = type
        self.seq = seq
        self.time = time
        self.data = data
        self.surfaceOp = surfaceOp
        self.eventID = eventID
    }

    private enum CodingKeys: String, CodingKey {
        case type, seq, time, data, surfaceOp, eventID = "eventId"
    }

    private struct SessionHeader: Decodable {
        let type: String
        let version: Int
        let id: String
        let createdAt: Int64
        let isSeeded: Bool
        let delegationDepth: Int
    }

    /// Parses a DSH v4 session JSONL file. The session header is not an event;
    /// every other line that does not decode as a canonical event (including an
    /// invalid `surfaceOp` object) is skipped and reported in the returned
    /// diagnostics instead of failing the whole file.
    public static func parseJSONL(_ data: Data) -> BotDSHSessionLogParseResult {
        let decoder = JSONDecoder()
        var events: [BotDSHSessionEvent] = []
        var skipped: [BotDSHSessionLogSkippedRecord] = []
        var firstRecord = true
        for (index, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
            guard !trimmed.isEmpty else { continue }
            let record = Data(trimmed)
            if firstRecord {
                firstRecord = false
                if let header = try? decoder.decode(SessionHeader.self, from: record),
                   header.type == "session", header.version == 4 {
                    continue
                }
            }
            do {
                events.append(try decoder.decode(BotDSHSessionEvent.self, from: record))
            } catch {
                skipped.append(BotDSHSessionLogSkippedRecord(
                    lineNumber: index + 1, seq: skippedSeq(in: record)))
            }
        }
        return BotDSHSessionLogParseResult(
            events: events,
            diagnostics: BotDSHSessionLogDiagnostics(skipped: skipped))
    }

    /// Best-effort `seq` for a record that failed to decode. A syntactically
    /// broken line has no readable seq and remains `nil`.
    private static func skippedSeq(in record: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              let number = object["seq"] as? NSNumber else { return nil }
        return number.intValue
    }
}

enum BotRowChange: Equatable, Sendable {
    case upsert(BotRow)
    case delete(id: String, updatedSeq: Int)

    var updatedSeq: Int {
        switch self {
        case .upsert(let row): return row.updatedSeq
        case .delete(_, let updatedSeq): return updatedSeq
        }
    }

    var id: String {
        switch self {
        case .upsert(let row): return row.id
        case .delete(let id, _): return id
        }
    }

    var isDelete: Bool {
        if case .delete = self { return true }
        return false
    }
}

public struct BotRowProjectionSnapshot: Sendable, Equatable {
    public var rows: [BotRow]
    public var tombstones: [BotRow]
    public var cursor: Int
    var changes: [BotRowChange]

    public static var empty: BotRowProjectionSnapshot {
        BotRowProjectionSnapshot(rows: [], tombstones: [], cursor: 0, changes: [])
    }
}

private struct BotRowOrder: Comparable {
    var time: Int64
    var source: Int
    var sourceSeq: Int
    var index: Int

    static func < (lhs: BotRowOrder, rhs: BotRowOrder) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.sourceSeq != rhs.sourceSeq { return lhs.sourceSeq < rhs.sourceSeq }
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        return lhs.index < rhs.index
    }
}

private struct BotRowDraft {
    var id: String
    var seq: Int
    var kind: BotRowKind
    var role: String?
    var body: BotRowBody
    var provenance: BotRowProvenance
    var createdAt: Int64
    var chatActionNonce: String? = nil
}

private enum BotRowMutation {
    case upsert(BotRowDraft, BotRowOrder)
    case delete(String, BotRowDraft, BotRowOrder)

    var order: BotRowOrder {
        switch self {
        case .upsert(_, let order), .delete(_, _, let order): return order
        }
    }
}

public enum BotRowProjectionError: Error, Sendable, Equatable {
    case cursorRegression
    case inconsistentRebuild
}

/// One main-chat session epoch, oldest first. The newest entry is the live
/// session; older entries are archived and may carry tombstones.
public struct BotSessionEpochProjection: Sendable, Equatable {
    public var sessionID: String
    public var events: [BotDSHSessionEvent]

    public init(sessionID: String, events: [BotDSHSessionEvent]) {
        self.sessionID = sessionID
        self.events = events
    }
}

public struct BotSessionLogProjector: Sendable {
    public init() {}

    public func project(botID: String, sessionID: String,
                        sessionEvents: [BotDSHSessionEvent],
                        uiEvents: [BotEvent], heldRequestNonces: [String: String] = [:]) -> BotRowProjectionSnapshot {
        let heldActionNonces = heldActionNonces(
            botID: botID, sessionID: sessionID, sessionEvents: sessionEvents, uiEvents: uiEvents)
        var mutations = projectDSH(botID: botID, sessionID: sessionID, events: sessionEvents,
                                   heldActionNonces: heldActionNonces,
                                   heldRequestNonces: heldRequestNonces, source: 0)
        mutations.append(contentsOf: projectUI(botID: botID, events: uiEvents, source: 1))
        mutations.sort { $0.order < $1.order }
        return apply(mutations, botID: botID)
    }

    /// Projects the whole main-chat epoch chain in time order. An older
    /// epoch's rows keep their own session ids and sort before the next epoch;
    /// UI events follow every session epoch exactly as the single-epoch form
    /// does.
    public func project(botID: String, epochs: [BotSessionEpochProjection],
                        uiEvents: [BotEvent], heldRequestNonces: [String: String] = [:])
        -> BotRowProjectionSnapshot {
        var mutations: [BotRowMutation] = []
        for (index, epoch) in epochs.enumerated() {
            let heldActionNonces = heldActionNonces(
                botID: botID, sessionID: epoch.sessionID,
                sessionEvents: epoch.events, uiEvents: uiEvents)
            mutations.append(contentsOf: projectDSH(
                botID: botID, sessionID: epoch.sessionID, events: epoch.events,
                heldActionNonces: heldActionNonces,
                heldRequestNonces: heldRequestNonces, source: index))
        }
        mutations.append(contentsOf: projectUI(
            botID: botID, events: uiEvents, source: max(1, epochs.count)))
        mutations.sort { $0.order < $1.order }
        return apply(mutations, botID: botID)
    }

    private func heldActionNonces(botID: String, sessionID: String,
                                  sessionEvents: [BotDSHSessionEvent], uiEvents: [BotEvent]) -> [Int: String] {
        let directNonces = Set(sessionEvents.compactMap { event -> String? in
            guard event.type == "user/message" else { return nil }
            let source = objectValue(event.data["source"])
                ?? objectValue(objectValue(event.data["message"])?["source"])
            return chatActionNonce(source)
        })
        var byTurn: [Int: Set<String>] = [:]
        for event in uiEvents {
            guard event.type == "conversation.turn_started", event.origin.isDirectUser,
                  event.principal.botId == botID, event.principal.sessionId == sessionID,
                  let turn = event.turnId.flatMap(Int.init), turn > 0,
                  let data = objectValue(event.data), stringValue(data["action"]) == "chat",
                  let nonce = nonEmpty(data, "nonce"), event.eventId == "action:\(nonce)",
                  !directNonces.contains(nonce) else { continue }
            byTurn[turn, default: []].insert(nonce)
        }
        return byTurn.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    private func projectDSH(botID: String, sessionID: String, events: [BotDSHSessionEvent],
                            heldActionNonces: [Int: String], heldRequestNonces: [String: String],
                            source: Int) -> [BotRowMutation] {
        let ignored: Set<String> = [
            "session", "permission/preset", "sandbox/mode", "approval/policy",
            "system/message", "developer/message", "agent/inbox/spliced",
            "request/header", "request/context", "session/title", "session/end-seed",
            BotSessionErasureTombstone.type,
            "session-log-deepseek/delivery-accepted", "job/registered", "job/settled",
            "step/start", "step/end", "turn/start", "assistant/stream"
        ]
        var result: [BotRowMutation] = []
        var turn = 0
        var hiddenTurns: Set<Int> = []
        var hiddenFallback = false
        var awaitingCard = false
        var suppressTrailingText = false
        var toolNames: [String: String] = [:]
        var toolFinals: [String: Bool] = [:]
        var calls: [String: (name: String, rowID: String, body: BotRowBody)] = [:]
        var seenEventIDs: Set<String> = []

        for (index, event) in events.enumerated() {
            if let eventID = event.eventID, !seenEventIDs.insert(eventID).inserted { continue }
            let order = BotRowOrder(time: event.time, source: source, sourceSeq: event.seq, index: index)
            if event.type == "turn/start" {
                turn = intValue(event.data["turn"]) ?? turn
                suppressTrailingText = false
                toolFinals = [:]
                continue
            }
            if ignored.contains(event.type) { continue }
            switch event.type {
            case "user/message":
                let message = objectValue(event.data["message"]) ?? [:]
                let role = stringValue(event.data["role"]) ?? stringValue(message["role"])
                let surfaceOp = event.surfaceOp ?? BotDSHSurfaceOp(jsonValue: event.data["surfaceOp"])
                let source = objectValue(event.data["source"]) ?? objectValue(message["source"])
                let sourceKind = source.flatMap { stringValue($0["kind"]) }
                let rawText = contentText(event.data["content"] ?? message["content"])
                let visibleRawText = BotSessionContinuation.strip(rawText)
                let origin = BotTurnOrigin.from(source: source)
                if origin.hidden {
                    if turn > 0 { hiddenTurns.insert(turn) } else { hiddenFallback = true }
                    awaitingCard = false
                    continue
                }
                awaitingCard = false
                // The text prefix is only a fallback for pre-source records;
                // a record that carries `source` is never classified by text.
                let injected = source == nil && isInjected(rawText)
                guard role == "user", surfaceOp == .append, !visibleRawText.isEmpty,
                      !injected, sourceKind == nil || sourceKind == "user" else { continue }
                // Another Bot's immediate message already has its agent-comm
                // row; it is not a user bubble.
                if origin.kind == .agent { continue }
                let visibleText = origin.held ? stripHeldMessages(visibleRawText) : visibleRawText
                let parsed = BotAttachmentPrompt.parse(visibleText)
                var fields = fieldsFrom(message)
                fields["text"] = .string(parsed.text)
                if visibleText.contains(BotAttachmentPrompt.openMarker) {
                    // The user-visible row carries the metadata; the prompt
                    // block never reaches the bubble. `content` is rewritten
                    // too so a consumer that prefers it cannot show the block.
                    if !parsed.attachments.isEmpty {
                        fields["attachments"] = .array(parsed.attachments.compactMap { attachment in
                            guard let data = try? JSONEncoder().encode(attachment) else { return nil }
                            return try? JSONDecoder().decode(BotJSONValue.self, from: data)
                        })
                    }
                    fields["content"] = .array([.object([
                        "type": .string("text"), "text": .string(parsed.text)
                    ])])
                }
                var draft = draft(id: rowID(sessionID, event.seq), event: event, kind: .message,
                                  role: "user", body: BotRowBody(type: .text, additionalProperties: fields),
                                  trust: BotRowProvenance.ownerDirect)
                draft.chatActionNonce = chatActionNonce(source)
                if origin.held {
                    draft.chatActionNonce = heldActionNonces[turn]
                        ?? source.flatMap { stringValue($0["rpcId"]) }.flatMap { heldRequestNonces[$0] }
                }
                result.append(.upsert(draft, order))
            case "assistant/message":
                let message = objectValue(event.data["message"]) ?? [:]
                let messageTurn = intValue(event.data["turn"]) ?? turn
                if hiddenFallback || hiddenTurns.contains(messageTurn) || awaitingCard
                    || suppressTrailingText { continue }
                let blocks = arrayValue(message["content"]) ?? []
                let text = contentText(.array(blocks.filter { stringValue(objectValue($0)?["type"]) == "text" }))
                guard !text.isEmpty else { continue }
                let reasoning = contentText(.array(blocks.filter { stringValue(objectValue($0)?["type"]) == "reasoning" }))
                var fields: [String: BotJSONValue] = ["text": .string(text)]
                if !reasoning.isEmpty { fields["reasoning"] = .string(reasoning) }
                for key in ["step", "turn"] where event.data[key] != nil { fields[key] = event.data[key] }
                let draft = draft(id: rowID(sessionID, event.seq), event: event, kind: .sendMessage,
                                  role: "assistant", body: BotRowBody(type: .text, additionalProperties: fields),
                                  trust: BotRowProvenance.model)
                result.append(.upsert(draft, order))
            case "tool/call":
                let name = stringValue(event.data["name"]) ?? ""
                let callID = stringValue(event.data["callId"]) ?? rowID(sessionID, event.seq)
                toolNames[callID] = name
                let callArguments = parseArguments(stringValue(event.data["arguments"]))
                if isFinalContentCard(name: name, arguments: callArguments) {
                    toolFinals[callID] = true
                }
                guard isApprovalTool(name) else { continue }
                let arguments = callArguments
                let action = nonEmpty(arguments, "action") ?? "未知操作"
                let command = stringValue(arguments["command"]) ?? ""
                let requestID = stringValue(arguments["requestId"])
                    ?? stringValue(event.data["requestId"]) ?? "\(sessionID):\(event.seq):\(callID)"
                let id = rowID(sessionID, event.seq, suffix: "-approval")
                var fields = fieldsFrom(arguments)
                fields["action"] = .string(action)
                fields["command"] = .string(command)
                fields["status"] = .string("pending")
                fields["requestId"] = .string(requestID)
                fields["approvalID"] = .string(requestID)
                fields["callId"] = .string(callID)
                fields["title"] = .string("允许执行「\(action)」吗？")
                fields["text"] = .string("待审批：\(action)")
                fields["ask"] = .object([
                    "requestId": .string(requestID),
                    "action": .string(classifyApproval(command: command)),
                    "target": .string(command.isEmpty ? action : command),
                    "status": .string("pending")
                ])
                let body = BotRowBody(type: .approval, additionalProperties: fields)
                calls[callID] = (name, id, body)
                let draft = draft(id: id, event: event, kind: .sendMessage, role: nil,
                                  body: body, trust: BotRowProvenance.model)
                result.append(.upsert(draft, order))
            case "tool/result":
                let message = objectValue(event.data["message"]) ?? [:]
                let callID = stringValue(message["toolCallId"]) ?? stringValue(event.data["callId"]) ?? ""
                let text = contentText(message["content"])
                if var call = calls[callID] {
                    let status = approvalStatus(text)
                    let resultFields = parseArguments(text)
                    let scope = stringValue(resultFields["scope"])
                    call.body["status"] = .string(status)
                    if let scope { call.body["scope"] = .string(scope) }
                    call.body["resultText"] = .string(text)
                    call.body["text"] = .string("\(approvalLabel(status, scope: scope))：\(stringValue(call.body["action"]) ?? "未知操作")")
                    if var ask = objectValue(call.body["ask"]) {
                        ask["status"] = .string(approvalAskStatus(status))
                        call.body["ask"] = .object(ask)
                    }
                    calls[callID] = call
                    let draft = draft(id: call.rowID, event: event, kind: .sendMessage, role: nil,
                                      body: call.body, trust: BotRowProvenance.model)
                    result.append(.upsert(draft, order))
                }
                let failed = message["isError"]?.boolValue == true || event.data["error"] != nil
                if !failed, toolFinals[callID] == true {
                    // P26 §2.9: this raw session log is the App's durable
                    // projection too. The host already drops the trailing
                    // `conversation.assistant_message`; keeping the same rule
                    // here prevents that sentence from reappearing after a
                    // turn end or a cache rebuild.
                    suppressTrailingText = true
                }
                toolFinals.removeValue(forKey: callID)
                let displayed = text.hasPrefix("已顯示") || text.hasPrefix("已显示") || text.hasPrefix("Displayed")
                let toolName = toolNames[callID] ?? stringValue(event.data["name"]) ?? ""
                if displayed && (toolName.hasSuffix("ask_user") || toolName.hasSuffix("show_next_steps")) {
                    awaitingCard = true
                }
            case "turn/end":
                awaitingCard = false
                suppressTrailingText = false
                toolFinals.removeAll()
                hiddenTurns.remove(turn)
                hiddenFallback = false
                let reason = objectValue(event.data["reason"])
                let reasonKind = reason.flatMap { stringValue($0["kind"]) }
                guard let reasonKind, reasonKind != "completed", reasonKind != "aborted" else { continue }
                let error = reason.flatMap { objectValue($0["error"]) } ?? [:]
                let detail = stringValue(error["message"]).map { "：\(String($0.prefix(200)))" } ?? ""
                let hint = intValue(error["status"]) == 401 ? "（API Key 无效或已被覆盖，请到设置重新粘贴）" : ""
                let text = String("回合失败\(detail)\(hint)".prefix(400))
                let draft = draft(id: rowID(sessionID, event.seq), event: event, kind: .event, role: nil,
                                  body: BotRowBody(type: .notice, additionalProperties: [
                                    "tone": .string("error"), "text": .string(text)
                                  ]), trust: BotRowProvenance.model)
                result.append(.upsert(draft, order))
            default:
                if event.type.hasPrefix("automation/") || event.type.hasPrefix("routine/") {
                    let run = objectValue(event.data["automation"]) ?? objectValue(event.data["routine"])
                        ?? objectValue(event.data["run"]) ?? [:]
                    let automationID = nonEmpty(run, "automationId") ?? nonEmpty(run, "id")
                    let name = nonEmpty(run, "name") ?? nonEmpty(run, "title")
                    guard automationID != nil || name != nil else { continue }
                    let status = automationStatus(run, event: event)
                    var fields = fieldsFrom(run)
                    fields["title"] = .string(name ?? "例行任务")
                    fields["status"] = .string(status)
                    fields["automation"] = .object(run.merging([
                        "automationId": automationID.map(BotJSONValue.string) ?? .null,
                        "name": .string(name ?? "例行任务"),
                        "status": .string(status)
                    ]) { _, new in new })
                    let draft = draft(id: rowID(sessionID, event.seq), event: event, kind: .message, role: nil,
                                      body: BotRowBody(type: .automation, additionalProperties: fields),
                                      trust: BotRowProvenance.model)
                    result.append(.upsert(draft, order))
                }
            }
        }
        return result
    }

    private func projectUI(botID: String, events: [BotEvent], source: Int) -> [BotRowMutation] {
        var result: [BotRowMutation] = []
        var seenEventIDs: Set<String> = []
        let (answeredCards, dismissedCards) = cardOutcomes(botID: botID, events: events)
        for (index, event) in events.sorted(by: stableUIEventOrder).enumerated() {
            // A physically erased payload must not be projected back into a
            // row: the header/digest stay, the content does not.
            guard !event.isErasedPayload else { continue }
            guard event.principal.botId == nil || event.principal.botId == botID,
                  let data = objectValue(event.data), seenEventIDs.insert(event.eventId).inserted else { continue }
            let order = BotRowOrder(time: event.time, source: source, sourceSeq: event.commitSeq ?? 0, index: index)
            if event.type == "transcript.row_deleted" {
                let nested = objectValue(data["row"]) ?? [:]
                guard let id = nonEmpty(data, "rowID") ?? nonEmpty(data, "id") ?? nonEmpty(nested, "id") else { continue }
                let body = BotRowBody(type: .deleted, additionalProperties: ["deletedAt": .number(Double(event.time))])
                let placeholder = BotRowDraft(id: id, seq: entrySeq(event.time, event.commitSeq ?? 0), kind: .event,
                                              role: nil, body: body,
                                              provenance: BotRowProvenance(eventIDs: [event.eventId],
                                                                           trust: BotRowProvenance.projector, tainted: false),
                                              createdAt: event.time)
                result.append(.delete(id, placeholder, order))
                continue
            }
            let supported = ["card.presented", "ui.send_to_user", "ui.notice", "ui.system_event",
                             "agent.comm",
                             "approval.requested", "approval.decided", "task.created", "task.started", "task.updated",
                             "task.stop_requested", "task.settled", "task.resumed", "conversation.automation_run",
                             "routine.run_started", "routine.run_finished", "verification.reported",
                             "bot.greeting_seeded"]
            guard supported.contains(event.type) else { continue }
            var payload = data
            for key in ["row", "entry", "message", "body", "card", "task", "automation", "routine", "run", "notice"] {
                if let nested = objectValue(data[key]) { payload.merge(nested) { _, new in new } }
            }
            let trust = event.origin.isDirectUser ? BotRowProvenance.ownerDirect : BotRowProvenance.model
            let provenance = BotRowProvenance(eventIDs: [event.eventId], trust: trust, tainted: false)
            let fallbackID = "e-ui-\(event.eventId)"
            var id = nonEmpty(payload, "id") ?? nonEmpty(payload, "rowID") ?? fallbackID
            if event.type == "card.presented" {
                // A closed card is locally hidden and must stay hidden after a cache rebuild.
                if dismissedCards.contains(id) { continue }
                if let optionID = answeredCards[id] {
                    payload["status"] = .string("answered")
                    payload["answeredOptionID"] = .string(optionID)
                }
            }
            var kind: BotRowKind = .sendMessage
            var role: String?
            var body: BotRowBody?

            if event.type == "ui.notice" || event.type == "ui.system_event" {
                kind = .event
                body = BotRowBody(type: .notice, additionalProperties: fieldsFrom(payload))
            } else if event.type == "approval.requested" || event.type == "approval.decided" {
                let approvalID = nonEmpty(payload, "approvalID") ?? nonEmpty(payload, "approvalId")
                    ?? nonEmpty(payload, "requestId") ?? nonEmpty(payload, "requestID")
                if let approvalID { id = nonEmpty(payload, "id") ?? "e-\(botID)-approval-\(approvalID)" }
                var fields = fieldsFrom(payload)
                if fields["status"] == nil {
                    let status: String
                    if event.type == "approval.requested" { status = "pending" }
                    else {
                        switch nonEmpty(payload, "decision") {
                        case "deny": status = "denied"
                        case "always": status = "always"
                        default: status = "allowed"
                        }
                    }
                    fields["status"] = .string(status)
                }
                if let approvalID { fields["approvalID"] = .string(approvalID) }
                body = BotRowBody(type: .approval, additionalProperties: fields)
            } else if event.type == "verification.reported" {
                // The verifier event carries the completed task's own fields
                // plus the nested conclusion, so it updates the existing task
                // row in place instead of creating a second card.
                guard payload["subjectKind"]?.stringValue == "task" else { continue }
                let taskID = nonEmpty(payload, "task_id")
                    ?? nonEmpty(payload, "subjectId")
                    ?? nonEmpty(payload, "subjectID")
                if let taskID {
                    id = "e-\(botID)-task-\(taskID)"
                }
                let cardKey = taskID.map { "task:\($0)" }
                body = BotRowBody(type: .widget, cardType: .task, cardKey: cardKey,
                                  additionalProperties: fieldsFrom(payload))
            } else if event.type.hasPrefix("task.") {
                let nativeTaskID = nonEmpty(payload, "task_id")
                let taskID = nativeTaskID ?? nonEmpty(payload, "taskID") ?? nonEmpty(payload, "taskId")
                    ?? nonEmpty(payload, "threadID")
                if let taskID {
                    let stableID = "e-\(botID)-task-\(taskID)"
                    id = nativeTaskID != nil ? stableID : nonEmpty(payload, "id") ?? stableID
                }
                let cardKey = nonEmpty(payload, "cardKey") ?? taskID.map { "task:\($0)" }
                body = BotRowBody(type: .widget, cardType: .task, cardKey: cardKey,
                                  additionalProperties: fieldsFrom(payload))
            } else if event.type == "conversation.automation_run" || event.type.hasPrefix("routine.run_") {
                kind = .message
                let runID = nonEmpty(payload, "runID") ?? nonEmpty(payload, "runId") ?? event.runId
                if let runID { id = nonEmpty(payload, "id") ?? "e-\(botID)-automation-\(runID)" }
                body = BotRowBody(type: .automation, additionalProperties: fieldsFrom(payload))
            } else if event.type == "agent.comm" {
                let comm = objectValue(payload["agentComm"]) ?? [:]
                let direction = nonEmpty(comm, "direction") ?? nonEmpty(payload, "direction")
                role = nonEmpty(payload, "role")
                    ?? ((direction == "inbound" || direction == "incoming") ? "user" : "assistant")
                kind = role == "user" ? .message : .sendMessage
                var fields = fieldsFrom(payload)
                if fields["agentComm"] == nil, !comm.isEmpty { fields["agentComm"] = .object(comm) }
                if fields["text"] == nil,
                   let text = nonEmpty(comm, "message") ?? nonEmpty(comm, "replyText")
                    ?? nonEmpty(payload, "message") ?? nonEmpty(payload, "replyText") {
                    fields["text"] = .string(text)
                }
                body = BotRowBody(type: .text, additionalProperties: fields)
            } else if event.type == "bot.greeting_seeded" {
                role = "assistant"
                var fields = fieldsFrom(payload)
                if fields["text"] == nil { fields["text"] = fields["content"] }
                body = BotRowBody(type: .text, additionalProperties: fields)
            } else {
                body = uiBody(payload, eventType: event.type)
            }
            guard let body else { continue }
            if body.type == .text {
                role = role ?? nonEmpty(payload, "role") ?? "assistant"
                kind = role == "user" ? .message : .sendMessage
                guard nonEmpty(body.additionalProperties, "text") != nil
                        || nonEmpty(body.additionalProperties, "content") != nil
                        || nonEmpty(body.additionalProperties, "replyText") != nil else { continue }
            }
            let draft = BotRowDraft(id: id, seq: entrySeq(event.time, event.commitSeq ?? 0), kind: kind,
                                    role: role, body: body, provenance: provenance, createdAt: event.time)
            result.append(.upsert(draft, order))
        }
        return result
    }

    private func cardOutcomes(botID: String, events: [BotEvent]) -> (answered: [String: String], dismissed: Set<String>) {
        var answered: [String: String] = [:]
        var dismissed: Set<String> = []
        for event in events.sorted(by: stableUIEventOrder) {
            guard event.principal.botId == nil || event.principal.botId == botID,
                  let data = objectValue(event.data),
                  let cardID = nonEmpty(data, "cardID") else { continue }
            switch event.type {
            case "card.answered":
                answered[cardID] = nonEmpty(data, "optionID") ?? answered[cardID] ?? ""
            case "card.dismissed":
                dismissed.insert(cardID)
            default:
                break
            }
        }
        return (answered, dismissed)
    }

    private func uiBody(_ payload: [String: BotJSONValue], eventType: String) -> BotRowBody? {
        if eventType == "card.presented" || payload["cardType"] != nil {
            guard let raw = nonEmpty(payload, "cardType") else { return nil }
            if raw == "attachment" || raw == "file" {
                return BotRowBody(type: .attachment, cardKey: nonEmpty(payload, "cardKey"),
                                  additionalProperties: fieldsFrom(payload))
            }
            guard let cardType = BotWidgetCardType(rawValue: raw) else { return nil }
            return BotRowBody(type: .widget, cardType: cardType, cardKey: nonEmpty(payload, "cardKey"),
                              additionalProperties: fieldsFrom(payload))
        }
        let rawType = nonEmpty(payload, "type") ?? "text"
        switch rawType {
        case "text": return BotRowBody(type: .text, additionalProperties: fieldsFrom(payload))
        case "attachment": return BotRowBody(type: .attachment, cardKey: nonEmpty(payload, "cardKey"),
                                             additionalProperties: fieldsFrom(payload))
        case "widget": return nil
        case "local-tool-permission", "approval": return BotRowBody(type: .approval, additionalProperties: fieldsFrom(payload))
        case "automation": return BotRowBody(type: .automation, additionalProperties: fieldsFrom(payload))
        case "notice": return BotRowBody(type: .notice, additionalProperties: fieldsFrom(payload))
        default: return nil
        }
    }

    private func apply(_ mutations: [BotRowMutation], botID: String) -> BotRowProjectionSnapshot {
        var rows: [String: BotRow] = [:]
        var tombstones: [String: BotRow] = [:]
        var progressRows: [String: String] = [:]
        var changes: [BotRowChange] = []
        var cursor = 0

        for mutation in mutations {
            switch mutation {
            case .upsert(let input, _):
                var id = input.id
                var progressKey: String?
                if input.body.type == .widget, input.body.cardType == .progress, let cardKey = input.body.cardKey {
                    progressKey = "\(botID):\(cardKey)"
                    if let existingID = progressRows[progressKey!] { id = existingID }
                }
                if tombstones[id] != nil { continue }
                let old = rows[id]
                var eventIDs = old?.provenance.eventIDs ?? []
                for eventID in input.provenance.eventIDs where !eventIDs.contains(eventID) { eventIDs.append(eventID) }
                let provenance = BotRowProvenance(eventIDs: eventIDs, trust: input.provenance.trust,
                                                  tainted: (old?.provenance.tainted ?? false) || input.provenance.tainted)
                var row = BotRow(id: id, botID: botID, seq: old?.seq ?? input.seq, updatedSeq: old?.updatedSeq ?? 0,
                                 kind: input.kind, role: input.role, body: input.body, provenance: provenance,
                                 streaming: false, createdAt: old?.createdAt ?? input.createdAt)
                // A verifier report updates the existing Task card in place:
                // keep the step list and earlier fields, then overlay the new
                // status/verification so the card does not lose its shape.
                if let old, old.body.cardType == .task, row.body.cardType == .task {
                    var merged = old.body.additionalProperties
                    for (key, value) in row.body.additionalProperties { merged[key] = value }
                    row.body.additionalProperties = merged
                }
                row.chatActionNonce = input.chatActionNonce
                if let old, sameContent(old, row) {
                    if let progressKey { progressRows[progressKey] = id }
                    continue
                }
                cursor += 1
                row.updatedSeq = cursor
                rows[id] = row
                if let progressKey { progressRows[progressKey] = id }
                changes.append(.upsert(row))
            case .delete(let id, let placeholder, _):
                if tombstones[id] != nil { continue }
                cursor += 1
                let old = rows[id]
                var body = old?.body ?? placeholder.body
                body.type = .deleted
                body.cardType = nil
                body.cardKey = nil
                body.additionalProperties = placeholder.body.additionalProperties
                if let old { body["deletedKind"] = .string(old.kind.rawValue) }
                var eventIDs = old?.provenance.eventIDs ?? []
                for eventID in placeholder.provenance.eventIDs where !eventIDs.contains(eventID) { eventIDs.append(eventID) }
                let tombstone = BotRow(id: id, botID: botID, seq: old?.seq ?? placeholder.seq, updatedSeq: cursor,
                                       kind: .event, role: nil, body: body,
                                       provenance: BotRowProvenance(eventIDs: eventIDs,
                                                                    trust: BotRowProvenance.projector, tainted: false),
                                       streaming: false, createdAt: old?.createdAt ?? placeholder.createdAt)
                rows.removeValue(forKey: id)
                tombstones[id] = tombstone
                progressRows = progressRows.filter { $0.value != id }
                changes.append(.delete(id: id, updatedSeq: cursor))
            }
        }
        return BotRowProjectionSnapshot(rows: rows.values.sorted(by: rowOrder),
                                        tombstones: tombstones.values.sorted(by: rowOrder),
                                        cursor: cursor, changes: changes)
    }

    private func draft(id: String, event: BotDSHSessionEvent, kind: BotRowKind, role: String?,
                       body: BotRowBody, trust: String) -> BotRowDraft {
        BotRowDraft(id: id, seq: entrySeq(event.time, event.seq), kind: kind, role: role, body: body,
                    provenance: BotRowProvenance(eventIDs: event.eventID.map { [$0] } ?? [], trust: trust, tainted: false),
                    createdAt: event.time)
    }
}

public actor BotRowHistory {
    private var snapshot: BotRowProjectionSnapshot
    private let projector: BotSessionLogProjector

    public init(snapshot: BotRowProjectionSnapshot = .empty, projector: BotSessionLogProjector = BotSessionLogProjector()) {
        self.snapshot = snapshot
        self.projector = projector
    }

    public func history() -> [BotRow] { snapshot.rows }

    public func tombstones() -> [BotRow] { snapshot.tombstones }

    public func cursor() -> Int { snapshot.cursor }

    @discardableResult
    public func rebuild(botID: String, sessionID: String, sessionEvents: [BotDSHSessionEvent],
                        uiEvents: [BotEvent], heldRequestNonces: [String: String] = [:]) throws -> BotRowBatch {
        try rebuild(botID: botID,
                    epochs: [BotSessionEpochProjection(sessionID: sessionID, events: sessionEvents)],
                    uiEvents: uiEvents, heldRequestNonces: heldRequestNonces)
    }

    @discardableResult
    public func rebuild(botID: String, epochs: [BotSessionEpochProjection],
                        uiEvents: [BotEvent], heldRequestNonces: [String: String] = [:]) throws -> BotRowBatch {
        let projected = projector.project(botID: botID, epochs: epochs,
                                          uiEvents: uiEvents,
                                          heldRequestNonces: heldRequestNonces)
        snapshot = reconciled(projected)
        return resetBatch()
    }

    public func replaceWithRebuiltCache(_ rebuilt: BotRowProjectionSnapshot) throws {
        snapshot = reconciled(rebuilt)
    }

    public func watch(after cursor: Int) -> BotRowBatch {
        if cursor <= 0 || cursor > snapshot.cursor { return resetBatch() }
        let selected = snapshot.changes.filter { $0.updatedSeq > cursor }
        var latest: [String: BotRowChange] = [:]
        for change in selected { latest[change.id] = change }
        let ordered = latest.values.sorted { $0.updatedSeq < $1.updatedSeq }
        return BotRowBatch(rows: ordered.compactMap { change in
            if case .upsert(let row) = change { return row }
            return nil
        }, deletes: ordered.filter(\.isDelete).map(\.id), cursor: snapshot.cursor, reset: false)
    }

    private func reconciled(_ projected: BotRowProjectionSnapshot) -> BotRowProjectionSnapshot {
        if snapshot.cursor == 0 && snapshot.rows.isEmpty && snapshot.tombstones.isEmpty && snapshot.changes.isEmpty {
            return projected
        }
        var rows = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        var tombstones = Dictionary(uniqueKeysWithValues: snapshot.tombstones.map { ($0.id, $0) })
        var changes = snapshot.changes
        var cursor = snapshot.cursor
        let projectedRowIDs = Set(projected.rows.map(\.id))
        let projectedTombstoneIDs = Set(projected.tombstones.map(\.id))

        for candidate in projected.rows {
            guard tombstones[candidate.id] == nil else { continue }
            if let old = rows[candidate.id], sameContent(old, candidate) {
                rows[candidate.id] = old
                continue
            }
            cursor += 1
            var inserted = candidate
            inserted.updatedSeq = cursor
            rows[candidate.id] = inserted
            changes.append(.upsert(inserted))
        }

        for candidate in projected.tombstones where tombstones[candidate.id] == nil {
            cursor += 1
            var deleted = candidate
            deleted.updatedSeq = cursor
            rows.removeValue(forKey: candidate.id)
            tombstones[candidate.id] = deleted
            changes.append(.delete(id: candidate.id, updatedSeq: cursor))
        }

        for previous in snapshot.rows {
            guard !projectedRowIDs.contains(previous.id), !projectedTombstoneIDs.contains(previous.id),
                  tombstones[previous.id] == nil, rows.removeValue(forKey: previous.id) != nil else { continue }
            cursor += 1
            changes.append(.delete(id: previous.id, updatedSeq: cursor))
        }
        return BotRowProjectionSnapshot(rows: rows.values.sorted(by: rowOrder),
                                        tombstones: tombstones.values.sorted(by: rowOrder),
                                        cursor: cursor, changes: changes)
    }

    private func resetBatch() -> BotRowBatch {
        BotRowBatch(rows: snapshot.rows,
                    deletes: snapshot.tombstones.sorted { $0.updatedSeq < $1.updatedSeq }.map(\.id),
                    cursor: snapshot.cursor, reset: true)
    }
}

private func stableUIEventOrder(_ lhs: BotEvent, _ rhs: BotEvent) -> Bool {
    let lseq = lhs.commitSeq ?? Int.max
    let rseq = rhs.commitSeq ?? Int.max
    if lseq != rseq { return lseq < rseq }
    if lhs.time != rhs.time { return lhs.time < rhs.time }
    return lhs.eventId < rhs.eventId
}

private func rowOrder(_ lhs: BotRow, _ rhs: BotRow) -> Bool {
    if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
    return lhs.id < rhs.id
}

private func sameContent(_ lhs: BotRow, _ rhs: BotRow) -> Bool {
    lhs.id == rhs.id && lhs.botID == rhs.botID && lhs.seq == rhs.seq && lhs.kind == rhs.kind
        && lhs.role == rhs.role && lhs.body == rhs.body && lhs.provenance == rhs.provenance
        && lhs.streaming == rhs.streaming && lhs.createdAt == rhs.createdAt
        && lhs.chatActionNonce == rhs.chatActionNonce
}

private func rowID(_ sessionID: String, _ seq: Int, suffix: String = "") -> String {
    "e-\(sessionID)-\(seq)\(suffix)"
}

private func entrySeq(_ time: Int64, _ sourceSeq: Int) -> Int {
    let positiveSource = max(0, sourceSeq) % 1000
    let (milliseconds, overflow) = time.multipliedReportingOverflow(by: 1000)
    if overflow || milliseconds > Int64(Int.max) || milliseconds < Int64(Int.min) { return time < 0 ? Int.min : Int.max }
    let value = Int(milliseconds)
    let (result, additionOverflow) = value.addingReportingOverflow(positiveSource)
    return additionOverflow ? Int.max : result
}

private func isInjected(_ text: String) -> Bool {
    text.isEmpty || text.hasPrefix("Current runtime context.") || text.hasPrefix("<system-reminder>")
        || text.hasPrefix("Check the [exit code: N] marker")
}

private func stripHeldMessages(_ text: String) -> String {
    let open = "<held_agent_messages>"
    let close = "</held_agent_messages>"
    guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else {
        return text
    }
    let before = String(text[..<start.lowerBound])
    var after = String(text[end.upperBound...])
    while after.hasPrefix("\n") || after.hasPrefix("\r") { after.removeFirst() }
    return (before + after).replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func contentText(_ value: BotJSONValue?) -> String {
    guard let blocks = arrayValue(value) else { return "" }
    return blocks.compactMap { block -> String? in
        guard let object = objectValue(block), stringValue(object["type"]) == "text" else { return nil }
        return stringValue(object["text"])
    }.joined()
}

private func isFinalContentCard(name: String, arguments: [String: BotJSONValue]) -> Bool {
    guard let bare = BotToolCatalog.contentCardNames.first(where: { candidate in
        name == candidate || name.hasSuffix("__\(candidate)")
    }) else { return false }
    return (try? BotCardPayloads.contentCardFinal(tool: bare, arguments: .object(arguments))) == true
}

private func parseArguments(_ text: String?) -> [String: BotJSONValue] {
    guard let text, let data = text.data(using: .utf8),
          let value = try? JSONDecoder().decode(BotJSONValue.self, from: data) else { return [:] }
    return objectValue(value) ?? [:]
}

private func isApprovalTool(_ name: String) -> Bool {
    name.components(separatedBy: "__").last?.split(separator: ".").last == "RequestApproval"
}

private func chatActionNonce(_ source: [String: BotJSONValue]?) -> String? {
    guard stringValue(source?["kind"]) == "user" else { return nil }
    return BotTurnOrigin.userActionNonce(from: stringValue(source?["rpcId"]))
}

private func approvalStatus(_ text: String) -> String {
    let fields = parseArguments(text)
    if fields["pending"]?.boolValue == true { return "pending" }
    if fields["allowed"]?.boolValue == false || stringValue(fields["decision"]) == "denied" {
        return "denied"
    }
    if fields["allowed"]?.boolValue == true {
        // The actual user decision and effective grant scope travel with the
        // tool result. A session grant must not render as "allowed once".
        switch stringValue(fields["approvalDecision"]) {
        case "always":
            return stringValue(fields["scope"]) == "session" ? "allowed-session" : "always"
        case "allowOnce":
            return "allowed"
        case "deny":
            return "denied"
        default:
            switch stringValue(fields["scope"]) {
            case "session": return "allowed-session"
            case "until": return "always"
            default: return "allowed"
            }
        }
    }
    let lower = text.lowercased()
    if text.contains("永不允许") || text.contains("永不允許") || lower.contains("never allow") { return "never" }
    if text.contains("总是允许") || text.contains("總是允許") || lower.contains("always allow") { return "always" }
    if text.contains("超时") || text.contains("逾時") || lower.contains("timed out") || lower.contains("timeout") { return "timed-out" }
    if text.contains("拒绝") || text.contains("拒絕") || lower.contains("denied") || lower.contains("rejected")
        || lower.contains("not allowed") { return "denied" }
    if text.contains("允许") || text.contains("允許") || lower.contains("allowed") { return "allowed" }
    return "unknown"
}

private func approvalLabel(_ status: String, scope: String? = nil) -> String {
    BotApprovalReceipt.label(for: status, scope: scope)
}

private func approvalAskStatus(_ status: String) -> String {
    switch status {
    case "allowed", "allowed-session", "always": return "allowed"
    case "timed-out": return "timed-out"
    case "unknown": return "pending"
    default: return status
    }
}

private func classifyApproval(command: String) -> String {
    command.isEmpty ? "other" : "command-execution"
}

private func automationStatus(_ run: [String: BotJSONValue], event: BotDSHSessionEvent) -> String {
    let raw = (stringValue(run["status"]) ?? stringValue(event.data["status"]) ?? "").lowercased()
    if ["confirming", "running", "sent", "failed", "idle"].contains(raw) { return raw }
    let tail = event.type.split(separator: "/").last.map(String.init) ?? ""
    if ["start", "started", "run", "running"].contains(tail) { return "running" }
    if ["end", "ended", "done", "completed", "sent"].contains(tail) { return "sent" }
    if ["fail", "failed", "error"].contains(tail) { return "failed" }
    return "idle"
}

private func fieldsFrom(_ object: [String: BotJSONValue]) -> [String: BotJSONValue] {
    object.filter { !["id", "rowID", "type", "cardType", "cardKey", "trust", "tainted"].contains($0.key) }
}

private func nonEmpty(_ object: [String: BotJSONValue], _ key: String) -> String? {
    guard let value = stringValue(object[key]), !value.isEmpty else { return nil }
    return value
}

private func objectValue(_ value: BotJSONValue?) -> [String: BotJSONValue]? {
    BotRowJSON.object(value)
}

private func arrayValue(_ value: BotJSONValue?) -> [BotJSONValue]? {
    BotRowJSON.array(value)
}

private func stringValue(_ value: BotJSONValue?) -> String? {
    guard case .string(let string) = value else { return nil }
    return string
}

private func intValue(_ value: BotJSONValue?) -> Int? {
    guard case .number(let number) = value, number.isFinite, number.rounded() == number,
          number >= Double(Int.min), number <= Double(Int.max) else { return nil }
    return Int(number)
}

private extension BotEventOrigin {
    var isDirectUser: Bool {
        if case .local(let source) = self { return source == "user" }
        return false
    }
}

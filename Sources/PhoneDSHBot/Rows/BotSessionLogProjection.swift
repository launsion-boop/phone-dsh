// SPDX-License-Identifier: MIT

import Foundation

public struct BotDSHSessionEvent: Codable, Sendable, Equatable {
    public var type: String
    public var seq: Int
    public var time: Int64
    public var data: [String: BotJSONValue]
    public var surfaceOp: String?
    public var eventID: String?

    public init(type: String, seq: Int, time: Int64, data: [String: BotJSONValue] = [:],
                surfaceOp: String? = nil, eventID: String? = nil) {
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

    public static func parseJSONL(_ data: Data) throws -> [BotDSHSessionEvent] {
        try data.split(separator: 0x0A).compactMap { line in
            let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
            guard !trimmed.isEmpty else { return nil }
            return try JSONDecoder().decode(BotDSHSessionEvent.self, from: Data(trimmed))
        }
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

public struct BotSessionLogProjector: Sendable {
    public init() {}

    public func project(botID: String, sessionID: String,
                        sessionEvents: [BotDSHSessionEvent],
                        uiEvents: [BotEvent]) -> BotRowProjectionSnapshot {
        var mutations = projectDSH(botID: botID, sessionID: sessionID, events: sessionEvents)
        mutations.append(contentsOf: projectUI(botID: botID, events: uiEvents))
        mutations.sort { $0.order < $1.order }
        return apply(mutations, botID: botID)
    }

    private func projectDSH(botID: String, sessionID: String,
                            events: [BotDSHSessionEvent]) -> [BotRowMutation] {
        let ignored: Set<String> = [
            "session", "permission/preset", "sandbox/mode", "approval/policy",
            "system/message", "developer/message", "agent/inbox/spliced",
            "request/header", "request/context", "session/title", "session/end-seed",
            "session-log-deepseek/delivery-accepted", "job/registered", "job/settled",
            "step/start", "step/end", "turn/start", "assistant/stream"
        ]
        var result: [BotRowMutation] = []
        var turn = 0
        var hiddenTurns: Set<Int> = []
        var hiddenFallback = false
        var awaitingCard = false
        var toolNames: [String: String] = [:]
        var calls: [String: (name: String, rowID: String, body: BotRowBody)] = [:]
        var seenEventIDs: Set<String> = []

        for (index, event) in events.enumerated() {
            if let eventID = event.eventID, !seenEventIDs.insert(eventID).inserted { continue }
            let order = BotRowOrder(time: event.time, source: 0, sourceSeq: event.seq, index: index)
            if event.type == "turn/start" {
                turn = intValue(event.data["turn"]) ?? turn
                continue
            }
            if ignored.contains(event.type) { continue }
            switch event.type {
            case "user/message":
                let message = objectValue(event.data["message"]) ?? [:]
                let role = stringValue(event.data["role"]) ?? stringValue(message["role"])
                let surfaceOp = event.surfaceOp ?? stringValue(event.data["surfaceOp"])
                let source = objectValue(event.data["source"]) ?? objectValue(message["source"])
                let sourceKind = source.flatMap { stringValue($0["kind"]) }
                let rawText = contentText(event.data["content"] ?? message["content"])
                if rawText.hasPrefix("[SAND_HIDDEN_PROMPT]") {
                    if turn > 0 { hiddenTurns.insert(turn) } else { hiddenFallback = true }
                    awaitingCard = false
                    continue
                }
                awaitingCard = false
                guard role == "user", surfaceOp == "append", !rawText.isEmpty,
                      !isInjected(rawText), sourceKind == nil || sourceKind == "user" else { continue }
                let visibleText = stripHeldMessages(rawText)
                var fields = fieldsFrom(message)
                fields["text"] = .string(visibleText)
                let draft = draft(id: rowID(sessionID, event.seq), event: event, kind: .message,
                                  role: "user", body: BotRowBody(type: .text, additionalProperties: fields),
                                  trust: BotRowProvenance.ownerDirect)
                result.append(.upsert(draft, order))
            case "assistant/message":
                let message = objectValue(event.data["message"]) ?? [:]
                let messageTurn = intValue(event.data["turn"]) ?? turn
                if hiddenFallback || hiddenTurns.contains(messageTurn) || awaitingCard { continue }
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
                guard isApprovalTool(name) else { continue }
                let arguments = parseArguments(stringValue(event.data["arguments"]))
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
                fields["title"] = .string("允許執行「\(action)」嗎？")
                fields["text"] = .string("待審批：\(action)")
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
                    call.body["status"] = .string(status)
                    call.body["resultText"] = .string(text)
                    call.body["text"] = .string("\(approvalLabel(status))：\(stringValue(call.body["action"]) ?? "未知操作")")
                    if var ask = objectValue(call.body["ask"]) {
                        ask["status"] = .string(approvalAskStatus(status))
                        call.body["ask"] = .object(ask)
                    }
                    calls[callID] = call
                    let draft = draft(id: call.rowID, event: event, kind: .sendMessage, role: nil,
                                      body: call.body, trust: BotRowProvenance.model)
                    result.append(.upsert(draft, order))
                }
                let displayed = text.hasPrefix("已顯示") || text.hasPrefix("已显示") || text.hasPrefix("Displayed")
                let toolName = toolNames[callID] ?? stringValue(event.data["name"]) ?? ""
                if displayed && (toolName.hasSuffix("ask_user") || toolName.hasSuffix("show_next_steps")) {
                    awaitingCard = true
                }
            case "turn/end":
                awaitingCard = false
                hiddenTurns.remove(turn)
                hiddenFallback = false
                let reason = objectValue(event.data["reason"])
                let reasonKind = reason.flatMap { stringValue($0["kind"]) }
                guard let reasonKind, reasonKind != "completed", reasonKind != "aborted" else { continue }
                let error = reason.flatMap { objectValue($0["error"]) } ?? [:]
                let detail = stringValue(error["message"]).map { "：\(String($0.prefix(200)))" } ?? ""
                let hint = intValue(error["status"]) == 401 ? "（API Key 無效或已被覆蓋，請到設定重新貼上）" : ""
                let text = String("回合失敗\(detail)\(hint)".prefix(400))
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
                    fields["title"] = .string(name ?? "例行工作")
                    fields["status"] = .string(status)
                    fields["automation"] = .object(run.merging([
                        "automationId": automationID.map(BotJSONValue.string) ?? .null,
                        "name": .string(name ?? "例行工作"),
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

    private func projectUI(botID: String, events: [BotEvent]) -> [BotRowMutation] {
        var result: [BotRowMutation] = []
        var seenEventIDs: Set<String> = []
        let (answeredCards, dismissedCards) = cardOutcomes(botID: botID, events: events)
        for (index, event) in events.sorted(by: stableUIEventOrder).enumerated() {
            guard event.principal.botId == nil || event.principal.botId == botID,
                  let data = objectValue(event.data), seenEventIDs.insert(event.eventId).inserted else { continue }
            let order = BotRowOrder(time: event.time, source: 1, sourceSeq: event.commitSeq ?? 0, index: index)
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
                             "approval.requested", "approval.decided", "task.created", "task.started", "task.updated",
                             "task.stop_requested", "task.settled", "task.resumed", "conversation.automation_run",
                             "routine.run_started", "routine.run_finished", "bot.greeting_seeded"]
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
            } else if event.type.hasPrefix("task.") {
                let taskID = nonEmpty(payload, "taskID") ?? nonEmpty(payload, "taskId") ?? nonEmpty(payload, "threadID")
                if let taskID { id = nonEmpty(payload, "id") ?? "e-\(botID)-task-\(taskID)" }
                let cardKey = nonEmpty(payload, "cardKey") ?? taskID.map { "task:\($0)" }
                body = BotRowBody(type: .widget, cardType: .task, cardKey: cardKey,
                                  additionalProperties: fieldsFrom(payload))
            } else if event.type == "conversation.automation_run" || event.type.hasPrefix("routine.run_") {
                kind = .message
                let runID = nonEmpty(payload, "runID") ?? nonEmpty(payload, "runId") ?? event.runId
                if let runID { id = nonEmpty(payload, "id") ?? "e-\(botID)-automation-\(runID)" }
                body = BotRowBody(type: .automation, additionalProperties: fieldsFrom(payload))
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
                guard nonEmpty(payload, "text") != nil || nonEmpty(payload, "content") != nil else { continue }
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
                        uiEvents: [BotEvent]) throws -> BotRowBatch {
        let projected = projector.project(botID: botID, sessionID: sessionID,
                                          sessionEvents: sessionEvents, uiEvents: uiEvents)
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

private func parseArguments(_ text: String?) -> [String: BotJSONValue] {
    guard let text, let data = text.data(using: .utf8),
          let value = try? JSONDecoder().decode(BotJSONValue.self, from: data) else { return [:] }
    return objectValue(value) ?? [:]
}

private func isApprovalTool(_ name: String) -> Bool {
    name.components(separatedBy: "__").last?.split(separator: ".").last == "RequestApproval"
}

private func approvalStatus(_ text: String) -> String {
    let lower = text.lowercased()
    if text.contains("永不允許") || lower.contains("never allow") { return "never" }
    if text.contains("總是允許") || lower.contains("always allow") { return "always" }
    if text.contains("逾時") || lower.contains("timed out") || lower.contains("timeout") { return "timed-out" }
    if text.contains("允許") || lower.contains("allowed") { return "allowed" }
    if text.contains("拒絕") || lower.contains("denied") || lower.contains("rejected") { return "denied" }
    return "unknown"
}

private func approvalLabel(_ status: String) -> String {
    switch status {
    case "allowed": return "已允許一次"
    case "always": return "已總是允許"
    case "denied": return "已拒絕"
    case "never": return "已設為永不允許"
    case "timed-out": return "逾時未回應（視為拒絕）"
    default: return "已處理"
    }
}

private func approvalAskStatus(_ status: String) -> String {
    switch status {
    case "allowed", "always": return "allowed"
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

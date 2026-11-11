// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore
import PhoneDSHBot

// The production Bot page speaks the UI driver vocabulary. These adapters are
// the only place that bridges the durable `BotProductionRowService` projection
// and the UI-facing rows/actions; the fixture models never run through them.

extension BotProductionRowService {
    func chatDriver() -> BotChatDriver {
        BotChatDriver(
            history: { [self] cursor, limit in
                let page = try await self.history(before: cursor, limit: limit)
                return BotUIHistoryPage(
                    rows: page.rows.map(BotUIRow.init(row:)),
                    nextCursor: page.nextCursor, hasMore: page.hasMore)
            },
            watch: { [self] cursor in
                let batch = try await self.watch(after: cursor)
                return BotUIRowBatch(
                    rows: batch.rows.map(BotUIRow.init(row:)),
                    deletes: batch.deletes, cursor: batch.cursor, reset: batch.reset)
            },
            perform: { [self] action in
                do {
                    return BotUIActionResult(try await self.perform(BotUserAction(action)))
                } catch {
                    return .rejected(reason: error.localizedDescription)
                }
            },
            stopCurrentTurn: { [self] turnID in
                try? await self.stopCurrentTurn(turnID: turnID)
            },
            turnProcesses: { [self] in await self.turnProcesses() },
            liveFrames: { [self] in
                let frames = await self.liveFrames()
                return AsyncStream { continuation in
                    let task = Task {
                        for await frame in frames {
                            if let mapped = BotLiveFrame(frame) { continuation.yield(mapped) }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            presentation: { [self] in
                try await self.presentation()
            })
    }
}

extension BotLiveFrame {
    init?(_ frame: BotLiveTurnFrame) {
        switch frame.kind {
        case .streamStart:
            self = .streamStart
        case .textDelta(let text):
            self = .textDelta(text)
        case .event(let event):
            guard let data = try? JSONEncoder().encode(event),
                  let value = try? JSONValue.parse(data) else { return nil }
            self = .event(value)
        }
    }
}

extension BotProductionInfoService {
    func infoDriver() -> BotInfoDriver {
        BotInfoDriver(
            load: { [self] in try await BotInfoSnapshot.production(self.load()) },
            rename: { [self] name in try await self.rename(name) },
            forget: { [self] fact in try await self.forget(factID: fact.id) },
            erase: { [self] in try await self.eraseMemories() },
            eraseShared: { [self] in try await self.eraseSharedMemories() },
            setRoutineEnabled: { [self] id, enabled in
                try await self.setRoutineEnabled(id, enabled: enabled)
            },
            saveProactiveSettings: { [self] settings in
                await self.saveProactiveSettings(settings)
            })
    }
}

extension BotUIRow {
    init(row: BotRow) {
        var values = row.body.additionalProperties.mapValues(BotJSONValue.init(production:))
        if let cardType = row.body.cardType {
            values["cardType"] = .string(cardType.rawValue)
        }
        if let cardKey = row.body.cardKey {
            values["cardKey"] = .string(cardKey)
        }
        self.init(
            id: row.id, botID: row.botID, seq: row.seq, updatedSeq: row.updatedSeq,
            kind: row.kind.rawValue, role: row.role,
            body: BotUIBody(type: row.body.type.rawValue, values: values),
            provenance: BotUIProvenance(
                eventIDs: row.provenance.eventIDs,
                trust: row.provenance.trust,
                tainted: row.provenance.tainted),
            streaming: row.streaming,
            createdAt: Int(clamping: row.createdAt))
        chatActionNonce = row.chatActionNonce
    }
}

private extension BotJSONValue {
    /// The row projection and the UI body are two JSON models. Bridge through
    /// their shared Codable representation instead of re-mapping every case.
    init(production value: PhoneDSHBot.BotJSONValue) {
        guard let data = try? JSONEncoder().encode(value),
              let converted = try? JSONDecoder().decode(BotJSONValue.self, from: data) else {
            self = .null
            return
        }
        self = converted
    }
}

extension BotUserAction {
    init(_ action: BotUIUserAction) {
        switch action {
        case .chat(let nonce, let botID, let text, let attachments):
            self.init(nonce: nonce, botID: botID, kind: .chat, text: text,
                      attachments: attachments)
        case .cardAnswer(let nonce, let botID, let cardID, let optionID):
            self.init(nonce: nonce, botID: botID, kind: .cardAnswer,
                      cardID: cardID, optionID: optionID)
        case .cardDismiss(let nonce, let botID, let cardID):
            self.init(nonce: nonce, botID: botID, kind: .cardDismiss, cardID: cardID)
        case .approval(let nonce, let botID, let approvalID, let decision, let digest):
            self.init(nonce: nonce, botID: botID, kind: .approval,
                      approvalID: approvalID,
                      decision: decision.productionDecision, digest: digest)
        case .stopTask(let nonce, let botID, let threadID):
            self.init(nonce: nonce, botID: botID, kind: .stopTask, threadID: threadID)
        }
    }
}

private extension BotUIApprovalDecision {
    var productionDecision: BotApprovalDecision {
        switch self {
        case .allowOnce: return .allowOnce
        case .always: return .always
        case .deny: return .deny
        }
    }
}

extension BotUIActionResult {
    init(_ result: BotActionResult) {
        switch result {
        case .accepted(let eventID): self = .accepted(eventID: eventID)
        case .duplicate(let eventID): self = .duplicate(eventID: eventID)
        case .stale(let reason): self = .stale(reason: reason)
        case .rejected(let reason): self = .rejected(reason: reason)
        }
    }
}

extension BotInfoSnapshot {
    static func production(_ snapshot: BotProductionInfoSnapshot) -> BotInfoSnapshot {
        BotInfoSnapshot(
            botName: snapshot.botName,
            memories: snapshot.memories.map { fact in
                BotMemoryFact(
                    id: fact.factID,
                    text: fact.text,
                    tier: fact.tier.rawValue,
                    scope: fact.scope.rawValue,
                    source: fact.source?.kind.rawValue ?? "unknown",
                    learnedAt: Date(timeIntervalSince1970: Double(fact.learnedAtMS) / 1_000))
            },
            routines: snapshot.routines.map { routine in
                BotRoutineInfo(
                    id: routine.id,
                    title: routine.title,
                    schedule: Self.scheduleText(routine.schedule),
                    timeZone: routine.schedule.timezone,
                    delivery: routine.delivery == .interrupt ? "立即打断" : "存入待处理",
                    quiet: routine.delivery == .held,
                    urgent: routine.urgent,
                    urgentReason: routine.urgentReason.isEmpty ? nil : routine.urgentReason,
                    lastResult: Self.lastResultText(routine.lastResult),
                    enabled: routine.enabled)
            },
            approvals: snapshot.approvals.map { approval in
                BotApprovalRecord(
                    id: approval.id,
                    parameterSummary: approval.parameterSummary,
                    decision: approval.decision == .allow ? "允许" : "拒绝",
                    decidedAt: Date(timeIntervalSince1970: Double(approval.decidedAtMS) / 1_000))
            },
            presence: snapshot.presence,
            proactiveSettings: snapshot.proactiveSettings)
    }

    private static func scheduleText(_ schedule: RoutineSchedule) -> String {
        switch schedule.kind {
        case .interval:
            return "每 \(schedule.everyMinutes ?? 0) 分钟"
        case .daily:
            return "每天 \(schedule.time ?? "—")"
        case .weekly:
            let names = (schedule.weekdays ?? []).map(weekdayName).joined(separator: "、")
            return "每周 \(names.isEmpty ? "—" : names) \(schedule.time ?? "")"
        case .cron:
            return "cron \(schedule.expr ?? "—")"
        }
    }

    private static func weekdayName(_ value: Int) -> String {
        switch value {
        case 1: return "周日"
        case 2: return "周一"
        case 3: return "周二"
        case 4: return "周三"
        case 5: return "周四"
        case 6: return "周五"
        case 7: return "周六"
        default: return "第 \(value) 天"
        }
    }

    private static func lastResultText(_ result: RoutineResult?) -> String {
        guard let result else { return "还没有运行结果。" }
        if !result.text.isEmpty { return result.text }
        if let error = result.error, !error.isEmpty { return error }
        return "运行状态：\(result.status.rawValue)"
    }
}

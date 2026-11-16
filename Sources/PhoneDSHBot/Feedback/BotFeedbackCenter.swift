// SPDX-License-Identifier: MIT

import Foundation

/// Write side used by both entry points (host UI action and the `.chat` model
/// tool). `record` is idempotent by `origin.nonce` and by effect: repeating the
/// same feedback never creates a second active preference/adoption.
public protocol BotFeedbackRecording: Sendable {
    func record(_ feedback: BotFeedback) async throws -> BotFeedbackOutcome
    func undo(_ feedbackID: String) async throws -> BotFeedbackOutcome
    func undo(_ feedbackID: String, botID: String,
              origin: BotFeedbackOrigin) async throws -> BotFeedbackOutcome
    func preferences(botID: String, scope: BotFeedbackScopeKind?) async throws -> BotFeedbackPreferences
}

/// Read side consumed by the proactive engine.
public protocol BotFeedbackGating: Sendable {
    /// `held` means the candidate must be recorded as held, not delivered, and
    /// must not consume the frequency fuse.
    func hold(for candidate: ProactiveCandidate, botID: String, at: Int64) async -> BotFeedbackHold
    /// Called for every finished consideration. Only `did` decisions enter the
    /// delivery index; the decision itself is already durable in the event log.
    func noteConsidered(_ decision: ProactiveDecision, candidate: ProactiveCandidate) async
}

/// Read side consumed by M (disputed refs), R (preferences material) and U
/// (Bot info page). Also exposes the would/did report.
public protocol BotFeedbackQuerying: Sendable {
    func records(botID: String, limit: Int) async throws -> [BotFeedbackRecord]
    /// Read-only preference view for R's decision material (active/revoked,
    /// class keys). Suppress/adopt remain delivery-gate facts; this API must
    /// not become a second preference system.
    func preferences(botID: String, scope: BotFeedbackScopeKind?) async throws -> BotFeedbackPreferences
    func disputedRefs(paths: [String]) async throws -> [String: [BotFeedbackDisputedRef]]
    func wouldReport(botID: String?, fromMS: Int64, toMS: Int64) async throws -> BotWouldCollectionReport
    func storeHealth() async -> String
}

public extension BotFeedbackRecording {
    func preferences(botID: String) async throws -> BotFeedbackPreferences {
        try await preferences(botID: botID, scope: nil)
    }

    /// Record a disputed-only correction against an existing applied memory
    /// version. It never edits the document/version and requires real refs;
    /// undo clears the dispute via the normal feedback reverse event.
    func dispute(memoryPath: String, version: Int, botID: String,
                 refs: [String], origin: BotFeedbackOrigin) async throws -> BotFeedbackOutcome {
        var feedback = BotFeedback(
            botID: botID, action: .correct,
            target: BotFeedbackArtifactRef(kind: .memory, id: memoryPath, version: version),
            scope: .artifact, origin: origin, disputedRefs: refs)
        feedback.disputedOnly = true
        return try await record(feedback)
    }
}

/// The single host authority for feedback binding and proactive preferences.
///
/// Facts live in `feedback.recorded` durable events (G-2 §3.1); the P18 key
/// `phone-dsh.bot.feedback.v1` is only the gate index and can be rebuilt from
/// those events. Corrections are verified against the applied memory version,
/// never by trusting model text.
public actor BotFeedbackCenter: BotFeedbackRecording, BotFeedbackGating, BotFeedbackQuerying {
    /// G-2 frozen P25 type. `ignorable: true` keeps old readers safe.
    public static let feedbackEventType = "feedback.recorded"

    static let memoryReviewEventType = "memory.review_requested"
    /// G-2 r5: `scope=user` accepts only kind-level classes (`proactive:<kind>`)
    /// and only from a host-verified UI action; narrow routine/reminder classes
    /// stay Bot-scoped. The class is derived from the artifact's kind, not from
    /// the model's words.
    private static let maximumIDLength = 128
    private static let maximumEventPages = 200

    private let store: any BotFeedbackStoring
    private let eventLog: (any BotEventLog)?
    private let memory: (@Sendable (String) async -> (any BotFeedbackMemoryReading)?)?
    /// Host-verified routine document for `target.kind=routine`. A routine can
    /// be suppressed before its first run, so no proactive delivery exists yet;
    /// this reader must ask the durable routine store, not infer from a delivery.
    private let routineReader: (any BotFeedbackRoutineReading)?
    private let now: @Sendable () -> Int64

    private var state: BotFeedbackState?
    private var loaded = false
    private var rebuiltCursor = 0
    private var health = "ok"
    private var needsFullReplay = false
    private var appliedEventIDs: Set<String> = []

    public init(store: any BotFeedbackStoring,
                eventLog: (any BotEventLog)? = nil,
                memory: (@Sendable (String) async -> (any BotFeedbackMemoryReading)?)? = nil,
                routineReader: (any BotFeedbackRoutineReading)? = nil,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                }) {
        self.store = store
        self.eventLog = eventLog
        self.memory = memory
        self.routineReader = routineReader
        self.now = now
    }

    /// Production constructor. It never blocks Bot start-up: a missing or bad
    /// index is rebuilt from events, and an event-log write failure is reported
    /// on that single call instead of failing the whole composition.
    public static func live(eventLog: (any BotEventLog)?,
                            memory: (@Sendable (String) async -> (any BotFeedbackMemoryReading)?)? = nil,
                            routineReader: (any BotFeedbackRoutineReading)? = nil,
                            defaults: UserDefaults = .standard,
                            key: String = BotFeedbackIndexFile.defaultsKey,
                            now: @escaping @Sendable () -> Int64 = {
                                Int64(Date().timeIntervalSince1970 * 1_000)
                            }) throws -> BotFeedbackCenter {
        BotFeedbackCenter(store: UserDefaultsBotFeedbackStore(defaults: defaults, key: key),
                          eventLog: eventLog, memory: memory,
                          routineReader: routineReader, now: now)
    }

    // MARK: - loading / replay / persistence

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        var index: BotFeedbackIndexFile?
        do {
            index = try await store.load()
        } catch let error as BotFeedbackStoreError {
            health = Self.healthLabel(error)
        } catch {
            health = "index-unreadable"
        }
        if let eventLog {
            // The durable events are the only facts. Rebuild from them on every
            // launch instead of trusting the persisted index: a stale/foreign
            // index (for example an app container reused by another run) must
            // not create phantom corrections or duplicate outcomes without a
            // matching feedback.recorded event (G-2 §3.4: file ahead -> truth).
            state = .empty
            rebuiltCursor = 0
            await replayEvents(eventLog: eventLog, full: true)
            if let current = state {
                for correction in current.corrections where correction.isActive() {
                    let original = current.records.last(where: { $0.id == correction.feedbackID })
                    await appendMemoryReviewRequest(
                        path: correction.path, version: correction.correctedVersion,
                        refs: correction.refs, botID: correction.botID,
                        sessionID: nil, at: correction.atMS,
                        outcome: original?.applied == nil ? "disputed" : nil)
                }
                // Write the rebuilt (phantom-free) index back.
                await persistIndex(current, bestEffort: true)
            }
        } else if let index {
            state = Self.state(from: index)
            rebuiltCursor = max(0, index.rebuiltFromCommitSeq)
        } else {
            state = .empty
            needsFullReplay = true
            health = "index-ignored-without-event-log"
        }
    }

    /// Replays durable feedback events. `full` is used when the index is
    /// missing/corrupt: it also rebuilds the delivery index from proactive
    /// decisions so a restored gate can resolve targets again.
    private func replayEvents(eventLog: any BotEventLog, full: Bool) async {
        var next = state ?? .empty
        var cursor = full ? 0 : rebuiltCursor
        var changed = false
        var pages = 0
        var truncated = false
        while pages < Self.maximumEventPages {
            let page: [BotEvent]
            do {
                page = try await eventLog.events(after: cursor, limit: 500)
            } catch {
                health = "event-replay-failed"
                return
            }
            if page.isEmpty { break }
            pages += 1
            for event in page {
                if event.type == Self.feedbackEventType,
                   let record = Self.record(from: event),
                   appliedEventIDs.insert(event.eventId).inserted {
                    Self.apply(record, to: &next)
                    changed = true
                } else if full, event.type == "proactive.considered",
                          let delivery = Self.delivery(from: event),
                          !next.deliveries.contains(where: { $0.id == delivery.id }) {
                    next.deliveries.append(delivery)
                }
            }
            guard let maxSeq = page.compactMap(\.commitSeq).max(), maxSeq > cursor else { break }
            cursor = maxSeq
            if page.count < 500 { break }
        }
        if pages == Self.maximumEventPages { truncated = true }
        rebuiltCursor = max(rebuiltCursor, cursor)
        if changed {
            state = next
            await persistIndex(next, bestEffort: true)
        }
        if needsFullReplay {
            health = health == "ok" ? "rebuilt-from-events" : health + "+rebuilt"
            needsFullReplay = false
        }
        if truncated { health = "replay-truncated" }
    }

    private func persistIndex(_ state: BotFeedbackState, bestEffort: Bool) async {
        let index = Self.index(from: state, cursor: rebuiltCursor, now: now())
        do {
            try await store.save(index)
        } catch {
            if !bestEffort {
                health = "index-write-failed"
            }
        }
    }

    public func storeHealth() async -> String {
        await ensureLoaded()
        return health
    }

    // MARK: - recording

    public func record(_ feedback: BotFeedback) async throws -> BotFeedbackOutcome {
        await ensureLoaded()
        let at = now()
        var signed = feedback
        let botID = Self.trim(feedback.botID)
        signed.botID = botID
        let nonce = Self.capped(Self.trim(feedback.origin.nonce),
                                max: Self.maximumIDLength - 40)
        signed.origin.nonce = nonce
        guard !botID.isEmpty else {
            return Self.rejected(signed, code: "permission-denied", message: "反馈必须绑定一个 Bot。")
        }
        guard !nonce.isEmpty else {
            return Self.rejected(signed, code: "insufficient-evidence",
                                 message: "反馈缺少宿主生成的幂等 nonce。")
        }
        switch signed.origin.kind {
        case .userChatTurn
            where Self.trim(signed.origin.sessionID ?? "").isEmpty:
            return Self.rejected(signed, code: "permission-denied",
                                 message: "用户回合反馈缺少会话。")
        case .uiAction, .userChatTurn:
            break
        }
        var snapshot = state ?? .empty

        if let existing = snapshot.records.first(where: {
            $0.botID == botID && !$0.nonce.isEmpty && $0.nonce == nonce
        }) {
            return Self.outcome(existing, status: .duplicated)
        }

        switch signed.action {
        case .adopt:
            return try await recordAdoption(signed, at: at, snapshot: &snapshot)
        case .suppress:
            return try await recordSuppression(signed, at: at, snapshot: &snapshot)
        case .correct:
            return try await recordCorrection(signed, at: at, snapshot: &snapshot)
        case .undo:
            if signed.target.kind != .feedback {
                return Self.rejected(signed, code: "target-unresolved",
                                     message: "undo 的 target 必须是 feedback id。")
            }
            return try await performUndo(signed.target.id, botID: botID,
                                         origin: signed.origin, at: at, snapshot: &snapshot)
        }
    }

    public func undo(_ feedbackID: String) async throws -> BotFeedbackOutcome {
        let origin = BotFeedbackOrigin(kind: .uiAction, nonce: "undo:\(feedbackID)")
        return try await undoScoped(feedbackID, botID: nil, origin: origin)
    }

    public func undo(_ feedbackID: String, botID: String,
                     origin: BotFeedbackOrigin) async throws -> BotFeedbackOutcome {
        try await undoScoped(feedbackID, botID: botID, origin: origin)
    }

    private func undoScoped(_ feedbackID: String, botID: String?,
                            origin: BotFeedbackOrigin) async throws -> BotFeedbackOutcome {
        await ensureLoaded()
        let id = Self.trim(feedbackID)
        guard !id.isEmpty else {
            return BotFeedbackOutcome(status: .rejected, action: .undo,
                                      target: BotFeedbackArtifactRef(kind: .feedback, id: feedbackID),
                                      scope: .artifact, code: "target-unresolved",
                                      message: "没有这条反馈。")
        }
        var snapshot = state ?? .empty
        return try await performUndo(id, botID: botID, origin: origin, at: now(), snapshot: &snapshot)
    }

    private func performUndo(_ feedbackID: String, botID: String?,
                             origin: BotFeedbackOrigin, at: Int64,
                             snapshot: inout BotFeedbackState) async throws -> BotFeedbackOutcome {
        let original = snapshot.records.last(where: { $0.id == feedbackID })
        let preference = snapshot.preferences.last(where: { $0.id == feedbackID })
        let adoption = snapshot.adoptions.last(where: { $0.feedbackID == feedbackID })
        let correction = snapshot.corrections.last(where: { $0.feedbackID == feedbackID })
        guard original != nil || preference != nil || adoption != nil || correction != nil else {
            return BotFeedbackOutcome(status: .rejected, action: .undo,
                                      target: BotFeedbackArtifactRef(kind: .feedback, id: feedbackID),
                                      scope: .artifact, code: "target-unresolved",
                                      message: "没有这条反馈。")
        }
        let originalAction = original?.action
            ?? (preference != nil ? .suppress : adoption != nil ? .adopt : .correct)
        let originalBotID = original?.botID ?? preference?.botID
            ?? adoption?.botID ?? correction?.botID ?? ""
        let originalScope = original?.scopeKind ?? preference?.scopeKind ?? .artifact
        guard originalAction != .undo else {
            return BotFeedbackOutcome(status: .rejected, action: .undo,
                                      target: BotFeedbackArtifactRef(kind: .feedback, id: feedbackID),
                                      scope: originalScope, code: "target-unresolved",
                                      message: "不能撤销一条撤销记录。")
        }
        if let botID, !botID.isEmpty, originalBotID != botID, originalScope != .user {
            return BotFeedbackOutcome(status: .rejected, action: .undo,
                                      target: BotFeedbackArtifactRef(kind: .feedback, id: feedbackID),
                                      scope: originalScope, code: "permission-denied",
                                      message: "这条反馈属于另一个 Bot。")
        }
        if let previous = snapshot.records.first(where: {
            $0.action == .undo && $0.reverses == feedbackID
        }) {
            return Self.outcome(previous, status: .duplicated, reverses: feedbackID)
        }
        let actingBot = (botID?.isEmpty == false ? botID! : originalBotID)
        let nonce = Self.trim(origin.nonce).isEmpty ? "undo-\(feedbackID)" : Self.trim(origin.nonce)
        let recordID = Self.messageID(botID: actingBot,
                                      nonce: "undo-" + Self.capped(nonce, max: 90))
        var record = BotFeedbackRecord(
            id: recordID, action: .undo, botID: actingBot,
            origin: origin, target: BotFeedbackArtifactRef(kind: .feedback, id: feedbackID),
            scopeKind: originalScope,
            scopeKey: preference?.scopeKey ?? feedbackID,
            classKey: preference?.classKey ?? correction?.path,
            subjects: correction?.refs ?? [],
            reverses: feedbackID, accepted: true, atMS: at, nonce: nonce)
        record.eventID = Self.eventID(for: record)
        switch originalAction {
        case .suppress:
            for index in snapshot.preferences.indices
            where snapshot.preferences[index].id == feedbackID
                && snapshot.preferences[index].revokedAtMS == nil {
                snapshot.preferences[index].revokedAtMS = at
                snapshot.preferences[index].revokedByFeedbackID = recordID
            }
        case .adopt:
            for index in snapshot.adoptions.indices
            where snapshot.adoptions[index].feedbackID == feedbackID
                && snapshot.adoptions[index].revokedAtMS == nil {
                snapshot.adoptions[index].revokedAtMS = at
                snapshot.adoptions[index].revokedByFeedbackID = recordID
            }
        case .correct:
            for index in snapshot.corrections.indices
            where snapshot.corrections[index].feedbackID == feedbackID
                && snapshot.corrections[index].retractedAtMS == nil {
                snapshot.corrections[index].retractedAtMS = at
                snapshot.corrections[index].retractedByFeedbackID = recordID
            }
        case .undo:
            break
        }
        let outcome = try await commit(&record, state: snapshot, reverses: feedbackID)
        if let original, originalAction == .correct, original.applied == nil,
           let correction {
            await appendMemoryReviewResolved(
                path: correction.path, version: correction.correctedVersion,
                feedbackID: feedbackID, botID: originalBotID, at: at)
        }
        return outcome
    }

    private func recordAdoption(_ feedback: BotFeedback, at: Int64,
                                snapshot: inout BotFeedbackState) async throws -> BotFeedbackOutcome {
        guard feedback.scope == .artifact else {
            return Self.rejected(feedback, code: "target-unresolved",
                                 message: "采纳只作用于被采纳的那一个产物。")
        }
        if let delivery = await resolveDelivery(feedback.target, botID: feedback.botID,
                                                snapshot: snapshot) {
            if let existing = snapshot.adoptions.last(where: {
                $0.artifactKey == delivery.id && $0.isActive()
            }) {
                return BotFeedbackOutcome(status: .duplicated, feedbackID: existing.feedbackID,
                                          action: .adopt,
                                          target: BotFeedbackArtifactRef(
                                            kind: .proactive,
                                            id: delivery.decisionID ?? delivery.dedupeKey,
                                            deliveryKey: delivery.dedupeKey),
                                          scope: .artifact, classKey: delivery.classKey)
            }
            var record = Self.recordBase(feedback, at: at, scopeKey: delivery.id,
                                         classKey: delivery.classKey, accepted: true)
            record.eventID = Self.eventID(for: record)
            snapshot.adoptions.append(BotFeedbackAdoption(
                artifactKey: delivery.id, botID: feedback.botID,
                feedbackID: record.id, atMS: at))
            return try await commit(&record, state: snapshot)
        }
        // A host UI action may adopt a specific visible assistant message or
        // attachment row that is not a proactive delivery. The row id comes
        // from the host projection, so it is real evidence; the model path
        // still has to resolve a delivered proactive artifact instead.
        guard feedback.origin.kind == .uiAction,
              feedback.target.kind == .delivery,
              !Self.trim(feedback.target.id).isEmpty else {
            return Self.rejected(feedback, code: "target-unresolved",
                                 message: "没有找到这条已投递的产物。")
        }
        let rowKey = Self.rowArtifactKey(botID: feedback.botID, rowID: feedback.target.id)
        if let existing = snapshot.adoptions.last(where: {
            $0.artifactKey == rowKey && $0.isActive()
        }) {
            return BotFeedbackOutcome(status: .duplicated, feedbackID: existing.feedbackID,
                                      action: .adopt, target: feedback.target,
                                      scope: .artifact)
        }
        var record = Self.recordBase(feedback, at: at, scopeKey: rowKey,
                                     classKey: "", accepted: true)
        record.classKey = nil
        record.eventID = Self.eventID(for: record)
        snapshot.adoptions.append(BotFeedbackAdoption(
            artifactKey: rowKey, botID: feedback.botID, feedbackID: record.id, atMS: at))
        return try await commit(&record, state: snapshot)
    }

    private func recordSuppression(_ feedback: BotFeedback, at: Int64,
                                   snapshot: inout BotFeedbackState) async throws -> BotFeedbackOutcome {
        var delivery = await resolveDelivery(feedback.target, botID: feedback.botID,
                                             snapshot: snapshot)
        var routineRevision: Int?
        if delivery == nil, feedback.target.kind == .routine, let routineReader {
            let routineID = Self.trim(feedback.target.id)
            if !routineID.isEmpty,
               let routine = await routineReader.routine(botID: feedback.botID,
                                                         routineID: routineID) {
                // A routine may be suppressed before its first run, so there
                // is no proactive delivery yet. It is still a real durable
                // artifact; bind a narrow routine class, never a fake delivery.
                routineRevision = routine.revision
                delivery = BotFeedbackDelivery(
                    botID: feedback.botID, dedupeKey: "routine:\(routineID)",
                    decisionID: nil, kind: ProactiveKind.routineResult.rawValue,
                    routineID: routineID, reminderID: nil, trigger: nil,
                    rowID: nil, atMS: at,
                    classKey: Self.classKey(kind: ProactiveKind.routineResult.rawValue,
                                            routineID: routineID, reminderID: nil))
            }
        }
        guard let delivery else {
            if feedback.origin.kind == .uiAction, feedback.target.kind == .delivery {
                return Self.rejected(feedback, code: "ambiguous-scope",
                                     message: "这条消息不是主动提醒，无法推导“这类”的范围；请只对主动提醒/例程结果使用不再提醒。")
            }
            return Self.rejected(feedback, code: "target-unresolved",
                                 message: "没有找到要停止提醒的那条真实产物。")
        }
        if feedback.target.kind == .routine, feedback.scope == .artifact {
            return Self.rejected(feedback, code: "ambiguous-scope",
                                 message: "例程目标没有单条投递可绑定；请用 routine 或 class 范围停止这个例程的提醒。")
        }
        let classKey = delivery.classKey
        var effectiveClassKey = classKey
        let scopeKey: String
        switch feedback.scope {
        case .artifact:
            scopeKey = delivery.id
        case .routine:
            guard classKey.hasPrefix("routine:") else {
                return Self.rejected(feedback, code: "target-unresolved",
                                     message: "这条产物不属于某个例行任务；请改用 artifact 或 class 范围。")
            }
            scopeKey = classKey
        case .class:
            // G-2 r5: a class suppression must be a narrow class. A kind-only
            // class (for example task-done) would silently widen "this kind"
            // to every target of that kind, so it is ambiguous instead.
            guard Self.isNarrowClassKey(classKey) else {
                return Self.rejected(feedback, code: "ambiguous-scope",
                                     message: "这个类只有 kind 级，无法确认用户指的是哪些目标；请改为这一条、某个例行任务，或由用户在 UI 明确选择。")
            }
            scopeKey = classKey
        case .user:
            // G-2 r5: a chat utterance cannot prove the user meant a cross-Bot
            // preference; only a host-verified UI action can.
            guard feedback.origin.kind == .uiAction else {
                return Self.rejected(feedback, code: "scope-requires-confirmation",
                                     message: "跨 Bot 偏好需要用户在 UI 明确选择；模型不能仅凭一句话扩大范围。")
            }
            // `user` is the kind-level class (`proactive:<kind>`), never a
            // Bot-local routine/reminder id. This is what makes a cross-Bot
            // "don't push this kind" possible without widening to all output.
            let kindClass = Self.kindLevelClass(kind: delivery.kind)
            guard Self.isKindLevelClassKey(kindClass) else {
                return Self.rejected(feedback, code: "scope-not-shareable",
                                     message: "这个产物没有可跨 Bot 的 kind 级类别。")
            }
            effectiveClassKey = kindClass
            scopeKey = kindClass
        }
        if let expiresAtMS = feedback.expiresAtMS, expiresAtMS <= at {
            return Self.rejected(feedback, code: "insufficient-evidence",
                                 message: "过期时间必须晚于现在。")
        }
        let sameScope = snapshot.preferences.last(where: {
            $0.isActive(at: at) && $0.scopeKind == feedback.scope
                && $0.scopeKey == scopeKey
                && (feedback.scope == .user || $0.botID == feedback.botID)
        })
        if let sameScope {
            return BotFeedbackOutcome(status: .duplicated, feedbackID: sameScope.id,
                                      action: .suppress,
                                      target: BotFeedbackArtifactRef(
                                        kind: .proactive, id: delivery.decisionID ?? delivery.dedupeKey,
                                        deliveryKey: delivery.dedupeKey),
                                      scope: feedback.scope, classKey: effectiveClassKey)
        }
        var record = Self.recordBase(feedback, at: at, scopeKey: scopeKey,
                                     classKey: effectiveClassKey, accepted: true)
        if let routineRevision { record.target.version = routineRevision }
        record.eventID = Self.eventID(for: record)
        record.expiresAtMS = feedback.expiresAtMS
        snapshot.preferences.append(BotFeedbackPreference(
            id: record.id, botID: feedback.botID, scopeKind: feedback.scope,
            scopeKey: scopeKey, classKey: effectiveClassKey, createdAtMS: at,
            expiresAtMS: feedback.expiresAtMS))
        return try await commit(&record, state: snapshot)
    }

    private func recordCorrection(_ feedback: BotFeedback, at: Int64,
                                  snapshot: inout BotFeedbackState) async throws -> BotFeedbackOutcome {
        guard feedback.target.kind == .memory else {
            return Self.rejected(feedback, code: "target-unresolved",
                                 message: "说错了需要绑定一条记忆文档的已应用版本；普通消息请走纠错回合，不要用消息行反馈。")
        }
        let path = Self.trim(feedback.target.id)
        guard let version = feedback.target.version, version >= 1, !path.isEmpty else {
            return Self.rejected(feedback, code: "target-unresolved",
                                 message: "纠正需要 memory path 与已应用版本号。")
        }
        let disputedOnly = feedback.disputedOnly
        if disputedOnly, feedback.disputedRefs.isEmpty {
            return Self.rejected(feedback, code: "insufficient-evidence",
                                 message: "disputed-only 纠正需要真实的 disputed_refs；不先改正文。")
        }
        var supplied: [String] = []
        for raw in feedback.disputedRefs.prefix(8) {
            guard let reference = BotRecordReference.parse(raw) else {
                return Self.rejected(feedback, code: "insufficient-evidence",
                                     message: "disputed_refs 必须是 record:// 引用。")
            }
            supplied.append(reference.canonical)
        }
        guard let memory else {
            return Self.rejected(feedback, code: "insufficient-evidence",
                                 message: "当前装配没有记忆读取端口，无法校验纠正。")
        }
        let reader = await memory(feedback.botID)
        guard let reader else {
            return Self.rejected(feedback, code: "insufficient-evidence",
                                 message: "这个 Bot 没有记忆读取端口。")
        }
        let snapshotRead: BotFeedbackMemorySnapshot?
        do {
            snapshotRead = try await reader.memorySnapshot(path: path)
        } catch {
            return Self.rejected(feedback, code: "insufficient-evidence",
                                 message: "读取记忆版本失败。")
        }
        guard let snapshotRead, snapshotRead.version == version else {
            return Self.rejected(feedback, code: "correction-not-applied",
                                 message: "当前记忆版本不是这次纠正确认的已应用版本；先真正写入再回报。")
        }
        if let existing = snapshot.corrections.last(where: {
            $0.isActive() && $0.path == path && $0.correctedVersion == version
        }) {
            // A crash between feedback.recorded and memory.review_requested is
            // recoverable: a retry with the same nonce repairs the review event
            // instead of returning a duplicate with no audit completion.
            let existingOriginal = snapshot.records.last(where: { $0.id == existing.feedbackID })
            let existingDisputedOnly = existingOriginal?.applied == nil
            await appendMemoryReviewRequest(
                path: path, version: version, refs: existing.refs,
                botID: feedback.botID, sessionID: feedback.origin.sessionID, at: at,
                outcome: existingDisputedOnly ? "disputed" : nil)
            return BotFeedbackOutcome(status: .duplicated, feedbackID: existing.feedbackID,
                                      action: .correct,
                                      target: BotFeedbackArtifactRef(kind: .memory, id: path,
                                                                     version: version),
                                      scope: .artifact, classKey: path,
                                      appliedMemory: existingDisputedOnly ? nil
                                        : BotFeedbackMemoryApplication(
                                            path: path, version: version,
                                            previousVersion: existing.supersededVersion))
        }
        var refs: [String] = []
        var seen = Set<String>()
        for raw in supplied + snapshotRead.evidence {
            guard let reference = BotRecordReference.parse(raw) else { continue }
            let canonical = reference.canonical
            if seen.insert(canonical).inserted { refs.append(canonical) }
            if refs.count == 8 { break }
        }
        let previousVersion = max(0, version - 1)
        var record = Self.recordBase(feedback, at: at, scopeKey: Self.memoryScopeKey(path: path,
                                                                                     version: version),
                                     classKey: path, accepted: true)
        record.subjects = refs
        if !disputedOnly {
            record.applied = BotFeedbackMemoryApplication(path: path, version: version,
                                                          previousVersion: previousVersion)
        }
        record.eventID = Self.eventID(for: record)
        snapshot.corrections.append(BotFeedbackCorrection(
            feedbackID: record.id, botID: feedback.botID, path: path, refs: refs,
            correctedVersion: version, supersededVersion: previousVersion, atMS: at))
        let outcome = try await commit(&record, state: snapshot)
        await appendMemoryReviewRequest(path: path, version: version, refs: refs,
                                        botID: feedback.botID,
                                        sessionID: feedback.origin.sessionID, at: at,
                                        outcome: disputedOnly ? "disputed" : nil)
        return outcome
    }

    // MARK: - commit (event first, index second)

    private func commit(_ record: inout BotFeedbackRecord, state next: BotFeedbackState,
                        reverses: String? = nil) async throws -> BotFeedbackOutcome {
        record.eventID = record.eventID ?? Self.eventID(for: record)
        record.eventAppended = false
        if let eventLog {
            switch await appendFeedbackEvent(record, eventLog: eventLog) {
            case .appended(let sequence):
                record.eventAppended = true
                rebuiltCursor = max(rebuiltCursor, sequence)
            case .exists:
                record.eventAppended = true
            case .failed:
                // The durable fact could not be written: do not create an
                // index-only phantom. The caller can retry the same nonce.
                throw BotFeedbackStoreError.unavailable("feedback-event-append-failed")
            }
        }
        var committed = next
        if !committed.records.contains(where: { $0.id == record.id }) {
            committed.records.append(record)
        }
        let index = Self.index(from: committed, cursor: rebuiltCursor, now: now())
        var auditPending = false
        if eventLog == nil {
            // Without a journal the index is the only durable copy; a failed
            // write must fail the call instead of pretending success.
            try await store.save(index)
        } else {
            do {
                try await store.save(index)
            } catch {
                auditPending = true
                health = "index-write-failed"
            }
        }
        state = committed
        return BotFeedbackOutcome(status: .accepted, feedbackID: record.id,
                                  action: record.action, target: record.target,
                                  scope: record.scopeKind, classKey: record.classKey,
                                  message: nil, reversed: reverses != nil,
                                  reverses: reverses, auditPending: auditPending,
                                  appliedMemory: record.applied)
    }

    private enum AppendOutcome {
        case appended(Int)
        case exists
        case failed
    }

    private func appendFeedbackEvent(_ record: BotFeedbackRecord,
                                     eventLog: any BotEventLog) async -> AppendOutcome {
        guard let eventID = record.eventID else { return .failed }
        let source = record.origin.kind == .uiAction ? "card-bridge" : "mcp"
        let event = BotEvent(
            type: Self.feedbackEventType, eventId: eventID, time: record.atMS,
            origin: .local(source: source), traceId: "trace:\(record.id)",
            principal: BotPrincipal(botId: record.botID,
                                    sessionId: record.origin.sessionID, kind: "chat"),
            causationId: record.reverses ?? record.target.deliveryKey,
            correlationId: record.id, ignorable: true,
            data: .object(Self.eventData(record)))
        do {
            let sequence = try await eventLog.append(event)
            return .appended(sequence)
        } catch {
            return await eventExists(eventID, in: eventLog) ? .exists : .failed
        }
    }

    private func eventExists(_ eventID: String, in eventLog: any BotEventLog) async -> Bool {
        var cursor = 0
        for _ in 0..<Self.maximumEventPages {
            guard let page = try? await eventLog.events(after: cursor, limit: 500),
                  !page.isEmpty else { return false }
            if page.contains(where: { $0.eventId == eventID }) { return true }
            guard let next = page.compactMap(\.commitSeq).max(), next > cursor else { return false }
            cursor = next
            if page.count < 500 { return false }
        }
        return false
    }

    private func appendMemoryReviewRequest(path: String, version: Int, refs: [String],
                                           botID: String, sessionID: String?, at: Int64,
                                           outcome: String? = nil) async {
        guard let eventLog else { return }
        let scope = BotMemoryAuthorizer.scope(of: path)?.rawValue ?? "agent"
        let eventID = "\(Self.memoryReviewEventType):\(botID):\(path):\(version)"
        var data: [String: BotJSONValue] = [
            "path": .string(path),
            "scope": .string(scope),
            "version": .number(Double(version)),
            "evidence": .array(refs.map(BotJSONValue.string)),
            "marked_at_ms": .number(Double(at)),
        ]
        if let outcome { data["outcome"] = .string(outcome) }
        let event = BotEvent(
            type: Self.memoryReviewEventType, eventId: eventID, time: at,
            origin: .local(source: "mcp"), traceId: "trace:\(eventID)",
            principal: BotPrincipal(botId: botID, sessionId: sessionID, kind: "chat"),
            causationId: nil, correlationId: nil, data: .object(data))
        _ = try? await eventLog.append(event)
    }

    private func appendMemoryReviewResolved(path: String, version: Int, feedbackID: String,
                                            botID: String, at: Int64) async {
        guard let eventLog else { return }
        let eventID = "memory.review_resolved:feedback:\(feedbackID)"
        let data: [String: BotJSONValue] = [
            "path": .string(path),
            "version": .number(Double(version)),
            "outcome": .string("dropped"),
            "feedback_id": .string(feedbackID),
            "resolved_at_ms": .number(Double(at)),
        ]
        let event = BotEvent(
            type: "memory.review_resolved", eventId: eventID, time: at,
            origin: .local(source: "mcp"), traceId: "trace:\(eventID)",
            principal: BotPrincipal(botId: botID, sessionId: nil, kind: "chat"),
            causationId: nil, correlationId: nil, data: .object(data))
        _ = try? await eventLog.append(event)
    }

    // MARK: - queries

    public func records(botID: String, limit: Int = 50) async throws -> [BotFeedbackRecord] {
        await ensureLoaded()
        let trimmed = Self.trim(botID)
        let rows = (state ?? .empty).records.filter { trimmed.isEmpty || $0.botID == trimmed }
        return Array(rows.suffix(max(0, limit))).reversed()
    }

    public func disputedRefs(paths: [String]) async throws -> [String: [BotFeedbackDisputedRef]] {
        await ensureLoaded()
        let wanted = Set(paths.map(Self.trim).filter { !$0.isEmpty })
        var result: [String: [BotFeedbackDisputedRef]] = [:]
        for correction in (state ?? .empty).corrections
        where wanted.isEmpty || wanted.contains(correction.path) {
            let view = BotFeedbackDisputedRef(
                path: correction.path, refs: correction.refs,
                feedbackID: correction.feedbackID,
                correctedVersion: correction.correctedVersion,
                supersededVersion: correction.supersededVersion,
                atMS: correction.atMS,
                state: correction.isActive() ? "active" : "retracted")
            result[correction.path, default: []].append(view)
        }
        return result
    }

    public func preferences(botID: String, scope: BotFeedbackScopeKind?) async throws
        -> BotFeedbackPreferences {
        await ensureLoaded()
        let at = now()
        let trimmed = Self.trim(botID)
        let all = (state ?? .empty).preferences
        let applicable = all.filter { preference in
            guard scope == nil || preference.scopeKind == scope else { return false }
            return preference.scopeKind == .user || preference.botID == trimmed
        }
        return BotFeedbackPreferences(
            botID: trimmed, generatedAtMS: at,
            active: applicable.filter { $0.isActive(at: at) },
            recentlyRevoked: Array(applicable.filter { $0.revokedAtMS != nil }
                .suffix(20)).reversed())
    }

    // MARK: - proactive gate

    public func hold(for candidate: ProactiveCandidate, botID: String,
                     at: Int64) async -> BotFeedbackHold {
        await ensureLoaded()
        guard let state else { return .notHeld }
        let classKey = Self.classKey(for: candidate)
        let artifactKey = Self.artifactKey(botID: candidate.botId,
                                           dedupeKey: Self.dedupeKey(for: candidate, at: at))
        for preference in state.preferences.reversed() where preference.isActive(at: at) {
            switch preference.scopeKind {
            case .artifact:
                if preference.botID == botID && preference.scopeKey == artifactKey {
                    return .held(feedbackID: preference.id, scopeKind: .artifact,
                                 scopeKey: preference.scopeKey, classKey: classKey)
                }
            case .routine, .class:
                if preference.botID == botID && preference.classKey == classKey {
                    return .held(feedbackID: preference.id, scopeKind: preference.scopeKind,
                                 scopeKey: preference.scopeKey, classKey: classKey)
                }
            case .user:
                let candidateKindClass = Self.kindLevelClass(kind: candidate.kind.rawValue)
                if preference.classKey == classKey
                    || preference.classKey == candidateKindClass {
                    return .held(feedbackID: preference.id, scopeKind: .user,
                                 scopeKey: preference.scopeKey, classKey: candidateKindClass)
                }
            }
        }
        return .notHeld
    }

    public func noteConsidered(_ decision: ProactiveDecision,
                               candidate: ProactiveCandidate) async {
        guard decision.decision == .did else { return }
        await ensureLoaded()
        let delivery = BotFeedbackDelivery(
            botID: candidate.botId,
            dedupeKey: decision.dedupeKey ?? Self.dedupeKey(for: candidate, at: decision.at),
            decisionID: decision.id, kind: candidate.kind.rawValue,
            routineID: candidate.routineId, reminderID: candidate.reminderId,
            trigger: candidate.trigger, rowID: candidate.rowId, atMS: decision.at,
            classKey: Self.classKey(for: candidate))
        var next = state ?? .empty
        next.deliveries.removeAll {
            $0.botID == delivery.botID && $0.dedupeKey == delivery.dedupeKey
        }
        next.deliveries.append(delivery)
        state = next
    }

    // MARK: - would/did report

    public func wouldReport(botID: String?, fromMS: Int64, toMS: Int64) async throws
        -> BotWouldCollectionReport {
        await ensureLoaded()
        guard fromMS >= 0, toMS > fromMS else {
            throw BotFeedbackStoreError.unavailable("invalid-report-window")
        }
        let trimmedBot = botID.map(Self.trim).flatMap { $0.isEmpty ? nil : $0 }
        var would = 0
        var did = 0
        var held = 0
        var adopted = 0
        var undone = 0
        var suppressed = 0
        var observedFrom: Int64?
        var observedTo: Int64?
        var notes: [String] = []
        var truncated = false

        let inWindow: (Int64) -> Bool = { $0 >= fromMS && $0 <= toMS }
        for adoption in (state ?? .empty).adoptions {
            guard trimmedBot == nil || adoption.botID == trimmedBot else { continue }
            if inWindow(adoption.atMS) {
                adopted += 1
                observedFrom = min(observedFrom ?? adoption.atMS, adoption.atMS)
                observedTo = max(observedTo ?? adoption.atMS, adoption.atMS)
            }
            if let revoked = adoption.revokedAtMS, inWindow(revoked) {
                undone += 1
                observedFrom = min(observedFrom ?? revoked, revoked)
                observedTo = max(observedTo ?? revoked, revoked)
            }
        }
        for preference in (state ?? .empty).preferences {
            guard trimmedBot == nil || preference.botID == trimmedBot else { continue }
            if inWindow(preference.createdAtMS) {
                suppressed += 1
                observedFrom = min(observedFrom ?? preference.createdAtMS, preference.createdAtMS)
                observedTo = max(observedTo ?? preference.createdAtMS, preference.createdAtMS)
            }
            if let revoked = preference.revokedAtMS, inWindow(revoked) {
                observedFrom = min(observedFrom ?? revoked, revoked)
                observedTo = max(observedTo ?? revoked, revoked)
            }
        }

        if let eventLog {
            var cursor = 0
            var pages = 0
            while pages < Self.maximumEventPages {
                let page = try await eventLog.events(after: cursor, limit: 500)
                if page.isEmpty { break }
                pages += 1
                for event in page where event.time >= fromMS && event.time <= toMS {
                    guard event.type == "proactive.considered" else { continue }
                    guard let data = event.data.objectValue else { continue }
                    let eventBot = Self.string(data["botId"]) ?? event.principal.botId
                    if let trimmedBot, eventBot != trimmedBot { continue }
                    let decision = Self.string(data["decision"]) ?? ""
                    switch decision {
                    case "would":
                        would += 1
                        observedFrom = min(observedFrom ?? event.time, event.time)
                        observedTo = max(observedTo ?? event.time, event.time)
                    case "did":
                        did += 1
                        observedFrom = min(observedFrom ?? event.time, event.time)
                        observedTo = max(observedTo ?? event.time, event.time)
                    default:
                        if Self.string(data["reason"]) == "feedback-held" {
                            held += 1
                            observedFrom = min(observedFrom ?? event.time, event.time)
                            observedTo = max(observedTo ?? event.time, event.time)
                        }
                    }
                }
                guard let next = page.compactMap(\.commitSeq).max(), next > cursor else { break }
                cursor = next
                if page.count < 500 { break }
            }
            if pages == Self.maximumEventPages { truncated = true }
        } else {
            notes.append("event-log-unavailable")
        }

        let observedSpanDays = {
            guard let observedFrom, let observedTo else { return 0.0 }
            return Double(observedTo - observedFrom) / 86_400_000.0
        }()
        if observedSpanDays < 14 { notes.append("window-shorter-than-14-days") }
        if did == 0 { notes.append("no-user-visible-deliveries") }
        if adopted + undone == 0 { notes.append("no-adoption-events") }
        if truncated { notes.append("event-window-truncated") }
        let adoptionRate: Double?
        if did > 0, adopted + undone > 0, observedSpanDays >= 14 {
            adoptionRate = Double(adopted) / Double(did)
        } else {
            adoptionRate = nil
        }
        let undoRate: Double?
        if did > 0, adopted + undone > 0, observedSpanDays >= 14 {
            undoRate = Double(undone) / Double(did)
        } else {
            undoRate = nil
        }
        let density: Double?
        if did > 0, observedSpanDays > 0 {
            density = Double(did) / observedSpanDays
        } else {
            density = nil
        }
        let window = BotWouldCollectionReport.Window(
            fromMS: fromMS, toMS: toMS, spanDays: observedSpanDays)
        return BotWouldCollectionReport(
            botID: trimmedBot, window: window, would: would, did: did, heldByFeedback: held,
            adopted: adopted, undone: undone, suppressed: suppressed,
            adoptionRate: adoptionRate, undoRate: undoRate,
            deliveryDensityPerDay: density, nonEstimable: notes, generatedAtMS: now())
    }

    // MARK: - delivery resolution

    private func resolveDelivery(_ target: BotFeedbackArtifactRef, botID: String,
                                 snapshot: BotFeedbackState) async -> BotFeedbackDelivery? {
        if target.kind == .routine {
            let routineID = Self.trim(target.id)
            if let hit = snapshot.deliveries.last(where: {
                $0.botID == botID && $0.routineID == routineID
            }) { return hit }
            return await deliveryFromEventLog(target: target, botID: botID)
        }
        let key = Self.trim(target.deliveryKey ?? "")
        let id = Self.trim(target.id)
        if let hit = snapshot.deliveries.last(where: { delivery in
            guard delivery.botID == botID else { return false }
            if !key.isEmpty { return delivery.dedupeKey == key }
            return delivery.id == id || delivery.decisionID == id
                || delivery.dedupeKey == id || delivery.rowID == id
        }) { return hit }
        return await deliveryFromEventLog(target: target, botID: botID)
    }

    private func deliveryFromEventLog(target: BotFeedbackArtifactRef,
                                      botID: String) async -> BotFeedbackDelivery? {
        guard let eventLog else { return nil }
        var cursor = 0
        var found: BotFeedbackDelivery?
        for _ in 0..<Self.maximumEventPages {
            guard let page = try? await eventLog.events(after: cursor, limit: 500),
                  !page.isEmpty else { break }
            for event in page where event.type == "proactive.considered" {
                guard let data = event.data.objectValue,
                      let decision = Self.string(data["decision"]), decision == "did",
                      (Self.string(data["botId"]) ?? event.principal.botId) == botID else { continue }
                let dedupeKey = Self.string(data["dedupeKey"]) ?? ""
                let decisionID = event.eventId
                let rowID = Self.string(data["rowId"])
                let id = Self.trim(target.id)
                let key = Self.trim(target.deliveryKey ?? "")
                let matches: Bool
                if target.kind == .routine {
                    matches = (Self.string(data["routineId"]) ?? "") == id
                } else if !key.isEmpty {
                    matches = dedupeKey == key
                } else {
                    matches = decisionID == id || dedupeKey == id || rowID == id
                }
                guard matches else { continue }
                found = BotFeedbackDelivery(
                    botID: botID, dedupeKey: dedupeKey, decisionID: decisionID,
                    kind: Self.string(data["kind"]) ?? "",
                    routineID: Self.string(data["routineId"]),
                    reminderID: Self.string(data["reminderId"]),
                    trigger: Self.string(data["trigger"]), rowID: rowID,
                    atMS: event.time,
                    classKey: Self.classKey(kind: Self.string(data["kind"]) ?? "",
                                            routineID: Self.string(data["routineId"]),
                                            reminderID: Self.string(data["reminderId"])))
            }
            guard let next = page.compactMap(\.commitSeq).max(), next > cursor else { break }
            cursor = next
            if page.count < 500 { break }
        }
        if let found, var state {
            state.deliveries.append(found)
            self.state = state
        }
        return found
    }

    // MARK: - state <-> index

    static func state(from index: BotFeedbackIndexFile) -> BotFeedbackState {
        var state = BotFeedbackState()
        for item in index.records {
            let botID = botID(fromFeedbackID: item.feedbackID) ?? "bot"
            let target = BotFeedbackArtifactRef(
                kind: item.target.kind, id: item.target.id,
                version: item.target.version, deliveryKey: item.target.deliveryKey)
            switch item.action {
            case .suppress:
                state.preferences.append(BotFeedbackPreference(
                    id: item.feedbackID, botID: botID, scopeKind: item.scope.kind,
                    scopeKey: item.scope.key, classKey: item.classKey ?? item.scope.key,
                    createdAtMS: item.createdAtMS, expiresAtMS: item.expiresAtMS,
                    revokedAtMS: item.status == .active ? nil : item.createdAtMS,
                    revokedByFeedbackID: item.status == .undone ? "index" : nil))
            case .adopt:
                state.adoptions.append(BotFeedbackAdoption(
                    artifactKey: item.scope.key, botID: botID,
                    feedbackID: item.feedbackID, atMS: item.createdAtMS,
                    revokedAtMS: item.status == .active ? nil : item.createdAtMS,
                    revokedByFeedbackID: item.status == .undone ? "index" : nil))
            case .correct:
                let corrected = item.target.version ?? 1
                state.corrections.append(BotFeedbackCorrection(
                    feedbackID: item.feedbackID, botID: botID, path: item.target.id,
                    refs: [], correctedVersion: corrected,
                    supersededVersion: max(0, corrected - 1), atMS: item.createdAtMS,
                    retractedAtMS: item.status == .active ? nil : item.createdAtMS,
                    retractedByFeedbackID: item.status == .undone ? "index" : nil))
            case .undo:
                continue
            }
            state.records.append(BotFeedbackRecord(
                id: item.feedbackID, action: item.action, botID: botID,
                origin: BotFeedbackOrigin(kind: .uiAction, nonce: "index-\(item.feedbackID)"),
                target: target, scopeKind: item.scope.kind, scopeKey: item.scope.key,
                classKey: item.classKey, accepted: true, atMS: item.createdAtMS,
                nonce: "", eventAppended: true))
        }
        return state
    }

    static func index(from state: BotFeedbackState, cursor: Int, now: Int64)
        -> BotFeedbackIndexFile {
        var records: [BotFeedbackIndexRecord] = []
        for preference in state.preferences {
            let target = BotFeedbackIndexRecord.Target(
                kind: .proactive, id: Self.capped(preference.scopeKey))
            let status: BotFeedbackIndexRecord.Status
            if preference.revokedAtMS != nil {
                status = .undone
            } else if let expires = preference.expiresAtMS, now >= expires {
                status = .expired
            } else {
                status = .active
            }
            records.append(BotFeedbackIndexRecord(
                feedbackID: preference.id, action: .suppress, target: target,
                scope: .init(kind: preference.scopeKind, key: preference.scopeKey),
                classKey: preference.classKey, status: status,
                createdAtMS: preference.createdAtMS, expiresAtMS: preference.expiresAtMS))
        }
        for adoption in state.adoptions {
            records.append(BotFeedbackIndexRecord(
                feedbackID: adoption.feedbackID, action: .adopt,
                target: .init(kind: .proactive, id: Self.capped(adoption.artifactKey)),
                scope: .init(kind: .artifact, key: Self.capped(adoption.artifactKey)),
                status: adoption.revokedAtMS == nil ? .active : .undone,
                createdAtMS: adoption.atMS))
        }
        for correction in state.corrections {
            records.append(BotFeedbackIndexRecord(
                feedbackID: correction.feedbackID, action: .correct,
                target: .init(kind: .memory, id: correction.path,
                              version: correction.correctedVersion),
                scope: .init(kind: .artifact,
                             key: Self.memoryScopeKey(path: correction.path,
                                                      version: correction.correctedVersion)),
                status: correction.retractedAtMS == nil ? .active : .undone,
                createdAtMS: correction.atMS))
        }
        records.sort { $0.createdAtMS < $1.createdAtMS }
        var activeCount = records.filter { $0.status == .active }.count
        if activeCount > BotFeedbackIndexLimits.maximumActive {
            var toDrop = activeCount - BotFeedbackIndexLimits.maximumActive
            records.removeAll { record in
                guard toDrop > 0, record.status == .active else { return false }
                toDrop -= 1
                activeCount -= 1
                return true
            }
        }
        if records.count > BotFeedbackIndexLimits.maximumTotal {
            records.removeFirst(records.count - BotFeedbackIndexLimits.maximumTotal)
        }
        return BotFeedbackIndexFile(v: BotFeedbackIndexFile.currentVersion,
                                    records: records, rebuiltFromCommitSeq: cursor)
    }

    /// Replays one durable event into the in-memory view. Used by startup
    /// replay; ordering is commit-sequence order from the event log.
    static func apply(_ record: BotFeedbackRecord, to state: inout BotFeedbackState) {
        guard !state.records.contains(where: { $0.id == record.id }) else { return }
        state.records.append(record)
        guard record.accepted else { return }
        switch record.action {
        case .suppress:
            guard let scopeKey = record.scopeKey else { return }
            state.preferences.append(BotFeedbackPreference(
                id: record.id, botID: record.botID, scopeKind: record.scopeKind,
                scopeKey: scopeKey, classKey: record.classKey ?? scopeKey,
                createdAtMS: record.atMS, expiresAtMS: record.expiresAtMS))
        case .adopt:
            guard let scopeKey = record.scopeKey else { return }
            state.adoptions.append(BotFeedbackAdoption(
                artifactKey: scopeKey, botID: record.botID,
                feedbackID: record.id, atMS: record.atMS))
        case .correct:
            guard let applied = record.applied else { return }
            state.corrections.append(BotFeedbackCorrection(
                feedbackID: record.id, botID: record.botID, path: applied.path,
                refs: record.subjects, correctedVersion: applied.version,
                supersededVersion: applied.previousVersion, atMS: record.atMS))
        case .undo:
            guard let reverses = record.reverses else { return }
            for index in state.preferences.indices
            where state.preferences[index].id == reverses
                && state.preferences[index].revokedAtMS == nil {
                state.preferences[index].revokedAtMS = record.atMS
                state.preferences[index].revokedByFeedbackID = record.id
            }
            for index in state.adoptions.indices
            where state.adoptions[index].feedbackID == reverses
                && state.adoptions[index].revokedAtMS == nil {
                state.adoptions[index].revokedAtMS = record.atMS
                state.adoptions[index].revokedByFeedbackID = record.id
            }
            for index in state.corrections.indices
            where state.corrections[index].feedbackID == reverses
                && state.corrections[index].retractedAtMS == nil {
                state.corrections[index].retractedAtMS = record.atMS
                state.corrections[index].retractedByFeedbackID = record.id
            }
        }
    }

    static func record(from event: BotEvent) -> BotFeedbackRecord? {
        guard case .object(let data) = event.data,
              string(data["schema"]) == BotFeedbackRecord.currentSchema,
              let feedbackID = string(data["feedback_id"]),
              let actionText = string(data["action"]),
              let action = BotFeedbackAction(rawValue: actionText),
              case .object(let origin)? = data["origin"],
              let originKindText = string(origin["kind"]),
              let originKind = BotFeedbackOriginKind(rawValue: originKindText),
              let nonce = string(origin["nonce"]),
              case .object(let target)? = data["target"],
              let targetKindText = string(target["kind"]),
              let targetKind = BotFeedbackArtifactKind(rawValue: targetKindText),
              let targetID = string(target["id"]),
              case .object(let scope)? = data["scope"],
              let scopeKindText = string(scope["kind"]),
              let scopeKind = BotFeedbackScopeKind(rawValue: scopeKindText),
              let scopeKey = string(scope["key"]) else { return nil }
        var version: Int?
        if let parsed = BotJSONInteger.int(target["version"]) { version = parsed }
        var expires: Int64?
        if let parsed = BotJSONInteger.int64(data["expires_at_ms"]) { expires = parsed }
        var subjects: [String] = []
        if case .array(let values)? = data["subjects"] {
            for value in values {
                if case .string(let text) = value { subjects.append(text) }
            }
        }
        var applied: BotFeedbackMemoryApplication?
        if case .object(let appliedObject)? = data["applied"],
           case .object(let memoryObject)? = appliedObject["memory"],
           let path = string(memoryObject["path"]),
           let versionNumber = BotJSONInteger.int(memoryObject["version"]),
           let previousNumber = BotJSONInteger.int(memoryObject["previous_version"]) {
            applied = BotFeedbackMemoryApplication(path: path,
                                                   version: versionNumber,
                                                   previousVersion: previousNumber)
        }
        let botID = botID(fromFeedbackID: feedbackID) ?? event.principal.botId ?? "bot"
        return BotFeedbackRecord(
            id: feedbackID, action: action, botID: botID,
            origin: BotFeedbackOrigin(kind: originKind,
                                      sessionID: string(origin["session_id"]),
                                      nonce: nonce),
            target: BotFeedbackArtifactRef(kind: targetKind, id: targetID, version: version,
                                           deliveryKey: string(target["delivery_key"])),
            scopeKind: scopeKind, scopeKey: scopeKey,
            classKey: string(data["class_key"]), subjects: subjects,
            applied: applied, reverses: string(data["reverses"]),
            accepted: bool(data["accepted"]) ?? true, atMS: event.time,
            expiresAtMS: expires, nonce: nonce, eventID: event.eventId,
            eventAppended: true)
    }

    static func delivery(from event: BotEvent) -> BotFeedbackDelivery? {
        guard event.type == "proactive.considered",
              case .object(let data) = event.data,
              let decision = string(data["decision"]), decision == "did",
              let dedupeKey = string(data["dedupeKey"]),
              let botID = string(data["botId"]) ?? event.principal.botId else { return nil }
        return BotFeedbackDelivery(
            botID: botID, dedupeKey: dedupeKey, decisionID: event.eventId,
            kind: string(data["kind"]) ?? "",
            routineID: string(data["routineId"]), reminderID: string(data["reminderId"]),
            trigger: string(data["trigger"]), rowID: string(data["rowId"]),
            atMS: event.time,
            classKey: classKey(kind: string(data["kind"]) ?? "",
                               routineID: string(data["routineId"]),
                               reminderID: string(data["reminderId"])))
    }

    // MARK: - helpers

    static func classKey(for candidate: ProactiveCandidate) -> String {
        classKey(kind: candidate.kind.rawValue, routineID: candidate.routineId,
                 reminderID: candidate.reminderId)
    }

    static func classKey(kind: String, routineID: String?, reminderID: String?) -> String {
        if kind == ProactiveKind.routineResult.rawValue,
           let routineID, !trim(routineID).isEmpty {
            return "routine:\(capped(trim(routineID), max: 64))"
        }
        if kind == ProactiveKind.reminder.rawValue,
           let reminderID, !trim(reminderID).isEmpty {
            return "proactive:reminder:\(capped(trim(reminderID), max: 64))"
        }
        return "proactive:\(kind)"
    }

    static func artifactKey(botID: String, dedupeKey: String) -> String {
        capped("proactive:\(botID):\(dedupeKey)")
    }

    static func rowArtifactKey(botID: String, rowID: String) -> String {
        capped("delivery:\(botID):\(trim(rowID))")
    }

    static func memoryScopeKey(path: String, version: Int) -> String {
        capped("memory:\(path)@v\(version)")
    }

    static func dedupeKey(for candidate: ProactiveCandidate, at: Int64) -> String {
        if let explicit = candidate.dedupeKey?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let payload = candidate.taskId ?? candidate.runId
            ?? candidate.reminderId ?? candidate.id ?? ""
        return "\(candidate.kind.rawValue):\(candidate.botId):\(payload.isEmpty ? String(at) : payload)"
    }

    static func messageID(botID: String, nonce: String) -> String {
        let bot = capped(sanitize(botID), max: 48)
        let room = maximumIDLength - 9 - 1
        let tail = capped(sanitize(nonce), max: max(1, room - bot.count - 1))
        return "feedback:\(bot):\(tail)"
    }

    static func eventID(for record: BotFeedbackRecord) -> String {
        "\(feedbackEventType):\(record.botID):\(record.nonce)"
    }

    static func botID(fromFeedbackID id: String) -> String? {
        let prefix = "feedback:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard let separator = rest.firstIndex(of: ":") else { return nil }
        let bot = String(rest[..<separator])
        return bot.isEmpty ? nil : bot
    }

    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capped(_ value: String, max: Int = 200) -> String {
        value.count <= max ? value : String(value.prefix(max))
    }

    static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        var output = ""
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else {
                output.append("-")
            }
        }
        return output.isEmpty ? "x" : output
    }

    static func isNarrowClassKey(_ key: String) -> Bool {
        key.hasPrefix("routine:") || key.hasPrefix("proactive:reminder:")
    }

    static func kindLevelClass(kind: String) -> String {
        "proactive:\(capped(trim(kind), max: 40))"
    }

    /// `proactive:<kind>` with no Bot-local id.
    static func isKindLevelClassKey(_ key: String) -> Bool {
        let pattern = #"^proactive:[a-z][a-z-]{0,39}$"#
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    static func safeClassKey(_ key: String) -> String? {
        let pattern = #"^(proactive:(task-done|routine-result|reminder(:[A-Za-z0-9._:-]{1,64})?)|routine:[A-Za-z0-9._:-]{1,64})$"#
        return key.range(of: pattern, options: .regularExpression) != nil ? key : nil
    }

    private static func recordBase(_ feedback: BotFeedback, at: Int64, scopeKey: String,
                                   classKey: String, accepted: Bool) -> BotFeedbackRecord {
        let nonce = trim(feedback.origin.nonce)
        return BotFeedbackRecord(
            id: messageID(botID: feedback.botID, nonce: nonce), action: feedback.action,
            botID: feedback.botID, origin: feedback.origin, target: feedback.target,
            scopeKind: feedback.scope, scopeKey: capped(scopeKey), classKey: classKey,
            accepted: accepted, atMS: at, expiresAtMS: feedback.expiresAtMS, nonce: nonce)
    }

    static func outcome(_ record: BotFeedbackRecord,
                        status: BotFeedbackOutcomeStatus,
                        reverses: String? = nil) -> BotFeedbackOutcome {
        BotFeedbackOutcome(status: status, feedbackID: record.id, action: record.action,
                           target: record.target, scope: record.scopeKind,
                           classKey: record.classKey, code: record.code,
                           reversed: reverses != nil, reverses: reverses,
                           auditPending: !record.eventAppended && record.eventID != nil,
                           appliedMemory: record.applied)
    }

    static func rejected(_ feedback: BotFeedback, code: String,
                         message: String) -> BotFeedbackOutcome {
        BotFeedbackOutcome(status: .rejected, action: feedback.action, target: feedback.target,
                           scope: feedback.scope, code: code, message: message)
    }

    static func eventData(_ record: BotFeedbackRecord) -> [String: BotJSONValue] {
        var data: [String: BotJSONValue] = [
            "schema": .string(BotFeedbackRecord.currentSchema),
            "feedback_id": .string(capped(record.id, max: maximumIDLength + 9)),
            "action": .string(record.action.rawValue),
            "origin": .object([
                "kind": .string(record.origin.kind.rawValue),
                "session_id": .string(capped(record.origin.sessionID ?? "", max: 64)),
                "nonce": .string(capped(record.nonce, max: 128)),
                "verified_by": .string("host"),
            ]),
            "target": .object([
                "kind": .string(record.target.kind.rawValue),
                "id": .string(capped(record.target.id, max: 200)),
            ]),
            "scope": .object([
                "kind": .string(record.scopeKind.rawValue),
                "key": .string(capped(record.scopeKey ?? record.classKey ?? "-", max: 200)),
            ]),
            "subjects": .array(record.subjects.prefix(8).map(BotJSONValue.string)),
            "accepted": .bool(record.accepted),
        ]
        if case .object(var origin)? = data["origin"], (record.origin.sessionID ?? "").isEmpty {
            origin.removeValue(forKey: "session_id")
            data["origin"] = .object(origin)
        }
        if let version = record.target.version {
            if case .object(var target)? = data["target"] {
                target["version"] = .number(Double(version))
                data["target"] = .object(target)
            }
        }
        if let deliveryKey = record.target.deliveryKey {
            if case .object(var target)? = data["target"] {
                target["delivery_key"] = .string(capped(deliveryKey, max: 200))
                data["target"] = .object(target)
            }
        }
        if let classKey = record.classKey, let safe = safeClassKey(classKey) {
            data["class_key"] = .string(safe)
        }
        if let applied = record.applied {
            data["applied"] = .object([
                "memory": .object([
                    "path": .string(capped(applied.path, max: 200)),
                    "version": .number(Double(applied.version)),
                    "previous_version": .number(Double(applied.previousVersion)),
                ]),
            ])
        }
        if let reverses = record.reverses {
            data["reverses"] = .string(capped(reverses, max: maximumIDLength + 9))
        }
        if let expires = record.expiresAtMS {
            data["expires_at_ms"] = .number(Double(expires))
        }
        return data
    }

    private static func string(_ value: BotJSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func bool(_ value: BotJSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }

    private static func healthLabel(_ error: BotFeedbackStoreError) -> String {
        switch error {
        case .unsupportedVersion(let version): return "index-version-\(version)-ignored"
        case .corrupted(let reason): return "index-\(reason)"
        case .unavailable(let reason): return "index-\(reason)"
        }
    }
}

extension BotJSONValue {
    var objectValue: [String: BotJSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}

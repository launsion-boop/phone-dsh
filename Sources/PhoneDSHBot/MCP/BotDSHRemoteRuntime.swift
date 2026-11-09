// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public struct BotRemoteTurnResult: Sendable, Equatable {
    public let sessionId: String
    public let turnId: String?
    public let status: String
    public let text: String
    public let error: String?

    public init(sessionId: String, turnId: String?, status: String, text: String, error: String? = nil) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.status = status
        self.text = text
        self.error = error
    }
}

/// A live view of the main chat turn for the Bot page, taken from the same
/// `session/follow` stream `collectTurn` already reads. In-process only: it is
/// not persisted, not a row and not part of any wire contract. Hidden
/// interactions and the text suppressed after a question card never appear.
public struct BotLiveTurnFrame: Sendable {
    public enum Kind: Sendable {
        /// A model attempt (step or retry) started streaming; text restarts.
        case streamStart
        /// A visible `text-delta` chunk.
        case textDelta(String)
        /// A durable DSH session event: `turn/start`, `step/start`,
        /// `assistant/message`, `tool/call`, `tool/result` or `turn/end`.
        case event(BotJSONValue)
    }

    public let sessionId: String
    public let turnId: String?
    public let kind: Kind
}

public actor BotDSHRemoteRuntime: BotTaskExecuting, BotTaskRestarting {
    /// Durable task projection. It is stored as `persistedTask` inside the
    /// existing `task.created`/`task.updated` events, so no new table, event
    /// type or wire field is introduced.
    struct PersistedBotTask: Codable, Sendable, Equatable {
        var taskId: String
        var sessionId: String
        var parentSessionId: String
        var parentBotId: String
        var parentIncarnation: String
        var parentKind: String
        var title: String
        var prompt: String
        var asynchronous: Bool
        var timeoutMs: Int
        var status: String
        var result: String?
        var partial: String?
        var error: String?
        var createdAt: Int64
        var wakeDelivered: Bool
    }

    private struct TaskState {
        var ownerBotId: String
        var ownerSessionId: String
        var ownerIncarnation: String
        var parentKind: BotSessionKind
        var title: String
        var prompt: String
        var asynchronous: Bool
        var timeoutMs: Int
        var record: BotTaskRecord
        var generation: Int
        var work: Task<BotTaskRecord, Error>?
        var stopWork: Task<BotTaskRecord, Error>?
        var live: Bool
        var wakeDelivered: Bool
    }

    private struct TurnCoordinator {
        let sessionId: String
        let attemptId: String
        let kind: BotSessionKind
        let hidden: Bool
        let work: Task<BotRemoteTurnResult, Error>
        var cancelRequested: Bool
        var promptAccepted: Bool
    }

    private struct QueuedTurn {
        let attemptId: String
        let work: Task<BotRemoteTurnResult, Error>
        var cancelled: Bool
    }

    private var transport: any DSHRemoteTransport
    private let runtime: BotMCPRuntime
    private let botId: String
    private let model: String
    private let providerName: String
    private let botDataDirectory: String
    private let onSessionRegistered: (@Sendable (String) -> Void)?
    private let now: @Sendable () -> Int64
    private let ledger: BotLLMLedger
    private let watchdog: BotWatchdogMonitor
    private let wakeInbox: WakeInbox?
    private var sessions: [String: BotGatewayPrincipal] = [:]
    private var coordinators: [String: TurnCoordinator] = [:]
    private var queuedTurns: [String: QueuedTurn] = [:]
    private var recentHeldChatActions: [(requestId: String, nonce: String)] = []
    private var taskStates: [String: TaskState] = [:]
    private var interruptedTaskWakes: [String] = []
    private var routineSessions: [String: String] = [:]
    private var mainSessionTask: Task<String, Error>?
    private var liveObserver: (@Sendable (BotLiveTurnFrame) -> Void)?

    public private(set) var mainSessionId: String?

    public init(
        transport: any DSHRemoteTransport,
        runtime: BotMCPRuntime,
        botId: String = "main",
        model: String = "deepseek-flash",
        provider: String = "deepseek-official",
        wakeInbox: WakeInbox? = nil,
        botDataDirectory: String = BotWorkspaceLayout.defaultBotDataDirectory,
        onSessionRegistered: (@Sendable (String) -> Void)? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) async throws {
        self.transport = transport
        self.runtime = runtime
        self.botId = botId
        self.model = model
        providerName = provider
        self.wakeInbox = wakeInbox
        self.botDataDirectory = botDataDirectory
        self.onSessionRegistered = onSessionRegistered
        self.now = now
        ledger = BotLLMLedger(eventLog: runtime.store)
        watchdog = BotWatchdogMonitor(eventLog: runtime.store, now: now)
        try await runtime.grants.recover()
        await runtime.attachTaskExecutor(self)
        await restorePersistedTasks()
    }

    public func attachTransport(_ newTransport: any DSHRemoteTransport) async {
        transport = newTransport
        guard mainSessionId != nil else { return }
        for (sessionId, coordinator) in coordinators {
            do {
                try await cancelTurn(sessionId: sessionId, includeQueued: true)
            } catch {
                coordinator.work.cancel()
                if coordinators[sessionId]?.attemptId == coordinator.attemptId {
                    coordinators.removeValue(forKey: sessionId)
                }
                await runtime.endTurn(sessionId: sessionId)
            }
        }
        for queued in queuedTurns.values { queued.work.cancel() }
        queuedTurns.removeAll()
        sessions.removeAll()
        mainSessionId = nil
    }

    /// `requestId` is the DSH prompt idempotency key. Callers replaying a
    /// persisted delivery (user action nonce, held inbox item, routine run)
    /// must pass the same value so the Worker does not open a second turn.
    public func sendUserMessage(_ text: String, requestId: String? = nil,
                                attachments: [BotAttachment] = []) async throws -> BotRemoteTurnResult {
        guard attachments.count <= BotAttachmentPolicy.maxCount else {
            throw BotMCPError.invalidRequest("too_many_attachments")
        }
        let sessionId = try await ensureMainSession()
        let steer = canSteer(sessionId: sessionId)
        var body = text
        let attachmentBlock = BotAttachmentPrompt.block(attachments)
        if !attachmentBlock.isEmpty {
            body = text.isEmpty
                ? String(attachmentBlock.drop(while: { $0 == "\n" }))
                : text + attachmentBlock
        }
        var prompt = body
        var stagedKey: String?
        var held = false
        var promptRequestId = requestId
        if !steer, let wakeInbox {
            let staged = try await wakeInbox.stage(now: now())
            stagedKey = staged.key
            if !staged.items.isEmpty {
                prompt = HeldMessages.block(items: staged.items) + "\n\n" + body
                held = true
                // Held deliveries derive their id from the item ids, not from
                // the random staged key, so a crash replay after `revert`
                // reuses the same id for the same items.
                promptRequestId = Self.deliveryRequestId(prefix: "held", items: staged.items)
                if let promptRequestId, let requestId, requestId.hasPrefix("user-action:") {
                    let nonce = String(requestId.dropFirst("user-action:".count))
                    recentHeldChatActions.removeAll { $0.requestId == promptRequestId }
                    recentHeldChatActions.append((promptRequestId, nonce))
                    if recentHeldChatActions.count > 64 { recentHeldChatActions.removeFirst() }
                }
            }
        }
        do {
            let result = try await runTurn(sessionId: sessionId, kind: .chat, prompt: prompt,
                                           hidden: false, held: held, requestId: promptRequestId)
            if let stagedKey { _ = try await wakeInbox?.commit(stagedKey) }
            return result
        } catch {
            if let stagedKey { _ = try await wakeInbox?.revert(stagedKey) }
            throw error
        }
    }

    /// The single runtime seam the app-layer attachment importer uses. It
    /// creates or recovers the durable main chat session before the first
    /// message, so the importer can write through the Worker's workspace
    /// import service without owning any session logic.
    public func ensureMainSessionID() async throws -> String {
        try await ensureMainSession()
    }

    public func sendHiddenInteraction(_ text: String, requestId: String? = nil) async throws -> BotRemoteTurnResult {
        let sessionId = try await ensureMainSession()
        return try await runTurn(sessionId: sessionId, kind: .chat, prompt: text,
                                 hidden: true, requestId: requestId)
    }

    /// One observer (the Bot page) receives live frames of visible main-chat
    /// turns; pass nil to stop.
    public func setLiveObserver(_ observer: (@Sendable (BotLiveTurnFrame) -> Void)?) {
        liveObserver = observer
    }

    public func heldChatActionNonces(sessionID: String) -> [String: String] {
        guard sessionID == mainSessionId else { return [:] }
        return Dictionary(uniqueKeysWithValues: recentHeldChatActions.map { ($0.requestId, $0.nonce) })
    }

    public func stopMainTurn(turnID: String?) async throws {
        let sessionId = try await ensureMainSession()
        if let turnID, coordinators[sessionId] != nil,
           await runtime.currentTurnID(sessionId: sessionId) != turnID {
            throw BotMCPError.invalidRequest("stale_turn")
        }
        try await cancelTurn(sessionId: sessionId)
    }

    public func stopTaskFromUser(taskID: String) async throws -> BotTaskRecord {
        guard let state = taskStates[taskID] else { throw BotMCPError.invalidRequest("unknown_task") }
        guard state.ownerBotId == botId, state.parentKind == .chat else { throw BotMCPError.unauthorized }
        if !state.live
            || ["stopped", "completed", "failed", "interrupted"].contains(state.record.status) {
            return state.record
        }
        let generation = state.generation + 1
        taskStates[taskID]?.generation = generation
        taskStates[taskID]?.record = BotTaskRecord(
            taskId: state.record.taskId, sessionId: state.record.sessionId,
            status: "stopping", title: state.record.title,
            result: nil, partial: state.record.partial, error: nil)
        return try await performStop(taskId: taskID, generation: generation)
    }

    public func cancelMainTurn() async throws {
        try await stopMainTurn(turnID: nil)
    }

    public func runRoutine(_ request: RoutineRunRequest) async -> RoutineExecutionResult {
        do {
            let sessionId = try await ensureRoutineSession(request.routine.id)
            let principal = try await ensureSession(sessionId: sessionId, kind: .routine)
            _ = try await runtime.eventWriter.append(
                type: "routine.run_started", principal: principal,
                data: .object([
                    "runId": .string(request.runId), "routineId": .string(request.routine.id),
                    "title": .string(request.routine.title), "attempt": .number(Double(request.attempt)),
                    "scheduledFor": .number(Double(request.startedAt)),
                ]), eventId: "started:\(request.runId)")
            let result = try await runTurn(
                sessionId: sessionId, kind: .routine, prompt: request.wake.text, hidden: true,
                requestId: "routine:\(request.runId)")
            let reply = RoutineWakeBuilder.normalizeReply(result.text)
            _ = try await runtime.eventWriter.append(
                type: "routine.run_finished", principal: principal,
                data: .object([
                    "runId": .string(request.runId), "routineId": .string(request.routine.id),
                    "title": .string(request.routine.title), "attempt": .number(Double(request.attempt)),
                    "status": .string(result.status), "text": .string(reply.text),
                    "quiet": .bool(reply.quiet), "delivery": .string(request.routine.delivery.rawValue),
                ]), eventId: "finished:\(request.runId)")
            if result.status == "completed" {
                return .success(result.text)
            }
            return RoutineExecutionResult(
                status: result.status == "cancelled" ? .cancelled : .failed,
                text: result.text, error: result.error ?? "routine turn failed")
        } catch {
            return .failure(String(describing: error))
        }
    }

    public func cancelRoutine(_ cancellation: RoutineCancellation) async -> RoutineCancellationResult {
        guard let sessionId = routineSessions[cancellation.routineId] else {
            return RoutineCancellationResult(cancelled: false, reason: "routine session is not active")
        }
        do {
            try await cancelTurn(sessionId: sessionId)
            return RoutineCancellationResult(cancelled: true)
        } catch {
            return RoutineCancellationResult(cancelled: false, reason: String(describing: error))
        }
    }

    public func start(request: BotTaskRequest) async throws -> BotTaskRecord {
        let taskId = "task-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let sessionId = try await createSession(kind: .task)
        let record = BotTaskRecord(
            taskId: taskId, sessionId: sessionId, status: "running", title: request.title,
            result: nil, partial: "")
        let state = TaskState(
            ownerBotId: request.parent.principal.botId,
            ownerSessionId: request.parent.sessionId,
            ownerIncarnation: request.parent.principal.incarnation,
            parentKind: request.parent.principal.kind,
            title: request.title, prompt: request.prompt,
            asynchronous: request.asynchronous, timeoutMs: request.timeoutMs,
            record: record, generation: 1, work: nil, stopWork: nil,
            live: true, wakeDelivered: false)
        taskStates[taskId] = state
        // Durability precedes work: a crash after this event leaves an
        // interrupted task the next process can report, never an orphan.
        do {
            try await persistTask(taskId: taskId, type: "task.created", eventId: "created:\(taskId)")
        } catch {
            taskStates.removeValue(forKey: taskId)
            throw error
        }
        if request.asynchronous {
            let work = Task { try await self.executeTask(taskId: taskId, generation: 1) }
            taskStates[taskId]?.work = work
            return record
        }
        return try await executeTask(taskId: taskId, generation: 1)
    }

    public func await(taskId: String, timeoutMs: Int, parent: BotResolvedToolCall) async throws -> BotTaskRecord {
        guard let state = try ownedTask(taskId: taskId, parent: parent) else {
            throw BotMCPError.invalidRequest("unknown task: \(taskId)")
        }
        if state.live, let work = state.work {
            let completed = await waitForTask(work, timeoutMs: timeoutMs)
            if !completed { return taskStates[taskId]?.record ?? state.record }
        }
        return taskStates[taskId]?.record ?? state.record
    }

    public func stop(taskId: String, parent: BotResolvedToolCall) async throws -> BotTaskRecord {
        guard let state = try ownedTask(taskId: taskId, parent: parent) else {
            throw BotMCPError.invalidRequest("unknown task: \(taskId)")
        }
        if let stopWork = state.stopWork { return try await stopWork.value }
        if ["stopped", "completed", "failed", "interrupted"].contains(state.record.status)
            || !state.live { return state.record }
        let generation = state.generation + 1
        taskStates[taskId]?.generation = generation
        taskStates[taskId]?.record = BotTaskRecord(
            taskId: state.record.taskId, sessionId: state.record.sessionId,
            status: "stopping", title: state.record.title,
            result: nil, partial: state.record.partial, error: nil)
        let work = Task { try await self.performStop(taskId: taskId, generation: generation) }
        taskStates[taskId]?.stopWork = work
        return try await work.value
    }

    private func performStop(taskId: String, generation: Int) async throws -> BotTaskRecord {
        guard let state = taskStates[taskId], state.generation == generation else {
            throw BotMCPError.invalidRequest("unknown task")
        }
        try await cancelTurn(sessionId: state.record.sessionId, includeQueued: true)
        state.work?.cancel()
        if let work = state.work { _ = try? await work.value }
        let stopped = BotTaskRecord(
            taskId: state.record.taskId, sessionId: state.record.sessionId,
            status: "stopped", title: state.record.title,
            result: nil, partial: state.record.partial, error: nil)
        if taskStates[taskId]?.generation == generation {
            taskStates[taskId]?.record = stopped
            taskStates[taskId]?.work = nil
            taskStates[taskId]?.stopWork = nil
            taskStates[taskId]?.live = false
            try? await persistTask(taskId: taskId, type: "task.updated",
                                   eventId: "persisted:stopped:\(taskId)")
            let principal = try await ensureSession(sessionId: stopped.sessionId, kind: .task)
            _ = try await runtime.eventWriter.append(
                type: "task.settled", principal: principal, data: stopped.jsonValue,
                eventId: "settled:\(taskId)")
        }
        return stopped
    }

    private func executeTask(taskId: String, generation: Int) async throws -> BotTaskRecord {
        guard let state = taskStates[taskId], state.generation == generation,
              state.record.status == "running" else {
            return taskStates[taskId]?.record ?? BotTaskRecord(
                taskId: taskId, sessionId: "", status: "stopped", title: "")
        }
        do {
            let turn = try await runTurn(
                sessionId: state.record.sessionId, kind: .task,
                prompt: state.prompt, hidden: true, requestId: "task-turn:\(taskId)")
            guard let current = taskStates[taskId], current.generation == generation,
                  current.record.status == "running" else {
                return taskStates[taskId]?.record ?? state.record
            }
            let completed = turn.status == "completed"
            let record = BotTaskRecord(
                taskId: taskId, sessionId: state.record.sessionId,
                status: completed ? "completed" : "failed", title: state.record.title,
                result: completed ? turn.text : nil,
                partial: turn.text, error: completed ? nil : turn.error ?? "task turn failed")
            taskStates[taskId]?.record = record
            taskStates[taskId]?.work = nil
            taskStates[taskId]?.live = false
            try? await persistTask(taskId: taskId, type: "task.updated",
                                   eventId: "persisted:settled:\(taskId)")
            let principal = try await ensureSession(sessionId: record.sessionId, kind: .task)
            _ = try await runtime.eventWriter.append(
                type: "task.settled", principal: principal, data: record.jsonValue,
                eventId: "settled:\(taskId)")
            if state.asynchronous, state.parentKind == .chat,
               taskStates[taskId]?.generation == generation {
                let prompt = "[SAND_HIDDEN_PROMPT][subagent]\n\(state.title) | \(record.status) | \(taskId)\n\(String(turn.text.prefix(1_200)))"
                _ = try await runTurn(
                    sessionId: state.ownerSessionId, kind: .chat, prompt: prompt, hidden: true,
                    requestId: "task-settled:\(taskId)")
            }
            return record
        } catch {
            guard let current = taskStates[taskId], current.generation == generation,
                  current.record.status == "running" else {
                return taskStates[taskId]?.record ?? state.record
            }
            let record = BotTaskRecord(
                taskId: taskId, sessionId: state.record.sessionId,
                status: "failed", title: state.record.title,
                result: nil, partial: nil, error: String(describing: error))
            taskStates[taskId]?.record = record
            taskStates[taskId]?.work = nil
            taskStates[taskId]?.live = false
            try? await persistTask(taskId: taskId, type: "task.updated",
                                   eventId: "persisted:failed:\(taskId)")
            return record
        }
    }

    private func ownedTask(taskId: String, parent: BotResolvedToolCall) throws -> TaskState? {
        guard let state = taskStates[taskId] else { return nil }
        guard state.ownerBotId == parent.principal.botId,
              state.ownerSessionId == parent.sessionId else {
            throw BotMCPError.unauthorized
        }
        // A live call is bound to the exact session incarnation. A persisted
        // record may outlive its incarnation; the same bot+session may still
        // read or stop it (and the interrupted status is explicit).
        if state.live, state.ownerIncarnation != parent.principal.incarnation {
            throw BotMCPError.unauthorized
        }
        return state
    }

    // MARK: - Durable task records

    /// Hides the Worker restart from `AwaitTask`/`StopSubagent`: every task
    /// that was running in the replaced process becomes an explicit
    /// `interrupted` record, and one parent wake is queued per asynchronous
    /// chat task. Terminal records survive too, so a restart never turns an
    /// existing task id into `unauthorized`.
    public func workerRestarted() async {
        let live = taskStates.filter { $0.value.live }
        for (taskId, state) in live {
            state.work?.cancel()
            state.stopWork?.cancel()
            let record = BotTaskRecord(
                taskId: state.record.taskId, sessionId: state.record.sessionId,
                status: "interrupted", title: state.record.title,
                result: nil, partial: state.record.partial, error: "worker_restarted")
            taskStates[taskId]?.record = record
            taskStates[taskId]?.generation = state.generation + 1
            taskStates[taskId]?.work = nil
            taskStates[taskId]?.stopWork = nil
            taskStates[taskId]?.live = false
            try? await persistTask(taskId: taskId, type: "task.updated",
                                   eventId: "persisted:interrupted:\(taskId)")
            if state.asynchronous, state.parentKind == .chat, !state.wakeDelivered,
               !interruptedTaskWakes.contains(taskId) {
                interruptedTaskWakes.append(taskId)
            }
        }
    }

    /// Delivers the single hidden wake for each task interrupted by a Worker
    /// restart. The prompt id is derived from the task id, so a crash between
    /// the turn and the wake marker makes the next attempt idempotent.
    @discardableResult
    public func deliverInterruptedTaskWakes() async -> Int {
        guard !interruptedTaskWakes.isEmpty else { return 0 }
        var delivered = 0
        for taskId in interruptedTaskWakes {
            guard let state = taskStates[taskId],
                  state.record.status == "interrupted", !state.wakeDelivered else {
                interruptedTaskWakes.removeAll { $0 == taskId }
                continue
            }
            let prompt = "[SAND_HIDDEN_PROMPT][subagent]\n"
                + "\(state.title) | interrupted | \(taskId)\n"
                + "The Worker restarted and interrupted this task; its result is incomplete."
            do {
                let result = try await runTurn(
                    sessionId: state.ownerSessionId, kind: .chat, prompt: prompt, hidden: true,
                    requestId: "task-interrupted:\(taskId)")
                guard result.status == "completed" else { continue }
                taskStates[taskId]?.wakeDelivered = true
                try? await persistTask(taskId: taskId, type: "task.updated",
                                       eventId: "persisted:wake:\(taskId)")
                interruptedTaskWakes.removeAll { $0 == taskId }
                delivered += 1
            } catch {
                continue
            }
        }
        return delivered
    }

    private func persistTask(taskId: String, type: String, eventId: String) async throws {
        guard let state = taskStates[taskId] else { return }
        let snapshot = PersistedBotTask(
            taskId: state.record.taskId, sessionId: state.record.sessionId,
            parentSessionId: state.ownerSessionId, parentBotId: state.ownerBotId,
            parentIncarnation: state.ownerIncarnation, parentKind: state.parentKind.rawValue,
            title: state.title, prompt: state.prompt, asynchronous: state.asynchronous,
            timeoutMs: state.timeoutMs, status: state.record.status,
            result: state.record.result, partial: state.record.partial,
            error: state.record.error, createdAt: now(), wakeDelivered: state.wakeDelivered)
        let principal = sessions[state.ownerSessionId] ?? BotGatewayPrincipal(
            botId: state.ownerBotId, sessionId: state.ownerSessionId,
            kind: state.parentKind, expiresAt: Int64.max,
            incarnation: state.ownerIncarnation)
        var data = state.record.jsonValue
        if case .object(var fields) = data {
            fields["persistedTask"] = try jsonValue(snapshot)
            data = .object(fields)
        }
        try await runtime.eventWriter.append(
            type: type, principal: principal, data: data, eventId: eventId)
    }

    private func restorePersistedTasks() async {
        var latest: [String: PersistedBotTask] = [:]
        var settled: [String: BotTaskRecord] = [:]
        var cursor = 0
        while true {
            let events: [BotEvent]
            do {
                events = try await runtime.store.events(after: cursor, limit: 1_000)
            } catch {
                break
            }
            for event in events {
                if let snapshot = Self.decodePersistedTask(event) {
                    latest[snapshot.taskId] = snapshot
                }
                if event.type == "task.settled", let record = Self.decodeTaskRecord(event.data),
                   let taskId = record["task_id"]?.stringValue {
                    settled[taskId] = BotTaskRecord(
                        taskId: taskId,
                        sessionId: record["sessionId"]?.stringValue ?? "",
                        status: record["status"]?.stringValue ?? "failed",
                        title: record["title"]?.stringValue ?? "",
                        result: record["result"]?.stringValue,
                        partial: record["partial"]?.stringValue,
                        error: record["error"]?.stringValue)
                }
            }
            guard events.count == 1_000, let last = events.last?.commitSeq else { break }
            cursor = last
        }
        for (taskId, stored) in latest {
            var snapshot = stored
            var record = BotTaskRecord(
                taskId: taskId, sessionId: snapshot.sessionId, status: snapshot.status,
                title: snapshot.title, result: snapshot.result,
                partial: snapshot.partial, error: snapshot.error)
            if let terminal = settled[taskId] {
                record = terminal
                snapshot.status = terminal.status
                snapshot.result = terminal.result
                snapshot.partial = terminal.partial
                snapshot.error = terminal.error
            }
            let interrupted = record.status == "running" || record.status == "stopping"
            if interrupted {
                record = BotTaskRecord(
                    taskId: taskId, sessionId: snapshot.sessionId, status: "interrupted",
                    title: snapshot.title, result: nil, partial: record.partial,
                    error: "worker_restarted")
                snapshot.status = "interrupted"
                snapshot.error = "worker_restarted"
            }
            let kind = BotSessionKind(rawValue: snapshot.parentKind) ?? .chat
            taskStates[taskId] = TaskState(
                ownerBotId: snapshot.parentBotId, ownerSessionId: snapshot.parentSessionId,
                ownerIncarnation: snapshot.parentIncarnation, parentKind: kind,
                title: snapshot.title, prompt: snapshot.prompt,
                asynchronous: snapshot.asynchronous, timeoutMs: snapshot.timeoutMs,
                record: record, generation: 1, work: nil, stopWork: nil,
                live: false, wakeDelivered: snapshot.wakeDelivered)
            if interrupted {
                try? await persistTask(taskId: taskId, type: "task.updated",
                                       eventId: "persisted:interrupted:\(taskId)")
            }
            if interrupted, snapshot.asynchronous, kind == .chat, !snapshot.wakeDelivered {
                interruptedTaskWakes.append(taskId)
            }
        }
        interruptedTaskWakes = Array(Set(interruptedTaskWakes)).sorted()
    }

    private static func decodePersistedTask(_ event: BotEvent) -> PersistedBotTask? {
        guard let value = event.data["persistedTask"],
              let data = try? value.encoded() else { return nil }
        return try? JSONDecoder().decode(PersistedBotTask.self, from: data)
    }

    private static func decodeTaskRecord(_ data: BotJSONValue) -> BotJSONValue? {
        data["task_id"] == nil ? nil : data
    }

    private static func deliveryRequestId(prefix: String, items: [WakeInboxItem]) -> String {
        let digest = (try? BotArgumentsDigest.string(for: .array(items.map { .string($0.id) })))
            ?? items.map(\.id).joined(separator: ",")
        return "\(prefix):\(digest)"
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> BotJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try BotJSONValue.parse(encoder.encode(value))
    }

    private func waitForTask(_ work: Task<BotTaskRecord, Error>, timeoutMs: Int) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await work.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutMs)) * 1_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    @discardableResult
    public func startMainSession() async throws -> String {
        try await ensureMainSession()
    }

    public func mainSessionIdentifier() -> String? { mainSessionId }

    public func isAvailable() async -> Bool {
        guard let mainSessionId else { return false }
        return await validateRemoteSession(mainSessionId)
    }

    public func isMainTurnBusy() -> Bool {
        guard let mainSessionId else { return false }
        return coordinators[mainSessionId] != nil || queuedTurns[mainSessionId] != nil
    }

    public func watchdogMonitor() -> BotWatchdogMonitor { watchdog }

    private func ensureMainSession() async throws -> String {
        if let mainSessionId { return mainSessionId }
        if let mainSessionTask { return try await mainSessionTask.value }
        let work = Task { try await self.recoverOrCreateMainSession() }
        mainSessionTask = work
        do {
            let sessionId = try await work.value
            mainSessionId = sessionId
            mainSessionTask = nil
            return sessionId
        } catch {
            mainSessionTask = nil
            throw error
        }
    }

    private struct RecoveredMainSession {
        let sessionId: String
        let cwd: String?
    }

    private func recoverOrCreateMainSession() async throws -> String {
        let root = botRoot()
        if let recovered = try await latestMainSessionEvent() {
            let recoveredCwd: String?
            if let stored = recovered.cwd {
                recoveredCwd = stored
            } else {
                recoveredCwd = await remoteSessionCwd(recovered.sessionId)
            }
            if recoveredCwd == root, await validateRemoteSession(recovered.sessionId, attempts: 100) {
                try await claimOwnedSession(recovered.sessionId)
                let principal = try await runtime.issueSession(botId: botId, sessionId: recovered.sessionId, kind: .chat)
                sessions[recovered.sessionId] = principal
                try await recordRuntimeStarted(recovered.sessionId, principal: principal, cwd: root)
                return recovered.sessionId
            }
            // The old chat session belongs to another cwd (the pre-root
            // `/dsh/workspace`, or a damaged/legacy header). DSH has no
            // session-delete Remote, so archive the old id and rebuild under a
            // fresh Bot id. The Bot domain data (events, memory, routines) is
            // untouched; only the DSH session is replaced.
            return try await rebuildMainSession(from: recovered.sessionId, cwd: root)
        }
        do {
            let sessionId = try await createSession(kind: .chat)
            let principal = try await ensureSession(sessionId: sessionId, kind: .chat)
            try await recordRuntimeStarted(sessionId, principal: principal, cwd: root)
            return sessionId
        } catch {
            // A persisted session can outlive its runtime.started event (an
            // event log restored from an older build). Its explicit
            // `gb-<botID>` id still exists under the old cwd, so
            // session/create rejects the cwd change as a conflict. Archive
            // that id and rebuild with a fresh Bot id instead of failing
            // forever.
            let legacyID = mintedSessionID(kind: .chat)
            if isSessionCwdConflict(error), await remoteSessionCwd(legacyID) != nil {
                return try await rebuildMainSession(from: legacyID, cwd: root)
            }
            throw error
        }
    }

    private func latestMainSessionEvent() async throws -> RecoveredMainSession? {
        var cursor = 0
        var latest: RecoveredMainSession?
        while true {
            let events = try await runtime.store.events(after: cursor, limit: 1_000)
            for event in events where event.type == "runtime.started"
                && event.principal.botId == botId && event.principal.kind == BotSessionKind.chat.rawValue {
                // An event that names no session cannot identify the main
                // session; skip it instead of recovering an empty id.
                guard let sessionId = event.data["sessionId"]?.stringValue ?? event.principal.sessionId,
                      !sessionId.isEmpty else { continue }
                latest = RecoveredMainSession(sessionId: sessionId, cwd: event.data["cwd"]?.stringValue)
            }
            guard events.count == 1_000, let commitSeq = events.last?.commitSeq else { return latest }
            cursor = commitSeq
        }
    }

    private func recordRuntimeStarted(
        _ sessionId: String, principal: BotGatewayPrincipal, cwd: String
    ) async throws {
        _ = try await runtime.eventWriter.append(
            type: "runtime.started", principal: principal,
            data: .object([
                "sessionId": .string(sessionId), "botId": .string(botId),
                "cwd": .string(cwd),
            ]))
    }

    /// Replaces an old main session without ever leaving the Bot sessionless:
    /// the replacement is created first, then the old id is archived, then the
    /// new `runtime.started` event is the durable commit point. Any failure
    /// after archiving rolls back by archiving the replacement and restoring
    /// the old id.
    private func rebuildMainSession(from oldSessionId: String, cwd: String) async throws -> String {
        onSessionRegistered?(oldSessionId)
        let newSessionId = rebuiltMainSessionID()
        let created = try await createSession(kind: .chat, sessionID: newSessionId)
        // Archive is best effort: if it fails the old id is still hidden by
        // BotSessionRegistry (`gb-` or explicitly registered) and the new
        // session stays usable. Never fail the rebuild just because the old
        // row could not be hidden a second way.
        _ = await archiveRemoteSession(oldSessionId)
        do {
            let principal = try await ensureSession(sessionId: created, kind: .chat)
            try await recordRuntimeStarted(created, principal: principal, cwd: cwd)
            return created
        } catch {
            _ = await archiveRemoteSession(created)
            _ = await unarchiveRemoteSession(oldSessionId)
            throw error
        }
    }

    private func archiveRemoteSession(_ sessionId: String) async -> Bool {
        do {
            _ = try await transport.call("workspace/archiveSession", args: .object(["request": .object([
                "sessionId": .string(sessionId), "stopActivity": .bool(false),
            ])]))
            return true
        } catch {
            return false
        }
    }

    private func unarchiveRemoteSession(_ sessionId: String) async -> Bool {
        do {
            _ = try await transport.call("workspace/unarchiveSession", args: .object(["request": .object([
                "sessionId": .string(sessionId),
            ])]))
            return true
        } catch {
            return false
        }
    }

    private func remoteSessionCwd(_ sessionId: String) async -> String? {
        do {
            // DSH 0.2.2-rc.1's gateway requires the reserved `_request` member
            // for `session/list` (assertExactArguments); a bare `{}` is
            // arguments-invalid and used to be swallowed here.
            let list = try await transport.call("session/list", args: .object(["_request": .object([:])]))
            for item in list["items"]?.arrayValue ?? [] where item["sessionId"]?.stringValue == sessionId {
                return item["cwd"]?.stringValue
            }
        } catch {
            await recordDiagnostic(
                "session/list cwd lookup failed for \(sessionId): \(error)", sessionId: sessionId)
        }
        return nil
    }

    /// Diagnostics go to the Bot journal's ephemeral `runtime.stderr` buffer,
    /// the same event writer this runtime already uses; no durable event,
    /// schema, or wire field is introduced.
    private func recordDiagnostic(_ message: String, sessionId: String) async {
        let principal = BotGatewayPrincipal(
            botId: botId, sessionId: sessionId, kind: .chat, expiresAt: Int64.max)
        _ = try? await runtime.eventWriter.append(
            type: "runtime.stderr", principal: principal,
            data: .object([
                "source": .string("BotDSHRemoteRuntime.remoteSessionCwd"),
                "message": .string(message),
            ]))
    }

    private func isSessionCwdConflict(_ error: Error) -> Bool {
        (error as? DSHRemoteError)?.code == "session/conflict"
    }

    private func botRoot() -> String {
        BotWorkspaceLayout.botRoot(botId: botId, dataDirectory: botDataDirectory)
    }

    private func rebuiltMainSessionID() -> String {
        "gb-\(BotWorkspaceLayout.safePathComponent(botId))-\(UUID().uuidString.lowercased())"
    }

    private func validateRemoteSession(_ sessionId: String, attempts: Int = 1) async -> Bool {
        for attempt in 0..<max(1, attempts) {
            do {
                let page = try await transport.call("session/page", args: .object(["request": .object([
                    "address": .object(["kind": .string("session"), "sessionId": .string(sessionId)]),
                    "throughSeq": .number(-1), "maxMessages": .number(1),
                ])]))
                if let returned = page["sessionId"]?.stringValue ?? page["session"]?["sessionId"]?.stringValue {
                    return returned == sessionId
                }
                return true
            } catch let error as DSHRemoteError where error.code == "session/not-found" && attempt + 1 < attempts {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return false
                }
            } catch {
                return false
            }
        }
        return false
    }

    private func ensureRoutineSession(_ routineId: String) async throws -> String {
        if let existing = routineSessions[routineId] {
            if await validateRemoteSession(existing) { return existing }
            routineSessions.removeValue(forKey: routineId)
        }
        let sessionId = try await createSession(kind: .routine)
        routineSessions[routineId] = sessionId
        return sessionId
    }

    private func createSession(kind: BotSessionKind, sessionID: String? = nil) async throws -> String {
        var fields: [String: BotJSONValue] = ["cwd": .string(botRoot())]
        fields["sessionId"] = .string(sessionID ?? mintedSessionID(kind: kind))
        let request: BotJSONValue = .object(fields)
        let created = try await transport.call("session/create", args: .object(["request": request]))
        guard let sessionId = created["sessionId"]?.stringValue, !sessionId.isEmpty else {
            throw BotMCPError.unavailable("session/create returned no sessionId")
        }
        try await claimOwnedSession(sessionId)
        let principal = try await runtime.issueSession(botId: botId, sessionId: sessionId, kind: kind)
        sessions[sessionId] = principal
        return sessionId
    }

    /// New Bot sessions carry the reserved `gb-` namespace even before the
    /// claim RPC lands; legacy/recovered ids are claimed explicitly. Both feed
    /// the Worker-local owned-session registry that gates identity/approval.
    private func mintedSessionID(kind: BotSessionKind) -> String {
        if kind == .chat { return "gb-\(BotWorkspaceLayout.safePathComponent(botId))" }
        return "gb-\(kind.rawValue)-\(UUID().uuidString.lowercased())"
    }

    /// A Bot session must be owned before its first turn. New `gb-` sessions
    /// are already deterministically owned by the Worker namespace; legacy or
    /// recovered ids need this RPC. A Worker that predates the claim method is
    /// tolerated only for `gb-` ids; everything else fails closed.
    private func claimOwnedSession(_ sessionId: String) async throws {
        // The App-side registry mirrors every id this runtime creates,
        // recovers or claims so the DSH pages can hide legacy non-`gb-` ids.
        onSessionRegistered?(sessionId)
        let response: BotJSONValue
        do {
            response = try await transport.call("phone/botClaimSession", args: .object([
                "request": .object(["sessionId": .string(sessionId)]),
            ]))
        } catch {
            if sessionId.hasPrefix("gb-") { return }
            throw error
        }
        guard response["ok"]?.boolValue == true else {
            // An unacknowledged claim can never make a legacy id safe.
            if sessionId.hasPrefix("gb-") { return }
            throw BotMCPError.unavailable("Bot session ownership was not acknowledged for \(sessionId)")
        }
    }

    private func ensureSession(sessionId: String, kind: BotSessionKind) async throws -> BotGatewayPrincipal {
        if let existing = sessions[sessionId] { return existing }
        guard await validateRemoteSession(sessionId) else {
            throw BotMCPError.unavailable("session/page could not resume \(sessionId)")
        }
        try await claimOwnedSession(sessionId)
        let principal = try await runtime.issueSession(botId: botId, sessionId: sessionId, kind: kind)
        sessions[sessionId] = principal
        return principal
    }

    private func canSteer(sessionId: String) -> Bool {
        guard queuedTurns[sessionId] == nil, let active = coordinators[sessionId],
              active.promptAccepted, !active.cancelRequested, active.kind == .chat, !active.hidden else { return false }
        return true
    }

    private func cancelTurn(sessionId: String, includeQueued: Bool = false) async throws {
        if includeQueued, var queued = queuedTurns[sessionId] {
            queued.cancelled = true
            queuedTurns[sessionId] = queued
        }
        guard var active = coordinators[sessionId] else {
            if includeQueued, let queued = queuedTurns[sessionId] {
                queued.work.cancel()
                _ = try? await queued.work.value
                queuedTurns.removeValue(forKey: sessionId)
            }
            return
        }
        active.cancelRequested = true
        coordinators[sessionId] = active
        _ = try await transport.call("session/cancel", args: .object(["request": .object([
            "sessionId": .string(sessionId),
            "cause": .object(["kind": .string("user")]),
        ])]))
        await waitForCancellation(active)
        if includeQueued, let queued = queuedTurns[sessionId] {
            queued.work.cancel()
            _ = try? await queued.work.value
            queuedTurns.removeValue(forKey: sessionId)
        }
    }

    private func waitForCancellation(_ coordinator: TurnCoordinator) async {
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await coordinator.work.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !completed {
            coordinator.work.cancel()
            if coordinators[coordinator.sessionId]?.attemptId == coordinator.attemptId {
                coordinators.removeValue(forKey: coordinator.sessionId)
            }
        }
    }

    private func runTurn(sessionId: String, kind: BotSessionKind,
                         prompt: String, hidden: Bool, held: Bool = false,
                         requestId: String? = nil) async throws -> BotRemoteTurnResult {
        _ = try await ensureSession(sessionId: sessionId, kind: kind)
        let requestId = requestId ?? "bot-\(UUID().uuidString.lowercased())"
        if canSteer(sessionId: sessionId), kind == .chat, !hidden,
           let active = coordinators[sessionId] {
            try await sendPrompt(sessionId: sessionId, prompt: prompt, mode: "steer", requestId: requestId)
            return try await active.work.value
        }
        if let predecessor = queuedTurns[sessionId]?.work ?? coordinators[sessionId]?.work {
            let attemptId = UUID().uuidString.lowercased()
            let work = Task { () throws -> BotRemoteTurnResult in
                _ = try? await predecessor.value
                if let queued = queuedTurns[sessionId], queued.attemptId == attemptId {
                    queuedTurns.removeValue(forKey: sessionId)
                    if queued.cancelled {
                        return BotRemoteTurnResult(
                            sessionId: sessionId, turnId: nil, status: "cancelled", text: "", error: "cancelled")
                    }
                }
                return try await startCoordinatedTurn(
                    sessionId: sessionId, kind: kind, prompt: prompt, hidden: hidden, held: held,
                    attemptId: attemptId, requestId: requestId)
            }
            queuedTurns[sessionId] = QueuedTurn(attemptId: attemptId, work: work, cancelled: false)
            return try await work.value
        }
        return try await startCoordinatedTurn(
            sessionId: sessionId, kind: kind, prompt: prompt, hidden: hidden, held: held,
            attemptId: UUID().uuidString.lowercased(), requestId: requestId)
    }

    private func startCoordinatedTurn(sessionId: String, kind: BotSessionKind,
                                      prompt: String, hidden: Bool, held: Bool,
                                      attemptId: String, requestId: String) async throws -> BotRemoteTurnResult {
        let work = Task { try await self.performCoordinatedTurn(
            sessionId: sessionId, kind: kind, prompt: prompt, hidden: hidden, held: held,
            attemptId: attemptId, requestId: requestId) }
        coordinators[sessionId] = TurnCoordinator(
            sessionId: sessionId, attemptId: attemptId, kind: kind, hidden: hidden,
            work: work, cancelRequested: false, promptAccepted: false)
        return try await work.value
    }

    private func performCoordinatedTurn(sessionId: String, kind: BotSessionKind,
                                        prompt: String, hidden: Bool, held: Bool,
                                        attemptId: String, requestId: String) async throws -> BotRemoteTurnResult {
        await runtime.beginTurn(sessionId: sessionId, hidden: hidden, held: held)
        var mux: (any DSHMuxConnection)?
        do {
            let opened = try await transport.openMux()
            mux = opened
            try await opened.send(.object([
                "type": .string("open"), "streamId": .string("follow"),
                "endpoint": .string("session/follow"),
                "payload": .object(["args": .object(["request": .object([
                    "address": .object(["kind": .string("session"), "sessionId": .string(sessionId)]),
                    "maxMessages": .number(64), "assistantStream": .bool(true),
                ])])]),
            ]))
            try await waitForSnapshot(mux: opened)
            if coordinators[sessionId]?.attemptId != attemptId {
                await opened.close()
                await finishCoordinatedTurn(sessionId: sessionId, attemptId: attemptId)
                return BotRemoteTurnResult(
                    sessionId: sessionId, turnId: nil, status: "cancelled", text: "", error: "stale turn attempt")
            }
            if coordinators[sessionId]?.cancelRequested == true {
                await opened.close()
                await finishCoordinatedTurn(sessionId: sessionId, attemptId: attemptId)
                return BotRemoteTurnResult(
                    sessionId: sessionId, turnId: nil, status: "cancelled", text: "", error: "cancelled")
            }
            try await sendPrompt(sessionId: sessionId, prompt: prompt, mode: "queue", requestId: requestId)
            coordinators[sessionId]?.promptAccepted = true
            let result = try await collectTurn(
                mux: opened, sessionId: sessionId, kind: kind, hidden: hidden, attemptId: attemptId)
            await opened.close()
            await finishCoordinatedTurn(sessionId: sessionId, attemptId: attemptId)
            return result
        } catch {
            if let mux { await mux.close() }
            await finishCoordinatedTurn(sessionId: sessionId, attemptId: attemptId)
            throw error
        }
    }

    private func finishCoordinatedTurn(sessionId: String, attemptId: String) async {
        guard coordinators[sessionId]?.attemptId == attemptId else { return }
        await runtime.endTurn(sessionId: sessionId)
        coordinators.removeValue(forKey: sessionId)
    }

    private func sendPrompt(sessionId: String, prompt: String, mode: String,
                            requestId: String) async throws {
        _ = try await transport.call("session/prompt", args: .object(["request": .object([
            "requestId": .string(requestId), "sessionId": .string(sessionId), "mode": .string(mode),
            "content": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
        ])]))
    }

    private func waitForSnapshot(mux: any DSHMuxConnection) async throws {
        while true {
            guard let frame = try await mux.receive() else {
                throw BotMCPError.unavailable("session/follow ended before its snapshot")
            }
            if frame["type"]?.stringValue == "error" {
                throw BotMCPError.unavailable(frame["error"]?["message"]?.stringValue ?? "session/follow failed")
            }
            guard frame["type"]?.stringValue == "item",
                  frame["streamId"]?.stringValue == "follow" else { continue }
            let value = frame["value"] ?? .null
            if value["type"]?.stringValue == "snapshot" { return }
            if value["type"]?.stringValue == "end" {
                throw BotMCPError.unavailable("session/follow ended before its snapshot")
            }
        }
    }

    private func collectTurn(mux: any DSHMuxConnection, sessionId: String,
                             kind: BotSessionKind, hidden: Bool,
                             attemptId: String) async throws -> BotRemoteTurnResult {
        var currentTurn: String?
        var stepStartedAt: Int64?
        var firstDeltaAt: Int64?
        var texts: [String] = []
        var resultTexts: [String] = []
        var toolNames: [String: String] = [:]
        var suppressWrapUp = false
        let live = kind == .chat && !hidden
        func publish(_ frameKind: BotLiveTurnFrame.Kind) {
            guard live, let liveObserver else { return }
            liveObserver(BotLiveTurnFrame(sessionId: sessionId, turnId: currentTurn, kind: frameKind))
        }
        while true {
            guard coordinators[sessionId]?.attemptId == attemptId else {
                return BotRemoteTurnResult(
                    sessionId: sessionId, turnId: currentTurn, status: "cancelled",
                    text: "", error: "stale turn attempt")
            }
            guard let frame = try await mux.receive() else {
                return BotRemoteTurnResult(sessionId: sessionId, turnId: currentTurn,
                                           status: "failed", text: texts.joined(),
                                           error: "session/follow ended before turn/end")
            }
            if frame["type"]?.stringValue == "error" {
                return BotRemoteTurnResult(sessionId: sessionId, turnId: currentTurn,
                                           status: "failed", text: texts.joined(),
                                           error: frame["error"]?["message"]?.stringValue ?? "session/follow failed")
            }
            guard frame["type"]?.stringValue == "item",
                  frame["streamId"]?.stringValue == "follow" else { continue }
            let value = frame["value"] ?? .null
            if value["type"]?.stringValue == "assistant-stream" {
                if coordinators[sessionId]?.cancelRequested == true { continue }
                if value["frame"]?["type"]?.stringValue == "start" { publish(.streamStart) }
                if let text = value["frame"]?["chunk"]?["text"]?.stringValue,
                   !text.isEmpty, value["frame"]?["chunk"]?["type"]?.stringValue == "text-delta" {
                    if firstDeltaAt == nil {
                        firstDeltaAt = Int64((value["time"]?.numberValue ?? Double(now())).rounded())
                    }
                    if !suppressWrapUp { publish(.textDelta(text)) }
                }
                continue
            }
            guard value["type"]?.stringValue == "event", let event = value["event"],
                  let type = event["type"]?.stringValue,
                  let seq = event["seq"]?.intValue else { continue }
            let data = event["data"] ?? .null
            let eventTurn = data["turn"]?.intValue.map(String.init)
            if let currentTurn, let eventTurn, currentTurn != eventTurn { continue }
            if coordinators[sessionId]?.cancelRequested == true, type != "turn/end" { continue }
            let eventTime = Int64((event["time"]?.numberValue ?? Double(now())).rounded())
            if type == "turn/start" { currentTurn = eventTurn ?? currentTurn }
            if ["turn/start", "step/start", "tool/call", "tool/result", "turn/end"].contains(type)
                || (type == "assistant/message" && !suppressWrapUp) {
                publish(.event(event))
            }
            switch type {
            case "turn/start":
                currentTurn = eventTurn ?? currentTurn
                if let currentTurn { await runtime.updateTurn(sessionId: sessionId, turnId: currentTurn) }
                stepStartedAt = eventTime
                firstDeltaAt = nil
                let unit = currentTurn ?? "unknown"
                _ = await watchdog.startUnit(
                    kind: watchdogKind(kind), id: "\(sessionId):\(unit)",
                    botId: botId, sessionId: sessionId, startedAt: eventTime, at: eventTime)
            case "step/start":
                stepStartedAt = eventTime
                firstDeltaAt = nil
            case "user/message":
                if !hidden {
                    _ = try await appendConversation(
                        type: "conversation.user_message", sessionId: sessionId, seq: seq,
                        data: data, principalKind: kind, time: eventTime, attemptId: attemptId)
                }
            case "assistant/message":
                let text = textBlocks(data["message"]?["content"])
                let usage = data["usage"]
                let duration = max(0, eventTime - (stepStartedAt ?? eventTime))
                let ttft = firstDeltaAt.map { max(0, $0 - (stepStartedAt ?? $0)) }
                let record = BotLLMLedgerRecord(
                    ts: BotLLMLedgerRecord.timestamp(Date(timeIntervalSince1970: Double(eventTime) / 1_000)),
                    botId: botId, sessionId: sessionId,
                    purpose: kind == .chat ? .frontTurn : .workerTurn,
                    model: data["model"]?.stringValue ?? model,
                    provider: data["provider"]?.stringValue ?? providerName,
                    inputTokens: usage?["inputTokens"]?.intValue ?? 0,
                    outputTokens: usage?["outputTokens"]?.intValue ?? 0,
                    cacheReadTokens: usage?["cacheReadTokens"]?.intValue ?? 0,
                    cacheWriteTokens: usage?["cacheWriteTokens"]?.intValue ?? 0,
                    ttftMs: ttft.map(Int.init), durationMs: Int(duration), status: "ok", errorKind: nil)
                _ = try await ledger.append(record)
                _ = await watchdog.observeUsage(
                    kind: watchdogKind(kind), id: "\(sessionId):\(currentTurn ?? "unknown")",
                    tokens: record.inputTokens + record.outputTokens + record.cacheReadTokens + record.cacheWriteTokens,
                    at: eventTime)
                if !text.isEmpty, !suppressWrapUp {
                    resultTexts.append(text)
                    if !hidden {
                        texts.append(text)
                        _ = try await appendConversation(
                            type: "conversation.assistant_message", sessionId: sessionId, seq: seq,
                            data: .object(["text": .string(text), "role": .string("assistant")]),
                            principalKind: kind, time: eventTime, attemptId: attemptId)
                    }
                }
            case "tool/call":
                let callId = data["callId"]?.stringValue ?? ""
                let name = data["name"]?.stringValue ?? ""
                toolNames[callId] = name
                _ = await watchdog.observeToolCall(
                    kind: watchdogKind(kind), id: "\(sessionId):\(currentTurn ?? "unknown")",
                    name: name, callId: callId, at: eventTime)
                _ = try await appendConversation(
                    type: "conversation.tool_call", sessionId: sessionId, seq: seq,
                    data: data, principalKind: kind, time: eventTime, attemptId: attemptId)
            case "tool/result":
                let callId = data["message"]?["toolCallId"]?.stringValue ?? ""
                let name = toolNames[callId] ?? ""
                let failed = data["message"]?["isError"]?.boolValue == true || data["error"] != nil
                if isQuestionTool(name), !failed {
                    suppressWrapUp = true
                    await runtime.suppressText(sessionId: sessionId)
                }
                _ = await watchdog.observeToolResult(
                    kind: watchdogKind(kind), id: "\(sessionId):\(currentTurn ?? "unknown")",
                    name: name, status: failed ? "error" : "ok", callId: callId, at: eventTime)
                _ = try await appendConversation(
                    type: "conversation.tool_result", sessionId: sessionId, seq: seq,
                    data: data, principalKind: kind, time: eventTime, attemptId: attemptId)
            case "turn/end":
                await watchdog.finishUnit(kind: watchdogKind(kind), id: "\(sessionId):\(currentTurn ?? "unknown")")
                let reason = data["reason"]?["kind"]?.stringValue ?? "completed"
                let cancelled = coordinators[sessionId]?.cancelRequested == true
                    || reason == "aborted" || reason == "interrupted"
                let status = cancelled ? "cancelled" : reason == "completed" ? "completed" : "failed"
                return BotRemoteTurnResult(
                    sessionId: sessionId, turnId: currentTurn ?? eventTurn, status: status,
                    text: kind == .chat && hidden ? "" : resultTexts.joined(),
                    error: status == "completed" ? nil : data["reason"]?["error"]?["message"]?.stringValue ?? reason)
            default:
                continue
            }
        }
    }

    private func isQuestionTool(_ name: String) -> Bool {
        ["ask_user", "show_next_steps"].contains { bare in
            name == bare || name.hasSuffix("__\(bare)")
        }
    }

    private func appendConversation(type: String, sessionId: String, seq: Int,
                                    data: BotJSONValue, principalKind: BotSessionKind,
                                    time eventTime: Int64? = nil,
                                    attemptId: String) async throws -> Int {
        guard coordinators[sessionId]?.attemptId == attemptId else { return -1 }
        let principal = try await ensureSession(sessionId: sessionId, kind: principalKind)
        guard coordinators[sessionId]?.attemptId == attemptId else { return -1 }
        return try await runtime.eventWriter.append(
            type: type, principal: principal, data: data,
            eventId: "dsh:\(sessionId):\(seq):\(type)", origin: .dsh(sessionId: sessionId, seq: seq),
            time: eventTime ?? now())
    }

    private func watchdogKind(_ kind: BotSessionKind) -> BotWatchdogUnitKind {
        switch kind {
        case .chat: return .turn
        case .task: return .task
        case .routine: return .routine
        case .team, .proactive, .watchdog: return .turn
        }
    }

    private func textBlocks(_ content: BotJSONValue?) -> String {
        (content?.arrayValue ?? []).compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined()
    }
}

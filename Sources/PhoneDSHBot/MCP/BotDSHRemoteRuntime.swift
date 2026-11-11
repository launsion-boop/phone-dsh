// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

public struct BotRemoteTurnResult: Sendable, Equatable {
    public let sessionId: String
    public let turnId: String?
    public let status: String
    public let text: String
    public let error: String?
    /// Canonical `record://session/<id>#<seq>` references for the user,
    /// assistant, tool-call and tool-result rows this turn observed. A
    /// verifier receives these instead of the doer session's self-report.
    public let recordRefs: [String]
    /// The last non-empty assistant text of the turn. A multi-step verifier
    /// turn emits prose before its tool calls; the contract's final answer is
    /// that last message, not the concatenation of every step.
    public let finalText: String?

    public init(sessionId: String, turnId: String?, status: String, text: String,
                error: String? = nil, recordRefs: [String] = [],
                finalText: String? = nil) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.status = status
        self.text = text
        self.error = error
        self.recordRefs = recordRefs
        self.finalText = finalText
    }
}

/// Handle for one live-frame observer. Multiple independent observers may
/// subscribe to the same Bot; removing one never disturbs the others.
public struct BotLiveFrameSubscription: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
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

public actor BotDSHRemoteRuntime: BotTaskExecuting, BotTaskRestarting, BotTaskAuthorizing {
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
        /// Optional for old persisted rows. A missing value restores the
        /// workspace-only default rather than an unrestricted child.
        var authorization: BotTaskAuthorization?
        /// S3 completion contract. Optional so rows written before S3 restore
        /// as "no completion condition" instead of an unverifiable task.
        var completion: String?
        var purpose: String?
        var constraints: [String]?
        var budget: BotTaskBudget?
        var verification: BotVerification?
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
        var completion: String
        var purpose: String?
        var constraints: [String]
        var budget: BotTaskBudget?
        var authorization: BotTaskAuthorization
        var record: BotTaskRecord
        var generation: Int
        var work: Task<BotTaskRecord, Error>?
        var stopWork: Task<BotTaskRecord, Error>?
        var live: Bool
        var wakeDelivered: Bool
    }

    private struct SessionCredential {
        let token: String
        let principal: BotGatewayPrincipal
        /// The Worker generation that acknowledged the claim. A Worker restart
        /// invalidates the Worker's in-memory token map, so the App must claim
        /// again before the session's next turn.
        var claimGeneration: UInt64
        var claimAcknowledged: Bool
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
    private var sessions: [String: SessionCredential] = [:]
    /// Bumped whenever the Worker is replaced. Every session credential is
    /// re-claimed before its next turn, using its current token when that
    /// incarnation still resolves and a freshly issued one otherwise.
    private var claimGeneration: UInt64 = 0
    private var coordinators: [String: TurnCoordinator] = [:]
    private var queuedTurns: [String: QueuedTurn] = [:]
    private var recentHeldChatActions: [(requestId: String, nonce: String)] = []
    private var taskStates: [String: TaskState] = [:]
    private var interruptedTaskWakes: [String] = []
    private var routineSessions: [String: String] = [:]
    private var maintainerSessionId: String?
    private var mainSessionTask: Task<String, Error>?
    private var liveObservers: [BotLiveFrameSubscription: @Sendable (BotLiveTurnFrame) -> Void] = [:]
    /// The one compatibility observer installed by `setLiveObserver`.
    private var legacyLiveSubscription: BotLiveFrameSubscription?
    private var wakeInFlight = false

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
        await runtime.attachTaskExecutor(self, botID: botId)
        await restorePersistedTasks()
    }

    public func attachTransport(_ newTransport: any DSHRemoteTransport) async {
        transport = newTransport
        // The previous Worker's in-memory session credentials are gone. Keep
        // the host-side tokens (the BotTokenRegistry incarnation is still the
        // current one) but require a fresh issue+claim before the next turn.
        claimGeneration &+= 1
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
        await onUserTurnStarted?()
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
        var promptRequestId = requestId ?? BotTurnOrigin.visibleRequestId()
        if !steer, let wakeInbox {
            let staged = try await wakeInbox.stage(now: now())
            stagedKey = staged.key
            if !staged.items.isEmpty {
                prompt = HeldMessages.block(items: staged.items) + "\n\n" + body
                // Held deliveries derive their id from the item ids, not from
                // the random staged key, so a crash replay after `revert`
                // reuses the same id for the same items.
                promptRequestId = Self.deliveryRequestId(items: staged.items)
                if let nonce = BotTurnOrigin.userActionNonce(from: requestId) {
                    recentHeldChatActions.removeAll { $0.requestId == promptRequestId }
                    recentHeldChatActions.append((promptRequestId, nonce))
                    if recentHeldChatActions.count > 64 { recentHeldChatActions.removeFirst() }
                }
            }
        }
        do {
            let result = try await runTurn(sessionId: sessionId, kind: .chat, prompt: prompt,
                                           requestId: promptRequestId)
            if let stagedKey { _ = try await wakeInbox?.commit(stagedKey) }
            await onUserTurnFinished?()
            return result
        } catch {
            if let stagedKey { _ = try await wakeInbox?.revert(stagedKey) }
            await onUserTurnFinished?()
            throw error
        }
    }

    /// The one delivery seam for another Bot's immediate message. It is not a
    /// user turn: the request id carries the frozen `agent:` origin, pending
    /// held items are not folded into it, and it never steers into a turn of a
    /// different origin.
    public func sendAgentMessage(_ text: String, requestId: String) async throws -> BotRemoteTurnResult {
        guard BotTurnOrigin(rpcId: requestId).kind == .agent else {
            throw BotMCPError.invalidRequest("agent delivery requires an agent: request id")
        }
        let sessionId = try await ensureMainSession()
        return try await runTurn(sessionId: sessionId, kind: .chat, prompt: text,
                                 requestId: requestId, allowSteer: false)
    }

    /// The single runtime seam the app-layer attachment importer uses. It
    /// creates or recovers the durable main chat session before the first
    /// message, so the importer can write through the Worker's workspace
    /// import service without owning any session logic.
    public func ensureMainSessionID() async throws -> String {
        try await ensureMainSession()
    }

    /// Hidden work must carry a hidden `rpcId` prefix; the parameter alone no
    /// longer decides whether the turn is hidden. There is currently no
    /// production caller.
    public func sendHiddenInteraction(_ text: String, requestId: String? = nil) async throws -> BotRemoteTurnResult {
        guard let requestId, BotTurnOrigin(rpcId: requestId).hidden else {
            throw BotMCPError.invalidRequest("hidden interaction requires a hidden request id prefix")
        }
        let sessionId = try await ensureMainSession()
        return try await runTurn(sessionId: sessionId, kind: .chat, prompt: text,
                                 requestId: requestId)
    }

    /// Subscribes one additional observer to live frames of visible main-chat
    /// turns. Every subscription is independent; the returned token removes
    /// only that observer.
    public func subscribeLiveFrames(
        _ observer: @escaping @Sendable (BotLiveTurnFrame) -> Void
    ) -> BotLiveFrameSubscription {
        let subscription = BotLiveFrameSubscription()
        liveObservers[subscription] = observer
        return subscription
    }

    public func unsubscribeLiveFrames(_ subscription: BotLiveFrameSubscription) {
        liveObservers.removeValue(forKey: subscription)
    }

    /// Independent stream view of the same live frames. Each call gets its own
    /// subscription; cancelling the stream removes only that observer.
    public func liveFrames() -> AsyncStream<BotLiveTurnFrame> {
        let subscription = BotLiveFrameSubscription()
        let (stream, continuation) = AsyncStream<BotLiveTurnFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(512))
        liveObservers[subscription] = { frame in continuation.yield(frame) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribeLiveFrames(subscription) }
        }
        return stream
    }

    /// Backward-compatible single observer used by the existing Bot page.
    /// Subscriptions created through `subscribeLiveFrames`/`liveFrames` are
    /// unaffected; pass nil to remove only this compatibility observer.
    public func setLiveObserver(_ observer: (@Sendable (BotLiveTurnFrame) -> Void)?) {
        if let legacyLiveSubscription {
            liveObservers.removeValue(forKey: legacyLiveSubscription)
        }
        legacyLiveSubscription = nil
        guard let observer else { return }
        let subscription = BotLiveFrameSubscription()
        liveObservers[subscription] = observer
        legacyLiveSubscription = subscription
    }

    /// Delivers pending held inbox items by opening a normal visible chat turn
    /// whose prompt starts with the held block. If this Bot already has a
    /// running (or queued) chat turn, nothing is opened and the items stay
    /// pending for the next user turn.
    public func wakeWithHeldMessages() async throws {
        guard let wakeInbox else { return }
        guard !wakeInFlight else { return }
        wakeInFlight = true
        defer { wakeInFlight = false }
        let sessionId = try await ensureMainSession()
        guard coordinators[sessionId] == nil, queuedTurns[sessionId] == nil else { return }
        let pending = try await wakeInbox.items().contains { $0.state == .pending }
        guard pending else { return }
        _ = try await sendUserMessage("")
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
            result: nil, partial: state.record.partial, error: nil,
            completion: state.record.completion, purpose: state.record.purpose,
            constraints: state.record.constraints, budget: state.record.budget,
            verification: state.record.verification)
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
                sessionId: sessionId, kind: .routine, prompt: request.wake.text,
                requestId: BotTurnOrigin.routineRequestId(runId: request.runId))
            let completion = request.routine.completionCriteria
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var verification: BotVerification?
            if result.status == "completed", !completion.isEmpty {
                let constraints = request.routine.constraints
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                verification = await verify(
                    subjectKind: "routine", subjectId: request.routine.id,
                    subjectSessionId: sessionId, title: request.routine.title,
                    status: "succeeded", taskId: nil,
                    routineId: request.routine.id, runId: request.runId,
                    completion: completion, purpose: nil,
                    constraints: constraints.isEmpty ? [] : [constraints],
                    budgetMs: Int(request.timeoutMs), doerRefs: result.recordRefs)
            }
            let baseReply = RoutineWakeBuilder.normalizeReply(result.text)
            var replyText = baseReply.quiet ? "" : baseReply.text
            if let verification, verification.verdict != .passed {
                let label = verification.verdict == .failed ? "验证未通过" : "验证不确定"
                let summary = String(verification.summary
                    .prefix(BotVerificationPolicy.maximumSummaryCharacters))
                replyText = replyText.isEmpty
                    ? "\(label)：\(summary)"
                    : "\(label)：\(summary)\n\(replyText)"
            }
            let reply = RoutineWakeBuilder.normalizeReply(replyText)
            var finishedData: [String: BotJSONValue] = [
                "runId": .string(request.runId), "routineId": .string(request.routine.id),
                "title": .string(request.routine.title), "attempt": .number(Double(request.attempt)),
                "status": .string(result.status), "text": .string(reply.text),
                "quiet": .bool(reply.quiet), "delivery": .string(request.routine.delivery.rawValue),
            ]
            if let verification {
                finishedData["verification"] = verification.jsonValue
            }
            _ = try await runtime.eventWriter.append(
                type: "routine.run_finished", principal: principal,
                data: .object(finishedData), eventId: "finished:\(request.runId)")
            if result.status == "completed" {
                return .success(reply.text, quiet: reply.quiet)
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
        let authorization = try BotTaskAuthorization.resolve(
            requestedDirectories: [], workspaceRoot: botRoot())
        return try await start(request: request, authorization: authorization)
    }

    /// Authorized Task dispatch. The requested subset is resolved against this
    /// Bot's workspace root, narrowed to the parent task's own subset when the
    /// caller is a task, persisted with the durable record and baked into the
    /// child session's principal capabilities before any prompt is sent.
    public func start(request: BotTaskRequest,
                      authorization requested: BotTaskAuthorization) async throws -> BotTaskRecord {
        let authorization = try resolveAuthorization(requested, parent: request.parent)
        let taskId = "task-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let sessionId = try await createSession(
            kind: .task, capabilities: authorization.capabilities)
        let record = BotTaskRecord(
            taskId: taskId, sessionId: sessionId, status: "running", title: request.title,
            result: nil, partial: "", completion: request.completion.isEmpty ? nil : request.completion,
            purpose: request.purpose, constraints: request.constraints, budget: request.budget)
        let state = TaskState(
            ownerBotId: request.parent.principal.botId,
            ownerSessionId: request.parent.sessionId,
            ownerIncarnation: request.parent.principal.incarnation,
            parentKind: request.parent.principal.kind,
            title: request.title, prompt: request.prompt,
            asynchronous: request.asynchronous, timeoutMs: request.timeoutMs,
            completion: request.completion, purpose: request.purpose,
            constraints: request.constraints, budget: request.budget,
            authorization: authorization,
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

    /// The resolved subset stored with one task. Used by `AwaitTask` so the
    /// parent sees the same capabilities it was told at dispatch time.
    public func authorization(taskId: String,
                              parent: BotResolvedToolCall) async throws -> BotTaskAuthorization? {
        guard let state = try ownedTask(taskId: taskId, parent: parent) else {
            throw BotMCPError.invalidRequest("unknown task: \(taskId)")
        }
        return state.authorization
    }

    private func resolveAuthorization(_ requested: BotTaskAuthorization,
                                      parent: BotResolvedToolCall) throws -> BotTaskAuthorization {
        var resolved = try BotTaskAuthorization.resolve(
            requestedDirectories: requested.allowedWriteDirectories,
            workspaceRoot: botRoot(),
            canNetworkWrite: false, canDelegateTasks: false)
        guard parent.principal.kind == .task,
              let parentAuthorization = BotTaskAuthorization.from(
                capabilities: parent.principal.capabilities) else {
            return resolved
        }
        // A task child can only narrow its own write scope; delegation is
        // rejected by BotMCPRuntime before this path can run in this revision.
        let narrowed = resolved.allowedWriteDirectories.filter { directory in
            parentAuthorization.allowedWriteDirectories.contains { allowed in
                directory == allowed || directory.hasPrefix(allowed + "/")
            }
        }
        resolved = try BotTaskAuthorization.resolve(
            requestedDirectories: narrowed.isEmpty
                ? parentAuthorization.allowedWriteDirectories : narrowed,
            workspaceRoot: resolved.workspaceRoot,
            canNetworkWrite: parentAuthorization.canNetworkWrite,
            canDelegateTasks: false)
        return resolved
    }

    /// The doer sees the same terminal contract the verifier will check. The
    /// verifier never receives the doer's later self-report.
    static func taskContractPrompt(completion: String, purpose: String?,
                                   constraints: [String], budgetMs: Int) -> String {
        var lines = ["<task_contract>"]
        lines.append("budget_ms: \(budgetMs)")
        if !completion.isEmpty {
            lines.append("completion:")
            lines.append(HeldMessages.escapedHeldField(completion))
        }
        if let purpose, !purpose.isEmpty {
            lines.append("purpose:")
            lines.append(HeldMessages.escapedHeldField(purpose))
        }
        if !constraints.isEmpty {
            lines.append("constraints:")
            lines.append(contentsOf: constraints.map { "- \(HeldMessages.escapedHeldField($0))" })
        }
        if !completion.isEmpty {
            lines.append("Finish only when the completion condition is true. A separate read-only verifier will re-check the artifacts and raw records; your own summary is not evidence.")
        }
        lines.append("</task_contract>")
        return lines.joined(separator: "\n")
    }

    static func authorizationPrompt(_ authorization: BotTaskAuthorization) -> String {
        let escapedRoot = HeldMessages.escapedHeldField(authorization.workspaceRoot)
        let directories = authorization.allowedWriteDirectories
            .map(HeldMessages.escapedHeldField).joined(separator: ", ")
        return """
        <task_authorization>
        workspace_root: \(escapedRoot)
        allowed_write_directories: \(directories)
        write_outside_workspace: \(authorization.canWriteOutsideWorkspace)
        network_write: \(authorization.canNetworkWrite)
        delegate_tasks: \(authorization.canDelegateTasks)
        </task_authorization>
        """
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
            result: nil, partial: state.record.partial, error: nil,
            completion: state.record.completion, purpose: state.record.purpose,
            constraints: state.record.constraints, budget: state.record.budget,
            verification: state.record.verification)
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
            result: nil, partial: state.record.partial, error: nil,
            completion: state.record.completion, purpose: state.record.purpose,
            constraints: state.record.constraints, budget: state.record.budget,
            verification: state.record.verification)
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
            let prompt = Self.authorizationPrompt(state.authorization)
                + "\n\n" + Self.taskContractPrompt(
                    completion: state.completion, purpose: state.purpose,
                    constraints: state.constraints,
                    budgetMs: state.budget?.maxDurationMs ?? state.timeoutMs)
                + "\n\n" + state.prompt
            let turn = try await runTurn(
                sessionId: state.record.sessionId, kind: .task,
                prompt: prompt, requestId: BotTurnOrigin.taskTurnRequestId(taskId: taskId))
            guard let current = taskStates[taskId], current.generation == generation,
                  current.record.status == "running" else {
                return taskStates[taskId]?.record ?? state.record
            }
            let completed = turn.status == "completed"
            var verification: BotVerification?
            // P26 §2.8: every async Task with a completion condition is
            // verified once on completion, regardless of which session
            // delegated it. Only the parent wake below stays chat-specific.
            if completed, !state.completion.isEmpty, state.asynchronous {
                verification = await verify(
                    subjectKind: "task", subjectId: taskId,
                    subjectSessionId: state.record.sessionId,
                    title: state.title, status: "completed",
                    taskId: taskId, routineId: nil, runId: nil,
                    completion: state.completion, purpose: state.purpose,
                    constraints: state.constraints,
                    budgetMs: (state.budget?.maxDurationMs ?? state.timeoutMs),
                    doerRefs: turn.recordRefs)
            }
            let record = BotTaskRecord(
                taskId: taskId, sessionId: state.record.sessionId,
                status: completed ? "completed" : "failed", title: state.record.title,
                result: completed ? turn.text : nil,
                partial: turn.text, error: completed ? nil : turn.error ?? "task turn failed",
                completion: state.record.completion, purpose: state.record.purpose,
                constraints: state.record.constraints, budget: state.record.budget,
                verification: verification)
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
                let title = HeldMessages.escapedHeldField(state.title)
                let status = HeldMessages.escapedHeldField(record.status)
                let escapedTaskID = HeldMessages.escapedHeldField(taskId)
                let body: String
                if let verification {
                    body = Self.verificationWakeBody(
                        verification, title: state.title, status: record.status,
                        taskID: taskId)
                } else {
                    let excerpt = HeldMessages.escapedHeldField(String(turn.text.prefix(1_200)))
                    body = "\(title) | \(status) | \(escapedTaskID)\n\(excerpt)"
                }
                let prompt = "[SAND_HIDDEN_PROMPT][subagent]\n\(body)"
                _ = try await runTurn(
                    sessionId: state.ownerSessionId, kind: .chat, prompt: prompt,
                    requestId: BotTurnOrigin.taskSettledRequestId(taskId: taskId))
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
                result: nil, partial: nil, error: String(describing: error),
                completion: state.record.completion, purpose: state.record.purpose,
                constraints: state.record.constraints, budget: state.record.budget,
                verification: state.record.verification)
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
        // The replaced Worker lost every in-memory session credential. Keep the
        // host-side issue/principal pair and re-claim it before the next turn.
        claimGeneration &+= 1
        let live = taskStates.filter { $0.value.live }
        for (taskId, state) in live {
            state.work?.cancel()
            state.stopWork?.cancel()
            let record = BotTaskRecord(
                taskId: state.record.taskId, sessionId: state.record.sessionId,
                status: "interrupted", title: state.record.title,
                result: nil, partial: state.record.partial, error: "worker_restarted",
                completion: state.record.completion, purpose: state.record.purpose,
                constraints: state.record.constraints, budget: state.record.budget,
                verification: state.record.verification)
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
            let title = HeldMessages.escapedHeldField(state.title)
            let escapedTaskID = HeldMessages.escapedHeldField(taskId)
            let prompt = "[SAND_HIDDEN_PROMPT][subagent]\n"
                + "\(title) | interrupted | \(escapedTaskID)\n"
                + "The Worker restarted and interrupted this task; its result is incomplete."
            do {
                let result = try await runTurn(
                    sessionId: state.ownerSessionId, kind: .chat, prompt: prompt,
                    requestId: BotTurnOrigin.taskInterruptedRequestId(taskId: taskId))
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

    // MARK: - Independent verification (P26 §2.8)

    /// Run one read-only verifier session and record its conclusion. Every
    /// failure path becomes `uncertain`; the model can never self-certify a
    /// passed verdict through a malformed response or an invented reference.
    private func verify(subjectKind: String, subjectId: String, subjectSessionId: String,
                        title: String, status: String, taskId: String?,
                        routineId: String?, runId: String?,
                        completion: String, purpose: String?, constraints: [String],
                        budgetMs: Int, doerRefs: [String]) async -> BotVerification {
        let startedAt = now()
        let verificationId = "verification-\(UUID().uuidString.lowercased())"
        let budgetLimit = BotVerificationPolicy.verifierLimitMs(subjectBudgetMs: budgetMs)
        let verifierSession: String
        do {
            verifierSession = try await createSession(kind: .verifier)
        } catch {
            return BotVerification(
                verdict: .uncertain,
                summary: "the verifier session could not be created",
                refs: [], unverified: ["Verifier session unavailable"],
                budget: BotVerificationPolicy.budget(
                    subjectBudgetMs: budgetMs, usedMs: max(0, Int(now() - startedAt))),
                output: "unavailable")
        }

        func finish(_ verification: BotVerification) async -> BotVerification {
            let used = max(0, Int(now() - startedAt))
            var result = verification
            if result.budget.usedMs != used || result.budget.exceeded {
                result.budget = BotVerificationBudget(
                    limitMs: budgetLimit, usedMs: max(used, result.budget.usedMs),
                    exceeded: result.budget.exceeded || used > budgetLimit)
                if result.budget.exceeded, result.verdict == .passed {
                    result.verdict = .uncertain
                    result.output = "budget_exceeded"
                    result.summary = "the verifier budget was exceeded before the evidence was complete"
                    if result.unverified.isEmpty {
                        result.unverified = ["Verification budget exceeded"]
                    }
                }
            }
            var data: [String: BotJSONValue] = [
                "verificationId": .string(verificationId),
                "subjectKind": .string(subjectKind),
                "subjectId": .string(subjectId),
                "subjectSessionId": .string(subjectSessionId),
                "title": .string(String(title.prefix(BotVerificationPolicy.maximumSubjectTitleCharacters))),
                "status": .string(status),
                "verification": result.jsonValue,
                "createdAt": .number(Double(now())),
            ]
            if let taskId { data["task_id"] = .string(taskId) }
            if let routineId { data["routine_id"] = .string(routineId) }
            if let runId { data["runId"] = .string(runId) }
            if let principal = try? await ensureSession(sessionId: verifierSession, kind: .verifier) {
                _ = try? await runtime.eventWriter.append(
                    type: "verification.reported", principal: principal,
                    data: .object(data),
                    eventId: "verification:\(verificationId)")
            }
            return result
        }

        let emptyBudget = BotVerificationPolicy.budget(
            subjectBudgetMs: budgetMs, usedMs: max(0, Int(now() - startedAt)))
        // Session-log refs can briefly lag materialization. Durable events for
        // the doer session are already committed by the time it settled, so
        // include them as additional record:// evidence for the verifier.
        var refs = doerRefs
        if let stored = try? await runtime.store.events(after: 0, limit: 1_000) {
            let eventRefs = stored.compactMap { event -> String? in
                guard event.principal.sessionId == subjectSessionId,
                      let seq = event.commitSeq else { return nil }
                return "record://event/\(seq)"
            }.suffix(4)
            refs.append(contentsOf: eventRefs)
        }
        refs = Array(refs.suffix(12))
        guard !refs.isEmpty else {
            return await finish(BotVerification(
                verdict: .uncertain,
                summary: "the doer turn produced no readable record references",
                refs: [], unverified: ["No doer record references were available"],
                budget: emptyBudget, output: "unavailable"))
        }
        let prompt = BotVerifierPrompt.build(
            subjectKind: subjectKind, subjectId: subjectId,
            completion: completion, purpose: purpose, constraints: constraints,
            refs: refs, subjectSessionId: subjectSessionId)
        let work = Task {
            try await self.runTurn(
                sessionId: verifierSession, kind: .verifier,
                prompt: prompt,
                requestId: BotTurnOrigin.taskTurnRequestId(taskId: "verifier-\(verificationId)"))
        }
        let completed = await waitForVerifierTurn(work, timeoutMs: budgetLimit)
        guard completed else {
            try? await cancelTurn(sessionId: verifierSession, includeQueued: true)
            work.cancel()
            return await finish(BotVerification(
                verdict: .uncertain,
                summary: "the verifier did not finish within its budget",
                refs: [], unverified: ["Verification timed out"],
                budget: BotVerificationBudget(
                    limitMs: budgetLimit, usedMs: budgetLimit, exceeded: true),
                output: "budget_exceeded"))
        }
        let turn: BotRemoteTurnResult
        do {
            turn = try await work.value
        } catch {
            return await finish(BotVerification(
                verdict: .uncertain,
                summary: "the verifier turn failed: \(String(describing: error))",
                refs: [], unverified: ["Verifier turn failed"],
                budget: emptyBudget, output: "unavailable"))
        }
        let used = max(0, Int(now() - startedAt))
        let budget = BotVerificationPolicy.budget(subjectBudgetMs: budgetMs, usedMs: used)
        if budget.exceeded {
            return await finish(BotVerification(
                verdict: .uncertain,
                summary: "the verifier exceeded its 30% budget",
                refs: [], unverified: ["Verification budget exceeded"],
                budget: budget, output: "budget_exceeded"))
        }
        guard turn.status == "completed" else {
            return await finish(BotVerification(
                verdict: .uncertain,
                summary: turn.error ?? "the verifier turn did not complete",
                refs: [], unverified: ["Verifier turn did not complete"],
                budget: budget, output: "unavailable"))
        }
        let output: BotVerifierOutput
        do {
            output = try BotVerifierOutputParser.parse(turn.finalText ?? turn.text)
        } catch {
            return await finish(BotVerification(
                verdict: .uncertain,
                summary: "the verifier output was not the required JSON object: \(String(describing: error))",
                refs: [], unverified: ["Verifier output format invalid"],
                budget: budget, output: "invalid"))
        }
        guard let resolver = runtime.recordEvidence else {
            return await finish(BotVerification(
                verdict: .uncertain, summary: output.summary,
                refs: output.refs, unverified: output.unverified,
                budget: budget, output: "unavailable"))
        }
        do {
            _ = try await resolver.resolveEvidence(
                output.refs, callerBotID: botId, callerSessionID: verifierSession)
        } catch BotRecordServiceError.erasedRecord {
            // S6: a cited record erased after the doer settled is not a passed
            // verification and not a host failure. Keep the explicit
            // `record_erased` code in the evidence text; the verdict is
            // uncertain, never passed.
            return await finish(BotVerification(
                verdict: .uncertain,
                summary: "the verifier cited a record that has been erased",
                refs: [],
                unverified: output.unverified + ["record_erased: a cited record:// reference was physically erased"],
                budget: budget, output: "invalid"))
        } catch {
            return await finish(BotVerification(
                verdict: .uncertain,
                summary: "the verifier cited a record it could not resolve",
                refs: [],
                unverified: output.unverified + ["Cited record references were invalid or out of scope: \(String(describing: error))"],
                budget: budget, output: "invalid"))
        }
        return await finish(BotVerification(
            verdict: output.verdict, summary: output.summary,
            refs: output.refs, unverified: output.unverified,
            budget: budget, output: "valid"))
    }

    private func waitForVerifierTurn(_ work: Task<BotRemoteTurnResult, Error>,
                                     timeoutMs: Int) async -> Bool {
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

    /// The parent wake carries the verifier's evidence, never the child's own
    /// summary. Failed/uncertain conclusions carry an explicit instruction to
    /// tell the user honestly.
    static func verificationWakeBody(_ verification: BotVerification,
                                     title: String, status: String,
                                     taskID: String) -> String {
        let escapedTitle = HeldMessages.escapedHeldField(title)
        let escapedTaskID = HeldMessages.escapedHeldField(taskID)
        let escapedStatus = HeldMessages.escapedHeldField(status)
        let escapedSummary = HeldMessages.escapedHeldField(
            String(verification.summary.prefix(BotVerificationPolicy.maximumSummaryCharacters)))
        let refs = verification.refs.joined(separator: " ")
        let unverified = verification.unverified.isEmpty
            ? "none"
            : verification.unverified.map(HeldMessages.escapedHeldField).joined(separator: "; ")
        var lines = [
            "\(escapedTitle) | \(escapedStatus) | \(escapedTaskID)",
            "[verification] \(verification.verdict.rawValue)",
            "summary: \(escapedSummary)",
            "refs: \(refs)",
            "unverified: \(unverified)",
            "budget: used=\(verification.budget.usedMs)ms limit=\(verification.budget.limitMs)ms exceeded=\(verification.budget.exceeded)",
        ]
        if verification.verdict != .passed {
            lines.append("[verification_instruction] This is the independent verifier's conclusion; the doer's own final message is not evidence. Tell the user honestly that the task did not pass or could not be verified and why, with the record references. Do not present it as done. Use SendToUser if you need to deliver that message from this hidden wake.")
        } else {
            lines.append("[verification_instruction] This is the independent verifier's conclusion; the doer's own final message is not evidence. The task passed. No message is required.")
        }
        return lines.joined(separator: "\n")
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
            error: state.record.error, createdAt: now(), wakeDelivered: state.wakeDelivered,
            authorization: state.authorization,
            completion: state.completion.isEmpty ? nil : state.completion,
            purpose: state.purpose, constraints: state.constraints,
            budget: state.budget, verification: state.record.verification)
        let principal = sessions[state.ownerSessionId]?.principal ?? BotGatewayPrincipal(
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
                if let snapshot = Self.decodePersistedTask(event),
                   snapshot.parentBotId == botId {
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
                        error: record["error"]?.stringValue,
                        completion: record["completion"]?.stringValue,
                        purpose: record["purpose"]?.stringValue,
                        constraints: record["constraints"]?.arrayValue?
                            .compactMap(\.stringValue) ?? [],
                        budget: Self.decodeTaskBudget(record["budget"]),
                        verification: Self.decodeVerification(record["verification"]))
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
                partial: snapshot.partial, error: snapshot.error,
                completion: snapshot.completion, purpose: snapshot.purpose,
                constraints: snapshot.constraints ?? [], budget: snapshot.budget,
                verification: snapshot.verification)
            if let terminal = settled[taskId] {
                // The terminal event is authoritative for the lifecycle status,
                // but an older binary may not have written the S3 fields. Keep
                // the persisted snapshot's completion contract and verification
                // rather than dropping them on restart.
                record = BotTaskRecord(
                    taskId: terminal.taskId, sessionId: terminal.sessionId,
                    status: terminal.status, title: terminal.title,
                    result: terminal.result, partial: terminal.partial,
                    error: terminal.error,
                    completion: terminal.completion ?? snapshot.completion,
                    purpose: terminal.purpose ?? snapshot.purpose,
                    constraints: terminal.constraints.isEmpty
                        ? (snapshot.constraints ?? []) : terminal.constraints,
                    budget: terminal.budget ?? snapshot.budget,
                    verification: terminal.verification ?? snapshot.verification)
                snapshot.status = record.status
                snapshot.result = record.result
                snapshot.partial = record.partial
                snapshot.error = record.error
            }
            let interrupted = record.status == "running" || record.status == "stopping"
            if interrupted {
                record = BotTaskRecord(
                    taskId: taskId, sessionId: snapshot.sessionId, status: "interrupted",
                    title: snapshot.title, result: nil, partial: record.partial,
                    error: "worker_restarted", completion: snapshot.completion,
                    purpose: snapshot.purpose, constraints: snapshot.constraints ?? [],
                    budget: snapshot.budget, verification: snapshot.verification)
                snapshot.status = "interrupted"
                snapshot.error = "worker_restarted"
            }
            let kind = BotSessionKind(rawValue: snapshot.parentKind) ?? .chat
            taskStates[taskId] = TaskState(
                ownerBotId: snapshot.parentBotId, ownerSessionId: snapshot.parentSessionId,
                ownerIncarnation: snapshot.parentIncarnation, parentKind: kind,
                title: snapshot.title, prompt: snapshot.prompt,
                asynchronous: snapshot.asynchronous, timeoutMs: snapshot.timeoutMs,
                completion: snapshot.completion ?? "", purpose: snapshot.purpose,
                constraints: snapshot.constraints ?? [], budget: snapshot.budget,
                authorization: snapshot.authorization ?? (try? BotTaskAuthorization.resolve(
                    requestedDirectories: [], workspaceRoot: botRoot()))
                    ?? BotTaskAuthorization(
                        workspaceRoot: botRoot(), allowedWriteDirectories: [botRoot()],
                        canWriteOutsideWorkspace: false, canNetworkWrite: false,
                        canDelegateTasks: false),
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

    private static func decodeTaskBudget(_ value: BotJSONValue?) -> BotTaskBudget? {
        guard let value, case .object(let fields) = value else { return nil }
        return BotTaskBudget(maxDurationMs: fields["max_duration_ms"]?.intValue)
    }

    private static func decodeVerification(_ value: BotJSONValue?) -> BotVerification? {
        guard let value, let data = try? value.encoded() else { return nil }
        return try? JSONDecoder().decode(BotVerification.self, from: data)
    }

    private static func deliveryRequestId(items: [WakeInboxItem]) -> String {
        let digest = (try? BotArgumentsDigest.string(for: .array(items.map { .string($0.id) })))
            ?? items.map(\.id).joined(separator: ",")
        return BotTurnOrigin.heldRequestId(digest: digest)
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

    /// Installed by the maintenance controller. Called before a visible/user
    /// main-chat turn starts so a running maintenance batch yields immediately;
    /// committed memory writes stay.
    private var onUserTurnStarted: (@Sendable () async -> Void)?
    /// Called after a user main-chat turn finishes so the controller can wait
    /// for quiet before starting an eligible batch.
    private var onUserTurnFinished: (@Sendable () async -> Void)?

    /// Installs the maintenance yield hooks. Mutating actor state from the
    /// composition root goes through this method instead of the properties.
    public func setUserTurnObservers(
        started: (@Sendable () async -> Void)?,
        finished: (@Sendable () async -> Void)?
    ) {
        onUserTurnStarted = started
        onUserTurnFinished = finished
    }

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
                let principal = try await issueAndClaimSession(recovered.sessionId, kind: .chat)
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

    /// Every Bot session must have its preset composed at `session/create`
    /// time: the session controller resolves and mounts it before announcing
    /// `agent/created`, so a later `agentPresets.select` is already locked and
    /// an immutable creation header is the single authority for the tool
    /// surface.
    ///
    /// - `phone-bot` is the ordinary Bot surface (main chat, Task, routine and
    ///   the other Bot turn kinds). It is the only surface the phone persona
    ///   teaches: no raw subagent/fork, no second schedule authority, no
    ///   workspace skill catalog, no native ask-user, plan mode, present or
    ///   workflow.
    /// - `pdsh-verifier` and `phone-bot-maintainer` are the restricted kinds.
    ///
    /// `createSession` always sends the header and fails closed when the Worker
    /// reports a different composition, so a Bot turn never runs on a wider
    /// surface than its contract.
    public static let phoneBotAgentPreset = "phone-bot"
    public static let verifierAgentPreset = "pdsh-verifier"
    public static let maintainerAgentPreset = "phone-bot-maintainer"

    private static func requestedPreset(for kind: BotSessionKind) -> String {
        switch kind {
        case .verifier: return verifierAgentPreset
        case .maintainer: return maintainerAgentPreset
        case .chat, .task, .routine, .team, .proactive, .watchdog: return phoneBotAgentPreset
        }
    }

    private func createSession(kind: BotSessionKind, sessionID: String? = nil,
                               capabilities: [String] = []) async throws -> String {
        var fields: [String: BotJSONValue] = ["cwd": .string(botRoot())]
        fields["sessionId"] = .string(sessionID ?? mintedSessionID(kind: kind))
        let expectedPreset = Self.requestedPreset(for: kind)
        fields["agentPreset"] = .string(expectedPreset)
        let request: BotJSONValue = .object(fields)
        let created = try await transport.call("session/create", args: .object(["request": request]))
        guard let sessionId = created["sessionId"]?.stringValue, !sessionId.isEmpty else {
            throw BotMCPError.unavailable("session/create returned no sessionId")
        }
        // The returned composition is part of the contract: a Worker that
        // mounted a different preset (or did not report one) must not run the
        // Bot turn on the wrong tool surface.
        guard let composed = created["agentPreset"]?.stringValue else {
            throw BotMCPError.unavailable(
                "session/create did not report its composed agent preset " +
                "(expected \(expectedPreset) for \(kind.rawValue)); refusing to run the Bot turn")
        }
        guard composed == expectedPreset else {
            throw BotMCPError.unavailable(
                "Bot \(kind.rawValue) session composed preset \(composed) instead of " +
                "\(expectedPreset); refusing to run the Bot turn")
        }
        _ = try await issueAndClaimSession(sessionId, kind: kind, capabilities: capabilities)
        return sessionId
    }

    /// New Bot sessions carry the reserved `gb-` namespace even before the
    /// claim RPC lands; legacy/recovered ids are claimed explicitly. Both feed
    /// the Worker-local owned-session registry that gates identity/approval.
    private func mintedSessionID(kind: BotSessionKind) -> String {
        if kind == .chat { return "gb-\(BotWorkspaceLayout.safePathComponent(botId))" }
        return "gb-\(kind.rawValue)-\(UUID().uuidString.lowercased())"
    }

    /// One host-issued maintainer session per Bot runtime. The session is
    /// hidden, memory-only and claimed like every other Bot session; a Worker
    /// restart drops the credential and `ensureSession` reclaims it.
    public func ensureMaintenanceSession() async throws -> String {
        if let existing = maintainerSessionId {
            if await validateRemoteSession(existing) {
                _ = try await ensureSession(sessionId: existing, kind: .maintainer)
                return existing
            }
            maintainerSessionId = nil
        }
        let sessionId = try await createSession(kind: .maintainer)
        maintainerSessionId = sessionId
        return sessionId
    }

    /// Runs one maintenance batch in the hidden maintainer session. The
    /// controller owns candidate selection, the prompt, budgets and the
    /// post-run checks; the runtime only provides the isolated turn.
    public func runMaintenanceTurn(prompt: String, batchID: String) async throws -> BotRemoteTurnResult {
        let sessionId = try await ensureMaintenanceSession()
        await runtime.beginMaintenanceTurn(sessionId: sessionId, batchID: batchID)
        do {
            let result = try await startCoordinatedTurn(
                sessionId: sessionId, kind: .maintainer, prompt: prompt,
                hidden: true, held: false,
                attemptId: UUID().uuidString.lowercased(),
                requestId: "maintenance:\(batchID)",
                origin: BotTurnOrigin(rpcId: nil))
            await runtime.endMaintenanceTurn(sessionId: sessionId)
            return result
        } catch {
            await runtime.endMaintenanceTurn(sessionId: sessionId)
            throw error
        }
    }

    public func maintenanceSessionIdentifier() -> String? { maintainerSessionId }

    /// Cancels the active maintenance turn, if any. Called when the user starts
    /// a main-chat turn; the controller still checks whatever was committed.
    public func cancelMaintenanceTurn() async {
        guard let maintainerSessionId else { return }
        try? await cancelTurn(sessionId: maintainerSessionId, includeQueued: true)
    }

    /// Issues the registry token for a session first, then hands exactly that
    /// token to `phone/botClaimSession`; the reverse order would leave the
    /// Worker without a credential for the first turn. A Worker that predates
    /// the claim method is tolerated only for `gb-` ids, and the missing token
    /// then fails identity registration closed.
    private func issueAndClaimSession(_ sessionId: String, kind: BotSessionKind,
                                      capabilities: [String] = []) async throws -> BotGatewayPrincipal {
        let issued = try await runtime.issueSessionToken(
            botId: botId, sessionId: sessionId, kind: kind, capabilities: capabilities)
        let acknowledged = try await claimOwnedSession(sessionId, sessionToken: issued.token)
        sessions[sessionId] = SessionCredential(
            token: issued.token, principal: issued.principal,
            claimGeneration: claimGeneration, claimAcknowledged: acknowledged)
        return issued.principal
    }

    /// Claims one Bot session for the current Worker generation. Returns
    /// whether the Worker acknowledged the claim; an unacknowledged `gb-` claim
    /// is retried before the next turn rather than treated as authenticated.
    private func claimOwnedSession(_ sessionId: String, sessionToken: String) async throws -> Bool {
        // The App-side registry mirrors every id this runtime creates,
        // recovers or claims so the DSH pages can hide legacy non-`gb-` ids.
        onSessionRegistered?(sessionId)
        var fields: [String: BotJSONValue] = ["sessionId": .string(sessionId)]
        if !sessionToken.isEmpty { fields["sessionToken"] = .string(sessionToken) }
        let response: BotJSONValue
        do {
            response = try await transport.call("phone/botClaimSession", args: .object([
                "request": .object(fields),
            ]))
        } catch {
            if sessionId.hasPrefix("gb-") { return false }
            throw error
        }
        guard response["ok"]?.boolValue == true else {
            // An unacknowledged claim can never make a legacy id safe.
            if sessionId.hasPrefix("gb-") { return false }
            throw BotMCPError.unavailable("Bot session ownership was not acknowledged for \(sessionId)")
        }
        return true
    }

    private func ensureSession(sessionId: String, kind: BotSessionKind) async throws -> BotGatewayPrincipal {
        if let existing = sessions[sessionId] {
            if existing.claimGeneration == claimGeneration, existing.claimAcknowledged {
                return existing.principal
            }
            // A replaced Worker lost its in-memory map but the host may still
            // hold the current incarnation. Re-claim that exact token instead
            // of rotating for availability; a re-sign/rotate/revoke in the
            // meantime no longer resolves and falls through to a fresh issue.
            if let current = await runtime.gateway.tokens.lookup(existing.token),
               current.sessionId == sessionId,
               let live = await runtime.gateway.tokens.lookupSession(sessionId),
               live.incarnation == current.incarnation {
                let acknowledged = try await claimOwnedSession(
                    sessionId, sessionToken: existing.token)
                sessions[sessionId] = SessionCredential(
                    token: existing.token, principal: current,
                    claimGeneration: claimGeneration, claimAcknowledged: acknowledged)
                return current
            }
        } else {
            guard await validateRemoteSession(sessionId) else {
                throw BotMCPError.unavailable("session/page could not resume \(sessionId)")
            }
        }
        // New session or no current incarnation: issue first, then claim.
        // A restored task session derives its subset from the durable task
        // state; starting with an empty capability list would silently tighten
        // every restored task to "no writes".
        let restoredTaskCapabilities = taskStates.values
            .first { $0.record.sessionId == sessionId }?.authorization.capabilities
        return try await issueAndClaimSession(
            sessionId, kind: kind,
            capabilities: sessions[sessionId]?.principal.capabilities
                ?? restoredTaskCapabilities ?? [])
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
                         prompt: String, requestId: String,
                         allowSteer: Bool = true) async throws -> BotRemoteTurnResult {
        _ = try await ensureSession(sessionId: sessionId, kind: kind)
        let origin = BotTurnOrigin(rpcId: requestId)
        let hidden = origin.hidden
        let held = origin.held
        if allowSteer, canSteer(sessionId: sessionId), kind == .chat, !hidden,
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
                    attemptId: attemptId, requestId: requestId, origin: origin)
            }
            queuedTurns[sessionId] = QueuedTurn(attemptId: attemptId, work: work, cancelled: false)
            return try await work.value
        }
        return try await startCoordinatedTurn(
            sessionId: sessionId, kind: kind, prompt: prompt, hidden: hidden, held: held,
            attemptId: UUID().uuidString.lowercased(), requestId: requestId, origin: origin)
    }

    private func startCoordinatedTurn(sessionId: String, kind: BotSessionKind,
                                      prompt: String, hidden: Bool, held: Bool,
                                      attemptId: String, requestId: String,
                                      origin: BotTurnOrigin) async throws -> BotRemoteTurnResult {
        let work = Task { try await self.performCoordinatedTurn(
            sessionId: sessionId, kind: kind, prompt: prompt, hidden: hidden, held: held,
            attemptId: attemptId, requestId: requestId, origin: origin) }
        coordinators[sessionId] = TurnCoordinator(
            sessionId: sessionId, attemptId: attemptId, kind: kind, hidden: hidden,
            work: work, cancelRequested: false, promptAccepted: false)
        return try await work.value
    }

    private func performCoordinatedTurn(sessionId: String, kind: BotSessionKind,
                                        prompt: String, hidden: Bool, held: Bool,
                                        attemptId: String, requestId: String,
                                        origin: BotTurnOrigin) async throws -> BotRemoteTurnResult {
        await runtime.beginTurn(sessionId: sessionId, hidden: hidden, held: held, origin: origin)
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
        var toolFinals: [String: Bool] = [:]
        var recordRefs: [String] = []
        var suppressWrapUp = false
        let live = kind == .chat && !hidden
        func publish(_ frameKind: BotLiveTurnFrame.Kind) {
            guard live else { return }
            publishLiveFrame(BotLiveTurnFrame(
                sessionId: sessionId, turnId: currentTurn, kind: frameKind))
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
            if ["user/message", "assistant/message", "tool/call", "tool/result"].contains(type) {
                let ref = "record://session/\(sessionId)#\(seq)"
                if !recordRefs.contains(ref) { recordRefs.append(ref) }
            }
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
                await runtime.observeUserMessage(
                    sessionId: sessionId, seq: seq, source: data["source"]?.objectValue)
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
                    purpose: kind == .chat
                        ? .frontTurn
                        : (kind == .maintainer ? .memoryMaintenance : .workerTurn),
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
                if isContentCardTool(name), let final = contentCardFinal(in: data["arguments"]) {
                    toolFinals[callId] = final
                }
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
                let finalCard = isContentCardTool(name) && toolFinals[callId] == true
                toolFinals.removeValue(forKey: callId)
                if (isQuestionTool(name) || finalCard), !failed {
                    // `final:true` content cards reuse the ask_user seam. This
                    // only drops the rest of the turn's visible text; it never
                    // cancels the turn or rewrites the tool result.
                    suppressWrapUp = true
                    await runtime.suppressText(sessionId: sessionId)
                }
                _ = await watchdog.observeToolResult(
                    kind: watchdogKind(kind), id: "\(sessionId):\(currentTurn ?? "unknown")",
                    name: name, status: failed ? "error" : "ok", callId: callId, at: eventTime)
                let resultCommitSeq = try await appendConversation(
                    type: "conversation.tool_result", sessionId: sessionId, seq: seq,
                    data: data, principalKind: kind, time: eventTime, attemptId: attemptId)
                if resultCommitSeq > 0,
                   let trace = Self.redactionTrace(in: data),
                   !trace.rules.isEmpty {
                    let record = "record://event/\(resultCommitSeq)"
                    let sessionRecord = "record://session/\(sessionId)#\(seq)"
                    _ = try? await appendConversation(
                        type: "redaction.applied", sessionId: sessionId, seq: seq,
                        data: .object([
                            "sessionId": .string(sessionId),
                            "seq": .number(Double(seq)),
                            "record": .string(record),
                            "sessionRecord": .string(sessionRecord),
                            "rules": .array(trace.rules.map { rule in
                                .object(["rule": .string(rule.name),
                                         "count": .number(Double(rule.count))])
                            }),
                        ]), principalKind: kind, time: eventTime, attemptId: attemptId)
                }
            case "turn/end":
                await watchdog.finishUnit(kind: watchdogKind(kind), id: "\(sessionId):\(currentTurn ?? "unknown")")
                let reason = data["reason"]?["kind"]?.stringValue ?? "completed"
                let cancelled = coordinators[sessionId]?.cancelRequested == true
                    || reason == "aborted" || reason == "interrupted"
                let status = cancelled ? "cancelled" : reason == "completed" ? "completed" : "failed"
                return BotRemoteTurnResult(
                    sessionId: sessionId, turnId: currentTurn ?? eventTurn, status: status,
                    text: kind == .chat && hidden ? "" : resultTexts.joined(),
                    error: status == "completed" ? nil : data["reason"]?["error"]?["message"]?.stringValue ?? reason,
                    recordRefs: recordRefs, finalText: resultTexts.last)
            default:
                continue
            }
        }
    }

    private func publishLiveFrame(_ frame: BotLiveTurnFrame) {
        guard !liveObservers.isEmpty else { return }
        for observer in Array(liveObservers.values) { observer(frame) }
    }

    private func isQuestionTool(_ name: String) -> Bool {
        ["ask_user", "show_next_steps"].contains { bare in
            name == bare || name.hasSuffix("__\(bare)")
        }
    }

    private func isContentCardTool(_ name: String) -> Bool {
        BotToolCatalog.contentCardNames.contains { bare in
            name == bare || name.hasSuffix("__\(bare)")
        }
    }

    /// Reads `final` from the recorded `tool/call` arguments. DSH records the
    /// model's arguments as a JSON string; accepting an object as well keeps
    /// the projection stable for tests and older recordings. A missing,
    /// non-boolean or unparseable value means "not final" here; the host MCP
    /// validation still rejects a non-boolean call before any card is sent.
    private func contentCardFinal(in value: BotJSONValue?) -> Bool? {
        let object: [String: BotJSONValue]?
        if case .object(let fields)? = value {
            object = fields
        } else if let text = value?.stringValue,
                  let parsed = try? BotJSONValue.parse(Data(text.utf8)),
                  case .object(let fields) = parsed {
            object = fields
        } else {
            object = nil
        }
        guard case .bool(let final)? = object?["final"] else { return nil }
        return final
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
        case .verifier, .team, .proactive, .watchdog, .maintainer: return .turn
        }
    }

    private struct RedactionTrace {
        var rules: [(name: String, count: Int)]
    }

    /// Parses the one trace line the Worker appends after redacting a Bot tool
    /// result. The line carries rule names and counts only; the original text
    /// never becomes an event field.
    private static func redactionTrace(in data: BotJSONValue) -> RedactionTrace? {
        let content = data["message"]?["content"]?.arrayValue ?? []
        let text = content.compactMap { block -> String? in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined(separator: "\n")
        let pattern = #"\[pdsh-redaction rules=((?:[a-z0-9-]+:[0-9]+)(?:,[a-z0-9-]+:[0-9]+)*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges == 2 else { return nil }
        let rulesText = (text as NSString).substring(with: match.range(at: 1))
        var rules: [(String, Int)] = []
        for entry in rulesText.split(separator: ",") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let count = Int(parts[1]), count > 0 else { continue }
            rules.append((String(parts[0]), count))
        }
        rules.sort { $0.0 < $1.0 }
        return rules.isEmpty ? nil : RedactionTrace(rules: rules)
    }

    private func textBlocks(_ content: BotJSONValue?) -> String {
        (content?.arrayValue ?? []).compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined()
    }
}

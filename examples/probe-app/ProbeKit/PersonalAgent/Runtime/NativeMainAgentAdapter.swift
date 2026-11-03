// SPDX-License-Identifier: MIT

import Foundation

public protocol MainContextProviding: Sendable {
    func snapshot(for turn: MainTurnInput) async throws -> MainConversationSnapshot
}

public struct MainStaticContextProvider: MainContextProviding {
    private let base: MainConversationSnapshot

    public init(base: MainConversationSnapshot = MainConversationSnapshot(currentText: "")) {
        self.base = base
    }

    public func snapshot(for turn: MainTurnInput) async throws -> MainConversationSnapshot {
        MainConversationSnapshot(currentText: turn.text, mandate: turn.mandate ?? base.mandate,
                                 followUps: base.followUps, pendingQuestions: base.pendingQuestions,
                                 messages: base.messages, rollingSummary: base.rollingSummary,
                                 memory: base.memory, connectorDocuments: base.connectorDocuments,
                                 userConstraints: base.userConstraints,
                                 currentArtifacts: base.currentArtifacts,
                                 pendingReconciliations: base.pendingReconciliations,
                                 responseStylePrompt: base.responseStylePrompt)
    }
}

public struct EmptyConnectorToolInvoker: ConnectorToolInvoker {
    public let descriptors: [ConnectorToolDescriptor] = []

    public init() {}

    public func invoke(_ name: String, argumentsJSON: String,
                       caller: ToolCaller) async -> ToolInvocationResult {
        ToolInvocationResult(toolCallID: "", contentJSON: "{\"error\":\"no_tools\"}", isError: true)
    }
}

public final class NativeMainAgentAdapter: MainAgentPort, @unchecked Sendable {
    private struct PendingTurn {
        let turn: MainTurnInput
        let continuation: AsyncThrowingStream<MainEvent, Error>.Continuation
    }

    private let clientResolver: any MainModelClientResolving
    private let contextProvider: any MainContextProviding
    private let compactor: MainConversationCompactor
    private let toolLoop: NativeToolLoop
    public let latencyRecorder: MainLatencyRecorder

    private let lock = NSLock()
    private var activeTurnID: UUID?
    private var pending: [PendingTurn] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncThrowingStream<MainEvent, Error>.Continuation] = [:]
    private var cancelled: Set<UUID> = []
    private var terminal: Set<UUID> = []

    public init(clientResolver: any MainModelClientResolving,
                toolInvoker: any ConnectorToolInvoker = EmptyConnectorToolInvoker(),
                contextProvider: any MainContextProviding = MainStaticContextProvider(),
                compactor: MainConversationCompactor = MainConversationCompactor(),
                toolConfiguration: NativeToolLoopConfiguration = NativeToolLoopConfiguration(),
                latencyRecorder: MainLatencyRecorder = MainLatencyRecorder()) throws {
        self.clientResolver = clientResolver
        self.contextProvider = contextProvider
        self.compactor = compactor
        self.toolLoop = NativeToolLoop(invoker: toolInvoker,
                                       codec: try ToolNameCodec(descriptors: toolInvoker.descriptors),
                                       configuration: toolConfiguration)
        self.latencyRecorder = latencyRecorder
    }

    public func run(turn: MainTurnInput) -> AsyncThrowingStream<MainEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            continuations[turn.turnID] = continuation
            let queued = PendingTurn(turn: turn, continuation: continuation)
            pending.append(queued)
            let shouldStart = activeTurnID == nil
            if shouldStart {
                activeTurnID = turn.turnID
                pending.removeFirst()
            }
            lock.unlock()

            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.cancelSynchronously(turn.turnID) }
            }
            if shouldStart {
                start(queued)
            } else {
                continuation.yield(.status(StatusLine(text: "已排队，等待上一回合完成", phase: .preparing)))
            }
        }
    }

    public func cancel(turnID: UUID) async {
        cancelSynchronously(turnID)
    }

    private func cancelSynchronously(_ turnID: UUID) {
        lock.lock()
        guard !terminal.contains(turnID) else {
            lock.unlock()
            return
        }
        cancelled.insert(turnID)
        let isActive = activeTurnID == turnID
        let task = tasks[turnID]
        var queuedContinuation: AsyncThrowingStream<MainEvent, Error>.Continuation?
        if !isActive, let index = pending.firstIndex(where: { $0.turn.turnID == turnID }) {
            queuedContinuation = pending.remove(at: index).continuation
            terminal.insert(turnID)
            continuations[turnID] = nil
        }
        lock.unlock()

        if let queuedContinuation {
            queuedContinuation.yield(.failed(.cancelled))
            queuedContinuation.finish()
            return
        }
        if isActive {
            if let continuation = continuation(for: turnID, markTerminal: true) {
                continuation.yield(.failed(.cancelled))
                continuation.finish()
            }
            task?.cancel()
        }
    }

    private func start(_ queued: PendingTurn) {
        let turnID = queued.turn.turnID
        let task = Task { [self] in
            await execute(queued)
        }
        lock.lock()
        tasks[turnID] = task
        let wasCancelled = cancelled.contains(turnID)
        lock.unlock()
        if wasCancelled { task.cancel() }
    }

    private func execute(_ queued: PendingTurn) async {
        let turn = queued.turn
        let tracker = MainTurnLatencyTracker(turnID: turn.turnID)
        var outcome = "failed"
        do {
            try Task.checkCancellation()
            emit(.status(StatusLine(text: "正在准备上下文", phase: .preparing)), for: turn.turnID)
            let resolved = try clientResolver.resolveClient()
            let snapshot = try await contextProvider.snapshot(for: turn)
            let compacted = try await compactor.compact(snapshot)
            let assistant = try await toolLoop.run(client: resolved.client, model: resolved.model,
                                                   maxTokens: resolved.maxTokens,
                                                   context: compacted.context, mandate: turn.mandate,
                                                   telemetry: tracker,
                                                   isCancelled: { [weak self] in
                                                       self?.isCancelled(turn.turnID) ?? true
                                                   }) { [weak self] event in
                self?.emit(event, for: turn.turnID)
            }
            outcome = "completed"
            if let continuation = continuation(for: turn.turnID, markTerminal: true) {
                continuation.yield(.completed(assistant))
            }
        } catch let failure as MainFailure {
            outcome = failure == .cancelled ? "cancelled" : "failed"
            emitFailure(failure, for: turn.turnID)
        } catch is CancellationError {
            outcome = "cancelled"
            emitFailure(.cancelled, for: turn.turnID)
        } catch {
            if Task.isCancelled || isCancelled(turn.turnID) {
                outcome = "cancelled"
                emitFailure(.cancelled, for: turn.turnID)
            } else {
                emitFailure(.provider(MainRuntimeJSON.boundedString(error)), for: turn.turnID)
            }
        }
        await latencyRecorder.record(tracker.sample(outcome: outcome))
        complete(turn.turnID)
    }

    private func isCancelled(_ turnID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(turnID)
    }

    private func emit(_ event: MainEvent, for turnID: UUID) {
        lock.lock()
        let continuation = terminal.contains(turnID) ? nil : continuations[turnID]
        lock.unlock()
        continuation?.yield(event)
    }

    private func emitFailure(_ failure: MainFailure, for turnID: UUID) {
        if let continuation = continuation(for: turnID, markTerminal: true) {
            continuation.yield(.failed(failure))
        }
    }

    private func continuation(for turnID: UUID, markTerminal: Bool)
    -> AsyncThrowingStream<MainEvent, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        if terminal.contains(turnID) { return nil }
        if markTerminal { terminal.insert(turnID) }
        return continuations[turnID]
    }

    private func complete(_ turnID: UUID) {
        lock.lock()
        tasks[turnID] = nil
        continuations[turnID]?.finish()
        continuations[turnID] = nil
        terminal.remove(turnID)
        cancelled.remove(turnID)
        if activeTurnID == turnID { activeTurnID = nil }
        var next: PendingTurn?
        if activeTurnID == nil, !pending.isEmpty {
            next = pending.removeFirst()
            activeTurnID = next?.turn.turnID
        }
        lock.unlock()
        if let next { start(next) }
    }
}

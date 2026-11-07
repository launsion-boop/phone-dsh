// SPDX-License-Identifier: MIT

import Foundation

public actor BotMCPRuntime {
    public static let defaultRuntimeID = "phone-worker"
    /// Expired registrations are swept on this cadence in addition to the
    /// opportunistic prune in `registerIdentity`/`identityForApproval`.
    public static let registrationMaintenanceIntervalMilliseconds: Int64 = 30_000

    public let store: SQLiteDomainStore
    public let gateway: BotGateway
    public let grants: BotGrantStore
    public let authorizer: BotExecutionAuthorizer
    public let eventWriter: BotMCPEventWriter
    public let approvals: BotApprovalCoordinator
    public let volatileContext: BotVolatileContextProducer
    public private(set) var tasks: any BotTaskExecuting
    public let memory: BotMemory
    public let routineMachine: RoutineMachine

    private let now: @Sendable () -> Int64
    private let memorySource: @Sendable (BotResolvedToolCall) -> BotMemorySourceKind
    private var registrations: [String: BotAttribution] = [:]
    private var registrationArguments: [String: BotJSONValue] = [:]
    /// Bumped by `workerRestarted()`. Every registration/claim/approval is
    /// scoped by it, so a call registered by the previous Worker generation
    /// can never be claimed or approved after the restart.
    private var registrationGeneration: UInt64 = 0
    private var suppressingTextSessions: Set<String> = []
    private var hiddenTextSessions: Set<String> = []
    private var heldMessageSessions: Set<String> = []
    private var turnIDs: [String: String] = [:]

    public init(
        store: SQLiteDomainStore,
        gateway: BotGateway? = nil,
        volatileProvider: (any BotVolatileContextProviding)? = nil,
        taskExecutor: (any BotTaskExecuting)? = nil,
        routineStore: (any RoutineStore)? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        memorySource: (@Sendable (BotResolvedToolCall) -> BotMemorySourceKind)? = nil
    ) {
        self.store = store
        self.now = now
        let gateway = gateway ?? BotGateway(now: now)
        self.gateway = gateway
        let audit = BotAuditLog(eventLog: store)
        let grants = BotGrantStore(domainStore: store, now: now, audit: audit)
        self.grants = grants
        authorizer = BotExecutionAuthorizer(grants: grants)
        eventWriter = BotMCPEventWriter(eventLog: store, now: now)
        approvals = BotApprovalCoordinator(grants: grants, eventWriter: eventWriter, now: now)
        volatileContext = BotVolatileContextProducer(provider: volatileProvider ?? EmptyBotVolatileContextProvider())
        tasks = taskExecutor ?? UnimplementedBotTaskExecutor()
        memory = BotMemory(
            store: SQLiteBotMemoryFactStore(eventLog: store, now: now),
            dataRoot: store.fileURL.deletingLastPathComponent().path,
            botID: "main", now: now)
        routineMachine = RoutineMachine(store: routineStore ?? SQLiteRoutineStore(domainStore: store))
        self.memorySource = memorySource ?? { call in
            switch call.principal.kind {
            case .chat: return .userTurn
            case .task: return .task
            case .routine: return .routine
            case .team, .proactive, .watchdog: return .hiddenWake
            }
        }
        let interval = Self.registrationMaintenanceIntervalMilliseconds
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                guard !Task.isCancelled, let self else { return }
                _ = await self.pruneExpiredRegistrations()
            }
        }
    }

    public func attachTaskExecutor(_ executor: any BotTaskExecuting) {
        tasks = executor
    }

    @discardableResult
    public func issueSession(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotGatewayPrincipal {
        try await gateway.issueSession(botId: botId, sessionId: sessionId, kind: kind)
    }

    public func currentTurnID(sessionId: String) -> String? { turnIDs[sessionId] }

    public func beginTurn(sessionId: String, hidden: Bool, held: Bool = false) {
        suppressingTextSessions.remove(sessionId)
        turnIDs.removeValue(forKey: sessionId)
        if hidden { hiddenTextSessions.insert(sessionId) } else { hiddenTextSessions.remove(sessionId) }
        if held { heldMessageSessions.insert(sessionId) } else { heldMessageSessions.remove(sessionId) }
    }

    public func updateTurn(sessionId: String, turnId: String) {
        turnIDs[sessionId] = turnId
    }

    public func endTurn(sessionId: String) {
        hiddenTextSessions.remove(sessionId)
        heldMessageSessions.remove(sessionId)
        turnIDs.removeValue(forKey: sessionId)
    }

    public func suppressText(sessionId: String) {
        suppressingTextSessions.insert(sessionId)
    }

    /// The Worker-visible runtime identifier is the base name; every stored
    /// registration carries the current generation instead. The plugin keeps
    /// sending `phone-worker`, so a Worker restart needs no environment change.
    public func scopedRuntimeID(_ runtimeId: String) -> String {
        "\(runtimeId)@\(registrationGeneration)"
    }

    public func registerIdentity(runtimeId: String, sessionId: String, callId: String,
                                 name: String, arguments: BotJSONValue,
                                 argsDigest: String? = nil) async throws -> BotAttribution {
        _ = pruneExpiredRegistrationsSync()
        let bareName = bareToolName(name)
        guard BotToolCatalog.isRegistered(bareName)
                || ["bash", "write", "edit", "phone"].contains(bareName)
                || BotDeviceToolProvider.tools.contains(bareName) else {
            throw BotMCPError.unknownTool(name)
        }
        let scope = scopedRuntimeID(runtimeId)
        let key = key(scope, sessionId, callId)
        let digest = try (argsDigest ?? BotArgumentsDigest.string(for: arguments))
        if let existing = registrations[key] {
            let principal = await gateway.tokens.lookupSession(sessionId)
            if existing.sessionId == sessionId, existing.name == bareName,
               existing.argsDigest == digest, let principal,
               principal.incarnation == existing.incarnation {
                registrationArguments[key] = arguments
                return existing
            }
        }
        let attribution = try await gateway.registerToolCall(
            sessionId: sessionId, callId: callId, name: bareName,
            arguments: arguments, argsDigest: argsDigest, runtimeId: scope)
        registrations[key] = attribution
        registrationArguments[key] = arguments
        return attribution
    }

    @discardableResult
    public func cancelIdentity(id: String) async -> Bool {
        guard let match = registrations.first(where: { $0.value.id == id }) else { return false }
        registrations.removeValue(forKey: match.key)
        registrationArguments.removeValue(forKey: match.key)
        return await gateway.cancelToolCall(id: id)
    }

    /// Called before issuing an approval card. An expired registration and one
    /// from a previous Worker generation are both treated as unattributed.
    /// `sessionId` narrows the lookup when the same model call id exists in
    /// independent sessions.
    public func identityForApproval(runtimeId: String, sessionId: String? = nil,
                                    callId: String) async -> BotResolvedToolCall? {
        _ = pruneExpiredRegistrationsSync()
        let scope = scopedRuntimeID(runtimeId)
        let matches = registrations.filter { key, attribution in
            key.hasPrefix("\(scope)\u{0}") && attribution.callId == callId
                && (sessionId == nil || attribution.sessionId == sessionId)
                && attribution.expiresAt > now()
        }
        guard matches.count == 1, let attribution = matches.first?.value else { return nil }
        guard let principal = await gateway.tokens.lookupSession(attribution.sessionId),
              principal.incarnation == attribution.incarnation else { return nil }
        return BotResolvedToolCall(
            sessionId: attribution.sessionId, callId: attribution.callId,
            agentId: principal.botId, principal: principal, attribution: attribution)
    }

    /// Cancels every pending card, invalidates every registration and rotates
    /// the runtime generation. The composition calls this whenever the Host
    /// rebuilt or recovered the Worker; old registrations can never be claimed
    /// after it returns.
    @discardableResult
    public func workerRestarted() async -> Int {
        let previous = scopedRuntimeID(Self.defaultRuntimeID)
        let previousRegistrations = registrations
        registrationGeneration &+= 1
        registrations.removeAll()
        registrationArguments.removeAll()
        for attribution in previousRegistrations.values {
            _ = await gateway.cancelToolCall(id: attribution.id)
        }
        _ = await gateway.cancelToolCalls(runtimeId: previous)
        let cancelled = await approvals.cancelAll(reason: "worker_restarted")
        if let restarting = tasks as? any BotTaskRestarting {
            await restarting.workerRestarted()
        }
        return cancelled
    }

    /// Removes registrations past their expiry and revokes their pending
    /// attributions. Public so a test and the maintenance task can force it.
    @discardableResult
    public func pruneExpiredRegistrations() async -> Int {
        let expired = pruneExpiredRegistrationsSync()
        for attribution in expired {
            _ = await gateway.cancelToolCall(id: attribution.id)
        }
        _ = await gateway.attribution.prune()
        return expired.count
    }

    private func pruneExpiredRegistrationsSync() -> [BotAttribution] {
        let timestamp = now()
        let expired = registrations.filter { $0.value.expiresAt <= timestamp }
        guard !expired.isEmpty else { return [] }
        for (key, _) in expired {
            registrations.removeValue(forKey: key)
            registrationArguments.removeValue(forKey: key)
        }
        return expired.map(\.value)
    }

    public func approve(runtimeId: String, sessionId: String? = nil, callId: String, name: String,
                        action: String, detail: String, command: String,
                        argsDigest: String, alwaysScope: String, askAction: String,
                        suppliedEffects: [BotToolEffect]? = nil) async -> BotApprovalOutcome {
        let scope = scopedRuntimeID(runtimeId)
        guard let call = await identityForApproval(runtimeId: runtimeId, sessionId: sessionId, callId: callId),
              bareToolName(call.attribution.name) == bareToolName(name),
              let arguments = registrationArguments[key(scope, call.sessionId, callId)] else {
            return BotApprovalOutcome(ok: false, allowed: false, message: "unattributed")
        }
        guard let suppliedDigest = try? BotArgumentsDigest.validated(argsDigest),
              suppliedDigest == call.attribution.argsDigest,
              let registeredDigest = try? BotArgumentsDigest.string(for: arguments),
              registeredDigest == suppliedDigest else {
            return BotApprovalOutcome(ok: false, allowed: false, message: "stale:digest_mismatch")
        }
        let bareName = bareToolName(name)
        if bareName == "bash", arguments["command"]?.stringValue != command {
            return BotApprovalOutcome(ok: false, allowed: false, message: "stale:command_mismatch")
        }
        let effects: [BotToolEffect]
        if askAction == "sandbox-escalation" {
            guard bareName == "bash", alwaysScope == "none",
                  let suppliedEffects, suppliedEffects.count == 1,
                  suppliedEffects[0].operation == "sandbox-escalation",
                  !BotResourceNormalizer.normalize(suppliedEffects[0].resource).isEmpty else {
                return BotApprovalOutcome(ok: false, allowed: false, message: "stale:sandbox_effect")
            }
            effects = [BotToolEffect(
                tool: "bash", operation: "sandbox-escalation",
                resource: suppliedEffects[0].resource, target: suppliedEffects[0].target,
                mutability: .write, policy: .ask, label: action, detail: detail)]
        } else {
            effects = await effectsForApproval(
                name: bareName, botID: call.principal.botId,
                arguments: bareName == "bash" ? .object(["command": .string(command)]) : arguments)
        }
        guard ["until", "session", "none"].contains(alwaysScope) else {
            return BotApprovalOutcome(ok: false, allowed: false, message: "stale:always_scope")
        }
        let expectedScope = !effects.isEmpty && effects.allSatisfy { !$0.known } ? "session" : "until"
        guard alwaysScope == expectedScope || alwaysScope == "none" else {
            return BotApprovalOutcome(ok: false, allowed: false, message: "stale:always_scope")
        }
        if effects.isEmpty { return BotApprovalOutcome(ok: true, allowed: true, message: "auto-policy") }
        return await approvals.request(
            call: call, effects: effects, action: action, detail: detail,
            command: command, alwaysScope: alwaysScope)
    }

    public func execute(name: String, arguments: BotJSONValue,
                        context: BotMCPRequestContext) async -> BotMCPCallResult {
        let bareName = bareToolName(name)
        guard BotToolCatalog.isRegistered(bareName) else { return .failure("unknown_tool", "Unknown tool: \(name)") }
        let scope = scopedRuntimeID(context.runtimeId)
        guard let call = await gateway.resolveToolCall(
            runtimeId: scope, name: bareName, arguments: arguments) else {
            return .failure("unattributed", "The tool call could not be attributed to an active session")
        }
        let registrationKey = key(scope, call.sessionId, call.callId)
        registrations.removeValue(forKey: registrationKey)
        registrationArguments.removeValue(forKey: registrationKey)
        do {
            if bareName == BotToolCatalog.volatileContextName {
                let read = BotToolEffect(
                    tool: bareName, operation: "context.volatile", resource: "session=\(call.sessionId)",
                    mutability: .read, policy: .auto, label: "Read current volatile context")
                guard await authorize(call: call, effect: read) == nil else {
                    return .failure("permission_denied", "Volatile context authorization failed")
                }
                let snapshot = try await volatileContext.snapshot(request: arguments, principal: call.principal)
                return .success(snapshot.jsonValue)
            }
            let effect = BotToolEffectClassifier.effect(for: bareName, arguments: arguments)
            var executionEffect = effect
            var replyAuthorization: BotDeviceReplyTool.Authorization?
            if bareName == BotToolCatalog.deviceReplyName {
                // Host extension: the pure classifier knows only the staged
                // `device:*` shape. Resolve the staged source and authorize the
                // concrete device/session effect (tool-effects.json
                // hostExtensions); the model still cannot name a destination.
                _ = try BotDeviceReplyTool.validatedMessage(arguments)
                let source = try await BotDeviceReplyTool.resolveSource(
                    store: store, botID: call.principal.botId)
                if let mainSessionID = source.mainSessionID, call.sessionId != mainSessionID {
                    return .failure("unauthorized",
                                    "ReplyToDevice source session does not match the caller")
                }
                executionEffect = BotDeviceReplyTool.requiredEffect(for: source)
                guard executionEffect.tool == effect.tool,
                      executionEffect.operation == effect.operation else {
                    return .failure("permission_denied", "device-reply-effect-mismatch")
                }
                let decision = await authorizer.authorizeExecution(
                    principal: BotExecutionPrincipal(gateway: call.principal),
                    effects: [executionEffect], source: "app-mcp-execution",
                    argsDigest: call.attribution.argsDigest)
                guard decision.allowed else {
                    return .failure("permission_denied", decision.reason)
                }
                replyAuthorization = BotDeviceReplyTool.Authorization(
                    source: source, decision: decision)
            } else if let reason = await authorize(call: call, effect: executionEffect) {
                return .failure("permission_denied", reason)
            }
            return try await dispatch(name: bareName, arguments: arguments, call: call,
                                      replyAuthorization: replyAuthorization)
        } catch let error as BotMCPError {
            return .failure(Self.code(error), Self.message(error))
        } catch let error as BotCardPayloadError {
            switch error {
            case .invalid(let message): return .failure("invalid_arguments", message)
            }
        } catch {
            return .failure("execution_failed", String(describing: error))
        }
    }

    private func authorize(call: BotResolvedToolCall, effect: BotToolEffect) async -> String? {
        let decision = await authorizer.authorizeExecution(
            principal: BotExecutionPrincipal(gateway: call.principal), effects: [effect],
            source: "app-mcp-execution", argsDigest: call.attribution.argsDigest)
        return decision.allowed ? nil : decision.reason
    }

    private func dispatch(name: String, arguments: BotJSONValue,
                          call: BotResolvedToolCall,
                          replyAuthorization: BotDeviceReplyTool.Authorization? = nil) async throws -> BotMCPCallResult {
        if BotToolCatalog.cardToolNames.contains(name) {
            let built = try BotCardPayloads.build(tool: name, arguments: arguments)
            guard case .object(let result) = built, let card = result["card"] else {
                throw BotMCPError.invalidRequest("card builder returned no card")
            }
            var fields = card.objectValue ?? [:]
            fields["card"] = card
            fields["id"] = .string("card-\(UUID().uuidString.lowercased())")
            fields["tool"] = .string(name)
            fields["callId"] = .string(call.callId)
            _ = try await eventWriter.append(type: "card.presented", principal: call.principal, data: .object(fields))
            if name == "ask_user" || name == "show_next_steps" {
                suppressingTextSessions.insert(call.sessionId)
                let text = name == "ask_user"
                    ? "已显示提问卡；回合应在此结束，等待用户选择。"
                    : "已显示建议下一步卡片；回合应在此结束，等待用户选择。"
                return .success(built, text: text)
            }
            return .success(built)
        }
        switch name {
        case "UpdateMemory": return try await updateMemory(arguments, call: call)
        case "RecallMemory": return try await recallMemory(arguments)
        case "Task": return try await startTask(arguments, call: call)
        case "AwaitTask": return try await awaitTask(arguments, call: call)
        case "StopSubagent": return try await stopTask(arguments, call: call)
        case "UpdateRoutine": return try await updateRoutine(arguments, call: call)
        case "ListRoutines": return .success(try await BotRoutineTool.list(machine: routineMachine, principal: call.principal))
        case "RequestApproval": return try await requestApproval(arguments, call: call)
        case "SendToUser": return try await sendToUser(arguments, call: call)
        case BotToolCatalog.deviceReplyName:
            return .success(try await BotDeviceReplyTool.reply(
                arguments: arguments, call: call, store: store, authorizer: authorizer,
                authorization: replyAuthorization))
        default: throw BotMCPError.unknownTool(name)
        }
    }

    private func updateMemory(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments else { throw BotMCPError.invalidRequest("arguments must be an object") }
        let action = string(args["action"]) ?? "write"
        let scope = BotMemoryScope(rawValue: string(args["scope"]) ?? "agent") ?? .agent
        switch action {
        case "write":
            guard let text = string(args["fact"]), !text.isEmpty else {
                throw BotMCPError.invalidRequest("UpdateMemory write requires fact")
            }
            let tier = BotMemoryTier(rawValue: string(args["tier"]) ?? "log") ?? .log
            let request = BotMemoryWriteRequest(
                text: text, tier: tier, scope: scope, key: string(args["key"]),
                source: BotMemorySource(
                    kind: hiddenTextSessions.contains(call.sessionId)
                        ? .hiddenWake
                        : heldMessageSessions.contains(call.sessionId) ? .agentMessage : memorySource(call),
                    sessionID: call.principal.sessionId, turnID: turnIDs[call.sessionId],
                    role: call.principal.kind.rawValue))
            let result = try await memory.write(
                request, context: BotMemoryWriteContext(source: request.source))
            return .success(.object([
                "ok": .bool(result.ok), "fact_id": result.factID.map(BotJSONValue.string) ?? .null,
                "duplicated": .bool(result.duplicated), "tier": .string(result.tier.rawValue),
                "scope": .string(result.scope.rawValue), "count": .number(Double(result.count ?? 0)),
                "error": result.error.map(BotJSONValue.string) ?? .null,
            ]))
        case "forget":
            let result = try await memory.forget(text: string(args["fact"]), factID: string(args["fact_id"]), scope: scope)
            return .success(.object([
                "ok": .bool(result.ok), "removed": .number(Double(result.removed)),
                "removed_facts": .number(Double(result.removedFacts)),
                "fact_ids": .array(result.factIDs.map(BotJSONValue.string)),
                "count": .number(Double(result.count)), "scope": .string(result.scope.rawValue),
                "error": result.error.map(BotJSONValue.string) ?? .null,
            ]))
        default: throw BotMCPError.invalidRequest("UpdateMemory action must be write or forget")
        }
    }

    private func recallMemory(_ arguments: BotJSONValue) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments else { throw BotMCPError.invalidRequest("arguments must be an object") }
        let limit = try optionalInt(args["limit"]) ?? 40
        guard (1...50).contains(limit) else { throw BotMCPError.invalidRequest("RecallMemory limit must be 1…50") }
        let scope = string(args["scope"]) ?? "all"
        guard ["agent", "user", "all"].contains(scope) else { throw BotMCPError.invalidRequest("invalid memory scope") }
        var hits = try await memory.recall(string(args["query"]) ?? "", limit: limit)
        if scope != "all" { hits = hits.filter { $0.scope.rawValue == scope } }
        return .success(.object([
            "ok": .bool(true), "facts": .array(try hits.map { try encode($0) }), "count": .number(Double(hits.count)),
        ]))
    }

    private func startTask(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard call.principal.kind == .chat || call.principal.kind == .task else {
            throw BotMCPError.invalidRequest("Task can only start from a chat or task session")
        }
        guard case .object(let args) = arguments else { throw BotMCPError.invalidRequest("arguments must be an object") }
        guard args["task_id"] == nil, args["resume"] == nil else {
            throw BotMCPError.invalidRequest("Task resume is not implemented")
        }
        let title = firstNonEmpty(args["task_title"], args["description"]) ?? "Delegated task"
        guard let prompt = firstNonEmpty(args["prompt"], args["task_description"]), !prompt.isEmpty else {
            throw BotMCPError.invalidRequest("Task requires prompt or task_description")
        }
        let timeout = try optionalInt(args["timeout_ms"]) ?? 180_000
        guard (1_000...300_000).contains(timeout) else { throw BotMCPError.invalidRequest("Task timeout_ms must be 1000…300000") }
        let request = BotTaskRequest(
            parent: call, title: title, prompt: prompt,
            asynchronous: bool(args["async"]) ?? false, timeoutMs: timeout)
        let record = try await tasks.start(request: request)
        // The production task executor persists `task.created` itself, before
        // it starts any work (BotDSHRemoteRuntime.start). Writing a second
        // event here would either race the durable snapshot or leave a crash
        // window with a running task that has no record.
        let taskPrincipal = BotGatewayPrincipal(
            botId: call.principal.botId, sessionId: record.sessionId, kind: .task,
            capabilities: call.principal.capabilities, expiresAt: call.principal.expiresAt)
        _ = try await eventWriter.append(type: "task.started", principal: taskPrincipal, data: record.jsonValue)
        if ["completed", "failed", "stopped"].contains(record.status) {
            _ = try await eventWriter.append(
                type: "task.settled", principal: taskPrincipal, data: record.jsonValue,
                eventId: "settled:\(record.taskId)")
        }
        return .success(record.jsonValue)
    }

    private func awaitTask(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments, let id = string(args["task_id"]), !id.isEmpty else {
            throw BotMCPError.invalidRequest("AwaitTask requires task_id")
        }
        let timeout = try optionalInt(args["timeout_ms"]) ?? 180_000
        guard (1_000...600_000).contains(timeout) else { throw BotMCPError.invalidRequest("AwaitTask timeout_ms must be 1000…600000") }
        let record = try await tasks.await(taskId: id, timeoutMs: timeout, parent: call)
        if ["completed", "failed", "stopped"].contains(record.status) {
            let principal = BotGatewayPrincipal(
                botId: call.principal.botId, sessionId: record.sessionId, kind: .task, expiresAt: Int64.max)
            _ = try await eventWriter.append(
                type: "task.settled", principal: principal, data: record.jsonValue,
                eventId: "settled:\(record.taskId)")
        }
        return .success(record.jsonValue)
    }

    private func stopTask(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments else { throw BotMCPError.invalidRequest("arguments must be an object") }
        guard let id = firstNonEmpty(args["task_id"], args["id"]), !id.isEmpty else {
            throw BotMCPError.invalidRequest("StopSubagent requires task_id")
        }
        let record = try await tasks.stop(taskId: id, parent: call)
        let principal = BotGatewayPrincipal(
            botId: call.principal.botId, sessionId: record.sessionId, kind: .task, expiresAt: Int64.max)
        _ = try await eventWriter.append(
            type: "task.stop_requested", principal: principal, data: record.jsonValue,
            eventId: "stop:\(record.taskId)")
        _ = try await eventWriter.append(
            type: "task.settled", principal: principal, data: record.jsonValue,
            eventId: "settled:\(record.taskId)")
        return .success(record.jsonValue)
    }

    private func updateRoutine(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        let result = try await BotRoutineTool.handle(
            machine: routineMachine, principal: call.principal, arguments: arguments, now: now())
        guard case .object(let args) = arguments, case .string(let action)? = args["action"] else {
            throw BotMCPError.invalidRequest("UpdateRoutine requires action")
        }
        if !["get", "list"].contains(action) {
            let type = action == "create" ? "routine.defined" : action == "delete" ? "routine.deleted" : "routine.updated"
            _ = try await eventWriter.append(type: type, principal: call.principal, data: result)
        }
        return .success(result)
    }

    private func requestApproval(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments, let action = string(args["action"]), !action.isEmpty else {
            throw BotMCPError.invalidRequest("RequestApproval requires action")
        }
        let detail = string(args["detail"]) ?? ""
        let command = string(args["command"]) ?? ""
        let resource = BotResourceNormalizer.normalize("action=\(action)")
        var effects = command.isEmpty ? [] : BotApprovalPatternAnalyzer.effects(
            tool: "bash", arguments: .object(["command": .string(command)]), workspace: "/dsh/workspace")
        effects.append(BotToolEffect(
            tool: "RequestApproval", operation: "approval.weak-action", resource: resource,
            target: command.isEmpty ? resource : command, mutability: .destructive, policy: .ask,
            label: action, detail: detail, known: false, isMcp: true))
        let alwaysScope = effects.contains(where: \.known) ? "until" : "session"
        let outcome = await approvals.request(
            call: call, effects: effects, action: action, detail: detail,
            command: command, alwaysScope: alwaysScope)
        return .success(.object([
            "allowed": .bool(outcome.allowed), "decision": .string(outcome.allowed ? "allowed" : "denied"),
            "approvalId": outcome.approvalId.map(BotJSONValue.string) ?? .null,
            "message": outcome.message.map(BotJSONValue.string) ?? .null,
        ]))
    }

    private func sendToUser(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard call.principal.kind == .chat else { throw BotMCPError.invalidRequest("SendToUser is only available in the main chat") }
        guard !hiddenTextSessions.contains(call.sessionId), !suppressingTextSessions.contains(call.sessionId) else {
            throw BotMCPError.invalidRequest("Text output is suppressed for this turn")
        }
        guard case .object(let args) = arguments, let message = string(args["message"]), !message.isEmpty else {
            throw BotMCPError.invalidRequest("SendToUser requires message")
        }
        let rowId = "message-\(UUID().uuidString.lowercased())"
        _ = try await eventWriter.append(
            type: "ui.send_to_user", principal: call.principal,
            data: .object([
                "id": .string(rowId), "type": .string("text"), "role": .string("assistant"),
                "text": .string(message), "content": .string(message),
            ]))
        return .success(.object(["ok": .bool(true), "rowId": .string(rowId)]))
    }

    private func effectsForApproval(name: String, botID: String,
                                    arguments: BotJSONValue) async -> [BotToolEffect] {
        if name == BotToolCatalog.volatileContextName { return [] }
        if name == BotToolCatalog.deviceReplyName {
            return await BotDeviceReplyTool.requiredEffects(store: store, botID: botID)
        }
        if ["bash", "write", "edit"].contains(name) {
            if name == "bash" {
                return BotApprovalPatternAnalyzer.effects(tool: name, arguments: arguments, workspace: "/dsh/workspace")
            }
            return [BotToolEffectClassifier.effect(for: name, arguments: arguments)]
        }
        let effect = BotToolEffectClassifier.effect(for: name, arguments: arguments)
        return effect.mutability == .read || effect.ui || effect.policy == .auto ? [] : [effect]
    }

    private func encode<T: Encodable>(_ value: T) throws -> BotJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try BotJSONValue.parse(encoder.encode(value))
    }

    private func firstNonEmpty(_ values: BotJSONValue?...) -> String? {
        for value in values {
            if let text = string(value), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    private func string(_ value: BotJSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private func bool(_ value: BotJSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }

    private func optionalInt(_ value: BotJSONValue?) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value, number.isFinite, number.rounded() == number else {
            throw BotMCPError.invalidRequest("timeout/limit must be an integer")
        }
        return Int(number)
    }

    private func bareToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.components(separatedBy: "__").last ?? name
    }

    private func key(_ runtimeId: String, _ sessionId: String, _ callId: String) -> String {
        "\(runtimeId)\u{0}\(sessionId)\u{0}\(callId)"
    }

    private static func code(_ error: BotMCPError) -> String {
        switch error {
        case .invalidRequest: return "invalid_arguments"
        case .unauthorized: return "unauthorized"
        case .unknownTool: return "unknown_tool"
        case .unattributed: return "unattributed"
        case .crossSessionDenied: return "cross_session_read_denied"
        case .timeout: return "timeout"
        case .unavailable: return "unavailable"
        }
    }

    private static func message(_ error: BotMCPError) -> String {
        switch error {
        case .invalidRequest(let message), .unavailable(let message): return message
        case .unauthorized: return "Unauthorized"
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .unattributed: return "The call is not attributable"
        case .crossSessionDenied: return "The requested session is outside the caller's principal"
        case .timeout: return "The operation timed out"
        }
    }
}
